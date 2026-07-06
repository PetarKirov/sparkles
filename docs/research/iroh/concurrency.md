# Tokio Concurrency Inventory

The complete map of the iroh stack's runtime concurrency — every long-lived task, channel, lock, `tokio::select!` loop, `spawn_blocking`, and timer — classified into what the **protocol demands** versus what is an **artifact of `Send + Sync` multithreading**, and translated construct-by-construct onto the single-threaded [`sparkles:event-horizon`][eh-spec] runtime.

**Last reviewed:** July 6, 2026

| Field                 | Value                                                                                                                                                                                                                                                                 |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crates surveyed       | `n0-future` 0.3.2, `n0-watcher` 1.0.0, `iroh` 1.0.1, `iroh-blobs` 0.103.0, `iroh-docs` 0.101.0, `iroh-gossip` 0.101.0, `iroh-util` 0.6.0, `irpc` 0.17.0, `iroh-metrics` 1.0.1                                                                                         |
| Version pin           | iroh workspace **v1.0.1** (git `22cac742ca`)                                                                                                                                                                                                                          |
| Repository            | [`n0-computer`][org] (GitHub org)                                                                                                                                                                                                                                     |
| Documentation         | [docs.rs/n0-future][n0-future] · [docs.rs/n0-watcher][n0-watcher] · [docs.rs/irpc][irpc-docs]                                                                                                                                                                         |
| ALPN(s)               | None — this subsystem is process-internal plumbing; the wire-bearing ALPNs belong to their own pages ([blobs][blobs], [gossip][gossip], [relay][relay])                                                                                                               |
| Approx. size (LoC)    | Shim layer `n0-future` ~1490, `n0-watcher` ~1475, `iroh-util` `connection_pool` 866, `irpc` `lib.rs` 2663; plus the actor loops embedded across the five subsystem crates                                                                                             |
| Runtime model         | `tokio` multi-threaded work-stealing, **plus two extra runtimes**: `iroh-blobs` builds its own multi-thread pool; `iroh-docs` builds a current-thread runtime on a bare `std::thread`                                                                                 |
| Target runtime        | [`sparkles:event-horizon`][eh-spec] — single loop, completion-first (`io_uring`/kqueue/IOCP), fibers + algebraic effects, `single` topology default                                                                                                                   |
| Category              | D migration                                                                                                                                                                                                                                                           |
| Upstream spec / draft | None — these are `tokio`/`tokio-util` runtime primitives, not a protocol. The _absence_ of a spec is the finding: the concurrency architecture is convention, and a clean-room port is free to re-derive it from the protocol constraints (see [Analysis](#analysis)) |

---

## Overview

### What it solves

Every other page in this survey describes one subsystem's bytes and state machines. This page describes the **glue that runs them**: the tree of `tokio` tasks, the bounded channels between them, the locks that guard shared state, the `select!` loops that multiplex events, and the blocking work that escapes to dedicated threads. It is the direct input to [D Architecture Migration][d-arch] — before a single line of the port is written, the migration needs an exhaustive, cited census of what concurrency exists, why each piece exists, and which pieces evaporate when the whole thing moves from a `Send + Sync` work-stealing runtime to a single-threaded completion loop.

The census answers three questions per construct:

1. **Is it inherent to the protocol?** A relay reconnect backoff, a "cancel the losing probes once we have enough" race, or an idle-timeout on a per-remote actor must exist in _any_ implementation, single-threaded or not.
2. **Is it a `Send + Sync` artifact?** An `Arc<Mutex<…>>`, an `AtomicU64`, a `papaya` lock-free map, or the intricate protocol that restarts a dying actor with its unprocessed inbox re-injected — these exist _only_ because tasks migrate across threads and shared state races. Under [event-horizon][eh-spec]'s default `single` topology they collapse to plain fields owned by one fiber.
3. **Is it genuinely hard single-threaded?** CPU-bound BLAKE3 hashing on the loop thread and an embedded blocking database are neither pure protocol nor free to delete; they need explicit design.

The catalog compares directly against the three async-I/O deep-dives it draws on: [Tokio][tokio-async] (the work-stealing model iroh is built on), and [Glommio][glommio] / [Monoio][monoio] (the thread-per-core, share-nothing stance event-horizon adopts instead).

### Design philosophy

The iroh stack is a **tree of single-consumer actors** connected by bounded `tokio::sync::mpsc` channels, with `oneshot` channels for request/reply, [`n0-watcher`][n0-watcher] "watchables" for last-value-wins state observation, and `CancellationToken` trees for shutdown. Almost every long-lived task is a `loop { tokio::select! { … } }` over an inbox, some event streams, some timers, a cancellation token, and a `JoinSet` of children it reaps. There is essentially **no shared-mutable-state concurrency on hot paths**: the locks that exist guard cold config or tiny bimaps, and the one lock-free structure (a `papaya`-backed `ConcurrentReadMap`) exists so the datagram path can find a per-remote actor's inbox sender without a round-trip through the socket actor.

Two shim crates encode the philosophy. `n0-future` is a _re-export layer_ that abstracts task-spawn and time so the same code compiles for native `tokio` and for `wasm32-unknown-unknown` — its crate root is candid about why it exists:

> _"Read up more on our challenges with rust's async: `https://www.iroh.computer/blog/async-rust-challenges-in-iroh`"_
>
> — [`n0-future/src/lib.rs:3`][n0-future]

`n0-watcher` is the state-observation half, and its own doc comment states the last-value-wins design contract that the port must preserve because it is _public API_ (`iroh::Watcher` re-exports it):

> _"A `Watchable` exists to keep track of a value which may change over time. It allows observers to be notified of changes to the value. The aim is to always be aware of the **last** value, not to observe *every* value change."_
>
> — [`n0-watcher/src/lib.rs:3-5`][n0-watcher]

The architecture is not without self-criticism. The socket layer's core `Socket` handle carries a comment that reads as a design confession, and it is a useful warning for the port about where the module boundaries should be tightened:

> _"Shared state between an awful lot of iroh subsystems. In particular both the `EndpointInner` as well as this actor itself have a copy. But also other subsystems that consequently have access to way to much state."_
>
> — [`iroh/src/socket.rs:1456-1459`][socket]

---

## The concurrency substrate: `n0-future` and `n0-watcher`

Everything in the inventory is spelled in the vocabulary of these two crates, so they are the first thing to port.

### `n0-future` — the task/time abstraction

On native targets `n0-future::task` is _literally_ a re-export of `tokio`; there is no novel scheduling logic:

```rust
// n0-future/src/task.rs:4-9 — the entire native "abstraction"
#[cfg(not(wasm_browser))]
pub use tokio::spawn;
#[cfg(not(wasm_browser))]
pub use tokio::task::{AbortHandle, Id, JoinError, JoinHandle, JoinSet};
#[cfg(not(wasm_browser))]
pub use tokio_util::task::AbortOnDropHandle;
```

`n0-future::time` similarly re-exports `tokio::time::{sleep, timeout, interval, Instant, …}`. On `wasm_browser` both are reimplemented over `wasm_bindgen_futures::spawn_local` and `setTimeout`. The crate adds exactly **one** novel type, `MaybeFuture` — an optional future that polls `Pending` when `None` and resets itself to `None` after completing, whose documented purpose is to conditionally enable a `select!` arm:

```rust
// n0-future/src/maybe_future.rs:86-94
#[derive(Default, Debug)]
#[pin_project(project = MaybeFutureProj, project_replace = MaybeFutureProjReplace)]
pub enum MaybeFuture<T> {
    /// The state in which it wraps a future to be polled.
    Some(#[pin] T),
    /// The state in which there's no future set, and polling will always return [`Poll::Pending`]
    #[default]
    None,
}
```

> _"One major use case for this is ergonomically disabling branches in a `tokio::select!`."_ — [`n0-future/src/maybe_future.rs:24`][n0-future]

`MaybeFuture` appears throughout the socket actor and per-remote actor as an armable timer (a holepunch retry, a path-open deadline, a network-change backoff). Its behaviour is fully captured by "arm the in-ring `TIMEOUT` op only when the state says so" under event-horizon — there is no future to disable when the corresponding forwarder fiber simply is not running.

### `n0-watcher` — `Watchable` / `Watcher`

`Watchable<T>` holds `Arc<Shared<T>>` where `Shared` couples an `RwLock` over `{value, epoch}` with a waker `VecDeque` behind a `Mutex`:

```rust
// n0-watcher/src/lib.rs:96-99, 763-774
pub struct Watchable<T> { shared: Arc<Shared<T>> }
struct Shared<T> {
    state: RwLock<State<T>>,      // { value: T, epoch: u64 }
    wakers: Mutex<VecDeque<Waker>>,
}
```

`set` compares the new value with `Eq`, bumps `epoch`, and wakes queued wakers **only when the value actually changed** ([`lib.rs:147-172`][n0-watcher]); `poll_updated` is the classic check-epoch → register-waker → re-check-epoch double-check against lost wakeups; dropping the last `Watchable` wakes all watchers so they observe `Disconnected` (modelled by `Weak` upgrade failure). The observer side is a poll-based trait with combinators:

```rust
// n0-watcher/src/lib.rs:230-284 (trimmed) — the Watcher trait
pub trait Watcher: Clone {
    type Value: Clone + Eq;
    fn get(&mut self) -> Self::Value { self.update(); self.peek().clone() }
    fn update(&mut self) -> bool;
    fn peek(&self) -> &Self::Value;
    fn is_connected(&self) -> bool;
    fn poll_updated(&mut self, cx: &mut task::Context<'_>) -> Poll<Result<(), Disconnected>>;
    fn updated(&mut self) -> NextFut<'_, Self> { … }
    fn initialized<T, W>(&mut self) -> InitializedFut<'_, T, W, Self> where … { … }
    fn stream(self) -> Stream<Self> where Self: Unpin { … }
    fn map<T: Clone + Eq>(self, map: impl Fn(Self::Value) -> T + Send + Sync + 'static) -> Map<Self, T> { … }
    fn or<W: Watcher>(self, other: W) -> Tuple<Self, W> { … }
}
```

The `map` combinator additionally dedups the _mapped_ value, so a chain of watchers never spins. This is not an internal detail to paper over — the public `Endpoint::watch_addr` API is composed as `watch_addrs.or(watch_relay).map(…)` ([`endpoint.rs:1270-1284`][endpoint-src]), and `home_relay_status` / `net_report` are watchers too. Any D port exposes the same surface, so the semantics (last-value-wins, notify-on-change-only, `map`/`or`/`Join` combinators, `Disconnected` on drop) must be reproduced faithfully; see the [paired sketch](#mapping-to-event-horizon) below.

---

## Per-crate concurrency inventory

The tables below are the census. Cites are `file:line` against the pinned revisions; capacities are **protocol policy** a port must carry over verbatim.

### Long-lived tasks and actors

| Actor / task                            | Spawn site                                                                             | Inbox(es) (cap)                                              | State owned                                                            | Shutdown mechanism                                                               |
| --------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| socket `Actor` (1/endpoint)             | [`socket.rs:1098`][socket]                                                             | `ActorMessage` mpsc(256); `direct_addr_done` mpsc(8)         | `RemoteMap`, netmon watcher, re-stun interval, `DirectAddrUpdateState` | child of `at_endpoint_closed` token + `AbortOnDropHandle`; 100 ms grace          |
| `RemoteStateActor` (1/remote)           | [`remote_state.rs:223`][remote-state] → `JoinSet` [`remote_map.rs:145`][remote-map]    | `RemoteStateMessage` mpsc(16)                                | per-remote paths, holepunch state, per-conn event streams (merged)     | shutdown token, inbox close, or **60 s idle**; leftover-message restart protocol |
| `RelayActor` (1)                        | [`relay.rs:57`][relay-transport]                                                       | `RelayActorMessage` mpsc(256); `RelaySendItem` mpsc(256)     | `BTreeMap<RelayUrl, ActiveRelayHandle>`, `JoinSet<()>`                 | cancel token; 3 s bounded `close_all_active_relays`                              |
| `ActiveRelayActor` (1/relay URL)        | [`actor.rs:1268`][relay-actor] → `JoinSet`                                             | prio mpsc(32), inbox mpsc(64), send mpsc(64)                 | relay TCP/WS client, ping tracker, 60 s inactivity sleep               | stop token (child); self-exit on inactivity unless home relay                    |
| `reportgen::Actor` (1/report)           | [`reportgen.rs:141`][reportgen]                                                        | none (fans out); results mpsc(32)                            | probe `JoinSet` + captive-portal token                                 | `AbortOnDropHandle` drop = abort; 5 s overall timeout                            |
| net-report run task (1/update)          | [`socket.rs:816`][socket]                                                              | —                                                            | owned mutex guard on `net_report::Client`                              | `token.run_until_cancelled` + 10 s `NET_REPORT_TIMEOUT`                          |
| `Router` accept loop                    | [`protocol.rs:614`][protocol]                                                          | —                                                            | `JoinSet` of per-connection handler tasks                              | own `CancellationToken` + drop guard; ordered shutdown                           |
| noq driver tasks (endpoint/conn)        | [`runtime.rs:90`][runtime]                                                             | —                                                            | quinn/noq internals                                                    | `TaskTracker` + shared cancel token                                              |
| `PkarrPublisher` service                | `pkarr.rs:324`                                                                         | `n0-watcher` `updated()`                                     | republish sleep (5 min default)                                        | watcher disconnect                                                               |
| relay server `relay_supervisor`         | [`server.rs:959`][relay-server]                                                        | `JoinSet` of services                                        | http/quic server handles                                               | first exit stops all                                                             |
| relay server per-client `Actor`         | [`client.rs:146`][relay-server-client]                                                 | packets mpsc(512), messages mpsc(512)                        | client stream, ping tracker                                            | `done` token + `AbortOnDropHandle`                                               |
| blobs FS store main actor               | [`fs.rs:1424`][blobs-fs] (own runtime)                                                 | cmds mpsc(100), fs-cmds mpsc(100)                            | `JoinSet`, `EntityManagerState` (pool 1024, inbox 32), temp tags       | inbox close; joins all tasks                                                     |
| blobs `meta::Actor` (redb)              | [`fs.rs:667`][blobs-fs]                                                                | db cmds mpsc(100)                                            | redb `Database`, delete set                                            | inbox close / `Shutdown` cmd                                                     |
| blobs entity actor (1/active hash)      | [`entity_manager.rs:612`][blobs-entity]                                                | per-entity mpsc(32)                                          | per-hash `FuturesUnordered` tasks                                      | recycled to pool on idle; `ShutdownAll`                                          |
| blobs `DownloaderActor`                 | [`downloader.rs:400`][downloader]                                                      | `SwarmMsg` mpsc(32)                                          | `ConnectionPool`, `JoinSet`, idle waiters                              | inbox close (drains in-flight — downloads are _not_ aborted on drop)             |
| blobs gc task                           | [`fs.rs:1427`][blobs-fs] / [`mem.rs:143`][blobs-mem]                                   | —                                                            | `sleep(interval)` loop                                                 | runtime/task drop                                                                |
| blobs provider per-stream               | [`provider.rs:308`][blobs-provider]                                                    | —                                                            | one request/response stream                                            | connection close                                                                 |
| pool `Actor` (iroh-util)                | [`connection_pool.rs:430`][conn-pool]                                                  | `ActorMessage` mpsc(100)                                     | `HashMap<EndpointId, mpsc::Sender>`, idle LRU, `FuturesUnordered`      | **immortal** — owner-sender cycle, no shutdown message                           |
| pool connection actor (1/remote)        | [`connection_pool.rs:176`][conn-pool]                                                  | `RequestRef` mpsc(100)                                       | one QUIC `Connection`, `ConnectionCounter`, idle timer                 | main actor drops sender (idle timeout / conn close / eviction)                   |
| docs `SyncHandle` actor                 | [`actor.rs:289`][docs-actor] (**bare `std::thread`** + current-thread rt + `LocalSet`) | `Action` `async_channel`(1024)                               | redb store, open replicas, reply-streamer `JoinSet`                    | `Shutdown` action / channel close; thread joined on last handle drop             |
| docs `LiveActor`                        | [`engine.rs:126`][docs-engine]                                                         | `ToLiveActor` mpsc(64); replica events `async_channel`(1024) | 3 `JoinSet`s (connect/accept syncs, downloads), gossip state           | `Shutdown` msg, ordered                                                          |
| gossip net `Actor` (1)                  | [`net.rs:206`][gossip-net]                                                             | local mpsc(16), rpc mpsc(64), in-events mpsc(1024)           | sans-IO `proto::State`, `TimerMap`, `Dialer` `JoinSet`, conn `JoinSet` | `Shutdown` msg or all handles dropped                                            |
| gossip connection task (1/peer)         | [`net.rs:545`][gossip-net]                                                             | send queue mpsc(64)                                          | read: `FuturesUnordered` of stream reads; write: finish `JoinSet`      | connection close                                                                 |
| gossip topic subscriber forwarder       | [`net.rs:933`][gossip-net]                                                             | `broadcast::Receiver`(256)                                   | —                                                                      | broadcast closed / receiver gone                                                 |
| irpc `rpc::listen` accept loop          | [`irpc/lib.rs:2485`][irpc-lib]                                                         | —                                                            | `JoinSet` per accepted connection                                      | connection `ApplicationClosed(0)`                                                |
| metrics `MetricsServer`/`Dumper`/`Push` | [`iroh-metrics/service.rs`][iroh-metrics]                                              | —                                                            | HTTP scrape / CSV / push-gateway loop                                  | `CancellationToken` + `AbortOnDropHandle`                                        |

### Channels, by kind

| Kind                        | Representative sites                                                                                                                        | Purpose                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `tokio::sync::mpsc` bounded | every actor inbox above; blobs request/progress streams; provider events channel                                                            | actor inboxes; capacity = backpressure or drop policy   |
| `tokio::sync::oneshot`      | ~40 call sites: [`socket.rs:1325`][socket], [`remote_map.rs:266`][remote-map], blobs [`meta.rs`][blobs-meta], docs [`actor.rs`][docs-actor] | request/reply into actors                               |
| `tokio::sync::watch`        | portmapper external-address ([`socket.rs:1509`][socket]); relay rate-limit live update; blobs per-blob storage state                        | last-value config/state propagation                     |
| `tokio::sync::broadcast`    | per-connection path events, cap 8 (`path_watcher.rs:50`); gossip topic events, cap 256 ([`net.rs:824`][gossip-net])                         | multi-subscriber fan-out with `Lagged` on overflow      |
| `tokio::sync::Notify`       | path-state change (`path_watcher.rs:134`); relay `clearable_timeout`; connection-pool `ConnectionCounter`                                   | edge-triggered wakeup without payload                   |
| `async_channel` (MPMC)      | docs action inbox ([`actor.rs:274`][docs-actor]); replica event subscribers; replica events to `LiveActor` (cap 1024)                       | crosses the `std::thread` boundary; cloneable receivers |
| `n0-watcher` `Watchable`    | net-report `(Option<Report>, UpdateReason)`; `DiscoveredDirectAddrs.addrs`; `HomeRelayWatch`; the public `Endpoint::watch_addr` API         | last-value-wins observation, including public API       |
| `irpc` typed channel        | `Client<S>` local path = plain `tokio` mpsc/oneshot; remote path = `noq` bidi stream framed `varint-len ++ postcard`                        | the [RPC seam][irpc-docs] behind blobs/docs/gossip APIs |

### Locks, and what they guard

| Lock                                                                                        | Guards                                                 | Contention profile                               |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------ |
| `Mutex<Option<AbortOnDropHandle<()>>>` ([`socket.rs:209`][socket])                          | task handle for shutdown                               | once, at close                                   |
| `Arc<AsyncMutex<net_report::Client>>` ([`socket.rs:712`][socket])                           | one-report-at-a-time gate (`try_lock_owned` as a flag) | never contended — used as a boolean              |
| `AddrMap: Arc<std::sync::Mutex<AddrMapInner>>` ([`mapped_addrs.rs:330`][mapped-addrs])      | EndpointId/relay ↔ mapped-IPv6 bimaps                  | short critical sections on send/recv translation |
| `ConcurrentReadMap` (papaya, lock-free, [`concurrent_read_map.rs:19`][concurrent-read-map]) | per-remote actor senders; single writer via `&mut`     | **hot read** on datagram dispatch                |
| `path_watcher Mutex<State> + Notify`                                                        | per-conn path list + selected path                     | writer = `RemoteStateActor`, readers = API       |
| address-lookup `Arc<RwLock<Vec<Box<dyn AddressLookup>>>>`                                   | service registry / cached data                         | cold                                             |
| relay server `DashMap` ×2 ([`clients.rs`][relay-server])                                    | client registry + sent-to sets                         | per-packet lookup, sharded                       |
| blobs `Arc<Mutex<DeleteSet>>`, `TempTagScope(Mutex<…>)`                                     | gc protection, temp tags                               | short                                            |
| docs `ProviderNodes(Arc<std::sync::Mutex<HashMap>>)` ([`live.rs:899`][docs-live])           | live-sync provider map                                 | cold (only insert; never pruned)                 |
| gossip `NodeMap = Arc<RwLock<BTreeMap>>`                                                    | gossip-learned addresses                               | cold + evict interval                            |
| `n0-watcher` `RwLock<State> + Mutex<VecDeque<Waker>>`                                       | every watchable read/set                               | every `get`/`set`/poll                           |
| metrics `Counter`/`Gauge` = `portable_atomic`, `Family = Arc<RwLock<…>>`                    | metric cells / label-set map                           | lock-free inc from any thread                    |

### `select!` loops (arm count → purpose)

| Site                                                        | Arms                                                                                                                                                                                                   | Notes                              |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------- |
| socket actor [`socket.rs:1519`][socket]                     | 10: shutdown / inbox / re-stun tick / local-addr watch / net-report watch / direct-addr-done / portmap watch / netmon watch / remote-map cleanup / `MaybeFuture` backoff                               | the endpoint's "main thread"       |
| [`remote_state.rs:272`][remote-state]                       | 11, `biased`: shutdown / inbox / path events / NAT-addr events / conn-close futures / direct-addr watch / scheduled path open / scheduled holepunch / addr-lookup stream / upgrade tick / idle timeout | per-remote brain                   |
| relay `actor.rs:1023` (`RelayActor`)                        | 5, `biased`: cancel / `JoinSet` reap / inbox / send channel (gated on in-flight send) / pending send future                                                                                            | backpressure by arm-gating         |
| relay [`actor.rs:416/543/747`][relay-actor]                 | 6–8 each, `biased`: dialing / connected / sending FSM                                                                                                                                                  | three-phase connection FSM         |
| net-report [`net_report.rs:560`][net-report-src]            | 3, `biased`: shutdown / v4 `JoinSet` / v6 `JoinSet`                                                                                                                                                    | QAD probe collection, early-cancel |
| [`protocol.rs:528`][protocol]                               | 3, `biased`: cancel / `JoinSet` reap (break on panic) / accept                                                                                                                                         | `Router`                           |
| relay server [`client.rs:348`][relay-server-client]         | 6, `biased`: done / client frame / packet queue / message queue / pong timeout / keepalive tick                                                                                                        | per-client io actor                |
| blobs [`fs.rs:604`][blobs-fs]                               | 4: entity-manager tick / cmds / fs-cmds / `JoinSet` reap + idle-waiter flush                                                                                                                           | store main loop                    |
| blobs [`downloader.rs:94/213`][downloader]                  | 2 + 3: inbox / `join_next`; progress / part results / `tx.closed()`                                                                                                                                    | swarm download + split driver      |
| pool connection actor [`connection_pool.rs:226`][conn-pool] | 4, `biased`: inbox / `conn.closed()` / idle-stream / idle timer                                                                                                                                        | per-connection lifecycle           |
| docs [`live.rs:245`][docs-live]                             | 6, `biased`: inbox / replica events / connect-sync / accept-sync / download `JoinSet` / gossip progress                                                                                                | sync coordinator                   |
| gossip [`net.rs:383`][gossip-net]                           | 9, `biased`: local inbox / rpc inbox / command streams / addr updates / dialer / in-events / timers / conn `JoinSet` / forwarder `JoinSet`                                                             | the gossip event loop              |

### `spawn_blocking`, dedicated threads, and dedicated runtimes

| Site                              | What blocks                                                                                                                                                      | Why                                                             |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| relay server `main.rs:627`        | TLS key/cert load + parse at startup                                                                                                                             | **the only `spawn_blocking` in all five trees**                 |
| blobs [`fs.rs:1400`][blobs-fs]    | dedicated multi-thread runtime `iroh-blob-store-N`                                                                                                               | blocking `std::fs` + redb + BLAKE3 hashing run **inline** on it |
| docs [`actor.rs:289`][docs-actor] | dedicated `std::thread` "sync-actor" (current-thread rt + `LocalSet`)                                                                                            | blocking redb; async facade via `async_channel`                 |
| CPU crypto                        | BLAKE3/bao `init_outboard` hashes 16 KiB groups inline between awaits ([`util.rs:308-330`][blobs-util]); explicit `yield_now().await` in 64 KiB–1 MiB copy loops | cooperative chunking instead of thread offload                  |
| qlog sink                         | synchronous buffered file `write` under `Arc<Mutex<QlogStreamer>>` inside the noq connection's packet path ([`noq-proto/…/qlog.rs`][noq-qlog])                   | tracing writes on the datapath (feature-gated ZST when off)     |

> [!IMPORTANT]
> There is **zero `spawn_blocking` in `iroh-blobs`**. The 0.x folklore "iroh-blobs offloads file I/O with `spawn_blocking`" is false in v0.103.0: blocking `std::fs`, redb transactions, and BLAKE3 hashing all run _inline_ on a dedicated multi-thread runtime whose threads nothing else touches. This is the single most important fact for the port's throughput story — see [Mapping to event-horizon](#mapping-to-event-horizon).

### Timers and intervals (steady state)

| Timer                                                                          | Value                                     | Site                                  |
| ------------------------------------------------------------------------------ | ----------------------------------------- | ------------------------------------- |
| re-stun (net-report refresh) interval                                          | random 20–26 s                            | [`socket.rs:2004`][socket]            |
| `FULL_REPORT_INTERVAL`                                                         | 5 min                                     | [`net_report.rs:132`][net-report-src] |
| `NET_REPORT_TIMEOUT` / `OVERALL_REPORT_TIMEOUT`                                | 10 s / 5 s                                | `defaults.rs`                         |
| relay `PING_INTERVAL` / `RELAY_INACTIVE_CLEANUP_TIME` / `CONNECT_TIMEOUT`      | 15 s / 60 s / 10 s                        | [`actor.rs`][relay-actor]             |
| holepunch retry / connection upgrade / actor idle                              | 5 s / 60 s / 60 s                         | [`remote_state.rs`][remote-state]     |
| `HEARTBEAT_INTERVAL` / `PATH_MAX_IDLE_TIMEOUT` / `RELAY_PATH_MAX_IDLE_TIMEOUT` | 5 s / 15 s / 30 s                         | [`socket.rs:109`][socket]             |
| pool `idle_timeout` / `connect_timeout`                                        | 5 s / **1 s** (incl. `on_connected` hook) | [`connection_pool.rs`][conn-pool]     |
| pkarr republish                                                                | 5 min                                     | `pkarr.rs:146`                        |
| docs `MAX_COMMIT_DELAY`                                                        | 500 ms                                    | [`actor.rs:36`][docs-actor]           |
| gossip `TimerMap`                                                              | protocol-driven, earliest-sleep           | [`net/util.rs:400`][gossip-util]      |

---

## Pattern taxonomy: protocol-inherent vs `Send + Sync` artifact

The whole point of the census is this split.

**Inherent to the protocol** (must exist in any implementation):

- Every timer in the table above; the [`ActiveRelayActor`][relay] connection FSM with exponential backoff (10 ms → 16 s, jittered, reset after an established Pong); the drop policies on relay datagram queues (the relay is best-effort by design); the "enough reports → cancel the rest" probe race in [net-report][net-report]; per-peer/per-connection concurrent I/O (multiple relays, multiple streams, dial-while-receiving); the idle-out of per-remote actors (a memory bound); watcher _semantics_ (last-value-wins, notify-on-change), which are public API; and ordered graceful shutdown.

**Artifacts of `Send + Sync` multithreading** (vanish or simplify under `single` topology):

- Every `Arc<Mutex/RwLock>`, `DashMap`, and `papaya` map becomes a plain field owned by the loop fiber. `AddrMap`, `ConcurrentReadMap`, and the relay `Clients` registry become ordinary hash maps.
- Every `oneshot` request/reply becomes a direct call into the owning fiber's state, or a `fork`/`join`.
- `Watchable`'s waker queue + epoch double-check (a lost-wakeup race) reduces to `struct { value; epoch; waiterList }` with no races possible.
- The `AsyncMutex` used as a "report running" flag becomes a plain `bool`.
- `AtomicBool`/`AtomicU64` (`ipv6_reported`, shutdown `closed`, task counters) become plain fields.
- The **`RemoteStateActor` leftover-message restart protocol** ([`remote_map.rs:230-311`][remote-map]) — a genuinely intricate dance where a dying actor returns its unprocessed inbox and the map either removes its sender or restarts it with the messages re-injected — exists _only_ because the sender map's readers race with actor death across tasks. With one loop, "actor death" and "map cleanup" are atomic; the whole mechanism deletes.
- The pool's **immortal main actor** ([`connection_pool.rs:315-319`][conn-pool]), which can never observe all-senders-dropped because its shared `Context` holds a clone of its own inbox sender — a design forced by detached spawning — is fixed for free by structural ownership: a `Scope`-owned struct's teardown is scope exit.
- The dedicated runtime/thread for blobs and docs storage exists because blocking file/DB I/O must not stall the network runtime. Under event-horizon, _file_ I/O is native `io_uring` and needs no offload; what remains is the harder residue below.
- The `TaskTracker` + `CancellationToken` wrapper that iroh retrofits around every noq/quinn driver task ([`runtime.rs`][runtime]) — a structured-concurrency retrofit over an unstructured spawner — becomes native: the D QUIC drivers are fibers in the endpoint's `Scope`, and scope exit _is_ the tracker. The entire `runtime.rs` file evaporates.

**Genuinely hard single-threaded** (neither pure protocol nor free to delete):

1. **CPU-bound BLAKE3/bao hashing during [verified streaming][bao-tree] and import.** Rust runs it inline on a _dedicated multi-thread runtime_ so the endpoint never stalls. A single event loop stalls **all** networking for the duration of a hash burst. The Rust code shows the mitigation shape — hash one 16 KiB chunk group per step with an await between groups, plus explicit `yield_now` in copy loops — but that only cooperates _within_ one runtime; it does not free the loop thread the way a second thread does.
2. **Embedded blocking database** (redb, under blobs `meta` and docs storage): there is no `io_uring` story for an mmap-backed embedded KV store; it needs a worker thread with completion injection, or a redesign to an async-friendly store.

Both are treated in [Mapping to event-horizon](#mapping-to-event-horizon) and are load-bearing inputs to the [D architecture migration][d-arch].

---

## Analysis

### The tokio → event-horizon translation table

Each pattern maps to a specific [event-horizon][eh-spec] construct or is flagged as a gap requiring new design. Section references are to [SPEC.md][eh-spec].

| tokio / iroh pattern                               | event-horizon construct                                                                                                                                                     | Notes / gaps                                                                                                                       |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `tokio::spawn` + `JoinHandle`                      | `Scope.spawn` / `Scope.fork` → `JoinHandle.join` (§8.1)                                                                                                                     | outcome is `Outcome!(T, E)`; a `panic`/`Throwable` maps to `Cause.die`                                                             |
| `AbortOnDropHandle`                                | child fiber in a scope; scope exit cancels (`spawnDaemon` + `sc.cancel`)                                                                                                    | drop-based abort becomes _structural_ — the owner scope's exit                                                                     |
| `JoinSet<T>` + `join_next`                         | **no direct primitive** — build a `TaskSet` over the O20 channel: each child pushes `(id, Outcome)` on completion; `joinNext` = channel recv                                | `race` is wrong (it cancels losers). Needed by `RemoteMap`, `RelayActor`, `Router`, gossip, blobs, docs                            |
| `CancellationToken` tree, `run_until_cancelled`    | `CancelContext` tree + `Scope.cancel(Interrupt)`; checkpoints deliver it (§8.2, §8.4)                                                                                       | the two-token `ShutdownState` (`at_close_start`, `at_endpoint_closed`) maps to two nested scopes                                   |
| `token.drop_guard()`                               | `onExit` hook cancelling a child scope (LIFO, §8.1)                                                                                                                         | —                                                                                                                                  |
| `tokio::select!` over event sources                | **not `race`** — one owner fiber blocking on a single **inbox channel** (O20), with one daemon fiber per event source forwarding into it                                    | tokio `select!` polls `&mut` futures _without cancelling them_; `race` cancels losers. This is the single most load-bearing gap    |
| `mpsc::channel(n)` bounded                         | **GAP — [open-issue O20][eh-spec]** (no cross-fiber channel in v1)                                                                                                          | needs: bounded ring, sender-park-on-full, `trySend` for drop sites, `recvMany` batch drain, close semantics. Capacities are policy |
| `oneshot`                                          | `fork` + `JoinHandle.join`; or a one-slot rendezvous (`isWaker` handle) inside the message                                                                                  | single-threaded — no atomics needed                                                                                                |
| `tokio::sync::watch` / `n0-watcher` `Watchable`    | **no direct equivalent** — port `n0-watcher`'s semantics (they are public API): `struct Watchable(T) { T value; ulong epoch; WaiterList waiters; }`                         | `map`/`or`/`Join` are direct transliterations; `Disconnected` tied to scope/refcount lifetime                                      |
| `broadcast::channel(n)` + `Lagged`                 | per-topic ring buffer + per-subscriber cursor; a subscriber > `n` behind gets `Lagged{missed}` and snaps to head                                                            | small library type over the watcher/waiter list                                                                                    |
| `Notify`                                           | `isWaker` one-shot park/wake (§10.3)                                                                                                                                        | direct fit                                                                                                                         |
| `time::interval` + `MissedTickBehavior`            | `repeat` driver with a `spaced` schedule (§10.4)                                                                                                                            | intervals that `reset()` on traffic (relay ping) need a re-armable timer: `cancel(h)` + `submitAfter`                              |
| resettable `Sleep` (`inactive_timeout.reset`)      | keep an `OpHandle` to an in-ring `TIMEOUT`; reset = `cancel` + `submitAfter` (§5.3)                                                                                         | 5+ sites — worth a small `ResettableTimer` utility                                                                                 |
| `MaybeFuture` in `select!`                         | conditionally-armed `TIMEOUT` op — arm only when state says so                                                                                                              | trivial once `select!` is an inbox: the forwarder fiber just is not running                                                        |
| `timeout(d, fut)`                                  | `withDeadline` / `timeout` driver (§8.3, §10.4)                                                                                                                             | interrupt kind `deadline`                                                                                                          |
| backon `ExponentialBuilder{10ms→16s, jitter}`      | `Schedule`: `exponential(10.msecs) & upTo(16.seconds)` + `jittered`, via `retry` (§10.4)                                                                                    | `retry` consumes only the `fail` channel — matches "reset backoff after established" needing a manual policy reset, as Rust does   |
| `spawn_blocking` (1 site: TLS load)                | do it synchronously during startup, before the loop is hot                                                                                                                  | zero-cost                                                                                                                          |
| blobs dedicated runtime / docs `std::thread`       | either strict cooperative chunking on the single loop (yield every N chunk groups — _measure_), or a second worker via `Topology.threadPerCore` + `postTo`/`MSG_RING` (§11) | **decision point** — `io_uring` removes the file-I/O half of the reason; the CPU-hash and embedded-DB halves remain                |
| `TaskTracker` (quinn runtime wrapper)              | native QUIC drivers are fibers in the endpoint's scope; scope exit joins them (§8.1)                                                                                        | the entire `runtime.rs` evaporates                                                                                                 |
| `papaya`/`DashMap` concurrent maps                 | plain `HashMap`-equivalents owned by the loop fiber                                                                                                                         | under `single`, cross-"task" reads are same-thread                                                                                 |
| `PollSender` / manual `poll_recv` glue into quinn  | disappears — the D QUIC stack speaks tier-B verbs / tier-A callbacks directly                                                                                               | the poll-based seam is a Rust-ecosystem artifact                                                                                   |
| `async_channel` MPMC across the storage thread     | if storage stays on-loop: plain O20 channel; if a second loop: `MSG_RING`-backed cross-ring channel                                                                         | only needed for the worker-offload design                                                                                          |
| `irpc` local channel + `noq`-stream remote channel | direct capability calls in-process; framed tier-B fiber loops on the wire ([wire-serialization][wire])                                                                      | keep the request-enum _design_, drop the proc-macro; local path can monomorphize away entirely                                     |

### Mapping to event-horizon

Four themes dominate the port, in decreasing order of difficulty.

**1. The missing cross-fiber channel (open-issue O20) is the load-bearing gap.** Event-horizon v1 has structured concurrency (`Scope`, `fork`, `JoinHandle`, `race`), cancellation (`CancelContext`, `withDeadline`), and one-shot park/wake (`isWaker`), but [no cross-fiber channel primitive][eh-spec] — the spec names it as a recognised gap. **Every actor in the inventory is an inbox loop**, so the port cannot proceed without a channel design. The needed shape is fully specified by the census: a bounded ring of `T` with sender-park-on-full for backpressure sites, `trySend` returning `Full` vs `Closed` for the _drop_ sites (relay datagram queues, the `try_send` network-change fan-out), a `recvMany` batch drain for the relay's 20-datagram `recv_many` batching, and close semantics (recv returns none when all senders drop). Because callers and the owning fiber share one thread under `single`, request/reply `oneshot` traffic can bypass the channel entirely — a direct method call plus a parked-fiber rendezvous is equivalent — but the _stream_ fan-ins (split-download progress, gossip topic events) genuinely need the queue.

Critically, a tokio `select!` loop does **not** translate to `race`: `select!` polls its arms _without cancelling them_ across loop iterations, whereas event-horizon's `race` cancels the losers (§10.4). The faithful translation of every actor is one long-lived owner fiber blocking on a single inbox channel, fed by one daemon forwarder fiber per event source (a `sleep` fiber for a timer, a watcher fiber for a `Watchable`, a `TaskSet` for child completions). An `if guard` arm becomes "do not run that forwarder"; a `MaybeFuture` arm becomes "only arm that `TIMEOUT` when the state says so". Side by side:

```rust
// Rust — the socket actor's select! loop (trimmed), iroh/src/socket.rs:1519
loop {
    tokio::select! {
        _ = shutdown_token.cancelled() => break,
        Some(msg) = inbox.recv() => self.handle_message(msg),
        _ = re_stun_timer.tick() => self.trigger_net_report(),
        Ok(()) = local_addrs_watcher.updated() => self.on_local_addrs_change(),
        // … 6 more arms: net-report watch, direct-addr-done, portmap, netmon,
        //   remote-map cleanup, MaybeFuture backoff
    }
}
```

```d
// PROPOSED / SKETCH — one owner fiber + forwarder daemons + one inbox (O20).
// The `select!` collapses into a single blocking recv; every other source is a
// daemon fiber that forwards a tagged message into the same inbox.
void runSocketActor(ref RootScope sc, ref Env env, Chan!ActorEvent inbox)
{
    // Forwarders: each parks on ITS source and posts into the shared inbox.
    sc.spawnDaemon({ repeat(sc, env.clock, spaced(restunInterval()),
                            { inbox.send(ActorEvent.reStunTick); return ioOk(); }); });
    sc.spawnDaemon({ foreach (v; localAddrsWatcher.updates)          // watcher fiber
                         inbox.send(ActorEvent.localAddrs(v)); });
    // … one daemon per net-report watch / portmap / netmon / remote-map cleanup

    // The owner: no locks, no Arc — `RemoteMap` etc. are plain owned fields.
    for (;;)
    {
        auto ev = inbox.recv();                 // parks; the ONLY multiplex point
        if (ev.hasError) break;                 // all senders dropped ⇒ shutdown
        final switch (ev.value.kind) with (ActorEvent.Kind)
        {
            case message:    handleMessage(ev.value.msg);       break;
            case reStunTick: triggerNetReport();                break;
            case localAddrs: onLocalAddrsChange(ev.value.addrs); break;
            // …
        }
    }
    // scope exit joins/cancels every forwarder daemon — no CancellationToken tree
}
```

**2. `Watchable` is public API and must be ported faithfully — but drops all its synchronisation.** The single-threaded rewrite has no `Arc`, no `RwLock`, no waker `Mutex`; the lost-wakeup double-check is impossible because there is no concurrent poll:

```rust
// Rust — n0-watcher/src/lib.rs:96-99, 763-774 (the synchronised original)
pub struct Watchable<T> { shared: Arc<Shared<T>> }
struct Shared<T> {
    state: RwLock<State<T>>,       // { value: T, epoch: u64 }
    wakers: Mutex<VecDeque<Waker>>,
}
```

```d
// PROPOSED / SKETCH — single-thread Watchable; T must be equality-comparable.
struct Watchable(T)
if (__traits(compiles, (T a, T b) => a == b))
{
    private T value;
    private ulong epoch;
    private WaiterList waiters;              // intrusive list of isWaker handles

    /// Dedup on equality (n0-watcher semantics): wake watchers only on change.
    void set(T next)
    {
        if (next == value) return;
        value = next;
        epoch++;
        waiters.wakeAll();                   // resume every parked watcher fiber
    }

    ref const(T) peek() const return => value;
}

/// Watcher.updated: park until the epoch advances past what we last saw.
IoResult!T updated(Watcher)(ref Watcher w)      // proposed
{
    while (w.seenEpoch == w.src.epoch)
        w.src.waiters.park(currentTask);         // no lost-wakeup race single-threaded
    w.seenEpoch = w.src.epoch;
    return ioOk(w.src.peek);
}
```

The `map`/`or`/`Join` combinators are straight transliterations — they poll children and combine, adding no machinery — and `map`'s output-dedup must be kept or downstream watchers spin. `broadcast` + `Lagged` is the same waiter list plus a per-subscriber cursor. This machinery underpins the whole public watcher surface consumed by [socket][socket], [discovery][discovery], and [endpoint][endpoint].

**3. `spawn_blocking` has no thread pool — and mostly does not need one.** Event-horizon exposes no blocking-work executor. Three of the census's five offload sites dissolve: the lone `spawn_blocking` (relay TLS load) runs synchronously at startup before the loop is hot; file I/O is native `io_uring`, so the _file-I/O_ justification for the blobs and docs dedicated runtimes disappears. What genuinely remains is CPU hashing and the embedded DB:

- **BLAKE3/bao on the loop thread.** This is the one place where single-threading has a real throughput cost. A `read_at`/import of a large blob hashes megabytes; on one loop that stalls all networking for the burst. Two viable designs, both flagged for [bao-tree][bao-tree] and [blobs][blobs]: **(a)** enforce a `yieldNow` checkpoint every _N_ chunk groups (budgeted — a 1 MiB group is tens of microseconds of BLAKE3), accepting that hashing throughput and network latency are coupled; or **(b)** run the store on a second worker via `Topology.threadPerCore` and `LoopGroup.postTo`, harvesting results with `MSG_RING` completions (§11) — mirroring Rust's dedicated-runtime architecture exactly. The census shows Rust chose (b) for exactly this reason; the port's choice is a measured trade-off, not an obvious one.
- **The redb-style embedded DB** under blobs `meta` and docs storage has no `io_uring` path (it is mmap + blocking syscalls). It needs a worker thread with completion injection, or a redesign to an on-loop async store. This is the residual reason the docs storage actor is a bare `std::thread` rather than a task.

**4. Everything else is a simplification.** The `JoinSet`-reaping loops become a `TaskSet` built on the O20 channel (a spawn-wrapper fiber sends `(id, Outcome)` on completion; `joinNext` is a channel recv). The `CancellationToken` trees map onto `CancelContext` + `Scope.cancel`, with the two-token `ShutdownState` becoming two nested scopes. The [`irpc`][irpc-docs] seam keeps its essential design — one serializable request enum, a per-variant `(Tx, Rx)` channel mapping, a message type = request ⊗ live channels — but drops the proc-macro for D compile-time introspection (`static foreach` over `__traits(allMembers)`), and the _local_ path monomorphizes to direct capability calls, achieving the "zero overhead in-process" goal irpc only approximates. The gossip protocol core is already sans-IO (`InEvent`/`OutEvent`, a `BTreeMap` `TimerMap`, zero `tokio`), so the D port of the gossip logic is a state-machine _transliteration_, not an async rewrite — and the same sans-IO discipline in [noq-proto][quic] means the deterministic `Pair` conformance rig maps directly onto event-horizon's `TestClock` + `TestSched.advanceAndSettle`, giving the port test determinism that _exceeds_ upstream's (whose iroh-level tests fall back to `sleep(100–200ms)` settling waits).

**One hazard survives the translation.** The docs `LiveActor` carries the warning that its self-send channel deadlocks if used from the actor's own methods:

> _"Send messages to self. Note: Must not be used in methods called from `Self::run` directly to prevent deadlocks. Only clone into newly spawned tasks."_ — [`iroh-docs/src/engine/live.rs:157-159`][docs-live]

The D equivalent — a fiber sending into its own full inbox — deadlocks identically. Inbox self-sends must be `trySend` or deferred; the single-threaded model removes the _lock_ hazards but not this _logical_ one. Likewise the bounded-channel _arm-gating_ trick (the `RelayActor` stops reading its input while its output is full, to preserve ordering and drop behaviour) must be reproduced deliberately: "park on send" gives the backpressure, but the gating that stops consuming upstream is a policy the port must re-implement.

---

## Strengths

Assessed as a _porting target_ — how amenable the concurrency architecture is to a clean-room single-threaded reimplementation:

- **Actor-per-subsystem with explicit inboxes** is the friendliest possible shape for a fiber port: each actor becomes one owner fiber, and its bounded inbox capacity is a documented policy constant to carry over verbatim.
- **Minimal shared-mutable-state on hot paths.** The locks are almost all cold config or tiny bimaps; the one hot structure (`ConcurrentReadMap`) exists solely for cross-task datagram dispatch and simply becomes a field. Most of the census's synchronisation is _deletable_, not _translatable_.
- **`n0-future` is a thin shim, not a runtime.** The native path is a re-export of `tokio`; the only novel type (`MaybeFuture`) has a trivial single-threaded equivalent. There is no bespoke scheduler to reverse-engineer.
- **Sans-IO cores where it matters most.** [gossip][gossip]'s `proto/` and [noq-proto][quic]'s connection state machine are pure `InEvent`/`OutEvent` machines with zero `tokio`; they transliterate rather than rewrite, and they bring a ready-made deterministic test rig.
- **Cancellation is already structured in intent.** `CancellationToken` trees, `AbortOnDropHandle`, `run_until_cancelled`, ordered graceful shutdown — the _design_ is structured concurrency retrofitted onto an unstructured spawner. Event-horizon's `Scope` provides natively what iroh assembles by hand, so the port is often _simpler_ than the original.

## Weaknesses

- **The channel gap (O20) blocks nearly everything.** Every actor is an inbox loop, so the port cannot start subsystem work before landing a cross-fiber channel design — the largest single prerequisite.
- **CPU-bound BLAKE3/bao is a genuine single-thread hazard.** Rust hides it behind a dedicated multi-thread runtime; the port must choose between cooperative chunking (coupling hash throughput to network latency) and a second worker loop (reintroducing cross-loop plumbing). Neither is free.
- **Embedded blocking databases have no completion-model home.** redb is mmap + blocking syscalls; there is no `io_uring` translation, only a worker thread or a store redesign.
- **Some patterns look mappable but are not.** `tokio::select!` is _not_ `race`; a naive translation that cancels losers is a correctness bug. The distinction must be understood per loop.
- **Backpressure semantics are subtle and load-bearing.** The relay's arm-gating, the many `try_send`-and-drop sites, and the docs self-send deadlock are policy that the "park on send" default does not reproduce automatically.
- **Two extra runtimes encode assumptions.** blobs' multi-thread pool and docs' `std::thread` bake in "storage must never stall the network runtime" — an assumption a single-loop port must re-satisfy explicitly rather than inherit.

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                                                                 | Trade-off                                                                                                                                                 |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tree of single-consumer actors over bounded `mpsc` (iroh)               | Isolates state per subsystem; backpressure and drop policy are explicit per channel                                       | Every subsystem needs a cross-fiber channel to port ([O20][eh-spec]) — the whole port waits on one primitive                                              |
| Model actor `select!` as one owner fiber + forwarder daemons (port)     | Faithful to tokio's poll-without-cancel semantics; `race` would wrongly cancel losers                                     | One extra daemon fiber per event source; ordering across sources must be re-established via inbox tagging                                                 |
| Delete all `Arc<Mutex>`/atomics/`papaya` under `single` topology (port) | Single-thread ownership removes every data race; no locks needed                                                          | Requires auditing each lock's _reason_ — a few (self-send deadlock, arm-gating) are logical, not just sync                                                |
| Port `Watchable` semantics but drop its synchronisation (port)          | Last-value-wins observation is public API; the epoch double-check is a lost-wakeup guard that cannot fire single-threaded | Must preserve `Eq`-dedup on `set` and `map` or watchers spin; combinators are hand-transliterated                                                         |
| Run BLAKE3/bao on the loop thread with cooperative yields (option A)    | No second thread, no cross-loop plumbing; matches event-horizon's `single` default                                        | Hash bursts couple to network latency; a large import visibly stalls I/O unless the yield budget is tuned                                                 |
| Or run the store on a second worker loop with `MSG_RING` (option B)     | Mirrors Rust's dedicated runtime; keeps the network loop responsive during hashing                                        | Reintroduces cross-ring channels, `postTo`, and share-nothing message passing — the complexity `single` avoids                                            |
| Keep the `irpc` request-enum design, drop the proc-macro (port)         | The seam (request ⊗ live channels, local/remote sum) is sound; D introspection generates it                               | The local path can monomorphize to direct calls — better than irpc's channel-send approximation — but the remote framed-stream loop must be built by hand |
| No `spawn_blocking` executor in the target runtime                      | Startup blocking is done synchronously; file I/O is native `io_uring`                                                     | The embedded DB has no home — needs a worker thread with completion injection or a store redesign                                                         |
| Structural scope teardown replaces `TaskTracker`/`AbortOnDropHandle`    | Scope exit joins/cancels children natively; the pool's immortal-actor bug is fixed for free                               | Requires re-expressing every detached spawn as a scoped child — a discipline, not a drop-in                                                               |

---

## Sources

Primary sources (pinned revisions):

- [`n0-future`][n0-future] 0.3.2 — `task.rs` (native = `tokio` re-export), `time.rs`, `maybe_future.rs`.
- [`n0-watcher`][n0-watcher] 1.0.0 — `Watchable`/`Watcher`, epoch/waker machinery, combinators.
- [`iroh`][socket] 1.0.1 — `socket.rs`, `socket/remote_map*.rs`, `socket/transports/relay*.rs`, `net_report*.rs`, `protocol.rs`, `runtime.rs`, `endpoint.rs`; [`iroh-relay`][relay-server] server actors.
- [`iroh-blobs`][blobs-fs] 0.103.0 — FS/mem stores, `meta`/`entity_manager`, `api/downloader.rs`, `provider.rs`, `util.rs`.
- [`iroh-docs`][docs-actor] 0.101.0 — `actor.rs` (bare-thread storage), `engine.rs`, `engine/live.rs`.
- [`iroh-gossip`][gossip-net] 0.101.0 — `net.rs`, `net/util.rs` (sans-IO `proto::` core + `TimerMap`).
- [`iroh-util`][conn-pool] 0.6.0 — `connection_pool.rs`, `access_limit.rs`.
- [`irpc`][irpc-lib] 0.17.0 — typed-channel seam, `rpc::listen`, `NoqSender` framing.
- [`iroh-metrics`][iroh-metrics] 1.0.1 and [`noq-proto`][noq-qlog] qlog — observability actors and the on-datapath qlog write.
- Related surveys: [event-horizon SPEC][eh-spec]; async-I/O deep-dives [Tokio][tokio-async], [Glommio][glommio], [Monoio][monoio]; [algebraic effects][alg-effects].
- Sibling iroh pages this census feeds: [survey umbrella][index], [concepts][concepts], [identity & cryptography][identity], [wire formats][wire], [QUIC transport][quic], [endpoint & router][endpoint], [socket][socket-page], [NAT traversal][nat], [relay][relay], [discovery][discovery], [net report][net-report], [blobs][blobs], [bao-tree][bao-tree], [docs sync][docs-sync], [gossip][gossip], and the capstone [D architecture migration][d-arch].

<!-- References -->

[org]: https://github.com/n0-computer
[n0-future]: https://docs.rs/n0-future/0.3.2/n0_future/
[n0-watcher]: https://docs.rs/n0-watcher/1.0.0/n0_watcher/
[irpc-docs]: https://docs.rs/irpc/0.17.0/irpc/
[iroh-metrics]: https://docs.rs/iroh-metrics/1.0.1/iroh_metrics/
[socket]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/socket.rs
[remote-map]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/socket/remote_map.rs
[remote-state]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/socket/remote_map/remote_state.rs
[relay-transport]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/socket/transports/relay.rs
[relay-actor]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/socket/transports/relay/actor.rs
[concurrent-read-map]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/socket/concurrent_read_map.rs
[mapped-addrs]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/socket/mapped_addrs.rs
[net-report-src]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/net_report.rs
[reportgen]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/net_report/reportgen.rs
[protocol]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/protocol.rs
[runtime]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/runtime.rs
[endpoint-src]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/endpoint.rs
[relay-server]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh-relay/src/server.rs
[relay-server-client]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh-relay/src/server/client.rs
[blobs-fs]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs.rs
[blobs-meta]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs/meta.rs
[blobs-entity]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs/util/entity_manager.rs
[blobs-mem]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/mem.rs
[downloader]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/api/downloader.rs
[blobs-provider]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/provider.rs
[blobs-util]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/util.rs
[docs-actor]: https://github.com/n0-computer/iroh-docs/blob/v0.101.0/src/actor.rs
[docs-engine]: https://github.com/n0-computer/iroh-docs/blob/v0.101.0/src/engine.rs
[docs-live]: https://github.com/n0-computer/iroh-docs/blob/v0.101.0/src/engine/live.rs
[gossip-net]: https://github.com/n0-computer/iroh-gossip/blob/v0.101.0/src/net.rs
[gossip-util]: https://github.com/n0-computer/iroh-gossip/blob/v0.101.0/src/net/util.rs
[conn-pool]: https://github.com/n0-computer/iroh-util/blob/v0.6.0/src/connection_pool.rs
[irpc-lib]: https://github.com/n0-computer/irpc/blob/v0.17.0/src/lib.rs
[noq-qlog]: https://github.com/n0-computer/noq/blob/noq-v1.0.1/noq-proto/src/connection/qlog.rs
[eh-spec]: ../../specs/event-horizon/SPEC.md
[tokio-async]: ../async-io/tokio.md
[glommio]: ../async-io/glommio.md
[monoio]: ../async-io/monoio.md
[alg-effects]: ../algebraic-effects/index.md
[index]: ./index.md
[concepts]: ./concepts.md
[identity]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[quic]: ./quic-transport.md
[endpoint]: ./endpoint.md
[socket-page]: ./socket.md
[nat]: ./nat-traversal.md
[relay]: ./relay.md
[discovery]: ./discovery.md
[net-report]: ./net-report.md
[blobs]: ./blobs.md
[bao-tree]: ./bao-tree.md
[docs-sync]: ./docs-sync.md
[gossip]: ./gossip.md
[d-arch]: ./d-architecture-migration.md
