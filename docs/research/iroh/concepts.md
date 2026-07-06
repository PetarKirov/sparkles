# Concepts & Vocabulary

The shared glossary the rest of this survey is written in: every load-bearing iroh 1.0 noun — `EndpointId`, `EndpointAddr`, `Ticket`, `ALPN`, `postcard`, the `Socket`/`Endpoint`/`Connection` layering, `path`/multipath, QUIC Address Discovery, NAT traversal, `address_lookup`, `Hash`/`bao`/`outboard`, `HashSeq`, `NamespaceId`/`AuthorId`/`Entry`, gossip `TopicId`, `relay`/home relay, `net_report` — defined once, grounded in a cited source line, and linked onward to the deep-dive that treats it in depth.

**Last reviewed:** July 6, 2026

> [!NOTE]
> This is a _reference_ page, not a deep-dive: it fixes terminology and points at the
> authoritative treatment, so the deep-dives can use a term without re-defining it. Every
> definition here is pinned to iroh workspace **v1.0.1** (commit `22cac742ca`) and the
> matching crate tags ([`iroh-blobs`][blobs] 0.103.0, [`iroh-docs`][docs-sync] 0.101.0,
> [`iroh-gossip`][gossip] 0.101.0, [`noq`][quic] `noq-v1.0.1`, [`bao-tree`][bao] 0.16.0).
> iroh 1.0 is a **major rename** of the 0.x API — see [The 1.0 rename cascade](#the-1-0-rename-cascade)
> — so 0.x folklore (`NodeId`, `magicsock`, DISCO, STUN, `Collection`-as-protocol) does not
> compile against this tree. Part of the [iroh survey][index].

---

## Why this page

iroh's names are load-bearing. The single most consequential fact about the whole stack — that
an endpoint's identity, address, and encryption root are the _same_ Ed25519 key — is expressed
purely through the type aliasing `pub type EndpointId = PublicKey`, and reading the code without
that in hand is a maze. The 1.0 restructure then renamed roughly a dozen of the most-used
identifiers at once. This page is the decoder ring: it gives one grounded definition per term and
a link to where the mechanics live, so a reader (or a D re-implementer) can move between deep-dives
without re-deriving vocabulary each time.

Terms are grouped by the layer they belong to, bottom-up: **identity & addressing** → **serialization
& sharing** → **the connectivity layering** → **getting connected** → **content addressing (blobs)**
→ **documents & gossip**. Two cross-cutting facts frame everything: the whole application stack
serializes with one format ([`postcard`](#postcard)), and the whole connectivity stack is one
[QUIC][quic] connection per peer carrying multiple [paths](#path-direct-vs-relay-and-multipath).

---

## The 1.0 rename cascade

iroh 1.0 renamed the vocabulary wholesale and deleted two 0.x subsystems outright. A term on the
left will not be found in the pinned tree; use the right.

| 0.x term                       | 1.0 term                                                            | Note                                                                          |
| ------------------------------ | ------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `NodeId`                       | [`EndpointId`](#endpointid-publickey-secretkey)                     | still an alias of `PublicKey` ([`key.rs`][key])                               |
| `NodeAddr`                     | [`EndpointAddr`](#endpointaddr-transportaddr)                       | now an `id` + a unified `BTreeSet<TransportAddr>`                             |
| `NodeTicket`                   | [`EndpointTicket`](#ticket-and-its-three-kinds)                     | old `node…` ticket strings are unparseable by 1.0                             |
| `magicsock` / `MagicSock`      | the [socket][socket] layer / `Socket`                               | `pub(crate)`, restructured around `noq` multipath ([`socket.rs`][socket-doc]) |
| `discovery` / `Discovery`      | [`address_lookup`](#address_lookup-pkarr-and-dns) / `AddressLookup` | a pure name→address directory ([`address_lookup.rs`][al-trait])               |
| `DiscoveryItem` / `NodeInfo`   | `Item` / `EndpointInfo` / `EndpointData`                            | see [Address Lookup][discovery]                                               |
| `DISCO` (UDP side-protocol)    | **gone** → in-QUIC [NAT traversal](#nat-traversal-holepunch) (QNT)  | no magic ping/pong packets on the wire                                        |
| STUN                           | **gone** → [QUIC Address Discovery](#quic-address-discovery-qad)    | no STUN code anywhere in the tree                                             |
| `netcheck`                     | [`net_report`](#net_report)                                         | same shape, QAD+HTTPS substrate ([`net_report.rs`][nr-doc])                   |
| DERP                           | [relay](#relay-and-home-relay) (`iroh-relay`)                       | WebSocket packet-forwarder, revised                                           |
| `Collection` (a protocol type) | a [`HashSeq`](#hashseq-and-collection) convention                   | no longer known to the wire protocol                                          |
| `quinn`                        | [`noq`](#the-runtime-asyncudpsocket-seam)                           | n0's fork adding multipath / QAD / QNT ([`README.md`][noq-readme])            |

---

## Identity & addressing

Everything an endpoint _is_ and everywhere it can be _reached_ hangs off one 32-byte Ed25519 key.
The crate root states the dual role directly ([`iroh-base/src/key.rs`][key]):

> _"Each endpoint in iroh has a unique identifier created as a cryptographic key. This can be used
> to globally identify an endpoint. Since it is also a cryptographic key it is also the mechanism by
> which all traffic is always encrypted for a specific endpoint only."_

| Term                   | Definition                                                                                                                                                                                                                                       | Owning page · cite                                   |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| `PublicKey`            | A `#[repr(transparent)]` newtype over the 32-byte compressed Edwards y-coordinate of an Ed25519 verifying key; `LENGTH = 32`. Verification is `verify_strict`, not the permissive `verify`.                                                      | [identity-crypto][identity] · [`key.rs`][key]        |
| `EndpointId`           | The **same type**, `pub type EndpointId = PublicKey`. Convention: say `PublicKey` for crypto operations, `EndpointId` when naming an endpoint. Self-certifying — the name _is_ the verification key.                                             | [identity-crypto][identity] · [`key.rs`][key]        |
| `SecretKey`            | The 32-byte Ed25519 **seed** wrapping `ed25519_dalek::SigningKey`, `ZeroizeOnDrop`. `public()` re-derives the `PublicKey`; the same secret signs relay, pkarr, and docs surfaces with no extra crypto.                                           | [identity-crypto][identity] · [`key.rs`][key]        |
| `Signature`            | A 64-byte Ed25519 signature; on the wire it is 64 raw bytes, no length prefix.                                                                                                                                                                   | [identity-crypto][identity] · [`key.rs`][key]        |
| `EndpointAddr`         | `EndpointAddr { id: EndpointId, addrs: BTreeSet<TransportAddr> }` — an id plus a set of location hints. Dialing by bare `id` (empty `addrs`) is legal; [address lookup](#address_lookup-pkarr-and-dns) fills the rest.                           | [wire][wire] · [`endpoint_addr.rs`][endpoint-addr]   |
| `TransportAddr`        | The `#[non_exhaustive]` enum of one location hint: `Relay(RelayUrl)` (postcard tag 0), `Ip(SocketAddr)` (1), `Custom(CustomAddr)` (2). Derived `Ord` = `(variant index, payload)`, which _is_ the ticket byte order.                             | [wire][wire] · [`endpoint_addr.rs`][endpoint-addr]   |
| `RelayUrl`             | A newtype over `Arc<Url>` naming a [relay](#relay-and-home-relay) server (e.g. `http://derp.me./`); it appears as `TransportAddr::Relay` and as an endpoint's [home relay](#relay-and-home-relay).                                               | [relay][relay] · [`endpoint_addr.rs`][endpoint-addr] |
| `EndpointIdMappedAddr` | A **synthetic** IPv6 Unique-Local-Address (`fd15:70a:510b::/64`, dummy port `12345`) minted one-per-remote so [`noq`][quic], which only understands `SocketAddr`, can dial a peer that has no fixed IP. `struct EndpointIdMappedAddr(Ipv6Addr)`. | [socket][socket] · [`mapped_addrs.rs`][mapped]       |

Two subtleties a reader trips on. First, an `EndpointId` **string** is 64-char lowercase hex by
`Display` (the 0.x base32 `Display` is gone), though `FromStr` still accepts either hex or
`BASE32_NOPAD`. Second, the `EndpointIdMappedAddr` is one of a family of "fake" ULA addresses the
[socket][socket] uses to name non-IP destinations to QUIC — `RelayMappedAddr` and `CustomMappedAddr`
are the siblings; the mapping table is append-only for process lifetime ([`mapped_addrs.rs`][mapped]).

---

## Serialization & sharing

### `postcard`

The **one** application-level serialization format across the whole stack — a compact,
non-self-describing binary [`serde`][serde] encoding. There is no `protobuf`, no `bincode`, and no
JSON on any hot path. The rules a codec must implement: unsigned integers are LEB128 varints
(little-endian 7-bit groups, MSB = continuation); signed integers are zigzag-then-varint; a fixed
`[u8; N]` (a key, a hash) is N raw bytes with **no** length prefix; an `enum` is a varint of the
_declaration index_ then the payload; a struct is its fields concatenated in declaration order with
no tags. Because nothing is self-describing, **the Rust declaration order _is_ the wire contract** —
reordering a struct's fields is a silent wire break. A second varint dialect coexists: the
[QUIC varint][rfc9000] (RFC 9000 §16, big-endian, 2-bit length tag) is used for relay frame types
and QUIC-native fields; a port implements both and must never confuse them.
Full byte-level treatment in [Wire Formats & Serialization][wire].

### `ALPN`

An **Application-Layer Protocol Negotiation** byte string ([RFC 7301][rfc7301]) chosen per protocol;
every iroh connection is opened under one, and the accepting [protocol router][endpoint] dispatches
on an exact-match of the bytes (the accept side picks the winner; connect-side order is irrelevant).
The production registry:

| `ALPN`           | Owner                    | Carries                                                            |
| ---------------- | ------------------------ | ------------------------------------------------------------------ |
| `/iroh-bytes/4`  | [`iroh-blobs`][blobs]    | content-addressed [blob](#blob-document-and-gossip-topic) transfer |
| `/iroh-sync/1`   | [`iroh-docs`][docs-sync] | [document](#blob-document-and-gossip-topic) range-sync             |
| `/iroh-gossip/1` | [`iroh-gossip`][gossip]  | epidemic broadcast on a [topic](#blob-document-and-gossip-topic)   |
| `/iroh-qad/0`    | [`iroh-relay`][relay]    | [QUIC Address Discovery](#quic-address-discovery-qad) listener     |
| `DUMBPIPEV0`     | `dumbpipe`               | raw byte pipe (example app)                                        |

The full registry, hex, and citations are in [Wire Formats & Serialization][wire]. Note that `ALPN`
is _not_ the TLS server name: the [SNI][identity] is a synthetic `base32(EndpointId).iroh.invalid`
that carries the dialed id and buckets 0-RTT tickets per peer.

### `Ticket` and its three kinds

A **ticket** is the copy-pasteable string that bootstraps a connection: a `KIND` prefix plus the
`BASE32_NOPAD` of a [`postcard`](#postcard) payload wrapped in a single-variant enum (so byte `0x00`
opens every ticket, a one-byte version discriminant bought cheaply). The [`Ticket`][tickets-lib]
trait leaves the byte format to the implementer but recommends `postcard`, which all three concrete
tickets use.

| Ticket           | `KIND`     | Payload                                                                                                                       | Cite                              |
| ---------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| `EndpointTicket` | `endpoint` | `EndpointId` + `BTreeSet<TransportAddr>` (the unified 1.0 address shape, `Variant1`)                                          | [`endpoint.rs`][tickets-endpoint] |
| `BlobTicket`     | `blob`     | **legacy 0.x layout**: `EndpointId` + `Option<RelayUrl>` + `BTreeSet<SocketAddr>` + `BlobFormat` + [`Hash`](#hash-and-blake3) | [`ticket.rs`][blobs-ticket]       |
| `DocTicket`      | `doc`      | a `Capability` (`Read` = a `NamespaceId`, or `Write` = a raw 32-byte `NamespaceSecret`) + `Vec<EndpointAddr>`                 | [`ticket.rs`][docs-ticket]        |

Two hazards worth stating in the glossary. `BlobTicket` still ships the pre-1.0 address shape and
**silently drops** `Custom` transports and all but the first relay on encode — a port cannot reuse
one address encoder for all three. And a `DocTicket` whose `Capability` is `Write` embeds the
document's raw secret key: **tickets are bearer credentials, not just addresses**.

---

## The connectivity layering

Three objects sit in a strict stack, and confusing them is the most common vocabulary error. From
bottom to top:

| Object       | What it is                                                                                                                                                                                                                                                                                                                                                               | Owning page · cite                                |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------- |
| `Socket`     | The multipath **connectivity fabric** (ex-`magicsock`, `pub(crate)`). It presents [`noq`][quic] with a single object that _looks like one UDP socket_ (`noq::AsyncUdpSocket`) while fanning datagrams across IP, one relay, and custom transports, and owns [path](#path-direct-vs-relay-and-multipath) selection and [hole-punch](#nat-traversal-holepunch) scheduling. | [socket][socket] · [`socket.rs`][socket-doc]      |
| `Endpoint`   | The public **front door**: a cheaply-clonable `Arc<EndpointInner>` over the QUIC stack + identity + a [protocol `Router`][endpoint]. Recommended one per application so all connections share peer-to-peer state.                                                                                                                                                        | [endpoint][endpoint] · [`endpoint.rs`][ep-single] |
| `Connection` | **One QUIC connection** to one peer (over `noq::Connection`), typed `Connection<State>` for 0-RTT correctness. A single connection carries multiple concurrent [multipath paths](#path-direct-vs-relay-and-multipath).                                                                                                                                                   | [endpoint][endpoint] · [`quic-transport`][quic]   |

The `Endpoint` doc comment fixes the "one per application" convention ([`endpoint.rs`][ep-single]):

> _"It is recommended to only create a single instance per application. This ensures all the
> connections made share the same peer-to-peer connections to other iroh endpoints, while still
> remaining independent connections."_

### The `Runtime` / `AsyncUdpSocket` seam

The seam between the QUIC state machine and its host is the single most important interface for a
port. [`noq`][quic] is **sans-io**: `noq-proto` is pure protocol logic with no clock and no sockets,
and the async `noq` crate reaches the outside world through four traits — `Runtime` (`new_timer`,
`spawn`, `wrap_udp_socket`, `now`), `AsyncUdpSocket` (`create_sender`, `poll_recv`, `local_addr`),
`UdpSender` (`poll_send`), and `AsyncTimer`. iroh plugs its multipath `Socket` in as an
`AsyncUdpSocket` via `new_with_abstract_socket` (so `wrap_udp_socket` is dead code — the QUIC stack
never touches a raw UDP fd), and drives every timer/task through `Runtime`. That trait object is
exactly what a D port replaces with an [event-horizon][eh-spec] capability row + `Scope`, and the
sans-io core it fronts is what makes the port tractable at all ([`noq/src/runtime/mod.rs`][noq-runtime]).

### `path` (direct vs relay) and multipath

A **path** in iroh 1.0 is a QUIC-Multipath path, not a mode. The decisive change from 0.x: there is
no separate "relay mode" any more — **the relay and every direct address are concurrent multipath
paths on one connection**, and "upgrading from relay to direct" is just flipping a path's QUIC
`PathStatus` from `Backup` to `Available` and letting [`noq`][quic] route ([`socket.rs`][socket-doc]).

- A **direct path** is a hole-punched UDP 4-tuple between the two peers (see [NAT traversal](#nat-traversal-holepunch)).
- A **relay path** carries the same encrypted QUIC datagrams through a [relay](#relay-and-home-relay) server by `EndpointId`.
- Internally [`noq`][quic] separates a `PathId` (a multipath **packet-number space**: its own packet
  numbers, ACK state, loss timers) from a `PathData` (the **4-tuple in use**: RTT, congestion
  controller, MTU); one `PathId` can migrate across 4-tuples. Scheduling is a strict two-tier
  priority — lowest-`PathId` validated `Available` path wins; `Backup` paths carry data only when no
  `Available` path exists.

iroh configures **8** concurrent paths, a **5 s** heartbeat, and a **15 s** per-path idle timeout;
smarter selection (RTT-weighting, sticky failover) lives in the [socket][socket]'s per-remote actor,
above `noq`.

---

## Getting connected

Four subsystems cooperate to turn a bare `EndpointId` into a working direct path. STUN and the DISCO
UDP side-protocol of 0.x are **both gone** — every mechanism below rides inside QUIC or over HTTPS.

### QUIC Address Discovery (QAD)

The **STUN replacement**: the peer at the other end of a QUIC connection tells you the source
`SocketAddr` it observes for you, in an `OBSERVED_ADDRESS` frame. It is negotiated by the transport
parameter `ObservedAddr = 0x9f81a176` (role ∈ {send-only, receive-only, both}) and carried by frames
`ObservedIpv4Addr = 0x9f81a6` / `ObservedIpv6Addr = 0x9f81a7` ([`noq-proto`][quic],
[`transport_parameters.rs`][noq-tp]). iroh consumes it two ways: **dedicated relay QAD servers**
(ALPN `/iroh-qad/0` on UDP port `7842`) that [`net_report`](#net_report) probes to learn its own
public address, and **in-band on every regular connection**. Because the probe rides the very socket
whose mapping it measures, the discovered address is a valid direct-path candidate. Draft:
[draft-seemann-quic-address-discovery][draft-qad]. See [NAT Traversal][nat] and [Net Report][net-report].

### NAT traversal (holepunch)

iroh punches through NATs **entirely inside QUIC**, via n0's own extension **QNT** — "inspired by
[draft-seemann-quic-nat-traversal-02][draft-qnt], simplified to n0's own protocol". Both peers
advertise their [QAD](#quic-address-discovery-qad)-learned reflexive addresses with
`ADD_ADDRESS`/`REMOVE_ADDRESS`/`REACH_OUT` frames (block `0x3d7f90…0x3d7f94`), then fire off-path
`PATH_CHALLENGE`/`PATH_RESPONSE` probes simultaneously so each NAT sees the inbound as a reply and
installs a mapping (**simultaneous open**). A successful probe becomes a validated
[multipath path](#path-direct-vs-relay-and-multipath). QNT requires multipath and negotiates via
transport parameter `N0NatTraversal = 0x3d7f91120401` (value = max advertised addresses); roles are
fixed by the QUIC client/server side, not by who is behind NAT. iroh allows **32** QNT addresses.
The engine is [sans-io][async-io]; orchestration lives in the [socket][socket] per-remote actor. Full
treatment in [NAT Traversal & Address Discovery][nat].

### `address_lookup`, pkarr, and DNS

**`address_lookup`** (what 0.x called _discovery_) is the directory that maps an `EndpointId` to
transport addresses — deliberately _not_ the dialer. The [`AddressLookup`][al-trait] trait is
asymmetric: `publish` is fire-and-forget, `resolve` is a cancellable multi-result stream. Its doc
comment ([`address_lookup.rs`][al-trait]):

> _"Publishes the given `EndpointData` to the Address Lookup mechanism. This is fire and forget,
> since the `Endpoint` can not wait for successful publishing."_

Two nouns name the _how_, not the _what_:

- **pkarr** — _Public-Key Addressable Resource Records_: the self-authenticating record format. An
  endpoint's addressing info is packed as an RFC 1035 DNS reply packet, wrapped in a [BEP-44][bep44]
  mutable-item encoding, signed by the `SecretKey`. The 1104-byte layout is a 32-byte public key, a
  64-byte signature, an 8-byte microsecond timestamp, then a `≤1000`-byte DNS packet
  ([`iroh-dns/src/pkarr.rs`][dns-pkarr]). Any party
  can verify; only the key-holder can mint a newer (monotonic-timestamp) record. iroh vendors the
  format (~400 lines) rather than depending on the upstream `pkarr` crate.
- **DNS** — one _transport_ for pkarr records: the same signed DNS packet is served under a
  z-base-32 domain label, so resolvers can cache it. The `N0` preset pairs a `PkarrPublisher`
  (publish over HTTP) with a `DnsAddressLookup` (resolve over cheap, cacheable DNS).

The default publisher filter is `relay_only()` — raw IPs are not leaked to a public pkarr server
unless the operator opts in. Full treatment in [Address Lookup (Discovery)][discovery].

### `relay` and home relay

A **relay** is a public, always-reachable server that both peers connect to and that forwards opaque
already-encrypted QUIC datagrams between them by destination `EndpointId` — a revised DERP. It is
simultaneously the _rendezvous_ (a fixed address both peers can reach) and the _fallback data path_
(a [relay path](#path-direct-vs-relay-and-multipath) until direct hole-punching succeeds). It never
sees plaintext ([`iroh-relay/src/lib.rs`][relay-lib]):

> _"The relay server helps establish connections by temporarily routing encrypted traffic until a
> direct, P2P connection is feasible. Once this direct path is set up, the relay server steps back,
> and the data flows directly between devices."_

The data plane is binary WebSocket messages over HTTP(S) (so it runs unmodified in a browser); the
relay binary also co-hosts the [QAD](#quic-address-discovery-qad) endpoint. A node's **home relay**
is the single lowest-latency relay it camps on, chosen by [`net_report`](#net_report) with hysteresis
to prevent flapping between near-equal servers. Full treatment in [The Relay Protocol][relay].

### `net_report`

The **connectivity-sensing report** (descendant of Tailscale's `netcheck`): it answers "what does the
network look like from here right now" — is UDP working over IPv4/IPv6, what public `SocketAddr` does
the world assign me (`global_v4`/`global_v6`), is the NAT mapping endpoint-dependent (symmetric,
which defeats naive hole-punching), which relay is the [home relay](#relay-and-home-relay), and is a
captive portal intercepting traffic ([`report.rs`][nr-report]). In 1.0 its only probes are
[QAD](#quic-address-discovery-qad) (over the _main_ endpoint) and HTTPS; STUN and ICMP are gone. It
also owns two sibling inputs — `netwatch` (interface/route watching + the rebindable `UdpSocket`) and
`portmapper` (UPnP/PCP/NAT-PMP). Full treatment in [Net Report][net-report].

---

## Content addressing (blobs)

### `Hash` and BLAKE3

A `Hash` is a 32-byte newtype over `blake3::Hash` — the content address at the heart of
[blobs][blobs]. On the wire it is 32 raw bytes, no length prefix; `Display` is 64-char lowercase hex,
`FromStr` also accepts 52-char base32-nopad. `Hash::EMPTY` (the BLAKE3 hash of `b""`) is a hard
special case: never stored, always "present", the only hash for which a zero-size response is legal
([`hash.rs`][blobs-hash]). The **hash is the request**: because response geometry is fully determined
by `(hash, size, ranges)`, there is exactly one correct byte sequence per request, and tampering is
detected locally.

### `bao`, `outboard`, and `ChunkRanges`

BLAKE3 internally hashes a blob as a binary Merkle tree over 1024-byte chunks; **[`bao-tree`][bao]**
exposes that tree as a **verified-streaming codec**, so a receiver holding only the 32-byte root can
pull an arbitrary subset from an untrusted peer and verify each piece _as it arrives_, aborting the
moment a hash mismatches — "the requester will notice if data is incorrect after at most 16 KiB of
data" ([`iroh-blobs/DESIGN.md`][design-integrity]).

| Term                             | Definition                                                                                                                                                                                                                                                   | Cite                                             |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------ |
| `bao` / bao-tree                 | The verified-streaming format (wire-compatible with the `bao` crate at block size 0), extended with runtime-configurable chunk groups and multi-range queries.                                                                                               | [bao-tree][bao] · [`tree.rs`][bt-tree]           |
| `outboard`                       | The tree of **interior** BLAKE3 hashes (64-byte parent chaining-value pairs) stored/transmitted separately from the data, so ranges can be verified without re-hashing the whole blob.                                                                       | [bao-tree][bao] · [`tree.rs`][bt-tree]           |
| `BlockSize` / chunk group        | The runtime leaf granularity, `log2(group bytes / 1024)`. iroh fixes `IROH_BLOCK_SIZE = BlockSize::from_chunk_log(4)` = **16 KiB** ("n0-flavoured bao"), cutting the outboard 16× versus per-1024-byte-chunk classic bao.                                    | [bao-tree][bao] · [`tree.rs`][bt-tree]           |
| `ChunkRanges` / `ChunkRangesSeq` | A run-length-encoded sorted set of non-overlapping chunk ranges (units of 1024-byte chunks) selecting exactly which parts of a blob (or hash-sequence) to fetch and verify. Encoded as alternating deselect/select span widths for small `postcard` varints. | [blobs][blobs] · [`protocol.rs`][blobs-protocol] |

### `HashSeq` and `Collection`

A **`HashSeq`** is the only structural type the [blobs][blobs] protocol knows beyond a raw blob: a
blob whose bytes are a raw concatenation of 32-byte hashes (`len % 32 == 0`, `get(i)` = bytes
`[i*32 .. (i+1)*32]`, no header) ([`hashseq.rs`][hashseq]). `BlobFormat` is therefore just
`Raw | HashSeq`. A **`Collection`** is a _convention_ layered on top (invisible to the protocol): a
`HashSeq` whose link 0 is the hash of a metadata blob whose `postcard`-encoded `CollectionMeta`
carries a `header: [u8; 13]` = `b"CollectionV0."` and a list of `names`, so `names[i]` labels
`link[i+1]` — a named directory of blobs
([`format/collection.rs`][collection]). In 0.x `Collection` was a protocol concept; in 1.0 it is only
this convention.

---

## Documents & gossip

### `blob`, `document`, and gossip `topic`

The three application protocols name three different data shapes:

| Term             | Data shape                                                                                                                                         | ALPN             | Owning page            |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | ---------------------- |
| **blob**         | An immutable, content-addressed byte sequence named by its [`Hash`](#hash-and-blake3).                                                             | `/iroh-bytes/4`  | [blobs][blobs]         |
| **document**     | A multi-writer, eventually-consistent key–value map (a _replica_) of signed `(namespace, author, key)` [entries](#namespaceid-authorid-and-entry). | `/iroh-sync/1`   | [docs-sync][docs-sync] |
| **gossip topic** | A `TopicId` — a 32-byte identifier naming one independent broadcast swarm and its membership + broadcast state machines.                           | `/iroh-gossip/1` | [gossip][gossip]       |

Gossip is a **control-plane** transport (default per-message ceiling **4096 bytes**): documents ride
it to fan out change notifications, and bulk content moves through blobs.

### `NamespaceId`, `AuthorId`, and `Entry`

A [document][docs-sync]'s identity model is three Ed25519-keyed nouns:

- **`NamespaceId`** — a `[u8; 32]` newtype over an Ed25519 public key that names the document. Its
  secret, `NamespaceSecret`, is the **write capability for the whole document**.
- **`AuthorId`** — a `[u8; 32]` public-key newtype naming a writer; its secret `Author` is an
  authorship proof. Any number of authors may write the same key.
- **`Entry`** — the unit of state: `Entry { id: RecordIdentifier, record: Record }`, where
  `RecordIdentifier` is the triple `(NamespaceId, AuthorId, key-bytes)` and `Record { len, hash,
timestamp }` is a metadata _pointer_ (the content bytes live in [blobs][blobs], fetched by
  `hash`). A `SignedEntry` carries **two** Ed25519 signatures over one canonical payload — one by the
  author, one by the namespace ([`sync.rs`][docs-sync-rs], [`keys.rs`][docs-keys]).

Conflicts resolve last-writer-wins (timestamp, then content `hash`); a **deletion is an empty
entry** (`Hash::EMPTY`, `len == 0`), itself a signed, replicated fact. Peers converge by
range-based set reconciliation — recursively fingerprinting ranges of the ordered key space and
descending only where fingerprints disagree.

### HyParView and Plumtree

The two classic algorithms [gossip][gossip] composes, each a faithful implementation of a Leitão et
al. paper:

- **HyParView** — the **membership** protocol ([DSN 2007][hyparview]). Each node keeps a small
  `active_view` (size 5) of peers it holds live bidirectional connections to, plus a larger
  `passive_view` (size 30) address book it draws from to heal the active view after a failure.
  Random walks (`ForwardJoin`, `Shuffle`) diffuse membership across the swarm.
- **Plumtree** — the **broadcast** protocol ([SRDS 2007][plumtree]). Each active neighbor is either
  _eager_ (receives full payloads) or _lazy_ (receives only a `blake3` message-id announcement,
  `IHave`). The eager set forms a low-redundancy spanning tree that carries each payload once per
  edge; the lazy set is a backstop that repairs gaps and continually re-optimizes the tree toward
  lowest latency by promoting a lazy peer to eager whenever it supplies a missing message.

Both run as one pure, IO-less state machine per topic ([`proto.rs`][g-proto]), driven over per-peer
[`noq`][quic] QUIC connections by the `net/` actor — the sans-io shape a D port drives directly on
[event-horizon][eh-spec] fibers.

---

## Terms at a glance

| Term                                 | One line                                                                  | Page                        |
| ------------------------------------ | ------------------------------------------------------------------------- | --------------------------- |
| `EndpointId` / `PublicKey`           | 32-byte Ed25519 key; the self-certifying endpoint name = verification key | [identity-crypto][identity] |
| `SecretKey`                          | 32-byte Ed25519 seed; signs TLS, relay, pkarr, docs                       | [identity-crypto][identity] |
| `EndpointAddr`                       | `id` + `BTreeSet<TransportAddr>` location hints                           | [wire][wire]                |
| `TransportAddr`                      | one hint: `Relay` \| `Ip` \| `Custom`                                     | [wire][wire]                |
| `RelayUrl`                           | URL of a relay server                                                     | [relay][relay]              |
| `EndpointIdMappedAddr`               | synthetic ULA so QUIC can dial a non-IP peer                              | [socket][socket]            |
| `postcard`                           | the one non-self-describing binary wire codec                             | [wire][wire]                |
| `ALPN`                               | per-protocol negotiation byte string; router dispatch key                 | [endpoint][endpoint]        |
| `Ticket`                             | base32 shareable string; `endpoint` / `blob` / `doc`                      | [wire][wire]                |
| `Socket`                             | multipath fabric under QUIC (ex-`magicsock`)                              | [socket][socket]            |
| `Endpoint`                           | public front door; one per app                                            | [endpoint][endpoint]        |
| `Connection`                         | one QUIC connection to one peer, multi-path                               | [endpoint][endpoint]        |
| `Runtime` / `AsyncUdpSocket`         | the sans-io host seam a D port replaces                                   | [quic][quic]                |
| path / multipath                     | a QUIC-Multipath path; relay & direct are concurrent paths                | [quic][quic]                |
| QUIC Address Discovery               | STUN replacement; `OBSERVED_ADDRESS` frame                                | [nat-traversal][nat]        |
| NAT traversal (QNT)                  | in-QUIC simultaneous-open hole-punch                                      | [nat-traversal][nat]        |
| `address_lookup`                     | `EndpointId` → addresses directory                                        | [discovery][discovery]      |
| pkarr                                | self-authenticating signed-DNS-packet record format                       | [discovery][discovery]      |
| relay / home relay                   | encrypted-datagram forwarder / lowest-latency relay                       | [relay][relay]              |
| `net_report`                         | connectivity-sensing report (ex-`netcheck`)                               | [net-report][net-report]    |
| `Hash` / BLAKE3                      | 32-byte content address                                                   | [blobs][blobs]              |
| bao / `outboard`                     | verified-streaming tree / stored interior hashes                          | [bao-tree][bao]             |
| `ChunkRanges`                        | RLE sorted set of chunk ranges to fetch/verify                            | [blobs][blobs]              |
| `HashSeq` / `Collection`             | concatenated-hashes blob / named-directory convention                     | [blobs][blobs]              |
| `NamespaceId` / `AuthorId` / `Entry` | doc identity + signed `(ns, author, key)` fact                            | [docs-sync][docs-sync]      |
| HyParView / Plumtree                 | membership / eager-lazy broadcast                                         | [gossip][gossip]            |

---

## Sources

- [`iroh-base/src/key.rs`][key] — `PublicKey` / `EndpointId` / `SecretKey` / `Signature`
- [`iroh-base/src/endpoint_addr.rs`][endpoint-addr] — `EndpointAddr`, `TransportAddr`
- [`iroh/src/socket/mapped_addrs.rs`][mapped] — `EndpointIdMappedAddr` and the ULA scheme
- [`iroh/src/socket.rs`][socket-doc] · [`iroh/src/endpoint.rs`][ep-single] — the `Socket`/`Endpoint` layering
- [`noq/src/runtime/mod.rs`][noq-runtime] — the `Runtime` / `AsyncUdpSocket` seam
- [`noq-proto/src/transport_parameters.rs`][noq-tp] — QAD / MP / QNT transport parameters
- [`iroh-tickets/src/endpoint.rs`][tickets-endpoint] · [`iroh-blobs/src/ticket.rs`][blobs-ticket] · [`iroh-docs/src/ticket.rs`][docs-ticket] — the three tickets
- [`iroh-blobs/src/protocol.rs`][blobs-protocol] · [`hash.rs`][blobs-hash] · [`hashseq.rs`][hashseq] · [`format/collection.rs`][collection] — `Hash`, `ChunkRangesSeq`, `HashSeq`, `Collection`
- [`bao-tree/src/tree.rs`][bt-tree] — `BlockSize`, chunk groups, outboard math
- [`iroh-docs/src/sync.rs`][docs-sync-rs] · [`keys.rs`][docs-keys] — `NamespaceId` / `AuthorId` / `Entry`
- [`iroh-gossip/src/proto.rs`][g-proto] — the sans-io HyParView + Plumtree state machine
- [`iroh/src/address_lookup.rs`][al-trait] · [`iroh-dns/src/pkarr.rs`][dns-pkarr] — `address_lookup`, pkarr
- [`iroh-relay/src/lib.rs`][relay-lib] · [`iroh/src/net_report/report.rs`][nr-report] — relay, `net_report`
- Deep-dives: [Identity & Cryptography][identity] · [Wire Formats & Serialization][wire] · [QUIC Transport][quic] · [Endpoint & Protocol Router][endpoint] · [The Multipath Socket][socket] · [NAT Traversal & Address Discovery][nat] · [The Relay Protocol][relay] · [Address Lookup][discovery] · [Net Report][net-report] · [Blobs][blobs] · [`bao-tree`][bao] · [Document Sync][docs-sync] · [Gossip][gossip] · [Tokio Concurrency Inventory][concurrency] · [D Architecture Migration][d-migration]
- Cross-tree: [event-horizon SPEC][eh-spec] · [async-io survey][async-io]
- External: [RFC 7301 (ALPN)][rfc7301] · [RFC 7250 (raw public keys)][rfc7250] · [RFC 9000 (QUIC)][rfc9000] · [BEP-44][bep44] · [`postcard`][serde-postcard] · [BLAKE3 spec][blake3-spec] · [HyParView paper][hyparview] · [Plumtree paper][plumtree] · [Range-Based Set Reconciliation][meyer] · [draft-seemann-quic-address-discovery][draft-qad] · [draft-seemann-quic-nat-traversal][draft-qnt]

<!-- References -->

[index]: ./index.md
[identity]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[quic]: ./quic-transport.md
[endpoint]: ./endpoint.md
[socket]: ./socket.md
[nat]: ./nat-traversal.md
[relay]: ./relay.md
[discovery]: ./discovery.md
[net-report]: ./net-report.md
[blobs]: ./blobs.md
[bao]: ./bao-tree.md
[docs-sync]: ./docs-sync.md
[gossip]: ./gossip.md
[concurrency]: ./concurrency.md
[d-migration]: ./d-architecture-migration.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[async-io]: ../async-io/index.md
[key]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh-base/src/key.rs
[endpoint-addr]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh-base/src/endpoint_addr.rs
[mapped]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/socket/mapped_addrs.rs
[socket-doc]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/socket.rs
[ep-single]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/endpoint.rs#L861
[al-trait]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/address_lookup.rs
[dns-pkarr]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh-dns/src/pkarr.rs
[nr-doc]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/net_report.rs
[nr-report]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/net_report/report.rs
[relay-lib]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh-relay/src/lib.rs
[noq-runtime]: https://github.com/n0-computer/noq/blob/noq-v1.0.1/noq/src/runtime/mod.rs
[noq-tp]: https://github.com/n0-computer/noq/blob/noq-v1.0.1/noq-proto/src/transport_parameters.rs
[noq-readme]: https://github.com/n0-computer/noq/blob/noq-v1.0.1/README.md
[tickets-lib]: https://github.com/n0-computer/iroh-tickets/blob/v1.0.0/src/lib.rs
[tickets-endpoint]: https://github.com/n0-computer/iroh-tickets/blob/v1.0.0/src/endpoint.rs
[blobs-ticket]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/ticket.rs
[blobs-protocol]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/protocol.rs
[blobs-hash]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/hash.rs
[hashseq]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/hashseq.rs
[collection]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/format/collection.rs
[design-integrity]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/DESIGN.md
[bt-tree]: https://github.com/n0-computer/bao-tree/blob/v0.16.0/src/tree.rs
[docs-sync-rs]: https://github.com/n0-computer/iroh-docs/blob/v0.101.0/src/sync.rs
[docs-keys]: https://github.com/n0-computer/iroh-docs/blob/v0.101.0/src/keys.rs
[docs-ticket]: https://github.com/n0-computer/iroh-docs/blob/v0.101.0/src/ticket.rs
[g-proto]: https://github.com/n0-computer/iroh-gossip/blob/v0.101.0/src/proto.rs
[serde]: https://docs.rs/serde/latest/serde/
[serde-postcard]: https://docs.rs/postcard/latest/postcard/
[rfc7301]: https://datatracker.ietf.org/doc/html/rfc7301
[rfc7250]: https://www.rfc-editor.org/rfc/rfc7250
[rfc9000]: https://datatracker.ietf.org/doc/html/rfc9000
[bep44]: https://www.bittorrent.org/beps/bep_0044.html
[blake3-spec]: https://github.com/BLAKE3-team/BLAKE3-specs/blob/master/blake3.pdf
[hyparview]: https://asc.di.fct.unl.pt/~jleitao/pdf/dsn07-leitao.pdf
[plumtree]: https://asc.di.fct.unl.pt/~jleitao/pdf/srds07-leitao.pdf
[meyer]: https://arxiv.org/abs/2212.13567
[draft-qad]: https://datatracker.ietf.org/doc/draft-seemann-quic-address-discovery/
[draft-qnt]: https://www.ietf.org/archive/id/draft-seemann-quic-nat-traversal-02.html
