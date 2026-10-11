# Seastar fiber synchronization (C++)

The shared-nothing extreme: Seastar runs one reactor thread per core and makes
every synchronization primitive **shard-local and atomic-free** — a semaphore
is a `ssize_t` plus a FIFO of promises, a condition variable a flag plus an
intrusive list — because two continuations on one shard never run at once.
Locks are for fibers that suspend across a `future`, never for parallelism;
cross-core coordination is message passing over per-pair SPSC queues, and a
non-reactor thread reaches a reactor through an `alien` lock-free queue plus an
`eventfd` write guarded by an asymmetric memory barrier.

|                        |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**               | framework (thread-per-core reactor, futures/promises, coroutines, `seastar::thread` stackful fibers)                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| **Language**           | C++20/23                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| **License**            | Apache-2.0                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **Repository**         | [`scylladb/seastar`][ss-repo] at `e018327663fa` (2026-06-02)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **Primitives covered** | `basic_semaphore` / `semaphore` / `semaphore_units`, `rwlock`, `shared_mutex`, `condition_variable`, `gate`, `abort_source`, `abortable_fifo`; cross-shard `smp::submit_to`, `foreign_ptr`; `alien::run_on` / `alien::submit_to`; `reactor::wakeup`                                                                                                                                                                                                                                                                                                         |
| **Parking substrate**  | none per primitive: a waiter is a `promise<>` stored in a `chunked_fifo` (semaphore, `shared_mutex`) or a `boost::intrusive` list node (condition variable); fulfilling it schedules the continuation on the same reactor. The reactor itself sleeps in its I/O backend and is woken through `_notify_eventfd`                                                                                                                                                                                                                                              |
| **Fairness**           | FIFO with direct handoff (`semaphore`, `shared_mutex`); "if several are awakened at once, they may be reordered by the scheduler"                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **Source read**        | [`core/semaphore.hh`][sem-h], [`core/abortable_fifo.hh`][afifo-h], [`core/shared_mutex.hh`][shm-h], [`core/rwlock.hh`][rwlock-h], [`core/condition-variable.hh`][cv-h], [`src/core/condition-variable.cc`][cv-cc], [`core/gate.hh`][gate-h], [`core/abort_source.hh`][as-h], [`core/smp.hh`][smp-h], [`core/sharded.hh`][sharded-h], [`core/alien.hh`][alien-h], [`src/core/alien.cc`][alien-cc], [`src/core/reactor.cc`][reactor-cc], [`src/core/systemwide_memory_barrier.cc`][smb-cc], [`src/core/thread_pool.cc`][tp-cc], [`doc/tutorial.md`][tutorial] |

## Overview

### What it solves

Seastar's tutorial makes the case against shared-memory synchronization on
modern machines ([`doc/tutorial.md` L38][tut-modern]):

> Modern machines are very different from those of just 10 years ago. They
> have many cores and deep memory hierarchies (from L1 caches to NUMA) which
> reward certain programming practices and penalizes others: Unscalable
> programming practices (such as taking locks) can devastate performance on
> many cores; Shared memory and lock-free synchronization primitives are
> available (i.e., atomic operations and memory-ordering fences) but are
> dramatically slower than operations that involve only data in a single
> core's cache, and also prevent the application from scaling to many cores.

The fiber primitives exist for a narrower problem: a _fiber_ (a chain of
continuations, a coroutine, or a `seastar::thread`) that holds state across a
suspension point. The `shared_mutex` header puts it plainly
([`shared_mutex.hh` L46–L48][shm-doc]): "many seastar tasks do not require
protection at all, since the seastar scheduler is not preemptive; however
tasks that do (by waiting on a future) may require explicit locking."

### Design philosophy

**Shard-local by construction.** The condition variable is "a standard
computer science condition variable sans locking, since in seastar access to
variables is atomic anyway, adapted for futures"
([`condition-variable.hh` L56–L69][cv-doc]). The semaphore is "a standard
computer science semaphore, adapted for futures" whose `broken()` is
"similar to POSIX's `pthread_cancel()`, with `wait()` acting as a cancellation
point" ([`semaphore.hh` L130–L148][sem-doc]). No field of any of these types is
atomic.

**Ownership never crosses a core implicitly.** `foreign_ptr` exists because
"As seastar avoids locking, any but the most trivial objects must be destroyed
on the same core they were created on […] the shared pointer types do not use
atomic operations to manage their reference counts" ([`sharded.hh`
L911–L931][foreign-ptr]); destroying one "sends a message to the original
core". A semaphore on shard 0 is simply unreachable from shard 1 except by
`submit_to`-ing a function that waits on it.

## How it works

`basic_semaphore<ExceptionFactory, Clock>` ([L149–L232][sem-state]) is

```cpp
ssize_t _count;
std::exception_ptr _ex;            // set by broken()
struct entry { promise<> pr; size_t nr; std::optional<abort_on_expiry<clock>> timer; };
internal::abortable_fifo<entry, expiry_handler> _wait_list;
```

- `wait(nr)` returns a ready future when `may_proceed(nr)` —
  `_count >= nr && _wait_list.empty()` — and otherwise `emplace_back`s an entry
  and returns `pr.get_future()`; a timeout arms an `abort_on_expiry` whose
  `abort_source` makes the entry abortable ([L293–L343][sem-wait]).
- `signal(nr)` adds to `_count` and, while the head's request fits, subtracts
  it, `set_value()`s its promise and pops it ([L406–L417][sem-signal]).
  Fulfilling a promise schedules the attached continuation on this reactor's
  task queue; no thread is woken.
- `consume(nr)` may drive `_count` negative; `broken(ex)` fails every waiter
  and all future waits ([L506–L515][sem-broken]).
- `get_units()` wraps a wait into RAII `semaphore_units` that `signal` on
  destruction ([L604–L628][sem-units]); `rwlock` is a semaphore of
  `max_counter()` units where a writer takes all of them ([`rwlock.hh`
  L71–L74][rwlock-h]).

`abortable_fifo` ([`abortable_fifo.hh` L61–L110][afifo-class]) keeps the first
element in a `std::unique_ptr<entry> _front` ("to avoid large allocations done
by chunked_fifo for single-element cases … it's common to have at most one
waiter") and the rest in a `chunked_fifo<entry>` of 128-element chunks. An
entry may carry an `abort_source::subscription`; on abort the handler fails the
promise, sets `payload = std::nullopt` and decrements `_size`, and the
tombstone is reclaimed lazily by `drop_expired_front()` when it reaches the
head ([L63–L105][afifo-entry]).

`shared_mutex` ([L55–L150][shm-impl]) is `unsigned _readers`, `bool _writer`
and a `chunked_fifo<waiter{promise<>, bool for_write}>`; `wake()` grants the
head and, while heads are readers, keeps granting, stopping at the first
writer.

`condition_variable` ([`condition-variable.hh` L71–L196][cv-impl]) holds a
`boost::intrusive::list<waiter>` with `auto_unlink` hooks, an `_ex`, and
`bool _signalled` — "set to true if signalled while no waiters". `wait()`
heap-allocates a self-deleting `promise_waiter`; the coroutine form `when()`
returns an `awaiter` that lives in the coroutine frame.

## Analysis

### State word and fast path

There is no lock word in the concurrent sense. `semaphore::wait` is a
compare-and-subtract on a plain `ssize_t` plus an emptiness check of the wait
list; `signal` is an add and a list walk; `shared_mutex::lock` checks two
plain fields. The fast path is a ready future — `make_ready_future<>()` —
whose `.then()` runs the continuation inline (subject to the scheduler's
preemption check). The memory-ordering question disappears because every
access happens on the owning reactor thread.

### Waiting: spin, yield, park

Not applicable inside a shard: a fiber that cannot proceed returns an
unresolved future (or a coroutine suspends on it, or a `seastar::thread`'s
`.get()` switches stacks), and the reactor runs something else. The tutorial is
explicit that a `seastar::thread` "can only block on Seastar futures, not on
blocking system calls" ([L2295][tut-thread]). The only spin-like policy is the
reactor's own: it polls its pollers (I/O, timers, SMP queues, alien queue)
and goes to sleep only after every poller agrees in `try_enter_interrupt_mode`
([`reactor.cc` L3020–L3054][smp-pollfn]).

### The parking substrate

A waiter is a `promise<>`, and where it lives depends on the primitive:

| Primitive            | Waiter record                                       | Storage                                                    |
| -------------------- | --------------------------------------------------- | ---------------------------------------------------------- |
| `semaphore`          | `entry{promise<>, nr, optional timer}`              | `_front` `unique_ptr`, then `chunked_fifo` chunks of 128   |
| `shared_mutex`       | `waiter{promise<>, for_write}`                      | `chunked_fifo`                                             |
| `condition_variable` | `promise_waiter` (heap, self-deleting) or `awaiter` | `boost::intrusive::list`, node in the heap object or frame |
| `gate`               | one `std::optional<promise<>> _stopped`             | inline                                                     |
| `abort_source`       | `subscription` (callback)                           | `boost::intrusive::list`, node in the subscriber           |

The semaphore's choice of a **slab-like chunked queue over an intrusive
list** is deliberate: a `promise` must stay where its `future` can find it,
so waiters are values in Seastar-owned storage rather than nodes in the
caller's frame, and cancellation becomes tombstoning instead of unlinking.

### Fairness, handoff and starvation

FIFO with **direct handoff**: `signal` subtracts the head's units before
fulfilling it, and `may_proceed` refuses a newcomer while anyone waits, so
nobody barges. A large request blocks smaller ones behind it ("Waits are
serviced in FIFO order, though if several are awakened at once, they may be
reordered by the scheduler", [L293–L298][sem-wait]). `shared_mutex` is
task-fair (phase by phase in arrival order): `try_lock_shared` fails while any
waiter is queued, so a reader cannot overtake a waiting writer, and a writer
is granted only when `_readers == 0`. Starvation is bounded by queue length;
the [convoy](./concepts.md#convoys) cost of handoff is small because the
"handed-to" fiber runs on the same core at the next task-queue turn.

**Cancellation safety.** There is no drop-to-cancel: discarding a returned
future does not dequeue the waiter, and a later `signal` would still charge
its units. Cancellation is explicit, through an `abort_source`
(`wait(as, nr)`) or a deadline. An aborted entry is failed and tombstoned
**before** any units are subtracted from it — `signal` only looks at
`front()`, which `drop_expired_front` guarantees is live — so an aborted
waiter never consumes a permit, and units granted to a live waiter stay with
it. `get_units` turns a successful wait into an RAII object, so units return
on any exit path. `condition_variable` timeouts unlink the node
(`waiter::timeout` → `unlink()` → exception, [`condition-variable.cc`
L47–L50][cv-timeout]).

### Condition variables and predicates

`condition_variable` has no mutex to release — shard atomicity replaces it —
so the classic lost-wakeup window is handled by **storing one signal**:
`signal()` with no waiter sets `_signalled`, and the next `wait()` consumes it
via `check_and_consume_signal()` ([`condition-variable.cc`
L66–L74][cv-signal]). `broadcast()` moves the list out and signals every
waiter; `broken()` fails all with an exception.

The predicate forms differ in where the predicate runs. `wait(pred)` is a
`do_until(pred, wait)` loop on the waiter's side. The coroutine form
`when(pred)` uses `predicate_awaiter`, whose `signal()` **evaluates the
predicate in the signaller's context** and, if false, re-enqueues the waiter
at the tail — "this maintains "wait" version semantics of moving to back of
queue if predicate fails" ([`condition-variable.hh` L152–L187][cv-pred]) — a predicate-carrying waiter
in the spirit of nsync's conditions or Abseil's `Await`, possible only because
the signaller and the waiter share a thread.

### Footprint and layout

Primitives are small value types: `semaphore` is a `ssize_t`, an
`exception_ptr`, the `abortable_fifo` (a `unique_ptr`, the `chunked_fifo`
header, the handler reference, a size) and an empty-optimized debug flag;
`condition_variable` is a list head, an `exception_ptr` and a `bool`;
`gate` is a `size_t` and an optional promise. None is padded — nothing is
shared between cores. The first waiter costs one `make_unique<entry>`; later
waiters are amortized over 128-entry chunks. A semaphore cannot be moved once
it has waiters (`SEASTAR_ASSERT(other._wait_list.empty())`, [L262–L271][sem-move]).

### Portability

Linux only in practice: the reactor backends at this SHA are `linux-aio`,
`epoll` and `io_uring` ([`reactor_backend.cc`][backend-cc]). The primitives themselves are portable C++; the cross-thread wake
paths below rely on `eventfd` and on `membarrier(MEMBARRIER_CMD_PRIVATE_EXPEDITED)`
or an `madvise(MADV_DONTNEED)` IPI fallback, which the code doubts on ARM
("FIXME: does this work on ARM?", and on `aarch64` without native
`membarrier` the reactor "will not sleep when idle", [`systemwide_memory_barrier.cc`
L79–L156][smb-cc]).

### Async and fiber integration

**Within a shard** every primitive is a fiber primitive; nothing blocks a
thread. **Across shards** there are no shared primitives at all:
`smp::submit_to(shard, func)` runs `func` on the target core and returns its
result as a future on the caller's core ([`smp.hh` L350–L362][smp-submit]).
The transport is a pair of `boost::lockfree::spsc_queue`s of capacity 128 per
(source, destination) pair, filled in batches of 16
([`smp.hh` L177–L197][smp-queue]); back-pressure is a **shard-local
semaphore** on the sending side (`get_units(sem, 1, timeout)` per
`smp_service_group` before an item is queued, [`reactor.cc`
L3732–L3752][smp-submit-item]).

**Waking a sleeping reactor** is the part that bears directly on a `WaitWord`.
The reactor publishes `_sleeping` with **relaxed** stores; a sender pushes
into the lock-free queue, issues only a compiler barrier, and checks it
([`reactor.cc` L3785–L3795][maybe-wakeup], [L3100–L3112][reactor-wakeup]):

```cpp
// This is read-after-write, which wants memory_order_seq_cst,
// but we insert that barrier using systemwide_memory_barrier()
// because seq_cst is so expensive.
//
// However, we do need a compiler barrier:
std::atomic_signal_fence(std::memory_order_seq_cst);
remote->wakeup();   // if (_sleeping) { _sleeping = false; write(_notify_eventfd, 1); }
```

The sleeper pays instead: `try_enter_interrupt_mode` stores `_sleeping =
true`, runs `try_systemwide_memory_barrier()` (`membarrier` private-expedited,
which forces a full barrier on every thread of the process), and **re-polls
the queues** before sleeping, backing out if anything arrived
([L3034–L3049][smp-pollfn]). Because Linux serializes concurrent
`membarrier` calls, Seastar takes a try-lock first and simply stays awake if
another reactor is mid-barrier ("While they wait on the mutex, they cannot be
woken", [`systemwide_memory_barrier.cc` L122–L156][smb-try]). This is the
asymmetric-fence version of the futex "set waiters bit, re-check, sleep"
protocol: the hot side (senders, millions per second) pays a plain load; the
cold side (a reactor going idle) pays a process-wide barrier.

**Alien threads.** A thread outside Seastar calls `alien::run_on(instance,
shard, func)` (noexcept, void) or `alien::submit_to`, which returns a
`std::future` the alien thread can block on ([`alien.hh`
L143–L196][alien-submit]). Items go into a `boost::lockfree::queue` (MPMC)
per shard, followed by the same `maybe_wakeup` → `reactor::wakeup()`
([`alien.cc` L47–L60][alien-cc-wake]). The syscall offload thread uses the
symmetric variant: after pushing a completion it executes a `seq_cst` fence
and writes the `eventfd` if `_main_thread_idle` ([`thread_pool.cc`
L45–L69][tp-wake]). The reverse direction — a reactor fiber waiting for an
alien thread — has no primitive: the alien thread must `run_on` a function
that fulfils a promise on the shard. Compare folly's
[`fibers::Baton`](./folly-sync.md#async-and-fiber-integration), which lets a
remote thread post directly to a fiber waiter, and tokio's
[`Unparker`](./tokio-sync.md#async-and-fiber-integration), which dispatches
between a condvar and the I/O driver.

## Strengths

- **No atomics, no lock word, no kernel** in any shard-local primitive.
- **FIFO handoff with no barging**; fairness is trivially correct on one
  thread.
- **Explicit, composable cancellation** (`abort_source`, deadlines) that
  provably never consumes a permit; tombstones make abort O(1).
- **`get_units` RAII** and `broken()` turn error propagation into a semaphore
  operation.
- **Asymmetric wake protocol**: cross-core and alien senders pay only a
  relaxed load to find out whether the target sleeps.
- Predicate waiters evaluated by the signaller (`when(pred)`).

## Weaknesses

- **Nothing is usable across cores**; every cross-shard interaction is a
  message and a future, and a lock shared by shards must be built from
  `submit_to` to an owner shard.
- **No drop-to-cancel**: a discarded wait future still consumes units when
  signalled.
- **No thread-side wait** on any primitive; an alien thread can only
  block on a `std::future` produced by `alien::submit_to`.
- `condition_variable::wait()` heap-allocates a waiter per wait; the first
  semaphore waiter allocates too.
- The sleep protocol depends on `membarrier` (or an `madvise` IPI) and is
  disabled outright on `aarch64` kernels without native `membarrier`.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                       | Trade-off                                                                      |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Shard-local primitives with plain fields                          | "taking locks" and atomics "prevent the application from scaling to many cores"                 | cross-core sharing only by message passing                                     |
| Waiter = `promise<>` stored in a chunked FIFO                     | promise must stay addressable; amortized allocation; one-waiter case inlined in `_front`        | not intrusive; first waiter allocates                                          |
| Cancel by `abort_source` and deadline, tombstone the entry        | explicit cancellation points like `pthread_cancel`; O(1) abort                                  | no implicit cancellation by dropping a future                                  |
| FIFO handoff, `may_proceed` requires an empty queue               | no starvation; large requests eventually served                                                 | head-of-line blocking by a large request                                       |
| Condition variable stores one signal instead of taking a mutex    | shard atomicity replaces the mutex; avoids lost wakeups                                         | at most one stored signal                                                      |
| Remote wake: relaxed `_sleeping` + `membarrier` on the sleep side | senders' hot path is a compiler barrier and a load                                              | process-wide barrier on every sleep attempt; serialized by the kernel          |
| `alien::run_on` is `noexcept` and returns nothing                 | "we cannot identify the alien thread, hence we are not able to post the fulfilled promise" back | results need `alien::submit_to`'s `std::future`, which blocks the alien thread |

## Sources

- `scylladb/seastar` at [`e018327663fa`][ss-repo]: the headers and sources in
  the metadata table.
- [`doc/tutorial.md`][tutorial] — the design rationale (L38, "Modern
  Machines"), shared-nothing TODOs (L1654–L1662), and `seastar::thread`
  semantics (L2278–L2295).

> [!NOTE]
> The Seastar clone is a single-commit checkout; no history is cited. The
> reactor backends were not read beyond the `_sleeping`/`_notify_eventfd`
> protocol, and no measurement was taken of the `membarrier` cost.

<!-- References -->

[ss-repo]: https://github.com/scylladb/seastar/tree/e018327663fa9eb100ae04edc662780f6716c55d
[sem-h]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/semaphore.hh
[sem-doc]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/semaphore.hh#L130-L148
[sem-state]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/semaphore.hh#L149-L232
[sem-move]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/semaphore.hh#L262-L271
[sem-wait]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/semaphore.hh#L293-L343
[sem-signal]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/semaphore.hh#L406-L417
[sem-broken]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/semaphore.hh#L506-L515
[sem-units]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/semaphore.hh#L604-L628
[afifo-h]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/abortable_fifo.hh
[afifo-class]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/abortable_fifo.hh#L61-L110
[afifo-entry]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/abortable_fifo.hh#L63-L105
[shm-h]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/shared_mutex.hh
[shm-doc]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/shared_mutex.hh#L38-L54
[shm-impl]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/shared_mutex.hh#L55-L150
[rwlock-h]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/rwlock.hh#L71-L74
[cv-h]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/condition-variable.hh
[cv-doc]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/condition-variable.hh#L56-L69
[cv-impl]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/condition-variable.hh#L71-L196
[cv-pred]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/condition-variable.hh#L152-L187
[cv-cc]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/condition-variable.cc
[cv-timeout]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/condition-variable.cc#L47-L50
[cv-signal]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/condition-variable.cc#L66-L74
[gate-h]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/gate.hh
[as-h]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/abort_source.hh
[smp-h]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/smp.hh
[smp-queue]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/smp.hh#L177-L197
[smp-submit]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/smp.hh#L350-L362
[sharded-h]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/sharded.hh
[foreign-ptr]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/sharded.hh#L911-L931
[alien-h]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/alien.hh
[alien-submit]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/include/seastar/core/alien.hh#L143-L196
[alien-cc]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/alien.cc
[alien-cc-wake]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/alien.cc#L47-L60
[reactor-cc]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/reactor.cc
[smp-pollfn]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/reactor.cc#L3020-L3054
[reactor-wakeup]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/reactor.cc#L3100-L3112
[smp-submit-item]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/reactor.cc#L3732-L3752
[maybe-wakeup]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/reactor.cc#L3785-L3795
[smb-cc]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/systemwide_memory_barrier.cc#L79-L156
[smb-try]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/systemwide_memory_barrier.cc#L122-L156
[backend-cc]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/reactor_backend.cc
[tp-cc]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/thread_pool.cc
[tp-wake]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/src/core/thread_pool.cc#L45-L69
[tutorial]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/doc/tutorial.md
[tut-modern]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/doc/tutorial.md#L38
[tut-thread]: https://github.com/scylladb/seastar/blob/e018327663fa9eb100ae04edc662780f6716c55d/doc/tutorial.md#L2295
