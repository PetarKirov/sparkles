# Wire Formats & Serialization

The single reference for how every iroh value becomes bytes: [`postcard`][postcard] over QUIC/WebSocket streams, base32-wrapped tickets, the ALPN registry, and the per-protocol framing that delimits it all.

| Field               | Value                                                                                                                                                                        |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crate(s)            | [`iroh-tickets`][tickets-lib] (string/byte codec), [`iroh-base`][endpoint-addr-rs] (addressing value types), plus `postcard` / `data-encoding` (external, format algorithms) |
| Version             | `iroh-tickets` 1.0.0 · `iroh-base` 1.0.1 (commit `22cac742`) · `postcard` 1.1.3 · `data-encoding` 2.9                                                                        |
| Repository          | [`n0-computer/iroh-tickets`][tickets-repo] · [`n0-computer/iroh`][iroh-repo]                                                                                                 |
| Documentation       | [docs.rs/postcard][postcard] · [docs.rs/iroh-tickets][tickets-docs] · [docs.rs/data-encoding][de-docs]                                                                       |
| ALPN(s)             | This page **is** the registry — see [The ALPN registry](#the-alpn-registry). No single ALPN belongs to the serialization layer.                                              |
| Approx. size (LoC)  | `iroh-tickets` ~345 (`lib.rs` 109 + `endpoint.rs` 235); `iroh-base` addressing ~440 (`endpoint_addr.rs`). The `postcard` codec itself is external.                           |
| Category            | Foundations                                                                                                                                                                  |
| Upstream spec/draft | [postcard wire spec][postcard-wire]; [RFC 4648 §6][rfc4648] (base32); LEB128; the coexisting QUIC varint is [RFC 9000 §16][rfc9000-varint]                                   |

---

## Overview

### What it solves

iroh has exactly **one** application-level serialization format — [`postcard`][postcard], a compact, non-self-describing binary encoding for [`serde`][serde]-derived types — and a small set of conventions layered above it: a canonical string form for shareable addresses ([tickets](#tickets-string-form-and-the-three-wire-layouts)), a registry of [ALPN][alpn] protocol identifiers, and a handful of per-protocol [framing](#the-alpn-registry) rules that carve `postcard` blobs out of a QUIC stream or a [relay][relay] WebSocket message. There is no `protobuf`, no `bincode`, and no JSON on any hot path: a `grep -rln bincode` over every pinned `src/` tree returns nothing, and JSON appears only where a human-readable format is explicitly requested. A D reimplementation therefore needs **one** codec — a `postcard`-compatible reader/writer — plus five table-driven base codecs, and it can reproduce the entire iroh wire surface. This page is the byte-level contract every other protocol page ([blobs][blobs], [docs][docs-sync], [gossip][gossip], [relay][relay], [discovery][discovery]) points back to.

`postcard` is _not_ self-describing: the bytes carry no field names, no type tags, and no lengths beyond what the schema implies. Both peers must agree on the struct layout at compile time. That is a deliberate size win — an [`EndpointId`][identity-crypto] is 32 raw bytes with zero framing overhead — but it means the wire format _is_ the Rust type declaration order, and any D port must freeze the same declaration order to stay byte-compatible.

### Design philosophy

The governing idea is that a wire format should be **the minimal encoding of a fixed schema**, with forward-compatibility bought explicitly (a leading discriminant) rather than paid for on every message (self-description). Every shareable value — a ticket — wraps its `postcard` payload in a single-variant Rust `enum` for exactly this reason ([`iroh-blobs/src/ticket.rs`][blobs-ticket], lines 36–38):

> "In the future we might have multiple variants (not versions, since they might be both equally valid), so this is a single variant enum to force postcard to add a discriminator."

Because a `postcard` `enum` encodes its discriminant as a varint of the _declaration index_, that single variant serializes as a leading `0x00`, which every current ticket carries and which future formats can bump — a de-facto version byte bought for one byte. The same discipline explains the `Slot2`..`Slot7` placeholder variants in the [blobs `Request`][blobs-protocol] enum: they pin `Push` to discriminant `8` and `GetMany` to `9` so the wire numbering never shifts when new request types land.

The [`Ticket`][tickets-lib] trait is explicit that the byte format is a policy choice, not a mandate (`iroh-tickets/src/lib.rs`, lines 17–18):

> "The serialization format for converting the ticket from and to bytes is left to the implementer. We recommend using [postcard] for serialization."

All three concrete tickets take that recommendation, so `postcard` is universal in practice even though the trait is codec-agnostic.

---

## How it works

### The `postcard` data model

`postcard` serializes a `serde` type by walking its fields in declaration order and concatenating each field's encoding with no separators. The primitive rules a codec author must implement:

| Rust type                                | `postcard` encoding                                                        |
| ---------------------------------------- | -------------------------------------------------------------------------- |
| `u8`                                     | one raw byte                                                               |
| `u16` / `u32` / `u64` / `u128` / `usize` | LEB128 varint: little-endian 7-bit groups, MSB of each byte = continuation |
| `i8` … `i128` / `isize`                  | zigzag-mapped to unsigned, then LEB128 varint                              |
| `bool`                                   | one byte, `00` = false / `01` = true                                       |
| `[u8; N]` (fixed array / newtype)        | N raw bytes, **no** length prefix                                          |
| `String`, `Vec<u8>`, `&[u8]`             | varint byte-length, then the raw bytes                                     |
| `Vec<T>`, `BTreeSet<T>`                  | varint element count, then each element                                    |
| `Option<T>`                              | `00` = `None` / `01` + payload = `Some`                                    |
| `enum`                                   | varint discriminant (declaration index), then the variant's payload        |
| `struct` / tuple                         | fields concatenated in declaration order, no tags, no count                |

The varint rule is documented in-tree, in the blobs stream reader ([`iroh-blobs/src/util/stream.rs`][blobs-stream], lines 403–406):

> "In Postcard's varint format (LEB128): Each byte uses 7 bits for the value; The MSB (most significant bit) of each byte indicates if there are more bytes (1) or not (0); Values are stored in little-endian order (least significant group first)."

Two consequences dominate a port:

- **Signed integers use zigzag.** `postcard` maps `i64` through zigzag (`(n << 1) ^ (n >> 63)`) before varint-encoding, so small-magnitude negatives stay short. No iroh wire struct surveyed here actually uses a signed integer — but a general `postcard` codec must implement it.
- **`BTreeSet` order is the wire order.** A `BTreeSet<T>` iterates in `Ord` order, so its serialization is canonical and deterministic. For [`TransportAddr`][endpoint-addr-rs] the derived `Ord` follows variant declaration order — all `Relay` (discriminant 0) sort before `Ip` (1) before `Custom` (2), then by inner value — which is exactly the byte order a ticket must reproduce for stable ticket strings. A D port must sort by `(variant index, payload)` to match.

### Walking a golden vector

The [`EndpointTicket`][tickets-endpoint] test at `iroh-tickets/src/endpoint.rs` (lines 178–234) pins an exact byte sequence for the id `ae58…02b6` with a relay `http://derp.me./` and `127.0.0.1:1024`. Decoding it byte-by-byte exercises most of the model at once:

```text
00                                  TicketWireFormat::Variant1  (enum discriminant, index 0)
ae58ff88…a75502b6                   EndpointId: 32 raw bytes, no length
02                                  addrs: BTreeSet count = 2 (varint)
  00                                  TransportAddr::Relay      (enum discriminant 0)
  10                                    RelayUrl: string length 16 (varint)
  687474703a2f2f646572702e6d652e2f    "http://derp.me./" (16 UTF-8 bytes)
  01                                  TransportAddr::Ip         (enum discriminant 1)
  00                                    SocketAddr::V4          (enum discriminant 0)
  7f000001                              127.0.0.1 (4 address octets)
  8008                                  port 1024 (varint u16: 0x80,0x08 → 0|8<<7 = 1024)
```

Note that the `BTreeSet` emitted `Relay` before `Ip` because the derived `Ord` puts variant 0 first; the port `1024` round-trips through the varint `80 08`; and the `EndpointId` and IP octets carry no length because they are fixed-width. `SocketAddr` is itself an `enum` (`V4` = 0, `V6` = 1); the V4 body is four address octets then the varint port, as shown. The V6 body is the sixteen address octets and the port; std's `serde` additionally serializes the V6 `flowinfo`/`scope_id`, which iroh's vectors do not exercise.

### The single-variant version byte in practice

Because every ticket wraps its payload in a `TicketWireFormat` enum, byte `0x00` opens every ticket. The [`EndpointTicket`][tickets-endpoint] variant is _named_ `Variant1` (signalling "layout differs from the 0.x `Variant0`") yet still encodes as index `0` — `postcard` numbers by declaration position, not by the name — so the leading byte stays `0x00`. Treating that byte as a literal version number is a trap: it is a discriminant that only advances when a genuinely new format variant is added.

---

## Analysis

### Wire format & framing

Everything above QUIC is a `postcard` payload; what differs per protocol is only the **envelope** that delimits it. There are two envelope families: shareable **ticket strings** (base32 of `postcard`), and **stream frames** (length-prefixed or FIN-delimited `postcard` on a QUIC bidi stream, or one WebSocket binary message on a [relay][relay] connection).

#### Tickets: string form and the three wire layouts

A ticket string is `lowercase(KIND) ++ lowercase(BASE32_NOPAD(encode_bytes()))` ([`iroh-tickets/src/lib.rs`][tickets-lib], lines 44–49). `BASE32_NOPAD` is [RFC 4648][rfc4648] base32 (alphabet `A–Z2–7`, no padding); it is emitted lowercase and the decoder uppercases the tail before decoding ([`decode_string`][tickets-lib], lines 57–64). Three `KIND` prefixes are in use: `endpoint`, `blob`, `doc`.

The three tickets do **not** agree on how they encode an address — a real interop hazard:

| Ticket           | `KIND`     | Wire enum  | Address encoding                                                                                 | Citation                          |
| ---------------- | ---------- | ---------- | ------------------------------------------------------------------------------------------------ | --------------------------------- |
| `EndpointTicket` | `endpoint` | `Variant1` | new: `EndpointId` + `BTreeSet<TransportAddr>` (relay, then ip, then custom, folded into one set) | [`endpoint.rs`][tickets-endpoint] |
| `DocTicket`      | `doc`      | `Variant0` | new: `Capability` + `Vec<EndpointAddr>` (each with the unified `BTreeSet<TransportAddr>`)        | [`docs ticket.rs`][docs-ticket]   |
| `BlobTicket`     | `blob`     | `Variant0` | **legacy 0.x**: `EndpointId` + `Option<RelayUrl>` + `BTreeSet<SocketAddr>`                       | [`blobs ticket.rs`][blobs-ticket] |

`BlobTicket` still ships the pre-1.0 address shape and converts at its edges: on encode it takes only `relay_urls().next()` (the first relay) and `ip_addrs()`, so **`Custom` transport addresses and all but the first relay are silently dropped** from a blob ticket ([`ticket.rs`][blobs-ticket], lines 67–79). A port must special-case blob tickets rather than reuse the unified `EndpointAddr` encoder.

The three byte-exact golden vectors (all sharing the id `ae58…02b6`):

```text
EndpointTicket (endpoint.rs:203-233) — relay http://derp.me./ + 127.0.0.1:1024
  00  ae58…02b6  02  00 10 687474703a2f2f646572702e6d652e2f  01 00 7f000001 8008

BlobTicket (blobs ticket.rs:226-233) — id-only, BlobFormat::Raw
  00              Variant0
  ae58…02b6       endpoint id, 32 bytes
  00              relay_url: None            (Option tag)
  00              direct_addresses count = 0 (BTreeSet<SocketAddr>)
  00              format = Raw               (HashSeq = 01)
  0b84…4a072      blake3 hash, 32 bytes

DocTicket (docs ticket.rs:102-109) — read capability, one id-only node
  00              Variant0
  01              Capability = Read          (Write = 00, then a 32-byte NamespaceSecret)
  ae58…02b6       namespace id, 32 bytes
  01              nodes: Vec length 1
  ae58…02b6       EndpointAddr.id
  00              EndpointAddr.addrs: empty set
```

`BlobFormat` is `Raw` = 0 / `HashSeq` = 1 ([`hash.rs`][blobs-hash]); a `Hash` is 32 raw bytes in binary `serde`. A `DocTicket` whose `Capability` is `Write` embeds a **raw 32-byte namespace secret key** in the copy-pasteable string — tickets are bearer credentials, not just addresses ([docs `ticket.rs`][docs-ticket]); the decoder also rejects an empty `nodes` list, the only place any ticket uses the `Verify` stage of [`ParseError`][tickets-lib].

#### The ALPN registry

Every connection is opened under an [ALPN][alpn] byte string; the accepting side's [protocol router][endpoint] dispatches on it. The production identifiers, verbatim with their hex, sweeping all pinned repos:

| ALPN (verbatim)  | Hex                                         | Owner crate              | Notes                                                                          | Citation                          |
| ---------------- | ------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------ | --------------------------------- |
| `DUMBPIPEV0`     | `44 55 4d 42 50 49 50 45 56 30`             | `dumbpipe`               | raw byte pipe; V0 since inception                                              | [`dumbpipe lib.rs`][dumbpipe-lib] |
| `/iroh-bytes/4`  | `2f 69 72 6f 68 2d 62 79 74 65 73 2f 34`    | [`iroh-blobs`][blobs]    | content-addressed transfer; `4` is the current version                         | [`protocol.rs`][blobs-protocol]   |
| `/iroh-sync/1`   | `2f 69 72 6f 68 2d 73 79 6e 63 2f 31`       | [`iroh-docs`][docs-sync] | document range-sync                                                            | [`docs net.rs`][docs-net]         |
| `/iroh-gossip/1` | `2f 69 72 6f 68 2d 67 6f 73 73 69 70 2f 31` | [`iroh-gossip`][gossip]  | epidemic broadcast                                                             | [`gossip net.rs`][gossip-net]     |
| `/iroh-qad/0`    | `2f 69 72 6f 68 2d 71 61 64 2f 30`          | [`iroh-relay`][relay]    | QUIC Address Discovery listener on relays (see [nat-traversal][nat-traversal]) | [`relay quic.rs`][relay-quic]     |
| `/iroh/ssh`      | `2f 69 72 6f 68 2f 73 73 68`                | `iroh-ssh` (third-party) | pins `iroh = "0.94"` — pre-1.0 API, an evolution contrast, not a 1.0 trace     | [`iroh-ssh ssh.rs`][iroh-ssh]     |

Everything else found is example- or test-only and carries no stable protocol id: the example ALPNs (`n0/iroh/transfer/example/1`, `iroh-example/echo/0`, `iroh-example/auth/0`, `0rtt-pingpong`, the post-quantum-TLS demos, `lz4//iroh-bytes/4`), the bench ALPNs (`n0/iroh-bench/0`, `n0/noq-bench/0`), and the test ALPNs (`n0/test/1`, `alpn/1`, `noop`, `TEST`, `my-gossip-alpn`, …). The [iroh-dns-server][discovery] serves standard HTTPS ALPNs `h2` / `http/1.1` for its DoH endpoint, which are not iroh protocols.

Three ALPN-adjacent identifiers a codec needs but which are _not_ ALPNs:

- **Relay protocol version** is negotiated through the WebSocket subprotocol header `Sec-Websocket-Protocol`, values `iroh-relay-v1` / `iroh-relay-v2`; the server picks the best it supports ([`relay http.rs`][relay-http]). V2 removed the `Health` frame (id 11) and added `Status` (id 13). Relay HTTP paths are `RELAY_PATH = /relay` and `RELAY_PROBE_PATH = /ping`.
- **QUIC extension transport parameters** in [`noq-proto`][quic-transport]: `ObservedAddr = 0x9f81a176` and `N0NatTraversal = 0x3d7f91120401` ([`transport_parameters.rs`][noq-tp]) — these ride the QUIC handshake, encoded as [QUIC varints][rfc9000-varint], not `postcard`. See [nat-traversal][nat-traversal].
- **Relay handshake domain-separation strings**: the blake3 `derive_key` context `"iroh-relay handshake v1 challenge signature"` and the TLS-exporter label `"iroh-relay handshake v1"` ([`handshake.rs`][relay-handshake]).

#### Framing conventions per protocol

Above QUIC, the delimiter varies; the payload is nearly always `postcard`:

| Protocol                        | Frame delimiter                                                                           | Payload    | Citation                          |
| ------------------------------- | ----------------------------------------------------------------------------------------- | ---------- | --------------------------------- |
| `dumbpipe`                      | fixed 5-byte `hello` handshake written by the `open_bi()` caller, then a raw byte pipe    | raw        | [`dumbpipe lib.rs`][dumbpipe-lib] |
| blobs `Get`/`GetMany`/`Observe` | 1 raw request-type byte, then a `postcard` body delimited by the **stream FIN**           | `postcard` | [`stream.rs`][blobs-stream]       |
| blobs `Push`                    | 1 raw type byte, then a **`postcard`-varint (LEB128) length prefix** + body               | `postcard` | [`stream.rs`][blobs-stream]       |
| blobs `Observe` response        | `postcard`-varint length prefix per `ObserveItem`                                         | `postcard` | [`protocol.rs`][blobs-protocol]   |
| blobs data phase                | a [`bao-tree`][bao-tree]-encoded verified stream                                          | bao        | [`protocol.rs`][blobs-protocol]   |
| [iroh-docs][docs-sync] sync     | **`u32` big-endian** length prefix + `postcard` `Message`                                 | `postcard` | [`docs codec.rs`][docs-codec]     |
| [iroh-gossip][gossip]           | first frame `StreamHeader { topic_id }`, then **`u32` big-endian** LP + `postcard` frames | `postcard` | [`gossip util.rs`][gossip-util]   |
| [relay][relay] data phase       | one WebSocket binary message per frame: **QUIC-varint** `FrameType` + hand-rolled layout  | manual     | [`relay.rs`][relay-relay]         |
| [relay][relay] handshake        | one WebSocket message: **QUIC-varint** `FrameType` + `postcard` body                      | `postcard` | [`handshake.rs`][relay-handshake] |

Two things to internalize. First, **blobs `Get` requests carry no length prefix at all** — the request body is terminated by the QUIC stream FIN and validated with an explicit `expect_eof`; only `Push` is length-prefixed because its payload follows on the same stream ([`stream.rs`][blobs-stream], the `read_to_end_as` vs `read_length_prefixed` split). Second, **iroh uses two different varint dialects on the wire**: `postcard`'s LEB128 (little-endian 7-bit groups) for serialized structures, and the [QUIC varint][rfc9000-varint] (RFC 9000 §16: big-endian, 2-bit length tag in the top bits) for relay frame types and QUIC-native fields. A port must implement both and never confuse them.

Relay datagram layouts, after the `FrameType` varint (hand-rolled, not `postcard`; see [relay][relay] for detail):

```text
ClientToRelayDatagram:       [32B dst EndpointId][1B ECN][contents…]
ClientToRelayDatagramBatch:  [32B dst EndpointId][1B ECN][2B BE segment_size][contents…]
RelayToClientDatagram(+Batch): the same, with a src EndpointId
EndpointGone: [32B EndpointId]     Ping/Pong: [8B payload]
Restarting: [4B BE reconnect_in ms][4B BE try_for ms]     Status: [1B discriminant]
```

#### Size limits

The bounds a decoder enforces (a hostile peer must not be able to make a reader allocate unboundedly):

| Limit                               | Value                        | Where                                                  | Citation                            |
| ----------------------------------- | ---------------------------- | ------------------------------------------------------ | ----------------------------------- |
| blobs `MAX_MESSAGE_SIZE`            | `1024 * 1024` = 1 MiB        | request read paths (doc comment says "100MiB" — stale) | [`protocol.rs`][blobs-protocol]     |
| docs `MAX_MESSAGE_SIZE`             | `1024 * 1024 * 1024` = 1 GiB | `SyncCodec` decode/encode ("likely too large")         | [`docs codec.rs`][docs-codec]       |
| gossip `DEFAULT_MAX_MESSAGE_SIZE`   | 4096 B                       | config default                                         | [`gossip proto.rs`][gossip-proto]   |
| gossip `MIN_MAX_MESSAGE_SIZE`       | 512 B                        | asserted at state init                                 | [`gossip proto.rs`][gossip-proto]   |
| relay `MAX_PACKET_SIZE`             | `64 * 1024` = 64 KiB         | per relayed frame, both directions                     | [`relay.rs`][relay-relay]           |
| relay `MAX_FRAME_SIZE`              | `1024 * 1024` = 1 MiB        | server rate limiting                                   | [`relay.rs`][relay-relay]           |
| relay `PER_CLIENT_SEND_QUEUE_DEPTH` | 512 packets                  | server per-client buffer                               | [`relay.rs`][relay-relay]           |
| pkarr `MAX_SIGNED_PACKET_SIZE`      | 1104 B (32 + 64 + 8 + 1000)  | [discovery][discovery] signed packet                   | [`pkarr.rs`][pkarr-rs]              |
| pkarr `UserData`                    | ≤ 245 B                      | TXT character-string minus prefix                      | [`endpoint_info.rs`][endpoint-info] |

Application-chosen caps also flow through the codec: sendme passes a `1024 * 1024 * 32` = 32 MiB cap to `get_hash_seq_and_sizes` to bound the hash-seq blob it will read ([`get/request.rs`][blobs-getreq]). `postcard`'s `MaxSize` derive computes a compile-time `POSTCARD_MAX_SIZE` upper bound for small fixed-shape headers, used as a header-length sanity check (e.g. the `u32`-LP example protocol in [`transfer.rs`][transfer-rs]) and for gossip `IHave` chunking.

### Cryptography & identity

The serialization layer transports cryptographic material but performs no cryptography — see [identity-crypto][identity-crypto] for the algorithms. The wire-relevant facts: an [`EndpointId`][identity-crypto] (an ed25519 public key) is **32 raw bytes with no length prefix** in binary `serde`, and a `Signature` is **64 raw bytes** (Rust needs `#[serde(with = "serde_bytes")]` or a hand-written 64-tuple visitor to stop `serde` treating the array as a 64-element sequence, but the _bytes_ are identical, so a D codec simply emits the raw array). Fixed-width raw-byte keys are the reason `postcard` addresses stay compact.

Two subtleties bind identity to serialization. First, iroh key types split their `serde` on `is_human_readable()`: a JSON encoder receives a hex string, a `postcard` encoder receives the raw 32/64 bytes. A D port must mirror this per-type split rather than pick one representation. Second, the string encodings a codec must ship (all table-driven) are: lowercase hex for `Display`; RFC 4648 base32-no-pad for tickets and key `FromStr`; z-base-32 (alphabet `ybndrfg8ejkmcpqxot1uwisza345h769`) for [pkarr][discovery] DNS labels; base32hex (`BASE32_DNSSEC`) for the TLS server name; and `BASE64URL_NOPAD` for the relay auth header. The DISCO sealed-box encryption and x25519 conversion of iroh 0.x are **gone** — no key material rides the wire encrypted at this layer.

### State machines & lifecycle

The serialization layer is almost entirely stateless value code; its only lifecycles are decode pipelines. The ticket decode pipeline is four fail-fast stages mapping one-to-one onto [`ParseError`][tickets-lib] variants: strip the `KIND` prefix → `Kind`; base32-decode (after uppercasing) → `Encoding`; `postcard`-decode the single-variant enum → `Postcard`; semantic check → `Verify` (only `DocTicket`'s non-empty-`nodes` rule). The framed-read lifecycle on a stream is: read the type byte or length prefix → bounded `recv` up to the [size limit](#size-limits) → `postcard`-decode → (for FIN-delimited frames) assert EOF.

The one genuine evolution hazard lives here: `TransportAddr` is `#[non_exhaustive]`, but `postcard` has **no skip-unknown mechanism**. A ticket minted by a future iroh with a fourth `TransportAddr` variant will hard-fail decoding on a 1.0 reader — the discriminant byte will exceed the known range and there is no length to skip past. Forward compatibility is therefore all-or-nothing per format version; the single-variant enum is the only escape hatch, and using it requires bumping the leading discriminant.

### Dependencies & coupling

The wire surface pulls in a deliberately tiny dependency set: `postcard` 1.1.3 (`use-std`), `data-encoding` 2.9 (`+ -macro` for the custom z-base-32 alphabet), `serde` 1 (`derive`) and `serde_bytes` for `[u8; 64]`. The coupling is that **every wire struct is `serde`-derive-bound to `postcard`'s binary profile** — the Rust declaration order is the wire order, so any field reordering is a silent wire break. There is no `bincode`, no `protobuf`, and no `capnp` anywhere in the pinned trees. Two families of struct sit _outside_ `postcard` and are hand-rolled: relay data frames and relay `Status` (byte layouts), and the QUIC-native transport parameters ([`noq-proto`][quic-transport]). A D port replaces `serde`'s reflection with compile-time introspection (`__traits(allMembers)`), so it needs no runtime reflection at all — the wire structs are few and frozen.

### Concurrency & I/O model

This dimension does not apply: the serialization layer is pure, synchronous, allocation-then-copy value code with **no concurrency and no I/O of its own**. Tickets are `Clone`/value types passed by value; encoders build a `Vec<u8>`; decoders parse a `&[u8]`. The framing _helpers_ (`read_varint_u64`, `read_to_end_as`, `read_length_prefixed`) drive an `async` stream, but the parsing itself is a straight-line loop. The absence is itself a finding: unlike [tokio-concurrency][concurrency], nothing in the codec needs a task, a channel, a lock, or a timer. The identity/ticket layer "spawns nothing" and introduces no `select!`, no `tokio::spawn`, no timers — the only shared-state artifacts are elsewhere (a relay `KeyCache` LRU, the pkarr monotonic-timestamp atomic), both of which belong to their own subsystems.

### Mapping to event-horizon

The codec maps onto [`sparkles:event-horizon`][eh-spec] as **pure value code**, not fibers or capabilities — it is `@safe pure nothrow @nogc`-friendly throughout, and needs none of the [async-io][async-io] machinery. The design work is concentrated in four places.

**1. A CTFE-friendly, allocation-free `postcard` codec.** Encode by walking `tupleof` in declaration order; the varint and enum-discriminant rules are a handful of `@nogc` helpers over any owned output buffer (`SmallBuffer` or a [`BufRing`][eh-spec] lease). `POSTCARD_MAX_SIZE` becomes a compile-time `enum` computed by the same introspection.

```rust
// iroh-tickets/src/endpoint.rs:35-43, 129-137 (verbatim, the wire mirror structs)
enum TicketWireFormat { Variant1(Variant1EndpointTicket) }   // discriminant 0x00
struct Variant1EndpointTicket { addr: Variant1EndpointAddr }
struct Variant1EndpointAddr  { id: EndpointId, info: Variant1AddrInfo }
struct Variant1AddrInfo      { addrs: BTreeSet<TransportAddr> }
```

```d
// proposed / sketch — declaration order IS the wire; introspection replaces serde-derive
void encode(T, Buf)(in T value, ref Buf w)
if (isOwnedIoBuf!Buf)
{
    static foreach (i, _; T.tupleof)
        encodeField(value.tupleof[i], w);   // recurse: struct → fields, enum → varint tag + payload
}

void putVarint(Buf)(ref Buf w, ulong v) @safe pure nothrow @nogc
{
    while (v >= 0x80) { w ~= cast(ubyte)(v | 0x80); v >>= 7; }
    w ~= cast(ubyte) v;                      // LEB128: little-endian 7-bit groups, MSB continuation
}
```

**2. The addressing value types and their canonical order.** `EndpointAddr` becomes a plain struct; the `BTreeSet<TransportAddr>` becomes a small sorted array whose comparator is `(variant index, payload)` — reproducing the derived Rust `Ord` gives byte-stable tickets for free.

```rust
// iroh-base/src/endpoint_addr.rs:41-62 (verbatim)
pub struct EndpointAddr {
    pub id: EndpointId,
    pub addrs: BTreeSet<TransportAddr>,
}
#[non_exhaustive]
pub enum TransportAddr {
    Relay(RelayUrl),      // postcard discriminant 0
    Ip(SocketAddr),       // 1
    Custom(CustomAddr),   // 2
}
```

```d
// proposed / sketch
struct EndpointAddr
{
    EndpointId id;                    // ubyte[32]
    SortedSet!TransportAddr addrs;    // canonical Ord = (kind, payload) → wire order for free
}

struct TransportAddr
{
    enum Kind : ubyte { relay = 0, ip = 1, custom = 2 }
    Kind kind;
    union { RelayUrl relay; SocketAddr ip; CustomAddr custom; }
}
```

**3. Ticket string codecs and the fail-fast decode.** hex, two base32 alphabets, z-base-32, and base64url-nopad are one table-driven codec parameterized by alphabet (a template or DbI parameter). Ticket payloads are small with a computable max size (base32 output is `⌈8n/5⌉`), so a stack `SmallBuffer` suffices — no heap. The four-stage decode maps cleanly onto the project's [`Expected`][expected] idiom:

```d
// proposed / sketch — mirrors ParseError { Kind, Encoding, Postcard, Verify }
Expected!(EndpointTicket, ParseError) decodeString(scope const(char)[] s) @safe
{
    // 1. strip lowercase KIND  → ParseError.kind
    // 2. uppercase + BASE32_NOPAD decode → ParseError.encoding
    // 3. postcard-decode single-variant enum → ParseError.postcard
    // 4. semantic verify (e.g. non-empty nodes) → ParseError.verify
}
```

**4. Framing verbs on Tier B fibers.** The `u32`-BE-length + body loops (docs, gossip) are sequenced `recv`s on a fiber — no channel, no task. The FIN-delimited blobs `Get` body needs a new **"read-until-stream-FIN with a byte cap"** verb (bounded by the 1 MiB `MAX_MESSAGE_SIZE`); size a provided-buffer-ring lease to that cap. Two codec pieces have no single-threaded shortcut and must be implemented from scratch: the LEB128 varint reader/writer _and_ a [QUIC varint][rfc9000-varint] reader/writer, since relay framing uses the latter. The `is_human_readable` split becomes a compile-time policy parameter (`HumanReadable` vs `Binary`) chosen at the call site, so JSON and `postcard` share one derive-free codec. Nothing here needs `Send`/`Sync`, a lock, or a `spawn_blocking` substitute — under the `single` topology the entire layer is inline value code on the loop fiber. `Arc<Url>` inside `RelayUrl` is single-threaded refcount noise and collapses to a plain reference-counted string or slice.

---

## Strengths

- **One format, fully specified by three golden vectors.** A `postcard` reader/writer plus five base codecs reproduces the entire iroh wire surface; the endpoint/blob/doc ticket vectors are a ready-made `checkRoundTrip` conformance corpus.
- **Maximally compact.** Fixed-width keys carry no framing (`EndpointId` = 32 bytes flat); varints keep small integers to one byte; no field names or type tags anywhere.
- **Deterministic and canonical.** `BTreeSet` iteration order is the wire order, so identical addressing produces identical bytes — essential for stable, deduplicable tickets.
- **Cheap, explicit forward compatibility.** The single-variant enum buys a version discriminant for exactly one byte, without paying self-description on every message.
- **No reflection required in a port.** The wire structs are few and frozen; compile-time introspection replaces `serde`-derive with zero runtime cost.

## Weaknesses

- **Not self-describing — schema drift is a silent wire break.** Reordering a struct's fields, or renumbering an enum, corrupts the wire with no error at the type level. The `Slot2`..`Slot7` placeholders exist solely to defend against this.
- **`#[non_exhaustive]` + no skip-unknown = brittle evolution.** A future `TransportAddr` variant hard-fails decoding on older readers; there is no partial-parse path.
- **Three tickets, two address encodings.** `BlobTicket`'s legacy `Variant0` layout silently drops `Custom` transports and extra relays, so a port cannot use one address encoder everywhere.
- **Two varint dialects coexist.** `postcard` LEB128 and QUIC varint sit side by side (blobs `Push` vs relay frame types); confusing them is an easy, silent bug.
- **A misleading "version byte."** The leading `0x00` is an enum discriminant, and `EndpointTicket`'s variant is _named_ `Variant1` while encoding as `0` — a trap for anyone reading the first byte as a version number.
- **Stale invariants in comments.** The blobs `MAX_MESSAGE_SIZE` doc says "100MiB" but the constant is 1 MiB; trust the constant, not the prose.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                 | Trade-off                                                                                   |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `postcard` everywhere (no `protobuf`/`bincode`/JSON on hot paths) | Compact, `serde`-native, minimal codec surface; one format for the whole stack            | Not self-describing; the Rust declaration order _is_ the wire contract and must be frozen   |
| Wrap every ticket in a single-variant enum                        | A one-byte leading discriminant gives explicit, cheap forward compatibility               | The byte reads like a version number but is an enum index; `Variant1` still encodes as `0`  |
| `BTreeSet` for address sets (canonical `Ord` order)               | Deterministic, deduplicated, byte-stable ticket output                                    | A port must reproduce the derived `Ord` exactly (variant index, then payload)               |
| Fixed `[u8; N]` for keys/hashes/signatures, no length prefix      | Zero framing overhead on the most common fields                                           | The decoder must know each field's width from the schema; no self-checking                  |
| Keep `BlobTicket` on the legacy 0.x address layout                | Old `blob…` tickets keep working across the 1.0 restructure                               | Silently drops `Custom` transports and extra relays; a second address encoder to maintain   |
| FIN-delimit blobs `Get` (length-prefix only `Push`)               | The QUIC stream end is a free frame boundary; no length to compute for the common request | Needs an `expect_eof` check and a "read-until-FIN with cap" reader distinct from LP readers |
| Two varint dialects (`postcard` LEB128 + QUIC varint)             | Each layer reuses its own ecosystem's native encoding                                     | A port implements and must never confuse both; relay framing crosses the boundary           |
| `is_human_readable` split (hex in JSON, raw bytes in `postcard`)  | One `serde` impl serves both a debuggable text form and a compact binary form             | Every key/ticket type carries two representations a port must mirror                        |

---

## Sources

- [`iroh-tickets/src/lib.rs`][tickets-lib] — the `Ticket` trait, `ParseError`, string codec
- [`iroh-tickets/src/endpoint.rs`][tickets-endpoint] — `EndpointTicket`, wire mirror structs, golden vector
- [`iroh-blobs/src/ticket.rs`][blobs-ticket] — `BlobTicket`, legacy address layout, golden vector
- [`iroh-blobs/src/protocol.rs`][blobs-protocol] — blobs ALPN, `Request` enum, `MAX_MESSAGE_SIZE`
- [`iroh-blobs/src/util/stream.rs`][blobs-stream] — LEB128 varint reader, FIN-delimited vs length-prefixed framing
- [`iroh-base/src/endpoint_addr.rs`][endpoint-addr-rs] — `EndpointAddr`, `TransportAddr`, `CustomAddr`
- [`iroh-docs/src/net/codec.rs`][docs-codec] · [`iroh-docs/src/ticket.rs`][docs-ticket] — docs framing + `DocTicket`
- [`iroh-gossip/src/net/util.rs`][gossip-util] · [`iroh-gossip/src/proto.rs`][gossip-proto] — gossip framing + size limits
- [`iroh-relay/src/protos/`][relay-relay] — relay frame ids, datagram layouts, handshake
- [`noq-proto/src/transport_parameters.rs`][noq-tp] — QUIC extension transport-parameter ids
- [postcard wire spec][postcard-wire] · [RFC 4648 §6 (base32)][rfc4648] · [RFC 9000 §16 (QUIC varint)][rfc9000-varint]
- Related pages: [Identity & Cryptography][identity-crypto] · [QUIC Transport (noq)][quic-transport] · [Endpoint & Protocol Router][endpoint] · [Blobs][blobs] · [bao-tree][bao-tree] · [Document Sync][docs-sync] · [Gossip][gossip] · [Relay][relay] · [Discovery][discovery] · [NAT Traversal][nat-traversal] · [Tokio Concurrency Inventory][concurrency] · [Concepts][concepts] · [survey umbrella][index]

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[identity-crypto]: ./identity-crypto.md
[quic-transport]: ./quic-transport.md
[endpoint]: ./endpoint.md
[blobs]: ./blobs.md
[bao-tree]: ./bao-tree.md
[docs-sync]: ./docs-sync.md
[gossip]: ./gossip.md
[relay]: ./relay.md
[discovery]: ./discovery.md
[nat-traversal]: ./nat-traversal.md
[concurrency]: ./concurrency.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[async-io]: ../async-io/index.md
[expected]: ../../guidelines/idioms/expected/index.md
[postcard]: https://docs.rs/postcard/latest/postcard/
[postcard-wire]: https://postcard.jamesmunns.com/wire-format.html
[serde]: https://docs.rs/serde/latest/serde/
[alpn]: https://datatracker.ietf.org/doc/html/rfc7301
[rfc4648]: https://datatracker.ietf.org/doc/html/rfc4648#section-6
[rfc9000-varint]: https://datatracker.ietf.org/doc/html/rfc9000#section-16
[de-docs]: https://docs.rs/data-encoding/latest/data_encoding/
[tickets-docs]: https://docs.rs/iroh-tickets/1.0.0/iroh_tickets/
[tickets-repo]: https://github.com/n0-computer/iroh-tickets
[iroh-repo]: https://github.com/n0-computer/iroh
[tickets-lib]: https://github.com/n0-computer/iroh-tickets/blob/4899684e1209dea29ed28aa2314450927557b037/src/lib.rs
[tickets-endpoint]: https://github.com/n0-computer/iroh-tickets/blob/4899684e1209dea29ed28aa2314450927557b037/src/endpoint.rs
[endpoint-addr-rs]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-base/src/endpoint_addr.rs
[relay-http]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/http.rs
[relay-quic]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/quic.rs
[relay-relay]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/protos/relay.rs
[relay-handshake]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/protos/handshake.rs
[pkarr-rs]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns/src/pkarr.rs
[transfer-rs]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/examples/transfer.rs
[iroh-ssh]: https://crates.io/crates/iroh-ssh
[endpoint-info]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns/src/endpoint_info.rs
[dumbpipe-lib]: https://github.com/n0-computer/dumbpipe/blob/6c4990dc0c49f3c93947ef6ebeafcf846a6532e0/src/lib.rs
[blobs-protocol]: https://github.com/n0-computer/iroh-blobs/blob/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc/src/protocol.rs
[blobs-ticket]: https://github.com/n0-computer/iroh-blobs/blob/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc/src/ticket.rs
[blobs-stream]: https://github.com/n0-computer/iroh-blobs/blob/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc/src/util/stream.rs
[blobs-hash]: https://github.com/n0-computer/iroh-blobs/blob/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc/src/hash.rs
[blobs-getreq]: https://github.com/n0-computer/iroh-blobs/blob/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc/src/get/request.rs
[docs-net]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/net.rs
[docs-codec]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/net/codec.rs
[docs-ticket]: https://github.com/n0-computer/iroh-docs/blob/091e8cac47bbc49cdb84b0bfed227cc163b61dfe/src/ticket.rs
[gossip-net]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/net.rs
[gossip-util]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/net/util.rs
[gossip-proto]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/proto.rs
[noq-tp]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/transport_parameters.rs
