# Document Sync (`iroh-docs`)

iroh's multi-writer, eventually-consistent key–value store: ed25519-signed `(namespace, author, key)` entries reconciled between peers by recursive range fingerprinting, with content bytes delegated to [blobs][blobs] and change notification to [gossip][gossip].

| Field               | Value                                                                                                                                                                                                 |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crate(s)            | [`iroh-docs`][docs-repo] (sync engine + range reconciler + redb store + irpc client)                                                                                                                  |
| Version             | `iroh-docs` 0.101.0 (git tag `v0.101.0`, commit `091e8cac47`) · against `iroh` 1.0.1 (`22cac742`), `iroh-blobs` 0.103.0, `iroh-gossip` 0.101.0, `irpc` 0.17.0, `redb` 4.1, `postcard` 1, `blake3` 1.8 |
| Repository          | [`n0-computer/iroh-docs`][docs-repo]                                                                                                                                                                  |
| Documentation       | [docs.rs/iroh-docs][docs-docs]                                                                                                                                                                        |
| ALPN(s)             | `/iroh-sync/1` ([`net.rs`][docs-net], line 18)                                                                                                                                                        |
| Approx. size (LoC)  | ~14,500 across `src/` (~9,000 non-test); the two load-bearing modules are `sync.rs` (2,688) and `ranger.rs` (1,652)                                                                                   |
| Category            | Protocols                                                                                                                                                                                             |
| Upstream spec/draft | Aljoscha Meyer, [_Range-Based Set Reconciliation_][meyer] (arXiv:2212.13567); data model informally after [Willow][willow] ("This is going to change!", [`sync.rs`][docs-sync-rs] lines 3–7)          |

---

## Overview

### What it solves

A _document_ in `iroh-docs` is a **multi-writer, eventually-consistent key–value map**. Internally it is a _replica_: a set of _entries_, each keyed by the triple `(NamespaceId, AuthorId, key-bytes)` ([`sync.rs`][docs-sync-rs], `RecordIdentifier`). The map's value is deliberately _not_ the payload — it is a `Record { len, hash, timestamp }` metadata pointer, and the content bytes it names live in [iroh-blobs][blobs], fetched separately by hash. Any number of authors may write the same key; conflicts resolve by a last-writer-wins rule (timestamp, then content hash). Deletion is modelled as writing an _empty_ entry, so a delete is itself a signed, replicated fact.

The hard problem is convergence: two peers each hold a large set of signed entries, and they must compute the _union_ of those sets over a network without shipping the whole set every time. `iroh-docs` solves it with **range-based set reconciliation** — a recursive protocol that fingerprints ranges of the ordered key space and only descends into ranges whose fingerprints disagree, so the traffic is proportional to the _difference_ between the two sets rather than their size. On top of that pairwise protocol, an [epidemic broadcast][gossip] layer fans out change notifications so a whole swarm converges from pairwise syncs. This page is the byte-level and state-machine contract for that stack; the serialization details it references live on the [wire-serialization][wire] page.

### Design philosophy

The reconciliation core is a direct implementation of Aljoscha Meyer's [range-based set reconciliation][meyer]; the crate documents the thesis verbatim ([`lib.rs`][docs-lib], lines 21–23):

> "Range-based set reconciliation is a simple approach to efficiently compute the union of two sets over a network, based on recursively partitioning the sets and comparing fingerprints of the partitions to probabilistically detect whether a partition requires further work."

The data model borrows its shape — namespaces, authors, prefix-pruning deletion, timestamp-then-hash ordering — from the [Willow][willow] protocol, with an explicit disclaimer that it is provisional ([`sync.rs`][docs-sync-rs], lines 3–7):

> "Names and concepts are roughly based on Willows design at the moment: https://hackmd.io/DTtck8QOQm6tZaQBBtTf7w … This is going to change!"

The prefix-pruning conflict rule is quoted from Willow directly in the `put` implementation ([`ranger.rs`][docs-ranger], lines 567–570): "Remove all entries whose timestamp is strictly less than the timestamp of any other entry … whose path is a prefix of `p`" and then "remove all but those whose record has the greatest hash component". This is the entire CRDT semantics, and it is encoded as the `Ord` impl on the entry value. The engineering philosophy is equally explicit and pragmatic: a single actor thread serialises _all_ store and reconciliation work so the store never needs to be `Sync`, and every wire artifact is [`postcard`][postcard] over a QUIC bidirectional stream. Both of those choices dissolve under a single-threaded runtime — see [Mapping to event-horizon](#mapping-to-event-horizon).

---

## How it works

### The data model

Identity is raw bytes. `NamespaceId` and `AuthorId` are `[u8; 32]` newtypes over ed25519 public keys ([`keys.rs`][docs-keys], lines 349, 367); the matching secrets are `NamespaceSecret` (the **write capability** for a whole document) and `Author` (an authorship proof), each wrapping an `iroh` `SecretKey`. A `RecordIdentifier` is one contiguous buffer — `namespace(32) || author(32) || key(var)` — ordered bytewise via a derived `Ord` on the underlying `Bytes` ([`sync.rs`][docs-sync-rs], lines 1006–1008). That single ordering drives _both_ the [redb][redb] key layout and the reconciliation range order, so the store and the reconciler never disagree about "what comes next".

The value is a metadata record, and its conflict order is fixed at the type level ([`sync.rs`][docs-sync-rs], lines 1126–1147):

```rust
// iroh-docs/src/sync.rs:1126-1147 (verbatim)
pub struct Record {
    len: u64,          // length of the data referenced by `hash`
    hash: Hash,        // blake3 of the content; Hash::EMPTY + len==0 => tombstone
    timestamp: u64,    // micros since the Unix epoch
}
// "Compares first the timestamp, then the content hash."
impl Ord for Record {
    fn cmp(&self, other: &Self) -> Ordering {
        self.timestamp.cmp(&other.timestamp)
            .then_with(|| self.hash.cmp(&other.hash))
    }
}
```

An `Entry { id: RecordIdentifier, record: Record }` is the unsigned fact; a `SignedEntry { signature: EntrySignature, entry: Entry }` carries two ed25519 signatures — one by the author, one by the namespace — over the _same_ canonical payload ([`sync.rs`][docs-sync-rs], lines 838–842, 913–917).

### The canonical signing payload

The bytes both signatures cover are **hand-rolled, not `postcard`** ([`sync.rs`][docs-sync-rs], lines 984–994, 1220–1224). They are `id.encode() || record.encode()`:

```text
signing payload (both author + namespace ed25519 signatures cover these bytes):
  namespace   32 bytes
  author      32 bytes
  key         var bytes        ── id.encode()  (RecordIdentifier)
  len         8 bytes  big-endian
  hash        32 bytes
  timestamp   8 bytes  big-endian   ── record.encode()
```

Two subtleties a byte-exact port must reproduce. First, this fixed-width big-endian layout is _not_ how a `SignedEntry` serialises on the wire: the `postcard` form encodes `len` and `timestamp` as LEB128 varints and `id` as a length-prefixed `Bytes`, so the signed bytes and the transmitted bytes differ — the verifier must reconstruct the canonical payload from the decoded fields, it cannot re-hash the received frame. Second, there is a standing `// TODO` that the payload "should probably include a namespace prefix" for domain separation ([`sync.rs`][docs-sync-rs], lines 861–863); today the namespace bytes lead the payload but there is no explicit domain-separation tag.

### Conflict resolution and prefix pruning

Insertion is a CRDT operation defined once as the default `Store::put` in the reconciler ([`ranger.rs`][docs-ranger], lines 551–584). A new entry is stored iff its value compares **strictly greater** than the value of every existing entry whose key _is a prefix of, or equal to,_ the new key (the `prefixes_of` walk). Then every existing entry whose key is _prefixed by_ the new key with a value ≤ the new value is physically deleted (`remove_prefix_filtered`), and finally the new entry is written. So the semantics are last-writer-wins per `(author, key)`, with the content `hash` as tiebreaker, and an exact duplicate is a no-op (`InsertOutcome::NotInserted`). Because the comparison is on `Record`, an author can always win a conflict by choosing a larger timestamp.

### Tombstones and deletion

Deletion is not a separate operation — it is an _empty_ entry. `Record::empty(ts) = Record::new(Hash::EMPTY, 0, ts)` ([`sync.rs`][docs-sync-rs], lines 1169–1177), and `Replica::delete_prefix` signs an empty entry whose key is the prefix to erase; the `put` prefix-pruning rule above then removes everything under it ([`sync.rs`][docs-sync-rs], lines 401–417). A normal `insert` refuses an empty payload (`InsertError::EntryIsEmpty`), and remote entries must satisfy the invariant `hash == EMPTY ⟺ len == 0` (`validate_empty`, error `InvalidEmptyEntry`). Tombstones persist as ordinary rows and replicate like any entry, but queries filter them out unless `include_empty` is set ([`store/fs/query.rs`][docs-repo]). A prefix delete physically drops the pruned rows with no per-row event, so the deleted set is unrecoverable except by re-syncing from a peer that still holds newer, non-pruned data.

Validation on every insert (`validate_entry`, [`sync.rs`][docs-sync-rs], lines 615–644): the namespace must match the replica, both signatures are verified for non-local origins, and the timestamp must be ≤ now + `MAX_TIMESTAMP_FUTURE_SHIFT` = 600,000,000 µs = 10 minutes ([`sync.rs`][docs-sync-rs], lines 46–48). Entries arbitrarily far in the _past_ are accepted; only the future is bounded.

### Range-based set reconciliation (`ranger.rs`)

Ranges are wrap-around pairs `Range { x, y }` over `RecordIdentifier`s ([`ranger.rs`][docs-ranger], lines 64–68): `x == y` means "everything", `x < y` is the half-open `[x, y)`, and `x > y` is the complement wrap. A range's `Fingerprint` is a 32-byte value combined by **byte-wise XOR** of per-entry fingerprints ([`ranger.rs`][docs-ranger], lines 106–128):

```rust
// iroh-docs/src/ranger.rs:106-128 (verbatim)
pub struct Fingerprint(pub [u8; 32]);
impl Fingerprint {
    pub(crate) fn empty() -> Self { Fingerprint(*blake3::hash(&[]).as_bytes()) }
}
impl std::ops::BitXorAssign for Fingerprint {
    fn bitxor_assign(&mut self, rhs: Self) {
        for (a, b) in self.0.iter_mut().zip(rhs.0.iter()) { *a ^= b; }
    }
}
```

A per-entry fingerprint is `BLAKE3(namespace(32) || author(32) || key || timestamp_be(8) || content_hash(32))` ([`sync.rs`][docs-sync-rs], lines 826–834). Note that this fingerprint order differs from the signing payload: it _omits_ `len` and puts `timestamp` **before** `hash`. The empty-set fingerprint is `BLAKE3("")` — the hash of the empty string, deliberately _not_ all-zeros, so XOR-combination stays well-defined ([`ranger.rs`][docs-ranger], lines 115–120).

`Store::process_message` ([`ranger.rs`][docs-ranger], lines 324–549) consumes a `Message { parts: Vec<MessagePart> }` where each part is a `RangeFingerprint` or a `RangeItem`. The algorithm:

- **Incoming `RangeItem`** — store each value that passes `validate_cb` via `put` (firing `on_insert_cb` for real inserts). If the item's `have_local` flag is `false`, compute the _diff_ — local entries in the range absent from the peer's set, or present with a strictly smaller peer value — and reply `RangeItem { values: diff, have_local: true }`. `have_local: true` ends that branch.
- **Incoming `RangeFingerprint`** — three cases:
  1. equal fingerprints → the range is already in sync, no output;
  2. _recursion anchor_: if the local count ≤ 1, or the remote fingerprint equals the empty fingerprint, reply with all local values as a `RangeItem { have_local: false }`;
  3. otherwise **split** the range into `split_factor` subranges at pivots drawn from evenly spaced local elements, and for each non-empty subrange reply with a fresh `RangeFingerprint` if its chunk exceeds `max_set_size`, else a `RangeItem` carrying the values.

If no parts are produced, the reply is `None`, which terminates the session. The initial message is a single `RangeFingerprint` over the whole set (`Range(first_key, first_key)`, [`ranger.rs`][docs-ranger], lines 200–207). The configuration is effectively hardcoded: `process_message` is always called with `&SyncConfig::default()`, i.e. **`max_set_size: 1`, `split_factor: 2`** ([`ranger.rs`][docs-ranger], lines 673–688; call site [`sync.rs`][docs-sync-rs] line 547) — so a mismatched range is bisected until each subrange holds at most one element. The tunables are dead config in production. Termination is guaranteed because every recursion strictly reduces range cardinality, and equal fingerprints or a completed item exchange produce no output.

Every outgoing entry is annotated with a `ContentStatus` (`Complete`/`Incomplete`/`Missing`) obtained by awaiting a `content_status_cb` — a blobs-availability probe carried inline in the `RangeItem` values ([`ranger.rs`][docs-ranger], lines 384–388, 427–432). When no blob store is wired in, the default is `Missing` ([`sync.rs`][docs-sync-rs], lines 575–581). This callback is the _only_ asynchronous point inside `process_message`; all store work is synchronous.

### The network protocol (`net.rs`, `net/codec.rs`)

One sync session is one bidirectional QUIC stream under ALPN `/iroh-sync/1`. The dialer (`connect_and_sync`) opens `open_bi`, runs the initiator ("Alice") loop, then performs a clean close — `finish()` → `stopped()` → `read_to_end(0)` ([`net.rs`][docs-net], lines 23–92). The acceptor (`handle_connection`) mirrors with `accept_bi` and the responder ("Bob") loop.

Framing is a 4-byte **big-endian `u32`** length prefix followed by a `postcard`-encoded `Message`, with a maximum frame of `MAX_MESSAGE_SIZE = 1024 * 1024 * 1024` = 1 GiB and the self-deprecating comment "This is likely too large, but lets have some restrictions" ([`net/codec.rs`][docs-codec], lines 22–68). The session envelope is a three-variant enum ([`net/codec.rs`][docs-codec], lines 76–89):

```rust
// iroh-docs/src/net/codec.rs:76-89 (verbatim) — postcard varint discriminants 0/1/2
enum Message {
    Init { namespace: NamespaceId, message: ProtocolMessage },  // only the dialer, exactly once
    Sync(ProtocolMessage),                                       // both directions
    Abort { reason: AbortReason },                              // only the acceptor
}
// iroh-docs/src/net.rs:280-288
pub enum AbortReason { NotFound, AlreadySyncing, InternalServerError }  // 0/1/2
```

`ProtocolMessage` is `ranger::Message<SignedEntry>`. Progress is threaded through every call as a `SyncOutcome { heads_received, num_recv, num_sent }`.

### The store actor and redb schema

All store and replica access is funnelled through a **dedicated OS thread** named `"sync-actor"` that runs a current-thread tokio runtime inside a `LocalSet` (on wasm it degrades to a spawned task) ([`actor.rs`][docs-actor], lines 266–306). The rationale is documented on the handle ([`actor.rs`][docs-actor], lines 220–224):

> "The [`SyncHandle`] exposes async methods which all send messages into the actor thread, usually returning something via a return channel. The actor thread itself is a regular [`std::thread`] which processes incoming messages sequentially."

Callers send `Action`s over a bounded `async_channel` (`ACTION_CAP = 1024`) and receive replies via `tokio::sync::oneshot` (or an irpc `mpsc` for streaming). The actor owns the [redb][redb] `Store`, the `HashMap<NamespaceId, OpenReplica>` of open replicas with handle refcounts, and a `JoinSet` of streaming tasks. Its loop `select!`s over a **500 ms flush timer** (`MAX_COMMIT_DELAY`) that commits the pending redb write transaction, `join_next()` reaping, and the action channel. Writes reuse an open write transaction until it is 500 ms old, then commit and reopen (`CurrentTransaction`, [`store/fs.rs`][docs-store-fs], lines 229–294) — a coarse batching that trades durability latency for throughput.

The persistent schema is seven redb tables ([`store/fs/tables.rs`][docs-tables], lines 13–73):

| Table                     | Key                                             | Value                                                                         |
| ------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------- |
| `authors-1`               | `[u8;32]` `AuthorId`                            | `[u8;32]` author secret                                                       |
| `namespaces-2`            | `[u8;32]` `NamespaceId`                         | `(u8, [u8;32])` = `(CapabilityKind, secret-or-id)`                            |
| `records-1`               | `([u8;32], [u8;32], &[u8])` = (ns, author, key) | `(u64, [u8;64], [u8;64], u64, [u8;32])` = (ts, ns-sig, author-sig, len, hash) |
| `records-by-key-1`        | `([u8;32], &[u8], [u8;32])` = (ns, key, author) | `()` — pure secondary index                                                   |
| `latest-by-author-1`      | `([u8;32], [u8;32])` = (ns, author)             | `(u64, &[u8])` = (timestamp, key)                                             |
| `sync-peers-1` (multimap) | `[u8;32]` ns                                    | `(u64 nanos, [u8;32] peer)` — LRU of 5 useful peers                           |
| `download-policy-1`       | `[u8;32]` ns                                    | `postcard` `DownloadPolicy`                                                   |

`entry_put` writes the `records`, `records-by-key`, and `latest-by-author` tables atomically ([`store/fs.rs`][docs-store-fs], lines 760–793); signatures are stored inline (64 + 64 bytes per row). Queries choose an index via `IndexKind::from(&Query)`: author-then-key scans hit `records-1` directly, while key-then-author and "single latest per key" scans walk `records-by-key-1` and join back per hit. Range scans for the reconciler split a wrap-around range into up to two chained redb bounds-scans, and `prefixes_of` (the CRDT parent walk) is `O(key_len)` point lookups.

### Engine, live sync, gossip and blobs handoff

`Engine::spawn` wires the store actor, a `ContentStatusCallback` mapping `blobs.status(hash)` to `Complete`/`Incomplete`/`Missing`, a GC-protect task that streams doc-referenced hashes to the blobs garbage collector, and the **LiveActor** ([`engine.rs`][docs-engine]). The LiveActor is a single-owner event loop whose biased `select!` multiplexes its command inbox (`mpsc`, `ACTOR_CHANNEL_CAP = 64`), a replica-events channel (`async_channel`, cap 1024, subscribed into every open-for-sync replica), three `JoinSet`s (connect-syncs, accept-syncs, downloads), and per-namespace gossip progress ([`engine/live.rs`][docs-live], lines 239–294).

Live flow: `start_sync(namespace, peers)` opens the replica with `sync: true`, registers peer addresses in a `MemoryLookup` address book, joins the per-namespace [gossip][gossip] topic (topic id = the raw 32-byte `NamespaceId`), and kicks an initial sync for each bootstrap peer. Thereafter each replica insert raises a `LocalInsert` or `RemoteInsert` event; the LiveActor turns a `LocalInsert` into a gossip broadcast of `Op::Put(SignedEntry)` and a `RemoteInsert` into a content-download decision ([`engine/live.rs`][docs-live], lines 708–742). The gossip payloads are three ([`engine/live.rs`][docs-live], lines 40–56):

```rust
// iroh-docs/src/engine/live.rs:40-56 (verbatim) — postcard Op, discriminants 0/1/2
pub enum Op {
    Put(SignedEntry),
    ContentReady(Hash),
    SyncReport(SyncReport),   // { namespace: NamespaceId, heads: Vec<u8> /* encoded AuthorHeads */ }
}
```

An incoming `Op::Put` becomes an `insert_remote`, with `ContentStatus::Complete` assumed iff the message arrived direct from a neighbor (`msg.scope.is_direct()`), else `Missing`. `Op::ContentReady(hash)` triggers a download from that neighbor only if the hash is still missing. `Op::SyncReport` carries a size-capped `AuthorHeads` (the newest timestamp per author, [`heads.rs`][docs-heads]); the receiver compares heads via `has_news_for_us` and, if the reporter is ahead, starts a sync with it. Critically, **after every successful sync that received > 0 entries, the node broadcasts its own `SyncReport`** to gossip neighbors — this anti-entropy fan-out is what lets a swarm converge from pairwise syncs ([`engine/live.rs`][docs-live], lines 566–584). Downloads go through the iroh-blobs `Downloader` with a `ProviderNodes` map (hash → known provider endpoint ids) and `SplitStrategy::None`; completion emits `Event::ContentReady` plus a gossip `Op::ContentReady`, and failure re-queues the hash.

Concurrent syncs are deduplicated by a `PeerState` per `(namespace, peer)`: starting a connect while `Running` is refused, and a simultaneous dial+accept is resolved deterministically — the node with the _larger_ id bytes accepts, the other's dial wins (`expected_sync_direction`, [`engine/state.rs`][docs-state], lines 215–256).

### The irpc API seam

The client API (`DocsApi`, `Doc`) is a thin layer over [irpc][irpc] 0.17 ([`api.rs`][docs-api]). `DocsApi` wraps an `irpc::Client<DocsProtocol>` — a 26-variant request enum, each variant a `oneshot` or server-streaming `mpsc` reply, none carrying client-update channels ([`api/protocol.rs`][docs-api-proto], lines 307–366). irpc's essential design is _one serde request enum_ + a per-variant `(Tx, Rx)` channel-type mapping + a message type that is the request combined with its live channels; in-process this is a channel send into an actor, and remotely it is one QUIC bidi stream carrying `varint-len ++ postcard` frames, with no request IDs or headers — multiplexing is entirely QUIC's ([`irpc lib.rs`][irpc-lib], lines 50–52). Notably, the docs remote handler is hand-rolled as a 26-arm match rather than the derive-generated `remote_handler`, and the entire RPC plane dials the loopback (`"localhost"`, self-signed certs) over vanilla `noq` — it is a **cross-process CLI/daemon** feature, never the p2p endpoint. irpc's own goal is to be so lightweight it replaces "a mpsc channel with a giant message enum where each enum case contains mpsc or oneshot backchannels" ([`irpc lib.rs`][irpc-lib], lines 5–9) — which is exactly what a single-threaded D port makes unnecessary in-process (direct method calls).

---

## Analysis

### Wire format & framing

Everything is [`postcard`][postcard] over a QUIC bidi stream, except the two hand-rolled cryptographic payloads (the signing payload and the fingerprint pre-image). The complete surface, all cross-referenced from [wire-serialization][wire]:

- **ALPN**: `b"/iroh-sync/1"` ([`net.rs`][docs-net], line 18).
- **Frame**: 4-byte big-endian `u32` length (body only) + `postcard` body; max body 1 GiB (`MAX_MESSAGE_SIZE`, [`net/codec.rs`][docs-codec], line 22). Note this is a _third_ varint dialect coexisting with `postcard` LEB128 and QUIC varints: docs uses a plain fixed 4-byte big-endian prefix, matching [gossip's][gossip] framing but unlike blobs.
- **Session envelope** (`postcard` enum, varint discriminant): `0 = Init { namespace: [u8;32], message }`, `1 = Sync(message)`, `2 = Abort { reason }`. `AbortReason`: `0 = NotFound`, `1 = AlreadySyncing`, `2 = InternalServerError`.
- **Reconciliation message**: `Message { parts: Vec<MessagePart> }`; `MessagePart`: `0 = RangeFingerprint { range: {x, y}, fingerprint: [u8;32] }`, `1 = RangeItem { range, values: Vec<(SignedEntry, ContentStatus)>, have_local: bool }`. `Range<RecordIdentifier>` serialises as two `Bytes` (varint length + bytes each). `ContentStatus`: `0 = Complete`, `1 = Incomplete`, `2 = Missing`.
- **`SignedEntry`** (`postcard` field order): `signature { author_signature(64), namespace_signature(64) }`, then `entry { id: Bytes, record { len: varint, hash: [u8;32], timestamp: varint } }`. `iroh::Signature` wraps `ed25519_dalek::Signature` behind a wire-stable `serialize_tuple` impl so the on-wire format is independent of upstream `serde` changes ([`sync.rs`][docs-sync-rs], lines 17–22).
- **Canonical signing payload** (hand-rolled, big-endian, _not_ `postcard`): `namespace(32) || author(32) || key || len_be(8) || hash(32) || timestamp_be(8)`.
- **Per-entry fingerprint**: `BLAKE3(namespace(32) || author(32) || key || timestamp_be(8) || content_hash(32))`; range fingerprint = XOR of entry fingerprints; empty-set fingerprint = `BLAKE3("")`.
- **`AuthorHeads`** (inside `SyncReport.heads`): `postcard` `Vec<(u64 timestamp, [u8;32] author)>`, newest-first, tail-truncated until it fits the gossip max message size.
- **Gossip `Op`**: `0 = Put(SignedEntry)`, `1 = ContentReady([u8;32])`, `2 = SyncReport { namespace(32), heads: Vec<u8> }`; gossip topic id = the raw `NamespaceId` bytes.
- **`DocTicket`**: `postcard` of a single-variant `TicketWireFormat` (leading `0x00`) → `Capability` (`Write(secret 32)` = 0 / `Read(id 32)` = 1) + 32-byte key + `Vec<EndpointAddr>`; string form is `"doc"` + lowercase base32-nopad, decode rejects empty `nodes` ([`ticket.rs`][docs-ticket]). See [wire-serialization][wire] for the byte-exact golden vector.

Constants a decoder must enforce: `MAX_MESSAGE_SIZE` = 1 GiB, `MAX_TIMESTAMP_FUTURE_SHIFT` = 600,000,000 µs, `PEERS_PER_DOC_CACHE_SIZE` = 5. The 1 GiB frame is a genuine hazard: a `RangeItem` can legitimately carry a huge value set, so a port should stream item parts or cap far lower.

### Cryptography & identity

Every entry carries **two** ed25519 signatures over the same canonical payload — the author's (proof of authorship) and the namespace's (write authority) ([`sync.rs`][docs-sync-rs], `EntrySignature`). Verification recovers both public keys directly from the id bytes (they _are_ the 32-byte keys) and checks both signatures; a `MemPublicKeyStore` caches the decompressed ed25519 points to avoid repeated curve decompression during a sync ([`store/pubkeys.rs`][docs-repo]). Ids are stored and transmitted as raw bytes that may not be valid curve points until decompressed, so verification is where malformed keys are rejected.

The capability model is coarse. Holding the `NamespaceSecret` is the write capability; the read capability is simply **knowledge of the 32-byte `NamespaceId`**. A sync session performs _no_ authentication of the reader: Bob's accept callback only checks that the namespace is in the local sync set (else `NotFound`), so anyone who holds the id can fetch the entire document from any syncing node. A `DocTicket` with a `Write` capability embeds the raw namespace secret in the copy-pasteable string — tickets are bearer credentials. The full algorithm inventory (ed25519, blake3) belongs to [identity-crypto][identity-crypto]; the one docs-specific note is the missing domain-separation tag flagged in the signing-payload `TODO`.

### State machines & lifecycle

Eight interacting machines govern a session; all are synchronous except where noted:

1. **Initiator ("Alice")** (`run_alice`, [`net/codec.rs`][docs-codec]): _SendInit_ → _Loop_. Send `Init { namespace, whole-set fingerprint }`; on each `Sync(msg)` call `sync_process_message`, send the reply if `Some`, break if `None`. An unexpected `Init` or an `Abort` is a hard error; the clean close is `finish` → `stopped` → `read_to_end(0)`. No timers at this layer — QUIC handles liveness.
2. **Responder ("Bob")** (`BobState::run`, [`net/codec.rs`][docs-codec]): state variable `namespace: Option<NamespaceId>`. `(Init, None)` runs the accept callback (an async round-trip into the LiveActor); `Reject` → send `Abort` and error; `Allow` → process and set the namespace. `(Sync, Some)` → process. A double `Init`, a `Sync` before `Init`, or an `Abort` received by Bob are all protocol violations.
3. **Per-range recursion** (implicit, distributed): whole-set fingerprint → split into 2 → each subrange is either a fingerprint (chunk > 1 element) or an item exchange (≤ 1 element, or remote-empty). Terminates because cardinality strictly decreases.
4. **`PeerState` per `(namespace, peer)`** ([`engine/state.rs`][docs-state]): `Idle → Running{origin} → Idle`; a `SyncReport` while `Running` sets `resync_requested` so a fresh sync fires on completion; simultaneous dial+accept resolved by the id-bytes tie-break.
5. **`PendingContentReady` gate**: after a sync finishes, `PendingContentReady` is emitted exactly once — immediately if nothing was queued, else when the namespace's queued-hash set drains.
6. **Store transaction state** (`CurrentTransaction`): `None ↔ Read ↔ Write`; writes reuse the open write tx until it is 500 ms old, then commit; any snapshot request commits first.
7. **Content download tracking**: a hash is in exactly one of `missing_hashes`, `queued_hashes`, or done; a neighbor `ContentReady` moves missing → queued; a failed download moves it back.
8. **Replica open/close refcount** (`OpenReplicas`): open increments `handles` and merges the `sync` flag and subscribers; close decrements and evicts at 0.

### Dependencies & coupling

| Crate                         | Depth               | Notes for a D port                                                                                                                                                                                                                                                  |
| ----------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`redb`][redb] 4.1            | load-bearing        | Embedded ordered KV with multi-table ACID writes, forward/reverse range scans, multimap tables, `extract_from_if`/`retain_in`. A port needs an ordered persistent map with prefix/range scans and batched transactions. In-memory mode is redb's `InMemoryBackend`. |
| [`postcard`][postcard] 1      | load-bearing (wire) | Every wire artifact is `postcard`; reproduce bit-exactly (see [wire-serialization][wire]).                                                                                                                                                                          |
| `blake3` 1.8                  | load-bearing        | Entry and empty-set fingerprints — same library as [blobs][blobs]/[bao-tree][bao-tree].                                                                                                                                                                             |
| ed25519 (via `iroh`)          | load-bearing        | Two signatures per entry; ids are the public keys.                                                                                                                                                                                                                  |
| [`iroh`][iroh-repo] 1.0.1     | integration         | `Endpoint`/`Connection` (QUIC bidi streams over [noq][quic-transport]), `EndpointAddr`, `MemoryLookup` address book.                                                                                                                                                |
| [`iroh-gossip`][gossip] 0.101 | integration         | topic subscribe/broadcast, neighbor up/down events, `scope.is_direct()`.                                                                                                                                                                                            |
| [`iroh-blobs`][blobs] 0.103   | integration         | `blobs.status(hash)`, `Downloader::download_with_opts` + `ContentDiscovery`, `add_bytes`, GC protect.                                                                                                                                                               |
| [`irpc`][irpc] 0.17           | API surface         | Client API plumbing; in-proc = channels, remote = `noq`. Any RPC veneer substitutes.                                                                                                                                                                                |

`tokio-util` codec, `async-channel`, `tokio::sync`, `n0-future`, `self_cell`, and the derive-convenience crates are all shallow plumbing a port replaces with event-horizon constructs.

### Concurrency & I/O model

`iroh-docs` is one of the most concurrency-dense subsystems in the workspace — the [concurrency][concurrency] inventory catalogues ~26 distinct primitives. The shape is a **hierarchy of single-owner actors**: the `"sync-actor"` OS thread serialises all store and CRDT work behind an `async_channel` mailbox with per-request `oneshot` replies; the `LiveActor` task orchestrates live sync behind an `mpsc` inbox and three `JoinSet`s (connect/accept/download); the `RpcActor` task dispatches the irpc client protocol; and per-namespace gossip receive loops feed the LiveActor. Fan-out to subscribers is a `join_all` over per-replica `async_channel` senders that **back-pressures inserts** if a subscriber stops reading ([`sync.rs`][docs-sync-rs], lines 296–299). Shared state that survives the actor boundary — `ProviderNodes`, `MemPublicKeyStore`, `DefaultAuthor` — is wrapped in `Arc<Mutex<…>>`/`Arc<RwLock<…>>`. The two load-bearing rationales are Rust ownership (the store must not be `Sync`) and moving blocking redb I/O off the multi-threaded tokio runtime — both of which vanish under a single loop thread.

### Mapping to event-horizon

Under [`sparkles:event-horizon`][eh-spec]'s default `single` topology — one loop, one thread, completion-first io_uring — the entire actor-and-mailbox scaffolding collapses, and the subsystem becomes markedly simpler. Four moves matter.

**1. The store actor collapses into a plain fiber-owned struct.** The `"sync-actor"` thread exists only for Rust ownership and to keep blocking redb I/O off the runtime; io_uring covers file I/O natively (no `spawn_blocking` substitute needed, per the [eh brief][eh-spec]). The `Action`/`oneshot` message set becomes an ordinary method interface on a non-`shared` struct one fiber owns:

```rust
// iroh-docs/src/actor.rs:232-241 (verbatim) — the handle to the actor thread
pub struct SyncHandle {
    tx: async_channel::Sender<Action>,
    join_handle: Arc<Option<std::thread::JoinHandle<()>>>,
    metrics: Arc<Metrics>,
}
```

```d
// proposed / sketch — no thread, no mailbox, no oneshot; "Action"s are methods.
struct SyncStore
{
    Db db;                         // redb-equivalent ordered KV (own module)
    OpenReplicas open;            // NamespaceId -> OpenReplica { handles, sync, subs }
    MemPubKeyCache keys;          // decompressed ed25519 points

    // was Action::InsertLocal { .. } + oneshot reply
    IoResult!InsertOutcome insertLocal(NamespaceId ns, in Author a,
                                       scope const(ubyte)[] key, Hash h, ulong len);

    // was Action::SyncProcessMessage — see the invariant below.
    IoResult!(Message*) processMessage(NamespaceId ns, Message* msg,
                                       scope ContentStatusFn contentStatus);
}
```

The one invariant to preserve is **sequential store access**: `process_message` mutates the store mid-message (validate → put → diff), and the async point inside it is _only_ the `content_status_cb`. In Rust the actor thread serialises interleaving; in D, either run `processMessage`'s store work to completion without yielding, or gate a store with a logical "busy" token so two sessions cannot interleave at the `contentStatus` await. Model `content_status_cb` as a DbI capability (`isContentStatus`) so docs-sync is testable with no blob store (default `Missing`).

**2. The LiveActor becomes a `Scope` with a `race` loop.** The biased `tokio::select!` over inbox / replica-events / three `JoinSet`s / gossip progress maps to a `race` over an inbound command source plus child-fiber completions; the `JoinSet`s become child fibers `fork`ed in a `Scope`, and the scope's exit-join replaces `JoinSet` reaping — strictly stronger than Rust's abort-on-drop, whose swallowed panics are a known flaw. The obstacle is that **event-horizon has no cross-fiber channel primitive yet** (open issue O20), and this subsystem leans on channels heavily (the mailbox, the cap-1024 replica-events channel, subscriber fan-outs). Two viable paths: (a) resolve the channel design first (bounded SPSC suffices), or (b) restructure LiveActor callbacks as direct method calls on the single-threaded object — feasible precisely because the Rust `sync_actor_tx` self-send exists _only_ to avoid a same-thread deadlock ([`engine/live.rs`][docs-live], lines 157–159), which does not arise when one fiber owns the loop.

**3. Sync sessions map cleanly to Tier-B fibers.** `run_alice` / `BobState::run` are sequential recv → process → send loops over one QUIC bidi stream — ideal direct-style code with blocking-looking `recv`/`send` verbs, no function coloring:

```d
// proposed / sketch — one bidi noq stream; parks the fiber on recv, no channel/task.
Outcome!SyncOutcome runAlice(ref BiStream s, NamespaceId ns,
                             ref SyncStore store, in Env env)
{
    s.send(encode(Message.init(ns, store.initialMessage(ns))));  // Init{ns, whole-set fp}
    for (;;)
    {
        auto frame = s.recvFramed();          // u32-BE length + postcard body
        auto reply = store.processMessage(ns, decode!Message(frame), env.contentStatus);
        if (reply.isNone) break;              // None => reconciliation converged
        s.send(encode(reply.get));
    }
    s.finish(); s.stopped(); s.readToEnd(0);  // clean-close handshake ([noq] stream verbs)
    return ok(store.outcome);
}
```

The clean-close handshake needs the [noq][quic-transport] stream API equivalents of `finish`/`stopped`/`read_to_end(0)`; whether `read_to_end(0)` keeps quinn's "error if the peer sent unread data" semantics on the new noq API is an open interop question. Cancellation maps _better_ than Rust: a sync fiber cancelled by scope teardown resumes only at its terminal CQE, and the `Cause.interrupt` arm is the natural carrier for the `AlreadySyncing`/shutdown path.

**4. Locks and clocks become plain fields and capabilities.** Every `Arc<Mutex<…>>`/`RwLock` (`ProviderNodes`, `MemPublicKeyStore`, `DefaultAuthor`) is single-threaded refcount noise and collapses to a plain field. The tie-break logic (`expected_sync_direction`) and the `PeerState` machine are already pure and port as-is. The 500 ms flush timer is an in-ring `TIMEOUT` op re-armed per loop iteration; transaction age uses `MonoTime`. The determinism win is real: wall-clock `SystemTime::now` → µs timestamps should route through the `RingClock`/`isClock` capability so `TestClock` drives the timestamp-conflict tests deterministically, and `SimNet` can replace the QUIC stream entirely (the Rust tests already use `tokio::io::duplex`). The wasm single-thread mode `iroh-docs` already ships validates that the whole subsystem runs single-threaded. The irpc remote plane (`DocsApi::connect`/`listen`) is a localhost cross-process feature over vanilla QUIC, independent of the p2p wire, and can be deferred to a later milestone — but the request-enum schema should be fixed early because the in-process API shape derives from it (see [concurrency § irpc][concurrency]).

---

## Strengths

- **Sub-linear convergence.** Range-based set reconciliation exchanges traffic proportional to the _difference_ between two sets, not their size — a swarm of near-synchronised peers reconciles cheaply.
- **Clean three-layer separation.** Metadata (docs) / content ([blobs][blobs]) / propagation ([gossip][gossip]) are decoupled; a document row is a signed pointer, and content transfer is a separate, hash-verified fetch.
- **Genuine multi-writer semantics.** Authorship (`Author`) is separated from write authority (`NamespaceSecret`), and every entry is doubly signed, so a document can accept writes from many authors while any node can verify provenance offline.
- **Deletion is first-class and replicable.** Tombstones are signed empty entries and prefix deletes prune subtrees, so deletion converges like any other CRDT fact rather than being a local-only operation.
- **One ordering drives everything.** The bytewise `RecordIdentifier` order is simultaneously the redb key layout and the reconciliation range order, eliminating a whole class of store/reconciler mismatch bugs.
- **Anti-entropy fan-out.** Broadcasting a `SyncReport` after each successful sync lets pairwise reconciliation converge an entire gossip swarm without a coordinator.
- **Already single-threaded-capable.** The wasm task-fallback mode proves the design runs without the actor thread — direct validation of the event-horizon `single`-topology port shape.

## Weaknesses

- **No incremental fingerprints.** `get_fingerprint` is a full `O(n)` range walk with a standing `// TODO: optimize` ([`store/fs.rs`][docs-store-fs], lines 747–748) — there is no cached fingerprint tree, so even reconciling two _equal_ sets costs a full scan for the initial fingerprint, and blake3 over the whole range runs on the serialising actor thread.
- **A 1 GiB max frame.** `MAX_MESSAGE_SIZE` is 1 GiB with a self-deprecating comment; a `RangeItem` can carry an unbounded value set, so a hostile or unlucky peer can force a huge allocation. A port needs streaming item parts or a far smaller cap.
- **Sender-chosen wall-clock timestamps.** With only a +10-minute future bound and no lower bound, an author can win any conflict by post-dating within 10 minutes, and arbitrarily-past entries are accepted — the conflict rule is trust-based, not causal.
- **Prefix deletes are irreversible and silent.** Pruned rows are physically dropped with no per-row event; the deleted set is unrecoverable except by re-syncing from a peer that still holds newer, non-pruned data.
- **The read capability is just the id.** Knowledge of the 32-byte `NamespaceId` grants a full read; a syncing node authenticates no reader, so id leakage leaks the whole document.
- **Dead configuration.** `SyncConfig`'s `max_set_size`/`split_factor` are always `Default` (1, 2) in production; the tunables cannot be exercised without code changes.
- **A provisional, Willow-derived model.** The crate states outright that names and concepts "are going to change", and the signing payload lacks an explicit domain-separation tag ([`sync.rs`][docs-sync-rs], `TODO` at 861–863).
- **Heavy channel/actor coupling.** ~26 concurrency primitives and a subscriber `join_all` that back-pressures inserts make the Rust structure the densest translation target in the workspace; a `same_channel` identity check even resorts to `mem::transmute_copy` on channel senders.

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                                        | Trade-off                                                                                            |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| Range-based set reconciliation (Meyer) as the transfer protocol         | Traffic scales with the set _difference_; probabilistic fingerprint comparison avoids full dumps | Every fingerprint is an `O(n)` scan (no incremental tree); reconciling equal sets still costs a scan |
| Value = `Record` metadata pointer, content in [blobs][blobs]            | Documents stay small and fast to reconcile; content transfer is separate and hash-verified       | Two subsystems and a `ContentStatus` handoff to coordinate; a synced row may name content you lack   |
| Last-writer-wins by `(timestamp, hash)` with prefix pruning (Willow)    | A total order on values makes CRDT merge trivial and deterministic; deletes are ordinary entries | Sender-chosen wall-clock; post-dating wins conflicts; pruned rows are physically, silently dropped   |
| Dual ed25519 signatures (author + namespace) over a hand-rolled payload | Separates authorship from write authority; wire-stable signature encoding independent of `serde` | Two verifications per remote entry; the signed bytes differ from the wire bytes; no domain-sep tag   |
| Read capability = knowing the 32-byte `NamespaceId`                     | Simple bearer-token sharing via tickets; no key exchange to read                                 | Any id holder can fetch the whole doc from a syncing node; no per-reader authentication              |
| A single `"sync-actor"` thread serialises all store + CRDT work         | The store never needs to be `Sync`; blocking redb I/O stays off the async runtime                | A mailbox/`oneshot`/`JoinSet` scaffold to maintain; the blake3 fingerprint scan runs on one thread   |
| 500 ms write-transaction batching (`MAX_COMMIT_DELAY`)                  | Amortises redb commit cost across bursts of inserts                                              | Up to 500 ms of durability latency; a crash loses the open transaction's uncommitted writes          |
| `postcard` + `u32`-BE length frames on a QUIC bidi stream per session   | Compact, `serde`-native, one stream = one session; QUIC handles liveness and multiplexing        | 1 GiB frame cap admits huge `RangeItem`s; no streaming of large value sets                           |
| Anti-entropy `SyncReport` over gossip after each sync                   | Swarm convergence from pairwise reconciliation without a coordinator                             | Extra gossip traffic; content-location `Complete` is a scope heuristic, not a sender claim           |

---

## Sources

- [`iroh-docs/src/lib.rs`][docs-lib] — crate docs, Meyer/Willow framing, redb backing
- [`iroh-docs/src/sync.rs`][docs-sync-rs] — `Record`/`Entry`/`SignedEntry`, signing payload, conflict + tombstone rules, per-entry fingerprint
- [`iroh-docs/src/ranger.rs`][docs-ranger] — range reconciliation, `Fingerprint` XOR, `process_message`, `SyncConfig` defaults
- [`iroh-docs/src/net.rs`][docs-net] · [`iroh-docs/src/net/codec.rs`][docs-codec] — ALPN, framing, `Init`/`Sync`/`Abort`, Alice/Bob loops
- [`iroh-docs/src/actor.rs`][docs-actor] — the `"sync-actor"` thread, `SyncHandle`, `Action`/`ReplicaAction` set
- [`iroh-docs/src/store/fs.rs`][docs-store-fs] · [`iroh-docs/src/store/fs/tables.rs`][docs-tables] — redb store, transaction batching, schema
- [`iroh-docs/src/engine.rs`][docs-engine] · [`engine/live.rs`][docs-live] · [`engine/state.rs`][docs-state] — Engine, LiveActor, gossip/blobs handoff, `PeerState`
- [`iroh-docs/src/heads.rs`][docs-heads] · [`iroh-docs/src/keys.rs`][docs-keys] · [`iroh-docs/src/ticket.rs`][docs-ticket] — `AuthorHeads`, id/secret types, `DocTicket`
- [`iroh-docs/src/api.rs`][docs-api] · [`api/protocol.rs`][docs-api-proto] · [`irpc/src/lib.rs`][irpc-lib] — the irpc client seam
- [Meyer, _Range-Based Set Reconciliation_][meyer] (arXiv:2212.13567) · [Willow protocol][willow] · [redb][redb] · [postcard][postcard]
- Related pages: [Blobs][blobs] · [bao-tree][bao-tree] · [Gossip][gossip] · [Wire Formats & Serialization][wire] · [Identity & Cryptography][identity-crypto] · [QUIC Transport (noq)][quic-transport] · [Endpoint & Protocol Router][endpoint] · [Tokio Concurrency Inventory][concurrency] · [D Architecture Migration][d-migration] · [Concepts][concepts] · [survey umbrella][index]

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[identity-crypto]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[quic-transport]: ./quic-transport.md
[endpoint]: ./endpoint.md
[blobs]: ./blobs.md
[bao-tree]: ./bao-tree.md
[gossip]: ./gossip.md
[concurrency]: ./concurrency.md
[d-migration]: ./d-architecture-migration.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[irpc]: https://docs.rs/irpc/0.17.0/irpc/
[docs-repo]: https://github.com/n0-computer/iroh-docs
[docs-docs]: https://docs.rs/iroh-docs/0.101.0/iroh_docs/
[docs-lib]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/lib.rs
[docs-sync-rs]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/sync.rs
[docs-ranger]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/ranger.rs
[docs-net]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/net.rs
[docs-codec]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/net/codec.rs
[docs-actor]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/actor.rs
[docs-engine]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/engine.rs
[docs-live]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/engine/live.rs
[docs-state]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/engine/state.rs
[docs-store-fs]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/store/fs.rs
[docs-tables]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/store/fs/tables.rs
[docs-heads]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/heads.rs
[docs-keys]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/keys.rs
[docs-ticket]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/ticket.rs
[docs-api]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/api.rs
[docs-api-proto]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/api/protocol.rs
[irpc-lib]: https://github.com/n0-computer/irpc/blob/0ed2b235d5c797b54d8263ecb3b0247272d055f9/src/lib.rs
[iroh-repo]: https://github.com/n0-computer/iroh/tree/22cac742ca5e84da4542681e14b2d23b74c8330e
[meyer]: https://arxiv.org/abs/2212.13567
[willow]: https://willowprotocol.org/
[redb]: https://docs.rs/redb/latest/redb/
[postcard]: https://docs.rs/postcard/latest/postcard/
