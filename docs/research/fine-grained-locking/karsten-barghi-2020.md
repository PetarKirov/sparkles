# Karsten & Barghi 2020 — User-level Threading: Have Your Cake and Eat It Too

An M:N user-level threading runtime (the "fred" runtime, later published as
`libfibre`) that matches a best-in-class event-driven server while keeping
blocking, thread-per-session code. For this catalog it contributes three
reusable mechanisms. Idle processors park through a **benaphore**, a counting
semaphore with an atomic fast path, so the fully loaded case costs one atomic
add. Each file descriptor gets a user-level lock and a **binary semaphore that
absorbs duplicate readiness events**. The poller is itself a fiber that falls
back to OS blocking only when every processor runs dry.

|                 |                                                                                                                                                                                                           |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (SIGMETRICS 2020; journal article in POMACS)                                                                                                                                                        |
| **Year**        | 2020 (issue dated March 2020; published online 2020-05-27)                                                                                                                                                |
| **Authors**     | Martin Karsten, Saman Barghi (University of Waterloo)                                                                                                                                                     |
| **Venue**       | Proceedings of the ACM on Measurement and Analysis of Computing Systems (POMACS) 4(1), Article 17, 30 pp.; presented at ACM SIGMETRICS 2020; [DOI 10.1145/3379483][doi]                                   |
| **Language**    | C++ runtime with a pthreads-like C API; GCC or Clang on Linux and FreeBSD, x86-64                                                                                                                         |
| **License**     | paper: ACM, publication rights licensed; runtime: not stated in the paper                                                                                                                                 |
| **Platforms**   | measured on Linux 4.15 (Ubuntu 18.04) on 4-socket, 64-core AMD Opteron 6380; tail-latency runs on dual-socket Intel E5-2620 with Mellanox 10 GbE                                                          |
| **Primitive**   | M:N "freds" over per-processor ready-queues + work stealing; idle-sleep via the Inverted Shared Ready-Stack (a benaphore); per-FD user-level lock + binary semaphore; a poller fred over `epoll`/`kqueue` |
| **Source read** | `karsten-barghi-2020.pdf` ([author preprint][pdf], same pagination as the ACM version), all 30 pages. The `libfibre` repository at `git.uwaterloo.ca` requires a login to clone and was **not** read.     |

> [!NOTE]
> The runtime is known as `libfibre`, but the paper calls its execution context
> a **fred** and the system "the fred runtime". Its supplementary-material URL
> is `cs.uwaterloo.ca/~mkarsten/fred/`. The released library is `libfibre`, and
> the authors' `memcached-1.5.7-libfibre` repository matches the paper's
> Memcached 1.5.7 port. This page describes only what the paper states; the
> internals of `libfibre`'s mutex and condition variable are not covered by the
> paper and were not available to read.

## Overview

### What it solves

Whether thread-per-session code can perform like event-driven code
([Abstract, p. 17:1][pdf]):

> This paper clearly demonstrates, for the first time, that it is possible to
> employ user-level threading for building thread-per-session applications
> without compromising functionality, efficiency, performance, or scalability.
> [...] While no other runtime exists with comparable characteristics, an
> important fundamental finding of this work is that building this runtime does
> not require particularly intricate data structures or algorithms.

The authors surveyed M:N runtimes and found that each fails at least one of
scalability, efficiency, idle-sleep, scalable I/O blocking and load balancing
(Table 1, below). The usual culprit is that "existing M:N runtimes do not
realize the full potential of user-level threading" ([§2, p. 17:4][pdf]),
either by busy-looping every system thread or by lacking user-level I/O
blocking.

### Design philosophy

Every mechanism trades latency against resource use, and the design makes the
**loaded case cheap and the idle case correct** ([§4, p. 17:5][pdf]):

> busy-looping idle processors is good for latency and throughput, but parking
> system threads during times without work (idle-sleep) is crucial for resource
> efficiency. As another example, tight control via blocking locks is good for
> resource efficiency, but hurts scalability.

The scheduler is non-preemptive "to limit complexity and to avoid reentrancy
problems with third-party libraries" ([§3, p. 17:5][pdf]). Freds resume on the
system thread where they suspended unless migrated or stolen.

## How it works

### Topology

A **cluster** is a scheduling domain of **processors** (system threads,
typically one per core) that run **freds** ([§3][pdf]). Each processor has a
local ready-queue. The cluster also has a global **staging-queue**, used for
load-based placement, application-level work sharing and "do-not-move"
background freds. A processor looks for work locally, then in the staging
queue, then by stealing around a ring of processors ([§4.1.1, p. 17:6][pdf]).
Queues are intrusive arrays of lock-free Nemesis MPSC queues, one per static
priority. Stealing therefore needs a lock to serialize consumers
([§4.3, p. 17:11][pdf]).

### Idle-sleep: the Inverted Shared Ready-Stack

The scheme is "logically [...] a semaphore, but [...] implemented like a
benaphore" ([§4.1.2, p. 17:6][pdf]). A single atomic `fred_counter` counts
ready freds in the cluster or, **when negative, the number of processors
waiting for work**. Making a fred ready is a `V()`. A processor looking for
work does a `P()` first, which **reserves** a fred before searching for it
(Algorithm 1, [p. 17:8][pdf]):

```text
EnqueueFred(f):
  if atomic_add_fetch(fred_counter, 1) > 0:  add f to local or staging queue
  else: lock; if proc_stack empty: temp_fred_list.push_back(f)   # waiter not parked yet
              else: p = proc_stack.pop(); unlock; p.resume(f)       # hand f over directly
DequeueFred(p):
  if atomic_sub_fetch(fred_counter, 1) >= 0:  loop: local / staging / steal  # reserved, will appear
  else: lock; if temp_fred_list empty: proc_stack.push(p); unlock; f = p.suspend()
              else: f = temp_fred_list.pop_front(); unlock
```

When the system is backlogged, "the overhead of this scheme is a single atomic
arithmetic instruction per enqueue or dequeue operation". Locking and OS-level
blocking happen only when the system is not fully loaded. The paper names
three races and the fix for each ([p. 17:7][pdf]):

1. A processor has decremented the counter but has not yet pushed itself on the
   stack. `temp_fred_list` holds freds for such "slow" processors.
2. A fred is popped for a processor that has not yet suspended. A **dedicated
   OS semaphore per processor** carries the resume, so a post that arrives
   before the wait is not lost. This is "ultimately more efficient than
   extending the holding time of the shared scheduler lock."
3. The counter is incremented but the fred is not yet in a queue. The dequeuer
   loops, because the fred "is effectively reserved at this point and will
   appear in one of the queues very shortly."

Parked processors form a **stack**, not a queue, "to improve the chances that
CPU cores corresponding to longer-idle processors can reach deeper idle
states." When the whole cluster is idle, wakeups, timers included, are
delegated to the I/O subsystem.

### User-level I/O blocking

Each FD gets, per direction, "a user-level lock, used to serialize access from
multiple freds, and a user-level semaphore to signal I/O readiness", stored in
a global vector indexed by FD number, which POSIX keeps compact
([§4.2, p. 17:7–8][pdf]). An I/O call first tries the non-blocking syscall.
Only when that would block does the fred wait on the readiness semaphore and
retry. Two measured refinements: a fred **yields once before every input
attempt**, which raises the first try's success rate and adds fairness, and an
FD joins the `epoll`/`kqueue` interest set **lazily**, only after its first
failed attempt.

The paper documents an edge-triggered caveat ([§4.2.1, p. 17:9][pdf]): both
`epoll` and `kqueue` re-arm an edge on _every_ I/O activity, not only on
empty↔non-empty transitions, so a concurrently run poller sees spurious
notifications. The runtime absorbs them "by using binary semaphores that
ignore repeated notifications."

### Where the poller runs

Three variants exist ([§4.2.2, p. 17:10][pdf]):

- **Thread poller**: a dedicated system thread blocks in `epoll_wait`. It is
  simple, but the kernel controls the query rate, and it was "consistently
  outperformed".
- **Fred poller** (the default): a background fred runs the event query
  "only when a system thread runs out of local work". It makes "several
  non-blocking attempts [...] (followed by yielding), but ultimately resorts to
  user-level blocking". A rarely active master thread poller watches the poller
  fred's event-FD hierarchically.
- **Multiple / direct pollers**: FDs are partitioned round-robin across several
  poller freds, which shrinks each `epoll` set and parallelizes queries. In the
  extreme, one poller per processor mimics an event loop.

**Event scopes** ([§4.2.3][pdf]) give groups of clusters separate kernel FD
tables (`clone` without `CLONE_FILES`), because `accept` cost grows with
FD-table size.

## Analysis

### State word and fast path

The scheduler's state word is the signed `fred_counter`: positive means
backlog, negative means parked processors. Both fast paths are a single
`atomic_add_fetch` or `atomic_sub_fetch`. This is a 3-state
[futex](./concepts.md#futex)-style word generalized to a count. The paper does
not specify the bit layout of its user-level mutex or the memory orders it
uses.

### Waiting: spin, yield, park

"System-level blocking operations are preceded by short spins of non-blocking
attempts to avoid suspending and resuming system threads when possible. This
applies to internal locks, event queries, and idle-sleep suspend"
([§4.3, p. 17:11][pdf]). Spin bounds are not given. For freds, waiting means
suspending onto a user-level wait list, never spinning the processor. The
measurements show why: runtimes that spin all system threads (Boost Fiber,
Qthreads) or spin-lock (Arachne) post poor efficiency, while "Pthread, Fred,
Go, and Libfiber provide effective blocking and show similar efficiency"
([§5.1.2, p. 17:14][pdf]).

### The parking substrate

Two levels. Freds park on user-level objects (mutex, condition variable,
semaphore, per-FD readiness semaphore) with timeout support ([§3][pdf]).
Processors, that is system threads, park on **one OS semaphore each**,
reached through the inverted ready-stack. The per-thread semaphore is the
"post before wait is remembered" property the scheduler's second race needs.
It is the same property a futex word or a per-thread event provides
([`linux-futex`][futex], [`parking-lot`][parking-lot]).

### Fairness, handoff and starvation

The scheduler hands work over directly: a fred arriving while processors are
parked "is directly handed over to the resumed processor, instead of being
placed in a ready-queue" ([p. 17:7][pdf]). The paper states that "there is no
expectation of service guarantees for specific freds" ([§4.1, p. 17:6][pdf]),
and the scheduler is non-preemptive, so starvation is the application's
concern. The yield-before-read rule is the one explicit fairness measure: "a
busy session cannot hog resources." The paper does not describe the mutex's
fairness policy.

### Condition variables and predicates

Condition variables exist ("mutex, condition variable, and semaphore, are
provided with timeout support", [§3][pdf]), but their algorithm is not
described. The readiness semaphores are the paper's notable predicate wait.
They are **binary**, so a stream of edge notifications collapses into one
pending signal. That is the semantics a readiness wait needs, and it is a
counter-example to a counting semaphore there.

### Footprint and layout

Measured per-connection memory: 8 KB per fred against 12 KB per pthread in the
web server, and about 16 KB per connection for the thread-per-session
Memcached against 12 KB for vanilla ([§5.2.2, §6.2.1][pdf]). Stacks can be
resizable via GCC/Clang split stacks, with "no discernible performance impact"
in preliminary tests. The per-FD synchronization vector is indexed by FD, so it
is sized by the highest open FD.

### Portability

Linux (`epoll`) and FreeBSD (`kqueue`) on x86-64, GCC or Clang. Only
Linux/GCC was evaluated. Disk I/O, which has no readiness notification on
Linux, runs on a pool of helper system threads ([§3][pdf]). The paper predates
`io_uring` in its evaluation and does not discuss it.

### Async and fiber integration

This is the paper's subject. A fred blocks on any user-level primitive or any
I/O call without blocking its processor. Readiness crosses from the kernel to
freds through the poller fred, which `V()`s per-FD semaphores, and those make
freds ready through the same `EnqueueFred` path every wakeup uses. A wakeup
from any processor therefore goes through one function, and that function
alone decides whether a parked system thread must be woken. This is the
single-funnel property a `WaitWord` wake from a foreign thread needs.

## Evaluation

All micro-benchmarks ran on the 64-core AMD machine, averaging 20 runs
([§5][pdf]).

- **Lock-heavy scheduling** (1024 loops, 32 locks, 32 cores, work unit varied;
  Fig. 3–4): Libfiber, Qthreads and Fred scale to about 25× of single-core.
  Pthread, Go and Boost follow closely, Arachne and Mordor are mediocre, and
  µC++ is poorest below 55–70 µs work units.
- **Efficiency** (N² loops, N/4 locks, 2 × 20 µs work; Fig. 5): Pthread, Fred,
  Go and Libfiber show similar cost per iteration. Boost and Qthreads are poor
  because they spin every system thread. µC++ collapses past the 16-core NUMA
  boundary.
- **Web server, 15K connections** (Fig. 6): Fred, with 8 poller freds, matches
  the event-driven ULib server. Pthread is noticeably lower, and Go is lower
  still. Mimicking Fred's I/O design in Go's runtime raised Go's throughput by
  up to 50%.
- **Connection scaling** (16 cores, up to 600K connections; Fig. 7): Fred
  tracks ULib even with one poller fred. The Pthread server stops at 30,000
  connections.
- **Linux bottlenecks** (Fig. 9): `epoll` "does not scale beyond 16 cores",
  and at 32 cores at least 4 poller freds are needed. `accept` needs at least 4
  event scopes.
- **Memcached** (Fig. 10–13): only Fred equals vanilla Memcached's efficiency
  at 1,200 connections. At higher update ratios Fred "appears to have a slight
  edge", which the authors conjecture is because "user-level locking is cheaper
  than system-level locking". Work stealing absorbs a skewed load that vanilla
  and Arachne cannot.
- **Tail latency** (Fig. 14–15): Arachne's earlier tail-latency advantage was
  **not reproduced**. With 16 RX queues all variants are similar, and at 7,680
  connections only Fred matches vanilla. Appendix B attributes the earlier
  result to too few NIC RX queues on an older kernel.

| Runtime  | Idle-sleep (Table 1) | Scalable I/O | Load balancing |
| -------- | -------------------- | ------------ | -------------- |
| Fred     | yes                  | yes          | yes            |
| Pthread  | yes                  | limited      | yes            |
| Go 12.2¹ | 1 core loop/sleep    | good         | yes            |
| Arachne  | 1 core spin          | no           | yes            |
| Boost    | all cores spin       | no           | yes            |
| Libfiber | all cores loop/sleep | no           | not tested     |

¹ As printed in Table 1; presumably Go 1.12.2.

## Relevance to Sparkles

- **(d) one funnel for every wakeup.** Fred's I/O readiness, lock release and
  timer expiry all end in `EnqueueFred`, and only that function decides whether
  a parked OS thread needs a kernel wake. A Sparkles `WaitWord` registry should
  likewise make "make this fiber ready" the single wake operation, whether the
  caller is the fiber's own loop, another loop, or a foreign thread. The
  decision to issue a syscall then lives in one place.
- **(d) count parked loops in the same word as work.** The benaphore's signed
  counter makes "is anyone parked?" free on the loaded path. That is the same
  trick as a 3-state mutex word, applied to a scheduler. An event-horizon loop
  pool can use it to skip `eventfd`/`io_uring` wake syscalls whenever no loop
  is idle.
- **(d) binary readiness, not counting.** Duplicate readiness or wake
  notifications should collapse into one pending bit. The paper shows that
  edge-triggered `epoll`/`kqueue` produce such duplicates.
- **(c) bounded spin, then park; never spin a fiber.** Spinning belongs only
  before an OS-level block of a system thread. A fiber waiting on a lock should
  suspend at once. Runtimes that spun every carrier lost on efficiency.
- **(a) the paper does not settle the mutex word.** It gives no fred-mutex
  algorithm, so it cannot inform the 1-byte parking-lot versus 3-state choice.

## Strengths

- Reaches event-driven performance with blocking code, on a production
  application (Memcached, about 5% of its code changed) as well as on
  micro-benchmarks.
- Simple, explicitly enumerated race handling for idle-sleep; the loaded path
  costs one atomic.
- An honest comparison: it reproduces and refutes a prior tail-latency result,
  and it names Linux's `epoll` and `accept` scaling limits rather than hiding
  them.

## Weaknesses

- No algorithmic detail for the user-level mutex, condition variable or
  semaphore. The sync primitives are a black box in the paper.
- Non-preemptive: one runaway fred stalls its processor's queue, and there are
  no service guarantees.
- Linux/GCC only in evaluation; `io_uring` is absent; disk I/O needs helper
  threads.
- Workarounds such as poller partitioning and event scopes trade away load
  balancing, since FDs are not valid across scopes.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                              | Trade-off                                                                     |
| ----------------------------------------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Benaphore counter: ready freds (+) or parked processors (−) | One atomic per enqueue/dequeue when loaded; locking only when idle     | Three races need side structures (`temp_fred_list`, per-processor semaphores) |
| Parked processors on a LIFO stack                           | Longer-idle cores reach deeper C-states                                | Wakeups always land on the most recently active core                          |
| Direct fred handover to a resumed processor                 | No queue round trip; no lost wakeup between pop and suspend            | Bypasses queue order                                                          |
| Per-processor OS semaphore for suspend/resume               | A post before the wait is remembered; shorter scheduler-lock hold time | One kernel object per system thread                                           |
| Binary readiness semaphore per FD direction                 | Absorbs spurious edge-triggered notifications                          | Readiness is a hint; the I/O call must retry                                  |
| Poller as a fred, run only when a processor is out of work  | Runtime controls the query rate; no busy loops; idle-sleep composes    | Notification latency depends on processors running dry                        |
| Yield once before every input attempt                       | Raises first-try success and adds fairness                             | An extra context switch per read                                              |

## Sources

- [Karsten & Barghi, "User-level Threading: Have Your Cake and Eat It Too", POMACS 4(1):17, 2020][pdf] ([DOI][doi]) — §1 contributions; §2 related work (N:1 vs M:N, Arachne, Go); §3 runtime overview (freds, clusters, processors, sync primitives with timeouts, split stacks); §4.1 ready-queues and the Inverted Shared Ready-Stack (Fig. 1, Algorithm 1); §4.2 I/O blocking, edge-triggered caveat, poller variants, event scopes; §4.3 data structures and spin-before-block; §5 micro-benchmarks (Fig. 3–9); §6 Memcached (Fig. 10–15); §7 Table 1; Appendix B Arachne reproduction.
- Related catalog pages: [`go-sync`][go-sync] (Go's runtime semaphore and netpoller, the paper's main M:N comparator), [`von-behren-2003-capriccio`][capriccio] (the earlier user-level threading runtime it cites), [`folly-sync`][folly] (`folly::fibers`, an N:1 runtime it cites), [`enberg-2019`][enberg] (the shared-nothing reply to the same Memcached comparison), [`skazhenik-2025-lightweight-locks`][skazhenik] (spin/yield/suspend policy for locks over user-level threads).

<!-- References -->

[pdf]: https://cs.uwaterloo.ca/~mkarsten/papers/sigmetrics2020-preprint.pdf
[doi]: https://doi.org/10.1145/3379483
[futex]: ./linux-futex.md
[parking-lot]: ./parking-lot.md
[go-sync]: ./go-sync.md
[capriccio]: ./von-behren-2003-capriccio.md
[folly]: ./folly-sync.md
[enberg]: ./enberg-2019.md
[skazhenik]: ./skazhenik-2025-lightweight-locks.md
