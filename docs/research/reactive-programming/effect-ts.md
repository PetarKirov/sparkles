# Effect `Stream` (TypeScript)

Effect's streaming layer: a lazy, pull-based `Stream` built on a seven-parameter `Channel`, run on the same fiber runtime as `Effect`, with typed errors, `Scope`-owned resources, and latest-wins flattening (`Stream.switchMap`) that waits for the replaced inner stream's finalizers before starting the next one.

| Field             | Value                                                                                                                                                                                          |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript                                                                                                                                                                                     |
| License           | MIT ([`LICENSE`][v4-license], "Copyright (c) 2023 Effectful Technologies Inc")                                                                                                                 |
| Repository        | [`Effect-TS/effect`][repo]: the v4 line is now on `main`; the separate `effect-smol` repository covered by the [effect-system deep-dive][ae-effect] has merged back                            |
| Documentation     | [effect.website][docs] (its `/docs/stream/…` pages are the **v3** docs, marked "You're viewing v3, a previous version of Effect") · in-repo JSDoc + [`ai-docs/`][v4-ai-stream] for v4          |
| Category          | Pull-based effectful streams on fibers                                                                                                                                                         |
| Versions surveyed | `effect@4.1.5` (tag commit `e3aca1f1`, November 20, 2026) as primary; `effect@3.22.5` (`4569dd6e`) for v3 contrasts                                                                            |
| Core abstraction  | `Stream<A, E, R>` = a `Channel` that emits non-empty arrays of `A`, fails with `E`, needs services `R`; a `Channel` is a function from an upstream `Pull` and a `Scope` to a downstream `Pull` |

> [!NOTE]
> **Scope.** This page treats Effect as a _reactive/streaming_ toolkit. The `Effect<A, E, R>` type, generators, the `FiberImpl` interpreter, the scheduler and `Layer` are covered in the [Effect effect-system deep-dive][ae-effect] (written against `effect@4.0.0-beta.75`); they are not repeated here. Sibling deep-dives in this tree: [RxJS][rxjs] (push-based observables) and [Solid 2.0 signals][solid]. The shared vocabulary is in [Concepts][concepts]; the cross-library synthesis is in [Comparison][comparison]; the umbrella is [the index][index]. The target is a stream library over Sparkles' [`event-horizon`][eh] loop.

---

## Overview

### What it solves

An `Effect` produces at most one value. A UI, a socket, a file walk or a log tail produces many, over time, with backpressure, failure and cleanup. `Stream` is Effect's answer, and its module comment states the scope directly ([`Stream.ts`][v4-stream]):

> _"A `Stream<A, E, R>` can emit many `A` values, fail with `E`, and require services `R` while it is being consumed. Streams are useful for data that is pulled in steps, such as values from collections, queues, pubsubs, schedules, callbacks, async iterables, or platform streams."_

and of the model:

> _"Streams are pull-based with backpressure and emit chunks to amortize effect evaluation. They support monadic composition and error handling similar to `Effect`, adapted for multiple values."_

Everything a stream does — waiting, forking a producer, cancelling an inner stream — is an ordinary `Effect` running on a fiber. Cancellation is therefore fiber interruption, cleanup is `Scope` finalization, and time is the `Clock` service, which is why the same `TestClock` that drives `Effect.sleep` also drives `Stream.debounce`.

### Design philosophy

- **Streams are descriptions.** Building a pipeline runs nothing; a `run*` destructor (`Stream.runForEach`, `Stream.runCollect`, `Stream.runDrain`) turns it into an `Effect`, which in turn runs only when forked.
- **One substrate.** `Stream` and `Sink` are thin wrappers over `Channel`; the `Channel` module calls itself the low-level layer: _"Streams and sinks are built on channels, so most application code uses those higher-level modules instead"_ ([`Channel.ts`][v4-channel]).
- **End-of-stream is not an error, but travels like one.** v4 introduced `Pull` and `Cause.Done`: _"`Pull` represents completion in the error channel so low-level stream consumers can distinguish ordinary failures from end-of-input and carry a leftover value when needed"_ ([`Pull.ts`][v4-pull]).
- **Structured concurrency is non-negotiable.** Every fiber a combinator forks lives in a `Scope` derived from the stream's scope; nothing a stream starts outlives the run.

---

## How it works

### The three types, v4

```ts
// packages/effect/src/Stream.ts
export interface Stream<out A, out E = never, out R = never> extends Variance<A, E, R>, Pipeable {
  readonly channel: Channel.Channel<Arr.NonEmptyReadonlyArray<A>, E, void, unknown, unknown, unknown, R>
}

// packages/effect/src/Channel.ts — a channel is a transform from upstream Pull to downstream Pull
export const fromTransform = <OutElem, OutErr, OutDone, InElem, InErr, InDone, EX, EnvX, Env>(
  transform: (
    upstream: Pull.Pull<InElem, InErr, InDone>,
    scope: Scope.Scope
  ) => Effect.Effect<Pull.Pull<OutElem, OutErr, OutDone, EnvX>, EX, Env>
) => /* … */

// packages/effect/src/Pull.ts
export interface Pull<out A, out E = never, out Done = void, out R = never>
  extends Effect<A, E | Cause.Done<Done>, R> {}

// packages/effect/src/Sink.ts
export interface Sink<out A, in In = unknown, out L = never, out E = never, out R = never> {
  readonly transform: (
    upstream: Pull.Pull<NonEmptyReadonlyArray<In>, never, void>,
    scope: Scope.Scope
  ) => Effect.Effect<End<A, L>, E, R>
}
```

The consequences, read off those signatures:

| Concept    | v4 representation                                                                 | Consequence                                                                                       |
| ---------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Chunk      | `NonEmptyReadonlyArray<A>` (v3: `Chunk<A>`); `Channel.DefaultChunkSize` is `4096` | No empty chunks on the wire; element-wise operators run inside a chunk without an effect per item |
| Step       | `Pull` — an `Effect` that yields one chunk, fails with `E`, or fails with `Done`  | A stream is consumed by calling the same effect repeatedly                                        |
| Completion | `Cause.Done<OutDone>` in the error channel                                        | Done, failure, defect and interruption all propagate along one path and are split by filters      |
| Setup      | The `transform` effect, run once with the stream's `Scope`                        | Operators allocate state (latches, queues, forked fibers) at setup, register finalizers on scope  |
| Teardown   | Closing that `Scope`                                                              | Finalizers run newest-first by default (`Scope.make("sequential")`)                               |

The migration notes record what the redesign removed: v3's `Exit<A, Option<E>>` end-of-stream encoding became `Take` and `Cause.Done` (_"v4 uses Take… Stream.flattenTake unwraps it"_), and v3's `UpstreamPullStrategy` ADT is gone — _"Select flattening and scheduling through Channel.flatMap, Channel.switchMap, or Channel.mergeAll"_ ([`effect__Stream.yaml`][v4-mig-stream], [`v3-to-v4.md`][v4-mig-renames]).

### Sequential flattening, by hand

`flatMapSequential` in [`Channel.ts`][v4-channel] shows the idiom every operator follows: pull the outer, build the inner in a child `Scope`, and close that scope when the inner signals `Done`:

```ts
// packages/effect/src/Channel.ts (abridged)
const makePull = Effect.flatMap(pull, value => {
  childScope ??= Scope.forkUnsafe(scope);
  return Effect.flatMapEager(
    toTransform(f(value))(upstream, childScope),
    pull => {
      childPull = catchHalt(pull);
      return childPull;
    },
  );
});
const catchHalt = Pull.catchDone(_ => {
  childPull = undefined;
  // the scope can be reused if the inner channel left no finalizers behind
  if (childScope.state._tag === 'Empty') return makePull;
  const close = Scope.close(childScope, Exit.void);
  childScope = undefined;
  return Effect.flatMap(close, () => makePull);
});
```

Sequential `flatMap` forks nothing: the inner pull runs on the consumer's fiber. Concurrency appears only in operators that need it (`mergeAll`, `debounce`, `buffer`, `share`), each of which forks a producer fiber into the stream's scope and hands values to the consumer through a `Queue` or `Latch`.

---

## Evaluation model

**Pull, lazy, chunked.** A `Stream` value is inert; its `transform` runs when a destructor runs, and each downstream `Pull` drives one upstream pull. Sources that are inherently push (`Stream.callback`, `Stream.fromEventListener`, `Stream.fromPubSub`, `Stream.fromQueue`) are adapted through a `Queue`: the callback offers, the stream pulls. `Stream.callback` exposes the buffer policy: _"By default it uses an 'unbounded' buffer size"_, with `strategy?: "sliding" | "dropping" | "suspend"` ([`Stream.ts`][v4-stream]).

**Pull at the boundary, push inside some operators.** Concurrent operators decouple the two sides. `Channel.mergeAll` forks a loop that pulls the outer eagerly, starts inner fibers, and has each inner `Queue.offer` into a bounded queue (`bufferSize = 16`) that the consumer `Queue.take`s ([`Channel.ts`][v4-channel]). `Stream.debounce` forks a fiber that pulls upstream `forever`, gated by a `pullLatch` the consumer opens on demand. So "pull-based" is the contract at each `Pull` boundary; between boundaries a bounded queue provides backpressure rather than strict lock-step.

**Hot sources.** A stream is cold — each run re-executes its description. Sharing is explicit:

| Primitive                                                                | Semantics (v4)                                                                                                                                                                       |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `PubSub` (`bounded`/`dropping`/`sliding`/`unbounded`, optional `replay`) | _"each active `Subscription` receives its own copy of every accepted message. Unlike a queue, subscribers do not compete for messages"_ ([`PubSub.ts`][v4-pubsub])                   |
| `SubscriptionRef`                                                        | A value plus a `PubSub.unbounded({ replay: 1 })`; `changes` is `Stream.fromPubSub(self.pubsub)` — the current value, then every committed update ([`SubscriptionRef.ts`][v4-subref]) |
| `Stream.share` / `Stream.broadcast` / `Stream.toPubSub`                  | Turn a cold stream into a hot one inside a `Scope`; `share` takes `capacity`, `strategy`, `replay` and `idleTimeToLive`, and its doc test asserts the source is acquired once        |

> [!IMPORTANT]
> `SubscriptionRef` is _not_ a conflating signal. Its hub is unbounded, so a slow subscriber of `changes` receives every intermediate value, buffered. Latest-value semantics must be added downstream (`Stream.debounce`, `Stream.switchMap`, or a `Queue.sliding(1)` hop). Contrast the [signal model][solid], where a reader sees only the current value.

---

## Composition

- **Per element**: `map`, `filter`, `mapEffect` (with `concurrency` and `unordered`), `tap`, `scan`/`scanEffect`, `changes` (dedupe with `Equal.equals`), `filterEffect`.
- **Sequencing and flattening**: `flatMap` (sequential by default; `concurrency` > 1 merges), `switchMap` (v4; latest wins), `flatten`, `concat`, `unwrap` (lift `Effect<Stream>`; the effect runs lazily on first pull, per `Channel.unwrap`).
- **Combining**: `merge` (with a `haltStrategy` of `"left"`, `"right"`, `"both"` or `"either"`), `zipLatest`, `zip`, `interleave`.
- **Gating**: `interruptWhen`, `haltWhen`, `takeUntil`, `when`. Note `Stream.when(self, test)` evaluates `test` **once** at start — _"Returns the specified stream if the given condition is satisfied, otherwise returns an empty stream"_ — so it is not a runtime toggle; a toggle is a `switchMap` over a boolean stream (see [the worked pipeline](#the-worked-pipeline)).
- **Consuming**: `Sink` folds (`Sink.forEach`, `Sink.fold`, `Sink.collect`, `Sink.reduce`, …) with leftovers; `Stream.run(sink)`, `runForEach`, `runCollect`, `runDrain`, `toPull` (hand-driven), `toPubSub`.

Every operator is a `dual` — usable as `Stream.map(s, f)` or in `s.pipe(Stream.map(f))` — and type parameters accumulate: errors union, requirements union. The v4 API renamed `Chunk`-suffixed operators to `Array` (`flattenChunks` → `flattenArray`, `bufferChunks` → `bufferArray`) and removed some specialized constructors in favour of composition (`Stream.acquireRelease` → `Stream.scoped(Stream.fromEffect(Effect.acquireRelease(…)))`) ([`effect__Stream.yaml`][v4-mig-stream]).

---

## Time and scheduling

**Clock is a service.** `Clock` is a `Context.Reference` with a default, so time needs no wiring; `Effect.sleep`, `delay`, timeouts and schedules read it ([`Clock.ts`][v4-clock]). Fibers reach the JS event loop through the `Scheduler` (covered in the [effect-system deep-dive][ae-effect]); a fiber yields cooperatively once `fiber.currentOpCount >= fiber.cache.maxOpsBeforeYield`, default `2048` ([`Scheduler.ts`][v4-scheduler]).

**`Stream.debounce` takes a fixed duration.** Its signature is `debounce(duration: Duration.Input)`, and the implementation converts it to milliseconds once, at stream setup ([`Stream.ts`][v4-stream]):

```ts
// packages/effect/src/Stream.ts — Stream.debounce (abridged)
transformPull(self, Effect.fnUntraced(function*(pull, scope) {
  const clock = yield* Clock
  const durationMs = Duration.toMillis(Duration.fromInputUnsafe(duration)) // fixed for the run
  let lastArr, cause, emitAtMs = Infinity
  const pullLatch = Latch.makeUnsafe(), emitLatch = Latch.makeUnsafe(), endLatch = Latch.makeUnsafe()

  yield* pull.pipe(                       // producer fiber: pull upstream forever
    pullLatch.whenOpen,
    Effect.flatMap((arr) => {
      emitLatch.openUnsafe()
      lastArr = arr
      emitAtMs = clock.currentTimeMillisUnsafe() + durationMs   // restart the window
      return Effect.void
    }),
    Effect.forever({ disableYield: true }),
    Effect.onError((cause_) => { /* record end, open latches */ }),
    Effect.forkIn(scope)
  )

  const sleepLoop = Effect.suspend(function loop() {
    const now = clock.currentTimeMillisUnsafe()
    const timeMs = emitAtMs < now ? durationMs : Math.min(durationMs, emitAtMs - now)
    return Effect.flatMap(Effect.raceFirst(Effect.sleep(timeMs), endLatch.await), () =>
      now < emitAtMs ? loop() : /* emit Arr.of(Arr.lastNonEmpty(lastArr)) */ …)
  })
  return Effect.suspend(() => { pullLatch.openUnsafe(); return emitLatch.whenOpen(sleepLoop) })
}))
```

Design points: the window is a _deadline_ (`emitAtMs`) rewritten by every arrival, not a timer cancelled and re-armed; the consumer's fiber sleeps toward the deadline and re-checks; only the **last element of the last chunk** survives; on upstream end the pending value is flushed before `Done`. v3 implemented the same contract with a `Handoff` and a forked `Clock.sleep(duration)` fiber per chunk, also with a fixed `Duration.DurationInput` ([v3 `internal/stream.ts`][v3-stream]).

**`Schedule`** is a stepped policy — _"Each step either stops or produces an output together with the delay before the next step"_ ([`Schedule.ts`][v4-schedule]) — used by `retry`, `repeat`, `Stream.schedule` and `Stream.repeat`. In v4 `Schedule.modifyDelay` and `Schedule.addDelay` take an **effectful** function (`(metadata) => Effect<Duration.Input, …>`), so a schedule's delay can be read from a `Ref` at each step.

**Dynamic debounce.** There is no `debounceEffect` (verified: no such export at `effect@4.1.5`). Three workable shapes:

1. **Sleep inside a switched inner** (used below): `Stream.switchMap(q => Stream.unwrap(Effect.gen(function* () { yield* Effect.sleep(yield* Ref.get(ms)); … })))`. A new element interrupts the sleeping inner, which _is_ debouncing; the delay is read per element. A change to `ms` affects the next keystroke, not a window already running.
2. **Restart on either input**: switch over `Stream.zipLatest(query, SubscriptionRef.changes(ms))`, so changing `ms` also restarts the pending window with the new value.
3. **Re-create the operator**: `SubscriptionRef.changes(ms).pipe(Stream.switchMap(d => source.pipe(Stream.debounce(d))))` — correct only if `source` is hot (a `PubSub`/`SubscriptionRef`), since each switch re-subscribes.

---

## Concurrency and cancellation

**Interruption is cooperative and awaited.** `Fiber.interrupt`: _"The returned Effect completes only after the interrupted fiber has completed."_ and _"Interruption is cooperative. A fiber can continue running while it is inside uninterruptible work or finalizers."_ ([`Fiber.ts`][v4-fiber]). Interruption lands at effect boundaries (each `flatMap` step, each `yield*`); finalizers registered with `onExit`/`onInterrupt`/`ensuring`/`acquireRelease` run in an uninterruptible region. `Effect.uninterruptible` defers a pending interrupt until the region ends; `Effect.interruptible` reopens a window inside one; `uninterruptibleMask` gives `restore` for fine-grained regions ([`Effect.ts`][v4-effect]).

**Switch semantics — the new inner waits for the old inner's finalizers.** `Stream.switchMap` is `Channel.switchMap`, which is `mergeAll({ concurrency: 1, switch: true })`. The relevant loop in `mergeAll` ([`Channel.ts`][v4-channel]):

```ts
// packages/effect/src/Channel.ts — mergeAll (abridged, switch mode)
const channel = yield * pull; // next outer element
const childScope = Scope.forkUnsafe(forkedScope);
const childPull = yield * toTransform(channel)(upstream, childScope); // (1) set up new inner

while (fibers.size >= concurrencyN) {
  // (2) evict the old inner
  const [fiber, fiberScope] = Iterable.headUnsafe(fibers);
  fibers.delete(fiber);
  yield * Fiber.interrupt(fiber); //     awaits its exit + finalizers
  yield * Effect.ignoreCause(Scope.close(fiberScope, Exit.interrupt()));
}

const fiber =
  yield *
  childPull.pipe(
    // (3) only now start the new inner
    Effect.tap(() => Effect.yieldNow),
    Effect.flatMap(value => Queue.offer(queue, value)),
    Effect.forever({ disableYield: true }),
    Effect.onError(/* close childScope with the exit, publish failures */),
    Effect.forkChild,
  );
```

So, verified in source: (1) the new inner's _transform_ (setup) runs first; (2) the old fiber is interrupted and `Fiber.interrupt` blocks until its `onError` has closed its scope; (3) the new inner's first pull starts after that. Finalizer failures of replaced inners are discarded (`Effect.ignoreCause`). The test suite pins this: _"finalizes inner streams that are replaced before they start"_ asserts that when inner `3` starts, inners `1` and `2` are already finalized ([`Stream.test.ts`][v4-stream-test]). Stream-level `switchMap` flattens chunks first (`Channel.flattenArray`), so it switches per element, not per chunk. In v3, `Stream.flatMap(f, { switch: true })` reached `channel.mergeMap` with `MergeStrategy.BufferSliding()`; the old inner was cancelled by completing a `Deferred` it raced against, and the new inner was forked under `withPermits(1)`, so it started only once the old one released its permit after `Effect.scopedWith` closed its scope ([v3 `internal/stream.ts`][v3-stream], [v3 `internal/channel.ts`][v3-channel]).

> [!WARNING]
> Not every latest-wins helper waits. `FiberHandle.run`: _"Replacement requests interruption of the previous fiber without waiting for its cleanup"_ ([`FiberHandle.ts`][v4-fiberhandle]); the `Atom` runtime's cancel calls `fiber.interruptUnsafe()` fire-and-forget ([`Atom.ts`][v4-atom]). Await-old-finalizers is a property of `Stream.switchMap`, not of Effect generally.

**CPU-bound work cannot be interrupted mid-computation.** A synchronous `Effect.sync(() => hashAll())` is one step; interruption is noticed after it returns. Options, in increasing strength:

- **Slice and yield**: loop in `Effect` steps with `Effect.yieldNow` between slices (the scheduler also yields every 2048 ops); each yield is an interruption point. Still blocks the JS thread per slice.
- **Callback with cancel**: `Effect.callback((resume, signal) => …)` — _"an `AbortSignal` that is aborted if the fiber is interrupted… Return an optional cleanup effect from the registration function to run if the fiber is interrupted."_ ([`Effect.ts`][v4-effect]). In `internal/effect.ts` the cleanup is pushed as an `AsyncFinalizer` frame that aborts the controller and runs `onCancel` uninterruptibly while the fiber unwinds, so `Fiber.interrupt` — and therefore the next `switchMap` inner — waits for it ([`internal/effect.ts`][v4-internal-effect]). `Effect.promise(signal => …)` is the same with the caveat that _"the underlying asynchronous operation only stops if it observes that signal."_
- **Worker offload**: `effect/workers` (`Worker`, `WorkerRunner`, `@stability unstable`) and RPC over workers. The RPC protocol carries an `Interrupt` message from client to server (`FromClient = Request | Ack | Interrupt | Eof`, [`RpcMessage.ts`][v4-rpcmessage]), and the server interrupts the handler fiber ([`RpcServer.ts`][v4-rpcserver]). The handler still runs JS: a tight synchronous loop in the worker sees neither the message nor the interrupt until it yields. Hard cancellation means a shared-memory flag the loop polls, or `worker.terminate()`.

---

## Errors and completion

`Exit<A, E>` is `Success` or `Failure` carrying a `Cause<E>`. v4 flattened `Cause`: _"In v4, `Cause<E>` has been flattened to a simple wrapper around an array of `Reason` values"_, with `type Reason<E> = Fail<E> | Die | Interrupt` ([`migration/cause.md`][v4-mig-cause], [`Cause.ts`][v4-cause]). The three kinds map cleanly onto a D design:

| Reason      | Meaning                                       | Stream behaviour                                                                                              |
| ----------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `Fail<E>`   | Expected, typed error                         | Terminates the stream with `E`; recover with `Stream.catch`, `catchTag`, `retry(schedule)`, `orElse…`         |
| `Die`       | Defect (thrown exception, `Effect.die`)       | Not in `E`; `Stream.catch` skips it (_"Causes containing defects skip typed recovery"_); `catchCause` sees it |
| `Interrupt` | Cancellation, with the interruptor's fiber id | Propagates as a failure cause; `Cause.hasInterruptsOnly` lets cleanup code ignore pure cancellation           |
| `Done`      | Not a `Reason` — a `Cause.Done` value in `E`  | Normal completion of a `Pull`/`Queue`; `Pull.catchDone`, `Pull.filterDone` separate it from real failures     |

A stream fails at most once and then stops: there is no `onError`-and-continue. Per-element failure that should not end the pipeline is modelled as data — `Effect.exit` or `Effect.catch` inside the inner, producing a `Result`/tagged value (the worked pipeline does this). Inside `mergeAll`, a child's failure and any finalizer failure are combined (`Exit.asVoidAll`) and published to the output queue _"before releasing the permit or opening the latch, so the outer channel cannot complete ahead of them"_ ([`Channel.ts`][v4-channel]).

---

## State and sharing

| Primitive                                           | Role                                                                                                                                                                                               |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Ref<A>`                                            | _"holds one value and exposes reads, writes, and atomic transformations as effects"_ ([`Ref.ts`][v4-ref]); no notification                                                                         |
| `SynchronizedRef<A>`                                | `Ref` with effectful updates serialized by an internal `Semaphore`                                                                                                                                 |
| `SubscriptionRef<A>`                                | Serialized updates (_"Updates are serialized so only one change is applied at a time"_) plus a replay-1 hub; the bridge from imperative UI state into a stream ([`SubscriptionRef.ts`][v4-subref]) |
| `Queue<A, E>`                                       | `bounded` (suspend), `sliding`, `dropping`, `unbounded`; carries an error type and ends with `Queue.end` → `Cause.Done` ([`Queue.ts`][v4-queue])                                                   |
| `PubSub<A>`                                         | Broadcast with the same four strategies plus `replay`                                                                                                                                              |
| `TxRef`, `TxQueue`, `TxPubSub`, `TxSubscriptionRef` | The STM family (v3's `T*` renamed)                                                                                                                                                                 |

**v4 reactivity modules (verified present).** `effect/reactivity` ships `Reactivity`, `Atom`, `AtomRegistry`, `AtomRef`, `AsyncResult`, `Hydration`, `AtomHttpApi` and `AtomRpc`, all `@stability unstable`; framework bindings are separate packages `@effect/atom-react`, `@effect/atom-solid`, `@effect/atom-vue` ([`MIGRATION.md`][v4-migration] lists `reactivity` among the unstable modules; there is no `effect/unstable/…` path any more). What they are:

- **`Reactivity`** — _"Process-local invalidation for connecting writes to dependent reads. This module does not cache values itself."_ Keys are registered, `mutation` invalidates keys on success, `query`/`stream` re-run an effect when its keys change ([`Reactivity.ts`][v4-reactivity]).
- **`Atom`** — a signal-style graph: _"The registry runs atom reads, remembers current values, tracks dependencies between atoms, starts effects and streams, and cleans up atoms that are no longer used"_ ([`Atom.ts`][v4-atom]). An atom built from an `Effect` or `Stream` exposes an `AsyncResult`; on recompute the previous fiber is cancelled with `interruptUnsafe()` (not awaited), and the atom shows `AsyncResult.waitingFrom(previous)` — stale-while-revalidate.
- **`Atom.debounce`** uses raw `setTimeout`/`clearTimeout`, not the `Clock` service, so `TestClock` does not control it. It is the one timing operator in the tree that escapes the virtual clock.

The split is instructive: `Stream` is the pull-based, backpressured pipeline; `Atom` is the push-based, glitch-free current-value graph for UI binding; `SubscriptionRef.changes` and `Atom` constructors from streams are the bridges. This mirrors the [RxJS][rxjs]-vs-[signals][solid] split this survey compares.

---

## Lifetime and ownership

- **`Scope`**: _"A scope is a lifetime boundary. Code can register cleanup effects on it, and closing the scope runs those cleanups with the `Exit` value that ended the work… By default, closing a scope runs finalizers one at a time, most recently registered first"_ ([`Scope.ts`][v4-scope]). Every stream run has one; operators fork child scopes (`Scope.forkUnsafe`) per inner stream and close them on `Done`, failure, or replacement.
- **Fiber supervision**: `Effect.forkChild` (v3 `fork`) attaches the child to the parent — _"when the parent fiber terminates, the child fiber will be terminated as well… This behavior is called 'auto supervision'"_. `forkScoped`/`forkIn` hand ownership to a `Scope`: _"The scope owns the fiber, not the forker… Closing the scope from another fiber interrupts it and waits for completion, including finalizers."_ `forkDetach` (v3 `forkDaemon`) opts out ([`Effect.ts`][v4-effect], [`migration/forking.md`][v4-mig-forking]). All four take `{ startImmediately, uninterruptible }` in v4.
- **Stream resources**: `Stream.scoped`, `Stream.ensuring`, `Stream.onExit`, and `Effect.acquireRelease` lifted with `Stream.fromEffect`; the release receives the `Exit`, so it can tell completion from interruption.
- **Gotcha** documented on `forkIn`: _"A fiber that closes its own scope is not interrupted or awaited by that close. An uninterruptible fiber can delay scope closure."_

---

## Testing

**`TestClock`** (`effect/testing`) replaces the `Clock`: _"Instead of waiting for real time to pass, `sleep` and methods implemented in terms of it schedule effects to take place at a given clock time. Use `adjust` and `setTime` to move clock time, and all effects scheduled to take place on or before that time will automatically run in order"_ ([`TestClock.ts`][v4-testclock]). Implementation details that matter for a port:

- Sleeps are a list sorted by deadline; equal deadlines wake in registration order.
- `adjust` pops each due sleep, advances time to _that sleep's_ deadline, opens its latch, then **waits until the woken fibers go idle** before the next one — a `TrackingScheduler` counts tasks scheduled while waking (`WakeTracker.pending`). Hence the gotcha: _"The ordered execution of sleeps registered after multiple scheduler hops requires fibers running under `layer`"_.
- Two live-clock watchdogs log warnings: a test that sleeps without advancing (_"A test is using time, but is not advancing the test clock"_) and a woken fiber that never suspends.

**`@effect/vitest`**: `it.effect` runs the body `Effect.scoped` with `TestEnv = Layer.mergeAll(TestConsole.layer, TestClock.layer())` provided ([`internal.ts`][v4-vitest]); `it.live` uses the real services; `it.effect.prop` adds property tests. The debounce tests show the pattern — fork the consumer, schedule offers with `Effect.sleep` + `forkScoped`, then `TestClock.adjust` and `Fiber.join`:

```ts
// packages/effect/test/Stream.test.ts — "should drop earlier chunks within waitTime" (abridged)
const fiber =
  yield *
  pipe(
    coordination.stream,
    Stream.chunks,
    Stream.debounce(Duration.seconds(1)),
    Stream.runCollect,
    Effect.forkScoped,
  );
yield * coordination.offer; // t=0     [1]
yield *
  pipe(
    Effect.sleep(Duration.millis(500)),
    Effect.andThen(coordination.offer),
    Effect.forkScoped,
  ); // [3,4]
yield *
  pipe(
    Effect.sleep(Duration.seconds(2)),
    Effect.andThen(coordination.offer),
    Effect.forkScoped,
  ); // [5]
yield *
  pipe(
    Effect.sleep(Duration.millis(2500)),
    Effect.andThen(coordination.offer),
    Effect.forkScoped,
  ); // [6,7]
yield * TestClock.adjust(Duration.millis(3500));
deepStrictEqual(yield * Fiber.join(fiber), [
  [3, 4],
  [6, 7],
]);
```

One `adjust(3500)` replays four scheduled offers and three debounce windows deterministically. ([`Stream.test.ts`][v4-stream-test])

---

## The worked pipeline

Use case: a query field → debounce N ms (N adjustable at runtime) → hash a file set on a worker with latest-wins cancellation → show results; a toggle enables/disables the whole thing. Effect `4.1.5` API; the worker side is sketched in comments.

```ts
import { Data, Effect, Fiber, Stream, SubscriptionRef } from 'effect';

interface Hit {
  readonly path: string;
  readonly hash: string;
}
type View =
  | { readonly _tag: 'Disabled' }
  | { readonly _tag: 'Idle' }
  | { readonly _tag: 'Hashing'; readonly query: string }
  | {
      readonly _tag: 'Done';
      readonly query: string;
      readonly hits: ReadonlyArray<Hit>;
    }
  | {
      readonly _tag: 'Failed';
      readonly query: string;
      readonly message: string;
    };

class HashError extends Data.TaggedError('HashError')<{
  readonly message: string;
}> {}

// One request = one async effect. Interruption runs the returned cleanup (uninterruptibly)
// before the fiber's exit is reported, so the next switchMap inner starts after it.
const hashOnWorker = (worker: Worker, query: string) =>
  Effect.callback<ReadonlyArray<Hit>, HashError>(resume => {
    const id = crypto.randomUUID();
    const cancel = new Int32Array(new SharedArrayBuffer(4)); // polled by the worker's hash loop
    const onMessage = (ev: MessageEvent) => {
      if (ev.data.id !== id) return;
      worker.removeEventListener('message', onMessage);
      resume(
        ev.data.ok
          ? Effect.succeed(ev.data.hits)
          : Effect.fail(new HashError({ message: ev.data.error })),
      );
    };
    worker.addEventListener('message', onMessage);
    worker.postMessage({ id, query, cancel: cancel.buffer });
    return Effect.sync(() => {
      Atomics.store(cancel, 0, 1); // cooperative stop in the worker
      worker.removeEventListener('message', onMessage);
    });
  });

export const makeSearch = (render: (v: View) => void) =>
  Effect.gen(function* () {
    const query = yield* SubscriptionRef.make('');
    const debounceMs = yield* SubscriptionRef.make(200);
    const enabled = yield* SubscriptionRef.make(true);
    const worker = yield* Effect.acquireRelease(
      Effect.sync(
        () =>
          new Worker(new URL('./hash-worker.js', import.meta.url), {
            type: 'module',
          }),
      ),
      w => Effect.sync(() => w.terminate()),
    );

    // Inner stream for one query: sleep (= debounce), announce, hash, report.
    const search = (q: string): Stream.Stream<View> =>
      Stream.unwrap(
        Effect.gen(function* () {
          yield* Effect.sleep(yield* SubscriptionRef.get(debounceMs)); // N read per keystroke
          return Stream.concat(
            Stream.succeed<View>({ _tag: 'Hashing', query: q }),
            Stream.fromEffect(
              hashOnWorker(worker, q).pipe(
                Effect.map((hits): View => ({ _tag: 'Done', query: q, hits })),
                Effect.catchTag('HashError', e =>
                  Effect.succeed<View>({
                    _tag: 'Failed',
                    query: q,
                    message: e.message,
                  }),
                ),
              ),
            ),
          );
        }),
      );

    const pipeline: Stream.Stream<View> = SubscriptionRef.changes(query).pipe(
      Stream.changes,
      Stream.switchMap(q =>
        q === '' ? Stream.succeed<View>({ _tag: 'Idle' }) : search(q),
      ),
    );

    const view: Stream.Stream<View> = SubscriptionRef.changes(enabled).pipe(
      Stream.changes,
      Stream.switchMap(on =>
        on ? pipeline : Stream.succeed<View>({ _tag: 'Disabled' }),
      ),
    );

    const fiber = yield* view.pipe(
      Stream.runForEach(v => Effect.sync(() => render(v))),
      Effect.forkScoped, // owned by the caller's Scope
    );

    return {
      setQuery: (q: string) => SubscriptionRef.set(query, q),
      setDebounce: (ms: number) => SubscriptionRef.set(debounceMs, ms),
      setEnabled: (on: boolean) => SubscriptionRef.set(enabled, on),
      fiber,
    };
  });

// UI glue: const handle = Effect.runFork(Effect.scoped(Effect.flatMap(makeSearch(render), …)))
// input.oninput = (e) => Effect.runFork(api.setQuery(e.target.value))
// unmount: Effect.runFork(Fiber.interrupt(handle))  -> closes the scope: render loop, inners, worker
```

**Trace, per event** (N = 200 ms, real or `TestClock` time):

1. **Mount.** `forkScoped` starts the render fiber. `changes(enabled)` replays `true` (replay-1 hub); the outer `switchMap` forks inner `pipeline`, which subscribes to `changes(query)` and receives `""`; the inner `switchMap` emits `Idle` → `render(Idle)`.
2. **t = 0, key "a".** `setQuery("a")` publishes to the hub (serialized by the ref's semaphore). The `mergeAll` loop of the query `switchMap` pulls `"a"`, sets up `search("a")` in a fresh child scope, finds no live inner (the `Idle` inner ended with `Done` and removed itself from the fiber set), and forks the new inner. Its first pull runs `Stream.unwrap`'s effect: `SubscriptionRef.get` → 200, `Effect.sleep(200)` registers on the `Clock`.
3. **t = 120, key "ab".** The loop pulls `"ab"`, sets up `search("ab")`, then `Fiber.interrupt`s the `"a"` inner: the sleep is cancelled at its async boundary, the inner's `onError` closes its (empty) scope, `Fiber.interrupt` returns. Only then does the `"ab"` inner fork and sleep 200 ms. Nothing was rendered for `"a"` — the sleep _is_ the debounce.
4. **User sets N = 500 at t = 200.** Stored; the running `"ab"` window keeps 200 (shape 1 of [dynamic debounce](#time-and-scheduling)); keystrokes from here on wait 500.
5. **t = 320.** The sleep ends; the inner emits `Hashing("ab")` (offered into the 16-slot queue; the render loop's `Queue.take` gets it → `render`), then enters `Effect.callback`: the request is posted, the fiber suspends without blocking the JS thread.
6. **t = 400, key "abc", hash in flight.** Interrupting the `"ab"` inner unwinds into the callback's `AsyncFinalizer`: `Atomics.store(cancel, 1)`, listener removed. `Fiber.interrupt` waits for that cleanup (here synchronous; if it awaited a worker acknowledgement, the `"abc"` inner would start only after it). `"abc"` sleeps 500. The worker's loop sees the flag at its next poll and abandons `"ab"`; any late reply is ignored because the listener is gone.
7. **t = 900.** `Hashing("abc")`, worker runs, `resume(Effect.succeed(hits))` → `Done("abc", hits)` → `render`. A `HashError` becomes `Failed(…)` as data, so the pipeline survives it; a defect (thrown in the callback) would end the stream with `Die` and the render fiber would exit with that cause.
8. **Toggle off.** `setEnabled(false)`: the outer `switchMap` interrupts `pipeline`, which interrupts its current inner (sleep or hash cleanup runs) and closes the query subscription, before `Disabled` is emitted. Toggle on re-subscribes to `changes(query)`, which replays the current text and starts a fresh debounce.
9. **Unmount.** Interrupting the top fiber closes the `Scope`: the render fiber, both `switchMap` loops and their children unwind innermost-first, and `acquireRelease` terminates the worker last.

Under `it.effect`, steps 2–7 are reproduced with `setQuery` calls interleaved with `TestClock.adjust`, and a stub `hashOnWorker` built from `Effect.sleep` so hashing time is virtual too.

---

## Strengths

- **Cancellation is uniform.** Debounce windows, in-flight async calls and inner streams all stop by one mechanism (fiber interruption), with finalizers guaranteed and awaited.
- **Latest-wins is resource-safe by construction.** `Stream.switchMap` waits for the replaced inner's scope to close before the next inner pulls (verified in `mergeAll` and by test).
- **Typed errors with a three-way cause.** Expected failure, defect and interruption never blur; `Done` is separate again, which makes completion logic in operators explicit.
- **Deterministic time.** Every built-in timing operator goes through `Clock`; `TestClock` with a tracking scheduler makes multi-fiber timing tests exact.
- **Explicit hot/cold boundary.** Sharing is a `PubSub`/`share` with a declared capacity and strategy, never implicit.
- **Chunking amortizes effect overhead** without leaking into the element API.

## Weaknesses

- **Fixed-duration `debounce`.** Runtime-adjustable timing needs a hand-built shape; no `debounceEffect`.
- **`SubscriptionRef.changes` buffers unboundedly.** It is a log of updates, not a current-value signal; UI conflation is the user's job.
- **CPU-bound work is opaque to interruption.** JS has one thread per isolate; real cancellation of a hash needs a worker plus a polled flag or `terminate()`. Worker modules are `@stability unstable`.
- **Inconsistent replacement semantics across the library.** `Stream.switchMap` awaits; `FiberHandle.run` and `Atom` do not.
- **`Atom.debounce` escapes `TestClock`** (raw `setTimeout`).
- **Docs lag.** The public stream docs are still the v3 pages; v4 behaviour must be read from JSDoc and source.
- **Hidden concurrency.** "Pull-based" operators fork producer fibers with bounded buffers (16 in `mergeAll`), so element timing and memory are not strictly lock-step.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                             | Trade-off                                                                                           |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Pull-based `Stream` over `Channel` transforms                     | Backpressure is free; one abstraction implements streams and sinks                    | Push sources need a queue and a buffer policy; operators that decouple sides fork fibers            |
| Non-empty arrays as chunks (v4)                                   | Amortize effect steps; no empty-chunk edge cases; plain arrays, no `Chunk` type       | Operators like `debounce` keep only the last element of a chunk — chunk boundaries leak into timing |
| `Done` in the error channel (`Pull`)                              | Completion, failure and interruption share one propagation path                       | Every operator must filter `Done` out of real failures (`Pull.catchDone`, `filterDone`)             |
| `switchMap` awaits the old inner before starting the new          | No overlap of resources (two workers, two sockets) between generations                | A slow finalizer delays the next result; new-inner setup runs before old teardown                   |
| Cooperative, awaited interruption with uninterruptible finalizers | Cleanup always completes; no torn state                                               | Uninterruptible or CPU-bound code delays cancellation indefinitely                                  |
| Time as a `Clock` service, `TestClock` with a tracking scheduler  | Deterministic tests of debounce/timeout/retry across fibers                           | Anything using host timers directly (`Atom.debounce`) is invisible to the test clock                |
| Flat `Cause` with `Fail`/`Die`/`Interrupt` (v4)                   | Simple inspection; finalizer and concurrent failures collected into one array         | Loses v3's sequential/parallel tree structure                                                       |
| `Stream` and `Atom` as separate models                            | Pipelines want backpressure; UI bindings want current value and glitch-free recompute | Two cancellation semantics and two timing paths to learn                                            |

---

## Sources

- [`packages/effect/src/Stream.ts` — `Stream` model, `switchMap`, `flatMap`, `debounce`, `when`, `callback`, `share` (v4.1.5)][v4-stream]
- [`packages/effect/src/Channel.ts` — `fromTransform`, `flatMapSequential`, `switchMap`, `mergeAll`, `DefaultChunkSize`][v4-channel]
- [`packages/effect/src/Pull.ts` — `Pull` and `Cause.Done` completion][v4-pull]
- [`packages/effect/src/Sink.ts` — `Sink` transform and leftovers][v4-sink]
- [`packages/effect/src/SubscriptionRef.ts` — replay-1 hub, `changes`][v4-subref]
- [`packages/effect/src/PubSub.ts`][v4-pubsub] · [`packages/effect/src/Queue.ts`][v4-queue] · [`packages/effect/src/Ref.ts`][v4-ref]
- [`packages/effect/src/Fiber.ts` — `Fiber.interrupt` awaits completion][v4-fiber]
- [`packages/effect/src/FiberHandle.ts` — non-awaiting replacement][v4-fiberhandle]
- [`packages/effect/src/Effect.ts` — `callback`, `promise`, `yieldNow`, interruptibility, `fork*`][v4-effect]
- [`packages/effect/src/internal/effect.ts` — `callback` and its `AsyncFinalizer`][v4-internal-effect]
- [`packages/effect/src/Scope.ts`][v4-scope] · [`packages/effect/src/Exit.ts`][v4-exit] · [`packages/effect/src/Cause.ts`][v4-cause]
- [`packages/effect/src/Schedule.ts`][v4-schedule] · [`packages/effect/src/Clock.ts`][v4-clock] · [`packages/effect/src/Scheduler.ts` — `MaxOpsBeforeYield` 2048][v4-scheduler]
- [`packages/effect/src/testing/TestClock.ts` — sorted sleeps, tracking scheduler, warnings][v4-testclock]
- [`packages/effect/test/Stream.test.ts` — `switchMap` finalization and `debounce` tests][v4-stream-test]
- [`packages/vitest/src/internal/internal.ts` — `it.effect` test environment][v4-vitest]
- [`packages/effect/src/reactivity/Reactivity.ts`][v4-reactivity] · [`packages/effect/src/reactivity/Atom.ts`][v4-atom]
- [`packages/effect/src/workers/Worker.ts`][v4-worker] · [`packages/effect/src/rpc/RpcMessage.ts`][v4-rpcmessage] · [`packages/effect/src/rpc/RpcServer.ts`][v4-rpcserver]
- [`MIGRATION.md`][v4-migration] · [`migration/cause.md`][v4-mig-cause] · [`migration/forking.md`][v4-mig-forking] · [`migration/v3-to-v4.md`][v4-mig-renames] · [`migration/annotations/effect__Stream.yaml`][v4-mig-stream] · [`ai-docs/src/03_stream/index.md`][v4-ai-stream] · [`LICENSE`][v4-license]
- v3 contrasts (`effect@3.22.5`): [`internal/stream.ts` — `flatMap` switch, `debounce`][v3-stream] · [`internal/channel.ts` — `BufferSliding` merge][v3-channel] · [`Stream.ts`][v3-stream-api]
- [effect.website (v3 stream pages)][docs]
- Related: [Effect as an effect system][ae-effect] · [RxJS][rxjs] · [Solid 2.0 signals][solid] · [Concepts][concepts] · [Comparison][comparison] · [`event-horizon`][eh]

<!-- References -->

[repo]: https://github.com/Effect-TS/effect
[docs]: https://effect.website/docs/stream/introduction/
[v4-stream]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Stream.ts
[v4-channel]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Channel.ts
[v4-pull]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Pull.ts
[v4-sink]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Sink.ts
[v4-subref]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/SubscriptionRef.ts
[v4-pubsub]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/PubSub.ts
[v4-queue]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Queue.ts
[v4-ref]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Ref.ts
[v4-fiber]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Fiber.ts
[v4-fiberhandle]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/FiberHandle.ts
[v4-effect]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Effect.ts
[v4-internal-effect]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/internal/effect.ts
[v4-scope]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Scope.ts
[v4-exit]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Exit.ts
[v4-cause]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Cause.ts
[v4-schedule]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Schedule.ts
[v4-clock]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Clock.ts
[v4-scheduler]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/Scheduler.ts
[v4-testclock]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/testing/TestClock.ts
[v4-stream-test]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/test/Stream.test.ts
[v4-vitest]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/vitest/src/internal/internal.ts
[v4-reactivity]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/reactivity/Reactivity.ts
[v4-atom]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/reactivity/Atom.ts
[v4-worker]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/workers/Worker.ts
[v4-rpcmessage]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/rpc/RpcMessage.ts
[v4-rpcserver]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/rpc/RpcServer.ts
[v4-migration]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/MIGRATION.md
[v4-mig-cause]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/migration/cause.md
[v4-mig-forking]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/migration/forking.md
[v4-mig-renames]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/migration/v3-to-v4.md
[v4-mig-stream]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/migration/annotations/effect__Stream.yaml
[v4-ai-stream]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/ai-docs/src/03_stream/index.md
[v4-license]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/LICENSE
[v3-stream]: https://github.com/Effect-TS/effect/blob/4569dd6ec1fc02b3321bb5c9fe95d26b7ab26589/packages/effect/src/internal/stream.ts
[v3-channel]: https://github.com/Effect-TS/effect/blob/4569dd6ec1fc02b3321bb5c9fe95d26b7ab26589/packages/effect/src/internal/channel.ts
[v3-stream-api]: https://github.com/Effect-TS/effect/blob/4569dd6ec1fc02b3321bb5c9fe95d26b7ab26589/packages/effect/src/Stream.ts
[ae-effect]: ../algebraic-effects/typescript-effect.md
[rxjs]: ./rxjs.md
[solid]: ./solid-signals.md
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[eh]: ../../libs/event-horizon/index.md
