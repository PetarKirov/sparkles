# QUIC Transport (`noq`)

`noq` is n0's maintained fork of [`quinn`][quinn] — a sans-io QUIC v1 state machine (`noq-proto`), a synchronous platform-UDP layer (`noq-udp`), and a thin async façade (`noq`) — extended with QUIC Multipath, QUIC Address Discovery, and an in-QUIC NAT-traversal protocol; it is the single largest dependency a native D port of iroh must replace.

| Field               | Value                                                                                                                                                                                                                                                        |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Crate(s)            | `noq`, `noq-proto`, `noq-udp`                                                                                                                                                                                                                                |
| Version             | `1.0.1` (git tag `noq-v1.0.1`, HEAD `340e9c7`, released 2026-06-29)                                                                                                                                                                                          |
| Repository          | [`n0-computer/noq`][noq-readme]                                                                                                                                                                                                                              |
| Documentation       | [docs.rs/noq][docs-noq] · [docs.rs/noq-proto][docs-noq-proto] · [docs.rs/noq-udp][docs-noq-udp]                                                                                                                                                              |
| ALPN(s)             | none — `noq` is application-agnostic; ALPN is chosen by iroh's [Endpoint][endpoint], not by the transport                                                                                                                                                    |
| Approx. size (LoC)  | `noq-proto` 49,395 (38,221 non-test); `noq` + `noq-udp` 10,563 — ≈48k of protocol logic                                                                                                                                                                      |
| Category            | Foundations                                                                                                                                                                                                                                                  |
| Upstream spec/draft | [RFC 9000][rfc9000]/[9001][rfc9001]/[9002][rfc9002] (QUIC v1); [RFC 9221][rfc9221] (datagrams); [RFC 8899][rfc8899] (DPLPMTUD); drafts: [multipath][draft-multipath], [QAD][draft-qad], [QNT][draft-qnt], [ack-frequency][draft-ackfreq], [BBRv3][draft-bbr] |

> [!NOTE]
> The [NAT-traversal frame semantics][nat-traversal] (`ADD_ADDRESS`/`REACH_OUT`/`REMOVE_ADDRESS`,
> the probe timeline, hole-punch orchestration) live in [NAT Traversal & Address Discovery][nat-traversal].
> This page covers the transport plumbing: how those frames ride the QUIC dataplane, how
> paths are validated, and how the whole state machine is driven.

---

## Overview

### What it solves

iroh's connectivity story is "a QUIC connection to a stable [EndpointId][identity-crypto], no matter
where the peer is or how many network paths reach it." QUIC is the transport that carries that
promise: authenticated, encrypted, multiplexed streams over UDP, with connection identity
decoupled from the 4-tuple so a connection survives NAT rebinds and network changes. iroh needs
three things stock QUIC libraries do not provide together: (1) **multipath**, so one logical
connection can use a direct hole-punched path and a relayed path simultaneously and fail over
between them; (2) **QUIC Address Discovery**, so a peer learns its own public address from the
other end without a separate STUN side-protocol; and (3) **in-QUIC NAT traversal**, replacing
iroh 0.x's DISCO-over-UDP side-channel with `ADD_ADDRESS`/`REACH_OUT` frames carried inside the
encrypted connection itself. `noq` is the fork of [`quinn`][quinn] that adds all three.

Architecturally the decisive property is that the protocol logic is **sans-io**: `noq-proto`
"contains a fully deterministic implementation of QUIC protocol logic. It contains no networking
code and does not get any relevant timestamps from the operating system" ([`noq-proto/src/lib.rs:3-5`][lib-proto]).
Time, randomness, and buffers are all injected; the core is a pure function of `(now, event) →
(transmits, next-deadline)`. That is exactly the shape [`sparkles:event-horizon`][eh-spec] wants to
drive — see [Design philosophy](#design-philosophy) and [Mapping to event-horizon](#mapping-to-event-horizon).

### Design philosophy

The crate is split identically to `quinn` into three layers, and the split is the whole point.
From the `noq-proto` crate root ([`noq-proto/src/lib.rs:1-8`][lib-proto]):

> _"noq-proto contains a fully deterministic implementation of QUIC protocol logic. It contains no
> networking code and does not get any relevant timestamps from the operating system. Most users may
> want to use the futures-based noq API instead. The noq-proto API might be of interest if you want
> to use it from a C or C++ project through C bindings **or if you want to use a different event loop
> than the one tokio provides.**"_

That last clause is the licence for the D port. `noq` (the async crate) exists solely to weld the
sans-io core to `tokio` or `smol`: `Arc<Mutex<State>>` around the protocol machine, a spawned driver
future per endpoint and per connection, and waker maps to bridge `Future`/`Waker` back onto the
poll-based core. **None of that is intrinsic to QUIC.** A D port on event-horizon drives `noq-proto`'s
design directly — one fiber owning the `Connection` value, an in-ring `TIMEOUT` op for its single
collapsed deadline, tier-B `recv`/`send` verbs where `noq` calls `poll_recv`/`poll_send` — and the
two `Mutex<State>` cells, the mpsc channels, the `Notify`s, and the self-wakes all become zero code.

The fork's stated mission ([`README.md:14-21`][noq-readme]):

> _"Noq started out as a fork of the excellent Quinn project. The main focus of development has been
> towards adding support for more QUIC (draft) extensions: QUIC Multipath, QUIC Address Discovery
> (QAD), Using QUIC to traverse Nat's (QNT)."_

Two consequences shape everything downstream. First, a D port targeting interop with iroh 1.0 peers
**cannot skip the extensions**: iroh negotiates multipath, QAD, and QNT via transport parameters at
handshake, and — unlike iroh 0.x — there is no DISCO/STUN fallback if they are absent. Second, the
extensions are not cleanly separable modules; `PathId` plumbing reaches into the packet-number
spaces, the loss recovery, the frame registry, and even the AEAD nonce (see
[Cryptography & identity](#cryptography--identity)).

`noq` sits beside the other async-I/O prior art the Sparkles survey tracks: it is a `tokio`-first
poll-based runtime adapter ([Tokio][tokio]) over a sans-io core, the opposite pole from a
completion-first thread-per-core design ([Glommio][glommio], [Monoio][monoio]). The interesting
observation is that the _core_ is runtime-neutral by construction, so the adapter — not the protocol —
is what event-horizon replaces.

---

## How it works

### The three-crate stack

```text
┌──────────────────────────────────────────────────────────────────────┐
│ noq        async façade: Endpoint / Connection / SendStream / …        │
│            Arc<Mutex<State>> + spawned driver futures + waker maps      │
│            plugs into a runtime via Runtime / AsyncUdpSocket / AsyncTimer│
├──────────────────────────────────────────────────────────────────────┤
│ noq-udp    synchronous platform UDP: GSO / GRO / ECN / pktinfo / cmsg   │
│            UdpSocketState::{send,recv}; Transmit / RecvMeta currency    │
├──────────────────────────────────────────────────────────────────────┤
│ noq-proto  SANS-IO: Endpoint::handle / Connection pump methods          │
│            pure (now, event) → (transmits, deadline); no I/O, no clock  │
└──────────────────────────────────────────────────────────────────────┘
```

`noq-proto` is ~38k non-test lines of pure state machine. `noq-udp` (10k with `noq`) is the only
part that touches sockets, and `noq` is the ~4k-line adapter that a different runtime replaces.

### The platform UDP layer (`noq-udp`)

`UdpSocketState::new` ([`noq-udp/src/unix.rs:69-201`][udp-unix]) takes a borrowed non-blocking socket
and enables every UDP "superpower" the platform offers: `IP_RECVTOS`/`IPV6_RECVTCLASS` (read ECN),
`IP_PKTINFO`/`IPV6_RECVPKTINFO` (report the destination address of received datagrams and select the
source IP on send — load-bearing for multipath), `IP_MTU_DISCOVER=IP_PMTUDISC_PROBE` + `IPV6_DONTFRAG`
(turn fragmentation off; on failure `may_fragment` flips true), and `SOL_UDP/UDP_GRO` (receive
coalescing, `gro_segments=64` on success). **GSO** is probed once per process by a Linux ≥ 4.18
version check plus a trial `UDP_SEGMENT` `setsockopt`, yielding `max_gso_segments=64`; it is then
applied **per transmit** via a `UDP_SEGMENT` control message, never set globally
([`unix.rs:1021-1067`][udp-unix]). A single `sendmsg` carries up to three cmsgs — ECN
(`IP_TOS`/`IPV6_TCLASS`), segment size, and source address (`in_pktinfo`) — in an 88-byte aligned
control buffer (`CMSG_LEN = 88`). Receives use `recvmmsg` with `BATCH_SIZE = 32` on Linux.

The currency types are `Transmit` (an outgoing datagram or GSO batch) and `RecvMeta` (per-buffer
receive metadata):

```rust
// noq-udp/src/lib.rs:95-151 (comments condensed)
pub struct Transmit<'a> {
    pub destination: SocketAddr,
    pub ecn: Option<EcnCodepoint>,
    pub contents: &'a [u8],
    pub segment_size: Option<usize>, // Some => GSO batch of equal-size datagrams
    pub src_ip: Option<IpAddr>,
}
#[non_exhaustive]
pub struct RecvMeta {
    pub addr: SocketAddr,       // source of the datagram(s)
    pub len: usize,             // bytes in the buffer
    pub stride: usize,          // one datagram's size; len may be n*stride under GRO
    pub ecn: Option<EcnCodepoint>,
    pub dst_ip: Option<IpAddr>,
    pub interface_index: Option<u32>,
}
```

Runtime error hardening is pervasive and interop-relevant: `EMSGSIZE` on send is swallowed (expected
for MTU probes); GSO **dynamically self-disables** (drops to `max_gso_segments=1`) on `EIO`/`EINVAL`
from unsupported drivers; and "UDP transmission errors are considered non-fatal because higher-level
protocols must employ retransmits and timeouts anyway" ([`unix.rs:207-210`][udp-unix]). Windows
mirrors the design via `WSASendMsg`/`WSARecvMsg` with `UDP_SEND_MSG_SIZE`/`UDP_RECV_MAX_COALESCED_SIZE`
and `SIO_UDP_CONNRESET`+`SIO_UDP_NETRESET` ioctls; `posix_minimal.rs` is the graceful floor — plain
`send_to`/`recv_from`, no cmsgs.

### The trait seam: `Runtime`, `AsyncUdpSocket`, `AsyncTimer`

`noq/src/runtime/mod.rs` defines the four traits that make the async layer runtime-independent. **This
is precisely where iroh plugs its multipath [Socket][socket] in, and precisely what a D port replaces
with event-horizon.** `Runtime` supplies timers, task spawning, socket wrapping, and — crucially for
deterministic testing — the clock:

```rust
// noq/src/runtime/mod.rs:17-33
pub trait Runtime: Send + Sync + Debug + 'static {
    /// Construct a timer that will expire at `i`
    fn new_timer(&self, i: Instant) -> Pin<Box<dyn AsyncTimer>>;
    /// Drive `future` to completion in the background
    fn spawn(&self, future: Pin<Box<dyn Future<Output = ()> + Send>>);
    /// Convert `t` into the socket type used by this runtime
    fn wrap_udp_socket(&self, t: std::net::UdpSocket) -> io::Result<Box<dyn AsyncUdpSocket>>;
    /// Look up the current time. Allows simulating the flow of time for testing.
    fn now(&self) -> Instant { Instant::now() }
}
```

Sending is deliberately factored into per-task `UdpSender` objects rather than a `poll_send` on the
socket, because "a `poll_send` method on a single object can usually store only one `Waker` at a time,
i.e. allow at most one caller to wait for an event. This method allows any number of interested tasks
to construct their own `UdpSender` object" ([`runtime/mod.rs:48-52`][runtime]). The endpoint driver
and every connection driver each own a `UdpSender` so they can all block on write-readiness concurrently:

```rust
// noq/src/runtime/mod.rs:43-107 (doc comments trimmed)
pub trait AsyncUdpSocket: Send + Sync + Debug + 'static {
    fn create_sender(&self) -> Pin<Box<dyn UdpSender>>;
    fn poll_recv(&mut self, cx: &mut Context<'_>, bufs: &mut [IoSliceMut<'_>],
                 meta: &mut [RecvMeta]) -> Poll<io::Result<usize>>;
    fn local_addr(&self) -> io::Result<SocketAddr>;
    fn max_receive_segments(&self) -> NonZeroUsize { NonZeroUsize::MIN }
    fn may_fragment(&self) -> bool { true }
}
pub trait UdpSender: Send + Sync + Debug + 'static {
    fn poll_send(self: Pin<&mut Self>, transmit: &Transmit<'_>,
                 cx: &mut Context<'_>) -> Poll<io::Result<()>>;
    fn max_transmit_segments(&self) -> NonZeroUsize { NonZeroUsize::MIN }
}
```

iroh implements `AsyncUdpSocket` with its own `Transport` whose `poll_send` demultiplexes
`Transmit.destination` — a _mapped_ fake-IPv6 address — into a real UDP socket, a [relay][relay]
connection, or a custom transport, and whose `local_addr` fabricates a `DEFAULT_FAKE_ADDR` when only
relay transports exist ([`iroh/src/socket/transports.rs`][iroh-transports]). So the seam iroh occupies
_is_ the seam a D port occupies; reproducing this interface is reproducing iroh's connection API.

### The sans-io core: six pump methods

Below the seam, `noq-proto` exposes a tiny, purely synchronous surface. `Endpoint::handle` routes an
incoming datagram; `Connection` has exactly six pump methods:

```rust
// noq-proto: the sans-io Connection surface (signatures)
// noq-proto/src/connection/mod.rs:460,470,488,1018,2183,2394
impl Connection {
    fn handle_event(&mut self, event: ConnectionEvent);              // feed a routed datagram/rebind
    fn handle_timeout(&mut self, now: Instant);                      // a deadline fired
    fn poll_transmit(&mut self, now: Instant, max_datagrams: usize,
                     buf: &mut Vec<u8>) -> Option<Transmit>;         // produce one datagram/GSO batch
    fn poll_timeout(&mut self) -> Option<Instant>;                   // single collapsed next deadline
    fn poll(&mut self) -> Option<Event>;                             // application events (poll-pull)
    fn poll_endpoint_events(&mut self) -> Option<EndpointEvent>;     // CID needs, draining/drained
}
```

The endpoint side is equally spare. A single `handle` method takes the routed datagram and returns an
`Option<DatagramEvent>`; `connect`/`accept`/`refuse`/`retry`/`ignore` drive lifecycle. `DatagramEvent`
is the routing verdict:

```rust
// noq-proto/src/endpoint.rs:1220-1227
pub enum DatagramEvent {
    ConnectionEvent(ConnectionHandle, ConnectionEvent), // redirect to a Connection
    NewConnection(Incoming),                            // may start a new Connection
    Response(Transmit),                                 // stateless response from the endpoint
}
```

A `FourTuple` is deliberately a _two_-tuple — remote `SocketAddr` plus an optional local IP, no local
port, because "when we send, we can only specify the `src_ip`, not the source port"
([`noq-proto/src/lib.rs:371-380`][lib-proto]) — with IPv6 flowinfo and (usually) scope_id normalized
away so path-identity comparisons are stable.

### Streams, flow control, and datagrams

Stream data never crosses a channel: the mpsc channels between drivers carry only _events_; payload
bytes go straight into the shared `proto::Connection` under the mutex. Each send-stream owns a
`SendBuffer` ([`send_buffer.rs`][send-buffer]) — a base offset, a `VecDeque<Bytes>` of frozen segments,
and a `BytesMut last_segment` that coalesces writes ≤ `MAX_COMBINE = 1452` bytes; larger `Bytes` are
stored zero-copy. Its `poll_transmit(max_len)` is the only scheduler: lost ranges (`retransmits:
ArrayRangeSet`) are served before fresh `unsent..offset()` data. The send half is a three-state
machine — `Ready`, `DataSent{finish_acked}`, `ResetSent` ([`send.rs:293-301`][streams-send]) — with a
non-obvious rule: a peer `STOP_SENDING` only records `stop_reason` and emits an event; it does **not**
change the send state. The _application_ is expected to call `reset()` in response, which the async
layer does on `SendStream` drop.

The receive half reassembles into an `Assembler` ([`assembler.rs`][assembler]): a `BinaryHeap<Buffer>`
ordered min-offset-first, with an over-allocation defence because chunks refcount-pin their decrypted
packet buffers. When over-allocation exceeds `max(32768, buffered * 3/2)` the heap is defragmented into
fresh contiguous buffers. Reading happens through a `Chunks` guard that _removes_ the `Recv` from the
map for the duration of the read, so state cannot change mid-read; its `finalize()` (run by `Drop`)
issues connection flow-control credit exactly once. Per-stream flow control re-announces `MAX_STREAM_DATA`
when the window has moved ≥ 1/8 of `stream_receive_window` (default 1,250,000 bytes); **connection-level
flow control is disabled by default** — `receive_window` defaults to `VarInt::MAX` and the `MAX_DATA`
emitter goes silent above `VarInt::MAX`, so only the 1.25 MB per-stream window and the 10 MB local
`send_window` throttle ([`config/transport.rs:545-601`][cfg-transport]).

Unreliable [RFC 9221][rfc9221] `DATAGRAM` frames ([`datagrams.rs`][datagrams]) are queued in
`VecDeque`s; the receive queue drops _oldest_ silently when full, and `Event::DatagramReceived` fires
only on the empty→non-empty edge, so an application must drain exhaustively per event.

### Loss recovery, congestion control, and MTU discovery

All recovery and congestion state is **per-path** — one `RttEstimator`, `Box<dyn Controller>`, `Pacer`,
`MtuDiscovery`, and `InFlight` counter per `PathData` ([`paths.rs:162-286`][paths]). RTT is textbook
[RFC 6298][rfc6298]/[9002][rfc9002] (7/8 smoothed, 3/4 variance); `pto_base() = srtt + max(4*rttvar,
TIMER_GRANULARITY)` with `TIMER_GRANULARITY = 1ms`. Loss detection ([`mod.rs:3253-3352`][conn-proto])
is the RFC 9002 §6.1 dual threshold — `packet_threshold = 3` or `time_threshold = 9/8·RTT`.

`noq` deviates hardest from `quinn` in **PTO backoff**: instead of unbounded `pto * 2^n` exponential
backoff it computes an _interval-capped_ backoff — each doubling step is limited to at most
`max_interval` more than the previous deadline, where `max_interval` is `MAX_PTO_INTERVAL = 2s` normally
(`1s` under short idle timeouts, `1.5*srtt` on links with `srtt > 1333ms`)
([`mod.rs:3539-3634`][conn-proto]). With iroh's default 30s idle timeout, a stalled connection therefore
sends tail-loss probes at least every ~2s indefinitely rather than backing off toward the idle timeout.

Three congestion controllers ship. **Cubic is the default** — `CubicConfig::default()`
([`config/transport.rs:581`][cfg-transport]), and iroh does not override it — with NewReno and an
experimental **BBRv3** ([draft-ietf-ccwg-bbr-05][draft-bbr]) available; the widely-repeated claim that
"iroh runs BBR" is wrong at this pin. BBRv3 ([`bbr3/mod.rs`][bbr3], 1,743 lines) is a fresh
implementation keeping its own shadow packet ledger for delivery-rate sampling, with a
Startup → Drain → ProbeBw ⟲ / ProbeRtt state machine. The `Controller` trait is 13 hooks
([`congestion.rs:17-124`][congestion]); anti-amplification, MTU updates, and ECN all feed through it.

MTU discovery is [DPLPMTUD, RFC 8899][rfc8899] ([`mtud.rs`][mtud]): a per-path binary search from
`INITIAL_MTU = 1200` toward `min(1452, peer max_udp_payload_size)`, probes being lone padded PING
datagrams (+ `IMMEDIATE_ACK` if the peer supports ack-frequency, converging at RTT speed). A
`BlackHoleDetector` collapses `current_mtu` back to 1200 after > 3 "suspicious" loss bursts — bursts
whose smallest packet exceeds both `min_mtu` and any more-recently-acked packet size.

### Multipath, connection IDs, and packetization

Multipath is negotiated only when both sides send the `initial_max_path_id` transport parameter and the
handshake completes. A `PathId` (varint `u32`) names a **QUIC-Multipath packet-number space** — its own
packet numbers, ACK state, dedup window, and loss timers — while a `PathData` names a **4-tuple in use**
— RTT, congestion controller, pacer, MTU, anti-amplification counters, validation state. One `PathId`
can migrate across 4-tuples (successive `PathData` _generations_); every `SentPacket` records its
`path_generation` so ACK/loss accounting attributes to the correct controller across migrations
([`paths.rs:138-153`][paths]):

> _"With QUIC-Multipath a path is identified by a `PathId` … a single QUIC-Multipath path can migrate to
> a different 4-tuple … There are thus two states we keep for paths: `PacketNumberSpace` … which remains
> in place across path migrations … `PathData`: The state we keep for each unique 4-tuple within a space."_

Path scheduling is a **strict two-tier priority, not a spraying scheduler**. `poll_transmit` walks the
`paths: BTreeMap<PathId, PathState>` in ascending `PathId` order (the ordering _is_ the policy) and
sends on the lowest-`PathId` validated `Available` path that is not congestion/pacing/amplification
blocked; `Backup` paths carry data only when no `Available` path exists ([`paths.rs:1022-1031`][paths]):

> _"Paths marked with as available will be used when scheduling packets. If multiple paths are available,
> packets will be scheduled on whichever has capacity. … Paths marked as backup will only be used if
> there are no available paths."_

iroh configures 8 concurrent paths, a 5s heartbeat, and a 15s per-path idle timeout
([`iroh/src/socket.rs`][iroh-socket]). All smarter path selection (RTT-weighting, failover policy)
lives above `noq`, in iroh's [Socket][socket] remote-state actor.

Connection IDs are per-`PathId` in both directions. Locally, the _endpoint_ owns CID generation
(`NeedIdentifiers → NewIdentifiers`), issuing `min(peer active_connection_id_limit, LOCAL_CID_COUNT=12)`
per path and deriving the 16-byte stateless-reset token as `HMAC(reset_key, cid)`. Remotely, a
`CidQueue` is a 5-slot sliding window with one active CID. Packetization runs through `TransmitBuf`
(a GSO batch over the caller's `Vec<u8>`) and `PacketBuilder`, which enforce AEAD budgets before writing,
draw packet numbers via a `PacketNumberFilter` that **deliberately skips numbers at random** (an
optimistic-ACK defence — ACKing a skipped number is a `PROTOCOL_VIOLATION`), pad Initials to
`MIN_INITIAL_SIZE = 1200`, and coalesce ([RFC 9000][rfc9000] §12.2) only on `PathId::ZERO` during the
handshake. Frame emission order within a packet is fixed
([`mod.rs:6061-6540`][conn-proto]) — `HANDSHAKE_DONE`, `PING`, `IMMEDIATE_ACK`, `(PATH_)ACK` per path,
`ACK_FREQUENCY`, path-management frames, NAT-traversal frames, `CRYPTO`, control frames, `DATAGRAM`,
`NEW_TOKEN`, then `STREAM` data last.

### Address validation and anti-replay

Amplification defence is pure byte accounting on `PathData`
([`paths.rs:407-409`][paths]):

```rust
// noq-proto/src/connection/paths.rs:407-409 — the anti-amplification invariant
pub(super) fn anti_amplification_blocked(&self, bytes_to_send: u64) -> bool {
    !self.validated && self.total_recvd * 3 < self.total_sent + bytes_to_send
}
```

The check is enforced only for servers and only at datagram-creation time; any remaining budget admits
one full MTU ([quinn#1082 behaviour][conn-proto]). Two token mechanisms ([RFC 9000][rfc9000] §8.1)
supply validation across the 3× gate: **Retry tokens** (bind ip+port, ~15s lifetime, minted in a Retry
packet — the only token that can _kill_ a handshake, via `INVALID_TOKEN`) and **Validation tokens**
(bind IP only, ~2-week lifetime, minted in `NEW_TOKEN` frames, redeemable in a later connection — every
failure path only degrades to _unvalidated_). Both ride one AEAD-sealed `Token` container with the
nonce appended in the clear. A subtlety a port must reproduce: the server stores _addresses, not tokens_
in its pending `NEW_TOKEN` queue, so a lost `NEW_TOKEN` is retransmitted as a **freshly minted token**
and a client that receives both copies cannot double-spend ([`spaces.rs:570-586`][spaces]).

> [!IMPORTANT]
> **The entire `NEW_TOKEN` half is dormant in stock iroh 1.0.1.** iroh depends on `noq` with
> `default-features = false, features = ["rustls"]`, so the `bloom` feature is off, `BloomTokenLog`
> is not compiled, and `ValidationTokenConfig::default()` degrades to `NoneTokenLog` + `sent: 0`
> ([`config/mod.rs:519-531`][cfg-mod]): default servers send zero `NEW_TOKEN` frames. A D port can
> ship `NoneTokenLog`/`NoneTokenStore` semantics first and stay behaviour-identical to upstream,
> keeping the trait seams. The Retry half (mint/validate) is always live and is _mandatory_ for interop.

---

## Analysis

### Wire format & framing

`noq` speaks [RFC 9000][rfc9000]/[9001][rfc9001]/[9002][rfc9002] QUIC v1 (plus draft versions
`0xff00001d..0xff000022`). Load-bearing constants a port must reproduce byte-for-byte
([`noq-proto/src/lib.rs:350-359`][lib-proto]): `MAX_CID_SIZE = 20`, `RESET_TOKEN_SIZE = 16`,
`MIN_INITIAL_SIZE = 1200`, `INITIAL_MTU = 1200`, `MAX_UDP_PAYLOAD = 65527`, `LOCAL_CID_COUNT = 12`,
`TIMER_GRANULARITY = 1ms`. Integers are QUIC 2-bit-prefix varints (max `2^62−1`, max 8 encoded bytes) —
the same encoding surveyed in [Wire Formats & Serialization][wire-serialization]. `StreamId` bit layout
is `(index << 2) | (dir << 1) | initiator`.

The **frame-type registry carries the fork extensions** ([`frame.rs:41-136`][frame]): standard frames
`0x00`–`0x1e`, plus `ImmediateAck = 0x1f` and `AckFrequency = 0xaf`; **QAD** `ObservedIpv4Addr = 0x9f81a6`
/ `ObservedIpv6Addr = 0x9f81a7`; **[Multipath][draft-multipath]** `PathAck = 0x3e`, `PathAckEcn = 0x3f`,
`PathAbandon = 0x3e75`, `PathStatusBackup = 0x3e76`, `PathStatusAvailable = 0x3e77`,
`PathNewConnectionId = 0x3e78`, `PathRetireConnectionId = 0x3e79`, `MaxPathId = 0x3e7a`,
`PathsBlocked = 0x3e7b`, `PathCidsBlocked = 0x3e7c`; and **n0's NAT traversal** (`AddIpv4Address =
0x3d7f90` … `RemoveAddress = 0x3d7f94`), which the source labels "IROH'S NAT TRAVERSAL" and explicitly
calls "n0's own protocol", _not_ [draft-seemann-quic-nat-traversal][draft-qnt] semantics — see
[NAT Traversal & Address Discovery][nat-traversal].

The **transport-parameter registry** likewise ([`transport_parameters.rs:700-734`][tparams]): standard
`0x00`–`0x10`, `MaxDatagramFrameSize = 0x20` ([RFC 9221][rfc9221]), `GreaseQuicBit = 0x2AB2`
([RFC 9287][rfc9287]), `MinAckDelayDraft07 = 0xFF04DE1B`, plus the negotiation gates `ObservedAddr =
0x9f81a176` (QAD role), `InitialMaxPathId = 0x3e` (multipath), and `N0NatTraversal = 0x3d7f91120401`
(value = `max_remote_nat_traversal_addresses`). The dataplane frame layouts (`STREAM` `0x08`–`0x0f`
with OFF/LEN/FIN bits; `RESET_STREAM` `0x04`; `MAX_DATA` `0x10`; `DATAGRAM` `0x30`/`0x31`) match
[RFC 9000][rfc9000] §19 exactly; the fork changes are additive.

### Cryptography & identity

TLS 1.3 is provided by [`rustls`][rfc9001] (0.23.33 mainline — not a fork) behind a clean `crypto`
seam ([`crypto.rs`][crypto]): a `Session` trait wrapping `read_handshake`/`write_handshake` over
`CRYPTO`-frame bytes, and separate `PacketKey`/`HeaderKey`/`HmacKey`/`HandshakeTokenKey` traits. The
**decisive fork change is that packet protection is path-aware** — `PacketKey::encrypt`/`decrypt` take
a `PathId` ([`crypto.rs:157-175`][crypto]), because QUIC-Multipath separates the AEAD nonce space per
path:

```rust
// noq-proto/src/crypto.rs:157-175
pub trait PacketKey: Send + Sync {
    fn encrypt(&self, path_id: PathId, packet: u64, buf: &mut [u8], header_len: usize);
    fn decrypt(&self, path_id: PathId, packet: u64, header: &[u8], payload: &mut BytesMut)
        -> Result<(), CryptoError>;
    fn tag_len(&self) -> usize;
    fn confidentiality_limit(&self) -> u64;
    fn integrity_limit(&self) -> u64;
}
```

The `path_id` is folded into the nonce _inside_ mainline `rustls` 0.23 via
`encrypt_in_place_for_path(path_id.as_u32(), pn, …)` ([`crypto/rustls.rs:635-657`][crypto-rustls]) —
the nonce bytes never appear in `noq-proto`, so a clean-room D port must source the exact
QUIC-Multipath nonce construction from the [multipath draft][draft-multipath] and `rustls`. A stock
`quinn`/`rustls` `PacketKey` is therefore **not** drop-in.

Beyond packet keys, three more keyed constructions matter: the retry integrity tag (verifies a Retry
packet), the stateless-reset token `HMAC(reset_key, cid)`, and the token AEAD. iroh installs its own
`RustlsTokenKey` (a fixed random 32-byte key with the low 96 bits of the nonce as the IV, run through
the provider's first TLS 1.3 AEAD) — deliberately the construction `noq`'s own `RetryTokenKey`
(HKDF-per-nonce) avoids, and freshly randomized at every `Endpoint::bind`, so **tokens never survive a
process restart**. Randomness is injected throughout (`rng: StdRng` seeded from
`EndpointConfig::rng_seed`) for deterministic replay; a port needs a CSPRNG capability with a
deterministic test double. The peer-identity story — X.509-over-raw-public-keys, the synthetic SNI
`"{base32(endpoint_id)}.iroh.invalid"`, [EndpointId][identity-crypto] ↔ certificate binding — is a TLS
concern documented in [Identity & Cryptography][identity-crypto]; this page stops at the QUIC key seam.

### State machines & lifecycle

The connection lifecycle is `Handshake → Established → Closed → Draining → Drained`
([`state.rs`][state-proto]); `Draining` is reached directly on receiving `CONNECTION_CLOSE` (skipping
`Closed`), and `kill()` jumps straight to `Drained` on idle timeout, stateless-reset receipt, or AEAD
limit — with no wire traffic. Close is sent on exactly **one** path even under multipath, and closing
resets every timer, arming only a single `Close` timer at `3 × max-PTO` per [multipath draft][draft-multipath] §2.6.

The server's incoming-handshake decision is a four-way branch on an `Incoming`: `accept()`, `refuse()`
(sends `CLOSE`), `retry()` (address-validation Retry; errors if a token already validated the address),
or `ignore()` (silent) — and it **implicitly refuses on drop**. The per-`PathId` lifecycle is a
five-state progression — _unknown → open_ (`open_status: Pending`), _→ validated_ (`Sent → Informed` on
a matching on-path `PATH_RESPONSE`, emitting `PathEvent::Established`), _→ abandoned_ (`PATH_ABANDON`),
_→ draining_ (on abandon receipt, `PathDrained` armed at `3×PTO`), _→ discarded_. Critically, even after
a NAT-traversal hole-punch succeeds, the new `PathId` **still undergoes full [RFC 9000][rfc9000] §8.2
on-path validation** with a `3×PTO` deadline before iroh sees `Established` and can promote it to
`Available` (see the [NAT-traversal timeline][nat-traversal]). PathIds are never reused
(`max(max_abandoned, max_used) + 1`), and a remote abandon _increments_ `local_max_path_id`, always
replenishing the peer's path-open credit.

The masterstroke for a driver is **timer collapse**. `noq-proto` internally maintains a `TimerTable` of
7 connection timers (`Idle, Close, KeyDiscard, KeepAlive, PushNewCid, NoAvailablePath,
NatTraversalProbeRetry`) plus 9 per-path timers (`LossDetection, PathIdle, PathValidationFailed,
PathChallengeLost, AbandonFromValidation, PathKeepAlive, Pacing, MaxAckDelay, PathDrained`), keeping 4
paths inline before heap spill ([`timer.rs`][timer]). But `poll_timeout()` reduces _all_ of them to one
earliest `Instant`, and `noq` holds exactly **one** `AsyncTimer`, resetting it only when that value
changes. A port re-arms a single in-ring `TIMEOUT` op — never one timer per space or per stream.

### Dependencies & coupling

`noq-proto` is the load-bearing algorithm — all of QUIC — with a handful of infrastructural deps:

| Crate                             | Depth                         | D-port implication                                                                                                              |
| --------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `noq-proto` (self)                | the algorithm                 | ≈38.2k non-test LoC to reimplement; the big rock                                                                                |
| `rustls` (+ `ring`/`aws-lc-rs`)   | load-bearing (TLS 1.3 + AEAD) | Behind the `crypto` traits; `PacketKey` is **`PathId`-aware**, so the multipath nonce must be ported exactly                    |
| `bytes` (`Bytes`/`BytesMut`)      | load-bearing data model       | Refcounted zero-copy slices pervade stream reads and datagram I/O; the assembler defrag logic exists _only_ because of aliasing |
| `tokio` (`sync`/`io`/`time`/`rt`) | structural (in `noq` only)    | `Notify`/mpsc/watch/broadcast/oneshot — replaced wholesale by event-horizon idioms                                              |
| `socket2`, `libc`/`windows-sys`   | API-surface                   | cmsg/`sendmsg`/`recvmmsg` — ~1–2k LoC of D syscalls per platform                                                                |
| `sorted-index-buffer` (n0)        | load-bearing container        | `sent_packets`/`lost_packets` ordered-by-pn map with range iteration below `largest_acked`                                      |
| `rand` (`StdRng`) / `rand_pcg`    | mixed                         | CSPRNG (pn-skip filter, tokens, CID grease) must be injectable; BBR3 probe jitter can be any PRNG                               |
| `tinyvec`, `rustc-hash`, `slab`   | perf detail                   | `ArrayRangeSet` ≈ `SmallBuffer`; `FxHashMap`; connection-handle arena                                                           |

There is **no external QUIC/CC/recovery library to bind** — BBRv3, Cubic, the pacer, MTUD, the dedup
window, and the reassembler are all in-tree and must be reimplemented. A planning split of the ~38.2k
non-test lines:

| Bucket                             | LoC (approx.) | Contents                                                                                                                                                                       |
| ---------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| RFC-mandatory QUIC v1 core         | ~27–29k       | packets, frames, streams (2,230-line state machine + 846-line assembler + 762-line send buffer), loss/CC (Cubic/NewReno), MTUD (982), pacing (444), endpoint, tokens, TLS glue |
| n0 / draft extensions              | ~6–8k         | multipath machinery (`paths.rs` 1,187 + pervasive `PathId` plumbing), QNT (`n0_nat_traversal.rs` 1,075), QAD (`address_discovery.rs` 73), BBRv3 (`bbr3/` 1,894)                |
| qlog observability (feature-gated) | ~1.5k         | `connection/qlog.rs` + `config/qlog.rs`                                                                                                                                        |

Multipath is **not separable** — `PathId` appears 216 times in the 7,798-line `connection/mod.rs` and
reaches into `spaces.rs`, `frame.rs`, `cid_state.rs`, `packet_crypto.rs`, and the crypto trait. **iroh
couples to `noq` extremely tightly**: `iroh/src/endpoint/quic.rs` re-exports ~25 `noq` types and ~30
`noq_proto` types directly into iroh's public API (149 `noq::` references across 15 iroh modules), so
`noq`'s stream/error/varint types _are_ iroh's. Reimplementing the `noq` surface _is_ reimplementing
iroh's connection API — see [Endpoint & Protocol Router][endpoint].

### Concurrency & I/O model

`noq` (unlike iroh 0.x's actor-based magicsock) uses **no `select!`, no `JoinSet`, no `spawn_blocking`**
anywhere — the drivers are hand-rolled `Future::poll` implementations over two mutex-protected state
cells. All endpoint state lives in one `std::sync::Mutex<State>`; all connection state in another
(optionally a `lock_tracking` wrapper that warns when a lock is held > 1ms). A spawned `EndpointDriver`
future and one `ConnectionDriver` future per connection lock the state on each poll and pump the sans-io
machine; user-facing handles are `Arc` clones that take the same lock. The endpoint↔connection channels
carry only _events_ (datagrams pre-decoded); the full concurrency inventory (20 primitives — two
mutexes, unbounded mpscs, `oneshot`s, `watch` cells, `broadcast(32)` event streams, `Notify`s, per-stream
`FxHashMap<StreamId, Waker>` maps, refcount atomics) is enumerated in [Tokio Concurrency Inventory][concurrency].

Fairness is hand-managed because a `tokio` task must yield voluntarily: the endpoint caps at
`IO_LOOP_BOUND = 160` datagram-batches per poll and an adaptive `WorkLimiter` bounds recv work at
`RECV_TIME_BOUND = 50µs`/cycle ("This helps ensure we don't starve anything when the CPU is slower than
the link"); the connection caps at `MAX_TRANSMIT_DATAGRAMS = 20` and `MAX_TRANSMIT_SEGMENTS = 10` per
poll. When work remains, the driver self-wakes (`cx.waker().wake_by_ref()`) rather than looping.
Stateless endpoint responses are sent best-effort with a hand-rolled noop `Waker` and silently dropped
when the socket is full — deliberate load-shedding, "morally equivalent to the packet getting lost due
to congestion". The I/O model is thus **completion-agnostic readiness**: `noq-udp` does the syscalls
synchronously and the runtime bridges readiness to the sans-io core.

### Mapping to event-horizon

The entire `noq` crate is an adapter from a poll-based sans-io core to work-stealing `tokio`. Under
event-horizon's `single` topology ([spec][eh-spec]) that adapter dissolves. The sans-io _design_ of
`noq-proto` is what a D port keeps; `noq`'s `Arc<Mutex<State>>`, waker maps, `Notify`s, and self-wakes
become zero code because there is no preemption and no cross-thread sharing to guard.

**The `Runtime` trait maps to a capability row, not a trait object.** `Runtime::now` is [`isClock`][eh-spec]
(with `TestClock` giving the same virtual-time determinism `noq` gets via `Runtime::now`);
`new_timer`/`reset` become a single in-ring `TIMEOUT` op keyed on the collapsed `poll_timeout()`
deadline; `spawn` becomes `Scope.spawn`; `wrap_udp_socket` becomes an `isNet` capability. Dispatch is
monomorphized — no vtable:

```rust
// noq: authority arrives as a boxed trait object shared across threads
pub trait Runtime: Send + Sync + Debug + 'static { /* new_timer, spawn, wrap_udp_socket, now */ }
// noq/src/runtime/mod.rs:17-33 (see above)
```

```d
// proposed / sketch — authority is a value row handed to the root fiber;
// dispatch monomorphizes, no Send/Sync/'static, no vtable.
struct QuicEnv(Clock, Net)
if (isClock!Clock && isNet!Net)
{
    Clock clock;   // clock.now() -> MonoTime; TestClock supplies virtual time
    Net   net;     // sendmsg / recvmsg  (needs O19 msghdr support — see below)
    // no `spawn` field: children are opened on the ambient `Scope`
}
```

**Each driver becomes one fiber owning its state by value.** The connection driver's pump sequence
(`process events → transmit → timer → forward events`) maps to a plain fiber loop; the six pump methods
are plain method calls, and the two mutexes vanish:

```rust
// noq: connection state behind a lock, pumped by a spawned Future
pub(crate) struct State {
    pub(crate) inner: proto::Connection,          // the sans-io machine
    driver: Option<Waker>,
    timer: Option<Pin<Box<dyn AsyncTimer>>>,
    blocked_writers: FxHashMap<StreamId, Waker>,  // parked stream ops
    blocked_readers: FxHashMap<StreamId, Waker>,
    sender: Pin<Box<dyn UdpSender>>,
    buffered_transmit: Option<proto::Transmit>,   // stashed when the socket would block
    // ... + oneshots, watches, broadcasts, Notifys
}   // noq/src/connection.rs:1403-1447 (trimmed)
```

```d
// proposed / sketch — one fiber owns the Connection value outright.
// No lock, no Waker maps: parked stream ops are fibers in an intrusive wait-list.
Outcome!void driveConnection(ref QuicEnv env, ref Connection conn, Scope sc)
{
    for (;;)
    {
        while (auto ev = conn.nextInboundEvent())        // plain queue, same thread
            conn.handleEvent(ev);

        Buf dg = env.pool.acquire();                     // pinned, io_uring-registered
        while (auto t = conn.pollTransmit(env.clock.now(), maxDatagrams: 1, dg))
            env.net.sendmsg(t.destination, dg[]).await;  // tier-B verb; parks THIS fiber

        auto deadline = conn.pollTimeout();              // single collapsed Instant
        auto ev = sc.race(env.net.recvReady(),           // whichever fires first
                          env.clock.sleepUntil(deadline)).await;
        if (ev.isTimeout) conn.handleTimeout(env.clock.now());
    }
}
```

**Channels have no v1 equivalent (open issue O20)** but need none _inside_ the proto layer: the
endpoint↔connection mpscs carry events that, on one thread, `Endpoint::handle` can deliver by calling
directly into the target connection's `VecDeque` — `quinn`'s channel hop exists only for `Send`/lock
ordering. `tokio::sync::watch` (observed-address, open-path) and `broadcast(32)` (`path_events`,
`nat_traversal_updates`) also have no direct equivalent; a versioned cell + waiter list and a bounded
per-subscriber ring reproduce the lossy `Lagged(n)` semantics if API compatibility matters. Per-stream
`blocked_writers`/`blocked_readers: FxHashMap<StreamId, Waker>` become a `StreamId → FiberHandle`
table; `Notify::notify_waiters` becomes a wake-all of a parked-fiber list.

**Drop-glue is protocol-visible and must be reproduced deliberately.** `Incoming` drop ⇒ refuse;
`SendStream` drop ⇒ finish-or-reset; `RecvStream` drop ⇒ `stop(0)`; last connection handle drop ⇒
implicit `close(0)`. The peer observes `STOP_SENDING`/`RESET_STREAM`/`CONNECTION_CLOSE`, so a port maps
these to `Scope.onExit` LIFO hooks attached at handle creation — iroh-blobs' "drop-to-finish" provider
behaviour is literally the `SendStream::drop` impl.

**The hard prerequisite is O19 (msghdr-based `sendmsg`/`recvmsg`).** GSO/GRO/ECN/pktinfo all ride
control messages, and multipath _requires_ source-IP selection (pktinfo on send) and destination-IP
reporting (pktinfo on recv). event-horizon v1 lacks msghdr I/O, so wire-compatible transport is blocked
on O19. The mitigation is graceful: `noq-proto` explicitly supports `enable_segmentation_offload=false`
(forcing `max_datagrams = 1`), which removes the entire segment-size/padding-truncation branch — pass
`maxDatagrams: 1` and revisit with O19. Two more items have **no equivalent and need new design**: a
`WallClock` capability beside `isClock` (tokens use `SystemTime`/UNIX time, not `MonoTime`), and a
CSPRNG capability with a deterministic double (for the pn-skip filter and token nonces).

Two D-idiom wins fall out. The recovery/CC subsystem is a pure, allocation-light state machine — ideal
for a `@nogc`-leaning `SumType!(Cubic, NewReno, Bbr3)` in place of `Box<dyn Controller>`, `clone_box`
becoming a struct copy. And the buffer model has a clean choice: `noq`'s recv path _retains_ refcounted
aliases into decrypted packets (hence the assembler defragmenter), but a D port can instead **copy out
of the `Buf` at `STREAM`-frame ingest** into a per-stream buffer, deleting the entire `allocation_size`
bookkeeping and the 32 KiB defrag threshold for one memcpy — likely the right call for v1. See
[D Architecture Migration][d-migration] for the cross-subsystem plan.

---

## Strengths

- **Sans-io core is runtime-neutral by construction.** The one architectural fact that makes a D port
  tractable: no `Future`/`Waker` machinery is intrinsic to the protocol; event-horizon fibers drive the
  same `poll_transmit`/`handle_event`/`handle_timeout` shape directly.
- **Deterministic and testable.** Time, randomness, and buffers are injected; `noq` reproduces its full
  test harness with fake time via `Runtime::now`, exactly what a `TestClock` + `SimNet` gives in D.
- **Timer collapse.** 16 internal timer classes reduce to one `poll_timeout()` deadline and one runtime
  timer — a single in-ring `TIMEOUT` op suffices.
- **Genuine multipath + QAD + QNT** in one negotiated connection, with per-path CC/RTT/MTU and a clean
  `Available`/`Backup` priority — the capability set iroh's whole connectivity model rests on.
- **Battle-tested lineage.** A `quinn` fork inherits a mature, interop-tested QUIC v1 implementation;
  the fork surface is additive extensions, not a rewrite of the core.
- **Careful DoS hardening** throughout: optimistic-ACK pn-skip defence, assembler over-allocation cap,
  3× amplification limit, stateless-reset rate limiting, capped path-response memory.

## Weaknesses

- **Enormous.** ≈38k non-test lines of protocol logic with no external library to lean on — BBRv3,
  Cubic, pacer, MTUD, reassembler, token machinery all in-tree. This is the single largest port item.
- **Extensions are inseparable.** `PathId` pervades the core (216 mentions in one file); a port cannot
  ship "plain QUIC first, multipath later" and still interop with iroh, which negotiates multipath at
  handshake with no fallback.
- **Path-aware AEAD nonce lives in `rustls`, not `noq`.** The exact multipath nonce bytes never appear
  in the readable sources; a clean-room port must derive them from the draft and `rustls` source.
- **Tight iroh coupling.** 149 `noq::` references and ~55 re-exported types mean the transport API and
  iroh's public API are the same surface — you cannot swap the QUIC layer in isolation.
- **`tokio`-shaped concurrency** (`Arc<Mutex>`, mpsc, watch, broadcast, per-stream waker maps) is
  entirely incidental complexity that a single-threaded port must recognize as _removable_, not port.
- **Divergences from `quinn` are undocumented as a set** (pooled `Recv` objects, `sorted-index-buffer`,
  interval-capped PTO, BBRv3, `SendBufferData` coalescing) — a port cannot fully lean on `quinn` docs.
- **Two documented footguns to reproduce or fix**: `Controller::on_ack_frequency_update` is dead code,
  and BBRv3's default initial window is ~10× intended (a `MAX_DATAGRAM_SIZE` unit slip).

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                                   | Trade-off                                                                                          |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Sans-io core + thin async adapter (fork `quinn`'s split)       | Runtime-neutral, deterministic, C-bindable; drives any event loop                           | The adapter must re-implement fairness (`IO_LOOP_BOUND`, `WorkLimiter`) the executor won't provide |
| `Arc<Mutex<State>>` + spawned driver futures (in `noq`)        | Bridges a poll core to work-stealing `tokio`; concurrent senders via per-task `UdpSender`   | All incidental to `tokio`; a single-threaded port deletes it wholesale                             |
| Multipath as first-class `PathId` packet-number spaces         | Per-path CC/RTT/dedup/loss; connection survives path failover; enables QNT + relay fallback | `PathId` is inseparable from the core; per-path AEAD nonce reaches into the crypto trait           |
| In-QUIC NAT traversal (n0 frames), no DISCO/STUN side-channel  | One encrypted, authenticated channel; no separate side-protocol to secure                   | n0-proprietary frames diverge from the draft; no fallback if a peer lacks the TP                   |
| Interval-capped PTO backoff (not `quinn`'s `2^n`)              | Bounds tail-loss-probe cadence to ≤ 2s; steadier recovery on stalled links                  | Diverges from RFC-typical exponential backoff; more probes on a truly dead path                    |
| Cubic default, BBRv3 opt-in and "experimental"                 | Safe, well-understood default; BBRv3 available for high-BDP links                           | BBRv3's disjoint calling convention (ECN vs per-packet loss) hides behind one trait                |
| Refcounted `Bytes` recv path + assembler defragmenter          | Zero-copy stream reads; bounded over-allocation vs one-byte-frame attacks                   | Complex `allocation_size` bookkeeping; a copy-on-ingest port can delete it for one memcpy          |
| Single collapsed `poll_timeout()` deadline + one `AsyncTimer`  | 16 timer classes → one runtime timer; trivial to map to an in-ring `TIMEOUT`                | The internal `TimerTable` scan is linear (acknowledged TODO); fine at ≤ 8 paths                    |
| Token config off by default in iroh (`bloom` feature disabled) | Smaller dependency graph; NEW_TOKEN unneeded for iroh's connectivity model                  | The whole `NEW_TOKEN`/`BloomTokenLog` half is dormant; a port ships `NoneTokenLog` and matches     |

---

## Sources

- [`n0-computer/noq` — repository & README][noq-readme] (fork mission, extension list)
- [`noq-proto/src/lib.rs`][lib-proto] — sans-io crate doc, constants, `FourTuple`, versions
- [`noq/src/runtime/mod.rs`][runtime] — `Runtime`/`AsyncUdpSocket`/`UdpSender`/`AsyncTimer` seam
- [`noq/src/endpoint.rs`][ep-async] · [`noq/src/connection.rs`][conn-async] — driver architecture, `State`, fairness
- [`noq-udp/src/lib.rs`][udp-lib] · [`noq-udp/src/unix.rs`][udp-unix] — `Transmit`/`RecvMeta`, GSO/GRO/ECN/pktinfo
- [`noq-proto/src/endpoint.rs`][ep-proto] — `handle`, `DatagramEvent`, incoming decision, stateless reset
- [`noq-proto/src/connection/mod.rs`][conn-proto] — pump methods, scheduling, recovery, close/drain
- [`noq-proto/src/connection/streams/`][streams-state] ([`send.rs`][streams-send], [`recv.rs`][streams-recv], [`mod.rs`][streams-mod]) · [`assembler.rs`][assembler] · [`send_buffer.rs`][send-buffer] · [`datagrams.rs`][datagrams] — dataplane
- [`noq-proto/src/connection/spaces.rs`][spaces] · [`paths.rs`][paths] · [`timer.rs`][timer] — packet-number spaces, per-path state, timers
- [`noq-proto/src/congestion.rs`][congestion] ([`cubic.rs`][cubic], [`new_reno.rs`][newreno], [`bbr3/mod.rs`][bbr3]) · [`pacing.rs`][pacing] · [`mtud.rs`][mtud] · [`ack_frequency.rs`][ackfreq] — recovery/CC/MTUD
- [`noq-proto/src/connection/packet_builder.rs`][pktbuilder] · [`transmit_buf.rs`][transmitbuf] · [`packet.rs`][packet] · [`cid_state.rs`][cidstate] · [`cid_queue.rs`][cidqueue] — packetization & CIDs
- [`noq-proto/src/crypto.rs`][crypto] · [`crypto/rustls.rs`][crypto-rustls] · [`crypto/ring_like.rs`][ringlike] — path-aware AEAD, token keys
- [`noq-proto/src/token.rs`][token] · [`token_memory_cache.rs`][tokencache] · [`bloom_token_log.rs`][bloomlog] — Retry/NEW_TOKEN, anti-replay
- [`noq-proto/src/frame.rs`][frame] · [`transport_parameters.rs`][tparams] · [`config/transport.rs`][cfg-transport] · [`config/mod.rs`][cfg-mod] — registries & defaults
- [`iroh/src/endpoint/quic.rs`][iroh-quic] · [`iroh/src/socket.rs`][iroh-socket] · [`iroh/src/socket/transports.rs`][iroh-transports] — how iroh plugs in
- Standards: [RFC 9000][rfc9000], [RFC 9001][rfc9001], [RFC 9002][rfc9002], [RFC 9221][rfc9221], [RFC 9287][rfc9287], [RFC 8899][rfc8899], [RFC 8312][rfc8312], [RFC 6298][rfc6298]; drafts [multipath][draft-multipath], [QAD][draft-qad], [QNT][draft-qnt], [ack-frequency][draft-ackfreq], [BBRv3][draft-bbr]
- Related Sparkles pages: [Iroh survey (umbrella)][index] · [Concepts & Vocabulary][concepts] · [Wire Formats & Serialization][wire-serialization] · [Identity & Cryptography][identity-crypto] · [Endpoint & Protocol Router][endpoint] · [The Multipath Socket][socket] · [NAT Traversal & Address Discovery][nat-traversal] · [The Relay Protocol][relay] · [Tokio Concurrency Inventory][concurrency] · [D Architecture Migration][d-migration] · [event-horizon spec][eh-spec] · [async-io survey][async-io]

<!-- References -->

[noq-readme]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/README.md
[lib-proto]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/lib.rs
[runtime]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq/src/runtime/mod.rs
[ep-async]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq/src/endpoint.rs
[conn-async]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq/src/connection.rs
[udp-lib]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-udp/src/lib.rs
[udp-unix]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-udp/src/unix.rs
[ep-proto]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/endpoint.rs
[conn-proto]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/mod.rs
[streams-state]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/streams/state.rs
[streams-send]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/streams/send.rs
[streams-recv]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/streams/recv.rs
[streams-mod]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/streams/mod.rs
[assembler]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/assembler.rs
[send-buffer]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/send_buffer.rs
[datagrams]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/datagrams.rs
[spaces]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/spaces.rs
[paths]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/paths.rs
[timer]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/timer.rs
[pacing]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/pacing.rs
[mtud]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/mtud.rs
[ackfreq]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/ack_frequency.rs
[pktbuilder]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/packet_builder.rs
[transmitbuf]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/transmit_buf.rs
[packet]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/packet.rs
[cidstate]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/cid_state.rs
[cidqueue]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/cid_queue.rs
[state-proto]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/state.rs
[congestion]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/congestion.rs
[cubic]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/congestion/cubic.rs
[newreno]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/congestion/new_reno.rs
[bbr3]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/congestion/bbr3/mod.rs
[crypto]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/crypto.rs
[crypto-rustls]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/crypto/rustls.rs
[ringlike]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/crypto/ring_like.rs
[token]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/token.rs
[tokencache]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/token_memory_cache.rs
[bloomlog]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/bloom_token_log.rs
[frame]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/frame.rs
[tparams]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/transport_parameters.rs
[cfg-transport]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/config/transport.rs
[cfg-mod]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/config/mod.rs
[iroh-quic]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/quic.rs
[iroh-socket]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs
[iroh-transports]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports.rs
[docs-noq]: https://docs.rs/noq/1.0.1/noq/
[docs-noq-proto]: https://docs.rs/noq-proto/1.0.1/noq_proto/
[docs-noq-udp]: https://docs.rs/noq-udp/1.0.1/noq_udp/
[quinn]: https://github.com/quinn-rs/quinn
[rfc9000]: https://www.rfc-editor.org/rfc/rfc9000.html
[rfc9001]: https://www.rfc-editor.org/rfc/rfc9001.html
[rfc9002]: https://www.rfc-editor.org/rfc/rfc9002.html
[rfc9221]: https://www.rfc-editor.org/rfc/rfc9221.html
[rfc9287]: https://www.rfc-editor.org/rfc/rfc9287.html
[rfc8899]: https://www.rfc-editor.org/rfc/rfc8899.html
[rfc8312]: https://www.rfc-editor.org/rfc/rfc8312.html
[rfc6298]: https://www.rfc-editor.org/rfc/rfc6298.html
[draft-multipath]: https://datatracker.ietf.org/doc/draft-ietf-quic-multipath/
[draft-qad]: https://datatracker.ietf.org/doc/draft-ietf-quic-address-discovery/
[draft-qnt]: https://datatracker.ietf.org/doc/draft-seemann-quic-nat-traversal/
[draft-ackfreq]: https://datatracker.ietf.org/doc/draft-ietf-quic-ack-frequency/
[draft-bbr]: https://datatracker.ietf.org/doc/draft-ietf-ccwg-bbr/
[index]: ./index.md
[concepts]: ./concepts.md
[identity-crypto]: ./identity-crypto.md
[wire-serialization]: ./wire-serialization.md
[endpoint]: ./endpoint.md
[socket]: ./socket.md
[nat-traversal]: ./nat-traversal.md
[relay]: ./relay.md
[concurrency]: ./concurrency.md
[d-migration]: ./d-architecture-migration.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[async-io]: ../async-io/index.md
[tokio]: ../async-io/tokio.md
[glommio]: ../async-io/glommio.md
[monoio]: ../async-io/monoio.md
