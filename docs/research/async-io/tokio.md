# Tokio (Rust)

Rust's dominant asynchronous runtime: a readiness-based reactor over [mio] (epoll/kqueue/IOCP) paired with a work-stealing task scheduler, `std::future::Future` polling, and an _experimental_ completion-based `io_uring` backend gated behind `tokio_unstable` + the `io-uring` feature.

| Field         | Value                                                                                    |
| ------------- | ---------------------------------------------------------------------------------------- |
| Language      | Rust (edition 2021; tokio crate version `1.52.3` at time of writing)                     |
| License       | MIT                                                                                      |
| Repository    | [tokio-rs/tokio]                                                                         |
| Documentation | [Tokio docs.rs] / [Tokio Tutorial]                                                       |
| Key Authors   | Carl Lerche, Alice Ryhl, Eliza Weisman, and the Tokio contributors                       |
| Pattern       | Reactor (readiness, mio: epoll/kqueue/IOCP) + work-stealing M:N scheduler                |
| Encoding      | `Future`/`Waker` poll model; **experimental** Proactor (`io_uring`) backend for file I/O |

---

## Overview

### What it solves

Rust's `async`/`await` is a _language_ feature that lowers `async fn` bodies into state-machine types implementing the [`std::future::Future`] trait. The language deliberately ships **no runtime**: a `Future` does nothing until something repeatedly calls `Future::poll`, and `poll` does nothing useful unless an executor wires up a [`Waker`] so the future can be re-polled when it can make progress. Tokio supplies that missing half — an executor that drives futures to completion, an **I/O driver** (the reactor) that learns from the OS when sockets and pipes become ready, a hierarchical **timer**, a **blocking thread pool** for operations that have no non-blocking equivalent, and the leaf futures (`TcpStream`, `Sleep`, `File`, channels) that integrate with all of the above.

Conceptually Tokio occupies the same niche as [libuv] in C/Node.js, the [Go netpoller], .NET's [`SocketAsyncEngine`][dotnet], or [Glommio]/[Monoio] in Rust — but unlike the thread-per-core designs of Glommio and Monoio, Tokio's flagship scheduler is a **work-stealing, multi-threaded** executor where any task may migrate between worker threads. See [comparison] for how these models trade off against each other, and [d-landscape] for the D-language analogues.

### Design philosophy

- **Poll-based futures, not callbacks.** Tokio commits fully to the `Future`/`Waker` contract. There are no green threads and no stack switching; a suspended task is just a state machine sitting in memory with a `Waker` registered against whatever it is blocked on. This is the readiness/reactor counterpart to the _effect-handler_ designs surveyed in [effects-and-event-loops] and [OCaml Eio][eio].
- **Readiness over completion (by default).** The portable core is built on mio, which exposes the **readiness** model common to epoll and kqueue (and adapts Windows IOCP, a completion API, to look readiness-like). Tokio waits for "this fd is readable", then issues the actual `read(2)` itself. This is the opposite of the **completion** model used by `io_uring` and IOCP natively, where you submit the read and are notified when the bytes have already landed. See [primitives] and [techniques] for the readiness-vs-completion dichotomy.
- **`Send` tasks that can migrate.** The multi-thread scheduler can steal a task from one worker and resume it on another, so spawned futures are required to be `Send`. This is the central trade-off versus the thread-per-core runtimes ([Glommio], [Monoio]) that pin tasks to a core and avoid synchronization.
- **Composability via traits, not a monolith.** `AsyncRead`/`AsyncWrite`, `Stream`, `Future`, and `Waker` are standard or near-standard interfaces, so the ecosystem (hyper, tonic, tower, axum) layers cleanly on top.

---

## Core abstractions and types

| Concept                | Type / item                                             | Role                                                                          |
| ---------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Runtime                | `tokio::runtime::Runtime`                               | Owns scheduler, driver handle, and blocking pool; entry point via `block_on`. |
| Runtime flavor         | `RuntimeFlavor::{CurrentThread, MultiThread}`           | Single-threaded vs work-stealing executor.                                    |
| Cheap shared reference | `tokio::runtime::Handle`                                | Cloneable handle that lets other threads spawn onto / enter the runtime.      |
| Task handle            | `tokio::task::JoinHandle<T>`                            | Awaitable result of a spawned task; `abort()` cancels it.                     |
| Abort handle           | `tokio::task::AbortHandle`                              | Detached cancellation token for a task.                                       |
| Future contract        | `std::future::Future` + `std::task::Waker`              | The poll/wake protocol every leaf and combinator implements.                  |
| I/O driver (reactor)   | `runtime::io::Driver` (wraps `mio::Poll`)               | Blocks on the OS event queue; dispatches readiness to waiting tasks.          |
| Driver handle          | `runtime::io::Handle` (wraps `mio::Registry`)           | Registers/deregisters fds; wakes the reactor.                                 |
| Per-resource state     | `ScheduledIo`                                           | Tracks readiness bits and the `Waker`s blocked on a single fd.                |
| Readiness leaf         | `tokio::io::unix::AsyncFd<T>`                           | Generic readiness wrapper for any `AsRawFd`, with `AsyncFdReadyGuard`.        |
| Timer                  | `runtime::time::Driver` + `wheel::Wheel`                | Six-level hierarchical hashed timing wheel.                                   |
| Blocking pool          | `runtime::blocking::BlockingPool` / `spawn_blocking`    | Off-loads synchronous syscalls (incl. most file I/O) onto dedicated threads.  |
| `io_uring` context     | `runtime::io::driver::uring::UringContext` _(unstable)_ | Holds the ring + a `Slab<Lifecycle>`; experimental completion backend.        |

### The runtime object

`Runtime` (in [`tokio/src/runtime/runtime.rs`]) is a thin shell over three parts:

```rust
// tokio/src/runtime/runtime.rs
pub struct Runtime {
    /// Task scheduler
    scheduler: Scheduler,
    /// Handle to runtime, also contains driver handles
    handle: Handle,
    /// Blocking pool handle, used to signal shutdown
    blocking_pool: BlockingPool,
}

pub(super) enum Scheduler {
    CurrentThread(CurrentThread),
    #[cfg(feature = "rt-multi-thread")]
    MultiThread(MultiThread),
}
```

A `Runtime` is normally built by the `#[tokio::main]` macro or via `runtime::Builder::new_multi_thread().enable_all().build()`. `enable_all()` turns on both the I/O driver and the time driver; `enable_io()`/`enable_time()` enable them selectively. The driver stack itself is assembled in [`tokio/src/runtime/driver.rs`], which composes the I/O driver, an optional signal driver, an optional process driver, and the time driver into a single `Driver` that the scheduler "parks" on when it runs out of work.

---

## How it works

### The poll/wake contract

Every leaf resource in Tokio bottoms out in `Future::poll(cx)`. When a task cannot make progress it:

1. Clones `cx.waker()` (a `std::task::Waker`) and stores it somewhere the reactor or timer can reach.
2. Returns `Poll::Pending`.

The scheduler then sets that task aside. When the relevant event fires (fd readable, timer expired, channel send), whoever holds the `Waker` calls `waker.wake()`, which re-schedules the task onto a run queue so a worker re-polls it. This is the entire control-flow mechanism — there is no stack to save, only the `Future` state machine.

### The I/O driver (reactor) on mio

The portable reactor lives in [`tokio/src/runtime/io/driver.rs`]. Its `Driver` is a direct wrapper around mio:

```rust
// tokio/src/runtime/io/driver.rs
/// I/O driver, backed by Mio.
pub(crate) struct Driver {
    signal_ready: bool,
    events: mio::Events,      // reused across poll calls
    poll: mio::Poll,          // the system event queue
}

pub(crate) struct Handle {
    registry: mio::Registry,            // registers fds
    registrations: RegistrationSet,     // tracks all ScheduledIo
    synced: Mutex<registration_set::Synced>,
    #[cfg(not(target_os = "wasi"))]
    waker: mio::Waker,                  // self-pipe to break the poll
    // ...
}
```

[mio] ("metal I/O") is the cross-platform abstraction layer that papers over the OS selectors: **epoll** on Linux/Android, **kqueue** on the BSDs/macOS, and **IOCP** on Windows (adapted to look readiness-based). Its primitives — `Poll`, `Registry`, `Events`, `Token`, `Interest`, and `Waker` — map one-to-one onto the fields above. Tokio depends on mio `1.2.0`.

The reactor's hot loop is `Driver::turn`:

```rust
// tokio/src/runtime/io/driver.rs  (Driver::turn, abridged)
self.poll.poll(events, max_wait)?;          // one syscall: epoll_wait / kevent / GetQueuedCompletionStatus
for event in events.iter() {
    let token = event.token();
    if token == TOKEN_WAKEUP { /* self-wake, nothing to do */ }
    else if token == TOKEN_SIGNAL { self.signal_ready = true; }
    else {
        let ready = Ready::from_mio(event);
        // The token IS the exposed pointer to the ScheduledIo.
        let io: &ScheduledIo = unsafe { &*EXPOSE_IO.from_exposed_addr(token.0) };
        io.set_readiness(Tick::Set, |curr| curr | ready);
        io.wake(ready);                     // wakes every Waker blocked on this fd
    }
}
```

The key trick: each registered resource has an `Arc<ScheduledIo>`, and the _address_ of that allocation is exposed as the mio `Token`. When an event comes back, Tokio reconstitutes the `&ScheduledIo` directly from the token, ORs in the new readiness bits, and calls every `Waker` waiting on that direction (read/write). The reactor never performs the actual `read`/`write` — it only records _readiness_. The owning task wakes, re-polls, and issues the syscall itself, retrying on `WouldBlock`.

Two reserved tokens are special: `TOKEN_WAKEUP` (token 0) is fired by `Handle::unpark()` via `mio::Waker` to break a blocked `poll` when new tasks arrive; `TOKEN_SIGNAL` (token 1) carries Unix signal-driver notifications.

### Registration and the `AsyncFd` readiness model

`Handle::add_source` (in `io/driver.rs`) allocates a `ScheduledIo`, derives its token, and calls `mio::Registry::register(source, token, interest)`; `deregister_source` does the inverse, always deregistering from the OS first so the slot can be reclaimed safely. Built-in resources (`TcpStream`, `UdpSocket`, `UnixStream`, pipes) register themselves.

For _user-owned_ file descriptors, Tokio exposes [`AsyncFd<T>`] in `tokio/src/io/async_fd.rs`. It wraps any `T: AsRawFd` plus a `Registration`, and offers `readable()`/`writable()` (and the `poll_*_ready` variants) returning an `AsyncFdReadyGuard`. The guard is the readiness-model contract made explicit: after you attempt a syscall through it you call `clear_ready()` (or use `try_io`) to tell Tokio whether the fd is still ready, so it knows whether to re-arm the reactor. This is how readiness leaves are composed without baking every fd type into the runtime.

### Schedulers: current-thread vs multi-thread

The scheduler is selected at build time and dispatched through `scheduler::Handle` ([`tokio/src/runtime/scheduler/mod.rs`]):

```rust
// tokio/src/runtime/scheduler/mod.rs
pub(crate) enum Handle {
    CurrentThread(Arc<current_thread::Handle>),
    #[cfg(feature = "rt-multi-thread")]
    MultiThread(Arc<multi_thread::Handle>),
}
```

**Current-thread scheduler** ([`scheduler/current_thread/mod.rs`]). All tasks run on the thread that called `block_on`. The `Core` holds a single `VecDeque<Notified>` run queue, a tick counter, the `Driver`, and a `global_queue_interval` (default `31`) controlling how often the worker checks the shared inject queue versus its local queue for fairness. When the local queue empties, the worker takes the `Driver` out of the `Core`, parks on the reactor/timer, then puts it back. A notable subtlety: `block_on` can be called from several threads against one current-thread runtime — the first caller owns the driver, and others "steal" the driver when it is released, so progress continues even though tasks themselves never migrate.

**Multi-thread scheduler** ([`scheduler/multi_thread/worker.rs`]). A fixed pool of worker threads (defaulting to the number of CPUs), each owning a `Core`. The design is the work-stealing rewrite Carl Lerche described in _["Making the Tokio scheduler 10x faster"][tokio-scheduler-blog]_ (2019). Each `Core` has:

```rust
// tokio/src/runtime/scheduler/multi_thread/worker.rs  (Core, abridged)
struct Core {
    tick: u32,
    /// Last task scheduled by this worker; checked BEFORE the run queue (LIFO).
    lifo_slot: Option<Notified>,
    lifo_enabled: bool,
    /// The worker-local run queue (a bounded ring buffer).
    run_queue: queue::Local<Arc<Handle>>,
    is_searching: bool,
    is_shutdown: bool,
    // ...
}
```

A worker's task-selection order is: the **LIFO slot** (the most recently woken task, kept hot in cache to optimize message-passing ping-pong, capped at `MAX_LIFO_POLLS_PER_TICK = 3` consecutive polls to avoid starvation), then its **local run queue** (a fixed-size circular buffer, not crossbeam's Chase-Lev deque), then **work-stealing** from a randomly chosen peer, then the **global inject queue**:

```rust
// tokio/src/runtime/scheduler/multi_thread/worker.rs
fn steal_work(&mut self, worker: &Worker) -> Option<Notified> {
    if !self.transition_to_searching(worker) { return None; }
    let num = worker.handle.shared.remotes.len();
    let start = self.rand.fastrand_n(num as u32) as usize;   // random victim
    for i in 0..num {
        let i = (start + i) % num;
        if i == worker.index { continue; }                   // don't steal from self
        let target = &worker.handle.shared.remotes[i];
        if let Some(task) = target.steal.steal_into(&mut self.run_queue, &mut self.stats) {
            return Some(task);
        }
    }
    worker.handle.next_remote_task()                          // fall back to global queue
}
```

When a local queue overflows, surplus tasks spill to the global queue rather than growing unbounded. The number of concurrent stealers and the wakeup rate are throttled to cut contention. Because tasks can be stolen and resumed on another thread, spawned futures must be `Send`.

The `block_in_place` API lets a worker hand off its `Core` to a fresh thread so a long blocking call doesn't stall the other tasks queued behind it.

### The blocking pool and file I/O

Most file-system operations have no portable non-blocking syscall, so on the default (non-uring) build Tokio implements `tokio::fs` by shipping the synchronous `std::fs` call to a dedicated blocking thread pool via `spawn_blocking` / the internal `asyncify` helper. In `tokio/src/fs/read.rs`:

```rust
// tokio/src/fs/read.rs (default path)
pub async fn read(path: impl AsRef<Path>) -> io::Result<Vec<u8>> {
    let path = path.as_ref().to_owned();
    // (io_uring fast path elided — see below)
    asyncify(move || std::fs::read(path)).await
}
```

`spawn_blocking` returns a `JoinHandle`, and its threads are created lazily up to a configurable cap (512 by default), with idle threads timed out. The blocking pool is also what backs `block_in_place` shutdown semantics.

### The hierarchical timer wheel

Timers (`Sleep`, `timeout`, `interval`) are kept in a **six-level hierarchical hashed timing wheel** in [`tokio/src/runtime/time/wheel/mod.rs`]:

```rust
// tokio/src/runtime/time/wheel/mod.rs
/// Number of levels. Each level has 64 slots. By using 6 levels with 64 slots
/// each, the timer is able to track time up to 2 years into the future with a
/// precision of 1 millisecond.
const NUM_LEVELS: usize = 6;
pub(super) const MAX_DURATION: u64 = (1 << (6 * NUM_LEVELS)) - 1;
```

Each level holds 64 slots; level granularities cascade by a factor of 64:

| Level | Slot granularity | Range covered |
| ----- | ---------------- | ------------- |
| 0     | 1 ms             | 64 ms         |
| 1     | 64 ms            | ~4 s          |
| 2     | ~4 s             | ~4 min        |
| 3     | ~4 min           | ~4 hr         |
| 4     | ~4 hr            | ~12 days      |
| 5     | ~12 days         | ~2 years      |

Insertion picks the coarsest level whose slot still resolves the deadline (`level_for` masks the XOR of `elapsed` and `when` and counts leading zeros). As time advances, `process_expiration` "cascades" entries down to finer levels until, at level 0, they are marked pending and fired. The wheel gives O(1) amortized insert/expire instead of the O(log n) of a binary heap, at the cost of millisecond precision and a fixed ~2-year ceiling (`MAX_DURATION`). Timer entries are intrusive (`TimerShared`) and pinned, so no per-timer heap allocation is needed. (An alternative per-worker timer, `TimerFlavor::Alternative`, exists behind `tokio_unstable` for the multi-thread runtime.)

### Cancellation: `JoinHandle::abort`

Tokio's cancellation is cooperative and based on dropping/aborting the task state machine. `JoinHandle::abort` ([`tokio/src/runtime/task/join.rs`]) simply forwards to the raw task:

```rust
// tokio/src/runtime/task/join.rs
pub fn abort(&self) {
    self.raw.remote_abort();
}
```

`remote_abort` sets the task's `CANCELLED` bit (a bitfield in the task's atomic state word alongside `RUNNING`, `COMPLETE`, `NOTIFIED`, `JOIN_INTEREST`, `JOIN_WAKER`) and schedules it. The next time the runtime touches the task, it stops polling the future, drops it, and resolves the `JoinHandle` with a cancelled `JoinError`. Cancellation is therefore _not_ preemptive: a task is only cancelled at an `.await` point or when next scheduled, and `is_finished()` may briefly return `false` after `abort()`. An `AbortHandle` (from `abort_handle()`) is a detached token that can cancel the task without holding the `JoinHandle`; `JoinSet::abort_all` cancels a whole set. This is structurally weaker than the _structured_ cancellation of [Eio][eio] switches or Loom's [structured concurrency][java]; libraries layer `CancellationToken` and `select!`-based cancellation on top.

---

## The io_uring backend (experimental)

> **Status (verified):** As of tokio `1.52.x`, `io_uring` support in the _main_ tokio crate is **experimental / unstable**. It is compiled only when **all** of these hold: the `--cfg tokio_unstable` rustc flag is set, the `io-uring` cargo feature is enabled, the `rt` and `fs` features are on, and `target_os = "linux"`. It is opted into at runtime with `Builder::enable_io_uring()`. Without `tokio_unstable` the `io-uring` feature is a hard compile error. The tokio team explicitly documents the behavior as "currently experimental, so its behavior may change or it may be removed in future versions." This is distinct from the older, separate [tokio-uring] crate (see below).

The backend is wired into the _same_ reactor. The mio-backed `runtime::io::Handle` carries two extra `cfg`-gated fields ([`tokio/src/runtime/io/driver.rs`]):

```rust
// tokio/src/runtime/io/driver.rs  (Handle, uring fields)
#[cfg(all(tokio_unstable, feature = "io-uring", feature = "rt",
          feature = "fs", target_os = "linux"))]
pub(crate) uring_context: Mutex<UringContext>,
#[cfg(all(tokio_unstable, feature = "io-uring", feature = "rt",
          feature = "fs", target_os = "linux"))]
pub(crate) uring_probe: OnceCell<Option<io_uring::Probe>>,
```

There is **one** `UringContext` per runtime, guarded by a `Mutex` (a known scalability limitation; the proposed future direction is a per-worker ring — see [discussion #7684][tokio-uring-discussion]). It is built on the [tokio-rs/io-uring][io-uring-crate] crate (`io-uring 0.7.11`).

### `UringContext`, the `Slab`, and the `Lifecycle` state machine

```rust
// tokio/src/runtime/io/driver/uring.rs
const DEFAULT_RING_SIZE: u32 = 256;

pub(crate) struct UringContext {
    pub(crate) uring: Option<io_uring::IoUring>,
    pub(crate) ops: slab::Slab<Lifecycle>,   // index == SQE user_data
}
```

Each in-flight operation occupies a slot in a `slab::Slab<Lifecycle>`. The slot **index is the `user_data`** written into the submission-queue entry (SQE), so when a completion-queue entry (CQE) comes back, `cqe.user_data() as usize` directly indexes the right slot. The `Lifecycle` enum ([`runtime/driver/op.rs`]) is the per-op state machine:

```rust
// tokio/src/runtime/driver/op.rs
pub(crate) enum Lifecycle {
    Submitted,            // pushed to the SQ, in flight
    Waiting(Waker),       // the future is parked, holds its Waker
    Cancelled(CancelData),// future dropped; keep buffers alive until CQE arrives
    Completed(cqueue::Entry), // CQE seen, result stored for the future to pick up
}
```

The flow:

1. **Submit.** `Handle::register_op(entry, waker)` inserts `Lifecycle::Waiting(waker)` into the slab, stamps the SQE with `entry.user_data(index)`, pushes it onto the submission queue, and submits. If the SQ is full it flushes; if the CQ is full it drains completions first.
2. **Park.** The op future (`Op<T>`, also in `op.rs`) returns `Poll::Pending`. Its state goes `Initialize(entry) -> Polled(index)`.
3. **Complete.** When the reactor finishes a `mio::Poll::poll` (the `io_uring` fd is registered as a mio source under `TOKEN_WAKEUP`), `Driver::turn` calls `UringContext::dispatch_completions`:

   ```rust
   // tokio/src/runtime/io/driver/uring.rs  (dispatch_completions, abridged)
   for cqe in cq {
       let idx = cqe.user_data() as usize;
       match ops.get_mut(idx) {
           Some(Lifecycle::Waiting(waker)) => {
               waker.wake_by_ref();
               *ops.get_mut(idx).unwrap() = Lifecycle::Completed(cqe);
           }
           Some(Lifecycle::Cancelled(cancel_data)) => { /* discard, drop owned fd */ ops.remove(idx); }
           // ...
       }
   }
   ```

   The `Waiting(Waker) -> Completed(cqe)` transition wakes the parked future _and_ stashes the raw CQE.

4. **Resume.** The re-polled `Op<T>` finds `Lifecycle::Completed(cqe)`, removes the slot, and resolves with `data.complete(cqe.into())`, converting the negative-errno CQE result into an `io::Result<u32>` via `CqeResult`.

Cancellation (`Handle::cancel_op`) is the reason `Cancelled` carries `CancelData`: when an `Op<T>` future is dropped while still `Polled(index)`, Tokio transitions the slot to `Cancelled` and keeps the operation's buffers/owned-fd alive until the kernel actually completes (or the `UringContext::drop` impl drains them) — required because `io_uring` owns the buffer for the duration of the op.

### Which ops, and version gating

The unstable backend currently covers **file I/O only** — `tokio::fs::read`, `tokio::fs::write`, `OpenOptions::open`, and reads on an open `File` (its `AsyncRead` impl) — using three `io_uring` opcodes (from `tokio/src/io/uring/`):

| Tokio call             | SQE opcode (`io_uring::opcode`) | `io_uring` `IORING_OP_*` | Available since Linux |
| ---------------------- | ------------------------------- | ------------------------ | --------------------- |
| `fs::read` / file read | `opcode::Read`                  | `IORING_OP_READ`         | 5.6                   |
| `fs::write`            | `opcode::Write`                 | `IORING_OP_WRITE`        | 5.6                   |
| `OpenOptions::open`    | `opcode::OpenAt`                | `IORING_OP_OPENAT`       | 5.6                   |

`io_uring` itself landed in Linux **5.1** (May 2019); the `READ`/`WRITE`/`OPENAT` opcodes Tokio uses arrived in **5.6** (March 2020). See [io-uring/opcodes-reference] for the full opcode/version matrix, and [io-uring/features] for ring-feature gating.

### Probe-based capability detection and fallback

Tokio does **not** assume `io_uring` works just because the feature is compiled in. The first time a file op runs, `Handle::check_and_init(opcode)` lazily performs `io_uring_setup` and registers an `io_uring::Probe` (via `IORING_REGISTER_PROBE`), caching the result in the `OnceCell<Option<Probe>>`:

```rust
// tokio/src/runtime/io/driver/uring.rs  (check_and_init, abridged)
let probe = self.uring_probe.get_or_try_init(|| async {
    let mut probe = Probe::new();
    match self.try_init(&mut probe) {
        Ok(())                                          => Ok(Some(probe)),
        Err(e) if e.raw_os_error() == Some(libc::ENOSYS) => Ok(None), // kernel has no io_uring
        Err(e) if e.raw_os_error() == Some(libc::EPERM)  => Ok(None), // blocked by seccomp etc.
        Err(e)                                           => Err(e),
    }
}).await?;
Ok(probe.as_ref().is_some_and(|p| p.is_supported(opcode)))
```

The call site in `fs::read` shows the **fallback path** explicitly: probe first, take the `io_uring` path only on success, otherwise drop straight through to the blocking pool:

```rust
// tokio/src/fs/read.rs (uring fast path)
#[cfg(all(tokio_unstable, feature = "io-uring", feature = "rt",
          feature = "fs", target_os = "linux"))]
{
    let driver_handle = crate::runtime::Handle::current().inner.driver().io();
    if driver_handle.check_and_init(io_uring::opcode::Read::CODE).await? {
        return read_uring(&path).await;          // completion path
    }
}
asyncify(move || std::fs::read(path)).await       // readiness/blocking-pool fallback
```

So the runtime degrades gracefully across three layers: (1) `io_uring` if the kernel supports the specific opcode; (2) the mio readiness reactor for sockets/pipes always; (3) the blocking thread pool when neither applies. `ENOSYS` (old kernel) and `EPERM` (seccomp-sandboxed) both quietly route to `spawn_blocking`.

### Relationship to `tokio-uring`

The separate **[tokio-uring]** crate (announced 2021) is a _different_ product: a standalone, thread-per-core, fully completion-based runtime that drives `io_uring`-backed resources with owned-buffer APIs (`read_at`, `write_at`) and is Tokio-compatible (you can run a regular Tokio runtime inside it). It predates and is orthogonal to the in-tree experimental backend described above; the in-tree work aims to make `io_uring` a transparent acceleration of the existing `tokio::fs` API rather than a new runtime. For an `io_uring`-native runtime comparison see [Monoio] and [Glommio]; for the `io_uring` concept itself see [io-uring/index].

---

## Performance approach

- **One syscall per wakeup batch.** Each reactor turn is a single `epoll_wait`/`kevent`, draining a batch of events; per-fd dispatch is a pointer reconstruction from the token, not a hash lookup.
- **Cache-friendly scheduling.** The LIFO slot keeps a just-woken task on the same core to exploit warm caches for request/response patterns; the local run queue is a fixed ring buffer (no allocation, no Chase-Lev overhead).
- **Throttled stealing.** Bounding concurrent stealers and the wake rate avoids thundering-herd contention identified in the 2019 rewrite.
- **No allocation for control flow.** Suspended tasks are inline state machines; timers are intrusive list nodes; the `io_uring` slab reuses slots.
- **Completion I/O for files (opt-in).** The `io_uring` backend removes the readiness round-trip and the blocking-pool thread hop for file reads/writes; the discussion benchmarks cite ~4x throughput on concurrent file workloads at the cost of ~18% added latency for single ops, currently bottlenecked by the global ring `Mutex`.
- **Adaptive fairness.** `global_queue_interval` periodically forces a check of the global queue so injected/remote tasks aren't starved by a busy local queue.

---

## Strengths

- **De-facto standard.** The overwhelming majority of the Rust async ecosystem (hyper, axum, tonic, tower, sqlx, reqwest) targets Tokio's traits and runtime.
- **Mature, portable reactor.** mio gives consistent behavior across Linux, macOS/BSD, and Windows from one codebase.
- **Work-stealing throughput.** Automatic load balancing across cores without the user partitioning work, ideal for heterogeneous task sizes.
- **Rich, well-documented APIs.** `select!`, `JoinSet`, channels, `timeout`, `interval`, `AsyncFd`, tracing integration, and a polished tutorial.
- **Graceful `io_uring` opt-in.** Probe-based detection means enabling the feature can't break on kernels/sandboxes that lack support — it transparently falls back.
- **Strong observability.** `tokio_unstable` metrics, `tokio-console`, and task dumps.

## Weaknesses

- **`Send` tax.** Work-stealing forces `Send + 'static` on spawned tasks and pushes shared state behind `Arc`/`Mutex`, unlike thread-per-core runtimes ([Glommio], [Monoio]) that allow `!Send` tasks and lock-free per-core state.
- **Readiness, not completion, by default.** The portable path still does readiness + a separate syscall, missing `io_uring`'s batching/zero-syscall potential for sockets entirely (the backend is files-only).
- **`io_uring` backend is experimental and narrow.** Files only; single global ring behind a `Mutex`; gated behind `tokio_unstable`; explicitly may change or be removed.
- **Cooperative, unstructured cancellation.** `abort()` only takes effect at `.await` points; there is no built-in structured-concurrency scope (cf. [Eio][eio], [Loom][java]). Cancellation-safety of `select!` branches is a recurring footgun.
- **Blocking-pool thread hops.** Without `io_uring`, every file op (and any `spawn_blocking` work) pays a thread handoff and context-switch cost.
- **Timer precision/ceiling.** 1 ms granularity and a ~2-year max duration baked into the wheel.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                      | Trade-off                                                                              |
| ----------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| Poll-based `Future`/`Waker`, no green threads         | Zero-cost suspension; integrates with `async`/`await`; no stack to save        | Manual `poll` plumbing for leaves; cancellation is cooperative, not preemptive         |
| Readiness reactor via mio (epoll/kqueue/IOCP)         | One portable code path across all major OSes                                   | Extra syscall per I/O; cannot exploit `io_uring` batching on sockets                   |
| Work-stealing multi-thread scheduler                  | Auto load-balancing, high throughput on mixed workloads                        | Requires `Send` tasks and synchronized shared state; cross-core migration overhead     |
| LIFO slot + bounded ring local queue                  | Cache locality for ping-pong; bounded contention vs Chase-Lev deque            | LIFO can starve siblings (capped at 3 polls); overflow spills to slower global queue   |
| Blocking pool for file I/O                            | Portable async file API with no kernel non-blocking equivalent                 | Thread handoff + context-switch cost; thread-count caps                                |
| Six-level hashed timing wheel                         | O(1) amortized insert/expire; intrusive, no per-timer allocation               | 1 ms granularity; fixed ~2-year ceiling                                                |
| `io_uring` as opt-in, probe-gated, files-only backend | Faster file I/O where supported; never breaks on unsupported kernels/sandboxes | Experimental; single global ring behind a `Mutex`; narrow op coverage; may be removed  |
| `abort()` cancellation via task state bit             | Cheap, lock-free, remote-able via `AbortHandle`                                | Not structured; takes effect only at next poll; `select!` cancellation-safety pitfalls |

---

## Sources

- [tokio-rs/tokio] — main repository (source for all quoted file paths)
- [Tokio docs.rs] — API reference
- [Tokio Tutorial] — official guide
- [Making the Tokio scheduler 10x faster][tokio-scheduler-blog] — work-stealing design rationale (2019)
- [Announcing tokio-uring][tokio-uring] — separate `io_uring` runtime crate (2021)
- [io_uring integration discussion #7684][tokio-uring-discussion] — status of the in-tree experimental backend, global-ring limitation, future direction
- [tokio-rs/io-uring][io-uring-crate] — the low-level `io_uring` Rust crate Tokio builds on
- [mio] — cross-platform readiness reactor (epoll/kqueue/IOCP)
- [io_uring(7) man page][io-uring-man] — kernel interface and opcode semantics
- [io_uring on Wikipedia][io-uring-wiki] — version history (5.1 introduction)
- Sibling docs: [primitives], [techniques], [comparison], [effects-and-event-loops], [d-landscape], [io-uring/index], [io-uring/features], [io-uring/opcodes-reference], [Glommio], [Monoio], [libuv], [Go netpoller][go-netpoller], [dotnet], [java], [Eio][eio]

<!-- References -->

[tokio-rs/tokio]: https://github.com/tokio-rs/tokio
[Tokio docs.rs]: https://docs.rs/tokio/latest/tokio/
[Tokio Tutorial]: https://tokio.rs/tokio/tutorial
[tokio-scheduler-blog]: https://tokio.rs/blog/2019-10-scheduler
[tokio-uring]: https://tokio.rs/blog/2021-07-tokio-uring
[tokio-uring-discussion]: https://github.com/tokio-rs/tokio/discussions/7684
[io-uring-crate]: https://github.com/tokio-rs/io-uring
[mio]: https://github.com/tokio-rs/mio
[io-uring-man]: https://man7.org/linux/man-pages/man7/io_uring.7.html
[io-uring-wiki]: https://en.wikipedia.org/wiki/Io_uring
[`tokio/src/runtime/runtime.rs`]: https://github.com/tokio-rs/tokio/blob/dac81bf8c8de0a3e35f1626643674ba9faf9569c/tokio/src/runtime/runtime.rs
[`tokio/src/runtime/driver.rs`]: https://github.com/tokio-rs/tokio/blob/dac81bf8c8de0a3e35f1626643674ba9faf9569c/tokio/src/runtime/driver.rs
[`tokio/src/runtime/io/driver.rs`]: https://github.com/tokio-rs/tokio/blob/dac81bf8c8de0a3e35f1626643674ba9faf9569c/tokio/src/runtime/io/driver.rs
[`tokio/src/runtime/scheduler/mod.rs`]: https://github.com/tokio-rs/tokio/blob/dac81bf8c8de0a3e35f1626643674ba9faf9569c/tokio/src/runtime/scheduler/mod.rs
[`scheduler/current_thread/mod.rs`]: https://github.com/tokio-rs/tokio/blob/dac81bf8c8de0a3e35f1626643674ba9faf9569c/tokio/src/runtime/scheduler/current_thread/mod.rs
[`scheduler/multi_thread/worker.rs`]: https://github.com/tokio-rs/tokio/blob/dac81bf8c8de0a3e35f1626643674ba9faf9569c/tokio/src/runtime/scheduler/multi_thread/worker.rs
[`tokio/src/runtime/time/wheel/mod.rs`]: https://github.com/tokio-rs/tokio/blob/dac81bf8c8de0a3e35f1626643674ba9faf9569c/tokio/src/runtime/time/wheel/mod.rs
[`tokio/src/runtime/io/driver/uring.rs`]: https://github.com/tokio-rs/tokio/blob/dac81bf8c8de0a3e35f1626643674ba9faf9569c/tokio/src/runtime/io/driver/uring.rs
[`runtime/driver/op.rs`]: https://github.com/tokio-rs/tokio/blob/dac81bf8c8de0a3e35f1626643674ba9faf9569c/tokio/src/runtime/driver/op.rs
[`tokio/src/runtime/task/join.rs`]: https://github.com/tokio-rs/tokio/blob/dac81bf8c8de0a3e35f1626643674ba9faf9569c/tokio/src/runtime/task/join.rs
[`AsyncFd<T>`]: https://docs.rs/tokio/latest/tokio/io/unix/struct.AsyncFd.html
[`std::future::Future`]: https://doc.rust-lang.org/std/future/trait.Future.html
[`Waker`]: https://doc.rust-lang.org/std/task/struct.Waker.html
[primitives]: ./primitives.md
[techniques]: ./techniques.md
[comparison]: ./comparison.md
[effects-and-event-loops]: ./effects-and-event-loops.md
[d-landscape]: ./d-landscape.md
[io-uring/index]: ./io-uring/index.md
[io-uring/features]: ./io-uring/features.md
[io-uring/opcodes-reference]: ./io-uring/opcodes-reference.md
[Glommio]: ./glommio.md
[Monoio]: ./monoio.md
[libuv]: ./libuv.md
[go-netpoller]: ./go-netpoller.md
[Go netpoller]: ./go-netpoller.md
[dotnet]: ./dotnet.md
[java]: ./java.md
[eio]: ../algebraic-effects/ocaml-eio.md
