# ZIO (Scala)

A zero-dependency Scala library for asynchronous and concurrent programming whose effect type `ZIO[R, E, A]` is interpreted as a tree of instructions by a hand-written, trampolined fiber runtime — a _monadic effect system_, **not** an algebraic-effects/delimited-continuation runtime like [Koka] or [OCaml effects].

| Field         | Value                                                                                        |
| ------------- | -------------------------------------------------------------------------------------------- |
| Language      | Scala 2.12 / 2.13 / 3 (JVM, Scala.js, Scala Native)                                          |
| License       | Apache-2.0                                                                                   |
| Repository    | [ZIO GitHub repository] (analyzed at `v2.1.26`, branch `series/2.x`)                         |
| Documentation | [ZIO documentation]                                                                          |
| Key Authors   | John A. De Goes and the ZIO Contributors (Ziverge)                                           |
| Approach      | Reified effect data tree + fiber runtime interpreter (`FiberRuntime`); not algebraic effects |

---

## Overview

### What It Solves

ZIO provides a type-safe, resource-safe, interruptible substitute for ad-hoc `Future`/thread/exception code in Scala. A `ZIO[R, E, A]` value is a _description_ of a concurrent program; nothing runs until the value is submitted to a `Runtime`. The library bakes the three most common effects — environment (`Reader`), typed errors (`Either`), and a fiber-based async runtime (`IO`) — directly into one concrete type, avoiding monad-transformer stacking.

It is included in this algebraic-effects corpus as a **contrast point**: ZIO is frequently described as an "effect system," but it does _not_ implement algebraic effects. There are no user-definable effect operations resumed by a handler via captured continuations. Instead, a fixed, closed instruction set (`FlatMap`, `Sync`, `Async`, `FoldZIO`, `Stateful`, `UpdateRuntimeFlags`, `WhileLoop`, `YieldNow`, plus the `Exit` leaves) is interpreted by a single runtime loop. See [Comparison] and [Theory & Compilation] for where this sits on the spectrum, and [Cats Effect] for the closest peer.

### Design Philosophy

ZIO is deliberately concrete and non-academic: one effect type, no higher-kinded `F[_]` abstraction, no tagless-final, no category-theory vocabulary in the public API. The runtime is treated as a performance-critical microkernel — John De Goes describes the ZIO 2.0 runtime as the first "third-generation" effect engine for Scala, rewritten around a hybrid declarative/executable encoding that tries to run effects _without_ a trampoline and only falls back to a reified stack at asynchronous boundaries ([ZIO 2.0 Released]).

---

## Core Abstractions and Types

### `ZIO[-R, +E, +A]`

The central type (`core/shared/src/main/scala/zio/ZIO.scala`) is `sealed trait ZIO[-R, +E, +A]`. A good intuition is `R => Async[Either[Cause[E], A]]`.

| Parameter           | Meaning                             | Variance      | When `Any`/`Nothing`                     |
| ------------------- | ----------------------------------- | ------------- | ---------------------------------------- |
| **R** (Environment) | Contextual services required to run | Contravariant | `Any` = no requirements                  |
| **E** (Error)       | Typed, recoverable failure          | Covariant     | `Nothing` = cannot fail                  |
| **A** (Success)     | Value produced on success           | Covariant     | `Nothing` = never returns (unless fails) |

Common aliases (`UIO`, `URIO`, `Task`, `IO`, `RIO`) specialize `R`/`E`. Effect values are immutable and referentially transparent: building a `ZIO` performs no side effects.

### Effects as a reified data tree (the real interpreter input)

The "effect as data structure" claim is concrete. In the companion object `ZIO` (around `ZIO.scala:6175`), each combinator is a `case class` node implementing `ZIO`:

```scala
// core/shared/src/main/scala/zio/ZIO.scala
private[zio] type Erased = ZIO[Any, Any, Any]

private[zio] final case class FlatMap[R, E, A1, A2](
  trace: Trace, first: ZIO[R, E, A1], successK: A1 => ZIO[R, E, A2]
) extends Continuation with ZIO[R, E, A2]

private[zio] final case class Mapped[R, E, A1, A2](
  trace: Trace, first: ZIO[R, E, A1], successK: A1 => A2
) extends Continuation with ZIO[R, E, A2]

private[zio] final case class Sync[A](trace: Trace, eval: () => A) extends ZIO[Any, Nothing, A]

private[zio] final case class Async[R, E, A](
  trace: Trace,
  registerCallback: (ZIO[R, E, A] => Unit) => Either[URIO[R, Any], ZIO[R, E, A]],
  blockingOn: () => FiberId
) extends ZIO[R, E, A]

private[zio] case class FoldZIO[R, E1, E2, A1, A2]( /* successK + failureK */ ) extends Continuation with ZIO[R, E2, A2]
private[zio] final case class Stateful[R, E, A](trace, onState: (Fiber.Runtime[E, A], Fiber.Status.Running) => ZIO[R, E, A]) extends ZIO[R, E, A]
private[zio] final case class WhileLoop[R, E, A](trace, check: () => Boolean, body: () => ZIO[R, E, A], process: A => Any) extends ZIO[R, E, Unit]
private[zio] final case class UpdateRuntimeFlags(trace, update: RuntimeFlags.Patch) extends Continuation with ZIO[Any, Nothing, Unit]
private[zio] final case class YieldNow(trace, forceAsync: Boolean) extends ZIO[Any, Nothing, Unit]
```

Crucially, the success/failure leaves are _also_ `ZIO` nodes: `sealed trait Exit[+E, +A] extends ZIO[Any, E, A]` (`ZIO.scala:6474`), with `Exit.Success[A](value)` and `Exit.Failure[E](cause: Cause[E])`. So the runtime never special-cases "values" — they are instructions like everything else. The continuation frames pushed on the fiber's stack are exactly `FlatMap`, `Mapped`, `FoldZIO`, and `UpdateRuntimeFlags`, all subtypes of `private[zio] sealed abstract class Continuation`.

### `Cause[+E]` and `Exit[+E, +A]`

`Cause[+E]` (`Cause.scala:27`) is a full failure tree, not a single exception: leaves are `Fail` (typed error `E`), `Die` (defect/`Throwable`), `Interrupt` (fiber cancellation), `Empty`, and composites `Then` (sequential) and `Both` (parallel), plus `Stackless`. This lets ZIO faithfully represent _multiple simultaneous_ failures (e.g. an error during finalization while already failing) — something a single `Throwable` cannot. `Exit[E, A]` is the terminal value of a fiber: `Success(value)` or `Failure(cause)`.

---

## How Effects Are Declared

ZIO has no algebraic "effect declaration." What looks like declaring an effect is one of:

1. **Service traits + the `R` channel.** A capability is an ordinary trait whose methods return `ZIO`, accessed from the environment via `ZIO.service` / `ZIO.serviceWithZIO`. The `R` type parameter accumulates required services as an intersection type (`UserRepository & Logger`).
2. **Lifting callbacks via `ZIO.async`.** Any callback-style API becomes an `Async` node. The signatures live in the version-specific companion (`core/shared/src/main/scala-3/zio/ZIOCompanionVersionSpecific.scala`):

```scala
// scala-3/zio/ZIOCompanionVersionSpecific.scala
def async[R, E, A](
  register: Unsafe ?=> (ZIO[R, E, A] => Unit) => Unit,
  blockingOn: => FiberId = FiberId.None
)(implicit trace: Trace): ZIO[R, E, A] =
  Async(trace, { k => register(using Unsafe)(k); null }, () => blockingOn)

def asyncInterrupt[R, E, A](
  register: Unsafe ?=> (ZIO[R, E, A] => Unit) => Either[URIO[R, Any], ZIO[R, E, A]],
  blockingOn: => FiberId = FiberId.None
)(implicit trace: Trace): ZIO[R, E, A] =
  ZIO.Async[R, E, A](trace, register(using Unsafe), () => blockingOn)
```

`asyncInterrupt` lets `register` return `Left(cancelEffect)` (run on interruption) or `Right(result)` (synchronous short-circuit). This is the foundation for integrating OS/event-loop callbacks; see [Effects and Event Loops] and [Async I/O Comparison].

---

## How Handlers/Interpreters Work

There are no handlers. There is one interpreter: `FiberRuntime`. Each fiber owns a `FiberRuntime[E, A]` instance, and the `runLoop` method _is_ the entire instruction interpreter.

### The fiber as a state machine

`final class FiberRuntime[E, A](...) extends Fiber.Runtime.Internal[E, A] with FiberRunnable` (`core/shared/src/main/scala/zio/internal/FiberRuntime.scala:30`) holds mutable per-fiber state:

```scala
// internal/FiberRuntime.scala
private val running        = new AtomicBoolean(false)
private val inbox          = new ConcurrentLinkedQueue[FiberMessage]()   // the fiber's mailbox
private var _stack         = null.asInstanceOf[Array[Continuation]]       // reified continuation stack
private var _stackSize     = 0
private var _asyncContWith = null.asInstanceOf[AsyncContWith]             // pending async continuation
private var _runtimeFlags  = runtimeFlags0
@volatile private var _exitValue = null.asInstanceOf[Exit[E, A]]
```

`_stack` is an `Array[Continuation]` grown by `pushStackFrame` / `popStackFrame` — the explicitly reified call stack that replaces JVM recursion.

### The trampolined `runLoop`

`runLoop(effect, minStackIndex, startStackIndex, currentDepth, currentOps)` (`FiberRuntime.scala:1085`) is a `while (true)` dispatch over the `cur` instruction. The dispatch is a single `match`:

```scala
// internal/FiberRuntime.scala (runLoop, abridged)
while (true) {
  cur = drainQueueWhileRunning(cur)        // process inbox (interrupts, stateful msgs)
  ops += 1
  if (ops > FiberRuntime.MaxOperationsBeforeYield && RuntimeFlags.cooperativeYielding(_runtimeFlags)) {
    inbox.add(FiberMessage.Resume(cur))    // cooperative yield: re-enqueue self
    return null
  }
  cur match {
    case success: Exit.Success[Any] => /* unwind stack, applying successK of each Continuation */
    case sync: Sync[Any]            => var value = sync.eval(); /* unwind stack */
    case flatmap: FlatMap[...]      => stackIndex = pushStackFrame(flatmap, stackIndex); cur = flatmap.first
    case fold: FoldZIO[...]         => stackIndex = pushStackFrame(fold, stackIndex);    cur = fold.first
    case map: Mapped[...]           => stackIndex = pushStackFrame(map, stackIndex);     cur = map.first
    case stateful: Stateful[...]    => cur = stateful.onState(self, Fiber.Status.Running(...))
    case async: Async[...]          => cur = initiateAsync(async.registerCallback)
                                       if (cur eq null) cur = drainQueueAfterAsync()
                                       if (cur eq null) { self._blockingOn = async.blockingOn; return null }  // SUSPEND
    case iterate: WhileLoop[...]    => /* loop body via nested runLoop, no per-iteration stack growth */
    case yieldNow: ZIO.YieldNow     => inbox.add(FiberMessage.resumeUnit); return null
    case failure: Exit.Failure[Any] => /* unwind stack to nearest FoldZIO.failureK */
    case update0: UpdateRuntimeFlagsWithin.DynamicNoBox[...] => /* patch flags, push revert frame */
    case updateRuntimeFlags: UpdateRuntimeFlags             => cur = patchRuntimeFlags(...)
    case effect => throw new MatchError(effect)
  }
}
```

Two trampoline mechanisms keep the JVM stack bounded:

- **Depth trampoline.** At entry, `if (currentDepth >= FiberRuntime.MaxDepthBeforeTrampoline) { inbox.add(FiberMessage.Resume(effect)); return null }` (`MaxDepthBeforeTrampoline = 300`). Deep recursion bounces back through the inbox instead of growing the native stack.
- **Op-count cooperative yield.** After `MaxOperationsBeforeYield = 1024 * 10` instructions, the fiber re-enqueues itself (`FiberMessage.Resume(cur)`) and returns `null`, freeing the worker thread for other fibers. Forks also yield every `MaxForksBeforeYield = 128` (`shouldYieldBeforeFork`).

`Success`/`Sync` results unwind `_stack` inline, applying `flatMap.successK(value)`, `map.successK(value)`, or `foldZIO.successK(value)`; `Failure` unwinds looking for a `FoldZIO.failureK`. This is the reified equivalent of returning through nested `flatMap` closures.

### Driving the loop: `evaluateEffect`

`runLoop` is wrapped by `evaluateEffect(initialDepth, effect0)` (`FiberRuntime.scala:403`), which restarts `runLoop` while `effect ne null`, converts non-fatal exceptions into `Cause.die`, runs child interruption on completion, and finally calls `setExitValue` (or re-enqueues `FiberMessage.Resume(exit)` if the inbox is non-empty). A `null` return from `runLoop` means "suspended; an async resumption will continue."

---

## Performance Approach

### Async suspension and resumption (the core async loop)

When `runLoop` hits an `Async` node it calls `initiateAsync(async.registerCallback)` (`FiberRuntime.scala:696`). This constructs a one-shot `AsyncContWith.Callback` and invokes the user's `register`:

```scala
// internal/FiberRuntime.scala
private def initiateAsync(asyncRegister: (ZIO.Erased => Unit) => Either[ZIO.Erased, ZIO.Erased]): ZIO.Erased = {
  val callback = new AsyncContWith.Callback(self)
  val value    = asyncRegister(callback)               // user registers their callback
  value match {
    case Left(onInterrupt)              => if (isInterruptible()) self._asyncContWith = AsyncContWith(callback, onInterrupt)
    case Right(value) if value ne null  => if (callback.compareAndSet(false, true)) return value   // synchronous result
    case _                              => if (isInterruptible()) self._asyncContWith = AsyncContWith(callback)
  }
  null   // genuinely asynchronous: suspend
}
```

If no synchronous value is available, `runLoop` returns `null` after recording `self._blockingOn`. The fiber is now **suspended**: its worker thread is released and the fiber lives only as `_stack` + `_asyncContWith` + the `inbox`.

Resumption is the load-bearing detail the original draft glossed over. The `Callback` is an `AtomicBoolean` (for at-most-once completion) and a `ZIO.Erased => Unit`:

```scala
// internal/FiberRuntime.scala (AsyncContWith.Callback)
final class Callback(fiber: FiberRuntime[?, ?]) extends AtomicBoolean(false) with (ZIO.Erased => Unit) {
  def completeZIO(effect: ZIO.Erased): Boolean =
    if (compareAndSet(false, true)) { fiber.tell(FiberMessage.Resume(effect)); true } else false
  def completeCause(cause: Cause[Nothing]): Boolean =
    if (compareAndSet(false, true)) { fiber.tell(FiberMessage.Resume(Exit.Failure(cause))); true } else false
}
```

So when an OS event loop / `Future` / `Promise` invokes the registered callback with a result, that result becomes `FiberMessage.Resume(effect)` posted into the fiber's `inbox` via `tell`. `tell` (`FiberRuntime.scala:1521`) does:

```scala
private[zio] def tell(message: FiberMessage): Unit = {
  inbox.add(message)
  if (running.compareAndSet(false, true)) drainQueueLaterOnExecutor(false)  // wake the fiber on an executor
}
```

`drainQueueLaterOnExecutor` submits the fiber (which is `Runnable` via `FiberRunnable`) to its `Executor`. When the worker runs it, `drainQueueOnCurrentThread` → `evaluateMessageWhileSuspended` matches the `FiberMessage.Resume(nextEffect)` and calls `evaluateEffect`, re-entering `runLoop` with the resumed continuation. This is the whole "register callback → enqueue `FiberMessage.Resume` → resume the fiber" cycle; nothing about it involves captured native continuations.

### `FiberMessage` — the fiber mailbox protocol

```scala
// internal/FiberMessage.scala
private[zio] sealed trait FiberMessage
private[zio] object FiberMessage {
  final case class InterruptSignal(cause: Cause[Nothing])        extends FiberMessage
  final case class Stateful(onFiber: FiberRuntime[_, _] => Unit) extends FiberMessage
  final case class Resume(effect: ZIO[_, _, _])                  extends FiberMessage
}
```

Three messages drive everything: `Resume` (async wake-up / trampoline bounce), `InterruptSignal` (cancellation), and `Stateful` (cross-fiber state queries like `addChild`, run _on_ the target fiber to avoid races). `running` (an `AtomicBoolean`) guarantees at most one thread drains a given fiber's inbox at a time, so the fiber's mutable state needs no locks.

### Work-stealing executor: `ZScheduler`

The default JVM/Native executor is `ZScheduler` (`core/jvm-native/src/main/scala/zio/internal/ZScheduler.scala`), explicitly _"Inspired by 'Making the Tokio Scheduler 10X Faster' by Carl Lerche"_ (see [Tokio]). It is a fixed pool of `poolSize = Runtime.getRuntime.availableProcessors` daemon `Worker` threads. Each `Worker` has:

- a bounded `localQueue: RingBufferPow2[Runnable](256)`,
- a `nextRunnable` single-slot fast path (LIFO hand-off, like Tokio),
- a shared `globalQueue: PartitionedLinkedQueue[Runnable]`.

`submit` enqueues onto the current worker's local queue (or the global queue if called from outside a worker), then `maybeUnparkWorker`. `submitAndYield` (used by `submitAndYieldOrThrow` during cooperative yields) tries to keep the just-yielded runnable on the _current_ thread via `nextRunnable` to avoid park/unpark churn. When a worker's queues are empty, it enters a searching state and steals from peers:

```scala
// internal/ZScheduler.scala (Worker.run, steal path, abridged)
val runnables  = worker.localQueue.pollUpTo(size - size / 2)   // steal half a victim's queue
...
if (runnable eq null) runnable = globalQueue.poll(random)
```

`isCurrentThreadInExecutor` (overridden only here) lets the runtime detect "am I already on a scheduler worker?" so that, e.g., a synchronous interrupt can run the loop inline (`interruptAs` → `drainQueueOnCurrentThread`) rather than bouncing through the executor.

### Blocking pool and auto-blocking

`ZIO.blocking(zio)` shifts execution to `FiberRef.currentBlockingExecutor`, which on JVM is `Blocking.blockingExecutor` (`core/jvm-native/src/main/scala/zio/internal/Blocking.scala`): an unbounded `ThreadPoolExecutor` (`corePoolSize = 0`, `maxPoolSize = Int.MaxValue`, `SynchronousQueue`, 60s keep-alive, threads named `zio-default-blocking`). `attemptBlocking` = `ZIO.blocking(ZIO.attempt(...))`. This keeps thread-blocking I/O off the small `ZScheduler` worker pool.

`ZScheduler` _also_ supports **auto-blocking**: when constructed with `autoBlocking = true`, a `Supervisor` thread watches per-worker `opCount`; a worker stuck on the same `Trace` location for too long is `markAsBlocking()`-ed — its queued work is shoved to the global queue and a replacement worker is spawned. Critically, the default executor uses `Executor.makeDefault(autoBlocking = false)` (`core/jvm/src/main/scala/zio/RuntimePlatformSpecific.scala:26`); auto-blocking was **disabled by default in ZIO 2.1** because of performance regressions and must be opted into via the `Runtime.enableAutoBlockingExecutor` layer. This corrects a common misconception that ZIO auto-detects blocking out of the box.

### Memory footprint

Each fiber carries `FiberRefs`, runtime flags, a `Cause`-capable error channel, a children set, and observers — richer (and heavier) than a [Cats Effect] `IOFiber`. The ZIO 2.0/2.1 rewrite narrowed the gap: the fork/join optimization that shipped in 2.1.0 reports the `ZScheduler` runtime as ~6.5x faster than the pre-optimization `series/2.x` baseline (and ~15x with `FiberRoots` disabled) per its JMH benchmarks ([Fork-Join Performance PR]), partly by avoiding the trampoline on synchronous fast paths.

---

## Composability Model

### Monadic composition

`flatMap` builds a `FlatMap` node; `for`-comprehensions desugar to nested `FlatMap`/`Mapped` trees that `runLoop` walks via the reified `_stack`.

### Structured concurrency via `Scope` and fiber parent/child links

`fork` does **not** detach a fiber globally. `ZIO#fork` → `forkWithScopeOverride(null)` → `ZIO.unsafe.fork` → `makeChildFiber`, which adds the child to the parent's `FiberScope` (`parentScope.add(...)`). When the parent finishes, `evaluateEffect` calls `interruptAllChildren()`, awaiting every child — so a fiber cannot outlive its parent unless explicitly `forkDaemon`'d (attached to `FiberScope.global`) or `forkIn(scope)`/`forkScoped` into a longer-lived `Scope`.

`Scope` (`core/shared/src/main/scala/zio/Scope.scala`) is the resource-safety primitive: `addFinalizer` registers cleanup, `close(exit)` runs finalizers in reverse, and `acquireRelease` ties a resource's lifetime to the enclosing scope. `forkScoped` interrupts the child when its scope closes (`child.addFinalizer(interrupt(fiber))`).

### Interruption model

Interruption is fully reified through `FiberMessage.InterruptSignal(cause)` and the runtime flags, not Java thread interrupts (mostly). Key mechanics:

- **Interruptibility is a `RuntimeFlag`.** `ZIO.interruptible` / `ZIO.uninterruptible` emit `UpdateRuntimeFlagsWithin(trace, RuntimeFlags.enableInterruption/disableInterruption, …)` (`ZIO.scala:3981`, `:5017`). The loop pushes a _revert_ `UpdateRuntimeFlags` frame so the flag is restored on unwind.
- **Delivery.** `interruptAsFork`/`tellInterrupt` post `InterruptSignal`. `drainQueueWhileRunning` (called every loop iteration) turns it into `cur = Exit.Failure(cause)` **only if** `isInterruptible()`; otherwise the signal is recorded and deferred until the fiber re-enters an interruptible region.
- **Waking a suspended fiber.** `processNewInterruptSignal` (`FiberRuntime.scala:958`) grabs the pending `_asyncContWith`; if there is an `onInterrupt` cleanup it schedules it, then completes the callback with the interrupt `Cause`, resuming the suspended fiber so it can finalize.
- **Cooperative.** Because interruption is checked at loop boundaries and async points, a tight uninterruptible synchronous region runs to completion — interruption is safe, not preemptive thread-killing.

### `Schedule[Env, In, Out]`

`Schedule` (`core/shared/src/main/scala/zio/Schedule.scala`) is a composable recurrence/retry policy with an abstract `type State` and a `step(now, in, state): ZIO[Env, Nothing, (State, Out, Decision)]` driver. It powers `ZIO#repeat`/`#retry`, supports combinators (`&&`, `||`, `andThen`, `jittered`), and built-ins (`recurs`, `spaced`, `exponential`, `fixed`). It is an ordinary `ZIO`-returning value — interpreted by the same runtime, not a runtime feature.

### Concurrent primitives

| Primitive   | Purpose                       | File              |
| ----------- | ----------------------------- | ----------------- |
| `Ref`       | Atomic mutable reference      | `Ref.scala`       |
| `Promise`   | Single-value async rendezvous | `Promise.scala`   |
| `Queue`     | Bounded/unbounded async queue | `Queue.scala`     |
| `Semaphore` | Concurrency limiting          | `Semaphore.scala` |
| `Hub`       | Pub/sub broadcasting          | `Hub.scala`       |
| `STM`       | Software transactional memory | `stm/`            |

`Promise.await` and `Queue.take` are themselves built on `ZIO.asyncInterrupt`, registering callbacks that are completed (via `tell(Resume(...))`) when a value arrives — the same suspension/resumption machinery described above.

### Dependency injection: `ZLayer`

`ZLayer[RIn, E, ROut]` describes how to build services. `++` composes horizontally, `>>>` vertically, `>+>` with passthrough; `ZIO#provide` / `ZLayer.make` assemble the dependency graph and verify it at compile time via macros (`internal/macros/`). DI is a _library_ feature interpreted as ordinary `ZIO`, not a runtime capability.

---

## Strengths

- **Honest, fast runtime.** A single hand-tuned interpreter (`FiberRuntime.runLoop`) with explicit trampolining, a Tokio-style work-stealing scheduler, and a dedicated blocking pool — predictable and well-optimized.
- **Typed errors via `Cause`.** The `E` channel plus the `Cause` failure tree faithfully represents typed failures, defects, interruptions, and _parallel_ failures.
- **Real structured concurrency.** Parent/child fiber links + `Scope` make fiber and resource leaks structurally hard.
- **Reified interruption.** Interruptibility as a runtime flag gives precise, region-scoped, resource-safe cancellation.
- **Batteries included.** STM, `Schedule`, streaming (ZIO Streams), `ZLayer` DI, and ZIO Test ship together.
- **No HKT prerequisite.** One concrete type; approachable error messages.

## Weaknesses

- **Not algebraic effects.** A fixed, closed instruction set with one interpreter; you cannot define a new effect operation handled by a user-supplied handler via captured continuations (contrast [Koka], [OCaml effects], [Eff]).
- **No abstraction over the effect.** Concrete `ZIO`, no tagless-final `F[_]`; code is committed to ZIO.
- **Heavier fibers** than [Cats Effect] `IOFiber` (richer per-fiber state), though much narrowed since 2.0.
- **Closed effect set.** New "channels" (beyond `R`, `E`) cannot be added; everything routes through environment/error/value.
- **Learning curve.** Three type parameters, `ZLayer` wiring, and the interruption model take time.
- **Ecosystem split.** Some Scala libraries target only Cats Effect or only ZIO; ZIO interop exists but adds friction.

## Key Design Decisions and Trade-offs

| Decision                                             | Rationale                                                                    | Trade-off                                                         |
| ---------------------------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Reified effect tree + single `runLoop` interpreter   | Full control over trampolining, fusion, tracing; no GADT/free-monad overhead | Closed instruction set; no user-defined algebraic operations      |
| Concrete `ZIO[R,E,A]` (not `F[_]`)                   | Simpler API, better errors, no HKT machinery                                 | No abstraction over effect implementation; no tagless-final       |
| `Cause` failure tree                                 | Models typed errors + defects + interrupts + parallel failures               | More complex than a single `Throwable`                            |
| Async via `Async` node + `tell(Resume(...))` mailbox | Clean callback integration; lock-free per-fiber state via `running` CAS      | Resumption is a queue hop + executor submit, not a direct call    |
| `ZScheduler` work-stealing pool (Tokio-style)        | High throughput, good locality, minimal park/unpark                          | Complex scheduler; blocking work must be shifted off it manually  |
| Auto-blocking **off by default** (since 2.1)         | Avoids the perf regressions of trace-based detection                         | Users must remember `ZIO.blocking` / `enableAutoBlockingExecutor` |
| Structured concurrency (fiber scopes + `Scope`)      | Leak-resistant, resource-safe by construction                                | `forkDaemon`/`forkScoped` needed to escape parent lifetime        |
| Interruptibility as a `RuntimeFlag`                  | Precise, region-scoped, resource-safe cancellation                           | Cooperative only; uninterruptible regions delay interruption      |

---

## ZIO 2.x runtime facts (verified)

- **ZIO 2.0** shipped a complete runtime rewrite (the `FiberRuntime` interpreter analyzed here), pitched as the first "third-generation" Scala effect engine: a hybrid declarative/executable encoding that avoids the trampoline on synchronous fast paths and reifies the stack only at async boundaries ([ZIO 2.0 Released]).
- **`ZScheduler`** is the default executor on JVM/Native, a work-stealing scheduler explicitly inspired by Tokio (per-worker local ring buffer + shared global queue + work-stealing), introduced as the default in the 2.x line ([Advances In The ZIO 2.0 Scheduler]).
- **ZIO 2.1.0** brought major fork/join improvements (its JMH `ForkJoinBenchmark` measured the `ZScheduler` runtime ~6.5x faster than the pre-optimization `series/2.x` baseline, ~15x with `FiberRoots` disabled — see [Fork-Join Performance PR]) and **disabled auto-blocking detection by default** ([Release 2.1.0]).
- Latest release at time of writing is **v2.1.26** (the revision this document was grounded against), still on Scala 2.12/2.13/3 ([Releases]).

---

## Sources

- [ZIO documentation]
- [ZIO GitHub repository] — source analyzed at `v2.1.26`
- [Runtime reference]
- [ZIO 2.0 Released] — John A. De Goes
- [Advances In The ZIO 2.0 Scheduler] — Ziverge
- [Release 2.1.0] — ZIO release notes
- [Fork-Join Performance PR] — ZIO PR #8745 (the fork/join benchmark numbers)
- [Releases] — ZIO release index
- [Tuning ZIO for high performance] — Pierre Ricadat

Related corpus docs: [Index], [Comparison], [Evolution], [Theory & Compilation], [Parallelism], [Papers], [Cats Effect], [Koka], [OCaml effects], [Eff], [Effects and Event Loops], [Async I/O Comparison].

<!-- References -->

[Cats Effect]: scala-cats-effect.md
[Koka]: koka.md
[OCaml effects]: ocaml-effects.md
[Eff]: eff-lang.md
[Index]: index.md
[Comparison]: comparison.md
[Evolution]: evolution.md
[Theory & Compilation]: theory-compilation.md
[Parallelism]: parallelism.md
[Papers]: papers.md
[Effects and Event Loops]: ../async-io/effects-and-event-loops.md
[Async I/O Comparison]: ../async-io/comparison.md
[Tokio]: ../async-io/tokio.md
[ZIO documentation]: https://zio.dev
[ZIO GitHub repository]: https://github.com/zio/zio
[Runtime reference]: https://zio.dev/reference/core/runtime/
[ZIO 2.0 Released]: https://degoes.net/articles/zio-2.0
[Advances In The ZIO 2.0 Scheduler]: https://web.archive.org/web/20251109091601/https://www.ziverge.com/post/advances-in-the-zio-2-0-scheduler
[Release 2.1.0]: https://github.com/zio/zio/releases/tag/v2.1.0
[Fork-Join Performance PR]: https://github.com/zio/zio/pull/8745
[Releases]: https://github.com/zio/zio/releases
[Tuning ZIO for high performance]: https://blog.pierre-ricadat.com/tuning-zio-for-high-performance/
