# Koval, Khalanskiy & Alistarh 2023 — CQS: A Formally-Verified Framework for Fair and Abortable Synchronization

A waiter queue built like a fast concurrent queue rather than like a lock. Two
`Fetch-and-Add` counters index a logically infinite array of cells; `suspend()`
claims the next cell and parks a waiter in it, `resume(v)` claims the next cell
and hands `v` to whoever is (or will be) there. Cancellation clears a cell in
`O(1)` and unlinks whole segments of cancelled cells, so millions of abortable
coroutine waiters cost nothing when they leave. Shipped as the core of
`kotlinx.coroutines`' `Semaphore` and `Mutex`; this page doubles as the
`kotlinx-coroutines-sync` subject.

|                 |                                                                                                                                                                                                             |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (PLDI 2023) + production implementation (`kotlinx.coroutines`)                                                                                                                                        |
| **Year**        | 2023 (June); arXiv v1 2021-11-22, v2 2023-05-20                                                                                                                                                             |
| **Authors**     | Nikita Koval (JetBrains Research), Dmitry Khalanskiy (JetBrains), Dan Alistarh (IST Austria)                                                                                                                |
| **Venue**       | Proc. ACM Program. Lang. 7(PLDI), pp. 244–266; [DOI 10.1145/3591230][doi]                                                                                                                                   |
| **Language**    | pseudocode (Kotlin-like); implementations in Kotlin (coroutines) and Java (threads); proofs in Coq/Iris                                                                                                     |
| **License**     | paper: arXiv non-exclusive; `kotlinx.coroutines`: Apache-2.0                                                                                                                                                |
| **Platforms**   | JVM (OpenJDK 15) on 4× Intel Xeon Gold 6150, 144 hardware threads; the Kotlin library is multiplatform (JVM, Native, JS, Wasm)                                                                              |
| **Primitive**   | `CancellableQueueSynchronizer`: FAA-indexed segment list of cells; `suspend()`/`resume(v)`; simple vs smart cancellation; async vs sync resumption                                                          |
| **Source read** | `koval-2023-cqs.pdf` — [arXiv:2111.12682v2][arxiv], all 53 pages (body + Appendices A–F); `kotlinx.coroutines` at [`bd2e9a1`][kx-tree] (`Semaphore.kt`, `Mutex.kt`, `ConcurrentLinkedList.kt`) read in full |

> [!NOTE]
> The PLDI paper is published in PACMPL 7(PLDI) (DOI `10.1145/3591230`), not in
> a separate proceedings volume. The copy read here is arXiv v2, which carries
> the full appendices (synchronous resumption, segment removal, progress proofs,
> the Iris outline) that the 23-page journal version points to. Section and
> listing numbers below are arXiv v2's.

## Overview

### What it solves

Fair (FIFO) and abortable blocking synchronization, at a generality that
previously only Java's `AbstractQueuedSynchronizer` offered, and with
coroutines as the target ([abstract, p. 1][arxiv]):

> Supporting such semantics is critical given the rising popularity of
> constructs for asynchronous programming, such as coroutines, which abort
> frequently and are cheaper to suspend and resume compared to native threads.

The authors' diagnosis of `AbstractQueuedSynchronizer` ([§1, p. 2][arxiv]) is
that cancellation is a linear search: "One naive way to implement such
functionality is by linearly searching the waiting queue for the corresponding
segment, which is then unlinked [3]. … While for threads this approach is
sufficient (since their number is small and they rarely abort), for coroutines,
of which millions can exist at the same time and which cancel frequently,
significant complexity improvements are required."

### Design philosophy

Separate the **counter** that decides _whether_ to wait from the **queue** that
holds waiters, and make both `Fetch-and-Add`-driven. A primitive is a few lines
of counter logic over CQS; the mutex is the canonical example ([Listing 3, §2][arxiv]):

```kotlin
var state: Int = 1                 // 1 = unlocked, w <= 0: locked, -w waiters
fun lock()   { s := FAA(&state, -1); if s > 0: return; cqs.suspend() }
fun unlock() { s := FAA(&state, +1); if s < 0: cqs.resume(Unit) }
```

A second principle is that `resume` may run **before** the matching `suspend`
("as long as it is known that `suspend()` will happen eventually"): the value
is parked in the cell and `suspend` returns it without blocking, exactly like
`unpark` before `park` ([§2, p. 4][arxiv]). The race between the counter
update and the enqueue therefore never needs a lock.

## How it works

### Cells and counters

`suspend()` does `i := FAA(&suspendIdx, +1)` and CASes the current waiter
into `cells[i]`; on failure a value is already there, so it takes it and marks
the cell `TAKEN`. `resume(v)` does `i := FAA(&resumeIdx, +1)`; if the cell is
empty it CASes `v` in and returns ("elimination"), otherwise it reads the
waiter, marks the cell `RESUMED` and unparks it ([Listing 2][arxiv]). The
infinite array is emulated by a Michael–Scott-style list of fixed-size
segments, each with an `id`; the paper's benchmarks use 64 cells per segment
([§6, p. 13][arxiv]), the shipped library 16 ([`SEGMENT_SIZE`][kx-sem-const]).

### Simple and smart cancellation

A cancelled waiter's cell becomes `CANCELLED`. In **simple** mode the `resume`
that reaches it fails, and the primitive restarts: for the mutex, "the
`unlock()` invocation … incremented the counter (which must have been
decremented by a `lock()` operation earlier). Thus, the balance is met, and
`unlock()` should restart" ([§3.1][arxiv]). The cost is `Θ(N)` failed resumes
for `N` cancelled waiters, "amortized by `Thread.cancel()` invocations."

**Smart** mode lets cancellation take effect immediately: the cancellation
handler calls the primitive's `onCancellation()` (for the mutex, `FAA(&state,
+1)`), and `resume` skips `CANCELLED` cells. The naive version double-grants
the lock (Figure 3); the fix is a `REFUSE` state ([§3.2][arxiv]):

> This state signals that an operation attempted to abort, but determined that
> there is an upcoming `resume(..)` and the aborted waiter was the last one in
> the CQS. Thus, the `resume(..)` that inevitably visits the cell should be
> refused by CQS and will no longer attempt to pass the value to any waiter.

`onCancellation()` returns `true` (cell → `CANCELLED`, skippable) or `false`
(cell → `REFUSE`; the arriving `resume` calls `completeRefusedResume(v)`, which
for a mutex does nothing because the permit already went back into `state`, and
for a blocking pool re-inserts the element). When `resume` meets a waiter
whose cancellation is still in flight (`THREADCANCELLED`), it **delegates**: it
CASes its value into the cell and leaves; the handler's `GetAndSet` then finds
the value and completes or refuses it ([Listing 6][arxiv]). A permit is never
lost and never duplicated.

### Synchronous resumption and `tryLock`

Asynchronous resumption leaves "permits" in cells, so a `tryLock()` that only
looks at `state` can fail while a permit sits unclaimed (Figure 10). Synchronous
mode makes `resume` wait a bounded number of spins for `suspend` to take the
value, then CAS the cell to `BROKEN`; both sides then fail and restart
([Appendix A, Listing 10–11][arxiv]). The mutex becomes
`tryLock = CAS(&state, 1, 0)` with `lock`/`unlock` wrapped in retry loops.

### Segment removal in `O(1)`

Each segment packs `(pointers, cancelled)` in one word; it is logically removed
when every cell is cancelled and neither `suspendSegm` nor `resumeSegm` points
at it. Physical removal links the nearest alive neighbours through `prev`/`next`
and re-checks they are still alive; the tail segment is never removed, so ids
stay unique ([Appendix B.2, Listing 14][arxiv]). Memory is `O(N + T)` for `N`
live waiters and `T` threads (cells in `REFUSE` pin their segment until the
pending `resume` arrives).

### The shipped `kotlinx.coroutines` implementation

`Semaphore` and `Mutex` share `SemaphoreAndMutexImpl` ([`Semaphore.kt`][kx-sem-impl]).
Its in-source state machine is the paper's cell life-cycle
([`Semaphore.kt` L98–L124][kx-sem-fsm]), and it ships the **simple + synchronous**
corner of the design space, not smart cancellation:

- `release()` loops: `getAndIncrement`; if the old value was `>= 0` there is no
  waiter; otherwise `tryResumeNextFromQueue()`, restarting when it returns
  `false` ([L242–L262][kx-sem-release]).
- `tryResumeNextFromQueue` does `getAndSet(i, PERMIT)`; on `null` it spins
  `MAX_SPIN_CYCLES` (default 100) waiting for `TAKEN`, then breaks the cell; on
  `CANCELLED` it returns `false` ([L313–L337][kx-sem-resume]).
- A cancelled acquirer's segment simply stores `CANCELLED` and calls
  `onSlotCleaned()` ([L381–L386][kx-sem-cancel]); the permit balance is restored
  by `release`'s retry, as in the paper's simple mode.
- The waiter cell holds the `CancellableContinuation` itself; the segment is
  installed as the continuation's cancellation handler without allocating a
  closure, an optimisation explained in
  [`ConcurrentLinkedList.kt` L195–L201][kx-cll-handler].

`Mutex` adds an `owner` field on top of a 1-permit semaphore
([`Mutex.kt` L130][kx-mutex-impl]); `unlock` spins while the owner of a just-
granted lock is still `NO_OWNER` (`// <-- ATTENTION, BLOCKING PART HERE`,
[L212][kx-mutex-spin]) — the one place a coroutine waits on another without
suspending.

## Analysis

### State word and fast path

One `Int` counter per primitive: permits when positive, the negated number of
waiters when not ([`_availablePermits`][kx-sem-state]). The uncontended
`acquire` is one `getAndDecrement` (`FAA`) and a sign test; `release` is one
`getAndIncrement`. The paper attributes its 4× win over Java's `Semaphore` in
the no-wait regime to exactly this: Java "has to perform this update in a CAS
loop," while CQS lets the counter go negative ([§6.3, p. 14][arxiv]). The
library's `tryAcquire` is still a CAS loop (it must not go negative). The paper
assumes sequential consistency and SC-DRF ([§2, §5.1][arxiv]); the JVM code uses
`atomicfu` volatile atomics throughout.

### Waiting: spin, yield, park

None in the acquire path: a losing `acquire` goes straight to
`suspendCancellableCoroutineReusable`. The only spins are on the releasing side
— the bounded `MAX_SPIN_CYCLES` rendezvous wait of synchronous resumption, and
`Mutex`'s owner-field spin. CQS is a [parking](./concepts.md#parking) design
with no [spinning](./concepts.md#spinning) phase for the waiter; for coroutines
"the native thread never blocks" because the worker picks up another coroutine
([§1][arxiv]).

### The parking substrate

A per-primitive segment queue whose cells hold the waiter object itself — a
`Thread` in the paper's Java build, a `CancellableContinuation` or a select
instance in Kotlin. There is no global table, no futex, no per-thread event: the
"park" is whatever the waiter's runtime does (`LockSupport.park`, or returning
`COROUTINE_SUSPENDED` to the dispatcher), abstracted by `park(onCancel)` /
`unpark(result)` with unpark-before-park semantics ([Listing 1][arxiv]). Waiter
records are heap objects; the queue's memory is bounded by live waiters.

### Fairness, handoff and starvation

Strict FIFO with **direct handoff**: `release` gives its permit to the cell at
`resumeIdx`, so no newcomer can barge past a queued waiter while the counter is
negative ([barging and handoff](./concepts.md#barging-and-handoff)). A newcomer
that arrives when the counter is positive takes the permit directly, which is
the only reordering. The cost is visible in the evaluation: "Java's unfair
mutex and semaphore are predictably faster, as unfairness significantly reduces
context switches under high contention" ([§6.3][arxiv]) — the
[convoy](./concepts.md#convoys) price of handoff. FIFO is argued classically;
the Iris proofs explicitly do not cover it ([§5.1, Limitations][arxiv]).

### Condition variables and predicates

Not provided. CQS builds barriers, count-down latches (`DONE_BIT` in the
waiter counter), semaphores and blocking pools; the barrier ignores
cancellation because no system can "atomically resume a set of waiters"
([§4.1][arxiv]). A condition variable is absent from both paper and library —
Kotlin code waits on predicates through channels and `StateFlow`. Fair
readers–writer locks are named as future work ([§8][arxiv]).

### Footprint and layout

Per primitive: two `AtomicRef` segment pointers, two `Long` indices, the `Int`
counter, plus (for `Mutex`) an owner reference — several dozen bytes before the
first segment, far from a 1-byte or 4-byte lock word. Each segment is an object
with `id`, `prev`, `next`, a packed `cleanedAndPointers` word
(`POINTERS_SHIFT = 16`, [L209–L224][kx-cll-segment]) and an array of 16 cell
references. The design assumes GC; "hazard pointers [23] or hazard eras [24]
can be used in environments without GC" ([§2, p. 4][arxiv]).

### Portability

Pure user-space atomics (`CAS`, `GetAndSet`, `FAA`) over whatever suspension the
host provides. The Kotlin library compiles the same `common` sources for JVM,
Native, JS and Wasm. No OS primitive is involved at this layer.

### Async and fiber integration

This is the paper's native habitat: a waiter is a continuation, cancellation is
a first-class event with a handler, and `resume` may come from any thread. The
library's `acquire` is `suspend fun`; a resume from a foreign thread simply
completes the continuation, whose dispatcher reschedules it. The **prompt
cancellation guarantee** closes the remaining gap ([`Mutex.kt` L46][kx-mutex-prompt]):
if a waiter is cancelled after it was resumed but before it ran, the permit is
handed back through `onCancellationRelease` ([`Semaphore.kt` L149][kx-sem-onrel]),
so cancellation never leaks a permit.

## Evaluation

JMH on OpenJDK 15, 144 hardware threads; work between operations geometrically
distributed; CQS segment size 64 ([§6][arxiv]). All results are for **threads**
as waiters, chosen to favour Java's implementation.

| Benchmark                                     | Result                                                                                                                           |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Barrier (Figure 5)                            | tracks a spinning counter baseline; Java's `CyclicBarrier` scales far worse (it uses a lock internally)                          |
| Count-down latch (Figure 6)                   | up to 4× faster than Java's (§6.2; the introduction says 7×); Java decrements in a CAS loop                                      |
| Semaphore, threads ≤ permits (Figure 7)       | up to 4× faster than fair and unfair Java `Semaphore`                                                                            |
| Semaphore, high contention                    | up to 90× faster than fair Java `Semaphore`; on par with unfair Java at ≥16 permits                                              |
| Mutex (permits = 1)                           | all fair locks (CQS, fair `ReentrantLock`, CLH, MCS) equal; unfair Java faster                                                   |
| Blocking pools (Figure 8)                     | up to 100× faster than fair `ArrayBlockingQueue` (§6.4; the introduction says 150×); up to 10× over unfair queues at ≥8 elements |
| Cancellation, queue of 1–1000 waiters (Fig 9) | CQS flat in queue size; 1.9× faster than `AbstractQueuedSynchronizer` on an empty queue, 65× with 1000 waiters                   |
| Synchronous resumption overhead               | "negligible and does not affect results"                                                                                         |

The concurrent-cancellation comparison was abandoned because
`AbstractQueuedSynchronizer` "gets into a deadlock in its internal
`cleanQueue()` function" ([§6.5][arxiv]). Progress (Appendix D): `suspend` and
`resume` are wait-free without cancellation; with smart cancellation and
asynchronous resumption `resume` is lock-free; with synchronous resumption the
semaphore is only obstruction-free and `resume` can block on a cancelling cell.
The Coq proofs span about 8000 lines for CQS and 300–700 per primitive
([§5.1][arxiv]); they live on the [`cqs-proofs` branch][proofs].

## Relevance to Sparkles

- **Question (d), the `WaitWord` registry.** CQS is the most complete answer in
  the catalog to "fibers wait in a queue that another thread drains": an
  `FAA`-indexed cell array gives FIFO order without a queue lock, resume-before-
  suspend removes the enqueue race, and the waiter object is opaque (a fiber
  handle would do). It is a per-object queue, though, not a keyed registry: it
  does not answer "wait on an arbitrary address," which a
  [parking-lot](./parking-lot.md)-style hashed table does.
- **Cancellation without losing permits** is the transferable result. Either
  pay `Θ(N)` in the releaser (simple mode, what `kotlinx.coroutines` actually
  ships) or adopt the `REFUSE`/delegation protocol (smart mode). An event-loop
  fiber whose timeout or cancellation races a cross-thread wake hits exactly
  this; the "permit returned after resume but before run" path
  (`onCancellationRelease`) is a third case a `WaitWord` must cover.
- **Question (c), fairness.** The data says strict FIFO handoff costs context
  switches for a mutex even when waiters are cheap coroutines; CQS wins on
  semaphores and pools, not on the single-permit lock. That argues for a barging
  thread mutex with fair queues reserved for counting primitives.
- **Question (a).** The design is GC-dependent (segments reclaimed by the
  collector) and the per-object footprint is large; in `@nogc` D the segments
  would need an epoch or hazard scheme the paper only names.

## Strengths

- `O(1)` uncontended cancellation and constant-memory queues under mass
  cancellation — the property coroutine runtimes need and AQS lacks.
- Counter + queue separation makes each primitive a few lines; FAA everywhere on
  the contended path.
- Machine-checked safety proofs (Iris/Coq), modular per primitive; the authors
  report the formalization "identified subtle correctness issues in our
  implementation, notably w.r.t. cancellation semantics" ([§8][arxiv]).
- In production in one of the most widely used coroutine libraries.

## Weaknesses

- FIFO and progress are not mechanized; only safety is.
- Proofs assume sequential consistency; release–acquire is future work.
- Requires GC (or an unspecified reclamation scheme) for segments and cells.
- Large per-primitive footprint; segment allocation on the slow path.
- Smart cancellation is intricate (four extra cell states); the shipped code
  chose the simpler mode, so the paper's headline cancellation path is not what
  runs in `kotlinx.coroutines`.
- Fair handoff gives no advantage for a single-permit mutex in the evaluation.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                      | Trade-off                                                                         |
| -------------------------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Counter (`FAA`, may go negative) separate from waiter queue    | One atomic on the fast path; no CAS retry loop                 | `tryAcquire` needs a CAS loop and synchronous resumption to stay correct          |
| `FAA`-indexed infinite array of cells, segments of 16–64 cells | FIFO without a queue lock; scales like LCRQ-style queues       | Segment allocation and GC pressure; non-trivial segment-list maintenance          |
| Resume may precede suspend (value parked in cell)              | Removes the counter/enqueue race for free                      | Permits can sit "unattended" in cells, breaking naive `tryLock`                   |
| Simple cancellation (`resume` fails, caller retries)           | Trivial handler; `O(1)` cancel                                 | Releaser pays `Θ(N)` for `N` cancelled waiters; cancellation takes effect late    |
| Smart cancellation with `REFUSE` and delegation                | Cancellation takes effect immediately; `resume` never fails    | Four extra cell states; user must supply `onCancellation`/`completeRefusedResume` |
| Synchronous resumption with bounded spin then `BROKEN`         | Never leave a permit in a cell; enables `tryLock`/`tryAcquire` | Releaser spins (100 iterations by default); semaphore only obstruction-free       |
| Direct FIFO handoff                                            | No starvation; matches documented fairness                     | Convoys: unfair locks win the mutex benchmark                                     |

## Sources

- [Koval, Khalanskiy & Alistarh, "CQS: A Formally-Verified Framework for Fair and Abortable Synchronization", arXiv:2111.12682v2][arxiv] ([PLDI 2023 / PACMPL DOI][doi]) — §1 motivation and AQS critique; §2 basic CQS (Listings 1–3) and segments; §3 simple and smart cancellation (Figures 2–4, Listings 4–6); §4 barrier, latch, semaphore, pools; §5 Iris proofs and progress; §6 evaluation (Figures 5–9); App. A synchronous resumption; App. B segment removal (Listing 14); App. C semaphore and pools; App. D progress; App. E proof outline
- [`kotlinx.coroutines` at `bd2e9a1`][kx-tree] — [`Semaphore.kt`][kx-sem-impl] (cell state machine, `acquire`/`release`, `tryResumeNextFromQueue`, `SemaphoreSegment`), [`Mutex.kt`][kx-mutex-impl] (owner field, fairness and prompt-cancellation docs), [`ConcurrentLinkedList.kt`][kx-cll-segment] (segment list, `remove`, packed pointer/cleaned counter)
- [CQS proofs, `cqs-proofs` branch][proofs] — the Coq/Iris development
- [Lea 2005, `java.util.concurrent` synchronizer framework][java-aqs] — the `AbstractQueuedSynchronizer` CQS is measured against
- [Li & Zdancewic 2007][li-z] — an earlier "waiters are continuations" lock

<!-- References -->

[arxiv]: https://arxiv.org/abs/2111.12682v2
[doi]: https://doi.org/10.1145/3591230
[proofs]: https://github.com/Kotlin/kotlinx.coroutines/tree/970ef8c280dd8b934b3e89f78266e9b68b1a1290
[kx-tree]: https://github.com/Kotlin/kotlinx.coroutines/tree/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync
[kx-sem-impl]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Semaphore.kt#L90
[kx-sem-fsm]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Semaphore.kt#L98-L124
[kx-sem-state]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Semaphore.kt#L139-L147
[kx-sem-onrel]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Semaphore.kt#L149
[kx-sem-release]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Semaphore.kt#L242-L262
[kx-sem-resume]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Semaphore.kt#L313-L337
[kx-sem-cancel]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Semaphore.kt#L381-L386
[kx-sem-const]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Semaphore.kt#L390-L395
[kx-mutex-prompt]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Mutex.kt#L46
[kx-mutex-impl]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Mutex.kt#L130
[kx-mutex-spin]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/sync/Mutex.kt#L212
[kx-cll-handler]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/internal/ConcurrentLinkedList.kt#L195-L201
[kx-cll-segment]: https://github.com/Kotlin/kotlinx.coroutines/blob/bd2e9a1b90400fb7b2fa4f8731e7d8148799ab73/kotlinx-coroutines-core/common/src/internal/ConcurrentLinkedList.kt#L209-L224
[java-aqs]: ./java-aqs.md
[li-z]: ./li-zdancewic-2007.md
