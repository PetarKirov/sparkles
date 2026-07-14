# The Relay Protocol

A revised [DERP][derp]: an authenticated WebSocket packet-forwarder that rendezvouses endpoints and blindly relays encrypted [QUIC][quic-transport] datagrams by [`EndpointId`][concepts] until direct [NAT traversal][nat-traversal] succeeds — plus a bare QUIC endpoint that hands each client its observed public address in lieu of STUN.

| Field                 | Value                                                                                                                                                                                                                                                                                                      |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crate(s)              | `iroh-relay` (server + client + QAD); the client reconnect state machine lives in the `iroh` crate under `iroh/src/socket/transports/relay/`                                                                                                                                                               |
| Version               | `1.0.1` (iroh workspace `v1.0.1`, git `22cac742ca`)                                                                                                                                                                                                                                                        |
| Repository            | [`n0-computer/iroh` · `iroh-relay/`][repo]                                                                                                                                                                                                                                                                 |
| Documentation         | [docs.rs/iroh-relay][docs]                                                                                                                                                                                                                                                                                 |
| Protocol id / ALPN    | Relay data path negotiates a WebSocket subprotocol — `iroh-relay-v2` (default) / `iroh-relay-v1` — via `Sec-Websocket-Protocol` at path `/relay`; the co-hosted QUIC Address Discovery endpoint uses ALPN `/iroh-qad/0` ([`http.rs`][http], [`quic.rs`][quic])                                             |
| Approx. size (LoC)    | ~12,300 (`iroh-relay`) + ~2,150 (relay client actor + transport in `iroh`)                                                                                                                                                                                                                                 |
| Category              | Connectivity                                                                                                                                                                                                                                                                                               |
| Upstream spec / draft | No formal spec — a revision of Tailscale's [DERP][derp]. Sub-protocols: [RFC 6455][rfc6455] (WebSocket), [RFC 8305][rfc8305] (Happy Eyeballs), [RFC 5705][rfc5705] (TLS keying-material export), [RFC 9729][rfc9729] (Concealed HTTP Auth, the model for header auth), [QUIC Address Discovery][qad-draft] |

> [!NOTE]
> This page covers the **relay** subsystem in isolation: the wire protocol, the server, the client, and the QUIC Address Discovery (QAD) side-endpoint. How the relay is chosen and multiplexed against direct UDP paths belongs to [The Multipath Socket][socket]; how the observed address feeds hole-punching belongs to [NAT Traversal & Address Discovery][nat-traversal]; how a home relay is selected from measurements belongs to [Net Report][net-report].

---

## Overview

### What it solves

Two peers that both sit behind NATs cannot always reach each other directly, and even when they eventually can, hole-punching takes time and sometimes fails outright. iroh's answer is a **relay**: a public, always-reachable server that both peers connect to and that forwards opaque datagrams between them by destination `EndpointId`. The relay is simultaneously the _rendezvous_ (a fixed address both peers know how to reach) and the _fallback data path_ (traffic flows through it whenever a direct path is unavailable). It is a store-and-forward switch keyed on 32-byte public keys, never a decryptor: the bytes it forwards are already-encrypted QUIC packets from the [noq][quic-transport] stack, so the relay operator learns who talks to whom but never what they say.

The relay carries a **second, unrelated job** in iroh 1.0: **QUIC Address Discovery (QAD)** replaces the STUN protocol that iroh 0.x used to learn a node's public `IP:port`. There is no STUN code anywhere in the crate. Instead the relay binary optionally runs a bare [noq][quic-transport] QUIC endpoint on UDP port `7842` whose only function is to tell each connecting client the public address the server observed, using the QUIC Address Discovery transport extension implemented inside `noq-proto` ([`quic.rs`][quic]). This is a completely separate socket, ALPN, and code path from the WebSocket relay — they merely share a binary and a `RelayUrl`.

### Design philosophy

The relay is deliberately dumb and deliberately blind. From the crate root ([`iroh-relay/src/lib.rs`][lib]):

> _"The relay server helps establish connections by temporarily routing encrypted traffic until a direct, P2P connection is feasible. Once this direct path is set up, the relay server steps back, and the data flows directly between devices. This approach allows Iroh to maintain a secure, low-latency connection, even in challenging network situations."_

Three commitments follow from that, and they shape the whole crate:

1. **The relay never sees plaintext.** It maps a 32-byte destination key to a live connection and copies bytes; congestion control, retransmission, and encryption all live in the peers' QUIC layer. The relay forwards even ECN bits and GSO-style segment sizes verbatim so it does not disturb the end-to-end congestion controller.
2. **Everything rides one commodity transport.** The data plane is nothing but **binary WebSocket messages over HTTP(S)** — no DERP-era magic strings, no bespoke length framing, no server-key frame. This is what lets the identical protocol run unmodified in a browser over `ws_stream_wasm` ([`protos/streams.rs`][protos-streams]).
3. **Structured concurrency throughout.** From [`server.rs`][server]:

   > _"This code is fully written in a form of structured-concurrency: every spawned task is always attached to a handle and when the handle is dropped the tasks abort. So tasks can not outlive their handle."_

   That is a near-verbatim description of an [event-horizon `Scope`][eh-spec], and it makes the server unusually clean to port.

---

## How it works

### Transport stack, bottom-up

A relay connection is a stack of standard layers, each thin:

```text
TCP  →  (optional) TLS/rustls  →  HTTP/1.1  →  RFC 6455 WebSocket upgrade at GET /relay
     →  binary WebSocket messages, one message == exactly one relay frame
```

There is **no separate length-delimited framing**: the WebSocket message boundary _is_ the frame boundary. Each frame begins with a QUIC variable-length integer `FrameType` tag (in practice a single byte, since every defined type is `< 2^6`; [`protos/common.rs`][protos-common]). Non-binary WebSocket messages are skipped with a warning; WebSocket `ping`/`pong`/`close` control frames are handled by the WebSocket layer itself ([`protos/streams.rs`][protos-streams]). Two size ceilings apply: the raw WebSocket payload is capped at `MAX_FRAME_SIZE = 1024 * 1024` (1 MiB, _"also the minimum burst size that a rate-limiter has to accept"_), and a decoded relay frame's content after the tag is capped at `MAX_PACKET_SIZE = 64 * 1024` ([`protos/relay.rs`][protos-relay]).

### The connect + WebSocket upgrade dance

The client (`ClientBuilder::connect`, [`client.rs`][client]) rewrites the relay URL — path becomes `/relay`; scheme `http`→`ws`, `ws`→`ws`, anything else →`wss` — then dials TCP through a **Happy Eyeballs ([RFC 8305][rfc8305]) race** ([`client/tls.rs`][client-tls]): addresses stream in from DNS (`DNS_TIMEOUT = 3 s`), interleaved by address family; the preferred family gets a `RESOLUTION_DELAY = 50 ms` head start; each subsequent attempt starts `CONNECTION_ATTEMPT_DELAY = 250 ms` after the previous (or immediately on a failure); each individual attempt is capped at `DIAL_ENDPOINT_TIMEOUT = 1500 ms` ([`defaults.rs`][defaults]). `TCP_NODELAY` is set. An optional HTTP `CONNECT` proxy with basic-auth passthrough is supported.

On top of the (optionally TLS-wrapped) stream, the client issues an RFC 6455 upgrade request carrying up to three relay-specific headers:

- `Sec-Websocket-Protocol: iroh-relay-v2, iroh-relay-v1` — **version negotiation via WebSocket subprotocols** ([`http.rs`][http], `ProtocolVersion::all_as_header_value`).
- optional `Authorization: Bearer <token>` (in wasm, where browsers cannot set headers, the token moves to a `?token=` query parameter instead — [`http.rs`][http]).
- optional `x-iroh-relay-client-auth-v1` carrying a base64url `KeyMaterialClientAuth` for 0-RTT auth (below).

Automatic WebSocket flushing is disabled (`flush_threshold(usize::MAX)`) so the sender controls batching explicitly ([`client.rs`][client]). The client asserts a `101 Switching Protocols` response and reads the negotiated version back out of the response's `Sec-Websocket-Protocol` header.

The server, on `GET /relay` ([`server/http_server.rs`][http-server]), requires `Upgrade: websocket` and `Sec-WebSocket-Version: 13`, computes the RFC 6455 accept key (SHA-1 of the client key concatenated with the GUID `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`), picks `max()` of the offered protocol versions it supports (the `Ord` impl on `ProtocolVersion` is ordered newest-last precisely so `max` selects the best), spawns an upgrade-wait task, and replies `101`.

### Authentication: two mechanisms

The handshake exists to _"1. Inform the relay of the client's EndpointId 2. Check that the connecting client owns the secret key for its EndpointId … 3. Possibly check that the client has access to this relay"_ ([`protos/handshake.rs`][protos-handshake]). Two mechanisms achieve step 2, and the design is a study in trading round-trips for portability:

1. **Signed TLS keying material (0-RTT, header-based).** Modelled on [RFC 9729][rfc9729] Concealed HTTP Auth using [RFC 5705][rfc5705] exporters. The client exports 32 bytes from the live TLS session (label `b"iroh-relay handshake v1"`, context = its own public-key bytes), signs the **first 16** bytes with its ed25519 secret key, and passes the **last 16** through verbatim so the server can distinguish an exporter mismatch (a broken TLS middlebox) from a genuine bad signature. The `KeyMaterialClientAuth` struct is `postcard`-encoded then base64url-nopad-encoded into the `x-iroh-relay-client-auth-v1` request header — so authentication completes in the very first HTTP request, saving a round-trip. Its own doc-comment states the catch:

   > _"The second way can save a full round trip, because the challenge doesn't have to be sent to the client first, however, it won't always work, as it relies on the keying material extraction feature of TLS, which is not available in browsers … and might break when there's an HTTPS proxy that doesn't properly deal with this TLS feature."_ — [`protos/handshake.rs`][protos-handshake]

2. **Challenge / response (1 extra RTT, in-band frames).** The always-available fallback. The server sends a `ServerChallenge` (16 random CSPRNG bytes). Crucially the client signs **not** the raw challenge but `blake3::derive_key("iroh-relay handshake v1 challenge signature", challenge)`, for domain separation:

   > _"We're signing a key instead of the direct challenge. This gives us domain separation protecting from multiple possible attacks … Assume a malicious relay. If the protocol required the client to sign the challenge directly, this would allow the relay to obtain an arbitrary 16-byte signature, if it maliciously choses the challenge instead of generating it randomly."_ — [`protos/handshake.rs`][protos-handshake]

   The client replies `ClientAuth { public_key, signature }` and the server verifies it.

After authentication succeeds, **authorization** runs: `AccessControl::on_connect(&ClientRequest)` — an async trait object — inspects the endpoint id, negotiated version, URI, headers, and auth token (read from `Authorization: Bearer` first, else the `?token=` query param) and returns `Access::Allow` (server sends `ServerConfirmsAuth`) or `Access::Deny { reason }` (server sends `ServerDeniesAuth` and errors out) ([`server.rs`][server]). An `OnDisconnectGuard` created at admission and dropped when the connection actor ends guarantees exactly one `AccessControl::on_disconnect` per admitted connection. The server binary ships five access backends: `Everyone`, `Allowlist`, `Denylist`, an HTTP-POST hook (posts `X-Iroh-NodeId`, expects `200` + body `"true"`), and shared-token bearer auth ([`main.rs`][main]).

### Steady state: datagrams, batching, keepalive

Once admitted, the protocol is small ([`protos/relay.rs`][protos-relay]): _"server occasionally sends Ping; client responds to any Ping with a Pong; client sends ClientToRelayDatagram or ClientToRelayDatagramBatch; server then sends RelayToClientDatagram or RelayToClientDatagramBatch to recipient; server sends EndpointGone when the other client disconnects."_

The datagram frames are shaped after the QUIC transmit type — they carry an ECN codepoint and, in the batch variant, a `u16` segment size — so the relay forwards GSO-style batches of equal-size segments (last possibly shorter) without disturbing the peers' congestion control:

```rust
// iroh-relay/src/protos/relay.rs — modelled after `noq_proto::Transmit`
pub struct Datagrams {
    /// Explicit congestion notification bits
    pub ecn: Option<noq_proto::EcnCodepoint>,
    /// The segment size if this transmission contains multiple datagrams.
    /// This is `None` if the transmit only contains a single datagram
    pub segment_size: Option<NonZeroU16>,
    /// The contents of the datagram(s)
    pub contents: Bytes,
}
```

Keepalive is a `Ping`/`Pong` pair of 8 opaque bytes each. The server pings every `PING_INTERVAL = 15 s` plus 1–5 s of random jitter — half the QUIC `max_idle_timeout` of 30 s, and jittered _"to avoid all pings being sent at the same time"_ — and resets the interval whenever any frame arrives from the client ([`protos/relay.rs`][protos-relay], [`server/client.rs`][srv-client]).

### Server architecture: registry, per-client actors, broadcast

One accept loop per listener runs in a spawned task holding a `JoinSet` of per-connection tasks ([`server/http_server.rs`][http-server]). Each accepted TCP connection gets Nagle disabled and a `clearable_timeout` of `ESTABLISH_TIMEOUT = 30 s` that aborts connections which fail to complete TLS + WebSocket upgrade + handshake; a `Notify` disarms (does not _complete_) that timeout once the relay protocol takes over. The upgraded stream is wrapped in `RateLimited` (below), then the WebSocket server codec, then `handshake::serverside` + authorization run, then `Clients::register` spawns the per-client actor.

The registry is a pair of concurrent maps ([`server/clients.rs`][clients]):

```rust
// iroh-relay/src/server/clients.rs
pub struct Clients(Arc<Inner>);
struct Inner {
    clients: DashMap<EndpointId, ClientState>,
    /// Map of which client has sent where
    sent_to: DashMap<EndpointId, HashSet<EndpointId>>,
}
struct ClientState { active: Client, inactive: Vec<Client> }
```

Two behaviours here are load-bearing and non-obvious:

- **A duplicate `EndpointId` does not evict the incumbent.** The old connection is demoted onto an `inactive` stack and told `Status::SameEndpointIdConnected`; when the active one disconnects the most-recent inactive is promoted and told `Status::Healthy`. Only when the _last_ connection for a key unregisters does the server fan out `EndpointGone` to every peer recorded in that key's `sent_to` set.
- **Forwarding is lossy and silent.** `Clients::send_packet` does a `try_send` onto the destination's bounded queue (`PER_CLIENT_SEND_QUEUE_DEPTH = 512`). A full queue drops the packet — the sender is _not_ notified on the wire, only server-side metrics tick — because _"we should still keep succeeding to send, even if the packet won't be forwarded by the relay server because the server's send queue for b fills up"_ ([`server.rs`][server]). There is no wire-level NACK anywhere in the protocol; the only negative signal is `EndpointGone`.

Each admitted connection is owned by exactly one per-client **actor** task ([`server/client.rs`][srv-client]) that holds the socket exclusively, drains two bounded `mpsc` queues (a `packet_send_queue` and a `message_send_queue`, both capacity 512), tracks pings, and runs a `biased` `select!` in strict priority order: cancellation → inbound frames → packet queue → message queue → ping-timeout (break, killing the connection) → keepalive tick. Every write is wrapped in a `SERVER_WRITE_TIMEOUT = 2 s` timeout so a stalled client is evicted rather than allowed to back the server up, and the stream is flushed after each loop iteration.

### Rate limiting

Only **client→server receive** traffic is rate-limited, and the limiter sits _below_ the WebSocket codec, inside `poll_read` of the raw byte stream ([`server/streams.rs`][srv-streams]). It is a hand-rolled token `Bucket` (`i64` fill, refill every 100 ms, default burst = `bytes_per_second / 10`); when the bucket runs dry the underlying stream is simply not polled until a `time::sleep_until(refill)` elapses, which applies natural **TCP backpressure** rather than dropping data. The `Bucket` type is `pub` so embedders on custom HTTP servers can rate-limit at the frame layer.

Since commit [`c23446ce2e`][commit-ratelimit] (_"feat(relay): allow updating the per-client rate limit live"_, #4381), the limit is **live-updatable**: the config is distributed through a `tokio::sync::watch` channel checked on every `poll_read` via a cheap atomic `has_changed`, and `RelayService::set_client_rate_limit` reconfigures every current and future connection without dropping any. The connection-_accept_ rate limits (`accept_conn_limit` / `accept_conn_burst`) exist in the config but are explicitly _"Not currently implemented"_ ([`server.rs`][server]).

### QUIC Address Discovery (QAD) — the `quic.rs` role

QAD is **not relay-over-QUIC**; it is STUN's replacement ([`quic.rs`][quic]). The relay binary optionally runs a bare noq QUIC endpoint (default port `7842` — _"QUIC" typed on a phone keypad_) with ALPN `/iroh-qad/0`. The server-side transport config is stripped to the bone and one flag turned on:

```rust
// iroh-relay/src/quic.rs — QAD server transport config
transport_config
    .max_concurrent_uni_streams(0_u8.into())
    .max_concurrent_bidi_streams(0_u8.into())
    // enable sending quic address discovery frames
    .send_observed_address_reports(true);
```

Clients open _zero_ streams; the QUIC transport itself emits the client's observed public address via the address-discovery extension in `noq-proto` (see [QUIC Transport][quic-transport]). The server's accept loop simply waits for the client to close the connection (close code `1`, reason `b"finished"`). The client (`QuicClient`) enables `receive_observed_address_reports(true)`, sets `initial_rtt(111 ms)` (which _"implies a 999ms probe timeout"_ for fast failure), `keep_alive_interval(25 s)`, and `max_idle_timeout(35 s)`, then reads `conn.observed_external_addr()` (a watcher) and `conn.rtt(PathId::ZERO)`, canonicalizing IPv4-mapped IPv6. The observed address then feeds [NAT traversal][nat-traversal] and [net-report][net-report]; how the relay is _chosen_ is out of scope here.

### `RelayMap` and home-relay selection

The set of known relays is a runtime-mutable `RelayMap` — `Arc<RwLock<BTreeMap<RelayUrl, Arc<RelayConfig>>>>` supporting insert/remove/extend at runtime ([`relay_map.rs`][relay-map]). Each `RelayConfig { url, quic: Option<RelayQuicConfig { port }>, auth_token }` records whether that relay offers QAD and on which port; parsing a bare URL assumes QAD on `7842`. Home-relay _selection_ is not in this crate: the socket's [net-report][net-report] produces `report.preferred_relay`, and the client-side `RelayActor` reacts by publishing the new home URL to a `HomeRelayWatch` and sending `SetHomeRelay(bool)` to every `ActiveRelayActor` ([`actor.rs`][actor]).

### The client reconnect state machine

On the client side (in the `iroh` crate, [`actor.rs`][actor]) a single `RelayActor` owns a `BTreeMap<RelayUrl, ActiveRelayHandle>` and a `JoinSet`, with one `ActiveRelayActor` per relay URL in use. Each active actor alternates **Dialing ↔ Connected**: dial with `CONNECT_TIMEOUT = 10 s`; on failure retry with jittered exponential backoff from 10 ms to 16 s, unbounded — but if a connection was ever "established" (≥1 pong received) before failing, the backoff _resets_ and reconnect is immediate. While dialing, queued outbound datagrams are flushed and dropped every `UNDELIVERABLE_DATAGRAM_TIMEOUT = 3 s` (_"3 times the QUIC initial Probe Timeout"_):

> _"We regularly flush the relay_datagrams_send queue so it is not full of stale packets while reconnecting. Those datagrams are dropped and the QUIC congestion controller will have to handle this (DISCO packets do not yet have retry)."_ — [`actor.rs`][actor]

The Connected state pings every 15 s, treats any received frame as a ping-interval reset, sends datagram batches of up to `SEND_DATAGRAM_BATCH_SIZE = 20` items, and enters a **Sending** sub-state while awaiting a sink flush (during which inboxes are not consumed but the receive path stays live). Non-home actors self-terminate after `RELAY_INACTIVE_CLEANUP_TIME = 60 s` without outbound traffic; the home-relay actor never exits. A `CheckConnection { local_ips }` message (delivered on interface change) pings if the connection's local IP is still valid, otherwise forces a reconnect.

### TLS

Client-side trust is `CaTlsConfig` ([`tls.rs`][rtls]): embedded webpki (Mozilla) roots by default, optionally the OS platform verifier, custom roots only, a custom `ServerCertVerifier` callback, or (test only) skip verification. These CAs _"don't need to be trusted for the integrity or authenticity of native iroh connections"_ — the relay only carries already-encrypted QUIC, so relay TLS protects the _metadata channel_, not the payload. Server-side cert acquisition offers Let's Encrypt via `tokio-rustls-acme` (TLS-ALPN-01 answered inline in the accept path), a manual `rustls::ServerConfig`, or a `Reloading` resolver that re-reads PEM cert/key from disk every `DEFAULT_CERT_RELOAD_INTERVAL = 24 h` ([`server/resolver.rs`][resolver]).

---

## Analysis

### Wire format & framing

Every relay frame rides inside one binary WebSocket message; the message boundary is the frame boundary. A frame is `varint(FrameType) ‖ payload`. All 14 frame types are `< 2^6`, so the tag is one byte in practice. Frame ids 0–3 are handshake-only; the data plane starts at 4 ([`protos/common.rs`][protos-common]):

```rust
// iroh-relay/src/protos/common.rs — #[repr(u32)], #[non_exhaustive]
pub enum FrameType {
    ServerChallenge = 0,            ClientAuth = 1,
    ServerConfirmsAuth = 2,         ServerDeniesAuth = 3,
    ClientToRelayDatagram = 4,      ClientToRelayDatagramBatch = 5,
    RelayToClientDatagram = 6,      RelayToClientDatagramBatch = 7,
    EndpointGone = 8,               Ping = 9,   Pong = 10,
    Health = 11,   // REMOVED since relay-protocol-v2, use Status
    Restarting = 12,
    Status = 13,   // added in iroh-relay-v2
}
```

Byte layouts after the varint tag ([`protos/relay.rs`][protos-relay]):

| Frame                            | Layout after tag                                                                      |
| -------------------------------- | ------------------------------------------------------------------------------------- |
| `ClientToRelayDatagram` (4)      | 32 B dst `EndpointId` ‖ 1 B ECN ‖ contents                                            |
| `ClientToRelayDatagramBatch` (5) | 32 B dst ‖ 1 B ECN ‖ `u16` BE segment size ‖ contents (n segments, last may be short) |
| `RelayToClientDatagram` (6)      | 32 B src `EndpointId` ‖ 1 B ECN ‖ contents                                            |
| `RelayToClientDatagramBatch` (7) | 32 B src ‖ 1 B ECN ‖ `u16` BE segment size ‖ contents                                 |
| `EndpointGone` (8)               | 32 B `EndpointId` (exactly)                                                           |
| `Ping` (9) / `Pong` (10)         | exactly 8 opaque bytes                                                                |
| `Health` (11, v1 only)           | UTF-8 `problem` string (rest of frame)                                                |
| `Restarting` (12)                | `u32` BE `reconnect_in` ms ‖ `u32` BE `try_for` ms                                    |
| `Status` (13, v2 only)           | 1 B discriminant: `0` = Healthy, `1` = SameEndpointIdConnected, `n` = Unknown(n)      |

The single-datagram frames (4/6) carry _no_ segment-size field; the batch-vs-single distinction is the frame type itself. The ECN byte is `noq_proto::EcnCodepoint::from_bits` (`0` decodes to `None`). A concrete snapshot from the crate's own tests: a `RelayToClientDatagramBatch` to key `19 7f…`, ECN `Ce = 0x03`, segment size 6, contents `"Hello World!"` serializes to `07 ‖ <32-byte key> ‖ 03 ‖ 00 06 ‖ 48 65 6c 6c 6f 20 57 6f 72 6c 64 21` ([`protos/relay.rs`][protos-relay]).

The four **handshake** frames are different: their payload is [`postcard`][postcard]-encoded ([`protos/handshake.rs`][protos-handshake]). `ServerChallenge` is 16 raw bytes (17-byte frame); `ClientAuth` is a 32 B public key ‖ varint length `0x40` ‖ 64 B signature (98-byte frame); `ServerConfirmsAuth` is an empty unit struct; `ServerDeniesAuth` is a postcard string. The header-based `KeyMaterialClientAuth` is `postcard(32 B pk ‖ 0x40 ‖ 64 B sig ‖ 16 B suffix)` = 113 bytes, base64url-nopad-encoded — it is _not_ a frame, it travels in the `x-iroh-relay-client-auth-v1` request header. All of these are shared with the general [wire-serialization][wire-serialization] survey; postcard's fixed-array-raw / byte-slice-length-prefixed rules are what make the layouts predictable.

Absolute limits: decoded frame content ≤ `MAX_PACKET_SIZE = 65 536` bytes; WebSocket payload ≤ `MAX_FRAME_SIZE = 1 048 576` bytes; datagram frames must be non-empty (rejected at the Sink layer on both sides — [`client/conn.rs`][client-conn], [`server/streams.rs`][srv-streams]).

### Cryptography & identity

The relay is identity-aware but payload-blind. Two independent key systems are in play:

- **Endpoint identity (ed25519).** Every client is its `EndpointId` — a 32-byte ed25519 public key ([Identity & Cryptography][identity-crypto]). The handshake proves ownership by signing either a TLS-exporter value or a `blake3::derive_key`-domain-separated challenge (never the raw 16 bytes, to deny a malicious relay an arbitrary-message signing oracle). `EndpointGone`, the datagram addressing, and the registry are all keyed on this 32-byte value.
- **Transport TLS (rustls / webpki).** Relay TLS authenticates the _relay_, not the peers, and encrypts the metadata channel (who is connecting, auth tokens). Because the relayed payload is already end-to-end-encrypted QUIC, the doc-comment can honestly say the relay's CAs _"don't need to be trusted for the integrity or authenticity of native iroh connections"_ ([`tls.rs`][rtls]).

Two supporting pieces: `blake3::derive_key` provides the challenge domain separation ([`protos/handshake.rs`][protos-handshake]) and — separately — the TLS keying-material export ([RFC 5705][rfc5705]) is the _only_ thing that enables the 0-RTT auth path. A server maintains a `key_cache`: an LRU cache of parsed ed25519 public keys (`DEFAULT_KEY_CACHE_CAPACITY = 1 048 576` entries, _"sized for 1 million concurrent clients … ≈56 MB on 64-bit"_ — [`key_cache.rs`][key-cache], [`defaults.rs`][defaults]) to amortize the cost of re-parsing 32-byte keys off the wire into verified curve points.

### State machines & lifecycle

The subsystem is a lattice of six interacting state machines:

1. **Server connection lifecycle** (per TCP conn): `accepted` → [`clearable_timeout` 30 s armed] → `TLS` → `HTTP/1.1` → on `GET /relay` with valid headers → `101` + upgrade task → `handshake::serverside` → `authorize` → `Clients::register` (timeout disarmed via `Notify`) → per-client actor runs → exit → `unregister` → `OnDisconnectGuard` drop → `on_disconnect`. Any failure before `register` aborts; timeout expiry returns `EstablishTimeout` ([`server/http_server.rs`][http-server]).
2. **Same-`EndpointId` active/inactive stack**: `Vacant → active`; a new conn for the same key demotes `active → inactive` and installs the newcomer, telling the demoted one `Status::SameEndpointIdConnected`; on active disconnect the most-recent inactive is promoted with `Status::Healthy`, or if none remain the entry is removed and `EndpointGone` fans out to `sent_to` peers ([`server/clients.rs`][clients]).
3. **Server per-client actor loop**: a `biased` `select!` — cancel > read > packets > messages > pong-timeout > keepalive-tick — pinging every 15 s + jitter with `MissedTickBehavior::Delay`, interval reset on any inbound frame; a missed pong tears the connection down ([`server/client.rs`][srv-client]).
4. **Client `ActiveRelayActor`**: **Dialing** → **Connected** → **Sending** (a Connected sub-state), with jittered exponential backoff on failure, immediate reconnect after an "established" failure, and self-termination after 60 s of inactivity for non-home relays ([`actor.rs`][actor]).
5. **`PingTracker`** (shared client/server): `idle` –new ping→ `awaiting { data, deadline }`; a matching `pong_received` returns to `idle` and records RTT; the deadline fires `timeout()` once. The next ping's timeout is `3 × last_rtt` clamped to `[500 ms, 5 s]` (`MIN_HEALTH_CHECK_TIMEOUT` / `PING_TIMEOUT` — [`ping_tracker.rs`][ping-tracker]).
6. **Handshake** (both sides): server takes `[header present? verify → done]` else `challenge → await ClientAuth → verify → await access → confirm/deny`; client takes `await first frame → { ServerChallenge → send ClientAuth → await verdict | ServerConfirmsAuth → done | ServerDeniesAuth → error }`, enforcing per-state frame-type expectations via `read_frame(expected_types)` ([`protos/handshake.rs`][protos-handshake]).

Notable dead/vestigial edges: the `Restarting` frame is defined but the current client just logs and ignores it; the `Health` frame is gone in v2 but the server still translates `Status → Health { problem }` when speaking v1 to old clients ([`server/client.rs`][srv-client]).

### Dependencies & coupling

| Crate                                      | Role in the relay                                                        | Port impact                                                                                                                                   |
| ------------------------------------------ | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `tokio-websockets`                         | WebSocket client + server codec, payload limits, flush control, RFC 6455 | **Load-bearing.** The D port must implement RFC 6455 both ways (masking, control frames, 1 MiB payload cap). No `permessage-deflate` is used. |
| `hyper` / `http` / `http-body-util`        | HTTP/1.1 + `Upgrade` mechanics + `CONNECT` proxy                         | Needs a minimal HTTP/1.1 with upgrade — `sparkles:http` territory                                                                             |
| `rustls` / `tokio-rustls` / `webpki-roots` | TLS both sides **plus RFC 5705 keying-material export**                  | The D TLS binding must expose `export_keying_material`, or clients always pay the challenge RTT                                               |
| `tokio-rustls-acme`                        | Server-only ACME / Let's Encrypt (TLS-ALPN-01)                           | Optional for a port; manual / reloading cert modes suffice                                                                                    |
| `noq` / `noq-proto`                        | QAD endpoint, `EcnCodepoint`, `VarInt` codec, observed-address reports   | QUIC varint is trivial; QAD needs the address-discovery extension from [QUIC Transport][quic-transport]                                       |
| `blake3`                                   | `derive_key` for challenge domain separation                             | Must match byte-for-byte (test vectors exist)                                                                                                 |
| `iroh-base` (`ed25519-dalek`)              | `EndpointId` keys, sign / verify                                         | ed25519 required ([Identity & Cryptography][identity-crypto])                                                                                 |
| `postcard` + `serde_bytes`                 | The 4 handshake frames + the auth header                                 | Small: fixed arrays raw, byte slices varint-length-prefixed ([wire-serialization][wire-serialization])                                        |
| `data-encoding`, `sha1`                    | base64url / base64 (WS accept) / base32hex; SHA-1 accept key             | Trivial                                                                                                                                       |
| `dashmap`, `lru`                           | Concurrent registry, key-parse cache                                     | Collapse to plain single-threaded structures under `single` topology                                                                          |
| `n0-future` / `tokio-util`                 | `CancellationToken`, `AbortOnDropHandle`, structured-concurrency glue    | Maps to event-horizon [`Scope`][eh-spec] / `CancelContext`                                                                                    |
| `backon`                                   | Client-side exponential backoff (`iroh` crate)                           | Maps to event-horizon `Schedule.exponential.jittered`                                                                                         |
| `governor`                                 | **Not used** — rate limiting is the hand-rolled `Bucket`                 | Port the ~90-line `Bucket` directly                                                                                                           |

The relay is unusually self-contained on the _protocol_ axis (no bespoke serialization framework, no custom crypto) but heavily coupled on the _transport_ axis: it wants a full HTTP/1.1-with-upgrade stack, a full RFC 6455 WebSocket, and a TLS library that surfaces keying-material export. That is the real porting cost.

### Concurrency & I/O model

The server is a fan of tokio tasks glued by `JoinSet` + `CancellationToken` + `AbortOnDropHandle`, i.e. exactly the structured-concurrency shape the source doc-comment advertises ([full inventory in the Tokio Concurrency page][concurrency]). The salient primitives:

- **One task per layer**: a root supervisor (`relay_supervisor`, first-task-exit stops all), an accept loop per listener, a per-TCP-connection task, and a per-registered-client actor.
- **Two bounded `mpsc` channels per client** (`packet_send_queue`, `message_send_queue`, cap 512 each) fed by `try_send` — the drop-on-full backpressure decision that is the relay's entire QoS policy.
- **`watch` channels** for live state: the rate-limit config, `HomeRelayWatch`, and other `n0_watcher::Watchable` cells (current-value + wake-on-change).
- **Shared concurrent structures**: `DashMap` ×2 for the registry, `Arc<Mutex<lru::LruCache>>` for the key cache, `Arc<RwLock<BTreeMap>>` for the relay map, an `AtomicU64` connection-id counter.
- **Timers everywhere**: 15 s + jitter keepalive, 2 s per-write timeout, 30 s establish timeout, 100 ms bucket-refill sleeps, 24 h cert reload, and the client's exponential-backoff schedule.
- **`spawn_blocking`** appears exactly once, for one-shot cert/key file loading at startup ([`main.rs`][main]) — every hot-path operation is already async I/O.

Every `select!` in the crate is `biased`, so priority order is explicit and deterministic — a property a port must preserve.

### Mapping to event-horizon

The server's shape is almost perfectly fiber-native. The `JoinSet` + `CancellationToken` + `AbortOnDropHandle` triple _is_ an [event-horizon `Scope`][eh-spec]: exit joins children, first failure cancels siblings, `onExit` LIFO teardown. `relay_supervisor` becomes the root scope; each listener is a `spawnDaemon` fiber; each connection and each registered client is a `fork`ed child fiber. Under the default `single` topology there is no `Send`/`Sync` tax and no locks: `DashMap`, `Arc<Mutex<LruCache>>`, `AtomicU64`, and `Arc<RwLock<BTreeMap>>` all collapse to plain hash maps, an `lru` cache, a `size_t`, and a `BTreeMap` owned by one fiber.

The **hard part** is the per-client actor's two `mpsc` queues, because event-horizon has **no cross-fiber channel primitive** ([open issue O20][eh-spec]). The Rust side:

```rust
// iroh-relay/src/server/client.rs — per-client actor (trimmed)
struct Actor<S> {
    stream: RelayedStream<S>,
    timeout: Duration,                                     // 2 s write timeout
    packet_send_queue: mpsc::Receiver<Packet>,            // cap 512
    message_send_queue: mpsc::Receiver<RelayToClientMsg>, // cap 512
    guard: OnDisconnectGuard,
    clients: Clients,
    ping_tracker: PingTracker,
    metrics: Arc<Metrics>,
}
```

A workable single-threaded D shape replaces the two channels with intrusive bounded ring buffers the owning fiber drains, plus a resume hook the registry pokes after a push — preserving the crucial `try_send` semantics (drop-on-full, never block the _sender's_ fiber, since that is the relay's core backpressure decision):

```d
// proposed / sketch — one fiber owns the connection; no Send/Sync, no locks.
struct RelayClientActor
{
    ByteStream        stream;         // the upgraded WebSocket transport
    EndpointId        endpoint;
    PingTracker       pingTracker;
    Duration          writeTimeout;   // 2 s
    // No mpsc: the registry pushes into bounded rings this fiber drains.
    Ring!(Packet, 512)          packets;   // drop-on-full == try_send
    Ring!(RelayToClientMsg, 512) messages;  // Status / EndpointGone
    Waker             resume;         // registry wakes this fiber after a push
}

// Registry-side push, single-threaded: no atomics, no locking.
@safe nothrow
bool trySend(ref RelayClientActor dst, Packet p)
{
    if (dst.packets.full) return false;   // drop; caller "succeeds" anyway
    dst.packets.pushBack(p);
    dst.resume.wake();                    // resume the drain fiber
    return true;
}
```

The `biased select!` loop maps to a fiber that `race`s cancellation, a persistent multishot recv (Tier A) feeding an inbound queue, its two outbound rings, the ping deadline, and the keepalive tick — but with `race` cancelling losers, re-arming the recv each iteration is wasteful, so the recv should be a standing multishot op with the fiber polling the rings between completions ([SPEC § multishot backpressure, open issue O16][eh-spec]). Every timer (keepalive, 2 s write, 30 s establish, refill) becomes an in-ring `TIMEOUT` op or a `withDeadline` cancel scope. The `clearable_timeout` is the interesting one: a `CancelContext` armed at accept and _disarmed_ (not completed) when the upgrade hands off — model it as a deadline you cancel on an event.

Rate limiting sits below the WebSocket decoder; in a completion model apply it _between_ completions. The `Bucket` is a clean `@nogc` value type:

```rust
// iroh-relay/src/server/streams.rs
pub struct Bucket {
    fill: i64,
    max: i64,
    last_fill: time::Instant,
    refill_period: time::Duration,   // 100 ms
    refill: i64,
}
```

```d
// proposed / sketch — @nogc token bucket, consulted between recv completions.
struct Bucket
{
    long      fill;          // current tokens
    long      max;           // burst ceiling
    MonoTime  lastFill;
    Duration  refillPeriod;  // 100 ms
    long      refill;        // tokens added per period

    @safe nothrow @nogc
    bool tryConsume(size_t n, MonoTime now)
    {
        immutable periods = (now - lastFill) / refillPeriod;
        if (periods > 0) { fill = min(max, fill + periods * refill); lastFill += periods * refillPeriod; }
        if (fill < cast(long) n) return false;   // caller parks a timer before resubmitting recv
        fill -= cast(long) n;
        return true;
    }
}
```

After each recv completion of `n` bytes, `bucket.tryConsume(n)`; on refusal, park the read fiber on a `TIMEOUT` until the next refill instant before resubmitting the recv (with provided buffer rings, simply do not resubmit until then). The live-update `watch` channel becomes a plain shared config struct read each iteration — single-threaded, so no atomic `has_changed` is needed. The other `watch` cells (`HomeRelayWatch`, `n0_watcher::Watchable`) have **no** event-horizon equivalent and need a small "current value + list of parked fibers" cell; flag this as a reusable primitive the port must design ([open issue O20][eh-spec]).

Two more mappings: **Happy Eyeballs** is a poster child for `race` + `Schedule` — spawn dial fibers staggered by 250 ms timers inside a scope, first success cancels siblings, each attempt is a `withDeadline` of 1500 ms. The **client reconnect actor** is a `retry` driven by `Schedule.exponential(10.msecs, 16.seconds).jittered`, except the "reset the backoff if we ever received a pong" rule is not a stock combinator and needs custom schedule state. Finally, the RFC 5705 TLS **exporter** is a hard dependency of the fast-path auth: whatever TLS library the D port binds _must_ expose `export_keying_material` on both client and server sessions, or the port can only implement the challenge flow (which is mandatory to support anyway, since plain-HTTP and browser clients cannot export). `spawn_blocking` has no thread-pool analogue and needs none — io_uring covers the one startup file read natively.

---

## Strengths

- **Blind by construction.** The relay never decrypts; it forwards 32-byte-keyed opaque QUIC datagrams (with ECN and segment metadata preserved), so a compromised relay leaks connection metadata but never payload, and it cannot disturb the peers' end-to-end congestion control.
- **One commodity transport.** Binary WebSocket over HTTP(S) with no bespoke framing means the identical protocol runs unmodified in a browser, traverses HTTP proxies, and reuses off-the-shelf TLS/HTTP/WS stacks.
- **0-RTT auth when possible, always-correct fallback.** Signing TLS-exported keying material folds authentication into the first HTTP request; the challenge/response path guarantees the protocol still works where exporters are unavailable.
- **Graceful duplicate handling.** A second connection for the same `EndpointId` parks the incumbent on an inactive stack rather than killing it, smoothing reconnect races.
- **QAD unifies address discovery with the relay.** Reusing a QUIC endpoint's observed-address extension retires an entire second protocol (STUN) and its packet formats.
- **Structured concurrency, stated as such.** The source is written so every task is handle-owned and cancel-on-drop — which ports almost mechanically to fibers + scopes.
- **Live-tunable, backpressure-based rate limiting.** The token bucket applies TCP backpressure instead of dropping, and the limit is now reconfigurable without dropping connections.

## Weaknesses

- **Lossy and silent forwarding.** A full destination queue drops the packet with no wire-level NACK; the only negative signal is `EndpointGone` on full disconnect. Correct for QUIC (which retransmits) but opaque to any non-QUIC embedder.
- **Heavy transport dependency surface.** A port needs a full HTTP/1.1-with-upgrade stack, a full RFC 6455 WebSocket (client _and_ server, masking + control frames), and a TLS library exposing keying-material export — far more infrastructure than the ~1 KB protocol itself.
- **Fixed, undocumented queue depths.** `PER_CLIENT_SEND_QUEUE_DEPTH = 512` is reused for both the packet and message queues with no documented rationale; there is no per-client memory accounting beyond it.
- **Vestigial protocol edges.** `Restarting` is defined but ignored by the current client; `Health`/v1 support lingers with no stated deprecation timeline; `accept_conn_limit` is a config field that does nothing.
- **Single-relay bottleneck for a pair.** Two peers that both fall back to the relay funnel all traffic through one server's per-client 512-slot queues and 2 s write timeout; the relay is a throughput and latency choke until direct connectivity succeeds.
- **`watch`-cell idioms have no simple single-threaded equivalent** — a port must build a bespoke "value + wake-on-change" primitive it does not yet have.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                            | Trade-off                                                                              |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| Relay is payload-blind; forwards opaque QUIC by `EndpointId`   | Operator learns metadata only; peers keep end-to-end encryption + congestion control | Relay cannot dedup, cache, or apply app-layer policy; it is pure switch fabric         |
| Data plane = binary WebSocket over HTTP(S), no custom framing  | Runs in browsers, through proxies; reuses commodity TLS/HTTP/WS stacks               | A port inherits a large transport dependency surface for a tiny protocol               |
| Two auth mechanisms (TLS-exporter 0-RTT + challenge fallback)  | Save a round trip where TLS exporters work; stay correct where they don't (browsers) | Server must implement both; the fast path depends on a niche TLS feature               |
| Sign `derive_key(challenge)`, never the raw challenge          | Domain separation denies a malicious relay an arbitrary-message signing oracle       | One extra BLAKE3 call per handshake; a subtlety a naive port could get wrong           |
| `try_send` with drop-on-full, no wire NACK                     | Sender's fiber never blocks on a slow peer; QUIC will retransmit                     | Silent loss; opaque to non-QUIC embedders; no explicit congestion signal to the sender |
| Duplicate `EndpointId` demotes incumbent to an inactive stack  | Survives reconnect races without dropping the still-working old connection           | Unbounded-ish inactive vector; extra bookkeeping and `Status` signalling               |
| QAD replaces STUN via a QUIC observed-address extension        | Retires a whole second protocol; reuses the QUIC transport already present           | Couples address discovery to a running noq endpoint on a second UDP port (`7842`)      |
| Per-client actor owns the socket; `biased select!`             | One owner ⇒ no socket locking; deterministic priority (cancel > read > send > tick)  | Priority order is load-bearing and must be preserved bit-for-bit by a port             |
| Live-updatable rate limit via `watch`, TCP-backpressure bucket | Reconfigure without dropping connections; backpressure instead of loss               | Needs a wake-on-change cell; a single-threaded port must reinvent that primitive       |
| Structured concurrency (`JoinSet` + `CancellationToken`)       | Handle-owned, cancel-on-drop tasks; clean teardown                                   | Depends on the runtime supplying scope + cancel semantics (event-horizon does)         |

---

## Sources

- [`iroh-relay` on docs.rs (`1.0.1`)][docs]
- [`iroh-relay/src/lib.rs` — crate root; relay purpose, DERP lineage][lib]
- [`iroh-relay/src/protos/common.rs` — `FrameType` enum + varint codec][protos-common]
- [`iroh-relay/src/protos/relay.rs` — frames, `Datagrams`, size limits, snapshot tests][protos-relay]
- [`iroh-relay/src/protos/handshake.rs` — both auth mechanisms, domain separation][protos-handshake]
- [`iroh-relay/src/protos/streams.rs` — `WsBytesFramed` WebSocket adapter][protos-streams]
- [`iroh-relay/src/http.rs` — paths, headers, `ProtocolVersion`][http]
- [`iroh-relay/src/client.rs` — `ClientBuilder`, upgrade dance][client]
- [`iroh-relay/src/client/conn.rs` — `Conn` Stream/Sink][client-conn]
- [`iroh-relay/src/client/tls.rs` — Happy Eyeballs dialer, CONNECT proxy][client-tls]
- [`iroh-relay/src/server.rs` — `ServerConfig`, `AccessControl`, supervisor][server]
- [`iroh-relay/src/server/http_server.rs` — HTTP/WS upgrade, accept path][http-server]
- [`iroh-relay/src/server/client.rs` — per-client actor][srv-client]
- [`iroh-relay/src/server/clients.rs` — registry, packet routing][clients]
- [`iroh-relay/src/server/streams.rs` — `RelayedStream`, `RateLimited`, `Bucket`][srv-streams]
- [`iroh-relay/src/server/resolver.rs` — reloading TLS cert resolver][resolver]
- [`iroh-relay/src/quic.rs` — QUIC Address Discovery server + client][quic]
- [`iroh-relay/src/relay_map.rs` — `RelayMap` / `RelayConfig`][relay-map]
- [`iroh-relay/src/ping_tracker.rs` — `PingTracker`][ping-tracker]
- [`iroh-relay/src/key_cache.rs` — LRU pubkey parse cache][key-cache]
- [`iroh-relay/src/defaults.rs` — ports, timeouts, cache size][defaults]
- [`iroh-relay/src/tls.rs` — `CaTlsConfig` CA-root policy][rtls]
- [`iroh-relay/src/main.rs` — server binary: TOML config, access backends][main]
- [`iroh/src/socket/transports/relay/actor.rs` — client reconnect state machine][actor]
- [`c23446ce2e` — feat(relay): allow updating the per-client rate limit live (#4381)][commit-ratelimit]
- Related iroh pages: [The Multipath Socket][socket] · [NAT Traversal & Address Discovery][nat-traversal] · [Net Report][net-report] · [Address Lookup (Discovery)][discovery] · [QUIC Transport (noq)][quic-transport] · [Identity & Cryptography][identity-crypto] · [Wire Formats & Serialization][wire-serialization] · [Tokio Concurrency Inventory][concurrency]
- External: [DERP (Tailscale)][derp] · [RFC 6455 (WebSocket)][rfc6455] · [RFC 8305 (Happy Eyeballs)][rfc8305] · [RFC 5705 (TLS keying-material export)][rfc5705] · [RFC 9729 (Concealed HTTP Auth)][rfc9729] · [QUIC Address Discovery draft][qad-draft] · [postcard][postcard] · [event-horizon SPEC][eh-spec]

<!-- References -->

[repo]: https://github.com/n0-computer/iroh/tree/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay
[docs]: https://docs.rs/iroh-relay/1.0.1/iroh_relay/
[lib]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/lib.rs
[protos-common]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/protos/common.rs
[protos-relay]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/protos/relay.rs
[protos-handshake]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/protos/handshake.rs
[protos-streams]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/protos/streams.rs
[http]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/http.rs
[client]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/client.rs
[client-conn]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/client/conn.rs
[client-tls]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/client/tls.rs
[server]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/server.rs
[http-server]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/server/http_server.rs
[srv-client]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/server/client.rs
[clients]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/server/clients.rs
[srv-streams]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/server/streams.rs
[resolver]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/server/resolver.rs
[quic]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/quic.rs
[relay-map]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/relay_map.rs
[ping-tracker]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/ping_tracker.rs
[key-cache]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/key_cache.rs
[defaults]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/defaults.rs
[rtls]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/tls.rs
[main]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/main.rs
[actor]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports/relay/actor.rs
[commit-ratelimit]: https://github.com/n0-computer/iroh/commit/c23446ce2e
[socket]: ./socket.md
[nat-traversal]: ./nat-traversal.md
[net-report]: ./net-report.md
[discovery]: ./discovery.md
[quic-transport]: ./quic-transport.md
[identity-crypto]: ./identity-crypto.md
[wire-serialization]: ./wire-serialization.md
[concepts]: ./concepts.md
[concurrency]: ./concurrency.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[derp]: https://github.com/tailscale/tailscale/blob/6ee7bcb4583575f8b2623bc16d55f92737465217/derp/derp.go
[rfc6455]: https://datatracker.ietf.org/doc/html/rfc6455
[rfc8305]: https://datatracker.ietf.org/doc/html/rfc8305
[rfc5705]: https://datatracker.ietf.org/doc/html/rfc5705
[rfc9729]: https://datatracker.ietf.org/doc/rfc9729/
[qad-draft]: https://datatracker.ietf.org/doc/draft-ietf-quic-address-discovery/
[postcard]: https://docs.rs/postcard/latest/postcard/
