# Seo et al. 2018 — Argobots: A Lightweight Low-Level Threading and Tasking Framework

A user-level threading substrate for HPC runtimes: OS threads ("execution
streams") run stackful user-level threads (ULTs) and stackless tasklets from
user-visible pools under pluggable, stackable schedulers. The paper is about
the substrate, not locks — its synchronization story is one sentence and an MPI
lock sketch — but the library's mutex is a useful counter-example: a
test-and-set flag plus a spinlock-guarded waiter list that **wakes every
waiter on every unlock**, and a waiter list that mixes fibers (pushed back to a
pool) with OS threads (parked on a shared futex).

|                 |                                                                                                                                                                                                                                                                                                                                      |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Kind**        | paper (IEEE TPDS) + library (`pmodels/argobots`)                                                                                                                                                                                                                                                                                     |
| **Year**        | 2018 (March issue; accepted version online 2017-10-24; received 2017-07-28)                                                                                                                                                                                                                                                          |
| **Authors**     | Sangmin Seo, Abdelhalim Amer, Pavan Balaji, Cyril Bordage, George Bosilca, Alex Brooks, Philip Carns, Adrián Castelló, Damien Genet, Thomas Herault, Shintaro Iwasaki, Prateek Jindal, Laxmikant V. Kalé, Sriram Krishnamoorthy, Jonathan Lifflander, Huiwei Lu, Esteban Meneses, Marc Snir, Yanhua Sun, Kenjiro Taura, Pete Beckman |
| **Venue**       | IEEE Transactions on Parallel and Distributed Systems 29(3), pp. 512–526; [DOI 10.1109/TPDS.2017.2766062][doi]                                                                                                                                                                                                                       |
| **Language**    | C                                                                                                                                                                                                                                                                                                                                    |
| **License**     | Argobots: UChicago Argonne BSD-style (`COPYRIGHT` in the repository); paper: IEEE, accepted manuscript via OSTI                                                                                                                                                                                                                      |
| **Platforms**   | Linux; 2× Xeon E5-2699 v3 (36 cores / 72 hardware threads) for the core benchmarks; context switch via Boost `fcontext` (default) or `ucontext`                                                                                                                                                                                      |
| **Primitive**   | execution streams (Pthreads) running ULTs and tasklets from pools; stackable schedulers; `yield`/`yield_to`; mutex, condition variable, future, barrier ("only for ULTs" in the paper; today also external threads)                                                                                                                  |
| **Source read** | `seo-2018-argobots.pdf` — the accepted manuscript from [OSTI][osti], all 14 pages; Argobots at [`bffdf56`][abt-tree] (2025-11-28): `abti_mutex.h`, `abti_waitlist.h`, `abtd_spinlock.h`, `abtd_futex.c`, `abti_ythread.h`, `ythread.c`                                                                                               |

> [!NOTE]
> This survey's reading list gave this paper by DOI alone. It is the TPDS article published
> in volume 29, issue 3 (March 2018); the early-access version appeared online
> on 2017-10-24. The open copy read is the accepted manuscript ("has not been
> fully edited"), deposited at OSTI as report 1413456 (also on HAL as
> `hal-01887586`). The library code cited below is the current `main`, eight
> years newer than the paper; the paper itself does not describe the mutex.

## Overview

### What it solves

Generic user-level threading libraries make "transparent and rigid scheduling
decisions (e.g., random work stealing)" while specialized ones are unusable
outside their niche ([§1, p. 1][osti]). Argobots aims at the gap ([abstract][osti]):

> Argobots offers a carefully designed execution model that balances
> generality of functionality with providing a rich set of controls to allow
> specialization by end users or high-level programming models.

### Design philosophy

Expose everything the higher-level runtime may want to control: the OS
threads (execution streams, ESs), the pools (private or shared, the user
decides), the scheduler (replaceable, stackable), and the kind of work unit —
a ULT with its own stack, or a tasklet that "can be executed only as atomic
work units that run to completion without context switching" ([§1][osti]).
Blocking is cooperative ([§2.4, p. 3][osti]):

> Some Argobots synchronization primitives, such as mutex locking or thread
> join operations, automatically yield control when blocking is inevitable.
> ULTs that interact with external blocking resources (such as network or
> storage devices) are expected to explicitly context switch by using `yield`
> or `yield_to`.

## How it works

### Execution model

Each ES maps to one Pthread and runs a main scheduler that pops units from its
pools; work units in a pool are "ready," so Argobots "does not control
dependencies between work units" — the application does, through joins and
synchronization objects ([§2.2][osti]). `yield_to` switches directly to a named
ULT on the same ES, bypassing the scheduler and halving context switches
([§2.3, §4.3][osti]). A tasklet runs on the scheduler's stack.

### Critical-path engineering

§3 walks the create/join/free path cache miss by cache miss: memory allocation
was 93% of `Create` and 84% of `Free` until a per-ES memory pool (blocks freed
on another ES are returned to the allocating ES) and 2 MiB huge pages; a
performance-oriented field layout cut `Join` by up to 7%; skipping the context
save of a terminating ULT saved about 100 cycles (45% of `Join`); bypassing the
scheduler on join and a `join_many` cut the rest. A **private pool** "is
intended for only sequential access and thus does not use any mutex or atomic
instructions" ([§3.5][osti]).

### The library mutex (source, not paper)

`ABTI_mutex` is a test-and-set `ABTD_spinlock lock`, a second spinlock
`waiter_lock`, and an intrusive `ABTI_waitlist` ([`abti.h` L201–L212][abt-mutex-struct]).
Acquire ([`abti_mutex.h` L58–L77][abt-lock]):

```c
while (ABTD_spinlock_try_acquire(&p_mutex->lock)) {
    /* Failed to take a lock, so let's add it to the waiter list. */
    ABTD_spinlock_acquire(&p_mutex->waiter_lock);
    /* Maybe the mutex lock has been already released.  Check it. */
    if (!ABTD_spinlock_try_acquire(&p_mutex->lock)) {
        ABTD_spinlock_release(&p_mutex->waiter_lock);
        break;
    }
    ABTI_waitlist_wait_and_unlock(pp_local, &p_mutex->waitlist,
                                  &p_mutex->waiter_lock, ...);
}
```

Release takes `waiter_lock`, clears `lock`, and **broadcasts** the whole
waitlist ([L173–L185][abt-unlock]); every woken waiter re-runs the loop and all
but one queue again. A configure option `--enable-simple-mutex` swaps in "an
old yield-based mutex implementation" that just `yield`s in a `try_acquire`
loop ([`configure.ac`][abt-configure]).

### The waitlist: fibers and threads on one queue

`ABTI_waitlist_wait_and_unlock` ([`abti_waitlist.h` L20–L88][abt-wait]) branches
on the caller:

- **A ULT** links its own `ABTI_thread` (intrusive `p_next`) into the list and
  calls `ABTI_ythread_suspend_unlock`, which switches to the scheduler and
  releases the spinlock **in a callback on the scheduler's side** after the
  ULT is marked `BLOCKED` ([`ythread.c` L162–L177][abt-suspend-cb]) — the
  standard cure for the lost-wakeup window.
- **An external (non-Argobots) thread** links a stack-allocated dummy
  `ABTI_thread`, then waits on a futex shared by the whole waitlist, re-checking
  its own `state` word.

`signal` and `broadcast` resume ULTs by pushing them back to their pool
(`ABTI_ythread_resume_and_push`, [`abti_ythread.h` L41–L59][abt-resume]) and
wake external threads by bumping the shared futex — for _all_ of them, even on
`signal` ([L216–L244][abt-signal]):

```c
/* There's no way to selectively wake up threads.  Let's just
 * wake up all the threads.  They will sleep again since their
 * states are not marked as READY. */
ABTD_futex_broadcast(&p_waitlist->futex);
```

On Linux the futex is a raw `FUTEX_WAIT_PRIVATE`/`FUTEX_WAKE_PRIVATE` on a
generation counter ([`abtd_futex.c` L17–L48][abt-futex]); elsewhere a linked
list of per-waiter `pthread_cond_t`.

### The MPI lock (paper §5.2)

The MPICH-over-Argobots integration uses a custom lock with three parts:
prioritization that demotes ULTs in blocking MPI routines; a waiter queue per ES
and priority level "to avoid contention on the critical path"; and "a
lightweight lock ownership passing between ULTs in the same ES. Since such ULTs
are sequential, lock ownership can be passed with mostly a simple context switch
without an expensive fully fledged lock release operation" ([§5.2, p. 10][osti]).
The algorithm itself is in the authors' earlier PPoPP 2015 paper (ref. [40]).

## Analysis

### State word and fast path

One test-and-set boolean (`ABTD_atomic_test_and_set_bool`); uncontended
`try_acquire` is one atomic exchange, release is a release-store clear — but
only in `--enable-simple-mutex` mode. The default release always takes
`waiter_lock` and checks the waitlist, so an uncontended unlock is a
test-and-set plus two release stores. There is no "has waiters" bit to skip
the slow path.

### Waiting: spin, yield, park

A ULT that fails `try_acquire` spins only on `waiter_lock` (a TTAS spinlock,
[`abtd_spinlock.h` L28–L40][abt-spinlock]), then suspends; there is no adaptive
spin on the mutex itself. The simple variant `yield`s in a loop instead. The
timed wait polls the clock and `yield`s rather than suspending
([`abti_waitlist.h` L91–L135][abt-timed]). External threads park on the futex;
an `ABT_CONFIG_ACTIVE_WAIT_POLICY` build makes them busy-wait instead.

### The parking substrate

Per-object intrusive waiter list guarded by a spinlock; waiter records are the
`ABTI_thread` descriptors themselves (no allocation). ULTs park by being absent
from any pool; external threads park on one futex word per waitlist.

### Fairness, handoff and starvation

No handoff and no FIFO: unlock clears the flag and wakes all waiters, who race
with each other and with newcomers that never queued — full
[barging](./concepts.md#barging-and-handoff) plus a
[thundering herd](./concepts.md#thundering-herd) on every contended unlock. No
starvation bound. The MPI lock of §5.2 adds explicit intra-ES handoff, a hint
that the stock mutex was not enough.

### Condition variables and predicates

`ABTI_cond` is a spinlock, the waiter mutex pointer, and a waitlist
([`abti.h` L483–L487][abt-cond]); `eventual` (a one-shot future with a value) and
`future` use the same waitlist. No predicate waits, no requeue — a broadcast
re-queues waiters on the mutex by waking them all.

### Footprint and layout

`ABTI_mutex` holds `attrs`, two one-byte spinlocks, a nesting count, an owner
id, and the waitlist (head and tail pointers plus, without the active-wait
policy, a futex word) — tens of bytes, heap-allocated by `ABT_mutex_create`
(a static initializer also exists).

### Portability

Linux futex where available (detected at configure time), otherwise
`pthread_cond_t` lists; `fcontext` or `ucontext` for switching.

### Async and fiber integration

The whole point: ULT blocking is a scheduler operation. Wakeups cross ESs by
pushing the ULT into its associated pool, which another ES's scheduler pops. The
paper's I/O services show the event-loop side: `abt-io` delegates blocking
POSIX calls to tasklets on a dedicated pool and wakes the caller through an
`eventual`; `abt-snoozer` is a scheduler that blocks the ES in `epoll()` when
idle, "and the pool can `write()` to an `eventfd()` file descriptor to notify
it when new work units are added" ([§5.3, p. 11][osti]).

## Evaluation

Core benchmarks on 2× Xeon E5-2699 v3, gcc 4.8.5, PAPI counters ([§3–§4][osti]):

| Measurement                                  | Result                                                                                                          |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Baseline fork-join of 64 ULTs, one ES        | 2,443 cycles per ULT (1,837 create, 212 join, 394 free)                                                         |
| Memory pool + huge pages                     | largest gain for create/free (allocation was 93% / 84% of their cost)                                           |
| Create/join vs Qthreads, MassiveThreads      | optimized Argobots with private pools scales almost perfectly to 72 ESs; shared pools scale worst               |
| Create/join variation across ESs             | optimized Argobots under 20 cycles; MassiveThreads up to 740 cycles                                             |
| `yield_to` vs `yield`                        | twofold lower overhead at every ES count                                                                        |
| MPI receiver latency (36 ESs)                | 8 ULTs per ES (288 total) reach the lowest latency, near single-threaded                                        |
| Colocated I/O service (12 cores, 2,048 ULTs) | throughput competitive with Pthreads at lower CPU time; Pthreads up to nearly 8 s slower when pinned to 2 cores |

No mutex or condition-variable benchmark appears in the paper.

## Relevance to Sparkles

- **Question (d), mixing fibers and threads on one wait queue.** Argobots' waitlist
  is a working design for a `WaitWord` that both loop-resident fibers and plain
  OS threads wait on: fibers are re-enqueued on their home pool, threads park on
  a futex, and the waiter record is the intrusive thread descriptor. Its flaw is
  the shared futex — "no way to selectively wake up threads" — which a
  per-waiter wait word (or a parking-lot style table) avoids.
- **Unlock after the context switch.** Releasing the queue lock in the
  scheduler-side callback, after the fiber is marked blocked, is the pattern an
  event-loop `WaitWord` needs so a cross-thread wake cannot run before the
  fiber has actually left the CPU.
- **Question (a)/(c), what not to copy.** Broadcast-on-unlock with no waiter bit
  makes every contended unlock O(waiters) and every uncontended unlock pay for a
  second lock; the ITMO measurements
  ([Skazhenik et al. 2026][itmo]) found this mutex slower than a TTAS lock with
  yield.
- The `abt-snoozer` eventfd wake is the minimal "thread → event loop" bridge.

## Strengths

- Clean separation of execution streams, pools, schedulers and work-unit kinds,
  all user-controllable; private pools need no atomics.
- Thorough critical-path cost analysis down to cache and TLB misses.
- Sync primitives work for ULTs and external threads alike.

## Weaknesses

- The paper says almost nothing about synchronization design.
- The library mutex barges and broadcasts; no fairness, no handoff, no spin
  tuning.
- External waiters share one futex per waitlist and are all woken on every
  signal.
- Timed waits poll and yield instead of suspending.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                           | Trade-off                                                    |
| --------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------ |
| User-visible ESs, pools and stackable schedulers          | Higher-level runtimes control placement and policy  | Users must manage ES counts and pool sharing                 |
| Tasklets beside ULTs                                      | No stack or context cost for run-to-completion work | Tasklets cannot block on Argobots sync primitives            |
| Mutex = TAS flag + spinlock-guarded intrusive waitlist    | Simple; works for ULTs and external threads         | Unlock always takes the waiter lock; broadcast wake; barging |
| Unlock the waiter lock in the post-switch callback        | Closes the suspend/wake race without a handshake    | Ties the primitive to the scheduler internals                |
| One futex per waitlist for external threads               | Portable, small                                     | `signal` wakes every external waiter                         |
| Delegate blocking syscalls to a tasklet pool + `eventual` | Keeps request ULTs cooperative                      | An extra pool and hop per I/O call                           |

## Sources

- [Seo et al., "Argobots: A Lightweight Low-Level Threading and Tasking Framework", IEEE TPDS 29(3), 2018 (accepted manuscript)][osti] ([DOI][doi], [HAL][hal]) — §1 motivation; §2 execution model, schedulers, primitive operations, implementation; §3 critical-path cost analysis; §4 comparison with Qthreads and MassiveThreads; §5.1 OpenMP over Argobots; §5.2 MPI interoperability and its lock; §5.3 `abt-io` and `abt-snoozer`; §6 related work
- [Argobots at `bffdf56`][abt-tree] — mutex ([`abti_mutex.h`][abt-lock]), waitlist ([`abti_waitlist.h`][abt-wait]), spinlock ([`abtd_spinlock.h`][abt-spinlock]), futex ([`abtd_futex.c`][abt-futex]), suspend/resume ([`abti_ythread.h`][abt-resume], [`ythread.c`][abt-suspend-cb]), struct layouts ([`abti.h`][abt-mutex-struct]), build options ([`configure.ac`][abt-configure])
- [Skazhenik et al. 2026][itmo] — measures the Argobots mutex against adapted TTAS/MCS/HMCS
- [Capriccio (von Behren et al. 2003)][capriccio] and [Li & Zdancewic 2007][li-z] — cited by the paper as specialized user-level-thread runtimes

<!-- References -->

[doi]: https://doi.org/10.1109/TPDS.2017.2766062
[osti]: https://www.osti.gov/servlets/purl/1413456
[hal]: https://inria.hal.science/hal-01887586
[abt-tree]: https://github.com/pmodels/argobots/tree/bffdf56916879f9321a1d7983fa486736cd1d722
[abt-mutex-struct]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/include/abti.h#L201-L212
[abt-cond]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/include/abti.h#L483-L487
[abt-lock]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/include/abti_mutex.h#L58-L77
[abt-unlock]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/include/abti_mutex.h#L173-L185
[abt-wait]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/include/abti_waitlist.h#L20-L88
[abt-timed]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/include/abti_waitlist.h#L91-L135
[abt-signal]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/include/abti_waitlist.h#L216-L244
[abt-spinlock]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/include/abtd_spinlock.h#L28-L40
[abt-futex]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/arch/abtd_futex.c#L17-L48
[abt-resume]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/include/abti_ythread.h#L41-L59
[abt-suspend-cb]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/src/ythread.c#L162-L177
[abt-configure]: https://github.com/pmodels/argobots/blob/bffdf56916879f9321a1d7983fa486736cd1d722/configure.ac#L798-L801
[itmo]: ./skazhenik-2026-coroutine-sync.md
[capriccio]: ./von-behren-2003-capriccio.md
[li-z]: ./li-zdancewic-2007.md
