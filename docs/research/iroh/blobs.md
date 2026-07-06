# Blobs: Content-Addressed Transfer

iroh's bulk-data plane: a request/response protocol that moves BLAKE3-addressed content over QUIC as _verified streams_ — every 16 KiB is checked against the tree hash before it is surfaced — backed by a crash-consistent on-disk store, a resumable multi-provider downloader, and a per-`ALPN` connection pool. This is the protocol a D port must reproduce byte-for-byte to interoperate with n0's network.

| Field               | Value                                                                                                                                                                                                                                                                     |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crate(s)            | `iroh-blobs` — modules `protocol`, `protocol::range_spec`, `get` (the `fsm`), `provider`, `hashseq`, `format::collection`, `store::fs`, `api::{remote, downloader, blobs}` — plus `iroh-util::connection_pool`, `irpc`, and [`bao-tree`][bao-tree] for the hash-tree math |
| Version             | `iroh-blobs` **v0.103.0** (git `e82cbdcb`); `bao-tree` **v0.16.0**; `iroh-util` **v0.6.0** (`connection_pool`, crates.io-only); `irpc` **v0.17.0**; over `iroh` **v1.0.1** (`22cac742ca`) / `noq` tag `noq-v1.0.1`                                                        |
| Repository          | [`n0-computer/iroh-blobs`][repo] · [`iroh-util`][util-repo] · [`irpc`][irpc-repo] · [`bao-tree`][bt-repo]                                                                                                                                                                 |
| Documentation       | [docs.rs/iroh-blobs][docs] · [docs.rs/irpc][irpc-docs] · [docs.rs/bao-tree][bt-docs]                                                                                                                                                                                      |
| ALPN(s)             | `/iroh-bytes/4` (`b"/iroh-bytes/4"`) — the transfer protocol; unchanged across the 0.x→1.0 rename ([`protocol.rs:406`][bp-alpn])                                                                                                                                          |
| Approx. size (LoC)  | ≈14k across `iroh-blobs` (`protocol.rs` 1072, `range_spec.rs` 712, `get.rs` 992, `provider.rs` 708 + `events.rs` 716, `store/fs.rs` 2312 + `meta.rs` 976 + `bao_file.rs` 749 + …); plus `bao-tree` ≈5k, `irpc` ≈2.7k, `iroh-util` ≈1k                                     |
| Category            | Protocols                                                                                                                                                                                                                                                                 |
| Upstream spec/draft | No IETF draft; content addressing is [BLAKE3][blake3] verified streaming ("n0-flavoured bao", 16 KiB chunk groups). Rides QUIC [RFC 9000][rfc9000] via [`noq`][quic-transport]                                                                                            |

> [!NOTE]
> iroh 1.0 is a major restructure of the 0.x API and this crate rides on top of it: `NodeId` → `EndpointId`, `NodeAddr` → `EndpointAddr` (vocabulary in [Concepts][concepts]). Within blobs specifically, the 0.x `Store`/`Map` trait hierarchy is **gone** — a store is now "whatever handles the `Command` enum" over [`irpc`][concurrency]; the 0.x `downloader` with dial queues, retry backoff and request dedup is **gone**, replaced by a ~550-line orchestrator that pushed those concerns onto consumers; and `Collection` is no longer a protocol concept, just a [`HashSeq`](#hashseq-collections-and-the-hash-newtype) convention. `Collection`/`NodeAddr`-era folklore does not compile. The bao-tree _math_ — `TreeNode` addressing, outboard layout, the verified-decode stack machine — is described in [`bao-tree`][bao-tree]; this page covers the protocol, store, downloader and RPC seam that sit on top of it. This page is part of the [iroh survey][index].

---

## Overview

### What it solves

Given a 32-byte BLAKE3 [`Hash`](#hashseq-collections-and-the-hash-newtype), fetch the corresponding bytes from any peer that has them, verifying integrity incrementally so a lying or corrupt provider is caught within one 16 KiB chunk group — and do it _resumably_ (pick up where a previous partial download left off) and _from multiple providers_ (ask the next peer only for the ranges the previous one did not deliver). That is the whole job. The building blocks are:

1. **A request/response wire protocol** (`ALPN = /iroh-bytes/4`) over iroh QUIC connections: one bidirectional stream per request. A [`GetRequest`](#request-types-and-the-chunkrangesseq-encoding) names a root hash plus a run-length-encoded set of chunk ranges per blob; the response is the size header followed by the BLAKE3 [`bao-tree`][bao-tree] slice for exactly those ranges.
2. **A content-addressed store** that persists two artifacts per hash — the data and an _outboard_ (the interior BLAKE3 tree hashes) — with an inline-small-blobs optimization, a partial/complete entry state machine, and a crash-consistency discipline built around _never_ claiming to have data it cannot verify.
3. **A resumable multi-provider [`Downloader`](#the-downloader-and-connectionpool)** that splits a hash-sequence download into per-child requests, runs them with bounded parallelism, and re-plans each attempt against local state; underneath it, a generic **[`ConnectionPool`](#the-connectionpool)** caches and idle-evicts one QUIC connection per remote per `ALPN`.
4. **An [`irpc`][concurrency] actor/RPC seam** that unifies the in-process store API and the (optional) cross-process store RPC behind one request enum and typed channels.

### Design philosophy

Correctness dominates. The protocol module's opening doc comment ([`protocol.rs:10`][bp-integrity]):

> _"Data integrity is considered more important than performance. Data will be validated both on the provider and getter side. A well behaved provider will never send invalid data."_

The store's `DESIGN.md` restates the same principle as an availability invariant that governs the entire crash story ([`DESIGN.md:124`][design-crash]):

> _"Losing a bit of data that has been written immediately before the crash is tolerable. But we don't ever want to have a situation after a crash where we think we have some data, but actually we are missing something about the data or the outboard that is needed to verify the data."_

Three consequences shape everything below:

1. **There is exactly one correct answer per request, and the requester verifies it.** Because the response geometry is fully determined by `(hash, size, ranges)`, "there is exactly one sequence of bytes that is the correct answer. And the requester will notice if data is incorrect after at most 16 KiB of data" ([`DESIGN.md:5`][design-integrity]). No delimiters, no per-blob framing metadata, no hashes in the response — the tree is self-describing.
2. **Downloads must not touch the metadata database.** "An individual database update is very fast, but syncing the update to disk is extremely slow no matter how small the update is. So the secret to fast download speeds is to not touch the metadata database at all if possible" ([`DESIGN.md:61`][design-meta]). Syncing after each 16 KiB group would cap throughput at 3.2 MB/s ([`DESIGN.md:134`][design-fsync]); the store therefore batches metadata writes and persists per-hash bitfields only on clean shutdown, reconstructing them by re-hashing after a crash.
3. **Chunk possession is monotone, so concurrent downloads commute.** "A chunk of a blob can only go from not present (all zeroes) to present … And this means that all changes due to syncing from a remote source commute, which makes dealing with concurrent downloads from multiple sources much easier" ([`DESIGN.md:112`][design-commute]). This is what makes the resumable multi-provider downloader sound.

The crate is explicit that this generation is not yet hardened: "this version of iroh-blobs is not yet considered production quality. For now, if you need production quality, use iroh-blobs 0.35" ([`README.md:3`][bp-readme]).

---

## How it works

### The transfer, end to end

A getter holds an open QUIC [`Connection`][endpoint] to a provider that speaks `/iroh-bytes/4`. For each request it opens a **fresh bidirectional stream** ([`get.rs:239`][get-openbi]), postcard-serializes a [`Request`](#request-types-and-the-chunkrangesseq-encoding), writes it, and FINs the send half. The provider runs an `accept_bi` loop and spawns one task per accepted stream ([`provider.rs:305`][pv-accept]). Multiplexing many requests is free — you just open more streams: "Multiple requests just create multiple streams on the same connection, which is very cheap in QUIC" ([`protocol.rs:367`][bp-streams]).

For a `Get`, the provider replies, per requested blob and in request order, with an **8-byte little-endian `u64` claimed size** followed by the [`bao-tree`][bao-tree] verified slice for the requested ranges: a pre-order interleave of **64-byte parent nodes** (left CV ‖ right CV) and **leaf chunk-group payloads** (≤ 16 KiB) ([`api/blobs.rs:1133`][ab-write] write side; [`get.rs:520`][get-header] size read). The getter decodes with bao-tree's `ResponseDecoder`, which reconstructs the _same_ traversal from `(size, ranges)` and validates every parent and leaf against a hash stack seeded with the root ([`bao-tree/io/fsm.rs:317`][bt-decoder]). Blob boundaries need no delimiter — geometry is fully determined by the size header plus the request.

Missing data is signalled by an **early FIN**, not an error code: the getter maps `UnexpectedEof` at the size header to `NotFound` and mid-blob to `ChunkNotFound`/`ParentNotFound`/`LeafNotFound` purely by stream position ([`get.rs:495`][get-notfound]). Actual RESET codes are reserved for `ERR_PERMISSION`(1) / `ERR_LIMIT`(2) / `ERR_INTERNAL`(3) ([`protocol.rs:398`][bp-errcodes]).

### Request types and the `ChunkRangesSeq` encoding

The `Request` enum reserves stable postcard tags so `Push` and `GetMany` sit at 8 and 9 ([`protocol.rs:408`][bp-request]):

```rust
// iroh-blobs/src/protocol.rs:408 (tags: Get=0, Observe=1, Push=8, GetMany=9)
pub enum Request {
    Get(GetRequest),
    Observe(ObserveRequest),
    Slot2, Slot3, Slot4, Slot5, Slot6, Slot7,   // reserved; decode as InvalidData
    Push(PushRequest),
    GetMany(GetManyRequest),
}

pub struct GetRequest {
    pub hash: Hash,             // blake3 root
    pub ranges: ChunkRangesSeq, // element 0 = root; element n>0 = child n-1 of the HashSeq
}
```

A `GetRequest` addresses a _tree of blobs_: element 0 is the root blob; element `n>0` addresses child `n-1` of the root interpreted as a [`HashSeq`](#hashseq-collections-and-the-hash-newtype). A trailing non-empty element **repeats forever**, which is how "give me the hash sequence and all of its children" is expressed without knowing the child count ([`range_spec.rs:165`][rs-inf]). The sibling request types: `GetManyRequest { hashes: Vec<Hash>, ranges }` is "identical to a `GetRequest` for a `HashSeq`, but the `HashSeq` is provided by the requester" as an explicit hash list ([`protocol.rs:579`][bp-getmany]); `PushRequest(GetRequest)` inverts direction (the getter _sends_ bao data after the request — disabled by default, see below); `ObserveRequest { hash, ranges }` subscribes to the provider's local bitfield for a hash ([`protocol.rs:616`][bp-observe]).

The wire encoding of the range set is the protocol's one genuinely clever piece ([`protocol.rs:293`][bp-rangeseq]):

> _"In the wire encoding of `ChunkRangesSeq`, `ChunkRanges` are encoded alternating intervals of selected and non-selected chunks. This results in smaller numbers that will result in fewer bytes on the wire when using the postcard encoding format that uses variable length integers."_

Concretely, a `RangeSpec` is a `SmallVec<[u64; 2]>` of alternating span widths, starting _deselected_ at chunk 0; an odd element count means an open-ended selected tail ([`range_spec.rs:341`][rs-spec]). A `ChunkRangesSeq` is a `SmallVec` of `(offset-delta, RangeSpec)` tuples where deltas are between the _absolute indices at which the value changes_ ([`range_spec.rs:470`][rs-wire]). All ranges are in units of 1024-byte BLAKE3 chunks. From the crate's own hexdump tests ([`range_spec.rs:553`][rs-tests]):

```text
RangeSpec examples (span widths, alternating deselect/select from chunk 0):
    empty            00
    all (0..)        01 00        # one span of width 0 ⇒ selected from chunk 0
    chunks 64..      01 40
    chunks ..64      02 00 40     # deselect 0, select 64
    {1..3} ∪ {9..13} 04 01 02 06 04

Full GetRequest wire messages (tag ‖ 32-byte hash ‖ ChunkRangesSeq):
    GetRequest::all(hash)   00 <hash*32> 01 00 01 00        # root + all children, forever
    GetRequest::blob(hash)  00 <hash*32> 02 00 01 00 01 00  # (Δ0, all)(Δ1, empty) ⇒ root only
```

### Hashseq, collections, and the `Hash` newtype

`Hash` is a `#[repr(transparent)]`-style newtype over `blake3::Hash` ([`hash.rs:14`][hash-newtype]); on the wire it is **32 raw bytes, no length prefix** (postcard `MaxSize = 32`). Its `Display` is 64-char lowercase hex, `FromStr` also accepts 52-char base32-nopad, and `fmt_short()` prints the first 5 bytes ([`hash.rs:151`][hash-parse]). The empty blob is a hard special case everywhere: `Hash::EMPTY` is the compile-time constant BLAKE3 hash of `b""` (`af1349b9…3262`), never stored, always "present", and the only hash for which a `size == 0` response is legal ([`hash.rs:25`][hash-empty]).

A **`HashSeq`** is just a blob whose bytes are a raw concatenation of 32-byte hashes — `len % 32 == 0`, `get(i) = bytes[i*32 .. (i+1)*32]`, no header ([`hashseq.rs:54`][hashseq]). This is the only structural type the protocol knows beyond a raw blob; `BlobFormat` is `Raw | HashSeq`. A **`Collection`** is a _convention_ layered on top (not visible to the protocol): a `HashSeq` whose link 0 is the hash of a metadata blob `postcard(CollectionMeta { header: [u8;13] = b"CollectionV0.", names: Vec<String> })`, where `names[i]` labels `link[i+1]` ([`format/collection.rs:82`][collection]). Fetching a collection therefore reads child 0 (the metadata) before the payload children.

Because the response never transmits hashes, **the getter must already know or derive every blob hash**: the root is known from the request, children are learned by decoding the `HashSeq` blob mid-transfer. The low-level FSM makes this a _caller_ obligation — `AtStartChild::next(hash)` takes the child hash as an argument ([`get.rs:418`][get-startchild]).

### The provider pipeline

`BlobsProtocol` implements iroh's `ProtocolHandler`; `accept` delegates to `handle_connection` ([`net_protocol.rs:86`][np]). Per connection: an interceptable `ClientConnected` event can reject the connection outright (`conn.close(code, reason)` with `b"limit"`/`b"permission"`/`b"internal"`, [`provider.rs:294`][pv-reject]); then the accept loop spawns `handle_stream` per request stream. Per stream: `read_request` → a per-request-type **event gate** → `into_writer` asserts the request stream is at EOF (extra bytes ⇒ `InvalidData`) → serve.

`handle_get_impl` walks the requested ranges: offset 0 streams the root; offsets `>0` index into the `HashSeq`, which is **loaded fully into memory and assumed complete** (an explicit `todo`), and walking past the end of the sequence just stops the loop — not an error ([`provider.rs:429`][pv-getimpl]). Push is the mirror (`import_bao_reader` per non-empty range set) and is **disabled by default** via `EventMask::DEFAULT { push: RequestMode::Disabled }` ⇒ `ERR_PERMISSION` — the constants deliberately offer no "all-enabled" mask to avoid store-write misuse ([`provider/events.rs:189`][pe-pushdefault]). Observe streams length-prefixed `ObserveItem`s (full bitfield first, then diffs) until the remote STOPs the stream, driven by a `select!` on bitfield updates vs `writer.inner.stopped()` ([`provider.rs:627`][pv-observe]).

All provider observability flows through an `EventSender` (an `irpc::Client` over a tokio mpsc) configured by a static `EventMask` with per-request-type modes (`None | Notify | Intercept | NotifyLog | InterceptLog | Disabled`, [`provider/events.rs:167`][pe-mask]). In `Intercept*` modes the provider awaits a oneshot verdict before serving. **Throttling, when enabled, is a blocking RPC round-trip per payload write** — i.e. once per ≤16 KiB chunk group: `transfer_progress` awaits a `Throttle { connection_id, request_id, size }` reply ([`provider/events.rs:282`][pe-throttle]). Elegant, but a latency multiplier on the hot path.

### The store, on disk

The `fs` store's root directory holds `blobs.db` (a [redb][redb] database) plus `data/` and `temp/` (temp must be on the same device for atomic renames). Per hash, in `data/`, hex-lowercase: `<hash>.data` (raw bytes), `<hash>.obao4` (pre-order outboard, block size 4, **no size prefix**), `<hash>.sizes4` (a `u64`-per-chunk-group size log), and `<hash>.bitfield` (possession + best-known size). The redb schema is four tables ([`meta/tables.rs:7`][tables]):

| Table               | Key           | Value                                 |
| ------------------- | ------------- | ------------------------------------- |
| `blobs-0`           | `Hash` (32 B) | `EntryState` (postcard)               |
| `tags-0`            | `Tag` (bytes) | `HashAndFormat`                       |
| `inline-data-0`     | `Hash`        | `&[u8]` — complete blob bytes         |
| `inline-outboard-0` | `Hash`        | `&[u8]` — complete pre-order outboard |

An `EntryState` is `Complete { data_location, outboard_location } | Partial { size: Option<u64> }` ([`entry_state.rs:161`][entrystate]); `DataLocation` is `Inline | Owned(size) | External(Vec<PathBuf>, size)`. Inline thresholds default to **16 KiB for both data and outboard** ([`options.rs:71`][opts-inline]) — with those defaults, inline data implies no outboard is needed, and any needed outboard implies the data is on disk. `DESIGN.md`'s statement of the store's job ([`DESIGN.md:11`][design-job]):

> _"The job of a blob store is to store two pieces of data per hash, the actual data itself and an `outboard` containing the BLAKE3 hash tree that connects each chunk of data to the root. Data and outboard are kept separate so that the data can be used as-is."_

The per-hash in-memory state is a `BaoFileStorage` with states `Initial, Loading, NonExisting, PartialMem, Partial, Complete, Poisoned` ([`bao_file.rs:299`][baofile]). Fresh partial entries start as `PartialMem` (sparse memory buffers); when a write batch's max offset exceeds the inline threshold the state is persisted to `PartialFileStorage` (the three files, created _before_ the batch to avoid a large allocation on a write near the end of a huge file). When the bitfield reports the entry complete, storage converts to `CompleteStorage` (applying inline rules) and the db entry flips to `Complete`, queuing deletion of the now-redundant `.sizes4` and `.bitfield` files.

**The metadata database is written in batches.** The db actor pulls one command, opens a read _or_ write redb transaction, then keeps draining _compatible_ commands into it (via a peekable receiver) until a batch limit (10000 reads / 1000 writes), a 1-second timer, or an incompatible command ([`meta.rs:785`][meta-batch]). File deletions collected during a write transaction execute only _after_ the metadata commits (the "file transaction"), and `ProtectHandle::protect` removes pending deletions for files a concurrent task just (re)created. This is the crash-consistency spine: **metadata commits first, file deletion second, file creation protected against racing deletes** ([`delete_set.rs:113`][deleteset]).

**The bitfield is a dirty flag.** The `.bitfield` file (`blake3(payload) ‖ postcard(Bitfield)`) is written only on clean entity shutdown, after the data/outboard/sizes files are fsynced; on load it is read and immediately truncated to zero + fsync, so its mere validity is a "clean shutdown" marker ([`store/util.rs:218`][su-checksum]). A crash leaves it empty, and the bitfield is _reconstructed_ by re-hashing the data against the outboard. This is the concrete realization of design principle #2 — the store never fsyncs per chunk, so on the unhappy path it pays a full re-validation instead of ever trusting unverified data.

**GC is mark-and-sweep** over a "protected" set ([`gc.rs:34`][gc]): mark = all tag targets ∪ all temp tags ∪ (for every non-raw root) the hashes enumerated by streaming the blob as a `HashSeq`; sweep = list all blobs and delete the non-live ones in batches of 100. There is no per-blob refcount — protection is `tags ∪ temp-tags ∪ hashseq-closure ∪ recently-touched` (every db update since the last GC re-inserts its hash into `protected`, shielding entries written mid-GC). `TempTag` holds a `Weak<dyn TagDrop>`; dropping it notifies the store, `leak()` makes it permanent for the process.

### The store protocol is `irpc`, not a trait

Every store implementation (fs, mem, readonly-mem) is an actor handling one `Command` enum, generated by irpc's `#[rpc_requests]` macro from a `Request` enum whose variants declare their channel shapes ([`api/proto.rs:90`][proto]):

```rust
// iroh-blobs/src/api/proto.rs:90 (excerpt) — the whole store protocol
#[rpc_requests(message = Command, alias = "Msg", rpc_feature = "rpc")]
pub enum Request {
    #[rpc(rx = mpsc::Receiver<BaoContentItem>, tx = oneshot::Sender<Result<()>>)] ImportBao(..),
    #[rpc(tx = mpsc::Sender<EncodedItem>)]                                        ExportBao(..),
    #[rpc(tx = mpsc::Sender<Bitfield>)]                                           Observe(..),
    #[rpc(tx = mpsc::Sender<AddProgressItem>)]                                    ImportBytes(..),
    // … 23 variants total: ListBlobs, Batch, DeleteBlobs, tags, SyncDb, Shutdown …
}
```

The public `Store` is a `#[repr(transparent)]` wrapper over `irpc::Client<proto::Request>` ([`api.rs:211`][api-store]). In-process this is a plain tokio channel send; with the `rpc` feature the same enum is served remotely over a localhost noq socket via `irpc::rpc::listen` / `Store::connect` ([`api.rs:250`][api-connect]). So the "RPC layer" is irpc: **commands are postcard-serializable messages paired with typed channels; the local path never serializes.** irpc's own stated goal ([`irpc/lib.rs:5`][irpc-goal]):

> _"The main goal of this library is to provide an rpc framework that is so lightweight that it can be also used for async boundaries within a single process without any overhead, instead of the usual practice of a mpsc channel with a giant message enum where each enum case contains mpsc or oneshot backchannels."_

### The `Downloader` and `ConnectionPool`

`Downloader::new(store, endpoint)` spawns a detached actor and hands back an `irpc::Client<SwarmProtocol>` with two messages: `Download(DownloadRequest)` (server-streaming `DownloadProgressItem`s) and `WaitIdle` ([`api/downloader.rs:40`][dl-proto]). A `DownloadRequest` carries the request, an `Arc<dyn ContentDiscovery>` provider source, and a `SplitStrategy` — and it deliberately serializes to an error, making the call local-process-only by construction. `Store::downloader()` warns it "has internal state, so don't create it ad hoc but store it somewhere" ([`api.rs:241`][api-downloader]).

The provider loop is strictly sequential and resumable ([`api/downloader.rs:484`][dl-execget]):

> _"It will try each provider in order until it finds one that can fulfill the request. When trying a new provider, it takes the progress from the previous providers into account, so e.g. if the first provider had the first 10% of the data, it will only ask the next provider for the remaining 90%. This is fully sequential, so there will only be one request in flight at a time. … If the provider stream never ends, it will try indefinitely."_

Per provider: emit `TryProvider` → `pool.get_or_connect(provider)` (lazy) → `remote.local_for_request(request)` computes a `LocalInfo` from store bitfields → if already complete, done → await the connection (failure ⇒ `ProviderFailed`, next) → `execute_get_sink(conn, local.missing(), …)` resumes from local state, shifting byte offsets by the pre-existing local bytes. There is **no retry, no backoff, no provider scoring, no dedup** in the downloader — the only built-in policy is `Shuffled` (randomize order); dedup and retry live in consumers such as iroh-docs' [`LiveActor`][docs-sync] (`queued_hashes` / `missing_hashes`). The `Split` path first fully fetches the root `HashSeq` blob sequentially, then fans out one `GetRequest` per child offset with **at most 32 parts in flight** (`buffered_unordered(32)`); a failed part emits one `DownloadError` progress item but does **not** cancel its siblings ([`api/downloader.rs:150`][dl-strategy]).

Underneath sits a generic per-`(Endpoint, ALPN, Options)` **`ConnectionPool`** from the crates.io-only `iroh-util` crate ([`connection_pool.rs:1`][cp-doc]):

> _"You create a connection pool for a specific ALPN and `Options`. Then the pool will manage connections for you. … It is important that you keep the `ConnectionRef` alive while you are using the connection."_

Its `Options` are three numbers and a hook: `idle_timeout` (default **5 s**), `connect_timeout` (default **1 s**, explicitly _including_ time in the `on_connected` callback), `max_connections` (default **1024**), and an optional `on_connected` async callback (e.g. "hold this connection back until its path is direct") ([`connection_pool.rs:42`][cp-options]). The design is two-level actors: a main actor owns a `HashMap<EndpointId, mpsc::Sender>` of per-remote **connection actors** plus an idle LRU; each connection actor dials once, arms a `conn.closed()` watcher, and serves handed-out `ConnectionRef`s tracked by an atomic refcount. When the refcount hits zero it notifies the pool and arms a `sleep(idle_timeout)`; a fresh request clears the timer and reuses the connection (observable via `Connection::stable_id()`). A failed dial is **cached and re-served (cloned) to every queued waiter** until the pool unlists it (`PoolConnectError: Clone`, sources `Arc`-wrapped for exactly this). At `max_connections` the main actor evicts the oldest idle connection or answers `TooManyConnections`. Two quirks a port must note: the main actor **can never terminate** (its shared `Context` holds a clone of its own inbox sender, so `recv()` never sees all-senders-dropped, and there is no shutdown message), and there is **no request-level timeout** beyond the 1-second connect budget — a stalled established transfer is bounded only by QUIC idle mechanisms.

---

## Analysis

### Wire format & framing

Two wire surfaces, both postcard-over-QUIC, both length-delimited by the stream or an explicit varint — never by an in-band frame header.

**The blobs transfer protocol** (`/iroh-bytes/4`), one request per bidi stream:

| Request   | Layout                                                            | Terminator                           |
| --------- | ----------------------------------------------------------------- | ------------------------------------ |
| `Get`     | `0x00` ‖ hash(32) ‖ `ChunkRangesSeq`                              | stream FIN (client drops the writer) |
| `Observe` | `0x01` ‖ hash(32) ‖ `RangeSpec`                                   | explicit `finish()`                  |
| `Push`    | `0x08` ‖ varint(len) ‖ `postcard(GetRequest)` ‖ bao push payload… | payload then FIN                     |
| `GetMany` | `0x09` ‖ seq(hashes) ‖ `ChunkRangesSeq`                           | stream FIN                           |

`Get`/`GetMany`/`Observe` read the tag byte then read-to-EOF (bounded by `MAX_MESSAGE_SIZE` = `1024 * 1024` = **1 MiB**, despite a stale "100MiB" comment); `Push` is varint-length-prefixed because the same stream then carries payload ([`protocol.rs:395`][bp-maxsize], [`protocol.rs:448`][bp-read]). The **response** for `Get`/`GetMany`, per non-empty blob in request order:

```text
u64 size            (8 bytes, little-endian, *claimed*, verified progressively)
then bao items, pre-order over BaoTree::new(size, IROH_BLOCK_SIZE = BlockSize(4) = 16 KiB):
    parent:  64 bytes = left_child_CV(32) ‖ right_child_CV(32)
    leaf:    chunk-group payload, ≤ 16384 bytes (last group may be short)
```

The `Observe` response is repeated `varint(len) ‖ postcard(ObserveItem { size, ranges })` frames (full bitfield, then non-empty diffs). All multi-byte integers are postcard LEB128 varints (7 value bits/byte, MSB = continuation) — the crate ships its own 20-line varint reader ([`util/stream.rs:401`][stream-varint]), which a D port can lift verbatim. Note two subtleties flagged in recon: the same `Bitfield` data is encoded _two different ways_ (the store's custom flat `[size, boundaries…]` seq vs the wire `ObserveItem`'s derived struct), and `ObserveRequest.ranges` is transmitted but **ignored** by the provider (it streams all diffs regardless).

**The store/downloader RPC** ([`irpc`][concurrency]) uses a second, simpler framing — `varint_u64(len) ‖ postcard(payload)` per message, one request per QUIC bidi stream, **no request IDs and no frame headers** (multiplexing is entirely QUIC's) — with a 16 MiB message cap and error codes `1` (max-size-exceeded) / `2` (invalid-postcard) ([`irpc/lib.rs:50`][irpc-framing]). It is only reachable behind the optional `rpc` feature and dials TLS server name `"localhost"` — it is a _cross-process-on-one-host_ control plane, not part of the p2p wire. A port can defer it entirely and lose no interop.

On-disk formats (see [store, on disk](#the-store-on-disk)) are also postcard: `EntryState`, the `.bitfield` payload, and `CollectionMeta`. Because these are content-addressed and interop-relevant only for reusing an existing store directory, a port that starts from an empty store is free to choose its own on-disk layout — but adopting the `.data`/`.obao4`/`.sizes4`/`.bitfield` scheme byte-for-byte buys drop-in compatibility with n0 tooling. The tree math and the exact outboard byte layout are [`bao-tree`][bao-tree]'s remit.

### Cryptography & identity

Blobs owns **no key material and no handshake** — peer identity, TLS 1.3, and the `EndpointId` all belong to [`endpoint`][endpoint] / [`identity-crypto`][identity]. What lives here is _content_ cryptography: BLAKE3. Every byte the getter surfaces has been checked against a hash chained to the requested root, so a provider cannot substitute or corrupt data without detection within one 16 KiB group; the provider likewise validates on its side. The security-relevant details — chunk chaining values, the `set_input_offset` / `finalize_non_root` hazmat API, root vs non-root domain separation, the parent-CV merge — are the crypto core of [`bao-tree`][bao-tree] and are covered there; a D port needs a BLAKE3 implementation exposing those internals, not just the one-shot hash.

Two identity-adjacent items are in scope. **`BlobTicket`** (`{EndpointAddr, BlobFormat, Hash}`) is the shareable "here is a blob and where to get it" token: its string form is the literal `"blob"` followed by lowercase base32-nopad of a postcard single-variant enum that preserves the legacy 0.x `NodeAddr` shape (endpoint id ‖ optional relay URL ‖ direct socket addrs ‖ format ‖ hash) ([`ticket.rs:39`][ticket]) — the same `Ticket` codec described in [`wire-serialization`][wire]. And the **size-honesty check**: a validated leaf that contains the final chunk must end exactly at the claimed size, so a remote cannot inflate work with a fake size claim ([`fs.rs:1140`][fs-importbao]) — a small but load-bearing integrity guard the D port must replicate.

### State machines & lifecycle

The subject is unusually FSM-dense; the port should treat each as a checklist.

- **Get client typestate FSM** ([`get.rs` mod `fsm`][get-fsm], diagram `get_machine.drawio.svg`): `AtInitial → AtConnected → {AtStartRoot | AtStartChild | AtClosing} → AtBlobHeader → AtBlobContent →* AtEndBlob → {AtStartChild | AtClosing} → Stats`. It is an explicit _move-only_ typestate machine so a low-level API can be driven without async traits; a `Box<Misc>` (start time, counters, owned ranges iterator) is threaded through every state "so we don't have to memcpy it on every state transition" ([`get.rs:369`][get-misc]). `start_get_many` bypasses `AtInitial`/`AtConnected` and enters at `AtStartChild` (where the offset indexes `hashes` directly, no `-1`).
- **Verified-decode stack machine** (in [`bao-tree`][bao-tree]): state is `(response-iterator position, hash stack)`; a Parent pops+verifies+pushes children (right then left, gated by range flags), a Leaf pops+verifies; errors are positional (`ParentHashMismatch(node)`, `LeafHashMismatch(chunk)`).
- **Provider** — per connection: `client_connected` gate → `accept_bi` loop → spawn `handle_stream` per stream → `connection_closed` on loop exit. Per stream: `read_request` → per-type event gate → serve → `sync()` → `transfer_completed`, or on error `reset(code)` + `transfer_aborted`. **Per-request failure RESETs only the stream, never the connection** ([`provider.rs:372`][pv-dispatch]) — a stale doc paragraph claiming otherwise contradicts the code.
- **Store `BaoFileStorage`** (`Initial → Loading → {Complete | Partial | NonExisting} …`, with `PartialMem → Partial → Complete` on writes and any I/O error → `Poisoned`) and **`EntryState`** (`∅ → Partial{None} → Partial{Some(size)} → Complete`, merged with a commutative union so concurrent updates commute — the on-disk face of design principle #3).
- **Connection pool** — per connection: `Connecting → {Ready | Failed}`; `Ready ⇄ {InUse, Idle}`; `Idle → Draining` on the idle timer; `Draining → closed` (`conn.close(0, b"idle"/b"drop")`). Per pool entry: `Absent → Active → IdleListed → Evicted`.
- **irpc `NoqSender`** — `Open ⇄ Closed` with _take-poisoning_: a dropped in-flight `send` future poisons the sender (and all clones), guaranteeing a frame is on the wire completely or not at all. This is a workaround for silent Rust cancellation; event-horizon's terminal-CQE cancellation makes it unnecessary (see below).

Cleanup discipline matters: dropping a noq `SendStream` FINishes it gracefully (the get client depends on this — `drop(writer)` _is_ the end-of-request marker); the store persists the partial bitfield on entity shutdown; the pool closes connections in the connection actor's drain path.

### Dependencies & coupling

| Crate                       | Depth                                  | Port implication                                                                                                                                           |
| --------------------------- | -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`bao-tree`][bao-tree] 0.16 | **load-bearing algorithm**             | `ResponseDecoder`, `BaoTree`, outboard layout, chunk math — every response byte. Full reimplementation (its own dossier).                                  |
| `blake3` (hazmat)           | **load-bearing**                       | Chunk-counter CVs, `set_input_offset`, root/non-root finalize, parent merge. The crypto core.                                                              |
| `postcard` 1.1              | **load-bearing wire codec**            | Enum tags, LEB128 varints, seq length prefixes, fixed byte arrays, options. A D port needs a postcard subset.                                              |
| `range_collections` 0.4.6   | load-bearing (small)                   | `RangeSet2<ChunkNum>` sorted-boundary sets with union/intersection/difference/superset + serde-as-boundary-seq. ~200 lines.                                |
| `redb` 4.1                  | infrastructure                         | Embedded ACID B-tree KV (4 tables, point get/insert/remove, ordered scan, snapshot iteration). D: LMDB via ImportC, SQLite, or a purpose-built table file. |
| `irpc` 0.17                 | infrastructure (local) / wire (remote) | Locally = typed channels; replace with direct capability calls. Remote store RPC is optional.                                                              |
| `iroh-util` 0.6 (pool)      | load-bearing                           | The entire `ConnectionPool`; no other in-tree connection cache. Must be reimplemented (~1k LoC).                                                           |
| `iroh` (endpoint, streams)  | API surface                            | Maps to the [`endpoint`][endpoint] and [`socket`][socket] ports.                                                                                           |
| `tokio` / `n0-future`       | runtime                                | mpsc/oneshot/watch/JoinSet/select/try_join → event-horizon (see below).                                                                                    |
| `genawaiter`, `self_cell`   | convenience                            | Generator/owning-iterator sugar; subsumed by fibers and index-based iterators.                                                                             |

The critical observation: the entire get/provider stack is **generic over two traits**, `SendStream` and `RecvStream` ([`util/stream.rs:14`][stream-traits]) — a `recv_bytes_exact` / `send_bytes` / `reset` / `stop` byte-stream abstraction. A D `isByteStream` capability slots in exactly where these generics sit, including the deterministic `SimNet` test double. This is the seam that makes the protocol portable without touching the transport.

### Concurrency & I/O model

The Rust code is aggressively actor-and-channel structured _because it targets a multi-threaded runtime_, and much of that structure is incidental complexity that a single-threaded proactor dissolves. The full inventory (with translation) lives in [`concurrency`][concurrency]; the shape:

- **Protocol/get/provider layer**: one detached task per accepted request stream; a `select!` for the observe race (bitfield update vs remote STOP); a `try_join!` that concurrently feeds the store's `import_bao` while reading from the network; genawaiter generators for progress item streams. **No `spawn_blocking`, no `Mutex`/`RwLock`, no timers** — all timing (idle, keep-alive) lives in the [noq transport][quic-transport].
- **Store**: a dedicated multi-threaded [tokio][tokio] runtime, a main actor + a db actor, and a per-hash _entity manager_ (≤1 entity actor per hash, pooled and recycled) whose only purpose is to serialize access across threads. The per-hash state cell is a `watch::Sender<BaoFileStorage>` that doubles as the `Observe` subscription. File I/O is **synchronous `std::fs` pread/pwrite done directly inside async tasks** — no `spawn_blocking` anywhere, long copies yield cooperatively ([store, on disk](#the-store-on-disk)).
- **Downloader/pool**: detached actors, `JoinSet` of downloads (reaping is load-bearing — a documented leak class if skipped), `buffered_unordered(32)` bounded parallelism, `AtomicUsize + Notify` refcounting, `MaybeFuture` armable idle timers.

The one **CPU cost that pins the loop thread**: outboard computation on import and bitfield reconstruction on crash recovery re-hash entire blobs, and `encode_ranges_validated` re-hashes on hot serving paths. Under tokio these yield per 16 KiB group; under a single-threaded loop they need explicit checkpoints or an optional worker.

### Mapping to event-horizon

The dominant finding: **most of the concurrency machinery is a tax on `Send + Sync` + work-stealing that [event-horizon][eh-spec]'s `single` topology refunds.** Per-hash serialization, the entity manager's pool/inbox/recycle apparatus, `Arc<Mutex<DeleteSet>>`, `AtomicUsize` refcounts, and the pool's owner-cycle "immortal actor" all exist to coordinate across threads. Under one loop per thread with fiber-affine tasks, they collapse to plain single-owner objects. Concretely, mapping [event-horizon vocabulary][async-io] onto the four subsystems:

**1. The get FSM becomes straight-line fiber code.** The move-only typestate machine exists to drive a low-level API without async traits or lifetimes; a Tier-B fiber with blocking-looking verbs needs none of it. The whole get flow is one function: open stream → send request → per blob { read 8-byte size; loop: decode parent/leaf }. Keep the state _names_ as documentation checkpoints; the "who supplies the child hash" obligation becomes a delegate or an inversion where the driver owns the `HashSeq`.

```rust
// iroh-blobs/src/get.rs (fsm) — the low-level typestate, abbreviated
let start = fsm::start(connection, request, Default::default());
let connected = start.next().await?;
let ConnectedNext::StartRoot(at_start) = connected.next().await? else { … };
let header = at_start.next();
let (mut content, size) = header.next().await?;         // AtBlobHeader → AtBlobContent
loop {
    match content.next().await {
        BlobContentNext::More((next, item)) => { /* item = Parent|Leaf, verified */ content = next; }
        BlobContentNext::Done(end_blob) => break end_blob,
    }
}
```

```d
// proposed / sketch — Tier-B fiber over an `isByteStream` capability
IoResult!Stats fetchBlob(Stream)(ref Stream s, in GetRequest req, ref Env env)
{
    s.sendAll(encodeRequest(req));      // parks on submit; ownership of Buf → kernel
    s.finish();                          // graceful FIN == end-of-request marker
    ubyte[8] hdr = s.recvExact!8();      // AtBlobHeader; EOF here ⇒ NotFound
    immutable size = littleEndianU64(hdr);
    auto dec = ResponseDecoder(req.hash, size, req.ranges);   // bao-tree stack machine
    while (auto item = dec.pull(s))      // Parent(64B) | Leaf(≤16 KiB); verified before return
        env.store.writeBatch(item);      // no try_join!: interleave in one fiber (below)
    return dec.stats;
}
```

**2. One fiber per request stream; connection = a `Scope` with error isolation.** iroh's provider deliberately does _not_ tear down the connection when one stream handler fails — the spawned task swallows the error and RESETs only that stream. Map to `spawnDaemon`/a child `Scope` per stream that converts failure into `reset(code)` + an event, **never** sibling cancellation. `Closed::ProviderTerminating` maps to scope-exit cleanup closing the connection. A cancelled get fiber must RESET/STOP its streams in an `onExit` hook.

**3. Request gating and throttling become a capability row.** The 6-mode `EventMask` runtime dispatch is a Design-by-Introspection fit: an `isBlobEventSink` capability with optional methods (`interceptRequest`, `throttle`, `onTransferProgress`) detected by presence monomorphizes the whole thing — `EventMask::DEFAULT` = absent methods = zero cost. The throttle-as-blocking-call per 16 KiB is a natural fiber checkpoint (and a cancellation point). The observe server loop is `race(storeObserveNext, sendStreamStopped)`; the observe client is a fiber yielding bitfields. Both hit the **missing cross-fiber channel** (open issue O20): the Rust code already exposes the sink-shaped internals (`fetch_sink`, `execute_get_sink` take an `impl Sink<u64>`, [`api/remote.rs:341`][rm-missing]), so the port should make progress a `Sink`-style capability parameter and treat the channel-flavored wrappers as optional.

**4. The store two-actor + entity-manager architecture collapses to one owner.** Under `single` topology the store is a plain object owning a `HashMap<Hash, handle>`; per-hash serialization comes for free from single-threaded ownership. Keep the _idea_ of a per-hash handle map with load-on-demand and idle eviction (a memory bound), drop the pool/inbox/recycle machinery. The `watch::Sender<BaoFileStorage>` — handle-as-observer-channel, the only structurally interesting tokio primitive here — has no direct equivalent; the natural design is a state struct plus an intrusive list of parked observer fibers, woken on every bitfield mutation:

```rust
// iroh-blobs/src/store/fs/bao_file.rs:530 — the per-hash cell IS the observer channel
pub(crate) struct BaoFileHandle(pub(super) watch::Sender<BaoFileStorage>);
// mutation: handle.send_if_modified(|s| { *s = s.write_batch(batch)?; changed });
// Observe: subscribe() → forward every watch `changed()` as a Bitfield diff
```

```d
// proposed / sketch — single-threaded cell + parked observers (no channel needed)
struct BaoFileHandle
{
    BaoFileStorage state;
    Waker[] observers;                   // fibers parked in `observe`
    void writeBatch(in BaoBatch b) {     // plain mutation; no send_if_modified closure
        if (state.apply(b))              // returns true if bitfield changed
            foreach (ref w; observers) w.wake();
    }
}
```

Where the store touches disk, **event-horizon is strictly better than Rust here**: the write-batch path (leaves → `.data`, parents → `.obao4`, size slot → `.sizes4`) is a natural multi-op io_uring submission chain; `sync_all` is `IORING_OP_FSYNC`; ordering only matters versus the bitfield-persist fsync barrier, not within a batch. No dedicated runtime, no `spawn_blocking` — the whole "the fs store owns and manages its own tokio runtime" apparatus ([`fs.rs:50`][fs-runtime]) disappears. The db actor's transaction batching (amortize fsync across commands) stays valuable with any KV backend: one fiber owns the DB, drains its queue against an in-ring `TIMEOUT` deadline, commits batches.

**The connection pool ports cleanly and _better_.** Model it as a struct owned by a `Scope`; per-connection actors are `Scope.spawn`ed fibers whose `onExit` runs `conn.close(0, "drop")`. The Rust `Context.owner` self-cycle and the no-shutdown-message gap — the reason its main actor is immortal — simply vanish. `ConnectionCounter`'s `AtomicUsize + Notify + Arc` becomes a plain `size_t` refcount plus a parked-fiber wakeup; `ConnectionRef` becomes a RAII handle (D struct with a dtor, or an `onExit`-registered release). The idle timer is a `withDeadline`-style cancellable sleep armed only when the refcount is zero. **Caveat**: event-horizon's `race` _cancels the losers_, whereas tokio's per-iteration `select!` keeps arms (the `conn.closed()` watcher, the inbox) alive across loop turns — so the port must structure each connection as one long-lived fiber blocking on a persistent composite (multishot-style subscription), not per-iteration races over freshly-created ops. Timeout semantics to preserve exactly: 1 s connect (including the `on_connected` hook), 5 s idle, 1024 cap, oldest-idle eviction, and error-caching for queued waiters.

**The irpc seam is worth keeping; the macro is not.** The essential design — one serializable request enum + a per-variant `(Tx, Rx)` channel-type mapping + a message type = request ⊗ live channels — is a natural DbI fit: define the request structs, attach `Tx`/`Rx` as members/UDAs, and generate the message sum, the `From` conversions, and the remote dispatcher with `static foreach` over `__traits(allMembers)` — no proc-macro, and the **local path monomorphizes away entirely** into direct capability method calls, achieving the zero-overhead in-process goal irpc only approximates with channel sends. Remote channel halves are just framed stream loops — perfect Tier-B fiber material (a `recv` verb reading `varint + frame`, a `send` verb serializing into a `SmallBuffer` and `write_all`ing), with backpressure inherited from QUIC flow control. Cancellation maps _better_ than in Rust: irpc must poison senders on dropped futures because Rust cancellation is silent, but event-horizon cancels only at terminal CQEs, so a cancelled send fiber knows exactly how many bytes were submitted — the "frame fully sent or channel dead" invariant is cheap to uphold via the `interrupt` arm of `Cause`.

**What has no equivalent and needs new design**: (a) the **cross-fiber channel** (O20) — needed for `Observe`/`GetProgress` streaming, the split-mode progress fan-in, and the pool/downloader inboxes; until it lands, single-owner fibers + direct calls cover request dispatch, but the many→one progress fan-in genuinely needs a small ring buffer with a parked-consumer wakeup. (b) **Buffer strategy** for cheaply-shared decoded leaves and `Bitfield` values (Rust's `bytes::Bytes`): plan a refcounted immutable buffer, or accept GC slices off the hot path. (c) A **`buffered_unordered(32)` equivalent** — a `Scope` plus a counting gate that admits the next part-fiber on each completion. What ports with zero friction: the postcard codec (`@nogc` reader/writer over `sparkles.base.text`-style primitives), the entire bao-tree math and decode stack machine (pure, `@safe pure nothrow @nogc`-able with `SmallBuffer` hash stacks), the `Bitfield`/`EntryState` algebra, and — if interop is wanted — the on-disk file layout byte-for-byte.

---

## Strengths

- **Verified streaming with a 16 KiB detection bound.** Corruption or substitution is caught within one chunk group, on both sides, from a self-describing tree — no trust in the provider required.
- **Monotone, commutative chunk possession.** Resumable and multi-provider downloads are _sound by construction_: any subset of ranges from any subset of providers composes to the same result. This is the single design choice that makes everything above the wire simple.
- **A compact, varint-friendly range encoding.** Alternating selected/deselected spans keep numbers small, so even "the hash sequence and all its children, forever" is a handful of bytes.
- **Transport-abstracted core.** The get/provider stack is generic over `SendStream`/`RecvStream`, so the protocol is testable against an in-memory network and composable with stream layers (e.g. compression) without touching QUIC.
- **A principled crash story.** "Never think we have data we can't verify" yields a clean rule — fsync data/outboard, then a checksummed bitfield only on clean shutdown, reconstruct by re-hashing otherwise — that avoids per-chunk fsync (and its 3.2 MB/s ceiling) without ever risking phantom availability.
- **A genuinely minimal RPC seam.** irpc's local path is near-free and its remote path is "just framed postcard over a QUIC stream," with QUIC providing all multiplexing and flow control.

## Weaknesses

- **Pre-production, by its own admission** ([`README.md:3`][bp-readme]); several rough edges are visible in-tree (a lying `MAX_MESSAGE_SIZE` comment, an apparently-dead `max_write_duration`, an "immortal" pool actor, a `todo` that loads whole hash sequences into memory and assumes them complete).
- **Throttling is a synchronous RPC round-trip per 16 KiB** — correct but a latency multiplier on the hot serving path when enabled.
- **The provider trusts hash-sequence completeness.** `handle_get_impl` loads the whole `HashSeq` into memory and indexes past-the-end silently ends the response rather than erroring — brittle for large or partial sequences.
- **CPU-bound hashing is on the async thread.** Outboard computation, crash-recovery revalidation, and hot-path re-encoding re-hash whole blobs; only cooperative yields keep them from starving peers.
- **The downloader is deliberately dumb.** No retry, backoff, scoring, or dedup — every consumer must re-implement those (iroh-docs does), and `SplitStrategy::None` is silently ignored for `GetMany`, which always fans out to 32.
- **`ConnectionPool` lives in a crates.io-only crate with no in-tree home** and quirks (immortal main actor, 1 s connect timeout that includes hole-punching, no per-transfer timeout) that a port must consciously decide whether to reproduce.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                                            | Trade-off                                                                                                      |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| BLAKE3 verified streaming, 16 KiB chunk groups ("n0-flavoured bao")    | Incremental verification with a bounded detection window; 16× smaller outboards than 1 KiB bao       | Sub-group range requests must recompute sub-tree hashes on the fly; worst-case ~2 chunk groups overhead/range  |
| One bidi QUIC stream per request; no in-band framing                   | QUIC gives cheap multiplexing, ordering, flow control; geometry is `(hash, size, ranges)`-determined | No response-level metadata; "not found" overloaded onto early FIN; no request IDs to correlate                 |
| Alternating-span `ChunkRangesSeq` encoding                             | Minimizes varint sizes; "all children forever" expressible without a count                           | Non-obvious to read/debug; two different `Bitfield` encodings coexist                                          |
| Responses carry no hashes                                              | Self-describing tree; nothing to spoof                                                               | Getter must know/derive every child hash (decode the `HashSeq` mid-transfer); a caller obligation in the FSM   |
| Store never fsyncs per chunk; bitfield persisted only on clean exit    | Keeps download throughput high (avoids the 3.2 MB/s per-group-fsync ceiling)                         | A crash forces full re-hash reconstruction of the partial bitfield                                             |
| Metadata batched; file-delete after metadata-commit; protect-on-create | "Don't touch the database if possible"; crash-consistent ordering                                    | Complex db-actor batching loop; a lost-on-crash window for large partial blobs                                 |
| Store is an `irpc` `Request` enum, not a trait                         | One dispatch path for in-process and (optional) remote; local path never serializes                  | The store's whole surface is a message enum; behavior is implicit in the actor                                 |
| Downloader has no retry/scoring/dedup; per-provider resume             | Keep it small; possession-commutativity makes naive resume correct                                   | Consumers must add dedup/retry; `SplitStrategy::None` ignored for `GetMany`; a stalled transfer has no timeout |
| Per-`ALPN` `ConnectionPool` with idle eviction, cached dial errors     | Reuse expensive hole-punched connections; serialize "dial once, share result" without a lock         | Reuse is per-pool-per-ALPN (docs-sync dials separately); main actor never terminates; aggressive 1 s connect   |

---

## Sources

- [`iroh-blobs` — GitHub repository (`v0.103.0`)][repo] · [docs.rs][docs]
- [`iroh-blobs/src/protocol.rs` — `Request`, `GetRequest`, ALPN, `MAX_MESSAGE_SIZE`, error/close codes, `ChunkRangesSeq` doc][bp-request]
- [`iroh-blobs/src/protocol/range_spec.rs` — `RangeSpec`/`ChunkRangesSeq` wire encoding + hexdump tests][rs-wire]
- [`iroh-blobs/src/get.rs` — the get-client typestate `fsm`][get-fsm]
- [`iroh-blobs/src/provider.rs` — accept loop, per-stream dispatch, observe server][pv-dispatch] · [`provider/events.rs` — `EventMask`, throttle, update channels][pe-mask]
- [`iroh-blobs/src/hash.rs`][hash-newtype] · [`hashseq.rs`][hashseq] · [`format/collection.rs`][collection] · [`ticket.rs`][ticket] · [`util/stream.rs` (`SendStream`/`RecvStream`, varint)][stream-traits]
- [`iroh-blobs/src/store/fs.rs` — main actor, import/export, disk layout][fs-mainactor] · [`store/fs/meta/tables.rs` (redb schema)][tables] · [`entry_state.rs`][entrystate] · [`bao_file.rs`][baofile] · [`store/util.rs` (checksummed bitfield)][su-checksum] · [`store/gc.rs`][gc]
- [`iroh-blobs/src/api/proto.rs` — the store `Request` enum][proto] · [`api.rs` — `Store` = `irpc::Client`][api-store] · [`api/remote.rs` — `LocalInfo`/resume planner][rm-missing] · [`api/downloader.rs` — `Downloader`, split, provider loop][dl-execget]
- [`iroh-blobs/DESIGN.md` — integrity, crash-consistency, commutativity][design-integrity] · [`README.md`][bp-readme]
- [`iroh-util/src/connection_pool.rs` (`v0.6.0`) — pool `Options`, actors, idle eviction][cp-doc]
- [`irpc/src/lib.rs` (`v0.17.0`) — channels, `Service`/`Channels`, `Client`, framing, `listen`][irpc-goal] · [docs.rs][irpc-docs]
- [`bao-tree` (`v0.16.0`) — verified-streaming math (own dossier → [`bao-tree`][bao-tree])][bt-repo]
- Related iroh pages: [`bao-tree`][bao-tree] · [`wire-serialization`][wire] · [`quic-transport`][quic-transport] · [`endpoint`][endpoint] · [`docs-sync`][docs-sync] · [`concurrency`][concurrency] · [`d-architecture-migration`][d-migration]

<!-- References -->

[repo]: https://github.com/n0-computer/iroh-blobs/tree/v0.103.0
[docs]: https://docs.rs/iroh-blobs/0.103.0/iroh_blobs/
[util-repo]: https://github.com/n0-computer/iroh-util/tree/v0.6.0
[irpc-repo]: https://github.com/n0-computer/irpc/tree/v0.17.0
[irpc-docs]: https://docs.rs/irpc/0.17.0/irpc/
[bt-repo]: https://github.com/n0-computer/bao-tree/tree/v0.16.0
[bt-docs]: https://docs.rs/bao-tree/0.16.0/bao_tree/
[bp-alpn]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs#L406
[bp-maxsize]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs#L395
[bp-integrity]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs#L10
[bp-rangeseq]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs#L293
[bp-streams]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs#L367
[bp-request]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs#L408
[bp-getmany]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs#L579
[bp-observe]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs#L616
[bp-errcodes]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs#L398
[bp-read]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs#L448
[bp-readme]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/README.md#L3
[rs-spec]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol/range_spec.rs#L341
[rs-inf]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol/range_spec.rs#L165
[rs-wire]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol/range_spec.rs#L470
[rs-tests]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol/range_spec.rs#L553
[get-fsm]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/get.rs
[get-openbi]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/get.rs#L239
[get-startchild]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/get.rs#L418
[get-header]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/get.rs#L520
[get-misc]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/get.rs#L369
[get-notfound]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/get.rs#L495
[hash-newtype]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/hash.rs#L14
[hash-empty]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/hash.rs#L25
[hash-parse]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/hash.rs#L151
[hashseq]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/hashseq.rs#L54
[collection]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/format/collection.rs#L82
[ticket]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/ticket.rs#L39
[stream-traits]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/util/stream.rs#L14
[stream-varint]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/util/stream.rs#L401
[np]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/net_protocol.rs#L86
[pv-accept]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/provider.rs#L305
[pv-reject]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/provider.rs#L294
[pv-getimpl]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/provider.rs#L429
[pv-dispatch]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/provider.rs#L372
[pv-observe]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/provider.rs#L627
[pe-mask]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/provider/events.rs#L167
[pe-pushdefault]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/provider/events.rs#L189
[pe-throttle]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/provider/events.rs#L282
[ab-write]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/api/blobs.rs#L1133
[proto]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/api/proto.rs#L90
[api-store]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/api.rs#L211
[api-connect]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/api.rs#L250
[api-downloader]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/api.rs#L241
[rm-missing]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/api/remote.rs#L341
[dl-proto]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/api/downloader.rs#L40
[dl-strategy]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/api/downloader.rs#L150
[dl-execget]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/api/downloader.rs#L484
[fs-mainactor]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs.rs#L239
[fs-runtime]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs.rs#L50
[fs-importbao]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs.rs#L1140
[tables]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs/meta/tables.rs#L7
[meta-batch]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs/meta.rs#L785
[entrystate]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs/entry_state.rs#L161
[baofile]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs/bao_file.rs#L299
[opts-inline]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs/options.rs#L71
[deleteset]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs/delete_set.rs#L113
[su-checksum]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/util.rs#L218
[gc]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/gc.rs#L34
[design-integrity]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/DESIGN.md#L5
[design-job]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/DESIGN.md#L11
[design-meta]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/DESIGN.md#L61
[design-commute]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/DESIGN.md#L112
[design-crash]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/DESIGN.md#L124
[design-fsync]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/DESIGN.md#L134
[cp-doc]: https://github.com/n0-computer/iroh-util/blob/v0.6.0/src/connection_pool.rs#L1
[cp-options]: https://github.com/n0-computer/iroh-util/blob/v0.6.0/src/connection_pool.rs#L42
[irpc-goal]: https://github.com/n0-computer/irpc/blob/v0.17.0/src/lib.rs#L5
[irpc-framing]: https://github.com/n0-computer/irpc/blob/v0.17.0/src/lib.rs#L50
[bt-decoder]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/io/fsm.rs#L317
[blake3]: https://github.com/BLAKE3-team/BLAKE3
[redb]: https://docs.rs/redb/4.1.0/redb/
[rfc9000]: https://www.rfc-editor.org/rfc/rfc9000
[bao-tree]: ./bao-tree.md
[wire]: ./wire-serialization.md
[quic-transport]: ./quic-transport.md
[endpoint]: ./endpoint.md
[socket]: ./socket.md
[identity]: ./identity-crypto.md
[docs-sync]: ./docs-sync.md
[concurrency]: ./concurrency.md
[d-migration]: ./d-architecture-migration.md
[concepts]: ./concepts.md
[index]: ./index.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[async-io]: ../async-io/index.md
[tokio]: ../async-io/tokio.md
