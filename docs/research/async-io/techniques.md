# Implementation Techniques for Event Loops

A concept/reference doc surveying the implementation techniques that state-of-the-art async I/O runtimes use to turn raw OS notification primitives into ergonomic, high-throughput schedulers. Where a [primitive][primitives] (epoll, kqueue, `io_uring`, IOCP) defines _what the kernel offers_, this document covers _what runtimes build on top_: the reactor/proactor split, ring-buffer batching, scheduler topologies, wakers and continuations, timer wheels, buffer ownership, cancellation, backpressure, per-core data layout, and feature-probing fallback chains. The deep-dives ([tokio][tokio], [glommio][glommio], [monoio][monoio], [seastar][seastar], [boost.asio][boost-asio], [libuv][libuv]) instantiate these techniques in concrete code; this page is the cross-cutting taxonomy that ties them together.

> Scope note. This is the "techniques" leaf of survey question Q2 ("the key implementation techniques, especially those used by SOTA libraries"). It pairs with [primitives][primitives] (the kernel-level mechanisms), [comparison][comparison] (the head-to-head matrix), and [effects-and-event-loops][effects] (how completions resume suspended computations — fibers, continuations, algebraic effects). Code excerpts are non-runnable illustrations from the cited repos, not Sparkles examples.

---

## Reactor vs Proactor: readiness vs completion

The single most important axis in async I/O design is _who does the work and who gets told_. Two patterns, both named in Schmidt et al.'s POSA2 patterns work, divide the field.

| Aspect                     | **Reactor** (readiness)                                                   | **Proactor** (completion)                                         |
| -------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Kernel tells you           | "fd is _ready_ — you may now syscall without blocking"                    | "your operation _finished_ — here is the result"                  |
| Who issues the I/O syscall | The application, _after_ the readiness event                              | The kernel, on the application's behalf                           |
| Buffer lifetime            | Borrowed: buffer needed only during the (synchronous) `read`/`write`      | Owned: buffer handed to the kernel for the whole in-flight window |
| Canonical backends         | `epoll` (Linux), `kqueue` (BSD/macOS), `poll`/`select`, Windows `WSAPoll` | `io_uring` (Linux), `IOCP` (Windows), POSIX AIO                   |
| Extra syscall per op       | Yes (readiness notify, then the real read/write)                          | No (submission _is_ the operation)                                |
| Spurious wakeups           | Possible (readiness ≠ data)                                               | No (completion is definitive)                                     |

### Why io_uring and IOCP are proactors

With `epoll` the kernel only signals _readiness_; the application must still call `recv()` itself, which is a second syscall and a second user/kernel transition. With **io_uring** the application places a `recv` submission queue entry (SQE) describing the _whole operation_ (fd + buffer + length), and the kernel performs the receive and posts a completion queue entry (CQE) containing the byte count. The data is already in your buffer by the time you observe the CQE. **IOCP** (Windows) works the same way: you call `WSARecv` with an `OVERLAPPED` and a buffer, the kernel completes it asynchronously, and you dequeue the result from a completion port. Both are _completion_ models — hence proactors.

This distinction propagates upward into the entire runtime design:

- A **readiness** runtime can lend the application's `&mut [u8]` to the kernel transiently; the buffer is only touched during the synchronous syscall, so borrowed slices are safe.
- A **completion** runtime cannot. The kernel may touch the buffer at any point between submission and completion, so the buffer's lifetime must outlive the borrow — forcing _ownership transfer_ (see [Buffer management](#buffer-management)).

`io_uring` can _also_ be driven in a readiness style via `IORING_OP_POLL_ADD` (a poll that, especially in its multishot form, behaves like epoll), which several runtimes use as a migration bridge — monoio's `poll-io` feature installs such a poller (`opcode::PollAdd` over the inner uring fd, tagged with `POLLER_USERDATA`) so legacy readiness-based code can run on a uring driver. See [io-uring/features][uring-features] for the op-by-op breakdown.

---

## The SQ/CQ ring model and syscall amortization

`io_uring`'s defining structure is a **pair of single-producer/single-consumer ring buffers** mapped into both kernel and user space:

- **SQ (submission queue)** — userspace produces SQEs (operation descriptors); the kernel consumes them.
- **CQ (completion queue)** — the kernel produces CQEs (results); userspace consumes them.

Because both rings are shared memory, the application can enqueue _many_ operations and the kernel can post _many_ completions **without any syscall at all**. The syscall (`io_uring_enter`) is needed only to (a) tell the kernel "I've added N submissions, go look" and/or (b) block until at least M completions arrive. This is **syscall amortization**: one `io_uring_enter` can cover hundreds of operations.

### `submit_and_wait` — submit + park in one syscall

The key amortization primitive is `submit_and_wait(n)`: it flushes all queued SQEs _and_ blocks until `n` CQEs are available, in a single kernel crossing. This collapses the classic "drain the submission queue, then `epoll_wait`" two-syscall pattern into one. monoio's park loop does exactly this:

```rust
// rust/monoio/monoio/src/driver/uring/mod.rs — IoUringDriver::inner_park
if let Some(duration) = timeout {
    match inner.ext_arg {
        // Submit and Wait with timeout in a TimeoutOp way.
        // Better compatibility (5.4+).
        false => {
            self.install_timeout(inner, duration);
            inner.uring.submit_and_wait(1)?;
        }
        // Submit and Wait with enter args.
        // Better performance (5.11+).
        true => {
            let timespec = timespec(duration);
            let args = io_uring::types::SubmitArgs::new().timespec(&timespec);
            if let Err(e) = inner.uring.submitter().submit_with_args(1, &args) { /* ETIME ok */ }
        }
    }
} else {
    // Submit and Wait without timeout
    inner.uring.submit_and_wait(1)?;
}
```

Two timeout strategies appear here, gated by a runtime feature probe:

| Timeout mechanism                                             | Trigger                                   | Since                           | Cost                               |
| ------------------------------------------------------------- | ----------------------------------------- | ------------------------------- | ---------------------------------- |
| Submit a `Timeout` SQE alongside the wait                     | `ext_arg == false`                        | Linux 5.4 (`IORING_OP_TIMEOUT`) | Consumes one SQE/CQE slot per park |
| Pass a timespec directly to `io_uring_enter` via `SubmitArgs` | `ext_arg == true` (`IORING_FEAT_EXT_ARG`) | Linux 5.11                      | No extra SQE; cleaner              |

monoio detects this at startup with `uring.params().is_feature_ext_arg()` and stores the boolean in `UringInner.ext_arg`. The 5.11 marker for `IORING_ENTER_EXT_ARG`/`IORING_FEAT_EXT_ARG` is documented in the [io_uring_enter(2)][enter-man] man page. See the [io-uring/timeline][uring-timeline] for the full feature-by-kernel matrix.

### Lazy submission (deferred `io_uring_enter`)

A subtle but important optimization: a runtime need not call `io_uring_enter` the moment a task enqueues an op. monoio defers submission entirely — `submit_with_data` pushes the SQE onto the ring and _returns immediately_ without entering the kernel, relying on the next `park` to flush:

```rust
// rust/monoio/monoio/src/driver/uring/mod.rs — submit_with_data
// CHIHAI: We are not going to do syscall now. If we are waiting
// for IO, we will submit on `park`.
// let _ = inner.submit();
Ok(op)
```

This means that within one scheduler turn, a task can issue dozens of ops that all batch into a single `submit_and_wait`. Tokio's experimental uring driver currently takes the conservative opposite stance — it submits each op eagerly (`// Note: For now, we submit the entry immediately without utilizing batching.`) — but only flushes completions back to wakers in `dispatch_completions`.

### Multishot: amortizing the _re-arm_

A single-shot op produces exactly one CQE and is then done; to keep accepting connections you must re-submit an `accept` SQE after every completion. **Multishot** ops invert this: one SQE produces a _stream_ of CQEs until cancelled, eliminating the re-arm syscall and slab churn.

| Multishot op                   | What it streams                     | Since      | CQE marker                                     |
| ------------------------------ | ----------------------------------- | ---------- | ---------------------------------------------- |
| `IORING_OP_ACCEPT` (multishot) | One CQE per accepted connection     | Linux 5.19 | `IORING_CQE_F_MORE` set while more will follow |
| Multishot `recv`/`recvmsg`     | One CQE per received datagram/chunk | Linux 6.0  | `IORING_CQE_F_MORE`                            |
| `POLL_ADD` (multishot)         | One CQE per readiness edge          | Linux 5.13 | `IORING_CQE_F_MORE`                            |

The contract: while `IORING_CQE_F_MORE` is set on a CQE, the operation remains armed and the same `user_data` slot stays alive. The 5.19 marker for multishot accept (`IORING_ACCEPT_MULTISHOT`) is confirmed by the [io_uring_prep_multishot_accept(3)][multishot-accept-man] man page. Runtimes that support zero-copy send (`SEND_ZC`) must also handle the _two-CQE_ protocol — a result CQE with `IORING_CQE_F_MORE`, then a notification CQE with `IORING_CQE_F_NOTIF` once the buffer is safe to reuse. monoio's lifecycle state machine encodes this directly:

```rust
// rust/monoio/monoio/src/driver/uring/lifecycle.rs
const IORING_CQE_F_MORE: u32  = 2;  // more CQEs will follow (e.g. SEND_ZC)
const IORING_CQE_F_NOTIF: u32 = 8;  // this CQE is the zero-copy notification

enum Lifecycle {
    Submitted,
    Waiting(Waker),
    Completed(io::Result<MaybeFd>, u32),
    CompletedMore(io::Result<MaybeFd>, u32),       // got MORE, awaiting NOTIF (was Submitted)
    WaitingMore(Waker, io::Result<MaybeFd>, u32),  // got MORE, awaiting NOTIF (was Waiting)
    IgnoredMore(Box<dyn std::any::Any>),           // future dropped, NOTIF still pending
    Ignored(Box<dyn std::any::Any>),
}
```

The crucial correctness rule visible in `complete()`: on a `MORE` CQE in `Waiting` state, the runtime stores the result but **does not wake** — it transitions to `WaitingMore` and waits for the `NOTIF` CQE before waking the task, because the owned buffer must not be reused until the notification arrives. See [io-uring/opcodes-reference][uring-opcodes] for the per-opcode CQE-flag semantics.

---

## Scheduler architectures

Once submission/completion plumbing exists, the runtime must decide _which thread runs which task_. There are four dominant topologies, ordered roughly by sharing.

| Architecture                        | Task placement                                       | Synchronization            | Cache behavior                       | Exemplars                                                        |
| ----------------------------------- | ---------------------------------------------------- | -------------------------- | ------------------------------------ | ---------------------------------------------------------------- |
| **Single-threaded**                 | One queue, one thread                                | None                       | Excellent (single core)              | Node/libuv main loop, `tokio` current-thread, Python asyncio     |
| **Global-queue multi-thread**       | One shared MPMC queue, N workers                     | Lock/atomics on every pop  | Poor (queue is a contention point)   | Naive thread pools; early schedulers                             |
| **Work-stealing**                   | Per-worker local queue + shared overflow             | Atomics only when stealing | Good (local hits common, steal rare) | `tokio` multi-thread, Go runtime, Rust `cats-effect`/Fiber pools |
| **Thread-per-core / share-nothing** | One reactor + queues _pinned_ per core; no migration | None on the hot path       | Best (data never leaves its core)    | `seastar`, `glommio`, `monoio`                                   |

### Work-stealing (Tokio, Cats-Effect)

Tokio's multi-thread scheduler gives each worker a bounded **local run queue** (a lock-free SPMC ring of fixed capacity) plus access to a shared **global/injection queue** for overflow and remote wakeups. A worker prefers its own local queue; only when empty does it attempt to _steal_ a batch from a random peer.

```rust
// rust/tokio/tokio/src/runtime/scheduler/multi_thread/queue.rs
const LOCAL_QUEUE_CAPACITY: usize = 256;   // 4 under loom (test model checker)

pub(crate) struct Local<T: 'static> { inner: Arc<Inner<T>> }   // producer: single thread
pub(crate) struct Steal<T: 'static>(Arc<Inner<T>>);            // consumer: many threads
```

```rust
// rust/tokio/tokio/src/runtime/scheduler/multi_thread/worker.rs — steal_work
let start = self.rand.fastrand_n(num as u32) as usize;   // start from a random worker
for i in 0..num {
    let i = (start + i) % num;
    if i == worker.index { continue; }                   // don't steal from ourself
    if let Some(task) = target.steal.steal_into(&mut self.run_queue, &mut self.stats) {
        return Some(task);
    }
}
worker.handle.next_remote_task()                         // fall back to the global queue
```

Two extra tricks in Tokio's worker make a big difference:

- **LIFO slot** — a one-task `lifo_slot` per worker holds the _most recently woken_ task. When task A wakes task B (e.g., a message handoff), B runs immediately on the same core for cache-hot continuation, rather than going to the back of the queue. Bounded by `MAX_LIFO_POLLS_PER_TICK = 3` to avoid starving the queue, and the LIFO slot task is _not_ stealable (it's "part of the current task").
- **Periodic global-queue check** — to avoid starving globally-injected tasks, a worker checks the global queue every `global_queue_interval` ticks (auto-tuned from observed poll times), even when its local queue is non-empty.

Scala's `cats-effect` ([cats-effect][cats-effect]) and `ZIO` ([zio][zio]) use the same work-stealing fiber-pool design; Go's runtime ([go-netpoller][go]) pioneered the per-P local-run-queue + steal model in a production GC'd language.

### Thread-per-core / share-nothing (Seastar, Glommio, monoio)

The opposite philosophy: **never share mutable state between cores.** Each core (shard) runs its own reactor, its own task queues, its own memory allocator arena, and its own slice of the data. There are no locks on the hot path because there is no cross-core mutation — communication happens by _explicit message passing_ between shards.

Seastar is the archetype. `reactor.cc` constructs one `reactor` per shard, each pinned to a CPU, each owning a `reactor_backend`:

```cpp
// seastar/src/core/reactor.cc
reactor::reactor(std::shared_ptr<seastar::smp> smp, alien::instance& alien,
                 unsigned id, reactor_backend_selector rbs, reactor_config cfg) {
    // ...
    _backend = rbs.create(*this);   // per-shard backend (io_uring / aio / epoll)
    _backend->start_tick();
}
```

Cross-shard work is routed through lock-free SPSC `smp_message_queue`s (`smp::submit_to`, `invoke_on_all`, `invoke_on_others`) — a `reactor.cc` `smp_message_queue` exists for every (from-shard, to-shard) pair and batches messages to amortize the cross-core cache-line bounce. Glommio brings this model to Rust: a `LocalExecutor` per thread, optionally a `LocalExecutorPoolBuilder` with a `PoolPlacement` that _pins_ each executor to a CPU set (`bind_to_cpu_set`), each running a private `io_uring`.

| Property                    | Work-stealing                                      | Thread-per-core                                              |
| --------------------------- | -------------------------------------------------- | ------------------------------------------------------------ |
| Tail latency                | Higher variance (steal jitter, cross-core wakeups) | Low, predictable (no migration)                              |
| Load balancing              | Automatic (idle workers steal)                     | Manual (must shard work evenly; hot shard = bottleneck)      |
| `Send` requirement on tasks | Required (tasks migrate between threads)           | Not required — `glommio`/`monoio` futures need not be `Send` |
| Shared-state cost           | Atomics / locks for shared data                    | Message passing; no shared mutable data                      |
| Best for                    | General workloads, uneven task sizes               | Uniform, partitionable workloads (databases, proxies)        |

Glommio additionally layers a **fair scheduler over multiple `TaskQueue`s** within a single core, ordered in a `BinaryHeap` by virtual runtime and weighted by `Shares`, with a preemption timer (`DEFAULT_PREEMPT_TIMER = 100ms`, tunable by `Latency` requirements) so a CPU-bound task queue cannot starve a latency-sensitive one. This is essentially a userspace CFS. See [glommio][glommio] and [seastar][seastar] for the full treatment.

### M:N scheduling, green threads, and fibers

All of the above multiplex many logical tasks (M) onto few OS threads (N) — **M:N scheduling**. The unit of multiplexing differs:

| Unit                              | What suspends                            | Stack                                   | Examples                                                                                     |
| --------------------------------- | ---------------------------------------- | --------------------------------------- | -------------------------------------------------------------------------------------------- |
| **Stackless future/coroutine**    | A state-machine poll returning `Pending` | None (state lives in the future struct) | Rust `async`/`await` (tokio, glommio, monoio), C++20 coroutines, Python `async def`          |
| **Stackful fiber / green thread** | A full stack switch                      | Heap-allocated stack                    | Go goroutines, Java virtual threads ([java-loom][loom]), OCaml Eio fibers ([ocaml-eio][eio]) |

Stackless futures have zero per-task stack cost and no stack-overflow risk, but cannot suspend across an arbitrary call boundary without `await` coloring functions. Stackful fibers allow _direct-style_ code (any function can block) at the cost of stack memory and a context switch. The connection between a completed I/O operation and the resumption of a suspended task is detailed next, and the deeper continuation/effect theory in [effects-and-event-loops][effects] and [ocaml-eio][eio].

---

## Wakers, continuations, and resuming a suspended task

When a proactor posts a CQE (or a reactor reports readiness), _something_ must reconnect that event to the task that was waiting on it. The mechanism is a **waker**: an opaque handle the task registers when it suspends, which the driver invokes on completion.

The clearest illustration is Tokio's experimental uring driver, whose `Lifecycle` is a small state machine keyed by the SQE's `user_data` (a slab index):

```rust
// rust/tokio/tokio/src/runtime/driver/op.rs (Lifecycle) +
// rust/tokio/tokio/src/runtime/io/driver/uring.rs (dispatch_completions)
match ops.get_mut(idx) {
    Some(Lifecycle::Waiting(waker)) => {
        waker.wake_by_ref();                                // resume the suspended task
        *ops.get_mut(idx).unwrap() = Lifecycle::Completed(cqe);
    }
    Some(Lifecycle::Cancelled(cancel_data)) => { /* discard, free fd if Open */ ops.remove(idx); }
    // ...
}
```

The full transition graph:

| From state            | Event                                 | To state          | Side effect                                          |
| --------------------- | ------------------------------------- | ----------------- | ---------------------------------------------------- |
| (op submitted)        | `register_op(entry, waker)`           | `Waiting(Waker)`  | SQE pushed with `user_data = slab idx`               |
| `Waiting(waker)`      | CQE arrives in `dispatch_completions` | `Completed(cqe)`  | `waker.wake_by_ref()` — task rescheduled             |
| `Completed(cqe)`      | task polls again                      | (removed)         | result handed to the future, slab slot freed         |
| `Waiting`/`Submitted` | future dropped → `cancel_op`          | `Cancelled(data)` | keeps uring data alive until CQE                     |
| `Cancelled`           | CQE arrives                           | (removed)         | result discarded; if `Open`, the leaked fd is closed |

The flow end-to-end:

1. A future is polled; the I/O is not done, so it stores its `Waker` in `Lifecycle::Waiting` and returns `Poll::Pending`.
2. The op runs in the kernel. The worker eventually parks via `submit_and_wait`.
3. A CQE arrives. The driver maps `cqe.user_data()` → slab slot, finds `Waiting(waker)`, calls `wake_by_ref()`. That pushes the task back onto a run queue (Tokio) — often into the LIFO slot for cache-hot resumption.
4. The scheduler re-polls the future; it finds `Completed(cqe)`, reads the result, and returns `Poll::Ready`.

monoio's `poll_op` (in `lifecycle.rs`) shows the dual: a future that polls _before_ the CQE lands transitions `Submitted → Waiting(waker)`; if it polls _after_, it finds `Completed` and returns immediately. The waker is, in effect, a **reified continuation** of the suspended task — the same role that an effect handler's resumption plays in [OCaml Eio][eio] or a delimited continuation plays in [theory/compilation][effects]. The forward reference for the full taxonomy of "what gets resumed and how" is [effects-and-event-loops][effects].

---

## Timer management

A runtime must answer "wake task X at time T" efficiently for thousands of concurrent timers. Two families dominate.

| Structure                             | Insert             | Cancel    | Tick / find-min         | Notes                                                                                               |
| ------------------------------------- | ------------------ | --------- | ----------------------- | --------------------------------------------------------------------------------------------------- |
| **Binary min-heap**                   | O(log n)           | O(log n)¹ | O(1) peek, O(log n) pop | Simple; used by libuv (`heap`), Go's `timer` heap, Python asyncio (`heapq`)                         |
| **Balanced search tree of deadlines** | O(log n)           | O(log n)  | O(log n) leftmost       | Ordered, supports range queries; Glommio's timer set is a `BTreeMap<(Instant, id), Waker>`          |
| **Hashed/hierarchical timing wheel**  | **O(1)** amortized | **O(1)**  | **O(1)** advance        | Tokio, kernel timers, Kafka purgatory, Seastar's bucketed `timer_set`; from Varghese & Lauck (1987) |

¹ heaps need a side-index or lazy-deletion (tombstones) to cancel an arbitrary timer in better than O(n).

### Timing wheels (Tokio)

The **hashed and hierarchical timing wheel** comes from Varghese & Lauck's 1987 SOSP paper "Hashed and Hierarchical Timing Wheels: Data Structures for the Efficient Implementation of a Timer Facility" ([paper][timing-wheels-paper]). The idea: a circular array of _slots_; each tick advances a cursor by one slot and fires everything in it — O(1) insert/expire within the wheel's range. To cover a large range without a giant array, **stack multiple wheels at coarsening granularities** (a hierarchy); timers cascade from coarse wheels down to fine ones as their deadline approaches.

Tokio's `Wheel` is a 6-level hierarchy, 64 slots per level, 1 ms base resolution:

```rust
// rust/tokio/tokio/src/runtime/time/wheel/mod.rs
// Levels:
//   1 ms slots   /  64 ms range
//   64 ms slots  /  ~4 sec range
//   ~4 sec slots /  ~4 min range
//   ~4 min slots /  ~4 hr range
//   ~4 hr slots  /  ~12 day range
//   ~12 day slots/  ~2 yr range
const NUM_LEVELS: usize = 6;
pub(super) const MAX_DURATION: u64 = (1 << (6 * NUM_LEVELS)) - 1;   // ~2 years at 1ms
```

The level for a deadline is computed from the position of the highest differing bit between `now` and `when` (`level_for`), so each level is a 6-bit "digit" of the elapsed-time delta. `process_expiration` cascades entries down a level (`mark_pending` → `levels[level].add_entry`) or, at level 0, moves them to the `pending` list for firing. Entries are stored in **intrusive linked lists** (the `TimerShared` node _is_ the list link), so registration allocates nothing. See [tokio][tokio] for how the timer driver integrates with the I/O driver's park.

The trade-off: wheels give O(1) but have a fixed minimum resolution (1 ms here) and a bounded maximum (`MAX_DURATION`); heaps/trees give exact deadlines at O(log n). Thread-per-core runtimes that already keep timers per-shard (no cross-core timer contention) can afford an ordered tree/heap when exactness matters and n-per-shard is small — Glommio takes this route with a per-executor `BTreeMap`, whereas Seastar keeps a bucketed `timer_set` closer to the timing-wheel family.

---

## Buffer management

This is where the reactor/proactor split has the most visible API consequences.

### Why completion I/O forces ownership transfer

In a readiness model, `read(fd, &mut buf)` is _synchronous_: the kernel touches `buf` only during the call, so a borrowed `&mut [u8]` is sound. In a completion model, the buffer is handed to the kernel at _submission_ and the kernel may write to it any time before the CQE. If the future holding that borrow is dropped, or the buffer is freed, while the op is in flight, the kernel writes into freed memory — a use-after-free. The borrow checker cannot express "this borrow lasts until an event that happens at runtime."

The standard fix is **ownership transfer**: the buffer is _moved into_ the operation and _moved back out_ on completion. monoio encodes this with an `unsafe` `IoBuf` trait whose buffers are owned `'static` values:

```rust
// rust/monoio/monoio/src/buf/io_buf.rs
/// Because buffers are passed by ownership to the runtime, Rust's slice API
/// (`&buf[..]`) cannot be used. Instead, `monoio` provides an owned slice
/// API: `slice()`. The method takes ownership of the buffer ...
pub unsafe trait IoBuf: Unpin + 'static {
    fn read_ptr(&self) -> *const u8;     // stable address for the whole op
    fn bytes_init(&self) -> usize;       // length the kernel will read
}
unsafe impl IoBuf for Vec<u8> { /* ... */ }
```

Consequently monoio's read API is `read(buf) -> (Result<usize>, buf)`: you give the runtime your `Vec<u8>`, and you get it back (with the result) when the op completes. This is the _BufResult_ pattern shared by `tokio-uring`, `glommio` (`DmaBuffer`), and Windows IOCP wrappers. Cancellation is the hard case — if a future is dropped mid-op, the buffer must be kept alive until the kernel is done. monoio's `Lifecycle::Ignored(Box<dyn Any>)` does exactly this: dropping the op moves the buffer into a boxed `Any` held by the driver until the CQE arrives, then frees it.

| Model                | Buffer ownership                              | API shape                                                           | Used by                                    |
| -------------------- | --------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------ |
| **Borrowed**         | `&mut [u8]` lent during a synchronous syscall | `read(&mut buf) -> Result<usize>`                                   | tokio (epoll), libuv, asio readiness paths |
| **Owned (transfer)** | Buffer moved in, moved back out               | `read(buf) -> (Result<usize>, buf)`                                 | monoio, tokio-uring, glommio, IOCP         |
| **Kernel-provided**  | Kernel picks a buffer from a registered ring  | submit with `IOSQE_BUFFER_SELECT`; CQE reports the chosen buffer id | high-throughput uring servers              |

### Provided buffer rings

For _receive_ paths, owning a dedicated buffer per pending read wastes memory when most connections are idle. `io_uring`'s **provided buffers** let the application register a _pool_ of buffers and submit a `recv` _without_ a buffer; the kernel picks a free buffer from the pool only when data actually arrives and reports the chosen buffer id in the CQE. The modern, efficient form is the **provided buffer ring** (`IORING_REGISTER_PBUF_RING` / `io_uring_setup_buf_ring`), a shared ring the application replenishes by simply advancing a tail — available since **Linux 5.19** ([io_uring_register_buf_ring(3)][buf-ring-man]), superseding the older per-op `IORING_OP_PROVIDE_BUFFERS`. This decouples buffer count from in-flight-op count and is essential for C10K-style servers with many mostly-idle connections. See [io-uring/features][uring-features].

---

## Cancellation and structured concurrency

A robust runtime must be able to stop work cleanly, and to guarantee that spawned work does not outlive its parent. These are two faces of the same concern.

### Cancellation propagation in completion runtimes

Cancelling an in-flight op is not free in a proactor: the kernel may already be using the buffer/fd. Two layers cooperate:

1. **Local bookkeeping.** Dropping the future transitions the slab slot to a "no longer interested" state (`Lifecycle::Cancelled` in Tokio, `Lifecycle::Ignored` in monoio) _without_ freeing the buffer or removing the slot — the data must outlive the kernel's use of it.
2. **Kernel cancel.** Optionally submit `IORING_OP_ASYNC_CANCEL` referencing the op's `user_data`. monoio does this under the `async-cancel` feature:

```rust
// rust/monoio/monoio/src/driver/uring/mod.rs — drop_op
if !_must_finished && !_skip_cancel {
    let cancel = opcode::AsyncCancel::new(index as u64).build().user_data(u64::MAX);
    if inner.uring.submission().push(&cancel).is_err() {
        let _ = inner.submit();
        let _ = inner.uring.submission().push(&cancel);
    }
}
```

The slot is reclaimed only when the (possibly cancelled) op finally posts its CQE. Tokio's `dispatch_completions` shows the cleanup: a CQE for a `Cancelled` op is discarded, and if it was an `Open` that _succeeded_ before cancellation landed, the leaked fd is closed (`OwnedFd::from_raw_fd`). This fd-leak handling is why monoio wraps op results in `MaybeFd`, which `close()`s on drop if the result was a file descriptor.

### Structured concurrency

Structured concurrency makes task lifetime lexical: child tasks cannot outlive the scope that spawned them, and the scope does not exit until all children finish (or are cancelled).

| Construct                      | Language / library                    | Mechanism                                                        |
| ------------------------------ | ------------------------------------- | ---------------------------------------------------------------- |
| `Switch`                       | OCaml Eio ([eio][eio])                | Fibers are forked into a switch; switch exit joins/cancels all   |
| Nursery                        | Trio (Python, [python-async][python]) | `async with trio.open_nursery()`; block exit awaits all children |
| `StructuredTaskScope`          | Java ([java-loom][loom])              | `fork()` children, `join()`, scope close cancels stragglers      |
| Cancellation scope / `select!` | Rust async (tokio)                    | Dropping a future cancels it; `JoinSet` bounds task lifetime     |
| Seastar `when_all` / gates     | Seastar ([seastar][seastar])          | `gate` blocks shard shutdown until in-flight futures drain       |

The payoff is that cancellation _propagates structurally_: failing or cancelling a scope cancels its entire subtree, and resource cleanup is guaranteed at scope exit. This is the runtime-side counterpart of the effect-handler-based structured concurrency analyzed in [ocaml-eio][eio] and the broader [effects-and-event-loops][effects] discussion.

---

## Backpressure and flow control

Unbounded queues are a latency and memory hazard: if producers outrun consumers, the queue grows without limit and tail latency explodes. SOTA runtimes apply backpressure at several layers:

| Layer                  | Mechanism                                               | Example                                                              |
| ---------------------- | ------------------------------------------------------- | -------------------------------------------------------------------- |
| Run queue              | Bounded local queue with overflow to a shared queue     | Tokio `LOCAL_QUEUE_CAPACITY = 256`, overflow to global/injection     |
| Channels               | Bounded MPSC; `send().await` suspends when full         | tokio `mpsc::channel(n)`, Go buffered channels                       |
| Submission ring        | Fixed SQ depth; submit-and-retry on `EBUSY`/full        | monoio/tokio flush-then-retry when `submission().is_full()`          |
| Completion ring        | Dispatch completions when CQ is full before adding more | Tokio: `while ctx.completion().is_full() { dispatch_completions() }` |
| Connection accept      | Multishot accept rate vs. handler readiness             | drop/pause accept under load                                         |
| Cooperative scheduling | Per-task poll budget so one task can't hog a worker     | Tokio's `coop` budget; Glommio's preempt timer                       |

The ring buffers themselves _are_ a backpressure mechanism: when the SQ is full, `submit_with_data` must `submit()` (flush to kernel) before it can push more — naturally rate-limiting submission to the kernel's drain rate. Glommio goes further with its `Shares`/`Latency`-weighted multi-queue scheduler, explicitly trading CPU between task queues so a bulk queue cannot starve a latency-critical one.

---

## Per-core data, false sharing, and NUMA

The performance ceiling of a multi-core runtime is often set not by algorithms but by _cache coherency traffic_. Key techniques:

| Technique                        | Problem solved                                                                  | Mechanism                                                                                          |
| -------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **Per-core / per-shard data**    | Cross-core cache-line bouncing                                                  | Each core owns its queues, allocator, timers (Seastar/Glommio/monoio); no shared mutable hot state |
| **Cache-line padding**           | _False sharing_ — two unrelated atomics on one 64B line ping-pong between cores | Pad/align hot atomics to 64 bytes (`#[repr(align(64))]`, `crossbeam::CachePadded`)                 |
| **CPU pinning (affinity)**       | Scheduler migration trashing L1/L2                                              | `sched_setaffinity` / `bind_to_cpu_set` (Glommio `PoolPlacement`, Seastar `smp`)                   |
| **NUMA-aware placement**         | Remote-node memory latency                                                      | Allocate a shard's memory on its local NUMA node; Seastar pins memory per shard                    |
| **Message-passing over sharing** | Lock contention                                                                 | SPSC `smp_message_queue` between shards (Seastar) instead of shared locked structures              |

Seastar's whole model is "share nothing, message everything": each shard's `reactor` and memory are local, and the only cross-core traffic is the batched `smp_message_queue`, whose `maybe_wakeup`/`flush_response_batch` logic explicitly amortizes the cache-line transfer. Tokio's work-stealing queue uses _wider-than-necessary_ head/tail indices specifically to fight ABA and reduce contention (`// Use wider integers when possible to increase ABA resilience. See issue #5041`). The take-away: a thread-per-core runtime trades automatic load-balancing for the elimination of nearly all coherency traffic — which is why databases and proxies (ScyllaDB on Seastar, Redpanda on Seastar) choose it. See [comparison][comparison] for where each runtime lands on this spectrum.

---

## Runtime feature-probing and graceful fallback

`io_uring` is young and its op support varies wildly by kernel; a portable runtime must _probe_ capabilities at startup and fall back gracefully (often all the way down to epoll). The probing happens at three granularities.

### Backend selection (which mechanism at all)

Seastar enumerates _available_ backends in priority order and falls back at the backend level:

```cpp
// seastar/src/core/reactor_backend.cc
std::vector<reactor_backend_selector> reactor_backend_selector::available() {
    std::vector<reactor_backend_selector> ret;
#ifdef SEASTAR_HAVE_URING
    if (detect_io_uring()) ret.push_back(reactor_backend_selector("io_uring"));
#endif
    if (has_enough_aio_nr() && detect_aio_poll()) ret.push_back(reactor_backend_selector("linux-aio"));
    ret.push_back(reactor_backend_selector("epoll"));      // always-present fallback
    return ret;
}
```

`detect_io_uring()` is notably defensive — it not only tries to create a ring but applies _kernel-version-aware_ guards: it refuses `io_uring` on kernels older than 5.17 if MD/RAID devices are present (older kernels fell back to slow workqueues for RAID), and refuses on < 5.12 unless `mlock` limits are generous enough for the ring's locked memory:

```cpp
// seastar/src/core/reactor_backend.cc — detect_io_uring
if (!kernel_uname().whitelisted({"5.17"}) && have_md_devices()) return false;
if (!kernel_uname().whitelisted({"5.12"}) && mlock_limit() < (8 << 20)) return false;
auto ring_opt = try_create_uring(1, false);
// ...
```

So the canonical fallback chain on Linux is **`io_uring` → linux-aio → epoll**.

### Op-level probing (which operations within io_uring)

Even when `io_uring` is present, individual opcodes may be unsupported. The kernel exposes `IORING_REGISTER_PROBE`, which returns a bitmap of supported opcodes. Tokio's experimental uring driver uses it to decide _per operation_ whether to use uring or fall back:

```rust
// rust/tokio/tokio/src/runtime/io/driver/uring.rs — try_init / check_and_init
let uring = IoUring::new(DEFAULT_RING_SIZE)?;
match uring.submitter().register_probe(probe) {
    Ok(_) => {}
    Err(e) if e.raw_os_error() == Some(libc::EINVAL) =>
        return Err(io::Error::from_raw_os_error(libc::ENOSYS)), // no IORING_REGISTER_PROBE
    Err(e) => return Err(e),
}
// later, per op:
Ok(probe.as_ref().is_some_and(|probe| probe.is_supported(opcode)))
```

The fallback policy is explicit and graceful — uring is treated as an _opt-in accelerator_ layered over the existing epoll/mio reactor:

| Probe result                                       | Behavior                                              |
| -------------------------------------------------- | ----------------------------------------------------- |
| `io_uring_setup` returns `ENOSYS`                  | `io_uring` unsupported → use epoll/mio path           |
| `io_uring_setup` returns `EPERM` (seccomp-blocked) | fall back to `spawn_blocking` (see Tokio issue #7691) |
| `IORING_REGISTER_PROBE` returns `EINVAL`           | treat as `ENOSYS` → no uring                          |
| probe present but opcode unsupported               | use the per-op fallback for _that_ op only            |

monoio takes a compile-time-plus-runtime hybrid: the `legacy` (epoll) and `iouring` features are cfg-gated, and the `Inner` enum dispatches to `UringInner` or `LegacyInner` at runtime, with a `poll-io` bridge that runs readiness-style code over a uring `PollAdd` poller. Eio's `eio_linux` similarly prefers `io_uring` but ships `eio_posix` (kqueue/poll) for everything else ([ocaml-eio][eio]).

### Feature-flag probing (which uring _features_)

The finest granularity: even a supported op may have a faster path on newer kernels. monoio's `ext_arg` probe (`is_feature_ext_arg()`, `IORING_FEAT_EXT_ARG`, Linux 5.11) chooses between submitting a `Timeout` SQE (5.4-compatible) and passing the timeout inline to `io_uring_enter` (5.11, faster). This three-tier strategy — _backend → opcode → feature flag_ — is the general pattern every portable uring runtime follows; the per-feature kernel matrix lives in [io-uring/timeline][uring-timeline] and [io-uring/features][uring-features].

---

## Technique → runtime cross-reference

| Technique                       | Primary exemplars (deep-dive)                                                                                              |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Reactor (readiness)             | [libuv][libuv], [boost.asio][boost-asio] (epoll/kqueue), [go-netpoller][go], [tokio][tokio] (epoll path)                   |
| Proactor (completion)           | [monoio][monoio], [glommio][glommio], [seastar][seastar] (uring), [dotnet][dotnet] (IOCP), [boost.asio][boost-asio] (IOCP) |
| Work-stealing scheduler         | [tokio][tokio], [go-netpoller][go], [cats-effect][cats-effect], [zio][zio]                                                 |
| Thread-per-core / share-nothing | [seastar][seastar], [glommio][glommio], [monoio][monoio]                                                                   |
| Stackful fibers / green threads | [java-loom][loom], [ocaml-eio][eio], [go-netpoller][go]                                                                    |
| Hierarchical timing wheel       | [tokio][tokio]                                                                                                             |
| Heap/tree timers                | [libuv][libuv], [glommio][glommio], [python-async][python]                                                                 |
| Owned-buffer (transfer) I/O     | [monoio][monoio], [glommio][glommio], [dotnet][dotnet]                                                                     |
| Provided buffer rings           | [io-uring/features][uring-features], [monoio][monoio]                                                                      |
| Structured concurrency          | [ocaml-eio][eio], [java-loom][loom], [python-async][python]                                                                |
| Feature-probing / fallback      | [seastar][seastar], [tokio][tokio], [monoio][monoio], [eio-backend][eio-backend]                                           |

---

## Sources

- [Tokio uring driver — `Lifecycle` state machine and probe-based fallback (`uring.rs`)][tokio-uring-src]
- [Tokio work-stealing run queue (`queue.rs`) and worker LIFO slot (`worker.rs`)][tokio-queue-src]
- [Tokio hashed/hierarchical timing wheel (`time/wheel/mod.rs`)][tokio-wheel-src]
- [monoio uring driver — `submit_and_wait`, lazy submit, `ext_arg` (`driver/uring/mod.rs`)][monoio-uring-src]
- [monoio uring `Lifecycle` — multishot/zero-copy CQE protocol (`driver/uring/lifecycle.rs`)][monoio-lifecycle-src]
- [monoio `IoBuf` owned-buffer trait (`buf/io_buf.rs`)][monoio-iobuf-src]
- [Glommio executor — thread-per-core, `Shares`/`Latency` scheduling (`executor/mod.rs`)][glommio-exec-src]
- [Seastar reactor — per-shard reactor and backend (`core/reactor.cc`)][seastar-reactor-src]
- [Seastar backend selector — io_uring → aio → epoll fallback (`core/reactor_backend.cc`)][seastar-backend-src]
- [Varghese & Lauck, "Hashed and Hierarchical Timing Wheels" (SOSP 1987)][timing-wheels-paper]
- [io_uring_enter(2) — `IORING_ENTER_EXT_ARG`, since 5.11][enter-man]
- [io_uring_prep_multishot_accept(3) — multishot accept, since 5.19][multishot-accept-man]
- [io_uring_register_buf_ring(3) — provided buffer rings, since 5.19][buf-ring-man]
- [io_uring man pages index (kernel.dk)][kernel-dk]
- [Reactor and Proactor patterns (Schmidt, POSA2 / Pattern-Oriented Software Architecture)][posa2]
- Companion docs: [primitives][primitives], [comparison][comparison], [effects-and-event-loops][effects], [io-uring features][uring-features], [io-uring timeline][uring-timeline], [io-uring opcodes][uring-opcodes]

<!-- References -->

[primitives]: ./primitives.md
[comparison]: ./comparison.md
[effects]: ./effects-and-event-loops.md
[tokio]: ./tokio.md
[glommio]: ./glommio.md
[monoio]: ./monoio.md
[seastar]: ./seastar.md
[boost-asio]: ./boost-asio.md
[libuv]: ./libuv.md
[dotnet]: ./dotnet.md
[go]: ./go-netpoller.md
[python]: ./python-async.md
[eio-backend]: ./eio-backend.md
[uring-features]: ./io-uring/features.md
[uring-timeline]: ./io-uring/timeline.md
[uring-opcodes]: ./io-uring/opcodes-reference.md
[eio]: ../algebraic-effects/ocaml-eio.md
[loom]: ../algebraic-effects/java-loom.md
[cats-effect]: ../algebraic-effects/scala-cats-effect.md
[zio]: ../algebraic-effects/scala-zio.md
[tokio-uring-src]: https://github.com/tokio-rs/tokio/blob/master/tokio/src/runtime/io/driver/uring.rs
[tokio-queue-src]: https://github.com/tokio-rs/tokio/blob/master/tokio/src/runtime/scheduler/multi_thread/queue.rs
[tokio-wheel-src]: https://github.com/tokio-rs/tokio/blob/master/tokio/src/runtime/time/wheel/mod.rs
[monoio-uring-src]: https://github.com/bytedance/monoio/blob/master/monoio/src/driver/uring/mod.rs
[monoio-lifecycle-src]: https://github.com/bytedance/monoio/blob/master/monoio/src/driver/uring/lifecycle.rs
[monoio-iobuf-src]: https://github.com/bytedance/monoio/blob/master/monoio/src/buf/io_buf.rs
[glommio-exec-src]: https://github.com/DataDog/glommio/blob/master/glommio/src/executor/mod.rs
[seastar-reactor-src]: https://github.com/scylladb/seastar/blob/master/src/core/reactor.cc
[seastar-backend-src]: https://github.com/scylladb/seastar/blob/master/src/core/reactor_backend.cc
[timing-wheels-paper]: https://www.cs.columbia.edu/~nahum/w6998/papers/sosp87-timing-wheels.pdf
[enter-man]: https://man7.org/linux/man-pages/man2/io_uring_enter.2.html
[multishot-accept-man]: https://man7.org/linux/man-pages/man3/io_uring_prep_multishot_accept.3.html
[buf-ring-man]: https://man7.org/linux/man-pages/man3/io_uring_register_buf_ring.3.html
[kernel-dk]: https://kernel.dk/io_uring.pdf
[posa2]: https://www.dre.vanderbilt.edu/~schmidt/PDF/proactor.pdf
