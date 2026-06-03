# Seastar (C++)

A thread-per-core, share-nothing C++ framework for I/O-intensive servers: one reactor pinned per core, no shared mutable state, explicit lock-free message passing between shards, and a future/promise/continuation concurrency model over pluggable kernel backends (linux-aio, epoll, `io_uring`).

| Field         | Value                                                                                           |
| ------------- | ----------------------------------------------------------------------------------------------- |
| Language      | C++ (C++23 in current master)                                                                   |
| License       | Apache License 2.0                                                                              |
| Repository    | [Seastar GitHub Repository]                                                                     |
| Documentation | [Seastar Tutorial] / [Seastar API Reference]                                                    |
| Key Authors   | Avi Kivity, Nadav Har'El, Gleb Natapov, Kefu Chai (ScyllaDB / Cloudius Systems)                 |
| Pattern       | Thread-per-core, share-nothing reactor + future/promise continuations                           |
| Encoding      | Pluggable kernel backend: Reactor (epoll) + Proactor (linux-aio, `io_uring`); userspace polling |

---

## Overview

### What It Solves

Modern servers are bottlenecked not by raw single-core throughput but by **coordination between cores**: cache-line bouncing, lock contention, atomic ref-count traffic, and cross-NUMA memory access. A traditional thread-pool design hands a connection to whatever thread is free, then leans on locks and shared data structures to keep state consistent. As core counts climb, the locking and coherency overhead grows faster than the useful work.

Seastar attacks this by removing sharing entirely. It runs **exactly one thread per CPU core** (called a _shard_), each pinned to its core, each owning a private slice of RAM and its own copy of every data structure. Cores never block on each other and never take locks against shared state; when one core genuinely needs to talk to another, it sends an explicit message over a lock-free queue. This is the _share-nothing_ architecture that powers [ScyllaDB] and Redpanda, and that directly inspired the modern thread-per-core movement — including [Glommio](./glommio.md), [Monoio](./monoio.md), and the design discussions behind several other runtimes (see the [comparison](./comparison.md)).

### Design Philosophy

The [Seastar shared-nothing design][Shared-nothing Design] rests on a few commitments:

1. **Share nothing across cores.** Memory is partitioned at startup into one region per shard (NUMA-aware). Data structures are not shared; the default allocator is per-core. There is no global lock because there is nothing global to lock.

2. **Never block the reactor.** The single thread on each core must never make a blocking syscall or take a contended lock — doing so stalls every connection on that core. All I/O is asynchronous, expressed as futures, and all CPU-bound work is broken into small cooperatively-scheduled tasks.

3. **Futures over threads.** Concurrency is expressed with `future`/`promise` and continuation chaining (`.then()`), not OS threads. A "task" runs only as long as it takes to consume one I/O completion and submit the next operation.

4. **Explicit, asynchronous cross-core communication.** When work must cross cores, `smp::submit_to(shard, lambda)` posts the work to the target shard's queue and returns a `future` for the result. Communication is visible in the code, not hidden behind a shared cache line.

5. **Pluggable kernel backends.** The way the reactor talks to the kernel is abstracted behind `reactor_backend`, so Seastar can use `linux-aio` (its original mechanism), `epoll` (the portable fallback), or `io_uring` (the modern proactor) without changing user code. See [io_uring overview](./io-uring/index.md).

For the broader picture of why event loops and thread-per-core matter, and how this relates to algebraic-effects runtimes like [OCaml Eio](../algebraic-effects/ocaml-eio.md), see [effects and event loops](./effects-and-event-loops.md).

---

## Core abstractions and types

### The reactor (the "engine")

Each shard runs a `reactor` — Seastar's event loop, colloquially the _engine_. Its main loop lives in `reactor::run()` (`src/core/reactor.cc`). The reactor owns:

- a cooperative task scheduler (`_cpu_sched`), which runs ready continuations;
- a set of _pollers_ (`_pollers`) that check for new work (I/O completions, cross-core messages, timers);
- a `reactor_backend` (`_backend`) that mediates all kernel interaction.

The reactor does not have a thread per connection; it has a thread per _core_, and multiplexes thousands of connections as futures over that one thread.

### `future` / `promise` / continuation

The fundamental concurrency type is `future<T>` (`include/seastar/core/future.hh`). The header describes it precisely:

```cpp
// include/seastar/core/future.hh
/// Futures and promises are the basic tools for asynchronous
/// programming in seastar.  A future represents a result that
/// may not have been computed yet ...
/// Another way to look at futures and promises are as the reader
/// and writer sides, respectively, of a single-item, single use
/// queue.  You read from the future, and write to the promise ...
```

A `future<T>` is the read side; a `promise<T>` is the write side. You compose asynchronous work by attaching **continuations** with `.then()`:

```cpp
// chaining continuations (conceptual; from the tutorial)
return read_from_disk(fname).then([] (sstring contents) {
    return parse(contents);
}).then([] (parsed p) {
    return store(p);
});
```

The header documents the lifecycle of a continuation (`include/seastar/core/future.hh`):

```cpp
// include/seastar/core/future.hh
/// If a future is consumed by future::then before the future is
/// ready, a continuation is dynamically allocated. The continuation
/// also has a future_state<T> ...
/// After a future creates a continuation, the corresponding promise
/// points to the newly allocated continuation. When
/// promise::set_value is called, the continuation is ready and is
/// scheduled.
```

The key performance insight: if a future is **already ready** when `.then()` is called, no continuation is allocated — the work runs inline. A continuation (a heap allocation, derived from `continuation_base : public task`) is created only when the result is genuinely not yet available. This keeps the common "fast path" allocation-free.

### `task` and the scheduler

Continuations are `task`s. The reactor's `task_queue_group::run_some_tasks()` (`src/core/reactor.cc`) drains ready tasks until a _task quota_ (time budget, default 0.5 ms) is exhausted, then yields back to the poll loop so I/O and timers get serviced. This cooperative quota is what keeps one greedy continuation from starving the rest of the shard.

### `smp` and `smp::submit_to` — cross-core message passing

The `smp` class (`include/seastar/core/smp.hh`) is the share-nothing communication layer. `smp::submit_to(shard, func)` runs `func` on a remote shard and returns a `future` for its result:

```cpp
// include/seastar/core/smp.hh
template <typename Func>
static futurize_t<std::invoke_result_t<Func>>
submit_to(unsigned t, smp_submit_to_options options, Func&& func) noexcept {
    using ret_type = std::invoke_result_t<Func>;
    if (t == this_shard_id()) {
        // local: just invoke directly, no message
        return futurize<ret_type>::invoke(std::forward<Func>(func));
    } else {
        // remote: post to the (t, this_shard_id()) message queue
        return _qs[t][this_shard_id()].submit(t, options, std::forward<Func>(func));
    }
}
```

`_qs[to][from]` is a matrix of `smp_message_queue` objects — **one queue per ordered pair of shards** — so there is no shared queue and no lock contention. Each queue is a lock-free single-producer/single-consumer structure; the producing shard enqueues, the consuming shard polls (`smp_message_queue::process_queue`) and posts the response back over the reverse-direction queue. This is the entire basis of share-nothing: cores never touch each other's memory directly, they pass typed work items.

### `reactor_backend` — the kernel-interaction interface

`reactor_backend` (`src/core/reactor_backend.hh`) is the abstract interface every backend implements. Its own comment states the design:

```cpp
// src/core/reactor_backend.hh
// The "reactor_backend" interface provides a method of waiting for various
// basic events on one thread. We have one implementation based on epoll and
// file-descriptors (reactor_backend_epoll), one implementation based on
// linux aio, and one implementation based on io_uring.
class reactor_backend {
    ...
    virtual bool reap_kernel_completions() = 0;   // harvest finished async work, never blocks
    virtual bool kernel_submit_work() = 0;        // push newly produced ops, never blocks
    virtual bool kernel_events_can_sleep() const = 0;
    virtual void wait_and_process_events(const sigset_t*) = 0; // may block when idle
    // plus readable/writeable/accept/connect/read/recvmsg/sendmsg/writev/...
};
```

The split between non-blocking `reap_kernel_completions()` / `kernel_submit_work()` (called every poll iteration) and the potentially-blocking `wait_and_process_events()` (called only when the shard has decided to sleep) is what lets Seastar offer both busy-polling and interrupt-driven modes over the same interface.

### I/O scheduler: `io_queue`, `priority_class`, `fair_queue`

Disk I/O does not go straight to the backend. It flows through a per-shard **I/O scheduler**: `io_queue` (`include/seastar/core/io_queue.hh`) dispatches requests fairly across `priority_class`es using a `fair_queue` (`include/seastar/core/fair_queue.hh`). Each `priority_class` is tied to a `scheduling_group`, so CPU scheduling and disk-bandwidth scheduling share the same notion of "class of work." This lets a Seastar app, for example, give compaction I/O a smaller share than user-facing query I/O — globally, across the modeled disk — without locks, by coordinating shard shares through a shared cost model.

---

## How it works

### The poll loop

`reactor::run()` is, at its heart, a loop that alternates between running tasks and polling for work (`src/core/reactor.cc`):

```cpp
// src/core/reactor.cc (reactor::run(), simplified)
while (true) {
    _cpu_sched.run_some_tasks();          // run ready continuations (up to task quota)
    if (_stopped) break;

    if (check_for_work()) {               // poll_once() || have_more_tasks()
        // there was work; loop again immediately (busy path)
    } else {
        // nothing to do: maybe go to sleep
        if (idle_end - idle_start > _cfg.max_poll_time) {
            if (pollers_enter_interrupt_mode()) {
                wait_and_process_events();    // <-- the only place we may block
                pollers_exit_interrupt_mode();
            }
        } else {
            internal::cpu_relax();            // spin a little longer first
        }
    }
}
```

`poll_once()` simply runs every registered poller:

```cpp
// src/core/reactor.cc
bool reactor::poll_once() {
    bool work = false;
    for (auto c : _pollers) {
        work |= c->poll();   // io completions, smp queues, timers, ...
    }
    return work;
}
```

`wait_and_process_events()` delegates to the active backend:

```cpp
// src/core/reactor.cc
void reactor::wait_and_process_events() {
    _backend->wait_and_process_events(&_active_sigmask);
}
```

### Polling vs interrupt mode (busy-poll)

This loop captures Seastar's two operating modes:

| Mode                | When                                                         | Behavior                                                                                                                |
| ------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| **Busy-poll**       | `--poll-mode` set, or while work keeps arriving              | The reactor never sleeps; it spins on `poll_once()` at ~100% CPU. Lowest latency.                                       |
| **Spin-then-sleep** | Default; controlled by `idle_poll_time_us` / `max_poll_time` | After `max_poll_time` of idleness, the reactor enters interrupt mode and blocks in the backend until an event wakes it. |

The transition is guarded by `pollers_enter_interrupt_mode()`, which gives every poller a chance to _veto_ sleeping (e.g. if a backend still has in-flight work it must spin on). `reactor_options` (`include/seastar/core/reactor_config.hh`) exposes the knobs: `poll_mode` ("Poll continuously (100% cpu use)"), `idle_poll_time_us` ("Reduce for overprovisioned environments or laptops"), and `poll_aio` ("Busy-poll for disk I/O. Reduces latency and increases throughput"). The `overprovisioned` option sets `idle_poll_time_us = 0` and disables thread affinity for laptops/containers.

### Backend selection

The active backend is chosen at startup by `reactor_backend_selector` (`src/core/reactor_backend.cc`). The default is the **first available** backend, in a fixed preference order:

```cpp
// src/core/reactor_backend.cc
reactor_backend_selector reactor_backend_selector::default_backend() {
    return available()[0];
}

std::vector<reactor_backend_selector> reactor_backend_selector::available() {
    std::vector<reactor_backend_selector> ret;
#ifdef SEASTAR_HAVE_URING
    if (detect_io_uring()) {
        ret.push_back(reactor_backend_selector("io_uring"));
    }
#endif
    if (has_enough_aio_nr() && detect_aio_poll()) {
        ret.push_back(reactor_backend_selector("linux-aio"));
    }
    ret.push_back(reactor_backend_selector("epoll"));
    return ret;
}
```

So the preference is **`io_uring` → linux-aio → epoll**, when each is compiled in and probes successfully. (The `reactor_options::reactor_backend` doc comment still reads "Default: linux-aio (if available)", but the code prefers `io_uring` when `SEASTAR_HAVE_URING` is defined and `detect_io_uring()` succeeds — `io_uring` was promoted to the default in October 2022 (the commit "reactor: make `io_uring` the default backend if available", per [What's new in Seastar][whats-new-in-seastar], building on the [seastar-dev patch series][seastar-dev io_uring backend]).) The user can always force a specific backend with `--reactor-backend=epoll|linux-aio|io_uring`.

`reactor_backend_selector::create()` simply maps the chosen name to a concrete class:

```cpp
// src/core/reactor_backend.cc
std::unique_ptr<reactor_backend> reactor_backend_selector::create(reactor& r) {
    if (_name == "io_uring") {
#ifdef SEASTAR_HAVE_URING
        return std::make_unique<reactor_backend_uring>(r);
#else
        throw std::runtime_error("io_uring backend not compiled in");
#endif
    }
    if (_name == "linux-aio") return std::make_unique<reactor_backend_aio>(r);
    else if (_name == "epoll") return std::make_unique<reactor_backend_epoll>(r);
    throw std::logic_error("bad reactor backend");
}
```

### Backend 1: `reactor_backend_aio` (linux-aio) — the original proactor

Seastar was built on the Linux AIO interface (`io_setup`/`io_submit`/`io_getevents`) from the start, because that was the only way in ~2014 to submit disk I/O asynchronously with `O_DIRECT` (DMA), which on Linux historically meant XFS (see [Avi Kivity, Qualifying Filesystems for Seastar]). `reactor_backend_aio` (`src/core/reactor_backend.cc`) builds the whole event loop on AIO control blocks (`iocb`):

- It keeps two AIO contexts: a `preempt_io_context` (for the task-quota timer tick and the high-resolution timer) and a `_polling_io` general context (for fd readiness polling). Even _socket readiness_ is expressed as an AIO `IOCB_CMD_POLL` operation rather than `epoll`.
- `kernel_submit_work()` flushes queued `iocb`s via `io_submit`; `reap_kernel_completions()` harvests results.

A notable optimization lives in `src/core/linux-aio.cc`: completions are reaped **directly from the mmap'd AIO ring in userspace**, skipping the `io_getevents` syscall entirely when possible:

```cpp
// src/core/linux-aio.cc
static int try_reap_events(aio_context_t io_context, long min_nr, long nr,
                           io_event* events, const ::timespec* timeout, bool force_syscall) {
    auto ring = to_ring(io_context);
    if (usable(ring) && !force_syscall) {
        // read completions straight from the kernel-shared ring,
        // using acquire/release on ring->head / ring->tail
        ...
    }
    return -1; // fall back to the io_getevents syscall
}
```

This userspace-ring reaping prefigures exactly what `io_uring` later standardized: a kernel-shared ring you can drain without a syscall. The `--force-aio-syscalls` option (`force_io_getevents_syscall`) disables it to make `strace` legible.

`reactor_backend_aio` reports `uses_blocking_io::no` and `supports_aio_fdatasync::yes`.

### Backend 2: `reactor_backend_epoll` — the portable reactor

`reactor_backend_epoll` (`src/core/reactor_backend.cc`) is the classic readiness-based fallback. It converts non-fd events into fds so they can all be waited on by `epoll_wait`: timers become `timerfd`, signals become `signalfd`, inter-thread wakeups become `eventfd`. Disk I/O still uses an `aio_storage_context` (AIO for storage), but readiness for sockets uses `epoll`. It also spins up a dedicated `_task_quota_timer_thread` to drive the preemption timer. This backend works on any Linux and is the safe choice in restricted environments (containers without enough `aio-max-nr`, kernels without `io_uring`).

### Backend 3: `reactor_backend_uring` — the modern proactor

`reactor_backend_uring` (`src/core/reactor_backend.cc`, guarded by `#ifdef SEASTAR_HAVE_URING`) maps Seastar's operations onto `io_uring`'s submission queue (SQ) and completion queue (CQ). It is selected only after a careful probe.

**Detection and version gating.** `detect_io_uring()` refuses `io_uring` on configurations where it would be slower or fragile:

```cpp
// src/core/reactor_backend.cc
static bool detect_io_uring() {
    if (!kernel_uname().whitelisted({"5.17"}) && have_md_devices()) {
        // Older kernels fall back to workqueues for RAID (md) devices
        return false;
    }
    if (!kernel_uname().whitelisted({"5.12"}) && mlock_limit() < (8 << 20)) {
        // Older kernels lock ~32k/vcpu for the ring; require 8MB locked memory
        return false;
    }
    auto ring_opt = try_create_uring(1, false);   // actually try to create a ring
    if (ring_opt) ::io_uring_queue_exit(&ring_opt.value());
    return bool(ring_opt);
}
```

So `io_uring` is gated on kernel **5.12** (locked-memory behavior) and **5.17** (RAID/md devices no longer fall back to kernel workqueues), plus a live creation probe.

**Feature and opcode probing.** `try_create_uring()` requires specific features and verifies each opcode is supported via `io_uring_get_probe_ring` before committing:

```cpp
// src/core/reactor_backend.cc
auto required_features = IORING_FEAT_SUBMIT_STABLE | IORING_FEAT_NODROP;
auto required_ops = {
    IORING_OP_POLL_ADD, // linux 5.1
    IORING_OP_READV, IORING_OP_WRITEV, IORING_OP_FSYNC,
    IORING_OP_SENDMSG,  // linux 5.3
    IORING_OP_RECVMSG, IORING_OP_ACCEPT, IORING_OP_CONNECT,
    IORING_OP_READ,     // linux 5.6
    IORING_OP_WRITE, IORING_OP_SEND, IORING_OP_RECV,
};
```

`IORING_FEAT_SUBMIT_STABLE` (the kernel consumes SQ entries on submit, so the app may reuse them immediately) and `IORING_FEAT_NODROP` (completions are essentially never dropped) both date to Linux **5.5**; the opcodes carry their own minimums as annotated. The ring is also `io_uring_ring_dontfork`'d so a `fork()` child doesn't share the mmap'd ring. See [io_uring features](./io-uring/features.md) and the [opcode reference](./io-uring/opcodes-reference.md).

**Submitting operations.** Each Seastar `io_request` is translated to the matching `io_uring_prep_*` helper into an SQE obtained from `get_sqe()`:

```cpp
// src/core/reactor_backend.cc (submit_io_request, abridged)
switch (req.opcode()) {
    case o::read:      ::io_uring_prep_read(sqe, op.fd, op.addr, op.size, op.pos); break;
    case o::write:     ::io_uring_prep_write(sqe, op.fd, op.addr, op.size, op.pos); break;
    case o::readv:     ::io_uring_prep_readv(sqe, op.fd, op.iovec, op.iov_len, op.pos); break;
    case o::writev:    ::io_uring_prep_writev(sqe, op.fd, op.iovec, op.iov_len, op.pos); break;
    case o::fdatasync: ::io_uring_prep_fsync(sqe, op.fd, IORING_FSYNC_DATASYNC); break;
    case o::recv:      ::io_uring_prep_recv(sqe, op.fd, op.addr, op.size, op.flags); break;
    case o::recvmsg:   ::io_uring_prep_recvmsg(sqe, op.fd, op.msghdr, op.flags); break;
    case o::send:      ::io_uring_prep_send(sqe, op.fd, op.addr, op.size, op.flags); break;
    case o::sendmsg:   ::io_uring_prep_sendmsg(sqe, op.fd, op.msghdr, op.flags); break;
    case o::accept:    ::io_uring_prep_accept(sqe, op.fd, op.sockaddr, op.socklen_ptr, op.flags); break;
    case o::connect:   ::io_uring_prep_connect(sqe, op.fd, op.sockaddr, op.socklen); break;
    case o::poll_add: case o::poll_remove: case o::cancel:
        // not yet generated by the reactor
        abort();
}
::io_uring_sqe_set_data(sqe, completion);  // attach the completion handler
```

The `kernel_completion*` stashed in `io_uring_sqe_set_data` is recovered from `cqe->user_data` when the completion is reaped — this is the proactor pattern: you submit an operation plus a callback, and you're called back with the _result_, not merely a readiness signal.

**SQE pressure handling.** `get_sqe()` is robust to a full submission ring: if `io_uring_get_sqe` returns null, it flushes pending submissions and drains completions to free space, then retries:

```cpp
// src/core/reactor_backend.cc
::io_uring_sqe* get_sqe() {
    ::io_uring_sqe* sqe;
    while (__builtin_expect((sqe = try_get_sqe()) == nullptr, false)) {
        do_flush_submission_ring();
        do_process_kernel_completions_step();
        _did_work_while_getting_sqe = true;
    }
    return sqe;
}
```

**Submit / reap flow.** `kernel_submit_work()` services preempting timers, queues pending file I/O, and calls `io_uring_submit`. `reap_kernel_completions()` calls `io_uring_peek_batch_cqe` + `io_uring_cq_advance`, dispatching each `cqe->user_data` to its `kernel_completion::complete_with(cqe->res)`. When idle, `wait_and_process_events()` arms recurring poll completions for the timerfd and the SMP wakeup eventfd, then blocks in `io_uring_wait_cqes(&_uring, &cqe, 1, ...)` until at least one completion arrives. Unlike the AIO backend, the uring backend declares `uses_blocking_io::yes` and `kernel_events_can_sleep()` always returns `true` ("We never need to spin while I/O is in flight"), because `io_uring` can wait on storage and network completions in one place.

**Network readiness.** Socket `read`/`write`/`accept` paths still use `IORING_OP_POLL_ADD` (`poll()`) to wait for readiness, with speculative non-blocking attempts first (`take_speculation`), rather than relying solely on async send/recv ops. The history (see [io_uring + Seastar (k3fu)]) is that the backend began with only read/write/readv/writev and grew network opcode coverage over time; zero-copy send (`IORING_OP_SEND_ZC`, Linux 6.0) is a later opportunity discussed there.

### Per-core memory allocator

Seastar replaces the global allocator with a **per-core allocator** (`src/core/memory.cc`). At startup, physical memory is divided into one region per shard (NUMA-aware), and each shard allocates from its own region using size-classed `small_pool`s. Because allocations almost always stay on the owning core, there is no cross-core allocator lock and no false sharing of allocator metadata. Freeing memory that "belongs" to another shard is handled by returning it to the owner via the cross-shard machinery rather than touching another core's pools directly. This per-core allocator is a load-bearing part of share-nothing: without it, every `new`/`delete` would reintroduce the global contention the architecture exists to avoid.

### Networking stack: native vs POSIX

Seastar ships **two** network stacks, selectable via `--network-stack`:

| Stack      | Header                                | Description                                                                                                                                       |
| ---------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **POSIX**  | `include/seastar/net/posix-stack.hh`  | Default. Uses the kernel TCP/IP stack via ordinary sockets, driven through the chosen reactor backend. No special privileges.                     |
| **Native** | `include/seastar/net/native-stack.hh` | A full **userspace TCP/IP stack** running inside the shard, on top of DPDK or a virtio device. The kernel is bypassed entirely for the data path. |

The native stack (`create_native_stack`, `native_stack_options`) gives the lowest latency and highest throughput by keeping packets entirely in userspace and sharded per core (each core handles its own RX/TX queues), but requires a dedicated NIC and DPDK. The POSIX stack is the pragmatic default and what most deployments use.

### Why share-nothing maximizes throughput

Putting the pieces together: a request arriving on a socket is handled by the shard that owns that connection, using that shard's memory and that shard's I/O scheduler, scheduled as a chain of `.then()` continuations on that shard's reactor, with disk and network I/O submitted to that shard's private `io_uring`/AIO ring. **No lock is taken and no other core's cache line is touched** for the entire lifetime of the request — unless the data genuinely lives on another shard, in which case `smp::submit_to` makes that hop explicit and asynchronous. As core counts scale, throughput scales close to linearly because there is almost no coordination overhead to amortize. This is the property [ScyllaDB shard-per-core][ScyllaDB shard-per-core] markets as 5–10x improvements over lock-based designs.

---

## Performance approach

- **Zero shared mutable state** between cores eliminates lock contention and cache-line bouncing; the dominant cost on many-core machines.
- **Userspace completion reaping** — both the AIO ring (`try_reap_events`) and `io_uring`'s CQ are drained without syscalls on the hot path.
- **Batched submission** — operations accumulate in the SQ and are flushed with a single `io_uring_submit` (or `io_submit`) per poll iteration, amortizing the submission syscall across many ops.
- **Allocation-free fast path** for ready futures: `.then()` on an already-resolved future runs inline, allocating no continuation.
- **Cooperative scheduling with a task quota** keeps tail latency bounded — no single continuation can monopolize the core beyond ~0.5 ms before the loop re-polls I/O.
- **Busy-polling option** removes interrupt and wakeup latency entirely for latency-critical deployments, at the cost of 100% CPU.
- **Per-core, NUMA-aware memory** keeps allocations local and free of cross-socket traffic.
- **Optional userspace networking** (DPDK native stack) bypasses the kernel network stack for the extreme end of the latency spectrum.

---

## Strengths

- **Near-linear scaling** with core count for I/O-bound workloads, the headline benefit of share-nothing.
- **Three interchangeable kernel backends** (`io_uring`, linux-aio, epoll) selected automatically by capability probing, so one binary runs well across kernel generations and restricted environments.
- **True proactor model** via `io_uring`/AIO: you get completions with results, not just readiness, which suits storage I/O far better than `epoll`.
- **Pioneered userspace-ring completion reaping** in the AIO backend years before `io_uring` made it mainstream.
- **Integrated, fair I/O scheduler** with priority classes tied to scheduling groups — disk bandwidth is governed, not first-come-first-served.
- **Battle-tested** in [ScyllaDB] and Redpanda at very high scale.
- **Explicit cross-core communication** makes the concurrency model auditable: cross-shard hops are visible `submit_to` calls, not hidden contention.

## Weaknesses

- **Steep learning curve.** The future/promise/continuation model, share-nothing discipline, and "never block the reactor" rule are hard to internalize; one blocking call stalls a whole core.
- **Pre-coroutine ergonomics.** Classic Seastar code is deeply nested `.then()` chains. C++20 coroutines (`co_await`) improve this, but a large body of code and examples predates them.
- **C++-only and Linux-centric.** The high-performance backends (AIO, `io_uring`) and the native stack are Linux-specific; there is no portable high-performance path.
- **Data locality is the programmer's problem.** Share-nothing means you must shard your data so requests land on the core that owns the data; cross-shard hops via `submit_to` are not free.
- **Heavy framework.** Seastar is an all-or-nothing runtime (it owns the threads, the memory allocator, and the scheduler), not a library you sprinkle into an existing app.
- **`io_uring` gating is conservative.** On older kernels, with RAID devices, or with insufficient locked-memory limits, Seastar silently falls back to AIO/epoll, so you may not get `io_uring` even when it compiles in.

---

## Key design decisions and trade-offs

| Decision                                             | Rationale                                                                                 | Trade-off                                                                                   |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| One reactor per core, share-nothing                  | Eliminates locks and cache-line contention; scales near-linearly with cores               | Programmer must shard data; cross-core work needs explicit `submit_to` and may serialize    |
| Future/promise/continuation concurrency              | Lightweight, allocation-free fast path; no per-connection OS thread                       | Verbose `.then()` chains pre-coroutines; "callback hell" risk; backtraces are harder        |
| Pluggable `reactor_backend` (`io_uring`/aio/epoll)   | One codebase runs optimally across kernels; can adopt new kernel I/O without API churn    | Three code paths to maintain; subtle behavioral differences (e.g. blocking-io semantics)    |
| `io_uring` preferred but conservatively gated        | Best modern performance, but only where it is actually faster and safe (5.12/5.17 checks) | Many environments silently get AIO/epoll instead; surprising for users expecting `io_uring` |
| Proactor (completion-based) over reactor (readiness) | Matches storage I/O semantics; reaps results directly; userspace ring draining            | Needs `O_DIRECT`/DMA and good filesystems (XFS) for AIO; more complex than `epoll`          |
| Per-core memory allocator                            | Keeps allocations local and lock-free; required for share-nothing to hold                 | Cross-shard frees need special handling; replaces the global allocator wholesale            |
| Busy-poll option                                     | Removes wakeup/interrupt latency for latency-critical services                            | Burns 100% CPU per core; bad for overprovisioned/laptop/container deployments               |
| Two network stacks (POSIX default, native/DPDK)      | Pragmatic default plus a kernel-bypass extreme for max performance                        | Native stack needs a dedicated NIC + DPDK and added operational complexity                  |
| Cooperative task quota (~0.5 ms)                     | Bounds tail latency; one continuation can't starve the shard                              | CPU-bound work must be manually chunked into small tasks                                    |

---

## Sources

- [Seastar GitHub Repository]
- [Seastar Tutorial]
- [Seastar API Reference]
- [Shared-nothing Design]
- [ScyllaDB shard-per-core]
- [io_uring + Seastar (k3fu)]
- [seastar-dev io_uring backend]
- [What's new in Seastar (issue 1)][whats-new-in-seastar]
- [Avi Kivity, Qualifying Filesystems for Seastar]
- [Introducing Glommio (Datadog)]
- [io_uring_setup(2) man page]
- [io_uring overview (companion document)][io-uring-index]
- [io_uring features (companion document)][io-uring-features]
- [io_uring opcode reference (companion document)][io-uring-opcodes]
- [Glommio (companion document)][glommio-doc]
- [Comparison of async runtimes (companion document)][comparison-doc]
- [Effects and event loops (companion document)][effects-doc]
- [OCaml Eio (companion document)][eio-doc]

<!-- References -->

[Seastar GitHub Repository]: https://github.com/scylladb/seastar
[Seastar Tutorial]: https://docs.seastar.io/master/tutorial.html
[Seastar API Reference]: https://docs.seastar.io/master/index.html
[Shared-nothing Design]: https://seastar.io/shared-nothing/
[ScyllaDB shard-per-core]: https://www.scylladb.com/product/technology/shard-per-core-architecture/
[ScyllaDB]: https://www.scylladb.com/
[io_uring + Seastar (k3fu)]: https://blog.k3fu.xyz/seastar/2022/10/03/iouring-seastar.html
[seastar-dev io_uring backend]: https://groups.google.com/g/seastar-dev/c/S2sJq-h4VB0
[whats-new-in-seastar]: https://makedist.com/posts/2023/04/30/whats-new-in-seastar-issue-1/
[Avi Kivity, Qualifying Filesystems for Seastar]: https://www.scylladb.com/2016/02/09/qualifying-filesystems/
[Introducing Glommio (Datadog)]: https://www.datadoghq.com/blog/engineering/introducing-glommio/
[io_uring_setup(2) man page]: https://man7.org/linux/man-pages/man2/io_uring_setup.2.html
[io-uring-index]: ./io-uring/index.md
[io-uring-features]: ./io-uring/features.md
[io-uring-opcodes]: ./io-uring/opcodes-reference.md
[glommio-doc]: ./glommio.md
[comparison-doc]: ./comparison.md
[effects-doc]: ./effects-and-event-loops.md
[eio-doc]: ../algebraic-effects/ocaml-eio.md
