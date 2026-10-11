# Li & Zdancewic 2007 — Combining Events and Threads for Scalable Network Services

Threads as a library over an event loop. Each "monadic thread" is a lazy
trace of system-call nodes; the scheduler is an ordinary program that forces
one node, performs the call, and requeues the continuation. Blocking
synchronization — a mutex, an `MVar` — is not a kernel object or a futex but
a **scheduler extension**: a `(locked, queue-of-traces)` pair that the event
loop manipulates. The cleanest statement in the set of "a lock whose waiters
are continuations, not threads".

|                 |                                                                                                                                                                                                                        |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (PLDI '07)                                                                                                                                                                                                       |
| **Year**        | 2007 (June)                                                                                                                                                                                                            |
| **Authors**     | Peng Li, Steve (Stephan A.) Zdancewic (University of Pennsylvania)                                                                                                                                                     |
| **Venue**       | PLDI '07, ACM SIGPLAN Notices 42(6), pp. 189–199; [DOI 10.1145/1250734.1250756][doi]                                                                                                                                   |
| **Language**    | Haskell (GHC 6.5, with SMP and STM)                                                                                                                                                                                    |
| **License**     | not stated (academic paper)                                                                                                                                                                                            |
| **Platforms**   | Linux 2.6.15 (`epoll`, Linux AIO); measured on a dual Xeon (memory test) and a single-CPU Celeron 1.2 GHz (I/O tests)                                                                                                  |
| **Primitive**   | CPS concurrency monad `M a = (a -> Trace) -> Trace`; lazy `Trace` tree of `SYS_*` nodes; programmable scheduler of event loops and queues; mutex/`MVar` as scheduler-side "system calls"                               |
| **Source read** | `li-zdancewic-2007.pdf` — the ScholarlyCommons@Penn postprint ([repository item][penn], [PDF mirror][pdf]), all 20 pages (cover + 19-page preprint layout; section numbers match the proceedings, page numbers do not) |

> [!NOTE]
> The postprint's own cover sheet gives the publisher URL as
> `doi.acm.org/10.1145/1273442.1250756` (the SIGPLAN Notices issue); the
> proceedings DOI is `10.1145/1250734.1250756`. Both name the same article.
> Page references below are to the postprint's internal page numbers.

## Overview

### What it solves

The threads-versus-events stalemate for massively concurrent servers
([§1, p. 1][pdf]):

> The debate over threads and events never seems to end because a programmer
> often has to choose one model and give up the other. For example, if a
> Linux C programmer uses POSIX threads to write a web server, it is difficult
> to use asynchronous I/O. On the other hand, if the programmer uses epoll and
> AIO in Linux to write a web server, it will be inconvenient to represent
> control flow for each client.

Their diagnosis is that "conventional thread abstraction mechanisms are too
rigid: threads are implemented in the OS and runtime libraries and the user
cannot easily customize these components" — including the I/O multiplexer
and the synchronization primitives.

### Design philosophy

Take the Lauer–Needham duality (thread continuation ~ event handler,
scheduler ~ event loop, blocking call ~ send event / await reply) not as a
reason to pick one model but as a reason to have both, with the thread
abstraction and the event loop written **in the same program**
([§2.2–2.3][pdf]). They call this _application-level implementation_: the
scheduler is "a tree traversal function" written by the application, so
adding `epoll`, AIO, a TCP stack or a blocking primitive means adding a node
type and a case to the scheduler, not patching a runtime.

## How it works

### Traces and the CPS monad

A thread's run is a lazily produced tree of system calls (after Claessen's
"poor man's concurrency monad", 1999) ([§3.1–3.2, Figures 5–9][pdf]):

```haskell
data Trace = SYS_NBIO (IO Trace)
           | SYS_FORK Trace Trace
           | SYS_YIELD Trace
           | SYS_RET
           | SYS_EPOLL_WAIT FD EPOLL_EVENT Trace
           | SYS_AIO_READ FD Integer Buffer (Int -> Trace)
           | ...
newtype M a = M ((a -> Trace) -> Trace)
sys_epoll_wait fd ev = M (\c -> SYS_EPOLL_WAIT fd ev (c ()))
```

Forcing a node runs the thread to its next system call and suspends it there;
the continuation `c` is the child pointer. The scheduler "plays the active
role": it pattern-matches a node, performs the call, and puts the child trace
back on a queue. A blocking `sock_accept` is written in direct style as "try
non-blocking `accept`; on failure `sys_epoll_wait fd EPOLL_READ` and retry"
(Figure 10).

### Event loops and queues

The full system ([§4.4–4.6, Figure 14][pdf]) is several event loops, each in
its own OS thread, connected by queues:

- `worker_main` loops (several, for SMP) pop a trace from a shared ready
  queue, run it to its next system call and dispatch it. Pure segments between
  system calls are type-guaranteed to be I/O-free, so they run in parallel
  safely.
- On `SYS_EPOLL_WAIT`, the worker registers an `epoll` event whose user data
  is the continuation trace. A dedicated `worker_epoll` loop calls
  `epoll_wait` and writes each returned trace back onto the ready queue
  (Figure 16). AIO has its own loop the same way.
- `SYS_BLIO` (blocking I/O: `open`, `stat`, DNS) sends the trace to a queue
  served by a pool of OS threads.
- Exceptions are `SYS_CATCH`/`SYS_THROW` nodes; the scheduler keeps a
  per-thread handler stack.

### Synchronization

§4.7 is the part this catalog is about, quoted in full because it is the
whole design:

> For nonblocking synchronization, such as concurrent accesses to shared data
> structures, the software transactional memory (STM) provided by GHC can be
> used directly. Monadic threads can simply use `sys_nbio` to submit STM
> computations as IO operations. As long as the STM computations are
> nonblocking (i.e. without retry operations), the scheduler event loops can
> run them smoothly without being blocked.
>
> For blocking synchronization, like the producer-consumer model, that affects
> thread scheduling, we can define our own synchronization primitives as
> system calls and implement them as scheduler extensions. For example,
> mutexes can be implemented using a system call `sys_mutex`. A mutex is
> represented as a memory reference that points to a pair `(l,q)` where `l`
> indicates whether the mutex is locked, and `q` is a linked list of thread
> traces blocking on this mutex. Locking a locked mutex adds the trace to the
> waiting queue inside the mutex; unlocking a mutex with a non-empty waiting
> queue dispatches the next available trace to the scheduler's ready queue.
> Other synchronization primitives such as MVars in Concurrent Haskell can
> also be similarly implemented.

Two observations follow. A blocking STM `retry` would block the event loop
OS thread — so STM is restricted to non-blocking use. And monadic threads may
also "communicate efficiently using pipes provided by the OS", i.e. wait on
an fd through `epoll` like any other I/O.

## Analysis

### State word and fast path

The mutex is a Haskell `IORef` to `(l, q)`: a boolean and a queue of
continuations. No atomic word, no fast path distinct from the slow path — the
paper does not say how `sys_mutex` is made atomic across the SMP
`worker_main` loops (presumably an atomic `IORef` update or an `MVar`; not
stated). There is no measurement of mutex cost.

### Waiting: spin, yield, park

No spinning. A thread that finds the mutex locked is parked immediately by
appending its trace to `q`; `sys_yield` exists for cooperative yielding.
Parking a monadic thread costs nothing beyond the queue cons — the
continuation already exists as the trace's child pointer.

### The parking substrate

The waiter record **is** the thread: a continuation trace (an unevaluated
thunk, ~48 bytes with its exception stack). Waiters live in a per-mutex list
inside the mutex object. Wake-up is "dispatch the next available trace to the
scheduler's ready queue" — the same operation as any I/O completion. There is
no per-thread event, no futex and no global table; the event loop's ready
queue is the parking substrate.

### Fairness, handoff and starvation

The unlocker dequeues the next trace from `q` — FIFO by the list discipline —
and makes it runnable; whether ownership is handed off (the woken trace
already owns the mutex) or the woken thread must re-acquire (allowing
[barging](./concepts.md#barging-and-handoff)) is not specified. The scheduler
runs "a thread ... for a large number of steps before switching to another
thread to improve locality" ([§4.2][pdf]), which trades latency fairness for
throughput; there is no starvation bound or pre-emption.

### Condition variables and predicates

No condition variable is described. Blocking producer–consumer is to be
built as further scheduler extensions ("`MVar`s ... can also be similarly
implemented"); predicate waiting is left to STM, which is usable only without
`retry`. That gap is a finding: the monadic design makes a blocking STM
`retry` (the natural predicate wait) incompatible with the event loops.

### Footprint and layout

Per thread: 48 bytes measured (a trace thunk plus an exception-stack list),
10,000,000 threads in a 480 MB live set ([§5.1][pdf]). Per mutex: one
reference, a boolean and a list. All heap-allocated and garbage-collected.

### Portability

Linux-only as built: `epoll` and Linux AIO through GHC's FFI, plus an
optional user-level TCP stack fed by `iptables` queues. The architecture is
portable in principle — swap the `worker_epoll`/AIO loops for another
multiplexer — which is the paper's point about customizable schedulers.

### Async and fiber integration

Complete by construction: every blocking operation — I/O readiness, AIO
completion, a mutex, a blocking call offloaded to the thread pool — is a
continuation parked in some structure, and every wake-up is a write to the
ready queue from whichever loop observed the event (`worker_epoll`, the AIO
loop, the unlocking worker, a `SYS_BLIO` pool thread). Cross-OS-thread wakes
are therefore uniform: _any_ thread may push a continuation onto the ready
queue. What the design does not address is an external, non-monadic thread
waking a monadic one through shared memory — there is no word to wait on,
only scheduler-owned objects.

## Evaluation

Linux 2.6.15, GHC 6.5; the C comparison uses NPTL with 32 KB stacks, which
caps it near 16K threads ([§5][pdf]).

| Test                                         | Setup                                                                    | Result                                                                                       |
| -------------------------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Memory per thread                            | 10,000,000 threads looping on `sys_yield`; dual Xeon, 2 GB               | 480 MB live set after major GC — 48 bytes per thread                                         |
| Disk head scheduling (Capriccio's benchmark) | random 4 KB `O_DIRECT` reads from a 1 GB file, 512 MB total              | slightly above NPTL past 100 threads; steady to 64K threads; CPU 1% at 16K threads           |
| FIFO pipes, mostly idle                      | 128 active pairs exchanging 32 KB; many idle `epoll` waiters             | throughput ~30% higher than NPTL; GC < 0.2% of run time                                      |
| Web server vs Apache 2.0.55                  | 128K × 16 KB files, 100 MB cache, 100 Mbps link, up to 1,024 connections | "compares favorably" on the disk-bound load; CPU 70–85% (mostly system) at 1,024 connections |

The scheduler — CPS monad, system calls, event loops, queues for AIO,
`epoll`, mutexes, blocking I/O and exceptions — is 220 lines; the web server
370 lines. No synchronization-primitive benchmark is reported.

## Relevance to Sparkles

- **(d) a loop-resident waiter is a continuation in a queue.** Li &
  Zdancewic's mutex is the minimal fiber-native lock: `(locked, waiters)` with
  wake = "push the continuation onto the ready queue". The `WaitWord` registry
  needs the same wake operation — but must also accept wakes from threads that
  are _not_ the loop, which this design never faces because only scheduler
  loops touch the mutex.
- **Wake events and I/O completions share one ready queue.** `worker_epoll`
  and the mutex unlock both just enqueue a continuation; a `WaitWord` wake from
  a foreign thread should likewise become an ordinary loop completion (e.g. an
  `io_uring` `MSG_RING` or `FUTEX_WAKE` CQE), not a separate wake channel.
- **Never block the loop in a primitive.** STM is allowed only without `retry`
  because a blocking transaction would block the OS thread running the loop.
  The `sparkles.base.sync` mutex used from loop code must likewise either be
  non-blocking (`tryLock` / short critical sections) or have a fiber-aware
  slow path — the [Capriccio][capriccio] observation that cooperative
  scheduling makes uniprocessor locking "nearly free" no longer holds once
  several loops run in parallel.
- **No help for (a)–(c)**: no lock word, no condvar algorithm, no spin policy,
  and no measurement of synchronization cost.

## Strengths

- **One mechanism for all blocking**: I/O, AIO, blocking calls and locks are
  all "park a continuation, enqueue it later".
- **Tiny threads** (48 bytes) and a programmable scheduler of a few hundred
  lines.
- **SMP-safe by typing**: segments between system calls are pure, so several
  `worker_main` loops run them in parallel.
- Competitive I/O performance with NPTL and Apache on the authors' tests.

## Weaknesses

- **Synchronization is a sketch**: one paragraph, no algorithm for atomicity
  across worker loops, no condvar, no fairness statement, no numbers.
- **Blocking STM is excluded** — the natural predicate-wait mechanism does not
  fit the loops.
- **Throughput-first scheduling** (many steps per thread) with no pre-emption
  or starvation bound.
- Linux-only; I/O benchmarks on a single-CPU Celeron, so SMP lock contention
  is never exercised.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                           | Trade-off                                                                 |
| ------------------------------------------------------------ | ------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Threads as a CPS monad producing a lazy `Trace`              | No compiler or runtime change; scheduler written in the application | Every effect goes through a system-call node; Haskell-specific ergonomics |
| Scheduler = event loops + queues, one per event source       | Add `epoll`, AIO, TCP or thread pools as modules                    | Cross-loop hops add queueing latency                                      |
| Mutex as `(locked, queue of traces)` scheduler extension     | Waiters are already continuations; wake = enqueue                   | Only scheduler loops can touch it; no foreign-thread waker                |
| STM for non-blocking sharing, without `retry`                | Reuse GHC STM; never block an event-loop OS thread                  | No predicate waits via STM                                                |
| Blocking syscalls to a dedicated OS-thread pool (`SYS_BLIO`) | Keep `open`/`stat`/DNS off the loops                                | Extra queue hop and thread pool per blocking operation                    |

## Sources

- [Li & Zdancewic, "Combining Events And Threads For Scalable Network Services", PLDI '07][pdf] ([repository item][penn], [DOI][doi]) — §1 problem and hybrid model; §2 threads vs events, Lauer–Needham duality, application-level implementation; §3 traces, CPS monad, system calls (Figures 3–9); §4.1–4.3 monadic threads, round-robin scheduler, exceptions; §4.4 multiple event loops and SMP; §4.5 `epoll`/AIO loops (Figures 15–16); §4.6 blocking I/O pool; §4.7 thread synchronization; §4.8 TCP stack; §5 experiments (Figures 17–19); §6 related work (CML, Capriccio, SEDA)
- [von Behren et al. 2003, Capriccio][capriccio] — the user-level thread package whose disk benchmark this reuses
- [Reppy 1991, CML][cml] — the language-level event alternative they compare against

<!-- References -->

[pdf]: https://cse.hkust.edu.hk/~charlesz/comp610/paper/event_thread_pldi.pdf
[penn]: https://repository.upenn.edu/items/24b5fe79-5a47-447e-948e-b10b6f1e5934
[doi]: https://doi.org/10.1145/1250734.1250756
[capriccio]: ./von-behren-2003-capriccio.md
[cml]: ./reppy-1991-cml.md
