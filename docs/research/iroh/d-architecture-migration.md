# D Architecture Migration

The capstone of the iroh survey: the bridge from _how Rust iroh works_ to _how to
build it in D on [`sparkles:event-horizon`][eh-spec]_. It distils the fifteen
deep-dives into a per-subsystem port strategy, translates iroh's `tokio`
work-stealing concurrency onto a single-threaded completion loop, names the runtime
primitives event-horizon still owes the port, and lays out a layered build order —
each milestone cross-linking the prior-art page it draws on.

> [!NOTE]
> This is the _synthesis_ leaf of the survey. It assumes the per-subsystem mechanics
> ([the deep-dives](./index.md)) and the shared vocabulary ([concepts][concepts]) as
> given, and cross-links rather than re-derives them. The exhaustive census of every
> long-lived task, channel, lock, `select!` loop, and timer — with its
> construct-by-construct `tokio`→event-horizon translation table — lives in
> [Tokio Concurrency Inventory][concurrency]; this page builds the _plan_ on top of
> that census. The event-horizon analogue of async-io's [comparison][async-comparison].

**Last reviewed:** July 6, 2026

---

## Part 1 — The port at a glance

A native D reimplementation of iroh 1.0 is, before anything else, a reimplementation
of `noq` (n0's `quinn` fork) and a handful of protocol crates on top of it. The
survey establishes the two facts that make the port tractable: the QUIC core, the
gossip membership protocol, the docs range-reconciler, and the whole `bao-tree` codec
are **sans-io** — pure `(now, event) → (effects, deadline)` state machines with no
runtime baked in — and almost all of iroh's remaining concurrency is an _artifact_ of
`tokio`'s `Send + Sync` work-stealing model that event-horizon's `single` topology
refunds (see [Part 2](#part-2--the-concurrency-translation)).

### 1.1 The dependency-impact table

Each major Rust crate/subsystem, the D **strategy** that fits it, a rough **effort**
(LoC where the deep-dive counted them; T-shirt size otherwise), and the
event-horizon **primitives** it needs. Strategy legend: **native** = clean-room D
reimplementation; **sans-io reuse** = keep the Rust _design_ (the value-type state
machine) and re-house it on fibers, no line-for-line copy; **C-binding** = bind an
existing C library via ImportC rather than reimplement; **from-scratch** = a new D
component with no direct iroh analogue. The link cell points at the deep-dive.

| Subsystem (Rust crate/module)                                       | Size (Rust)             | D strategy                                          | Key event-horizon primitives                                                                                                        | Deep-dive                                            |
| ------------------------------------------------------------------- | ----------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| **Identity & crypto** (`iroh-base` `key.rs`, `iroh/src/tls`)        | ~1.2k + crypto          | native                                              | value structs; `Rng` capability; `SmallBuffer` codecs; `@safe pure nothrow @nogc`                                                   | [identity-crypto][identity]                          |
| **Ed25519 / SHA-512 / BLAKE3** (dalek, `blake3`)                    | (library)               | native or C-binding                                 | `verify_strict` interop-exact; BLAKE3 `hazmat` (chunk-counter CVs, ROOT flag)                                                       | [identity-crypto][identity] · [bao-tree][bao-tree]   |
| **Wire codec** (`postcard`, `iroh-tickets`, `iroh-base` addressing) | ~0.8k + codec           | native / from-scratch                               | CTFE `static foreach` over `tupleof`; LEB128 + QUIC-varint; `SmallBuffer`; `isOwnedIoBuf`                                           | [wire-serialization][wire]                           |
| **QUIC core** (`noq-proto`)                                         | ~38.2k non-test         | sans-io reuse                                       | one fiber owning `Connection`; tier-B verbs; one in-ring `TIMEOUT`; `SumType` controllers; **O19** msghdr; `WallClock` + `Rng` caps | [quic-transport][quic]                               |
| **TLS 1.3 + QUIC AEAD** (`rustls` + `ring`/`aws-lc-rs`)             | load-bearing            | C-binding **or** native (decision)                  | sans-io `Session` fed `CRYPTO` bytes; `PacketKey` with **`PathId`-aware** nonce                                                     | [identity-crypto][identity] · [quic-transport][quic] |
| **`noq-udp`** (platform UDP: GSO/GRO/ECN/pktinfo)                   | ~10k with `noq`         | native (per-OS syscalls)                            | `sendTo`/`recvFrom` verbs; **O19** msghdr/cmsg; `BufRing`                                                                           | [quic-transport][quic]                               |
| **Verified streaming** (`bao-tree`)                                 | ~5.6k                   | native (pure)                                       | `@safe pure nothrow @nogc` geometry; `SmallBuffer!(Hash,10)`; `isByteStream`; yield checkpoints                                     | [bao-tree][bao-tree]                                 |
| **Endpoint & Router** (`iroh` `endpoint`/`protocol`/`runtime`)      | ~6.1k non-test          | native (policy shell)                               | `Scope`; capability row; DbI `Connection<State>`; `ProtocolMap` AA; `Watchable`; memoized completion cell                           | [endpoint][endpoint]                                 |
| **Multipath socket** (`iroh` `socket`, ex-`magicsock`)              | ~8k non-test            | native                                              | per-transport recv fibers; multishot `BufRing`; plain `MappedAddrs`; `Watchable`; **O19**                                           | [socket][socket]                                     |
| **NAT traversal / QAD / QNT** (`noq-proto`, `iroh` `remote_state`)  | ~2.6k                   | sans-io reuse + native                              | value `ClientState`/`ServerState`; in-ring `TIMEOUT`; `race`; `Chan!T`                                                              | [nat-traversal][nat]                                 |
| **Relay** (`iroh-relay` + `iroh` relay transport)                   | ~12.3k + ~2.15k         | native (client first, server later)                 | WebSocket client; reconnect `Schedule`; TLS; `Chan!T` drop-queues                                                                   | [relay][relay]                                       |
| **Discovery** (`iroh` `address_lookup`, `iroh-dns`, `-server`)      | ~5k client + ~4k server | native + C-binding (DNS)                            | HTTP client; DNS wire codec; ed25519 `SignedPacket`; monotonic-CAS publisher                                                        | [discovery][discovery]                               |
| **Net report / netwatch / portmapper** (`net-tools`)                | ~10.5k                  | native + C-binding (iface enum)                     | per-OS interface watch; UPnP/PCP/NAT-PMP codecs; QAD probe; `Watchable`                                                             | [net-report][net-report]                             |
| **Blobs** (`iroh-blobs`)                                            | ~14k                    | native                                              | tier-B fibers; `isByteStream`; per-hash handle map; io_uring file ops; `Chan!T`; hash offload (decision)                            | [blobs][blobs]                                       |
| **Embedded KV store** (`redb`)                                      | (library)               | C-binding (LMDB) **or** from-scratch                | worker-thread-with-completion-injection **or** on-loop async store                                                                  | [blobs][blobs]                                       |
| **Docs sync** (`iroh-docs`)                                         | ~9k non-test            | native + sans-io reuse (`ranger`)                   | pure range reconciler; `SyncStore` fiber; `isContentStatus` cap; `TestClock`                                                        | [docs-sync][docs-sync]                               |
| **Gossip** (`iroh-gossip`)                                          | ~6.9k                   | sans-io reuse (`proto/` verbatim) + native (`net/`) | `GossipState` value type; `TimerMap`; broadcast + `Lagged`; `Scope`                                                                 | [gossip][gossip]                                     |
| **RPC seam** (`irpc`)                                               | ~2.7k                   | keep design, drop macro                             | DbI request enum; local path monomorphizes to direct calls; framed tier-B fiber remote                                              | [concurrency][concurrency] · [blobs][blobs]          |
| **Concurrency substrate** (`n0-future`, `n0-watcher`)               | ~3k shim                | native (mostly delete)                              | `Scope`/`fork`/`race`; port `Watchable` semantics faithfully (public API)                                                           | [concurrency][concurrency]                           |

### 1.2 The four strategies, and the size budget

The table clusters into four postures, in decreasing order of the ratio of _kept
design_ to _rewritten code_:

- **Sans-io reuse (the leverage).** `noq-proto`'s connection machine, `iroh-gossip`'s
  `proto/` HyParView/Plumtree core, `iroh-docs`'s `ranger`, and `bao-tree`'s codec are
  runtime-neutral by construction. The port keeps the algorithm and the value-type
  shape verbatim and simply drives it from a fiber instead of a `tokio` task — the
  `Arc<Mutex<State>>`, waker maps, `Notify`s, and self-wakes become _zero code_. The
  `noq-proto` crate root is explicit that this is licensed:

  > _"noq-proto contains a fully deterministic implementation of QUIC protocol logic.
  > It contains no networking code and does not get any relevant timestamps from the
  > operating system … or if you want to use a different event loop than the one tokio
  > provides."_ — [`noq-proto/src/lib.rs:3-8`][noq-lib]

- **Native reimplementation (the bulk).** The policy shells (endpoint/router, socket,
  relay client, discovery, blobs, docs `net/`) are a few thousand lines each of D over
  the sans-io cores. This is where iroh's identity model, its holepunching-tuned
  defaults, its wire framing, and its lifecycle live — all portable, most of it
  _simpler_ in D because event-horizon's `Scope` provides natively what iroh assembles
  by hand.

- **C-binding (the escape hatch).** Three subsystems can be bound rather than
  rewritten: the **TLS 1.3 + QUIC-AEAD** engine (bind a C QUIC-crypto library exposing
  the `PathId`-aware `PacketKey`, or reimplement a sans-io TLS 1.3), the **embedded KV
  store** (LMDB via ImportC in place of `redb`), and **platform interface/route
  enumeration** for net-report. Each is a decision the milestones flag, not a
  foregone conclusion.

- **From-scratch (the missing primitives).** A short list of runtime types
  event-horizon v1 does not ship — a cross-fiber channel, a `Watchable`, a bounded
  broadcast, a memoized completion cell — that _several_ subsystems need. These are
  [Part 4](#part-4--the-primitives-event-horizon-still-owes-the-port) and the gate on
  the whole port.

The **size budget** is dominated by one rock. `noq-proto` alone is ~38k non-test
lines with no external QUIC/CC/recovery library to lean on — BBRv3, Cubic, the pacer,
DPLPMTUD, the reassembler, and the token machinery are all in-tree ([quic][quic]).
Everything else combined — relay (~14k), net-tools (~10.5k), blobs (~14k), docs (~9k),
gossip (~6.9k), bao-tree (~5.6k), discovery (~9k), socket (~8k), endpoint (~6.1k) — is
the same order of magnitude _in aggregate_ as the single QUIC crate. The strategic
consequence: **the QUIC core is the critical path**, and the milestones ([Part
5](#part-5--the-layered-build-order)) are structured so that pure, testable value code
(crypto, wire, bao-tree) and the missing runtime primitives land _before_ the QUIC
core, so that when the big rock is being cut, its dependencies are already green.

---

## Part 2 — The concurrency translation

iroh is a **tree of single-consumer actors** connected by bounded
`tokio::sync::mpsc` channels, with `oneshot` for request/reply, [`n0-watcher`][concurrency]
watchables for last-value-wins state, and `CancellationToken` trees for shutdown —
almost every long-lived task a `loop { tokio::select! { … } }` over an inbox
([concurrency][concurrency]). event-horizon inverts every one of those axes: one loop
per thread, completion-first io_uring/kqueue/IOCP, fibers with structured concurrency,
and — under the default `single` topology — **no cross-thread sharing at all**.

### 2.1 `tokio` work-stealing → event-horizon single-thread thread-per-core

| Axis          | iroh on `tokio`                                                   | port on event-horizon                                                                             |
| ------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Scheduler     | multi-thread work-stealing; futures migrate across worker threads | one `Sched` per thread; a started fiber is **pinned for life** ([SPEC §11][eh-spec])              |
| Shared state  | `Arc<Mutex/RwLock>`, `AtomicU64`, `papaya`/`DashMap` on hot paths | plain fields owned by the loop fiber; no atomics, no locks under `single`                         |
| Task spawn    | `tokio::spawn` → `JoinHandle`; `AbortOnDropHandle`; `TaskTracker` | `Scope.spawn`/`fork` → `JoinHandle.join`; scope exit joins/cancels ([SPEC §8][eh-spec])           |
| Multiplex     | `tokio::select!` (polls arms _without_ cancelling them)           | one owner fiber blocking on an **inbox channel**, fed by forwarder daemons                        |
| Timers        | `tokio::time` `Sleep`/`interval`, one `AsyncTimer` per driver     | in-ring `TIMEOUT` ops; a single collapsed deadline per connection ([SPEC §5.3][eh-spec])          |
| Blocking work | dedicated runtimes/threads; `spawn_blocking`                      | native io_uring file I/O; **no thread pool** (a hazard — [§2.3](#23-what-single-threading-costs)) |
| I/O model     | readiness bridged to a sans-io core via wakers                    | completion-first: submit the op, resume the fiber on the terminal CQE                             |

This is exactly the [Glommio][glommio]/[Monoio][monoio] thread-per-core, share-nothing
stance, applied to a stack that was written for [Tokio][tokio]. The survey's central
finding is that iroh's actor architecture is _friendly_ to this inversion, not hostile
to it: each actor becomes one owner fiber, its documented bounded-inbox capacity
becomes a policy constant to carry over verbatim, and its `CancellationToken` tree —
"structured concurrency retrofitted onto an unstructured spawner" — is replaced by the
`Scope` that event-horizon provides natively ([concurrency][concurrency]).

### 2.2 What single-threading buys

Under the `single` topology the entire "locks, and what they guard" and "channels, by
kind" census ([concurrency][concurrency]) is mostly _deletable_, not merely
_translatable_:

- **No `Send + Sync` tax.** Per-shard state need not be `Send + Sync + 'static`; the
  `Arc`/`Mutex`/`RwLock`/`AtomicU64` scaffolding evaporates. `AddrMap`,
  `ConcurrentReadMap` (a `papaya` lock-free map that exists _only_ so the datagram path
  can find a per-remote actor's inbox cross-thread), the relay `Clients` `DashMap`, and
  the five `Arc`s in iroh's `TlsConfig` all become plain fields ([socket][socket],
  [identity-crypto][identity]).
- **No work-stealing overhead, no task migration.** A resumed fiber immediately submits
  to its owner ring; op slots, buffers, and deadline timers are ring-local, so
  cache-hot handoff replaces cross-core cache-coherency traffic ([SPEC §11][eh-spec]).
- **`oneshot` request/reply becomes a direct call.** Because caller and owner share one
  thread, `resolve_remote`/`register_connection`-style `mpsc(256) + oneshot`
  round-trips collapse to a suspendable method call on the owning state object
  ([endpoint][endpoint]).
- **Whole mechanisms delete.** The `RemoteStateActor` _leftover-message restart
  protocol_ — a dying actor returns its unprocessed inbox and the map either removes its
  sender or restarts it with the messages re-injected — exists solely because the sender
  map's readers race with actor death across tasks; single-threaded, "actor death" and
  "map cleanup" are atomic and the whole dance vanishes. The connection pool's
  **immortal main actor** (which can never observe all-senders-dropped because it holds
  a clone of its own inbox sender) is fixed for free by structural scope ownership. The
  `runtime.rs` `TaskTracker` wrapper around every noq driver task ([`iroh/src/runtime.rs:9`][iroh-runtime])
  becomes native scope children — _"the entire `runtime.rs` file evaporates"_
  ([concurrency][concurrency]).
- **`Watchable`'s lost-wakeup guard cannot fire.** The epoch double-check against lost
  wakeups is impossible with no concurrent poll, so `Watchable` reduces to
  `struct { value; epoch; waiterList }` with no `RwLock` and no waker `Mutex`
  ([concurrency][concurrency]).
- **Determinism that _exceeds_ upstream.** The sans-io cores driven by `TestClock` +
  `TestSched.advanceAndSettle` ([SPEC §10.3][eh-spec]) give run-to-quiescence tests
  with virtual time, where iroh's own end-to-end tests fall back to `sleep(100–200ms)`
  settling waits ([concurrency][concurrency]).

### 2.3 What single-threading costs

Three residues are neither pure protocol nor free to delete, and each needs explicit
design.

**(a) CPU-bound BLAKE3/bao on the loop thread — the one genuine throughput hazard.**
[`bao-tree`][bao-tree] hashes every byte on the read path (≈`N/16384` group hashes plus
≈`N/16384` parent merges for an `N`-byte blob) with _no yield points of its own_, and
[`iroh-blobs`][blobs] re-hashes whole blobs on import (outboard computation) and on
crash recovery (bitfield reconstruction). Rust hides this behind a **dedicated
multi-thread runtime** — critically, `iroh-blobs` runs blocking `std::fs`, `redb`, and
BLAKE3 all _inline_ on that runtime, with **zero `spawn_blocking`**
([`store/fs.rs:1400`][blobs-fs]) — so the network runtime never stalls. A single loop
has no such refuge: a multi-GiB verified decode monopolizes the loop and starves every
connection, timer, and accept. Two mitigations, in increasing order of effort and both
flagged for [bao-tree][bao-tree] and [blobs][blobs]:

1. **Cooperative chunking.** Make the decoder's `next()` a `yieldNow`
   cancellation/checkpoint every _N_ chunk groups (a 16 KiB group is tens of
   microseconds of BLAKE3). This bounds latency and honours `withDeadline`/cancellation
   without a second thread, at the cost of coupling hash throughput to network latency.
   A SIMD BLAKE3 (AVX2/AVX-512/NEON) shrinks the per-group burst and widens the budget.
2. **A bounded hashing worker.** Run the store on a second worker via
   `Topology.threadPerCore` and `LoopGroup.postTo`, harvesting results with `MSG_RING`
   completions ([SPEC §11][eh-spec]) — mirroring Rust's dedicated-runtime architecture
   exactly. This keeps the network loop responsive during hashing at the price of
   reintroducing cross-ring plumbing — the very complexity `single` avoids. The hashing
   is pure (owned buffer in, hash out, no shared state), so it is cleanly isolable.

The census shows Rust chose option 2 for exactly this reason; for the port it is a
**measured trade-off**, not an obvious one, and the right first cut is option 1 with an
instrumented yield budget.

**(b) The missing cross-fiber channel (open-issue O20) — the load-bearing prerequisite.**
event-horizon v1 has structured concurrency (`Scope`, `fork`, `JoinHandle`, `race`),
cancellation (`CancelContext`, `withDeadline`), and one-shot park/wake (`isWaker`), but
[no cross-fiber channel primitive][eh-spec]. **Every actor in the inventory is an inbox
loop**, so the port cannot start subsystem work before landing a channel design. The
needed shape is fully specified by the census — a bounded ring with sender-park-on-full
for backpressure sites, `trySend` returning `Full` vs `Closed` for the _drop_ sites
(relay datagram queues, the network-change fan-out), a `recvMany` batch drain for the
relay's 20-datagram `recv_many`, and close semantics (recv returns none when all senders
drop). The concrete D design is [§4.1](#41-the-cross-fiber-channel-chant--open-issue-o20).
Request/reply `oneshot` traffic can bypass it entirely (a direct method call plus a
parked-fiber rendezvous), but the _stream_ fan-ins — split-download progress, gossip
topic events, docs replica events — genuinely need the queue.

**(c) `spawn_blocking` with no thread pool.** event-horizon exposes no blocking-work
executor, and three of the census's five offload sites dissolve: the lone
`spawn_blocking` (relay TLS load) runs _synchronously at startup_ before the loop is
hot; file I/O is native io_uring, so the file-I/O justification for the blobs and docs
dedicated runtimes disappears. What genuinely remains is the **embedded blocking
database**: `redb` is mmap + blocking syscalls with no io_uring path, so it needs a
worker thread with completion injection or a redesign to an on-loop async store (or an
LMDB C-binding with the same worker discipline). This is the residual reason the docs
storage actor is a bare `std::thread` and the blobs store owns a whole runtime.

### 2.4 The `select!` ≠ `race` trap

The single most load-bearing translation error to avoid: a `tokio::select!` loop does
**not** map to event-horizon's `race`. `select!` polls its arms _without cancelling
them_ across loop iterations; `race` **cancels the losers** on the first terminal
contender ([SPEC §10.4][eh-spec]). The faithful translation of every actor is one
long-lived owner fiber blocking on a single inbox channel, fed by _one daemon forwarder
fiber per event source_ — a `sleep` fiber for a timer, a watcher fiber for a
`Watchable`, a `TaskSet` for child completions. A `biased` priority becomes inbox
ordering; an `if`-guarded arm becomes "do not run that forwarder"; a `MaybeFuture` arm
becomes "arm that `TIMEOUT` only when the state says so." A naive `race`-per-iteration
translation that cancels and re-creates its arms every turn is both slower and a
correctness bug (it drops the very completions `select!` would have kept alive). The
paired transcription of the socket actor's 10-arm loop is worked in
[concurrency § Mapping][concurrency]; the pattern recurs in [blobs][blobs]'s connection
pool, [gossip][gossip]'s 9-arm event loop, and [docs-sync][docs-sync]'s `LiveActor`.

---

## Part 3 — The load-bearing seams

Four seams carry the whole port. For each, the Rust shape (verbatim, cited) sits beside
the proposed D equivalent — marked _proposed / sketch_, in Sparkles D idioms
([`IoResult!`][eh-spec], `Buf`, `SmallBuffer`, capability structs, `Scope`).

### 3.1 The `Runtime` / `AsyncUdpSocket` trait → an event-horizon capability row

`noq` is application- and runtime-agnostic through four traits — `Runtime`,
`AsyncUdpSocket`, `UdpSender`, `AsyncTimer` — and iroh's entire QUIC-stack coupling to
its executor is the ~135-line adapter that implements them ([endpoint][endpoint]). This
is the port's front door: the boxed, `Send + Sync`, `'static` trait object becomes a
monomorphized capability row handed to the root fiber, with no vtable.

```rust
// noq/src/runtime/mod.rs:17-33 — authority as a boxed trait object shared across threads
pub trait Runtime: Send + Sync + Debug + 'static {
    fn new_timer(&self, i: Instant) -> Pin<Box<dyn AsyncTimer>>;
    fn spawn(&self, future: Pin<Box<dyn Future<Output = ()> + Send>>);
    fn wrap_udp_socket(&self, t: std::net::UdpSocket) -> io::Result<Box<dyn AsyncUdpSocket>>;
    fn now(&self) -> Instant { Instant::now() }
}
```

```d
// proposed / sketch — authority is a value row handed to the root fiber; dispatch
// monomorphizes (no Send/Sync/'static, no vtable). `spawn` is not a field: driver
// children are opened on the ambient Scope; `now` is the clock capability; the timer
// is one in-ring TIMEOUT; wrap_udp_socket is DEAD CODE in iroh and is dropped entirely.
struct QuicRuntime(Clock, Net)
if (isClock!Clock && isNet!Net)
{
    Clock clock;        // clock.now() -> MonoTime; TestClock gives virtual-time determinism
    Net   net;          // sendmsg / recvmsg — needs O19 msghdr for wire interop (below)
    Scope* scope;       // structured-concurrency nursery; exit joins/cancels all drivers
    EndpointId id;

    void spawnDriver(scope void delegate() body) => scope.spawnDaemon(body);
    Timer newTimer(MonoTime deadline)            => clock.timerAt(deadline);
    MonoTime now()                                => clock.now();
}
```

The `Runtime::now` clock is [`isClock`][eh-spec]; `new_timer`/`reset` collapse to a
single in-ring `TIMEOUT` op keyed on the connection's one collapsed `poll_timeout()`
deadline; `spawn` becomes `Scope.spawnDaemon`; and `wrap_udp_socket` is documented dead
code in iroh (the endpoint uses `new_with_abstract_socket`) and is omitted. The
`TaskTracker` + `CancellationToken` pair that iroh's `Runtime` carries _is_ a `Scope` —
exit joins children, `abort` = cancel the subtree ([endpoint][endpoint]).

### 3.2 A `noq` `Connection` → a fiber-owned D handle

Below the seam, `noq-proto` exposes six purely synchronous pump methods
(`handle_event`, `handle_timeout`, `poll_transmit`, `poll_timeout`, `poll`,
`poll_endpoint_events`). `noq` welds them to `tokio` with two `Mutex<State>` cells, a
spawned driver future per connection, and per-stream `FxHashMap<StreamId, Waker>` maps.
Under `single` the driver becomes one fiber owning the `Connection` value outright, and
every lock, waker map, `Notify`, and self-wake becomes zero code ([quic][quic]).

```rust
// noq/src/connection.rs:1403-1447 (trimmed) — connection state behind a lock,
// pumped by a spawned Future; parked stream ops live in Waker maps.
pub(crate) struct State {
    pub(crate) inner: proto::Connection,          // the sans-io machine
    driver: Option<Waker>,
    timer: Option<Pin<Box<dyn AsyncTimer>>>,
    blocked_writers: FxHashMap<StreamId, Waker>,
    blocked_readers: FxHashMap<StreamId, Waker>,
    sender: Pin<Box<dyn UdpSender>>,
    buffered_transmit: Option<proto::Transmit>,   // stashed when the socket would block
    // ... + oneshots, watches, broadcasts, Notifys
}
```

```d
// proposed / sketch — one fiber owns the Connection value; parked stream ops are fibers
// in an intrusive wait-list; the six pump methods are plain calls. maxDatagrams:1 until
// O19 lands (removes the GSO segment-size branch — noq supports this natively).
Outcome!void driveConnection(ref QuicRuntime rt, ref Connection conn)
{
    for (;;)
    {
        while (auto ev = conn.nextInboundEvent())        // plain queue, same thread
            conn.handleEvent(ev);

        Buf dg = rt.pool.acquire();                       // pinned, io_uring-registered
        while (auto t = conn.pollTransmit(rt.now(), maxDatagrams: 1, dg))
            rt.net.sendTo(t.destination, move(dg));        // tier-B verb; parks THIS fiber

        auto deadline = conn.pollTimeout();               // single collapsed Instant
        auto ev = race(rt.net.recvReady(),                // whichever fires first
                       rt.clock.sleepUntil(deadline));
        if (ev.isTimeout) conn.handleTimeout(rt.now());
    }
}
```

The endpoint↔connection `mpsc`s that `noq` uses carry only _events_ (datagrams
pre-decoded); on one thread `Endpoint::handle` delivers them by calling directly into
the target connection's `VecDeque`, so no channel is needed _inside_ the proto layer.
Drop-glue is protocol-visible and must be reproduced deliberately: `SendStream` drop ⇒
finish-or-reset, `RecvStream` drop ⇒ `stop(0)`, last handle drop ⇒ `close(0)`. These map
to `Scope.onExit` LIFO hooks attached at handle creation ([quic][quic]).

### 3.3 The blobs get-side FSM → a straight-line fiber

`iroh-blobs`'s low-level get path is an explicit _move-only typestate machine_
(`AtInitial → AtConnected → AtStartRoot → AtBlobHeader → AtBlobContent →* AtEndBlob → …`)
threaded with a `Box<Misc>` "so we don't have to memcpy it on every state transition."
That machine exists only to drive a low-level API without async traits and lifetimes; a
tier-B fiber with blocking-looking verbs needs none of it ([blobs][blobs]).

```rust
// iroh-blobs/src/get.rs (fsm) — the low-level typestate, abbreviated
let start = fsm::start(connection, request, Default::default());
let connected = start.next().await?;
let ConnectedNext::StartRoot(at_start) = connected.next().await? else { … };
let (mut content, size) = at_start.next().next().await?;   // AtBlobHeader → AtBlobContent
loop {
    match content.next().await {
        BlobContentNext::More((next, item)) => { /* Parent|Leaf, verified */ content = next; }
        BlobContentNext::Done(end_blob) => break end_blob,
    }
}
```

```d
// proposed / sketch — Tier-B fiber over an `isByteStream` capability. The typestate
// names survive as documentation checkpoints; the verified-decode stack machine
// (bao-tree) runs on the loop fiber with a yield checkpoint per group (see §2.3a).
IoResult!Stats fetchBlob(Stream)(ref Stream s, in GetRequest req, ref Env env)
if (isByteStream!Stream)
{
    s.sendAll(encodeRequest(req));       // parks on submit; Buf ownership → kernel
    s.finish();                           // graceful FIN == end-of-request marker
    ubyte[8] hdr = s.recvExact!8();       // AtBlobHeader; EOF here ⇒ NotFound
    immutable size = littleEndianU64(hdr);
    auto dec = BaoDecoder(req.hash, size, req.ranges);  // bao-tree hash-stack machine
    while (auto item = dec.next(s))       // Parent(64B) | Leaf(≤16 KiB); verified before return
        env.store.writeBatch(item);       // io_uring write chain; no try_join! needed
    return dec.stats;
}
```

The whole `SendStream`/`RecvStream` generic seam the Rust get/provider stack is written
over (`recv_bytes_exact`/`send_bytes`/`reset`/`stop`) is exactly an `isByteStream`
capability, so the protocol is testable against `SimNet` with no QUIC ([blobs][blobs]).

### 3.4 An actor + `mpsc` → a fiber owning state + the proposed channel

The canonical iroh shape — a `select!` loop over an inbox `mpsc` plus event streams,
timers, and a `JoinSet` of children — transcribes to one owner fiber blocking on a
single inbox `Chan!T`, fed by daemon forwarders (per [§2.4](#24-the-select--race-trap)).
The per-remote `RemoteStateActor`, the gossip `net::Actor`, the docs `LiveActor`, and
the blobs `DownloaderActor`/`ConnectionPool` are all this pattern.

```rust
// iroh/src/socket.rs:1519 — the socket actor's select! loop (trimmed to 4 of 10 arms)
loop {
    tokio::select! {
        biased;
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
// proposed / sketch — one owner fiber + forwarder daemons + one inbox (the Chan!T of §4.1).
// The select! collapses into a single blocking recv; every other source is a daemon fiber
// that forwards a tagged message into the shared inbox. State (RemoteMap, …) is a plain
// owned field — no Arc, no Mutex under `single`.
void runSocketActor(ref RootScope sc, ref Env env, ref Chan!ActorEvent inbox)
{
    sc.spawnDaemon({ repeat(sc, env.clock, spaced(restunInterval()),
                            { inbox.send(ActorEvent.reStunTick); return ioOk(); }); });
    sc.spawnDaemon({ foreach (v; localAddrsWatcher.updates)          // watcher fiber
                         inbox.send(ActorEvent.localAddrs(v)); });
    // … one daemon per net-report watch / portmap / netmon / remote-map cleanup

    for (;;)
    {
        auto ev = inbox.recv();                 // parks; the ONLY multiplex point
        if (ev.isNone) break;                   // all senders dropped ⇒ shutdown
        final switch (ev.get.kind) with (ActorEvent.Kind)
        {
            case message:    handleMessage(ev.get.msg);          break;
            case reStunTick: triggerNetReport();                 break;
            case localAddrs: onLocalAddrsChange(ev.get.addrs);   break;
            // …
        }
    }
    // scope exit joins/cancels every forwarder daemon — no CancellationToken tree
}
```

One hazard survives the translation and is _logical_, not a synchronization artifact:
the docs `LiveActor` carries the warning that its self-send channel deadlocks if used
from the actor's own methods ("Must not be used in methods called from `Self::run`
directly to prevent deadlocks"). A fiber sending into its own full inbox deadlocks
identically — inbox self-sends must be `trySend` or deferred. Likewise the relay's
_arm-gating_ (stop reading input while the output is full, to preserve ordering and drop
behaviour) is a policy the "park on send" default does not reproduce automatically
([concurrency][concurrency]).

---

## Part 4 — The primitives event-horizon still owes the port

The port cannot begin subsystem work before landing a short list of runtime types that
v1 does not ship. Each is small, self-contained, and needed by _several_ subsystems, so
they belong in a shared milestone ([§5, M1](#part-5--the-layered-build-order)), not
inside any one protocol.

| Primitive                                               | Needed by                                                                                | Proposed D shape                                                                                                                      |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Cross-fiber channel** (`Chan!T`, [O20][eh-spec])      | every actor inbox; split-download / gossip / docs stream fan-ins; relay drop-queues      | bounded ring + two waiter lists; `send`/`trySend`/`recv`/`recvMany`/close ([§4.1](#41-the-cross-fiber-channel-chant--open-issue-o20)) |
| **`Watchable!T`** (`n0-watcher` port)                   | `Endpoint.watch_addr`, `home_relay_status`, `net_report`, discovery, gossip addr updates | `struct { T value; ulong epoch; WaiterList }`; `set` dedups on `Eq`; `map`/`or`/`Join`; `Disconnected` on drop                        |
| **Bounded broadcast + `Lagged`**                        | gossip topic events (cap 256/2048); per-connection path events (cap 8); docs subscribers | per-topic list of per-subscriber ring buffers; overflow drops + delivers `Lagged{missed}`                                             |
| **Memoized completion cell** (`Shared<BoxFuture>` port) | 0-RTT "handshake accepted" future, awaited by many waiters                               | one-shot promise caching its `Outcome`; multi-waiter park; `JoinHandle` is single-consumer, so this is new                            |
| **`buffered_unordered(n)` gate**                        | blobs split-download (32-in-flight); any bounded fan-out                                 | a `Scope` plus a counting semaphore admitting the next child fiber on each completion                                                 |
| **msghdr I/O** ([O19][eh-spec])                         | `noq-udp` GSO/GRO/ECN/pktinfo; multipath source-IP selection                             | `sendMsg`/`recvMsg` verbs over `msghdr`/cmsg; until then `maxDatagrams:1`, no wire-interop GSO                                        |
| **`WallClock` capability**                              | QUIC tokens (bind UNIX time, not `MonoTime`); docs µs timestamps                         | `isWallClock` beside `isClock`; `TestWallClock` double for deterministic token/timestamp tests                                        |
| **`Rng` capability**                                    | ed25519 keygen; QUIC pn-skip filter, token nonces, CID grease; gossip                    | `isRng` DbI trait + `TestRng` deterministic double (matches `noq`'s seeded `StdRng` replay)                                           |

### 4.1 The cross-fiber channel (`Chan!T`) — open-issue O20

The channel is the keystone. Its full shape is dictated by the census, and
single-threading makes it a plain ring with no atomics or locks — the parking is via the
loop-free [`isWaker`][eh-spec] seam, and a parked `recv` is a non-I/O park, so
cancellation latches the interrupt and wakes immediately ([SPEC §8.4][eh-spec]).

```d
// proposed / sketch — the cross-fiber channel event-horizon v1 lacks (open-issue O20).
// One thread ⇒ no atomics/locks: a bounded ring plus two intrusive waiter lists.
struct Chan(T, size_t N)                       // N = capacity; SmallBuffer-backed FIFO
{
    private SmallBuffer!(T, N) ring;
    private WaiterList notFull;                 // senders parked on a full ring
    private WaiterList notEmpty;                // owner parked on an empty ring
    private uint senders = 1;                   // live producer count; 0 ⇒ closed

    // Backpressure sender: parks the fiber when the ring is full (actor inboxes).
    IoResult!void send(T v)
    {
        while (ring.length == N)
        {
            if (senders == 0) return chanClosed();
            notFull.park(currentTask);          // resumes when the owner drains one
        }
        ring.pushBack(move(v));
        notEmpty.wakeOne();
        return ioOk();
    }

    // Drop sender: never parks — relay datagram queues, network-change fan-out.
    enum SendResult : ubyte { ok, full, closed }
    SendResult trySend(T v)
    {
        if (senders == 0)     return SendResult.closed;
        if (ring.length == N) return SendResult.full;   // caller drops it (best-effort)
        ring.pushBack(move(v)); notEmpty.wakeOne();
        return SendResult.ok;
    }

    // The owner: parks on empty; returns none once all senders drop ⇒ graceful shutdown.
    Option!T recv()
    {
        while (ring.empty)
        {
            if (senders == 0) return Option!T.init;
            notEmpty.park(currentTask);
        }
        auto v = ring.popFront();
        notFull.wakeOne();
        return some(move(v));
    }

    // Batch drain — the relay's 20-datagram recv_many amortization.
    uint recvMany(scope T[] out_);              // pop up to out_.length; wake notFull
}
```

Because the callers and the owning fiber share one thread, request/reply traffic can
bypass `Chan!T` entirely (a direct suspendable method call), so the channel is reserved
for genuine many→one _stream_ fan-ins. This is the difference between the
`irpc`-flavoured request enums (which monomorphize to direct calls locally) and the
progress/observe streams (which need the queue) — see [blobs § irpc][blobs] and
[concurrency § irpc][concurrency].

---

## Part 5 — The layered build order

The milestones front-load pure value code and the missing primitives, cut the QUIC core
only once its dependencies are green, and defer the cross-process control plane to the
end. Each cross-links the deep-dive(s) it draws on.

**M0 — Pure value code: identity, crypto, wire.** Ed25519 (keygen / deterministic sign
/ `verify_strict`, interop-exact), SHA-512, BLAKE3 (`derive_key`, `keyed_hash`, and the
`hazmat` chunk-counter CVs / ROOT-flag merges), a CSPRNG behind an `Rng` capability, and
the `postcard` codec + `EndpointAddr`/ticket value types. All `@safe pure nothrow @nogc`,
all testable against the three golden ticket vectors with no I/O — the strongest possible
grounding for the riskiest interop surface (`verify_strict`'s edge rules, the `BTreeSet`
canonical order). Draws on [identity-crypto][identity] and [wire-serialization][wire].

**M1 — The missing runtime primitives (the gate).** `Chan!T` (O20),
`Watchable!T`, the bounded broadcast + `Lagged`, the memoized completion cell, the
`buffered_unordered` gate, and the `WallClock`/`Rng` capabilities — small library types
the rest of the port consumes. Landing these first is what unblocks every actor
translation. Draws on [concurrency][concurrency], with `Watchable` semantics from
[endpoint][endpoint]/[gossip][gossip].

**M2 — `bao-tree` verified streaming.** The pure geometry (`TreeNode` bit tricks, the
shifted tree, outboard layout) and both codec state machines (verified decode / range
encode) transliterate almost line-for-line; the only design work is the yield-checkpoint
budget of [§2.3(a)](#23-what-single-threading-costs). Depends on M0's BLAKE3 hazmat.
Draws on [bao-tree][bao-tree].

**M3 — The sans-io QUIC core + TLS seam.** `noq-proto` driven by event-horizon's
`isNet`-capability `AsyncUdpSocket`-equivalent ([§3.1](#31-the-runtime--asyncudpsocket-trait--an-event-horizon-capability-row)),
one fiber per `Connection` ([§3.2](#32-a-noq-connection--a-fiber-owned-d-handle)), one
collapsed in-ring `TIMEOUT`, `SumType!(Cubic, NewReno, Bbr3)` in place of
`Box<dyn Controller>`, and the sans-io TLS 1.3 `Session` with the `PathId`-aware
`PacketKey` nonce. The big rock. **Blocked on O19** for wire-interop GSO/multipath
source-IP selection; ships with `maxDatagrams:1` until then. Draws on [quic][quic] and
[identity-crypto][identity].

**M4 — Endpoint & Router shell.** The identity model, the four interception layers, the
guarded holepunching defaults, the DbI-typestate `Connection<State>`, and the router
`race` loop over the QUIC core. Small and portable once M3 exists. Draws on
[endpoint][endpoint].

**M5 — Connectivity: socket, NAT traversal, relay, discovery, net-report.** The multipath
socket (per-transport recv fibers, multishot `BufRing`, plain `MappedAddrs`), the QNT/QAD
sans-io driver, the relay WebSocket client with a reconnect `Schedule`, pkarr/DNS
discovery, and net-report/netwatch/portmapper. The relay _server_ and the DoH _server_
are deferrable; the interface-enumeration and portmapper layers are C-binding candidates.
Draws on [socket][socket], [nat-traversal][nat], [relay][relay], [discovery][discovery],
[net-report][net-report].

**M6 — Blobs + store.** The verified transfer protocol (`/iroh-bytes/4`) over
`isByteStream` fibers ([§3.3](#33-the-blobs-get-side-fsm--a-straight-line-fiber)), the
per-hash handle map (single-owner, load-on-demand, idle-evict), the io_uring write-batch
chain, and the resumable downloader + `ConnectionPool`. **The CPU-hash decision of
[§2.3(a)](#23-what-single-threading-costs) lands here**, as does the embedded-KV decision
(LMDB C-binding vs on-loop store). Draws on [blobs][blobs] and [bao-tree][bao-tree].

**M7 — Docs + gossip.** The gossip `proto/` core ports verbatim as a `GossipState` value
type with a `TimerMap`; the docs `ranger` is a pure range reconciler; both `net/` layers
become `Scope`-owned fibers consuming the M1 channel and broadcast primitives. The sans-io
cores bring ready-made deterministic test rigs (`TestClock` + `TestSched`). Draws on
[gossip][gossip] and [docs-sync][docs-sync].

**M8 — The remote control plane and hardening.** The `irpc` remote framed-stream loops
(the local path already monomorphized to direct calls in M6/M7), metrics, qlog, the relay
server, and the DoH server. All deferrable without losing p2p interop. Draws on
[concurrency][concurrency] and [blobs][blobs].

---

## Consensus: what the port keeps, deletes, and invents

Cutting across the fifteen deep-dives, the port resolves into three piles.

**Keep (verbatim design).** The four sans-io cores — `noq-proto`, gossip `proto/`, docs
`ranger`, `bao-tree` — plus the wire schema (frozen `postcard` declaration order, the
`ALPN` registry, the golden ticket vectors), the identity binding contract (44-byte SPKI
equality + `ED25519` `CertificateVerify` + mandatory client auth), every timeout and
capacity constant (they are protocol policy), and the `irpc` request-enum _design_. These
transliterate; the risk is interop precision (`verify_strict`, the multipath AEAD nonce,
the `BTreeSet` order), not architecture.

**Delete (the `Send + Sync` tax).** Every `Arc<Mutex/RwLock>`, `AtomicU64`,
`DashMap`/`papaya` map, `oneshot`, `TaskTracker`, `AbortOnDropHandle`, and the intricate
actor-restart and immortal-actor mechanisms that exist only because tasks migrate across
threads. Under `single` these are plain fields, direct calls, and structural scope
teardown. Most of iroh's concurrency census is _deletable_, not _translatable_ —
the reason the socket layer's own author calls the shared `Socket` handle a design
confession worth tightening:

> _"Shared state between an awful lot of iroh subsystems. In particular both the
> `EndpointInner` as well as this actor itself have a copy. But also other subsystems
> that consequently have access to way to much state."_ — [`iroh/src/socket.rs:1456-1459`][socket-src]

**Invent (the primitives event-horizon owes).** The cross-fiber channel (O20), the
`Watchable`, the bounded broadcast, the memoized completion cell, msghdr I/O (O19), and
the `WallClock`/`Rng` capabilities. These are small and shared, and they gate the port —
which is why M1 lands them before any subsystem, and why O19/O20 are the two
event-horizon roadmap items the iroh port most directly pressures.

The honest summary: the port is **one very large sans-io rock (`noq-proto` + TLS)** plus
a ring of tractable native shells, sitting on **one runtime gap (the channel) and one
throughput hazard (BLAKE3 on the loop)**. The QUIC core dominates the schedule; the
channel dominates the ordering; the hash offload is the one place the `single` topology's
purity is genuinely at stake, and the one place a second worker loop may be warranted.

---

## Key design decisions and trade-offs

| Decision                                                                     | Rationale                                                                                          | Trade-off                                                                                           |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Drive the sans-io cores from fibers, keep their value-type design            | `noq-proto`/gossip/`ranger`/`bao-tree` are runtime-neutral; fibers replace wakers 1:1              | Interop precision (AEAD nonce, `verify_strict`) must be exact; ~38k LoC of QUIC still to write      |
| Default `single` topology; delete `Arc/Mutex`/atomics/concurrent maps        | Single-thread ownership removes every data race; no lock or atomic on hot paths                    | A few "locks" are _logical_ (self-send deadlock, arm-gating) and survive the translation            |
| Model each actor as one owner fiber + forwarder daemons on an inbox `Chan!T` | Faithful to `select!`'s poll-without-cancel semantics; `race` would wrongly cancel losers          | One extra daemon per event source; cross-source ordering re-established via inbox tagging           |
| Land `Chan!T`/`Watchable`/broadcast (M1) before any subsystem                | Every actor is an inbox loop; the whole port waits on the channel primitive (O20)                  | A gating milestone with no user-visible protocol; pure runtime-library work up front                |
| BLAKE3/bao on the loop with cooperative yields (option A first)              | No second thread, no cross-ring plumbing; matches the `single` default                             | Hash bursts couple to network latency; a large import stalls I/O unless the yield budget is tuned   |
| …or a second hashing worker via `threadPerCore` + `MSG_RING` (option B)      | Mirrors Rust's dedicated runtime; keeps the network loop responsive during hashing                 | Reintroduces cross-ring channels and share-nothing message passing — the complexity `single` avoids |
| No `spawn_blocking`; startup blocking synchronous, file I/O native io_uring  | The one real `spawn_blocking` (TLS load) runs before the loop is hot; io_uring covers files        | The embedded KV (`redb`/LMDB) has no io_uring home — needs a worker thread or a store redesign      |
| Ship `maxDatagrams:1` until O19 (msghdr) lands                               | `noq-proto` natively supports segmentation-offload-off; unblocks the QUIC core early               | No GSO/GRO throughput and no multipath source-IP selection until msghdr I/O exists                  |
| Keep the `irpc` request-enum design, drop the proc-macro                     | D introspection generates the message sum; local path monomorphizes to direct calls                | The remote framed-stream loop is hand-built; only the remote plane needs it (deferrable to M8)      |
| TLS 1.3 + QUIC-AEAD: C-binding _or_ native sans-io `Session` (open decision) | Reimplementing a QUIC-correct TLS 1.3 is large; a binding is faster but constrains the crypto seam | A binding must expose the `PathId`-aware `PacketKey` nonce; a reimpl is a second large rock         |

---

## Sources

This capstone synthesises the fifteen deep-dives; per-subsystem primary sources are
cited in each. Load-bearing sources for the synthesis itself:

- The concurrency census and the construct-by-construct translation table:
  [Tokio Concurrency Inventory][concurrency].
- The sans-io licence and the QUIC port budget: [QUIC Transport (`noq`)][quic],
  [`noq-proto/src/lib.rs:3-8`][noq-lib], [`noq/src/runtime/mod.rs`][noq-runtime],
  [`noq/src/connection.rs`][noq-conn].
- The CPU-hash hazard and the dedicated-runtime fact: [bao-tree][bao-tree], [blobs][blobs],
  [`iroh-blobs/src/store/fs.rs`][blobs-fs], [`iroh-blobs/DESIGN.md`][blobs-design],
  [`iroh-blobs/src/get.rs`][blobs-get].
- The runtime seam and the `Watchable`/completion-cell gaps: [endpoint][endpoint],
  [`iroh/src/runtime.rs`][iroh-runtime]; the shared-state confession
  [`iroh/src/socket.rs:1456-1459`][socket-src].
- The sans-io-core wins and missing-primitive lists: [gossip][gossip],
  [`iroh-gossip/src/proto/state.rs`][gossip-state], [docs-sync][docs-sync],
  [socket][socket], [nat-traversal][nat].
- The target platform: [event-horizon SPEC][eh-spec] (topologies §11, scopes §8,
  buffers §6, capabilities §10, open-issues O19/O20).
- Structural model and the runtime family it joins: async-io's [comparison][async-comparison],
  [Tokio][tokio], [Glommio][glommio], [Monoio][monoio], and the
  [algebraic-effects][alg-effects] survey.
- Sibling iroh pages this plan integrates: [survey umbrella][index], [concepts][concepts],
  [identity & cryptography][identity], [wire formats][wire], [QUIC transport][quic],
  [endpoint & router][endpoint], [socket][socket], [NAT traversal][nat], [relay][relay],
  [discovery][discovery], [net report][net-report], [blobs][blobs], [bao-tree][bao-tree],
  [docs sync][docs-sync], [gossip][gossip], [concurrency][concurrency].

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
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
[bao-tree]: ./bao-tree.md
[docs-sync]: ./docs-sync.md
[gossip]: ./gossip.md
[concurrency]: ./concurrency.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[async-comparison]: ../async-io/comparison.md
[tokio]: ../async-io/tokio.md
[glommio]: ../async-io/glommio.md
[monoio]: ../async-io/monoio.md
[alg-effects]: ../algebraic-effects/index.md
[noq-lib]: https://github.com/n0-computer/noq/blob/noq-v1.0.1/noq-proto/src/lib.rs
[noq-runtime]: https://github.com/n0-computer/noq/blob/noq-v1.0.1/noq/src/runtime/mod.rs
[noq-conn]: https://github.com/n0-computer/noq/blob/noq-v1.0.1/noq/src/connection.rs
[socket-src]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/socket.rs
[iroh-runtime]: https://github.com/n0-computer/iroh/blob/22cac742ca/iroh/src/runtime.rs
[blobs-fs]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/store/fs.rs
[blobs-get]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/src/get.rs
[blobs-design]: https://github.com/n0-computer/iroh-blobs/blob/v0.103.0/DESIGN.md
[gossip-state]: https://github.com/n0-computer/iroh-gossip/blob/v0.101.0/src/proto/state.rs
