# Tardieu, Wang & Lin 2012 — A Work-Stealing Scheduler for X10's Task Parallelism with Suspension

Work stealing for a language whose tasks may block on arbitrary predicates. X10's
conditional atomic block `when (E) S` can suspend a task until another task
makes `E` true; most work-stealing runtimes either forbid that or block the
worker thread and spawn a compensating one. Tardieu et al. compile every task
into heap-migratable continuation frames, so a task that cannot proceed is
**parked as a continuation in a per-place queue** and its worker goes back to
stealing — a fixed thread pool with no thread ever blocked on a user predicate.

|                 |                                                                                                                                                                  |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (PPoPP '12)                                                                                                                                                |
| **Year**        | 2012 (February)                                                                                                                                                  |
| **Authors**     | Olivier Tardieu (IBM T.J. Watson Research Center), Haichuan Wang (University of Illinois at Urbana-Champaign), Haibo Lin (IBM Research – China)                  |
| **Venue**       | PPoPP '12: 17th ACM SIGPLAN Symposium on Principles and Practice of Parallel Programming, pp. 267–276; [DOI 10.1145/2145816.2145850][doi]                        |
| **Language**    | X10 2.2 (compiler pass + runtime library in X10), C++ backend; compared with Cilk++ and Java fork/join                                                           |
| **License**     | engine shipped in the X10 distribution under the Eclipse license (per §7)                                                                                        |
| **Platforms**   | 16-way x86-64 blade, 4× AMD Opteron 8347 HE (1.9 GHz), 24 GB, RHEL 5.6                                                                                           |
| **Primitive**   | compiler-generated cactus-stack frames; work-first deques; per-place queue of continuations suspended on `when`; thief/victim `tryLock` on the victim's deque    |
| **Source read** | `tardieu-2012-x10-work-stealing.pdf` — the ACM version (copy hosted on an Inria course page, [PDF][pdf]), all 10 pages; no open-access repository copy was found |

> [!NOTE]
> This survey's reading list gave this paper by DOI alone. Crossref resolves
> `10.1145/2145816.2145850` to Tardieu, Wang & Lin, "A work-stealing scheduler
> for X10's task parallelism with suspension"; Dice, Marathe & Shavit's "Lock
> Cohorting", which sits beside it in the same proceedings (pp. 247–256), is
> `10.1145/2145816.2145848`. The content is
> about scheduling, not lock design; it enters this catalog for how it
> waits on predicates without blocking threads.

## Overview

### What it solves

Work-stealing runtimes are fast because they constrain synchronization ([§1,
p. 267][pdf]):

> Java fork/join tasks may only use synchronization classes that are advertised
> to cooperate with fork-join scheduling. These restrictions are deemed
> necessary to make work-stealing effective and its implementation tractable.
> In contrast, X10 permits arbitrary task synchronizations, adopts a
> determinate exception semantics, and makes no connection between task and
> method boundaries.

The standard X10 runtime (XRX) copes by blocking: "if a task suspends on a
`when` construct (conditional atomic block) the scheduler suspends the worker
thread and allocates or wakes another thread in its pool to compensate for the
decrease in parallelism" ([§2, p. 268][pdf]). The goal is Cilk-like performance
for Cilk-like code with full-language support at "limited and predictable
overhead."

### Design philosophy

Make every task resumable from the heap. A compiler pass rewrites methods into
frame classes (one per scope, locals become fields, a `pc` field records the
re-entry point) so that "a runtime [can] queue a continuation for later
execution without sacrificing a thread. As a consequence, our runtime uses a
fixed number of threads … and a unified approach, where continuations are used
to implement both `finish` and `when`" ([§2, p. 268][pdf]).

## How it works

### Frames, deques and the work-first policy

Each scope gets a `Frame` subclass linked by `up` into a cactus stack; a worker
entering an `async` saves the `pc` of the statement after it and pushes the
enclosing frame on its deque (work-first, as in Cilk), runs the child, then
`pop`s. If the continuation was stolen, `pop` throws the singleton `STOLEN`
exception and the worker returns to stealing ([§4.2, pp. 270–271][pdf]). The
deque is "essentially a replica of the deque of Java's fork/join framework."
A fast clone (inlined, stack-allocated frames) runs normally; the slow clone
(frame helper methods) runs only when a thief resumes a stolen frame ([§5.3][pdf]).

### Thief–victim synchronization

Frames are speculatively allocated on the worker's thread stack, so a steal
must copy them to the heap ([§5.5, p. 272][pdf]):

> A thief grabs a lock (`tryLock`) on the victim's deque before attempting to
> steal. If the lock is acquired and the steal is successful, it keeps the lock
> while copying the frames. This prevents another thief from interfering with
> the copy. The victim when it fails to pop the stolen continuation acquires
> and releases the lock, hence ensuring that the copy is complete before
> trashing its stack.

The `finish` counter is shared and atomically updated, but §5.4 restructures it
to count only stolen-and-unfinished subtasks plus one for the non-stolen rest:
"these atomic operations are only required from thieves and victims. In
particular, if a single worker executes a finish body in its entirety, then no
counting ever takes place."

### Suspension on `when`

The predicate wait is a scheduler-side queue, one per place ([§6.1, pp. 272–273][pdf]):

> In order to cope with `when` constructs, our scheduler maintains in each place
> a queue of suspended continuations. Concretely, when a worker encounters a
> `when` statement whose condition evaluates to false, it saves the index of the
> `when` statement in the `pc` field of the current frame and pushes this frame
> to the extra queue. It then aborts its computation and switches to the idle
> state in which it will look for something else to run in the usual way.
> Dually, when a worker exits an atomic block, it grabs a lock on the extra
> queue and moves its entire content to its own deque, which will eventually
> lead to the re-evaluation of the condition of each suspended task.

Because the suspending worker's own deque may still point at stack frames, it
first "steals" all of its own deque into a second, heap-only **extra deque**
using the thieves' protocol, then aborts. Idle workers drain their extra deque
before stealing; thieves try a victim's extra deque before its normal one.

### Distribution

`at (p) S` is handled the same way: migrate the deque to the extra deque, ship
an at-frame to place `p`, abort; idle workers "not only try to steal from
collocated workers but also listen for incoming continuations from other
places" ([§6.2][pdf]). A remote `finish` uses a proxy object to coalesce counter
updates.

## Analysis

### State word and fast path

There is no lock word in the paper's own design. The X10 `atomic`/`when`
statements execute "as if in a single step during which all other concurrent
activities in the same place are suspended" ([§3][pdf]); how that atomicity is
implemented is not described in this paper. The
paper's own locks are the per-deque lock taken with `tryLock` by thieves and
the lock guarding each place's suspended-continuation queue.

### Waiting: spin, yield, park

A waiting **task** never spins or blocks: it is converted to a continuation and
queued. A waiting **worker** (an idle thread) runs the `findContinuation` loop —
"pseudo-random selection of a victim, attempt to steal from the victim's deque,
break if successful, continue if not" ([§4.2.1][pdf]) — an unbounded steal
spin; no backoff or sleep policy is described.

### The parking substrate

The per-place queue of suspended continuations (heap frames with a saved `pc`).
There is no per-predicate or per-address keying: every `when` in a place shares
one queue.

### Fairness, handoff and starvation

None for predicate waits: every atomic-block exit moves _all_ suspended tasks
back into runnable deques to re-evaluate their conditions — a
[thundering herd](./concepts.md#thundering-herd) by construction, and no
ordering among waiters whose conditions become true together. Stealing is
randomized; no starvation bound is claimed.

### Condition variables and predicates

The paper's center of gravity for this catalog. `when (E) S` is a predicate
wait with no explicit signal: the wake-up trigger is "any atomic block in this
place finished," and the waiter re-checks `E`. That matches the language rule
that "changes to `E` outside of atomic sections might not trigger the execution
of `S`" ([§6.1][pdf]), i.e. only atomic sections can make a `when` ready. It is
the same shape as nsync's or Abseil's `Await` (re-evaluate predicates on
release) but at place granularity rather than per mutex; see
[nsync](./nsync.md) and [abseil-mutex](./abseil-mutex.md).

### Footprint and layout

Not a lock-layout paper. Frames are speculatively stack-allocated and copied to
the heap only on steal, freed with `free` when popped ([§5.5][pdf]).

### Portability

The engine is X10 source plus a compiler pass, pluggable into both the C++ and
Java backends; the performance optimizations (uninitialized fields, stack
frames) need C++-backend support. The continuation approach also lets X10 run
on systems "without support for dynamic thread creation, such as IBM's
BlueGene/P" ([§2][pdf]).

### Async and fiber integration

Fully continuation-based: tasks are stackless (compiler-generated frames), and
both local predicate waits and remote completions re-enter the scheduler as
runnable continuations. Cross-place wakeups arrive as messages that idle
workers poll for. There is no OS-level parking and no external event loop.

## Evaluation

Micro-benchmarks (Fibonacci, Integrate, QuickSort) in X10, Cilk++ and Java
fork/join, and 6 of 19 PBBS programs ported from Cilk++; 1–16 workers;
averages of 10 runs ([§7][pdf]).

| Measurement                                    | Result                                                                               |
| ---------------------------------------------- | ------------------------------------------------------------------------------------ |
| Speedup at 16 workers, Integrate               | Cilk++ 15.8, X10 work-stealing 13.9, Java fork/join 9.0 (Figure 1)                   |
| X10 work-stealing vs standard X10 (16 threads) | Fib(40) 700× faster, Integrate(1536) 300×, QuickSort(10M) 60×                        |
| Sequential overhead (1 worker vs sequential)   | X10 "achieves the best result with overheads ranging from 7x to 28%" (Figure 3)      |
| PBBS at 16 workers                             | X10 and Cilk++ "comparable and often very close. Neither runtime wins" (Figure 4)    |
| Sequential X10 vs C++                          | X10 up to 40% slower; the work-stealing transformation adds up to 30% in a few cases |
| Exception support                              | disabling it gains at most 10%                                                       |

No benchmark exercises `when` or `at` — the comparison targets cannot express
them — so the cost of the suspension path is unmeasured.

## Relevance to Sparkles

- **Question (d).** This is the "continuation queue" end of the registry design
  space: a waiter that cannot proceed is turned into runnable-later work and
  its worker thread keeps going. The `WaitWord` analogue is a queue of fiber
  handles that a waker moves onto a run queue — here onto the waker's _own_
  deque, from which idle workers steal, so wakeups need no cross-thread
  signal into an event loop.
- **What not to copy:** one queue per place and "wake everyone on every atomic
  exit" is correct but O(waiters) per release; a keyed registry (per address or
  per predicate object) avoids the herd. The XRX fallback — block the worker
  and spawn a compensating thread — is the other anti-pattern.
- **Self-steal before suspending** is a useful trick for stackful fibers too:
  before a worker parks a fiber, make every reference into stack-local state
  heap-safe, or the waker resumes onto a dead stack.

## Strengths

- Arbitrary task suspension (`when`, `at`) inside a work-stealing scheduler on a
  fixed thread pool, with no blocked threads.
- Cilk-competitive performance on fork-join code despite the generality.
- `finish` counting that touches shared atomics only when steals happen.

## Weaknesses

- The suspension path is not evaluated at all.
- Predicate waits re-evaluate every suspended task in the place after every
  atomic block: no keying, no fairness, thundering herd.
- Unbounded steal spinning for idle workers; no sleep policy.
- Depends on a whole-program compiler transformation (with a buggy call graph,
  §6.5) and C++-backend extensions.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                  | Trade-off                                                          |
| ---------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------ |
| Compile tasks into heap-resumable frames with a saved `pc` | Any task can suspend without holding a thread              | Code-size and run-time overhead of generated continuations         |
| Speculative stack allocation, copy to heap on steal        | Common no-steal path pays almost nothing                   | Thief–victim lock on every steal; suspension must self-steal first |
| One per-place queue of `when`-suspended continuations      | Simple; matches "only atomic blocks change conditions"     | Every atomic exit re-runs every waiter's predicate                 |
| Waker moves suspended tasks onto its own deque             | Wakeup is just scheduling; other workers steal the surplus | Re-evaluation work lands on the waker first                        |
| `finish` counts only stolen subtasks plus one              | Atomics only on steal paths                                | More complex counting protocol                                     |

## Sources

- [Tardieu, Wang & Lin, "A Work-Stealing Scheduler for X10's Task Parallelism with Suspension", PPoPP '12][pdf] ([DOI][doi]) — §1 motivation; §2 related work and the XRX compensating-thread design; §3 X10 `async`/`finish`/`at`/`atomic`/`when`; §4 frames, deques, worker loop, generated code; §5 optimizations (selective transformation, inlining, `finish` out-degree, speculative stack allocation with thief `tryLock`); §6 `when` suspension, distribution, exceptions, asynchronous initialization; §7 evaluation (Figures 1–5); §8 conclusion
- [Li & Zdancewic 2007][li-z] — another scheduler where blocking synchronization is a run-queue operation
- [Capriccio (von Behren et al. 2003)][capriccio] — stackful user-level threads, the contrasting approach

<!-- References -->

[doi]: https://doi.org/10.1145/2145816.2145850
[pdf]: https://people.bordeaux.inria.fr/gaupy/ressources/teachings/2021/algo_hpc/articles-2021/x10.pdf
[li-z]: ./li-zdancewic-2007.md
[capriccio]: ./von-behren-2003-capriccio.md
