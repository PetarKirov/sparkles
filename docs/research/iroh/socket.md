# The Multipath Socket

iroh's connectivity layer — the module formerly called `magicsock` — that multiplexes kernel UDP sockets, one relay transport, and arbitrary custom carriers under a single `noq::AsyncUdpSocket`, addresses every peer by a stable [`EndpointId`][identity] through a synthetic-IPv6 mapped-address scheme, and drives QUIC-native path selection, hole-punching, and relay↔direct upgrade on top of `noq` multipath.

| Field               | Value                                                                                                                                                                                                                                                                                                                       |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crate(s)            | `iroh` — module `socket` (ex-`magicsock`): `transports` (`ip`/`relay`/`custom`), `remote_map` → `remote_state` → `path_state`/`path_watcher`, `mapped_addrs`, `biased_rtt_path_selector`, `concurrent_read_map`                                                                                                             |
| Version             | iroh **v1.0.1** (git `v1.0.1-6-g22cac742ca`, commit `22cac742ca`); QUIC stack `noq` tag `noq-v1.0.1`                                                                                                                                                                                                                        |
| Repository          | [`n0-computer/iroh`][repo] (module `iroh/src/socket/`)                                                                                                                                                                                                                                                                      |
| Documentation       | [docs.rs/iroh][docs] — the module is `pub(crate)`; its only public surface is via [`Endpoint`][endpoint], `Connection::paths()`, and `RemoteInfo`                                                                                                                                                                           |
| ALPN(s)             | None — the socket layer sits **below** QUIC/TLS and moves opaque QUIC datagrams; `ALPN`s are negotiated one layer up in [`endpoint`][endpoint]                                                                                                                                                                              |
| Approx. size (LoC)  | ~11.4k across the `socket` module tree (`socket.rs` 2871, `transports.rs` 1502 + `ip.rs` 541 / `relay.rs` 369 / `relay/actor.rs` 1787 / `custom.rs` 99, `remote_map.rs` 468 + `remote_state.rs` 1530 / `path_state.rs` 689 / `path_watcher.rs` 556, `mapped_addrs.rs` 383, `biased_rtt_path_selector.rs` 323); ≈8k non-test |
| Category            | Connectivity                                                                                                                                                                                                                                                                                                                |
| Upstream spec/draft | None of its own; the mapped-address scheme uses IPv6 Unique-Local-Addresses ([RFC 4193][rfc4193]). Multipath / QAD / NAT-traversal drafts live in [`noq`][quic] (see [`quic-transport`][quic] and [`nat-traversal`][nat])                                                                                                   |

> [!NOTE]
> This module **is** the 0.x `magicsock`, restructured for iroh 1.0. The type is now `Socket` (`pub(crate)`), not `MagicSock`; `NodeId` → [`EndpointId`][identity]; "discovery" → `address_lookup` (see [`discovery`][discovery]) — vocabulary in [Concepts][concepts]. The `DISCO` UDP side-protocol and STUN are **gone**: hole-punching is `conn.initiate_nat_traversal_round()` on the QUIC connection (see [`nat-traversal`][nat]) and address discovery is QUIC Address Discovery inside [`noq`][quic] (see [`net-report`][netreport]). A stale doc-comment still mentions "DISCO packets" ([`socket.rs:579`][socket-procdgram]); the body does no such thing. This page is part of the [iroh survey][index].

---

## Overview

### What it solves

A QUIC library speaks to a UDP socket and addresses peers by 4-tuple. iroh needs the opposite contract: address a peer by its stable [`EndpointId`][identity] and let the connection ride whatever mix of paths currently reaches it — a hole-punched direct IPv4 path, an IPv6 path, a relayed path, or several at once — failing over transparently as the network changes underfoot. The socket layer is the adapter that makes those two contracts meet. It presents [`noq`][quic] with a single object that _looks_ like one UDP socket (`noq::AsyncUdpSocket`), while underneath it fans datagrams across up to three transport families, rewrites addresses so QUIC can name a peer that has no fixed IP, and runs the policy machinery — path selection, hole-punch scheduling, relay lifecycle, network-change reaction — that keeps the "always the best available path" promise.

The layer owns almost no wire format of its own. Everything above it (QUIC packets, streams, multipath frames, NAT-traversal frames, address-discovery observations) is [`noq`][quic]'s; everything the relay carries is the [relay protocol][relay]'s. What the socket _does_ own is the **routing fabric**: a synthetic address space that lets QUIC point at non-IP destinations, a per-remote actor that decides which paths exist and which is preferred, and the demultiplexing that turns "one abstract socket" back into "N real carriers." From the module's own framing ([`socket.rs:325`][socket-doc]):

> _"This is responsible for routing packets to endpoints based on endpoint IDs, it will initially route packets via a relay and transparently try and establish an endpoint-to-endpoint connection and upgrade to it. It will also keep looking for better connections as the network details of both endpoints change."_

### Design philosophy

Three convictions shape the module, and each has a direct consequence for a D port.

1. **Everything is a QUIC path; there is no separate "relay mode."** In iroh 0.x the socket duplicated each datagram onto UDP _and_ the relay and let DISCO ping/pong pick a winner. In 1.0 the relay and every direct address are **concurrent QUIC multipath paths on one connection**. "Switching from relay to direct" is nothing more than flipping a path's QUIC `PathStatus` from `Backup` to `Available` and letting [`noq`][quic] route ([`remote_state.rs:682`][rs-apply]). The socket never duplicates payload datagrams — the only surviving fan-out is for QUIC Initials, and only through one synthetic address (below).

2. **The socket must never kill the QUIC endpoint driver.** `noq` treats a send error from its `AsyncUdpSocket` as fatal and tears the endpoint down. So the send path **blackholes** almost everything — unroutable addresses, parked transports, transient errors all return `Poll::Ready(Ok(()))` and let QUIC's loss detection recover ([`transports.rs:1369`][tp-blackhole]):

   > _"On errors this methods prefers returning `Ok(())` to Noq. Returning an error should only happen if the error is permanent and fatal and it will never be possible to send anything again. Doing so kills the Noq `EndpointDriver`. Most send errors are intermittent errors, returning `Ok(())` in those cases will mean Noq eventually considers the packets that had send errors as lost and will try and re-send them."_

3. **A selected path is a working path, not a preference.** The socket only marks a path selected once `noq` reports it functional, and demotes it to `None` the instant it looks broken ([`remote_state.rs:147`][rs-selected]):

   > _"**We expect this path to work.** If we become aware this path is broken then it is set back to `None`. Having a selected path does not mean we may not be able to get a better path: e.g. when the selected path is a relay path we still need to trigger holepunching regularly. We only select a path once the path is functional in Noq."_

The whole module is a **policy shell around `noq` multipath**: `noq` owns path validation, keep-alives, loss detection, and congestion; the socket owns _which_ paths exist, _which_ is preferred, and _when_ to hole-punch. Keeping that split clean is the single most important thing a port must preserve — it is what lets the connectivity logic be reasoned about without re-deriving QUIC.

---

## How it works

### The layer cake

From bottom to top, four objects stack up:

```text
noq::Endpoint  (QUIC state machine; sees ONE abstract socket)
   │  create_sender() / poll_recv(bufs, metas)
   ▼
Transport            wraps Arc<Socket> + Transports; impl noq::AsyncUdpSocket   (transports.rs:1249)
   ▼
Transports           owns IpTransports + Vec<RelayTransport> + Vec<Box<dyn CustomEndpoint>>   (transports.rs:52)
   ▼
{ IpTransport , RelayTransport , CustomEndpoint }   — each a poll_recv / poll_send datagram carrier
   ▼
kernel UDP sockets   /   RelayActor→ActiveRelayActor→WebSocket   /   user carrier
```

`Transport` is the seam handed to `noq`. It is installed once, at bind, as an _abstract_ socket ([`socket.rs:1027`][socket-abstract]):

```rust
// iroh/src/socket.rs:1027 — the QUIC endpoint talks to an abstract socket, not an fd
let endpoint = noq::Endpoint::new_with_abstract_socket(
    endpoint_config,
    Some(server_config),
    Box::new(Transport::new(sock.clone(), transports)),
    runtime.clone(),
)
```

`noq` then drives exactly two verbs on it — a batched `poll_recv` and `create_sender()` — plus capability queries (`local_addr`, `max_receive_segments`, `may_fragment`, and on the sender `max_transmit_segments`) ([`transports.rs:1260`][tp-transport]):

```rust
// iroh/src/socket/transports.rs:1260 — the entire noq↔iroh seam
impl noq::AsyncUdpSocket for Transport {
    fn create_sender(&self) -> Pin<Box<dyn noq::UdpSender>> { /* Sender { sock, transports.create_sender() } */ }
    fn poll_recv(&mut self, cx: &mut Context, bufs: &mut [IoSliceMut<'_>], meta: &mut [noq_udp::RecvMeta])
        -> Poll<io::Result<usize>> { self.transports.poll_recv(cx, bufs, meta, &self.sock) }
    fn local_addr(&self) -> io::Result<SocketAddr> { /* first IPv6, else IPv4→v6-mapped, else DEFAULT_FAKE_ADDR */ }
    fn max_receive_segments(&self) -> NonZeroUsize { self.transports.max_receive_segments() }
    fn may_fragment(&self) -> bool { self.transports.may_fragment() }
}
```

`local_addr` never returns a raw v4 address: mapped addresses are IPv6, so a v4 socket is reported as its IPv4-mapped-IPv6 form, and a relay/custom-only endpoint reports the placeholder `DEFAULT_FAKE_ADDR` = `[fd15:70a:510b:0:ffff:ffff:ffff:ffff]:12345` ([`mapped_addrs.rs:35`][mapped-default]).

### Transport families

`Transports` ([`transports.rs:52`][tp-struct]) owns three carrier families, all sharing the same poll-based shape:

- **`IpTransports`** — one `IpTransport` per bind config, split into v4/v6 vectors sorted descending by prefix length, with an optional per-family default index ([`ip.rs:384`][ip-transports]). Only one relay `TransportConfig` is accepted ([`socket.rs:906`][socket-onerelay]) despite `relay` being a `Vec`.
- **`RelayTransport`** — zero or one, wrapping the relay actor tree (below).
- **`CustomEndpoint`** — any number of user-supplied `Box<dyn CustomEndpoint>` ([`custom.rs:36`][custom]).

Each exposes `poll_recv(cx, bufs, metas, recv_infos)` — filling `noq_udp::RecvMeta` plus an iroh-side `RecvInfo` (remote as `transports::Addr`, optional local `CustomAddr`) — and a cheap clonable _sender_ with `is_valid_send_addr(...)` + `poll_send(...)`. A network path is named by `FourTuple` and a source address by `Addr` ([`transports.rs:742`][tp-addr], [`transports.rs:970`][tp-fourtuple]):

```rust
// iroh/src/socket/transports.rs:742,970
pub enum Addr {                          pub enum FourTuple {
    Ip(SocketAddr),                          Ip     { remote: SocketAddr, local: Option<IpAddr> },
    Relay(RelayUrl, EndpointId),             Relay  { url: RelayUrl, endpoint_id: EndpointId },
    Custom(CustomAddr),                      Custom { remote: CustomAddr, local: Option<CustomAddr> },
}                                        }
```

GSO/GRO is plumbed end-to-end: `max_transmit_segments` is the **min** over IP+custom transports and `max_receive_segments` the **max** over IP transports ([`transports.rs:420`][tp-segments]), and `Transmit.segment_size` / `RecvMeta.stride` carry the segment size all the way through (the relay re-batches to fit `noq`'s buffer).

### Mapped addresses: naming non-IP peers to QUIC

`noq` only understands `SocketAddr`. So every non-IP destination is represented as a fake IPv6 Unique-Local-Address in `fd15:70a:510b::/48` ([`mapped_addrs.rs:1`][mapped-doc]):

> _"We use non-IP transports to carry datagrams. Yet Noq needs to address those transports using IPv6 addresses. These defines mappings of several IPv6 Unique Local Address ranges we use to keep track of the various 'fake' address types we use."_

The 16-byte layout ([`mapped_addrs.rs:19`][mapped-doc]) is `[0]=0xfd` prefix · `[1..6]=15 07 0a 51 0b` (n0 global ID) · `[6..8]` subnet ID · `[8..16]` big-endian `u64` counter (process-global, starting at 1; a `portable_atomic::AtomicU64` per family):

| Subnet ID | `/64` range            | Type                   | One entry per            | Role                                   |
| --------- | ---------------------- | ---------------------- | ------------------------ | -------------------------------------- |
| `00 00`   | `fd15:70a:510b::/64`   | `EndpointIdMappedAddr` | remote `EndpointId`      | `Mixed` — Initial-only fan-out address |
| `00 01`   | `fd15:70a:510b:1::/64` | `RelayMappedAddr`      | `(RelayUrl, EndpointId)` | one relay path                         |
| `00 03`   | `fd15:70a:510b:3::/64` | `CustomMappedAddr`     | `CustomAddr`             | one custom path                        |

Subnet `2` is unused (a vestige of the 0.x "IP mapped" subnet, retired now that real IP addresses pass through unmapped). The port is always the dummy `MAPPED_PORT` = 12345. `MultipathMappedAddr::from(SocketAddr)` classifies a destination by prefix match; `Mixed` carries the per-`EndpointId` address ([`mapped_addrs.rs:89`][mapped-enum]):

```rust
// iroh/src/socket/mapped_addrs.rs:89
pub(crate) enum MultipathMappedAddr {
    Mixed(EndpointIdMappedAddr),  // per-EndpointId, Initial-only fan-out addr
    Relay(RelayMappedAddr),       // per-(RelayUrl, EndpointId)
    Ip(SocketAddr),
    Custom(CustomMappedAddr),
}
pub(crate) struct EndpointIdMappedAddr(Ipv6Addr);
```

Bidirectional lookup uses `AddrMap<K,V>` — two `FxHashMap`s behind one `std::sync::Mutex` — generating a fresh mapped address on `get` and reversing on `lookup`. Crucially, **entries are never removed** ([`mapped_addrs.rs:342`][mapped-addrmap]): every `(relay, endpoint)` pair ever seen holds a slot for process lifetime.

### Recv path

`Transports::poll_recv` ([`transports.rs:298`][tp-pollrecv]) polls every transport in sequence; a counter reverses the polling order on every other call for fairness. The first transport with data wins and returns immediately. The subtle part is the failure accounting: a per-transport error does **not** short-circuit, or a single always-failing transport would hot-loop the reactor; instead errors are counted, and only if _all_ polled transports error does `poll_recv` bump `consecutive_total_recv_failures` and — after `MAX_CONSECUTIVE_RECV_ERRORS` = 8 — surface a fatal `NetworkDown` to `noq`. Otherwise it returns `Ready(Ok(0))` (as both an error-suppression signal and a genuine zero-datagram result) or `Pending`.

After a batch, `Socket::process_datagrams` ([`socket.rs:583`][socket-procdgram]) rewrites `RecvMeta.addr` for non-IP transports: a relay datagram gets `noq_meta.addr = relay_mapped_addrs.get(&(url, src_endpoint))` (a synthetic ULA), a custom datagram similarly. IP datagrams keep their kernel address, except the AF_INET6 recv path converts IPv4 peers to IPv4-mapped-IPv6 for `noq` while keeping the canonical form in `RecvInfo`. Per-datagram metrics count GRO batches, including a repair for the degenerate `stride==0 && len>0` case.

### Send path

`noq` calls `Sender::poll_send(transmit)` ([`transports.rs:1363`][tp-pollsend]). The destination `SocketAddr` is decoded into `MultipathMappedAddr` and routed:

| Class      | Routing                                                                                                                                                       |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Ip**     | canonicalize, then `v4/v6` iterate → `is_valid_send_addr(src, dst)` → `poll_send`, falling back to the family default socket                                  |
| **Relay**  | reverse-lookup to `(RelayUrl, EndpointId)`, then reserve a slot in a `PollSender`-wrapped `mpsc(256)` to the `RelayActor`                                     |
| **Custom** | reverse-lookup, delegate to the first `CustomSender` accepting the address                                                                                    |
| **Mixed**  | the packet cannot be routed to a single path — copy the whole `Transmit` into an `OwnedTransmit` and `try_send` it as `SendDatagram(...)` to the remote actor |

The `Mixed` case is the _only_ fan-out left. The remote's `RemoteStateActor` sends it to the currently selected path, or — when none exists yet — **fans it out to every known candidate path** ([`remote_state.rs:788`][rs-fanout]), which is acceptable _only_ for QUIC Initials. Everything else on the send path deliberately swallows failure per the blackholing rule above.

### `RemoteMap` and per-remote actors

`RemoteMap` ([`remote_map.rs:56`][rm-struct]) owns a `ConcurrentReadMap<EndpointId, mpsc::Sender<RemoteStateMessage>>` — a `papaya` lock-free hashmap with one `&mut` writer (the socket actor) and cheap `ReadOnlyMap` clones for concurrent readers like the send path ([`concurrent_read_map.rs:13`][crm]) — plus a `JoinSet` of per-remote actor tasks. `send_to_actor` lazily spawns a `RemoteStateActor` (inbox `mpsc(16)`) on first message to a remote. Because a `mpsc::Sender` can outlive its receiver, a failed send means the actor is terminating: the map drains the joined task and **restarts the actor with the leftover messages** ([`remote_map.rs:287`][rm-restart]). `RemoteMap::cleanup()`, pumped from the socket actor's select loop, reaps joined tasks — removing the sender if the actor drained cleanly, restarting it if messages arrived during shutdown.

### `RemoteStateActor`: one actor per remote endpoint

`RemoteStateActor` ([`remote_state.rs:98`][rs-actor]) manages _all_ connections to one remote:

```rust
// iroh/src/socket/remote_map/remote_state.rs:98 (trimmed)
struct State {
    endpoint_id: EndpointId,
    local_direct_addrs: n0_watcher::Direct<BTreeSet<DirectAddr>>,
    relay_mapped_addrs: AddrMap<(RelayUrl, EndpointId), RelayMappedAddr>,
    custom_mapped_addrs: AddrMap<CustomAddr, CustomMappedAddr>,
    address_lookup: AddressLookupServices,
    connections_close: FuturesUnordered<OnClosed>,
    path_events: PathEvents,   // MergeUnbounded of per-conn noq PathEvent streams
    addr_events: AddrEvents,   // MergeUnbounded of per-conn QNT candidate streams
    paths: RemotePathState,
    last_holepunch: Option<HolepunchAttempt>,
    selected_path: Option<transports::FourTuple>,
    scheduled_holepunch: Option<Instant>,
    scheduled_open_path: Option<Instant>,
    pending_open_paths: VecDeque<transports::FourTuple>,
    address_lookup_stream: Option<BoxStream<Result<AddressLookupItem, AddressLookupFailed>>>,
    path_selector: Arc<dyn PathSelector>,
}
```

Its **biased** `select!` loop ([`remote_state.rs:272`][rs-loop]) consumes, in priority order: a shutdown token; the `mpsc(16)` inbox; merged `noq` `PathEvent` streams; merged NAT-traversal candidate streams (remote QNT announcements → trigger hole-punching); connection-closed futures; the local direct-address watcher; a scheduled path-open timer; a scheduled hole-punch timer; an optional address-lookup stream; a 60 s `UPGRADE_INTERVAL` quality check; and a 60 s `ACTOR_MAX_IDLE_TIMEOUT` that terminates the actor when it has no connections, an empty inbox, and no pending resolves.

`AddConnection` wires those three streams for a connection, seeds local QNT candidates (diff-based against `conn.get_local_nat_traversal_addresses()`), registers `PathId::ZERO`, and — client-side only — re-adds known relay addresses as paths if the initial path came out direct. **Path opening is client-only** ([`remote_state.rs:1036`][rs-openpath]); the server learns paths from QUIC frames and reacts to `PathEvent::Established`. If `noq` refuses to open (`RemoteCidsExhausted` / `MaxPathIdReached`), the address is queued in `pending_open_paths` and retried after 333 ms.

Per-remote _candidate_ knowledge lives in `RemotePathState`: a map `transports::Addr → PathState{sources, status}` with status `Open` / `Inactive(when)` / `Unusable` / `Unknown` ([`path_state.rs:43`][ps-status]), pruned to ≤30 non-relay paths — keeping the 10 most-recently-inactive hole-punch-proven ones and always dropping hole-punch-failed ones.

### Path selection: the biased-RTT algorithm

On every `Established` / `Abandoned` path event (and on `AddConnection`), `select_path()` runs the pluggable `PathSelector` ([`remote_state.rs:1419`][rs-selectortrait]) over a `PathSelectionContext` — the current selected `FourTuple` plus an iterator of `(FourTuple, PathId, Connection)` across _all_ connections:

```rust
// iroh/src/socket/remote_map/remote_state.rs:1419
pub trait PathSelector: Send + Sync + std::fmt::Debug + 'static {
    fn select(&self, ctx: &PathSelectionContext<'_>) -> PathSelection;
}
```

The default `BiasedRttPathSelector` ([`biased_rtt_path_selector.rs`][selector]) sorts candidates by a two-level key `(TransportType, biased_rtt)`:

- `TransportType` is `Primary` (IPv4 / IPv6 / custom) or `Backup` (relay). This is a strict **tier**, not an RTT penalty: a 1000 ms direct path beats a 1 ms relay path (the selector's own tests assert this).
- `biased_rtt` is the measured RTT plus a per-kind bias; IPv6 gets a `IPV6_RTT_ADVANTAGE` = 3 ms _subtracted_ so it wins ties against IPv4.

The switch conditions have deliberate hysteresis ([`biased_rtt_path_selector.rs:170`][selector-switch]):

```rust
// iroh/src/socket/biased_rtt_path_selector.rs (abridged select())
if current_tier != best_tier {
    selection.set(&best_psd);                                          // always switch across tiers
} else if best_biased + RTT_SWITCHING_MIN.as_nanos() as i128 <= current_biased {
    selection.set(&best_psd);                                          // same tier: only if ≥5 ms better
}
```

`RTT_SWITCHING_MIN` = 5 ms is the stickiness threshold: within a tier, a candidate must be at least 5 ms better before the socket abandons the current path; across tiers (relay → primary) it switches immediately. An empty selection keeps the current path.

`apply_selected_path()` ([`remote_state.rs:682`][rs-apply]) is where selection becomes routing. For each connection it opens the selected path if missing, sets QUIC `PathStatus::Available` on the selected path and `Backup` on all others (that is how "the data goes over the selected path" is _enforced_ — `noq` transmits on `Available` paths and keeps `Backup` paths alive with keep-alives), and **closes redundant non-selected IP paths so at most one IP path remains** ([`remote_state.rs:703`][rs-close]):

> _"Closes redundant IP paths so that at most one remains per connection. Relay and custom paths are kept open. Only the client closes paths, to avoid the client and server independently closing different paths and racing to abandon the last one."_

### Hole-punching: QUIC-native, not DISCO

`trigger_holepunching` ([`remote_state.rs:504`][rs-holepunch]) picks the lowest-`ConnId` _client-side_ connection (both endpoints may hold a client connection and both may initiate), diffs the current local+remote candidate sets against the last attempt, and skips (scheduling `last.when + 5 s` `HOLEPUNCH_ATTEMPTS_INTERVAL`) if no new candidates appeared. The actual punch is `conn.initiate_nat_traversal_round()` — the n0 NAT-traversal QUIC extension implemented in [`noq-proto`][quic] (see [`nat-traversal`][nat]) — retrying transient errors in 100 ms and giving up on fatal ones. A 60 s quality check re-triggers hole-punching unless every connection already has an IP path with RTT ≤ 10 ms (`GOOD_ENOUGH_LATENCY`). Candidates propagate as QNT add/remove-address frames driven from the socket-level `DiscoveredDirectAddrs` watcher. There is no DISCO ping/pong/call-me-maybe anywhere.

### The relay transport actor tree

`RelayTransport::new` spawns a `RelayActor` (as an `AbortOnDropHandle`) that multiplexes N relay servers, spawning one `ActiveRelayActor` per URL into a `JoinSet` ([`relay/actor.rs:853`][ra-spawn]). The channel topology is the busiest in the module ([`relay.rs:46`][rt-channels]): the `RelaySender` `mpsc(256)` feeds the `RelayActor`, which `try_send`s into a per-relay `mpsc(64)`; when full it parks a completion future and stops pulling new datagrams (backpressure). **Receive bypasses the `RelayActor` entirely**: each `ActiveRelayActor` `try_send`s inbound datagrams straight into a shared `mpsc(512)` consumed by `RelayTransport::poll_recv`, which re-batches GRO segments to fit `noq`'s buffer. Only the _send_ path funnels through the `RelayActor`, for routing and lazy actor-spawning — including asking existing `ActiveRelayActor`s (via a priority inbox) whether they have recently heard from a given `EndpointId`, to reuse a relay rather than dial a new one.

Each `ActiveRelayActor` maintains one WebSocket/TLS relay connection through `Dialing` → `Connected` → `Sending` states, pings every 15 s, drops queued datagrams after 3 s while disconnected, and exits after 60 s of send-inactivity — unless it is the home relay. Home-relay status is published through a URL-guarded `HomeRelayWatch` so a demoted actor cannot clobber the new home relay's status.

### The socket actor (top level) and shutdown

One `Actor` task per endpoint ([`socket.rs:1442`][socket-actor]) runs the outermost `select!` loop, handling: actor messages (network change, relay-map change, `ResolveRemote`, `AddConnection`, direct-address refresh); a re-STUN interval randomized **20–26 s** (just under the 30 s NAT-binding timeout); the local-address, net-report, portmapper, and netmon interface watchers; `remote_map.cleanup()`; and a default-route poll with exponential backoff 100 ms → 1 s cap (5 s max) before calling `endpoint.handle_network_change(hint)` into `noq`. The `NetworkChangeHint` tells `noq` which established paths are recoverable — relay paths always (the relay actor transparently reconnects), IP paths only if their local IP still exists, `Mixed` never, custom assumed unrecoverable. Direct-address updates merge portmapper + QAD (see [`net-report`][netreport]) + local interface addresses + user-configured addresses into `DiscoveredDirectAddrs` and republish `EndpointData` to the address-lookup services on change (see [`discovery`][discovery]).

Shutdown ([`socket.rs:276`][socket-shutdown]) is two `CancellationToken`s plus an `AtomicBool`: `close()` cancels `at_close_start` (stops net-reports), clears address lookup, calls `noq_endpoint.close(0, b"")`, then awaits `wait_all_draining()` — a call whose comment records being removed and re-added three times ([`socket.rs:1148`][socket-drain]):

> _"In the history of this code, this call had been removed … then added back in … then removed again … and finally added back in together with this comment. … this call tries its best to make sure that any queued close frames … are flushed out to the sockets *and acknowledged* (or time out with the 'probe timeout' of usually 3 seconds)."_

It then cancels `at_endpoint_closed` (all actors' tokens are children), gives the actor task 100 ms, awaits the `noq` `Runtime`'s task tracker, and sets `closed`. After closing, `poll_recv` returns `Pending` forever and senders error `NotConnected`.

---

## Analysis

### Wire format & framing

The socket sits mostly _below_ framing — it moves opaque QUIC datagrams, and iroh's application-level wire formats (tickets, `postcard` structures) live in [wire formats & serialization][wire] — but it defines several byte-level conventions of its own:

- **Mapped-address ULA layout** (16 bytes, [`mapped_addrs.rs:19`][mapped-doc]): `0xfd` · `15 07 0a 51 0b` · 2-byte subnet · 8-byte big-endian counter; port always 12345. This is the address space QUIC uses to name relay/custom/per-endpoint destinations. It ports verbatim (pure data).
- **GSO/GRO segmentation**: outgoing `Transmit { ecn, contents, segment_size }` with `datagram_count = contents.len().div_ceil(segment_size)`; incoming `RecvMeta.stride` is the segment size. The relay recv path re-batches with `num_segments = buf_len / segment_size` and drops datagrams larger than the offered buffer ("let MTU discovery take over").
- **Relay datagram envelope**: `Datagrams { ecn, segment_size: Option<NonZeroU16>, contents: Bytes }` inside `ClientToRelayMsg::Datagrams` / `RelayToClientMsg::Datagrams`; ECN maps 1:1 between `noq_udp::EcnCodepoint` and `noq_proto::EcnCodepoint`. The envelope is owned by the [relay protocol][relay].
- **QUIC grease-bit hack** ([`socket.rs:1013`][socket-grease]): `endpoint_config.grease_quic_bit(false)` makes `noq` _require_ the fixed bit, so a non-QUIC UDP packet is passed to `noq` with its first byte zeroed and dropped **without a buffer rewrite**.
- **Size/limit constants**: `MAX_MULTIPATH_PATHS` = 8 concurrent QUIC paths/connection; `MAX_QNT_ADDRESSES` = 32 NAT-traversal addresses; `PATH_MAX_IDLE_TIMEOUT` = 15 s (relay 30 s); `noq_udp::BATCH_SIZE` = 32 recv buffers (unix) / 1 (Windows, wasm).

### Cryptography & identity

The socket performs **no cryptography**. TLS/QUIC handshakes, packet protection, and the `EndpointId` ↔ Ed25519 key relationship all live in [`noq`][quic] and [`identity-crypto`][identity]; the socket only carries the ciphertext. Its single identity-shaped responsibility is _addressing by_ [`EndpointId`][identity]: the mapped-address scheme and `RemoteMap` are keyed on `EndpointId`, and the relay-reuse query matches remotes by `EndpointId`. The relay's own `Blake3HmacKey` for endpoint-config token keying is constructed here ([`socket.rs:1013`][socket-grease]) but consumed by `noq`. Absence is the finding: a port must not look for a DISCO shared-secret or STUN handshake here — there is none.

### State machines & lifecycle

Eight interacting state machines drive the module; the load-bearing ones for a port are:

1. **Candidate-path lifecycle** (`RemotePathState`): `Unknown` → (path established) `Open` → (abandoned) `Inactive(now)`; `Unknown|Unusable` + failed hole-punch → `Unusable`; any → (re-established) `Open`. Pruned on every insert (≤30 non-relay, keep 10 most-recently-inactive).
2. **Selected-path state**: `Option<FourTuple>`, `None` at start; set whenever the `PathSelector` returns a selection; cleared when the last connection closes. Hysteresis lives in the selector (5 ms same-tier, immediate cross-tier).
3. **Hole-punch scheduling**: a stateless trigger with a `last_holepunch` memo; skip-and-schedule (+5 s) if candidates ⊆ last attempt; retry in 100 ms on transient `noq` errors; give up on fatal ones (`Closed`, `TooManyAddresses`, `WrongConnectionSide`, `ExtensionNotNegotiated`).
4. **`RemoteStateActor` lifecycle**: `NotRunning` → (first message) `Running` → (idle 60 s) `Terminating` → (drains inbox) → restarted-with-leftovers _or_ removed. The restart-with-leftover-messages dance exists only because a `mpsc::Sender` can outlive its receiver.
5. **`ActiveRelayActor`**: `Dialing` (exponential backoff, min 10 ms / max 16 s / jittered) → `Connected` (ping every 15 s) → `Sending` → back to `Connected`; `Established` failures reconnect immediately with a fresh backoff, others back off; exit on stop token / closed inboxes / 60 s send-inactivity (unless home relay).
6. **Socket shutdown**: `Open` → (`close()`/`abort()`) `Closing` → (endpoint drained) cancel `at_endpoint_closed` → `closed`.

### Dependencies & coupling

The socket is a thin shell over a very deep dependency:

| Dependency                                  | Depth                 | What a D port inherits                                                                                                                                                                                                                                                         |
| ------------------------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`noq`/`noq-proto`/`noq-udp`][quic]         | load-bearing          | The entire QUIC stack incl. multipath (`PathId`, `Path::set_status/close/ping`, `open_path_ensure`, `path_events`), QUIC-native NAT traversal (`initiate_nat_traversal_round`), and the `AsyncUdpSocket`/`UdpSender`/`Runtime` seams. The socket layer is a shell around this. |
| [`iroh-relay`][relay]                       | load-bearing          | relay client (`ClientBuilder`, split Stream/Sink), `ClientToRelayMsg`/`RelayToClientMsg`, `Datagrams`, `PingTracker`.                                                                                                                                                          |
| `netwatch` / `net-tools`                    | load-bearing platform | `UdpSocket` with GSO/GRO + rebind, `netmon::Monitor` interface watching, `interfaces::State`. A port needs `sendmsg`/`recvmmsg` + `UDP_SEGMENT`/`UDP_GRO` and netlink/route monitoring (see [`net-report`][netreport]).                                                        |
| `n0-watcher`                                | load-bearing pattern  | `Watchable`/`Watcher` + `Join`/`Tuple`/`Map`/`or` combinators — a versioned last-value cell with change notification. **No event-horizon equivalent** (see Mapping).                                                                                                           |
| `tokio` / `tokio-util`                      | load-bearing runtime  | `mpsc`/`oneshot`/`broadcast`/`Notify`/`Mutex`/`RwLock`, biased `select!`, `JoinSet`, `CancellationToken` (+ child tokens), `PollSender`, `AbortOnDropHandle`.                                                                                                                  |
| `papaya`                                    | API-surface           | lock-free hashmap behind `ConcurrentReadMap`. Collapses to a plain hashmap under single-threaded D.                                                                                                                                                                            |
| `backon`, `rustc-hash`, `smallvec`, `bytes` | trivial               | exponential backoff; `FxHashMap`; `SmallVec`; ref-counted byte buffers. Backoff → event-horizon `Schedule`.                                                                                                                                                                    |

The full concurrency inventory (26 primitives) is enumerated in [`concurrency`][concurrency].

### Concurrency & I/O model

The module is a **constellation of tokio actors** communicating over channels, running on a work-stealing multi-thread runtime with `Arc`/`Mutex`/atomics guarding every shared datum. There are three actor tiers — one socket `Actor`, one `RemoteStateActor` per remote, one `RelayActor` + N `ActiveRelayActor`s — plus the `noq` endpoint driver, all potentially on different threads. The I/O model is `noq`'s poll-driven `AsyncUdpSocket`: `noq` calls `poll_recv`/`poll_send` and the socket threads its own actor events through tokio channels and `n0-watcher` watchables. Every `select!` here is **biased** (deterministic priority — shutdown token first), and that ordering is load-bearing, not incidental. There is **no `spawn_blocking` anywhere** in the subsystem, and the only `std::sync::Mutex`es (the `AddrMap` bimap, the `PathStateSender` shared state, the `actor_task` handle) hold short critical sections. That is the crucial fact for a port: nothing here needs true parallelism — the multi-thread machinery exists because tokio is multi-thread, not because the algorithm is.

### Mapping to event-horizon

This subsystem is where the tokio→[event-horizon][eh-spec] translation pays off most, because almost all of its concurrency is _accidental_ — a consequence of tokio's `Send + Sync` model, not of the connectivity algorithm. Under event-horizon's default `single` topology (one loop, one thread, [fibers][eh-spec] + [algebraic effects][algeff]) the `Arc<Mutex<…>>` scaffolding collapses to plain fields.

**1. The `AsyncUdpSocket` poll seam disappears.** The entire `poll_recv`/`poll_send` + `Waker` choreography exists because `noq` is a poll-driven state machine on tokio. On event-horizon the seam should be **completion-shaped**: each transport is a fiber doing `recv` (ideally multishot into a [`BufRing`][eh-spec]) and feeding a demux point, plus a `send(FourTuple, segments)` verb. The `poll_recv` fairness counter becomes unnecessary (each transport is its own fiber); the "all transports failed 8×" fatal escalation stays as policy.

```rust
// Rust: iroh/src/socket/transports.rs:1260 — poll-driven seam noq drives
impl noq::AsyncUdpSocket for Transport {
    fn poll_recv(&mut self, cx: &mut Context, bufs: &mut [IoSliceMut<'_>], meta: &mut [noq_udp::RecvMeta])
        -> Poll<io::Result<usize>> { self.transports.poll_recv(cx, bufs, meta, &self.sock) }
    fn create_sender(&self) -> Pin<Box<dyn noq::UdpSender>> { /* ... */ }
}
```

```d
// D (proposed / sketch): a completion-shaped multipath datagram carrier over event-horizon.
// Each transport is its own recv fiber feeding one demux mailbox; send is a direct verb.
struct MultipathSocket(Net) if (isNet!Net)
{
    Net net;                                   // RingNet capability (io_uring/kqueue/IOCP)
    IpTransport[] ip;                          // was IpTransports; sorted by prefix len
    RelayTransport* relay;                     // 0..1
    CustomTransport[] custom;
    MappedAddrs mapped;                         // plain bidi hashmaps — no Mutex under `single`

    // recv: one fiber per transport; on completion, tag with Addr and post to the demux.
    void spawnRecvFibers(ref Scope sc) {
        foreach (ref t; ip)     sc.spawn(() => t.recvLoop(&demux));   // multishot recv into a BufRing
        if (relay) sc.spawn(() => relay.recvLoop(&demux));
        foreach (ref t; custom) sc.spawn(() => t.recvLoop(&demux));
    }

    // send: never fails the QUIC stack — blackhole transient errors (load-bearing invariant).
    void send(FourTuple dst, scope const(Segment)[] segs) @safe nothrow {
        auto r = routeAndSend(dst, segs);      // IoResult!void
        if (r.hasError) { metrics.sendDrops++; /* drop: let noq loss detection recover */ }
    }
}
```

**2. Mapped addresses port verbatim.** The ULA scheme is pure data; `AddrMap` under `single` topology is a plain bidirectional hashmap with **no `Mutex`**. Keep the never-GC'd growth in mind — it is a real leak the port should bound (the Rust code has a `// TODO: use this` for remote-state pruning). `EndpointIdMappedAddr` is a 16-byte value that can be a `@safe pure nothrow @nogc` struct.

```rust
// Rust: iroh/src/socket/mapped_addrs.rs:135
pub(crate) struct EndpointIdMappedAddr(Ipv6Addr);   // fd15:70a:510b::/64 + AtomicU64 counter
```

```d
// D (proposed / sketch): the same 16 bytes, no atomic under single-threaded ownership.
struct EndpointIdMappedAddr { ubyte[16] octets; }   // 0xfd | 15 07 0a 51 0b | 00 00 | u64 counter (BE)

EndpointIdMappedAddr nextEndpointIdAddr(ref ulong counter) @safe pure nothrow @nogc {
    ubyte[16] o = [0xfd, 0x15, 0x07, 0x0a, 0x51, 0x0b, 0x00, 0x00, 0,0,0,0,0,0,0,0];
    o[8 .. 16] = nativeToBigEndian(++counter);       // plain field ++, not AtomicU64 under `single`
    return EndpointIdMappedAddr(o);
}
```

**3. Actor topology → fibers owning state; the restart dance evaporates.** The socket `Actor` becomes one fiber in the endpoint's [`Scope`][eh-spec]; each `RemoteStateActor` becomes one fiber spawned via `Scope.spawn`, keeping a `JoinHandle`. The reap/restart-with-leftover-messages machinery in `RemoteMap` exists **only** because a tokio `mpsc::Sender` can outlive its receiver across threads. In a single-threaded loop, enqueue-and-spawn is atomic — the port can drop the restart machinery entirely, contingent on a cross-fiber channel primitive (event-horizon [open-issue O20][eh-spec], the recognized gap this subsystem most needs).

**4. `select!` loops → `race` / first-completion, preserving bias.** Every loop here is a biased `select!`. Map each to event-horizon [`race`][eh-spec] over a small fixed set of awaitables; the biased orderings (shutdown token first) must be reproduced as **deterministic priority** when several completions are ready simultaneously.

**5. `CancellationToken` tree → `CancelContext` tree.** A direct fit: `at_close_start` / `at_endpoint_closed` and their `child_token()`s are nested cancel scopes; `run_until_cancelled(fut)` is `race(cancelled, fut)`; the 100 ms actor grace is [`withDeadline`][eh-spec].

**6. `PathSelector` → a DbI capability, not a `dyn` trait object.** The selector is a **pure function** of a context; it needs no allocation and no `Arc`. In D it is a compile-time capability (design-by-introspection), monomorphized at zero cost:

```rust
// Rust: iroh/src/socket/remote_map/remote_state.rs:1419
pub trait PathSelector: Send + Sync + std::fmt::Debug + 'static {
    fn select(&self, ctx: &PathSelectionContext<'_>) -> PathSelection;
}
```

```d
// D (proposed / sketch): a DbI trait — any struct exposing `select` qualifies; no vtable, no Arc.
enum isPathSelector(S) = is(typeof((S s, in PathSelectionContext ctx) => s.select(ctx)) : PathSelection);

struct BiasedRttPathSelector {
    // TransportType is a strict tier (relay = Backup); relay never wins on RTT.
    // sort key = (tier, rttNanos + bias);  IPv6 bias = -3 ms.  Switch same-tier only if ≥5 ms better.
    PathSelection select(in PathSelectionContext ctx) @safe pure nothrow @nogc {
        // single pass: best-by-(tier, biasedRtt); switch across tiers immediately,
        // within a tier only when `best + 5ms <= current` (hysteresis).
    }
}
static assert(isPathSelector!BiasedRttPathSelector);
```

**7. `n0-watcher` needs a new design — the one real gap.** Watchables are _the_ backbone here (local addrs, net-report, home relay, direct addrs, portmapper), and event-horizon has no watch equivalent. Minimal D design: a versioned value cell + a waiter list that wakes parked fibers; the `Join`/`Tuple`/`Map` combinators can be lazy structs recomputing on `get()`. Single-threaded means no lock, but the cross-fiber wakeup still needs the missing channel/`Notify`-like primitive (again O20). The `broadcast(8)` + `Lagged { missed }` path-event overflow semantics must be reproduced faithfully — the actor treats lag as "state possibly stale."

**8. Blackholing is load-bearing.** `send` must never propagate a transient error or backpressure to the QUIC stack. In D, a failed/parked transport send drops the datagram (increment a metric) rather than failing the endpoint fiber — see the `send` sketch above.

**9. GSO/GRO waits on O19.** `Transmit.segment_size` / `RecvMeta.stride` require `sendmsg`/`recvmmsg` with `UDP_SEGMENT`/`UDP_GRO` cmsgs — exactly event-horizon [open-issue O19][eh-spec] (msghdr ops). Until then a port is limited to one datagram per op (matching `noq-udp`'s `BATCH_SIZE = 1` fallback platforms: protocol-correct, slower). No `spawn_blocking` appears here, so there is nothing to flag for a missing thread pool; DNS resolution is async and lives elsewhere.

The net effect: under `single` topology this subsystem shrinks from a lock-and-channel constellation to a handful of state-owning fibers plus one new primitive (the watch/channel of O20). The mapped-address scheme, the biased-RTT selector, the hole-punch schedule, and the blackholing rule port almost verbatim; the concurrency scaffolding is what melts away.

---

## Strengths

- **Clean layering.** The socket is a policy shell; QUIC path validation, keep-alives, and loss detection are all `noq`'s. The connectivity logic can be read without re-deriving QUIC.
- **Uniform path model.** Relay and direct are the same thing — QUIC multipath paths. Relay↔direct "switching" is one `PathStatus` flip, eliminating the 0.x per-datagram duplication.
- **Robust failure handling.** The blackholing invariant, the 8-consecutive-error escalation, the never-kill-the-driver discipline, and the always-recover-via-loss-detection stance make the socket resilient to transient transport faults.
- **Pluggable selection.** `PathSelector` is a trait; the biased-RTT policy with 5 ms hysteresis and a strict relay-is-backup tier is a sensible, testable default.
- **Careful shutdown.** The `wait_all_draining()` history comment and the two-token + grace-period teardown reflect hard-won correctness around QUIC close frames.
- **QUIC-native NAT traversal.** Dropping DISCO/STUN for in-connection `initiate_nat_traversal_round()` removes an entire encrypted-side-channel protocol.

## Weaknesses

- **Deep `noq` coupling.** The socket is inseparable from a bespoke QUIC fork (multipath + QAD + QNT). A D port must reimplement or bind ~48k lines of `noq` before this shell does anything useful.
- **Unbounded mapped-address growth.** `AddrMap` has no removal API; every `(relay, endpoint)` pair ever seen leaks for process lifetime, and remote-state pruning is a `// TODO`.
- **Accidental concurrency tax.** `Arc`/`Mutex`/atomics/`papaya`/multi-thread actors exist for tokio's model, not the algorithm — pure overhead a single-threaded design removes but that a faithful Rust reader must wade through.
- **Stale artifacts.** A doc-comment still claims DISCO packets are processed; symbols like `re_stun` / `periodic_re_stun_timer` survive though STUN is gone (now QAD). Easy to mislead a port author.
- **Subtle poll semantics.** `Ready(Ok(0))` is overloaded (error-suppression _and_ zero datagrams); the reverse-order fairness counter and `pending_item` relay starvation are non-obvious invariants a port must not "simplify."
- **Asymmetric path control.** Only the client opens and closes paths; the server follows. Correct, but a source of confusion (both sides may hold client connections).

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                                     | Trade-off                                                                                          |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Relay + direct as concurrent QUIC multipath paths (not modes)           | One connection, one uniform routing model; failover is a `PathStatus` flip                    | Requires a multipath QUIC (`noq`); "switch" logic moves into path-status bookkeeping               |
| Synthetic IPv6 ULA mapped addresses for non-IP peers                    | Lets stock QUIC address relay/custom/per-endpoint destinations with plain `SocketAddr`s       | A second address space to maintain; `AddrMap` leaks entries for process lifetime                   |
| Blackhole send errors — always return `Ok(())` to `noq`                 | A send error kills the `noq` `EndpointDriver`; loss detection recovers intermittent failures  | Silent drops; no error surfaced to the app; masks genuine misconfiguration until QUIC times out    |
| One `RemoteStateActor` per remote, lazily spawned                       | Localizes all per-remote path/hole-punch state; natural unit of cancellation and idle-timeout | Restart-with-leftover-messages dance needed because `mpsc::Sender` outlives its receiver           |
| Biased-RTT selector: relay strictly `Backup`, 5 ms same-tier hysteresis | Relay is a fallback regardless of RTT; hysteresis avoids flapping between near-equal paths    | A very fast relay still loses to a slow direct path; policy is a default, tunable via the trait    |
| Client-only path open/close                                             | Avoids client and server racing to abandon the last path                                      | Asymmetric control flow; server reacts to frames only; "initiator" is per-connection, not per-peer |
| QUIC-native NAT traversal (no DISCO/STUN)                               | Candidates and probes ride the encrypted connection; one fewer side-protocol                  | Ties hole-punching to the QUIC extension in `noq-proto`; no out-of-band punch before a connection  |
| Abstract-socket seam (`new_with_abstract_socket`)                       | `noq` stays UDP-agnostic; the socket can multiplex any datagram carrier                       | Poll/`Waker` choreography that a completion-first runtime must invert (event-horizon O19/O20)      |

---

## Sources

Primary sources — the pinned iroh `socket` module (`iroh` v1.0.1, commit `22cac742ca`):

- [`iroh/src/socket.rs`][socket-doc] — `Socket`, `EndpointInner`, the top-level `Actor`, `process_datagrams`, shutdown, constants.
- [`iroh/src/socket/transports.rs`][tp-struct] — `Transports`, `Transport` (`noq::AsyncUdpSocket` impl), `Sender`, `Addr`, `FourTuple`, recv/send paths, blackholing.
- [`iroh/src/socket/transports/ip.rs`][ip-transports], [`relay.rs`][rt-channels], [`relay/actor.rs`][ra-spawn], [`custom.rs`][custom] — the three transport families and the relay actor tree.
- [`iroh/src/socket/mapped_addrs.rs`][mapped-doc] — the ULA mapped-address scheme and `AddrMap`.
- [`iroh/src/socket/remote_map.rs`][rm-struct] and [`remote_state.rs`][rs-actor] — `RemoteMap`, `RemoteStateActor`, path bookkeeping, hole-punch scheduling, `select_path`/`apply_selected_path`.
- [`iroh/src/socket/remote_map/remote_state/path_state.rs`][ps-status], [`path_watcher.rs`][pw] — candidate-path lifecycle and the public path-event stream.
- [`iroh/src/socket/biased_rtt_path_selector.rs`][selector] — the default `PathSelector`.
- [`iroh/src/socket/concurrent_read_map.rs`][crm] — the `papaya`-backed single-writer/multi-reader map.

Related pages: [QUIC transport (`noq`)][quic] (multipath, the `AsyncUdpSocket` contract), [NAT traversal & address discovery][nat] (the QNT frames this layer triggers), [the relay protocol][relay] (the datagram envelope), [net report][netreport] (QAD / interface watching / port mapping), [address lookup][discovery] (where direct addresses are republished), [endpoint & protocol router][endpoint] (the public surface above this layer), [concurrency inventory][concurrency] (all 26 primitives), and [D architecture migration][d-migration]. Runtime target: the [event-horizon spec][eh-spec]; concurrency-model contrast in [tokio][tokio] and the [async-io survey][async-io].

<!-- References -->

[repo]: https://github.com/n0-computer/iroh/tree/22cac742ca
[docs]: https://docs.rs/iroh/1.0.1/iroh/
[socket-doc]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L325
[socket-procdgram]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L583
[socket-abstract]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1027
[socket-grease]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1013
[socket-onerelay]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L906
[socket-actor]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1442
[socket-shutdown]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L276
[socket-drain]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1148
[tp-struct]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports.rs#L52
[tp-transport]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports.rs#L1260
[tp-addr]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports.rs#L742
[tp-fourtuple]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports.rs#L970
[tp-segments]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports.rs#L420
[tp-pollrecv]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports.rs#L298
[tp-pollsend]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports.rs#L1363
[tp-blackhole]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports.rs#L1369
[ip-transports]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports/ip.rs#L384
[rt-channels]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports/relay.rs#L46
[ra-spawn]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports/relay/actor.rs#L853
[custom]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports/custom.rs#L36
[mapped-doc]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/mapped_addrs.rs#L19
[mapped-default]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/mapped_addrs.rs#L35
[mapped-enum]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/mapped_addrs.rs#L89
[mapped-addrmap]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/mapped_addrs.rs#L342
[rm-struct]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map.rs#L56
[rm-restart]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map.rs#L287
[crm]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/concurrent_read_map.rs#L13
[rs-actor]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs#L98
[rs-loop]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs#L272
[rs-selected]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs#L147
[rs-fanout]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs#L788
[rs-openpath]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs#L1036
[rs-apply]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs#L682
[rs-close]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs#L703
[rs-holepunch]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs#L504
[rs-selectortrait]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs#L1419
[ps-status]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state/path_state.rs#L43
[pw]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state/path_watcher.rs#L53
[selector]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/biased_rtt_path_selector.rs#L19
[selector-switch]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/biased_rtt_path_selector.rs#L170
[quic]: ./quic-transport.md
[nat]: ./nat-traversal.md
[relay]: ./relay.md
[netreport]: ./net-report.md
[discovery]: ./discovery.md
[endpoint]: ./endpoint.md
[identity]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[concurrency]: ./concurrency.md
[d-migration]: ./d-architecture-migration.md
[concepts]: ./concepts.md
[index]: ./index.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[algeff]: ../algebraic-effects/index.md
[tokio]: ../async-io/tokio.md
[async-io]: ../async-io/index.md
[rfc4193]: https://www.rfc-editor.org/rfc/rfc4193
