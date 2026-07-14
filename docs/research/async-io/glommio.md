# Glommio (Rust)

A thread-per-core, share-nothing asynchronous runtime for Rust, built directly on Linux `io_uring`, originally developed at Datadog and inspired by ScyllaDB's [Seastar].

| Field         | Value                                                                                                    |
| ------------- | -------------------------------------------------------------------------------------------------------- |
| Language      | Rust (MSRV 1.70)                                                                                         |
| License       | MIT OR Apache-2.0 (dual)                                                                                 |
| Repository    | [DataDog/glommio][repo]                                                                                  |
| Documentation | [docs.rs/glommio][docs] · [crates.io][crate]                                                             |
| Key Authors   | Glauber Costa (original author), Datadog, Inc. and contributors                                          |
| Pattern       | Thread-per-core, share-nothing cooperative scheduler                                                     |
| Encoding      | Proactor over `io_uring` (three rings/CPU: main + latency + NVMe poll); no reactor fallback (Linux-only) |

> **Latest release:** `0.9.0`. **Platform:** Linux only — `io_uring` is mandatory, with a recommended/minimum kernel of **5.8** (the crate's stated floor; in practice startup only opcode-probes, and all opcodes it uses exist since 5.6). See [Version gating](#version-gating-and-the-no-fallback-stance).

---

## Overview

### What it solves

Most async runtimes (notably [Tokio][tokio]) are _work-stealing_: a small pool of OS threads share a global (or sharded-but-stealable) run queue, and a future spawned on one thread may be resumed on another. That model maximizes core utilization for heterogeneous workloads, but it forces every shared data structure to be `Send + Sync`, pushes atomics and locks onto the hot path, and pays cache-coherency and context-switch costs whenever a task migrates.

Glommio takes the opposite position, borrowed wholesale from [Seastar]: **one executor per CPU, pinned to that CPU, owning all of its own state.** Tasks never migrate. There is exactly one task running per thread at any instant, so within a thread there is no preemption, no data races, and therefore no need for locks or atomics on the common path. Cross-core communication happens explicitly through message-passing channels rather than shared mutable memory. This is the _share-nothing_ architecture that powers ScyllaDB and Redpanda, made available to Rust's `async`/`.await`.

The second pillar is **`io_uring` as the only I/O substrate.** Rather than wrap epoll (a _readiness_ / reactor interface) Glommio submits the actual operation — read, write, accept, connect, fsync, openat, statx — into a kernel-shared submission ring and harvests the result from a completion ring. This is a _Proactor_ (completion-based) design. It additionally exploits `io_uring`'s registered-buffer and `IOPOLL` features to drive `O_DIRECT` NVMe traffic without interrupts. For the broader context of why `io_uring` enables this, see [the io_uring deep-dive][io-uring].

### Design philosophy

From the crate root documentation ([`glommio/src/lib.rs`][lib]):

> _"Cooperative Thread-per-core is a very specific programming model. Because only one task is executing per thread, the programmer never needs any locking to be held. Atomic operations are therefore rare, delegated to only a handful of corner case tasks. … context switches are virtually non-existent (they only occur for kernel threads and interrupts) and no time is ever wasted in waiting on locks."_

Three consequences follow, and they shape the entire API:

1. **No `Send` requirement.** Futures spawned via `spawn_local` need not be `Send`; the `LocalExecutor` and its `Task` types live entirely on one thread. This is a sharp contrast to Tokio's `tokio::spawn`.
2. **Cooperative scheduling is the user's responsibility.** Because a task runs until it `.await`s or explicitly yields, long CPU loops must periodically call `yield_if_needed()`/`need_preempt()` or they will starve latency-sensitive peers. The runtime backstops this with a _preemption timer_ (below) but cannot interrupt a tight non-awaiting loop.
3. **Direct I/O is a first-class citizen.** The file APIs are built around `O_DIRECT` and aligned `DmaBuffer`s, on the thesis (from the linked Datadog/ScyllaDB articles) that _"modern storage is plenty fast; it is the APIs that are bad."_

Glommio sits in the same conceptual family as [Seastar], the [Eio][eio] effects runtime on Linux, and the Rust siblings [Glommio-vs-Tokio][tokio] / [Monoio][monoio]. Within the async-I/O survey it is the canonical _Rust thread-per-core + `io_uring`_ data point; compare it against [Monoio][monoio] (also thread-per-core `io_uring`, but with a pluggable epoll fallback) and the [overall comparison][comparison].

---

## Core abstractions and types

| Concept              | Type / function                                       | Role                                                                      |
| -------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------- |
| Per-CPU executor     | `LocalExecutor`                                       | The single-threaded scheduler + reactor that owns one CPU                 |
| Executor builder     | `LocalExecutorBuilder`                                | Configures placement, preempt timer, ring depth, spin-before-park         |
| Pool of executors    | `LocalExecutorPoolBuilder` → `PoolThreadHandles<T>`   | Spawns N executors (one per shard), each on its own pinned thread         |
| CPU placement policy | `Placement` / `PoolPlacement`                         | `Unbound`, `Fenced`, `Fixed`, `MaxSpread`, `MaxPack`, `Custom`            |
| Spawned task         | `Task<T>` / `ScopedTask<'a, T>`                       | A handle to a local future; `spawn_local`, `spawn_local_into`             |
| Scheduling group     | `TaskQueue` (internal) + `TaskQueueHandle`            | A weighted run queue; `executor().create_task_queue(...)`                 |
| Scheduling weight    | `Shares` (`Static` / `Dynamic`) + `SharesManager`     | Proportional CPU sharing between task queues                              |
| Latency class        | `Latency::{Matters(Duration), NotImportant}`          | Whether a queue's tasks demand low-latency preemption                     |
| Dynamic controller   | `DeadlineQueue<T>` + `DeadlineSource`                 | PID-style controller that auto-adjusts shares to hit a deadline           |
| I/O registration     | `Source` / `InnerSource` / `SourceType`               | Ties one in-flight SQE to its waker(s); see [How it works](#how-it-works) |
| The reactor          | `Reactor` (`sys::uring::Reactor`)                     | Owns the three `io_uring` instances and the sleep/wake machinery          |
| DMA buffer           | `DmaBuffer`                                           | 4096-aligned buffer suitable for `O_DIRECT` and registered-buffer I/O     |
| File handles         | `DmaFile`, `BufferedFile`, `OpenOptions`, `Directory` | Direct and buffered file I/O                                              |
| Network handles      | `TcpStream`, `TcpListener`, `UdpSocket`, `UnixStream` | Socket I/O routed through the latency/main rings                          |

### Entry point

A Glommio program starts by building one executor per core. The simplest single-executor form, from [`glommio/src/lib.rs`][lib]:

```rust
// glommio/src/lib.rs (doc example)
use glommio::{LocalExecutorBuilder, Placement};

LocalExecutorBuilder::new(Placement::Fixed(0)) // pin to CPU 0; never migrates
    .spawn(|| async move {
        // your code here
    })
    .unwrap();
```

`Placement::Fixed(0)` binds the spawned OS thread to CPU 0 via `sched_setaffinity` (see `bind_to_cpu_set` in [`executor/mod.rs`][executor]). Because there is _"only one executor per thread,"_ scaling out means creating more threads — which is what `LocalExecutorPoolBuilder` automates.

### Placement on CPUs

`PoolPlacement` ([`executor/placement/mod.rs`][placement]) materializes the machine topology (read from `/sys/devices/system/cpu/...`, see [`hardware_topology.rs`][topo]) into a concrete CPU assignment per shard:

| Variant                        | Meaning                                                                                                            |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `Unbound(n)`                   | `n` executors, not pinned to any CPU (OS scheduler is free to move them)                                           |
| `Fenced(n, CpuSet)`            | `n` executors restricted to a CPU set, but not individually pinned                                                 |
| `MaxSpread(n, Option<CpuSet>)` | `n` executors pinned to CPUs chosen for **maximal** topological separation (different NUMA nodes / packages first) |
| `MaxPack(n, Option<CpuSet>)`   | `n` executors pinned for **minimal** separation (fill a core's hyperthreads / a socket first)                      |
| `Custom(Vec<CpuSet>)`          | Explicit per-shard CPU set                                                                                         |

`MaxSpread` and `MaxPack` are driven by a _priority queue tree_ (`pq_tree.rs`) over the discovered `CpuLocation { cpu, core, package, numa_node }` records. `hardware_topology.rs` notably assigns a stable "virtual core id" by sorting `(numa_node, core)` so that hyperthread siblings share a core id and placement is deterministic across runs. The single-executor `Placement` enum is a thin projection onto `PoolPlacement` (`Placement::Fixed(cpu)` becomes `PoolPlacement::Custom(vec![one_cpu_set])`).

---

## How it works

### The run loop: scheduler ⟂ reactor

Each `LocalExecutor::run` ([`executor/mod.rs`][executor]) drives a loop that interleaves _running user tasks_ with _pumping the reactor_. Simplified from the source:

```rust
// glommio/src/executor/mod.rs — LocalExecutor::run (abridged)
loop {
    if let Poll::Ready(t) = future.as_mut().poll(cx) { break t.unwrap(); }

    // 1. Pump I/O first, so latency-sensitive completions are visible
    //    before we pick a task queue. Also (re)arms the preemption timer.
    this.parker.poll_io(|| Some(this.preempt_timer_duration()))?;

    // 2. Run user code: pick the lowest-vruntime active task queue and
    //    run its tasks until need_preempt() or the queue yields.
    let ran = this.run_task_queues();

    // 3. Nothing ran? spin briefly, then park (sleep) on io_uring.
    if !ran {
        while !this.reactor.spin_poll_io().unwrap() {
            if pre_time.elapsed() > spin_before_park { this.parker.park()?; break; }
        }
    }
}
```

`run_task_queues` repeatedly calls `run_one_task_queue` until `need_preempt()` flips. `run_one_task_queue` pops the task queue with the smallest _virtual runtime_ from a `BinaryHeap<Rc<RefCell<TaskQueue>>>` (a min-heap by `vruntime`), runs as many of its tasks as it can, then accounts the elapsed time back into that queue's `vruntime` before reinserting it.

### Cooperative scheduling: vruntime, shares, latency

Glommio's fair scheduler is a CFS-style weighted virtual clock ([`executor/mod.rs`][executor], [`shares.rs`][shares]):

- Each `TaskQueue` carries a `vruntime: u64`. After running for a real `Duration delta`, the queue's vruntime advances by `delta` scaled by its **reciprocal shares**:

  ```rust
  // glommio/src/executor/mod.rs — TaskQueue::account_vruntime
  let delta_scaled = (self.stats.reciprocal_shares * (delta.as_nanos() as u64)) >> 12;
  ```

- `reciprocal_shares` is `(1 << 22) / shares` ([`shares.rs`][shares]), with `shares` clamped to `[1, 1000]` and defaulting to `1000`. A queue with **more** shares has **smaller** reciprocal shares, so its vruntime grows **slower**, so it is selected **more often** — yielding proportional CPU sharing. Two equal-share queues each get 50%; add a third and each gets 33%.
- `Shares::Static(n)` never changes; `Shares::Dynamic(Rc<dyn SharesManager>)` is recomputed every `adjustment_period()` (default 250 ms), the basis for [controllers](#controllers).

**Preemption** is two-tier. There is no signal-based preemption — a task that never `.await`s cannot be interrupted. Instead:

1. **Latency ring timer.** Before picking a task queue, the reactor arms a _preemption timer_ in the latency ring sized to the _minimum_ latency requirement among active queues (`reevaluate_preempt_timer` walks `Latency::Matters(d)` vs `Latency::NotImportant`). When it fires, the latency ring's completion makes `need_preempt()` return `true`, ending the current queue's run.
2. **Cooperative `yield_if_needed()`.** Long loops should call `glommio::executor().need_preempt()` or `await yield_if_needed()`; the latter cheaply checks the latency ring and yields the task if preemption is pending. The crate docs explicitly recommend calling it _"after x iterations of the loop."_

### Source: tying an in-flight SQE to a waker

The bridge between Rust's `Future`/`Waker` world and the kernel ring is the `Source` ([`sys/source.rs`][source]). Its lifecycle:

1. An I/O method (e.g. `DmaFile::read_at`) constructs a `Source::new(io_requirements, raw_fd, SourceType::…, stats, task_queue)`. `SourceType` is a tagged union of every operation Glommio knows — `Read`, `Write`, `SockSend`, `SockRecv`, `Connect`, `Accept`, `Open`, `Statx`, `Timeout`, `Close`, `Fallocate`, etc. — and it _owns the buffers_ for the duration of the operation (critical for completion-based I/O: the kernel writes into memory the `Source` keeps alive).

   ```rust
   // glommio/src/sys/source.rs
   pub(crate) struct InnerSource {
       pub(crate) raw: RawFd,
       pub(crate) wakers: Wakers,           // tasks parked on this op
       pub(crate) source_type: SourceType,  // owns the buffer(s)
       pub(crate) io_requirements: IoRequirements,
       pub(crate) timeout: Option<TimeSpec64>,
       pub(crate) enqueued: Option<EnqueuedSource>,
       // ...
   }
   ```

2. The reactor enqueues a `UringDescriptor` and registers the source in a `SourceMap` (a `FreeList`), obtaining a `SourceId`. The `SourceId` is encoded into the SQE's `user_data` field (`to_user_data` = `id + 1`, reserving `0` for fire-and-forget ops like `POLL_REMOVE`/`CANCEL`).

3. The future for that op (`Source::collect_rw` → `poll_collect_rw`) is polled. If the result isn't ready it stores the task's `Waker` (`add_waiter_single` for 1:1 ops, `add_waiter_many` for shared streams) and returns `Poll::Pending`.

4. When a CQE arrives, `process_one_event` ([`sys/uring.rs`][uring]) reads `cqe.user_data()`, looks the `InnerSource` back up via `consume_source`, writes the result into `inner.wakers.result`, and calls `wake_waiters()` — re-scheduling every parked task.

   ```rust
   // glommio/src/sys/uring.rs — process_one_event (abridged)
   let src = source_map.borrow_mut().consume_source(from_user_data(value.user_data()));
   let res = Some(post_process(src.borrow_mut(), transmute_error(value.result())));
   src.borrow_mut().wakers.result = res;
   let woke = src.borrow_mut().wakers.wake_waiters();
   ```

5. **Cancellation is buffer-safe.** Dropping a `Source` whose op is still in the kernel does _not_ free the buffer; `Source::drop` sees `EnqueuedStatus::Dispatched`, issues a `cancel_request`, and defers reclaiming the source until the matching CQE is reaped — because _"the kernel might be using the buffers right now."_ Only an op that was enqueued-but-not-yet-submitted (`Enqueued`) can be dropped immediately. This is the completion-model discipline that epoll-based runtimes don't need.

### Driving three rings: main, latency, poll

The headline feature — and the reason `sys/uring.rs` is the heart of the crate — is that **each executor registers three independent `io_uring` instances** ([`sys/uring.rs`][uring], `Reactor` struct):

```rust
// glommio/src/sys/uring.rs
pub(crate) struct Reactor {
    main_ring: RefCell<SleepableRing>,
    latency_ring: RefCell<SleepableRing>,
    poll_ring: RefCell<PollRing>,
    // ...
    link_fd: RawFd,             // latency_ring's fd, polled by main_ring on sleep
    eventfd_src: Source,        // cross-executor wakeups
}
```

| Ring        | Type            | `io_uring` setup                         | Carries                                                                                                    |
| ----------- | --------------- | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **Main**    | `SleepableRing` | `IoUring::new(depth)` (interrupt-driven) | The default destination for almost everything: file metadata, buffered I/O, timeouts, opens, closes, sends |
| **Latency** | `SleepableRing` | `IoUring::new(depth)`                    | Latency-critical ops: socket **recv**, **accept**, **connect**, and the preemption/timer SQEs              |
| **Poll**    | `PollRing`      | `IoUring::new_with_flags(depth, IOPOLL)` | `O_DIRECT` NVMe reads/writes on devices that support polled completion                                     |

Routing is decided by `Reactor::ring_for_source` ([`sys/uring.rs`][uring]):

```rust
// glommio/src/sys/uring.rs — ring_for_source (abridged)
match &*source.source_type() {
    Read(p, _) | Write(p, _) => match p {
        PollableStatus::Pollable          => self.poll_ring.borrow_mut(),  // NVMe IOPOLL
        PollableStatus::NonPollable(_)    => self.main_ring.borrow_mut(),  // buffered / non-pollable disk
    },
    SockRecv(_) | SockRecvMsg(..) | Accept(_) | Connect(_) => self.latency_ring.borrow_mut(),
    _ => self.main_ring.borrow_mut(),
}
```

The rationale (verbatim from the source) is that _"we avoid putting requests that come in high numbers on the latency ring because the more requests we issue there, the less effective it becomes."_ The latency ring stays sparse so its completions reliably trigger fast preemption.

**Sharing the run/wake fabric across three rings** is the subtle part. The two `SleepableRing`s and the `PollRing` all implement a common `UringCommon` trait (`submit_one_event`, `consume_one_event`, `submission_queue`, `needs_kernel_enter`, `can_sleep`, …), letting the reactor pump them uniformly with the `consume_rings!` / `flush_rings!` / `flush_cancellations!` macros.

Going to sleep is where the three rings are _linked_. The poll ring **cannot** sleep — `IOPOLL` requires the application to keep entering the kernel (`needs_kernel_enter` returns true whenever there are in-flight or unsubmitted SQEs). So the executor only parks when **all three** report `can_sleep()`. To park, `link_rings_and_sleep` ([`sys/uring.rs`][uring]) issues a `POLL_ADD` on the latency ring's _file descriptor_ into the **main** ring, then blocks in `cq().wait(1)` on the main ring:

```rust
// glommio/src/sys/uring.rs — SleepableRing::sleep (abridged)
// Add a POLL_ADD(link.raw = latency_ring fd) into the main ring, then:
self.ring.cq().wait(1) // block until ANY completion shows up
```

Because the latency ring's fd is now being polled by the main ring, _any_ event the latency ring sees (a network packet, a fired timer) also wakes the main ring — so the executor wakes promptly for latency work even though it slept on the main ring. A separate `eventfd` (the `notifier`) is registered in the latency ring so that a _remote_ executor can wake this one across cores. Before truly sleeping the reactor issues a `sys_membarrier(MEMBARRIER_CMD_PRIVATE_EXPEDITED)` (`membarrier::heavy()`) — the [Seastar memory-barrier trick][membarrier-blog] — and re-sweeps remote channels, bailing out of sleep if a cross-core message arrived in the meantime.

### Preemption timers: latency vs throughput

`SleepableRing` prepares **two** kinds of timer SQE ([`sys/uring.rs`][uring]):

- **`prepare_latency_preemption_timer(d)`** pushes a `TIMEOUT` to the _front_ of the latency ring's submission queue so it fires first on the next ring entry — the periodic "take this task queue off the CPU" tick. It is _not_ armed when the executor is going to sleep with no runnable work (no point burning power).
- **`prepare_throughput_preemption_timer(min_events, eventfd)`** registers a `TIMEOUT` with `min_events = ring_depth` and **`IO_LINK`**s it to a write to the latency ring's eventfd. This timer "fires" only once `ring_depth` completions have accrued on the main ring, at which point the linked eventfd write flares the latency ring and forces a scheduler turn — bounding how long a throughput-bound queue monopolizes the CPU while in-flight I/O piles up.

### `io_uring` opcodes used, and version gating

Glommio enumerates exactly the opcodes it depends on in a static list (`GLOMMIO_URING_OPS`, [`sys/uring.rs`][uring]):

| Opcode (from `GLOMMIO_URING_OPS`)                | Used for                                              |
| ------------------------------------------------ | ----------------------------------------------------- |
| `IORING_OP_NOP`                                  | probing / benchmarks                                  |
| `IORING_OP_READV` / `IORING_OP_WRITEV`           | vectored I/O                                          |
| `IORING_OP_READ` / `IORING_OP_WRITE`             | plain buffered read/write                             |
| `IORING_OP_READ_FIXED` / `IORING_OP_WRITE_FIXED` | **registered-buffer** DMA read/write (see below)      |
| `IORING_OP_FSYNC`                                | `fdatasync`/`fsync`                                   |
| `IORING_OP_POLL_ADD` / `IORING_OP_POLL_REMOVE`   | readiness poll (ring-linking; socket "yolo" fallback) |
| `IORING_OP_SENDMSG` / `IORING_OP_RECVMSG`        | datagram / vectored socket I/O                        |
| `IORING_OP_SEND` / `IORING_OP_RECV`              | stream socket I/O                                     |
| `IORING_OP_TIMEOUT` / `IORING_OP_TIMEOUT_REMOVE` | preemption + user timers                              |
| `IORING_OP_LINK_TIMEOUT`                         | per-op timeouts on linked SQEs                        |
| `IORING_OP_ACCEPT` / `IORING_OP_CONNECT`         | socket setup                                          |
| `IORING_OP_OPENAT` / `IORING_OP_CLOSE`           | file open / close                                     |
| `IORING_OP_FALLOCATE`                            | preallocation / truncate                              |
| `IORING_OP_STATX`                                | file metadata                                         |

#### Version gating and the no-fallback stance

At first ring construction, the lazily-evaluated `IO_URING_RECENT_ENOUGH` calls `check_supported_operations(GLOMMIO_URING_OPS)`. It obtains an `io_uring` _probe_ (`io_uring_get_probe`) and tests each opcode with `io_uring_opcode_supported`. If the probe is null or any opcode is missing it prints one of the crate's trademark error messages — _"Yo kernel is so old it was with Hannibal when he crossed the Alps!"_ — and calls `std::process::exit(1)`. Strictly speaking, this run-time check only requires probe support plus the listed opcodes, all of which became available by **Linux 5.6** (the probe interface, `IORING_REGISTER_PROBE`, also landed in 5.6, and the newest opcodes Glommio uses — `STATX`, `READ`/`WRITE`, `SEND`/`RECV`, `OPENAT`, `CLOSE`, `FALLOCATE` — all arrived in 5.6 as well). The **kernel 5.8 minimum** is the crate's own stated/recommended floor (its docs say it requires a kernel "at least recent enough to run discovery probes … The minimum version at this time is 5.8"); there is no explicit 5.8 version check in the code beyond opcode probing, so a 5.6/5.7 kernel that exposes every probed opcode would in practice pass.

There is **no fallback path.** Unlike [Monoio][monoio] (which ships an epoll legacy driver) or [Eio][eio] (which selects `eio_posix` on non-Linux), Glommio is Linux-and-`io_uring`-only by design. If the kernel is too old, the process exits. This is a deliberate trade — the absence of a fallback keeps the hot path free of readiness/completion branching and lets the runtime assume completion semantics everywhere. The crate additionally requires at least **512 KiB of locked memory** (`RLIMIT_MEMLOCK`) for the rings, checked in `Reactor::new` against `MIN_MEMLOCK_LIMIT`.

### Registered buffers and O_DIRECT DMA I/O

To minimize per-op overhead, the reactor allocates one large 4096-aligned slab (`UringBufferAllocator`, default **10 MiB** via `LocalExecutorBuilder`'s `DEFAULT_IO_MEMORY = 10 << 20`, floored at 64 KiB and page-aligned in `Reactor::new`) and **registers it with all three rings** at startup via `Registrar::register_buffers_by_ref` ([`sys/uring.rs`][uring], `Reactor::new`). On success it calls `activate_registered_buffers(0)`, tagging the allocator with `io_uring` buffer index 0. Sub-allocations from this slab (`UringBufferAllocator::new_buffer`, backed by a buddy allocator) become `DmaBuffer`s whose storage is `BufferStorage::Uring`, carrying the registered `uring_buffer_id`.

When such a buffer is written, `Reactor::write_dma` selects `WriteFixed` (→ `IORING_OP_WRITE_FIXED`) instead of `Write`, and reads use `ReadFixed`. Registered-buffer ("fixed") ops let the kernel skip per-call page pinning/unpinning:

```rust
// glommio/src/sys/uring.rs — Reactor::write_dma (abridged)
SourceType::Write(_, IoBuffer::DmaSource(buf)) => match buf.uring_buffer_id() {
    Some(id) => UringOpDescriptor::WriteFixed(buf.as_ptr(), buf.len(), pos, id), // fixed/registered
    None     => UringOpDescriptor::Write(buf.as_ptr(), buf.len(), pos),          // plain
},
```

The `DmaBuffer` itself ([`sys/dma_buffer.rs`][dma]) enforces the `O_DIRECT` alignment contract: its backing `SysAlloc` (the non-registered fallback) and the registered slab are both `Layout::from_size_align(size, 4096)`. `trim_to_size` lets a read shrink the addressable region while preserving alignment. `DmaFile` (`io/dma_file.rs`) opens files with `O_DIRECT`; the `PollableStatus` of a `Read`/`Write` source decides whether the op goes to the poll ring (NVMe with `IOPOLL`) or the main ring.

### Networking and the "yolo" fast path

Stream and datagram sockets (`net::{TcpStream, TcpListener, UdpSocket, UnixStream}`) route their `recv`/`accept`/`connect` through the **latency** ring (per `ring_for_source`) and `send` through the **main** ring. Before going to the ring, the networking layer tries an optimistic non-blocking syscall first — the `yolo_accept`/`yolo_send`/`yolo_recv`/`yolo_peek` helpers in [`net/mod.rs`][netmod] flip the fd to `O_NONBLOCK`, attempt the syscall, and only fall back to submitting an `io_uring` op (and parking) on `EWOULDBLOCK`. For sockets that are usually ready this avoids a full ring round-trip entirely.

---

## Performance approach

| Technique                       | Mechanism in Glommio                                                                              |
| ------------------------------- | ------------------------------------------------------------------------------------------------- |
| No cross-core synchronization   | Share-nothing; `spawn_local` futures are `!Send`; per-CPU `Rc`/`RefCell` instead of `Arc`/`Mutex` |
| No task migration               | Each `LocalExecutor` pinned to a CPU; tasks complete on the thread that started them              |
| Completion-based I/O            | `io_uring` Proactor — submit the op, not a readiness wait; batch many SQEs per `submit_sqes()`    |
| Registered buffers              | One 4096-aligned slab registered with all rings → `READ_FIXED`/`WRITE_FIXED` skip page pinning    |
| `O_DIRECT` + `IOPOLL` poll ring | NVMe reads/writes bypass the page cache and complete without interrupts at high IOPS              |
| Optimistic syscall fast path    | "yolo" non-blocking `recv`/`send`/`accept` before falling back to the ring                        |
| Spin-before-park                | `spin_before_park` busy-polls the rings briefly before issuing the blocking `cq().wait(1)`        |
| Bounded latency under load      | Throughput preemption timer linked to an eventfd write forces fair scheduling turns               |
| Cheap wakeups                   | Wakers stored on the owning `Source`; CQE `user_data` indexes a `FreeList` for O(1) lookup        |

The cumulative effect is that on a saturated single core, an idle steady state submits a batch of SQEs, sleeps once on the main ring, and wakes once per batch of completions — approaching one syscall per _N_ I/O operations rather than per operation.

## Strengths

- **True share-nothing thread-per-core**: no locks/atomics on the hot path, no task migration, predictable cache behavior — ideal for sharded storage/proxy/database workloads.
- **`io_uring`-native end to end**: file, socket, timer, and metadata ops are all real `io_uring` submissions, not an epoll emulation.
- **First-class Direct I/O**: aligned `DmaBuffer`s, `O_DIRECT` `DmaFile`, and an NVMe poll ring make it well-suited to storage engines.
- **Rich, principled scheduling**: weighted `Shares` (static and dynamic), `Latency` classes, and PID-style `DeadlineQueue` controllers give fine-grained, theory-grounded control over CPU allocation.
- **Topology-aware placement**: `MaxSpread`/`MaxPack` understand NUMA nodes, packages, cores, and hyperthread siblings.
- **`!Send` futures allowed**: no `Send + Sync + 'static` straitjacket for per-shard state.

## Weaknesses

- **Linux-only, `io_uring`-only, with a stated kernel floor of 5.8 (effectively ~5.6 once opcode probing is satisfied) and `process::exit(1)` if the probe fails** — no portability and no graceful degradation.
- **No work stealing**: an imbalanced shard sits idle while another is overloaded; load balancing is the application's problem (explicit sharding + message passing).
- **Cooperative scheduling foot-guns**: a CPU-bound loop that forgets `yield_if_needed()` starves the whole core's latency-sensitive tasks; the runtime cannot forcibly preempt non-awaiting code.
- **`RLIMIT_MEMLOCK ≥ 512 KiB` requirement** is an operational gotcha (containers default lower).
- **Smaller ecosystem** than [Tokio][tokio]; many `Send`-assuming libraries are incompatible with `spawn_local` futures.
- **Cross-core communication is explicit and manual** (channels), which is more code than shared-state runtimes for some workloads.
- **Historically self-described as alpha / early-stage** and maintained by a relatively small team (later releases dropped the explicit "alpha" wording, but the project remains comparatively niche).

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                             | Trade-off                                                                                     |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Thread-per-core, share-nothing (vs. work-stealing)       | Eliminates locks/atomics and task migration; deterministic per-core performance       | No automatic load balancing; imbalanced shards waste cores; needs explicit message passing    |
| `io_uring`-only, no epoll/kqueue fallback                | Keeps the hot path branch-free with uniform completion semantics; full Proactor power | Linux-only; stated 5.8 floor (probe-enforced ~5.6); `process::exit(1)` on too-old kernels     |
| Three rings per CPU (main / latency / poll)              | Isolate sparse latency-critical ops from bulk traffic; poll NVMe without interrupts   | More rings to pump and link; sleep requires the ring-linking `POLL_ADD` dance                 |
| Completion model with `Source`-owned buffers             | Kernel can write into long-lived buffers safely; enables registered-buffer fixed I/O  | Cancellation must defer buffer reclaim until the CQE arrives; more careful lifetime mgmt      |
| CFS-style `vruntime` + `Shares` (1..1000, default 1000)  | Proportional, work-conserving CPU sharing without hard priorities                     | Percentages depend on the _currently active_ set of queues; harder to reason about absolutely |
| Timer-based preemption + cooperative `yield_if_needed`   | No signals; cheap latency-ring tick bounds queue residency                            | A non-awaiting tight loop is uninterruptible and starves peers                                |
| Registered single slab + buddy allocator for `DmaBuffer` | `READ_FIXED`/`WRITE_FIXED` avoid per-op page pinning; 4096 alignment for `O_DIRECT`   | Fixed-size pre-registered memory; allocations beyond the slab fall back to plain ops          |
| Optimistic non-blocking syscall ("yolo") before ring     | Skips a ring round-trip for already-ready sockets                                     | Extra `fcntl` toggles; only helps when the fd is usually ready                                |

---

## Sources

- [DataDog/glommio — GitHub repository][repo]
- [glommio on docs.rs (0.9.0)][docs]
- [glommio on crates.io][crate]
- [`glommio/src/lib.rs` — crate root docs (rings, kernel 5.8, Seastar)][lib]
- [`glommio/src/sys/uring.rs` — three-ring reactor, opcodes, sleep/wake][uring]
- [`glommio/src/sys/source.rs` — `Source`/`InnerSource`, waker binding, cancellation][source]
- [`glommio/src/sys/dma_buffer.rs` — aligned DMA buffers][dma]
- [`glommio/src/sys/hardware_topology.rs` — CPU topology discovery][topo]
- [`glommio/src/executor/mod.rs` — `LocalExecutor`, vruntime scheduler][executor]
- [`glommio/src/executor/placement/mod.rs` — `Placement`/`PoolPlacement`][placement]
- [`glommio/src/shares.rs` — `Shares` / reciprocal-shares math][shares]
- [`glommio/src/net/mod.rs` — "yolo" non-blocking fast path][netmod]
- [Introducing Glommio (Datadog Engineering blog, Glauber Costa)][blog]
- [Memory barriers in Seastar / Linux (ScyllaDB)][membarrier-blog]
- [Seastar framework][Seastar]
- [Related: Tokio (Rust)][tokio] · [Monoio (Rust)][monoio] · [io_uring deep-dive][io-uring] · [Comparison][comparison] · [Eio (OCaml)][eio]

<!-- References -->

[repo]: https://github.com/DataDog/glommio
[docs]: https://docs.rs/glommio/latest/glommio/
[crate]: https://crates.io/crates/glommio
[lib]: https://github.com/DataDog/glommio/blob/8434815962ce0bc161ace1967137213dc2334e4b/glommio/src/lib.rs
[uring]: https://github.com/DataDog/glommio/blob/8434815962ce0bc161ace1967137213dc2334e4b/glommio/src/sys/uring.rs
[source]: https://github.com/DataDog/glommio/blob/8434815962ce0bc161ace1967137213dc2334e4b/glommio/src/sys/source.rs
[dma]: https://github.com/DataDog/glommio/blob/8434815962ce0bc161ace1967137213dc2334e4b/glommio/src/sys/dma_buffer.rs
[topo]: https://github.com/DataDog/glommio/blob/8434815962ce0bc161ace1967137213dc2334e4b/glommio/src/sys/hardware_topology.rs
[executor]: https://github.com/DataDog/glommio/blob/8434815962ce0bc161ace1967137213dc2334e4b/glommio/src/executor/mod.rs
[placement]: https://github.com/DataDog/glommio/blob/8434815962ce0bc161ace1967137213dc2334e4b/glommio/src/executor/placement/mod.rs
[shares]: https://github.com/DataDog/glommio/blob/8434815962ce0bc161ace1967137213dc2334e4b/glommio/src/shares.rs
[netmod]: https://github.com/DataDog/glommio/blob/8434815962ce0bc161ace1967137213dc2334e4b/glommio/src/net/mod.rs
[blog]: https://www.datadoghq.com/blog/engineering/introducing-glommio/
[membarrier-blog]: https://www.scylladb.com/2018/02/15/memory-barriers-seastar-linux/
[Seastar]: https://seastar.io/
[tokio]: ./tokio.md
[monoio]: ./monoio.md
[io-uring]: ./io-uring/index.md
[comparison]: ./comparison.md
[eio]: ../algebraic-effects/ocaml-eio.md
