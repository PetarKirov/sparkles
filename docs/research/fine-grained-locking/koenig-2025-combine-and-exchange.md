# König, Epple & Becker 2025 — Minimize Your Critical Path with Combine-and-Exchange Locks

Delegation locking for cooperatively scheduled tasks. When a task unlocks a
contended mutex, Combine-and-Exchange Scheduling (CES) **suspends the unlocker,
re-dispatches it to the executor, and resumes the next waiter immediately on the
same thread**. Contended critical sections therefore run back to back on one
core, as under a combiner, while the work after each critical section spreads
across the other threads. The paper names the two failure modes of existing
coroutine mutexes, **queuing delay** (dispatch) and **collapse of parallelism**
(inline), and reports up to 8.1× (micro-benchmark) and 3.3× (LevelDB) gains.

|                 |                                                                                                                                 |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (arXiv preprint, cs.DC)                                                                                                   |
| **Year**        | 2025 (arXiv v1 dated 2025-11-12)                                                                                                |
| **Authors**     | Simon König, Lukas Epple, Christian Becker (University of Stuttgart)                                                            |
| **Venue**       | arXiv:2511.09194 [cs.DC] — no peer-reviewed venue at the time of reading; [abstract page][abs]                                  |
| **Language**    | C++20 coroutines (reference library); proofs of concept for Boost.Fiber and Java virtual threads                                |
| **License**     | not stated; the reference implementation "will be made publicly available upon acceptance"                                      |
| **Platforms**   | Linux 6.8: 2-socket AMD, 128 cores / 256 threads; 4-socket Intel, 64 cores; gcc 14.2.1 (clang 18.1.3 similar)                   |
| **Primitive**   | CES mutex: test-and-set-protected state + intrusive waiter queue; `unlock` is a suspension point that swaps unlocker and waiter |
| **Source read** | `koenig-2025-combine-and-exchange.pdf` ([arXiv PDF][pdf]), all 19 pages                                                         |

> [!NOTE]
> The paper's name for its mechanism is **Combine-and-Exchange Scheduling
> (CES)**, and this page uses that. The paper never abbreviates it "CXL",
> which conventionally means Compute Express Link.

## Overview

### What it solves

Coroutine mutexes inherit their design from thread mutexes, and in doing so
lengthen the program's critical path (Abstract; [§1][pdf]):

> we find that state-of-the-art userspace synchronization primitives approach
> synchronization in the userspace from the perspective of kernel-level
> scheduling. This introduces unnecessary delays on the critical path of the
> application, limiting throughput.

The paper sorts existing task-aware mutexes by what `unlock` does with the next
waiter ([§3.2][pdf]):

- **Inline schedulers** resume the next waiter _inside_ `unlock`, as a nested
  call. The paper lists cppcoro, folly's coroutines, Google's K3 and Go.
- **Dispatch schedulers** push the next waiter onto the executor's ready queue
  and return, "equivalent to `notify()`-ing a blocked thread at the OS-level".
  The paper lists Kotlin coroutines, Boost.Fiber and Tokio.

### Design philosophy

"Keep parallelizable program parts parallel and execute sequential parts as
soon as possible" ([§1][pdf]). Amdahl's law bounds throughput by the critical
path. A critical section waiting in a ready queue extends that path, however
busy the threads are ([§4][pdf]):

> It is a wide-spread intuition that a high processor utilization must also
> corresponds to high throughput, as long as threads do not busy-wait. [...] We
> aim to show that in circumstances that require queuing, it is beneficial (in
> terms of throughput) to prioritize specific types of work, and prevent them
> from ever having to wait in a ready queue.

## How it works

### The two failure modes

**Queuing delay** ([§4.1][pdf]) is "the time during which no task is in the
critical section even though at least one task is waiting to enter". With a
dispatch scheduler the lock stays `LOCKED` for the woken waiter, so no one can
[barge](./concepts.md#barging-and-handoff), while that waiter sits behind other
work in some thread's ready queue. Work stealing can shorten this but not
remove it: "A thief can only steal the task if it is inside the queue, i.e.,
already incurring queuing delay." This is the coroutine form of the
[convoy](./concepts.md#convoys) that FIFO handoff causes for threads.

**Collapse of parallelism** ([§4.2][pdf]): an inline scheduler runs the next
waiter as a nested call on the unlocker's stack. The waiter does the same for
the next one, recursively, so every contending task ends up on one thread's
stack, completing in reverse order. "Collapse of parallelism is a fundamental
problem of inline scheduling that cannot be circumvented by work-stealing",
because the stacked work is invisible to thieves. Rescheduling inside the
critical section to escape this reintroduces the queuing delay.

### CES `unlock`

`lock` is the usual task-aware lock: take an `UNLOCKED` mutex, or append the
continuation to `waiters` and suspend (Fig. 1). The change is in `unlock`
(Fig. 6, [§5][pdf]):

```cpp
void CES_mutex::unlock(current_continuation) {
  if(mutex.waiters.empty()) {
    mutex.state = UNLOCKED;
    current_continuation.resume();
  } else {
    waiter = mutex.waiters.pop_front();
    // Dispatch current task
    executor.schedule(current_continuation);
    // Immediately resume waiter
    waiter.resume();
  }
}
```

The unlocker, which has finished its sequential part, is the one that waits in
a ready queue, where any thief can take it. The waiter, whose next action is
sequential, runs with no gap. Under sustained contention every critical section
of that mutex runs on one thread. This is delegation (the combiner pattern) with
the combiner elected implicitly: "CES implicitly selects one of the contending
threads as the thread that executes all critical sections until contention
drops" ([§2][pdf]). With no waiters, `unlock` is a plain release, so
uncontended locks pay nothing.

Two assumptions are stated ([§5][pdf]): moving the code (the task) costs less
than moving the shared data, as in every delegation lock; and "the overhead of
switching the current task [...] is smaller than the queuing delay", which
holds "where no thread idles".

### Implementation

Lock and unlock must update state and queue atomically. The final
implementation "uses a test-and-set spin lock to protect the state variable and
an intrusive queue of waiters" ([§5.1][pdf]). A lock-free variant with a
three-state word (`UNLOCKED`, `LOCKED_NO_WAITERS`, pointer to the first waiter,
after cppcoro) "perform[ed] [less] reliably". The executor is NUMA-aware work
stealing over BWoS queues ([§5.3][pdf]).

### Beyond the mutex

- **Semaphore** `release(n)`: resume one waiter inline, dispatch up to `n − 1`.
- **Reader-writer mutex**: the last reader out resumes a queued writer inline. A
  writer unlocking resumes the next writer inline, or one reader inline and
  dispatches the rest.
- **Condition variable**: `notify` moves the waiter straight to the mutex's
  waiter queue if the mutex is held. This is
  [wait morphing](./concepts.md#wait-morphing), so the notified task never runs
  only to block again. If the mutex is free, the notified task is resumed
  immediately, ahead of the notifier.

## Analysis

### State word and fast path

A test-and-set spin lock guards a `state` field (`UNLOCKED`/`LOCKED`) and an
intrusive FIFO of continuations. The uncontended paths are lock-the-guard,
flip-state, unlock-the-guard. The paper does not give bit layouts or memory
orders. Its evaluated lock-free alternative, a single word holding `UNLOCKED`,
`LOCKED_NO_WAITERS` or a waiter pointer, is the same 3-state encoding as a futex
mutex, with a pointer in place of the "contended" state.

### Waiting: spin, yield, park

Tasks never spin and never block a thread. A waiting task is suspended into the
queue, and the paper criticizes TCLocks, flat combining and RCL because their
waiters "use a combination of busy-waiting and thread-level blocking" that
"wastes CPU cycles in spin-loops or system calls" ([§2][pdf]). The only spin is
the short test-and-set guard around the queue.

### The parking substrate

A waiter's continuation (the coroutine frame, the fiber, or the Java virtual
thread continuation) is the waiter record, linked intrusively into the mutex's
queue. Thread-level parking, when a worker runs out of work, is the executor's
concern and is not discussed.

### Fairness, handoff and starvation

FIFO with **direct ownership handoff**: "while the lock experiences contention,
it remains in the locked state the entire time and no other task can
'overtake' the next selected waiter" ([§3.2][pdf]). CES keeps this handoff and
changes only _where the successor runs_. The cost moves to the unlocker: "the
unlocking task's continuation might wait in the ready queue if there is a high
workload" ([§7][pdf]). Starvation of the combiner thread's own work, a known
weakness of flat combining, is avoided because the original owner of the
combining thread is itself dispatched away ([Fig. 7][pdf]). The paper states no
bound on how long one thread keeps combining.

### Condition variables and predicates

Wait morphing at `notify` time, with priority to the notified task when the
mutex is free ([§5.2][pdf]). The paper notes that preemptive implementations
also morph waits, but there the notified thread is only _scheduled_. CES runs
it immediately.

### Footprint and layout

State and guard flag plus a waiter-queue head. Waiter nodes are intrusive in
the continuation, so nothing is allocated per wait. The paper gives no byte
counts.

### Portability

Algorithmically portable to any runtime that can suspend the current task at
`unlock` and enqueue it on an executor: shown for C++20 coroutines, Boost.Fiber
and Java virtual threads. It requires a **global executor known to the
synchronization primitive** ([§3.1][pdf]). Inline-scheduling libraries such as
cppcoro deliberately lack one, which is why they resume inline.

### Async and fiber integration

This is the paper's subject. CES adds a second suspension point: `unlock` can
suspend. Callers must therefore treat `unlock` as a possible migration point.
A task may resume on another thread after releasing a lock, which matters for
thread-local state.

## Evaluation

Median of five runs ([§6][pdf]).

- **Mutex micro-benchmark** (5,000 tasks, each loop: pick a large prime, insert
  into a shared map under the mutex, factor outside; Fig. 8–9): inline
  scheduling collapses to one thread. At 256 threads, CES reaches **8.1×** the
  throughput of dispatch: 1.01 vs 0.124 Mops/s on the 2-socket machine.
- **Critical-section length** (Fig. 10): about 10× over dispatch at 256 threads
  for critical sections up to 250 ns, still about 2× at 7.5 µs, and never
  slower. In LevelDB, 95% of critical sections are under 1 µs, with a median
  under 350 ns.
- **Reader-writer mutex** (Fig. 11): 1.55× at 50% writers and 1.23× at 6.25%,
  converging because only one of several waiting readers avoids the queue.
- **Boost.Fiber** drop-in mutex (Fig. 12): at least 2× at 256 threads and never
  slower. The gain is smaller than with C++20 coroutines because stackful
  switches cost more.
- **Java virtual threads** vs `ReentrantLock` (Fig. 13): 6–18% **slower** for
  critical sections under 1 µs above 64 threads, and up to 37% faster at
  7.5 µs. The authors attribute the loss to continuation overhead fixable only
  inside the JVM.
- **LevelDB `readrandom`** (Fig. 14): slower than stock below 48 concurrent
  reads, where contention is low. Fastest above 64. At 256, **3.3×** TCLocks
  (1.41 vs 0.427 Mops/s), also ahead of ShflLock and dispatch.
- **Measured queuing delay** under dispatch (Fig. 15): at 256 concurrent reads
  the median delay is **35.5 µs**, against a median critical section of
  **319 ns**, "two orders of magnitude larger".

### Comparison with flat combining and `DistributedMutex`

| Property              | Flat combining (Hendler et al. 2010)         | folly `DistributedMutex` combining ([`folly-sync`][folly])           | CES                                                             |
| --------------------- | -------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------- |
| Unit of concurrency   | OS threads                                   | OS threads                                                           | cooperative tasks (coroutines, fibers, virtual threads)         |
| How the CS moves      | request record in a publication list         | type-erased closure in the waiter (`lock_combine(task)`)             | the whole continuation is resumed on the combiner's thread      |
| API change            | data structure rewritten around the combiner | opt-in: a closure that must not touch thread-locals or other mutexes | none: plain `lock`/`unlock`                                     |
| Combiner selection    | first thread to enter                        | the current holder, walking its contention chain                     | implicit: the thread where the last unlock happened             |
| Waiter while combined | spins (or blocks) until its result returns   | spins, then futex-sleeps, on its own cache line                      | nothing: the waiter is suspended and its thread runs other work |
| Bound on combining    | none in the scheme                           | 2 contention chains (`kMaxCombineIterations`)                        | none stated; ends when the queue empties                        |
| Combiner's own work   | delayed behind others' CSs                   | delayed (bounded by the cap)                                         | dispatched to another thread at its own unlock                  |

The CES claim over thread-level delegation is the last two rows: because a task
can be moved, neither the waiter nor the combiner's original task waits. The
cost is a task switch per handoff. That is cheap for stackless coroutines,
dearer for stackful fibers (Boost.Fiber gains less), and a loss for Java
virtual threads below 1 µs.

> [!WARNING]
> The classification of **Go** as an inline scheduler (citing a tutorial blog)
> does not match Go's source. `sync.Mutex` in normal mode wakes a waiter that
> then competes with newcomers. In starvation mode, `Unlock` calls
> `runtime_Semrelease(&m.sema, true, 2)`
> ([`internal/sync/mutex.go` L226–L232][go-mutex]), and `semrelease1` puts the
> waiter in the P's `runnext` slot and `goyield`s the unlocker onto the local
> run queue: "we now call the scheduler so that we start running the waiter G
> immediately" ([`runtime/sema.go` L265–L286][go-sema]). That is **CES's swap,
> already shipped**, in Go's starvation mode, with the unlocker stealable from
> the local queue (see [`go-sync`][go-sync]). The paper also groups folly's
> coroutines with the inline schedulers; per [`folly-sync`][folly-async],
> `coro::Mutex::unlock` resumes the waiter on the unlocking thread, but an
> awaiting `Task` then hops to its executor through `viaIfAsync` (implicit from
> a `Task`), which is dispatch behaviour, not inline.

## Relevance to Sparkles

- **(c) direct handoff for fibers should run the successor immediately.** If an
  event-horizon fiber mutex hands ownership FIFO and merely enqueues the
  successor, the lock sits idle for a full ready-queue drain. That was 35.5 µs
  of idle lock per 319 ns critical section in LevelDB. Either allow barging
  (the critical path stays short, fairness is lost) or adopt the CES swap:
  resume the successor now and requeue the unlocker. Go's starvation mode
  already does the latter. A FIFO-handoff-with-dispatch design, as in Tokio, is
  the dispatch case the paper measures losing by up to 8.1×.
- **(d) the swap needs the loop to accept "requeue me" from inside `unlock`.**
  On a completion-based loop, CES is: push the unlocker's continuation onto the
  loop's local run queue, where other loops can steal it, and switch to the
  waiter. That is only possible when the waiter is resident on the _same_ loop
  or can migrate to it. For a waiter parked on a foreign loop, a `WaitWord`
  wake has to cross loops, and the queuing delay returns.
- **(b) wait morphing pays off more with tasks than with threads**: a notified
  task that would re-block costs a full resume plus suspend, so move it to the
  mutex queue at `notify`.
- **`unlock` becomes a migration point.** Any Sparkles API that adopts CES must
  document that code after `unlock` may run on another thread. That rules it
  out for primitives used by thread-pinned code, which is the same constraint
  `DistributedMutex` places on combined closures.
- **(a)** The paper's lock-free variant is a 3-state word with a waiter
  pointer. The guard-plus-queue variant it shipped is the parking-lot shape.
  Neither result transfers to the OS-thread `sparkles.base.sync` mutex, where
  the unlocker cannot be moved.

## Strengths

- Names and measures queuing delay, a cost invisible to utilization metrics and
  two orders of magnitude larger than the critical section it delays.
- A one-line change to `unlock` with no API change: drop-in replacements for
  Boost.Fiber's mutex and Java's `ReentrantLock`.
- Delegation without its usual taxes: no closures, no dedicated server thread,
  no spinning waiters, and no starvation of the combiner's own task.
- Extends cleanly to semaphores, reader-writer locks and condition variables.

## Weaknesses

- Preprint; the reference implementation is unpublished until acceptance.
- Wins only when every worker is busy. At low contention LevelDB is slower, and
  Java virtual threads lose up to 18% on short critical sections.
- Requires a global executor and migratable tasks. The unlocker may resume on
  another thread, which breaks thread-local assumptions.
- No bound on combining duration, no fairness analysis for the requeued
  unlocker, and some prior-art classifications are questionable (Go; folly with
  an executor).
- Evaluation figures are mostly relative; absolute numbers are given only for a
  few points.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                             | Trade-off                                                                 |
| -------------------------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Suspend and re-dispatch the unlocker; resume the waiter inline | Zero queuing delay for the sequential part; the unlocker is stealable | A task switch per contended unlock; the unlocker may migrate threads      |
| Keep FIFO handoff (no barging)                                 | Waiters are served in order; no overtaking                            | Throughput depends on the swap; without it, FIFO dispatch creates convoys |
| Implicit combiner (wherever the last unlock ran)               | Delegation only under contention; no dedicated thread                 | No cap on how long one thread keeps combining                             |
| Test-and-set guard + intrusive queue                           | "more reliably" fast than the lock-free 3-state word in their runs    | A spin guard, though a very short one                                     |
| Wait morphing with priority to the notified task               | No resume-then-block round trip; the CS owner runs first              | Notifier is delayed when the mutex is free                                |
| Semaphore/RW: one waiter inline, rest dispatched               | At least one waiter avoids queuing delay                              | Gains shrink with many concurrent readers (1.23× at 6.25% writers)        |

## Sources

- [König, Epple & Becker, "Minimize Your Critical Path with Combine-and-Exchange Locks", arXiv:2511.09194, 2025][pdf] ([abstract][abs]) — §1 motivation and contributions; §2 delegation-style locks (flat combining, RCL, ffwd, TCLocks); §3 task-aware mutex, inline vs dispatch schedulers (Fig. 1–3); §4 queuing delay and collapse of parallelism (Fig. 4–5); §5 CES design (Fig. 6–7), assumptions, implementation, other primitives, the C++20 library; §6 evaluation (Fig. 8–15); §7 conclusion.
- Go source at [`015343854b5d9e2829481df30dbcae2ca6682d25`][go-sema]: [`src/runtime/sema.go`][go-sema] (`semrelease1` direct G handoff), [`src/internal/sync/mutex.go`][go-mutex] (starvation-mode unlock).
- Related catalog pages: [`folly-sync`][folly] (`DistributedMutex` combining, `coro::Mutex`), [`go-sync`][go-sync] (starvation mode, `goyield` handoff), [`tokio-sync`][tokio] (FIFO permit handoff via the waker, a dispatch scheduler), [`java-aqs`][java-aqs] (`ReentrantLock`, the Java baseline), [`queue-locks`][queue-locks] and [combining](./concepts.md#combining) (thread-level combining), [`skazhenik-2025-lightweight-locks`][skazhenik] (the spin/yield/suspend alternative for fibers).

<!-- References -->

[pdf]: https://arxiv.org/pdf/2511.09194v1
[abs]: https://arxiv.org/abs/2511.09194
[go-sema]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/sema.go#L265-L286
[go-mutex]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/sync/mutex.go#L226-L232
[folly]: ./folly-sync.md
[folly-async]: ./folly-sync.md#async-and-fiber-integration
[go-sync]: ./go-sync.md
[tokio]: ./tokio-sync.md
[java-aqs]: ./java-aqs.md
[queue-locks]: ./queue-locks.md
[skazhenik]: ./skazhenik-2025-lightweight-locks.md
