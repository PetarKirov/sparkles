# fs2 (Scala)

Pull-based, chunked, resource-safe effectful streams for Scala, compiled down to [Cats Effect][ce-deep-dive] fibers: a `Stream[F, O]` is a thin wrapper over a free `Pull` monad whose interpreter owns a tree of interruptible resource scopes, and every concurrent operator (`switchMap`, `merge`, `concurrently`, `debounce`) is built from fibers, `Deferred`s and a `Channel` on top of that interpreter.

| Field             | Value                                                                                                                                                                                                                                                      |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Scala 2.12 / 2.13 / 3, on the JVM, Scala.js and Scala Native ([`README.md`][fs2-readme])                                                                                                                                                                   |
| License           | fs2: MIT ([`LICENSE`][fs2-license]); cats-effect: Apache-2.0 ([`LICENSE.txt`][ce-license])                                                                                                                                                                 |
| Repository        | [typelevel/fs2][fs2-repo] · [typelevel/cats-effect][ce-repo]                                                                                                                                                                                               |
| Documentation     | [fs2.io][fs2-site] (rendered from [`site/guide.md`][fs2-guide]) · [typelevel.org/cats-effect][ce-site]                                                                                                                                                     |
| Category          | pull-based effectful streams (FS2) over a fiber runtime with structured cancellation (cats-effect 3)                                                                                                                                                       |
| Versions surveyed | fs2 `main` at `f679d5b45054` (2026-11-19), `tlBaseVersion := "3.16"` ([`build.sbt`][fs2-build]; newest upstream tag `v3.16.0`); cats-effect `main` at `de84c01f76b2` (2026-09-28), `tlBaseVersion := "3.7"`, newest tag `v3.7.1` ([`build.sbt`][ce-build]) |
| Core abstraction  | `Stream[+F[_], +O]` wrapping `Pull[F, O, Unit]`; consumed by `compile` into one `F[B]`; `Signal`/`SignallingRef` for state, `Channel`/`Topic` for messaging                                                                                                |

> [!NOTE]
> fs2's build pins `"org.typelevel" %%% "cats-effect" % "3.7.1"` ([`build.sbt`][fs2-build]); the cats-effect clone is the
> later `main`, so cats-effect claims below are verified against `main` source and assumed unchanged since `3.7.1`. The
> upstream tags were read with `git ls-remote`; their dates were not verified. For cats-effect _as an effect system_ —
> the typeclass hierarchy, `Resource`, the work-stealing runtime — see [Cats Effect (Scala)][ce-deep-dive]; this page
> covers only the parts a stream library leans on.

---

## Overview

### What it solves

fs2 gives Scala a value for "a possibly infinite, possibly effectful sequence" that is pure (a description, not a running process), resource-safe (every `bracket` is released exactly once, on success, error or interruption) and fast (values travel in `Chunk`s, which may wrap unboxed arrays). The `Stream` scaladoc opens with the evaluation model ([`Stream.scala`][stream]):

> _"'''Pull''': to evaluate a stream, a consumer pulls its values from it, by repeatedly performing one pull step at a time. Each step is a `F`-effectful computation that may yield some `O` values (or none), and a stream from which to continue pulling. The consumer controls the evaluation of the stream, which effectful operations are performed, and when."_

The same library covers file and socket I/O (`fs2.io`), hashing (`fs2.hashing`), text codecs and compression, so the sparkles worked pipeline — keystrokes, a debounce timer, a file-set hash, a toggle — can be written entirely in fs2 vocabulary.

### Design philosophy

The README names four goals ([`README.md`][fs2-readme]): _"Its design goals are compositionality, expressiveness, resource safety, and speed."_ Three decisions follow from them:

1. **One primitive, `Pull`.** `Pull` is _"a 'free' implementation of `Monad`"_ ([`Pull.scala`][pull]) with constructors for output, eval, acquire, scope and interruption. `Stream` is a newtype over `Pull[F, O, Unit]` (`final class Stream[+F[_], +O] private[fs2] (private[fs2] val underlying: Pull[F, O, Unit])`); every operator is either a `Pull` loop or a composition of other operators.
2. **Chunks are semantic, not just an optimisation.** _"Each pull is emitted from a chunk atomically, which is to say, any errors or interruptions in a pull can only happen between chunks, not within a chunk"_ ([`Pull.scala`][pull]). Chunk structure is observable (`chunks`), so the `Monad` right-identity law only holds up to re-chunking ([`Stream.scala`][stream]).
3. **Effect-polymorphic, cats-effect-shaped.** Operators demand the weakest typeclass they need — none for `map`, `Temporal` for `debounce`, `Concurrent` for `merge` — and _"FS2 core types (streams and pulls) are polymorphic in the effect type (as long as it is compatible with `cats-effect` typeclasses)"_ ([`README.md`][fs2-readme]).

---

## How it works

### `Pull`: a free monad with scopes

`Pull[F, O, R]` is a sealed ADT ([`Pull.scala`][pull]). Its interpreter-visible leaves are `Output(values: Chunk[O])`, `Eval(value: F[R])`, `Acquire(resource, release, cancelable)`, `InScope(stream, useInterruption)`, `InterruptWhen(haltOnSignal)`, the three `CloseScope` variants (`SucceedScope`, `CanceledScope`, `FailedScope`), `Uncons`, `StepLeg`, `Translate` and `FlatMapOutput`; `Bind` sequences them. Termination is one of `Succeeded(r)`, `Fail(error)` or `Interrupted(context, deferredError)`.

A stream transformer is a recursive `Pull` that `uncons`es a chunk and outputs another. `mapChunks` is the shape of most of the library:

```scala
// core/shared/src/main/scala/fs2/Stream.scala
def mapChunks[O2](f: Chunk[O] => Chunk[O2]): Stream[F, O2] =
  underlying.unconsFlatMap((hd: Chunk[O]) => Pull.output(f(hd))).stream
```

`.stream` opens a scope; `.streamNoScope` does not. That one distinction decides where finalizers run, and the API exposes both spellings for most resource operators (`bracket`/`bracketWeak`, `onFinalize`/`onFinalizeWeak`).

### `compile`: the interpreter

`Pull.compile` ([`Pull.scala`][pull]) is a CPS interpreter, `go(scope, extendedTopLevelScope, translation, runner, stream)`, that folds outputs into a `B` and returns one `F[B]`. Three of its cases carry the concurrency semantics:

- **`goEval`** runs an `Eval` through `scope.interruptibleEval(...)`, mapping `Left(Outcome.Canceled())` to `Interrupted(scope.id, None)`.
- **`goAcquire`** registers the resource on the current scope via `scope.acquireResource(poll => …)`; the acquire is polled (cancelable) only for `acquireCancelable`.
- **`interruptGuard`** checks `scope.isInterrupted` before acquiring, so a stream that was interrupted between steps stops at the next step.

### Scopes and the interrupt context

`Scope` ([`Scope.scala`][scope]) is a tree: _"A child scope never outlives its parent scope. I.e., when a parent scope is closed for whatever reason, the child scopes are closed too."_ Resources are prepended as acquired and released in reverse order. A scope may be _interruptible_; then

> _"Normally the interruption awaits next step in Algebra to be evaluated, with exception of Eval, that when interruption is enabled on scope will be wrapped in race, that eventually allows interruption while eval is evaluating."_ ([`Scope.scala`][scope])

The race is in `InterruptContext.eval` ([`InterruptContext.scala`][interrupt-ctx]): `F.raceOutcome(deferred.get, fa.attempt)`. When the interrupt `Deferred` wins, cats-effect cancels the losing `fa` — and a cancel _waits_ for the loser's finalizers (see [Concurrency and cancellation](#concurrency-and-cancellation)). A child interruptible scope subscribes to its parent's `Deferred` through a forked fiber (`childContext`), so interrupting a scope interrupts its whole subtree.

### Concurrency is built from fibers

`concurrently` is representative ([`Stream.scala` L548][stream-concurrently]): it starts the background stream with `compileBack.start` inside a `Stream.bracket`, makes both sides `interruptWhen(interrupt.get.attempt)`, and on release runs `stopBack`, documented in the source as _"stop background process but await for it to finalise with a result"_. `merge`, `parJoin`, `parEvalMap`, `switchMap` and `debounce` are the same kit: fibers, a `Deferred` per stop signal, a `Channel` or `Semaphore` for hand-off, and a `bracket` to tie the fiber's life to a scope.

---

## Evaluation model

- **Pull, lazy, cold.** Nothing runs until `compile` folds the stream; each compilation re-runs every effect. A `Stream` value is as cold as an RxJS `Observable` and more strictly lazy: `Stream.eval(fo)` evaluates `fo` only when the consumer pulls that step.
- **Demand-driven, chunk-granular.** The consumer's `uncons` drives the producer one chunk at a time. There is no `request(n)` protocol: back-pressure is implicit in the pull. Concurrent operators re-introduce bounded buffering: `merge` reads at most one chunk ahead per side (_"there may be up to two chunks (one from each stream) waiting to be processed"_, [`Stream.scala` L2039][stream-merge]); `prefetchN` and `Channel.bounded(n)` make the bound explicit.
- **Hot sources are explicit objects.** Sharing comes from `SignallingRef`, `Channel`, `Topic` or cats-effect `Queue`, each a mutable cell or queue whose `discrete`/`stream`/`subscribe` produces a fresh cold `Stream` per subscriber ([State and sharing](#state-and-sharing)).
- **Glitch-freedom: not a goal.** There is no dependency graph. Combining two `Signal`s through the `Applicative` instance zips their `discrete` streams _non-deterministically_ (`nondeterministicZip` in [`Signal.scala`][signal] uses `xs.either(ys).scan(...)`), so a diamond `(s, s.map(f)).mapN(g)` can emit the intermediate `(new, stale)` pair.
- **Propagation is asynchronous.** A `SignallingRef.set` completes the waiting listeners' `Deferred`s; each subscriber wakes on its own fiber and runs its own pipeline. There is no transaction or batch boundary beyond what a single `modify` makes atomic.

---

## Composition

`Stream` carries about 180 distinct instance-method names and the companion about 60 constructors (a rough `grep` count over [`Stream.scala`][stream], overloads merged). They group as:

| Group           | Examples                                                                                                                                                       |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pure, list-like | `map`, `filter`, `scan`, `take`, `zip`, `changes`, `chunks`, `mapChunks`, `++`, `flatMap` (list monad: `(a ++ b) flatMap f == (a flatMap f) ++ (b flatMap f)`) |
| Effectful       | `evalMap`, `evalTap`, `evalScan`, `foreach`, `Stream.eval`, `Stream.exec`, `Stream.repeatEval`                                                                 |
| Concurrent      | `merge`, `mergeHaltBoth`, `either`, `concurrently`, `parJoin(n)`, `parEvalMap(n)`, `parEvalMapUnordered(n)`, `switchMap`, `prefetch`, `conflate*`              |
| Time            | `debounce`, `metered`, `spaced`, `Stream.sleep`, `fixedRate`, `fixedDelay`, `awakeEvery`, `timeout`, `groupWithin`, `keepAlive`, `interruptAfter`              |
| Lifecycle       | `bracket`, `resource`, `onFinalize(Case)(Weak)`, `scope`, `interruptWhen`, `interruptScope`, `pauseWhen`                                                       |
| Errors          | `handleErrorWith`, `attempt`, `attempts`, `mask`, `onComplete`, `rethrow`, `Stream.raiseError`                                                                 |

Below the operator surface, `Pull` is the escape hatch: `s.pull.uncons`, `uncons1`, `stepLeg` and `Pull.Timed` (`timeoutWith`) let a user write any stateful operator as a tail-recursive pull, which is how the guide teaches `take` ([`site/guide.md`][fs2-guide], "Transforming streams using pulls"). A `Pipe[F, I, O]` is just `Stream[F, I] => Stream[F, O]`, and `through` applies it.

Derived values are not memoised. `s.map(f)` re-runs per subscriber; the only cached derived value is a `Signal` built by `hold`/`holdResource`, which is a `SignallingRef` fed by a background fiber.

---

## Time and scheduling

All time flows through cats-effect's `Temporal[F]` (`sleep`, `monotonic`, `realTime`). fs2 has no scheduler of its own and no frame clock: where an operator needs time it sleeps on a fiber, which the cats-effect runtime parks on its timer.

### `debounce` is a fixed-duration trailing throttle, not a restart-on-input debounce

`debounce` takes one `d: FiniteDuration`, fixed when the stream is built ([`Stream.scala` L691][stream-debounce]):

```scala
// core/shared/src/main/scala/fs2/Stream.scala — Stream#debounce (abridged)
def debounce[F2[x] >: F[x]](d: FiniteDuration)(implicit F: Temporal[F2]): Stream[F2, O] =
  Stream.force {
    for {
      chan <- Channel.bounded[F2, O](1)
      ref  <- F.ref[Option[O]](None)
    } yield {
      val sendLatest: F2[Unit] = ref.getAndSet(None).flatMap(_.traverse_(chan.send))
      def sendItem(o: O): F2[Unit] =
        ref.getAndSet(Some(o)).flatMap {
          case None    => (F.sleep(d) >> sendLatest).start.void // first item arms ONE timer
          case Some(_) => F.unit                                // later items only overwrite
        }
      def go(tl: Pull[F2, O, Unit]): Pull[F2, Nothing, Unit] =
        tl.uncons.flatMap {
          case Some((hd, tl)) => Pull.eval(sendItem(hd.last.get)) >> go(tl)
          case None           => Pull.eval(sendLatest >> chan.close.void)
        }
      chan.stream.concurrently(go(this.underlying).streamNoScope)
    }
  }
```

Three findings follow from the source:

1. **The timer is not reset by new input.** The first element after a quiet period starts `sleep(d)`; elements arriving during it only replace the slot. At `d` the latest is emitted. That is RxJS's `auditTime`, not `debounceTime`: a user typing continuously at 50 ms intervals with `d = 300 ms` gets an emission every ~300 ms, never "300 ms after the last keystroke". The scaladoc says as much — _"Debounce the stream with a minimum period of `d` between each element"_ — and its example `(1,2,3) ++ sleep(500ms) ++ (4,5) ++ sleep(10ms) ++ 6` debounced by `100ms` yields `Vector(3, 6)`.
2. **Only the last element of each chunk is seen** (`hd.last.get`): debounce is chunk-granular.
3. **`d` cannot change at runtime.** A runtime-adjustable interval needs either a `switchMap` over an interval signal (rebuilding the operator) or a hand-written trailing debounce; the [worked pipeline](#the-worked-pipeline) does the latter in two lines.

> [!WARNING]
> The timer fiber is started with a bare `.start.void` — it is not registered on any scope and not cancelled when the
> debounced stream is interrupted. Reading the source, after an interruption it still wakes at `d` and offers its value
> to a channel no one drains (capacity 1, so the send completes). It is not a leak in the "grows without bound" sense,
> but it is an unstructured fiber inside a library that is otherwise strictly scoped. (Reading of the source; not
> reproduced.)

### `metered`, `spaced`, `fixedRate`

`metered(rate)` is `Stream.fixedRate[F2](rate).zipRight(this)` ([`Stream.scala` L725][stream-metered]) — a rate limiter that never drops. `fixedRate_` keeps a `lastAwakeAt` from `Temporal.monotonic`, sleeps until `lastAwakeAt + period`, and on overrun emits one catch-up tick (`dampen = true`) or one per missed period ([`Stream.scala` L3615][stream-fixedrate]). `spaced(delay)` instead zips with `fixedDelay`, i.e. `sleep(period).repeat`, so it _"simply introduced a fixed sleep time between elements, irrespective of other pauses in the stream or the consumer"_. All three take a fixed `FiniteDuration`.

### Where the work runs

cats-effect decides: compute fibers run on the work-stealing pool, `Sync.blocking` thunks on a separate blocking pool, and `IO.evalOn(ec)` pins a region to a chosen `ExecutionContext` (see [Cats Effect: thread pool architecture][ce-deep-dive]). fs2 adds nothing; `fs2.io`'s JVM file reads are `F.blocking { … }` per chunk ([`FileHandlePlatform.scala`][fs2-filehandle]).

---

## Concurrency and cancellation

### `switchMap`: latest-wins, and the next inner waits for the previous one's finalizers

`switchMap` is the latest-wins operator ([`Stream.scala` L1975][stream-switchmap]). Its scaladoc states the guarantee directly:

> _"Finializers of each inner stream are guaranteed to run before the next inner stream starts."_

The implementation enforces it with a one-permit `Semaphore` acquired by each inner stream and released only by that inner's bracket finalizer:

```scala
// core/shared/src/main/scala/fs2/Stream.scala — Stream#switchMap
def runInner(o: O, halt: Deferred[F2, Unit]): Stream[F2, O2] =
  Stream.bracketFull[F2, Unit] { poll =>
    poll(guard.acquire) // guard inner with a semaphore to prevent parallel inner streams
  } {
    case (_, ExitCase.Errored(_)) => F.unit // if there's an error, don't start next stream
    case _                        => guard.release
  } >> f(o).interruptWhen(halt.get.attempt)

def haltedF(o: O): F2[Stream[F2, O2]] =
  for {
    halt <- F.deferred[Unit]
    prev <- haltRef.getAndSet(halt.some)
    _    <- prev.traverse_(_.complete(())) // interrupt previous one if any
  } yield runInner(o, halt)

this.evalMap(haltedF).parJoin(2)
```

Step by step, for a new outer element `o2` while inner `i1` runs:

1. `haltedF(o2)` completes `i1`'s `halt` `Deferred` — a non-blocking signal; the outer keeps going.
2. `parJoin(2)` starts `i2`, whose first step is `poll(guard.acquire)`; it **blocks** (cancelably, via `poll`) because `i1` still holds the permit.
3. `i1` observes interruption at its next step or, if it is inside an `Eval`, by the `raceOutcome` in its interruptible scope, which cancels the running `F` and waits for that cancellation to finish.
4. `i1`'s scope closes, running its finalizers in reverse acquisition order; the `guard.release` bracket was acquired first, so it runs **last**.
5. Only then does `i2` acquire the permit and run `f(o2)`.

So a cancel _does_ wait for the cancelled work: the new inner starts only after the old one has fully torn down. The test suite pins this — _"inner stream finalizer always runs before switching"_ ([`StreamSwitchMapSuite.scala`][switchmap-suite]) runs an inner whose `onFinalize` sleeps 100 ms and fails if the next inner sees the flag unset. Two corollaries: at most two inners exist at once (the dying one and the waiting one, hence `parJoin(2)`), and a burst of outer elements interrupts each waiting inner in turn, since each is itself an interruptible stream blocked in `poll`. If an inner _errors_, the permit is deliberately not released and the whole stream fails.

### How cancellation reaches running work

fs2 interruption becomes cats-effect fiber cancellation at an `Eval`, and cats-effect's rules then decide:

- **Cancellation is cooperative, observed at run-loop boundaries.** `MonadCancel` defines a cancelation boundary as one _"where the cancelation status of a fiber ''may'' be checked"_, introduced _"before each of the combinators from the Cats/Cats Effect hierarchy (`map`, `flatMap`, `handleErrorWith`, `attempt`, etc)"_ ([`MonadCancel.scala`][ce-monadcancel]). In `IOFiber.runLoop` ([`IOFiber.scala` L225][ce-iofiber-loop]) `shouldFinalize()` (`canceled && masks == 0`) is tested on every iteration, with a `readBarrier()` to see a cross-thread cancel every `cancelationCheckThreshold` iterations (default `512` on the JVM, [`IORuntimeConfigCompanionPlatform.scala`][ce-rtconfig]). A `delay { … }` thunk is never interrupted mid-body.
- **`cancel` backpressures.** _"`cancel` semantically blocks all callers until finalization is complete"_ (the scaladoc's `[[Fiber!.cancel cancel]]` link rendered as plain `cancel`) ([`GenSpawn.scala` L89][ce-genspawn]). This is why fs2's `interruptWhen`, `concurrently` and `switchMap` all wait.
- **`uncancelable` / `Poll`.** `uncancelable(poll => …)` masks the body; `poll(fb)` re-opens a cancelable window. _"cancelation is effective; it cannot be undone. It can be suppressed, but once it is observed, it must be respected"_ ([`monadcancel.md`][ce-monadcancel-doc]). fs2's `bracketFull` passes the `Poll` to `acquire`, which is how `switchMap`'s waiting `guard.acquire` stays cancelable.

### CPU-bound and blocking work

| Primitive                       | Runs on       | On cancel                                                                                                                                               |
| ------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `IO.delay` / `Sync.delay`       | compute pool  | not interrupted; cancel observed after it returns                                                                                                       |
| `IO.blocking` / `Sync.blocking` | blocking pool | _"the created effect will be uncancelable"_ ([`Sync.scala` L64][ce-sync]); cancel waits for the thunk                                                   |
| `IO.interruptible`              | blocking pool | _"will attempt to abort the blocking operation using thread interrupts in the event of cancelation. The interrupt will be attempted only once."_        |
| `IO.interruptibleMany`          | blocking pool | interrupts repeatedly until the thunk exits                                                                                                             |
| `IO.cede`                       | compute pool  | yields; the scaladoc recommends `(fa <* IO.cede).map(expensiveWork).guarantee(IO.cede)` and splitting work above ~1 ms ([`IO.scala` L1542][ce-io-cede]) |

For the file-set hash, fs2's own stack already yields fine-grained cancel points: `Files.readAll` reads 64 KiB per `F.blocking` step (`readAll(path, 64 * 1024, Flags.Read)`, [`Files.scala`][fs2-files]) and `Hasher.update` is `Sync[F].delay(unsafeUpdate(bytes))` per chunk ([`HasherCompanionPlatform.scala`][fs2-hasher-jvm]). A cancel therefore waits for at most one 64 KiB read plus one digest update.

### Other combinators

- **`parEvalMap(n)`** keeps order through a `Channel.bounded(n + 1)` of per-element results (_"One is taken by inner stream read"_); `parEvalMapUnordered` drops ordering ([`Stream.scala` L2283][stream-pareval]).
- **`interruptWhen(Stream[F, Boolean] | Signal | Deferred | F[Either[Throwable, Unit]])`** — the `F` form is primitive: `(Pull.interruptWhen(haltOnSignal) >> this.pull.echo).stream.interruptScope`. The `Stream[F, Boolean]` overload runs the watcher on a background fiber and, on release, _awaits_ it (`stopWatch = interruptR.complete(()) >> backResult.get…`) ([`Stream.scala` L1764][stream-interruptwhen]). `interruptAfter(d)` is `interruptWhen(sleep(d).attempt)`.
- **`concurrently`** runs a background stream for the lifetime of the foreground; a background error interrupts the foreground and is re-raised.
- **`merge`** halts when both sides halt, or on the first error, stopping the other side through a shared `stopDef` ([`Stream.scala` L2039][stream-merge]).

---

## Errors and completion

A stream terminates in exactly one way: normal exhaustion, an error (`Fail`), or interruption (`Interrupted`), the last of which is not an error and is invisible to `handleErrorWith`.

- **Errors are `Throwable`s in `F`.** `Stream.raiseError(e) ++ s == Stream.raiseError(e)` and `raiseError(e).handleErrorWith(h) == h(e)` are stated laws ([`Stream.scala`][stream]). `handleErrorWith` is `Pull.scope(underlying).handleErrorWith(…)`, so the failed stream's resources are released before the handler runs ([`Stream.scala` L1623][stream-handleerror]).
- **`attempt`** materialises the first error as a terminal `Left` (`Right(1), Right(2), Right(3), Left(...)`), then halts; `attempts(delays)` retries. A typed-error discipline (`EitherT`, or the result as data) is a user choice; the library's channel is `Throwable`.
- **Errors are terminal; there is no resumption** inside a stream — a recovered stream continues with the _handler's_ stream. Per-element failure is modelled by `attempt` on the inner effect (`evalMap(f(_).attempt)`), as the worked pipeline does.
- **Concurrent errors compose.** `merge` reports both sides' failures through `CompositeFailure.fromResults`; `concurrently` raises the background error in the foreground.
- **Cleanup belongs in finalizers.** The guide warns that under asynchronous interruption _"you should not use `handleErrorWith` or other interruptible functions for resource cleanup. Use `bracket` or `onFinalize` for this purpose"_ ([`site/guide.md`][fs2-guide], Appendix A1).

---

## State and sharing

### `Signal` and `SignallingRef`

`Signal[F, A]` is _"Pure holder of a single value of type `A` that can be read in the effect `F`"_ with `get`, `discrete` and `continuous` ([`Signal.scala`][signal]). `SignallingRef` adds the `Ref` writers (`set`, `update`, `modify`). The two streams differ precisely:

- **`discrete`** emits the current value, then each update — but conflated: _"when you pull from this stream you may be notified of only the latest update since your last pull. If you want to be notified about every single update, use a `Queue` or `Channel` instead."_ Implementation: the state is `State(value, lastUpdate: Long, listeners: LongMap[Deferred[F, (A, Long)]])`; a writer bumps `lastUpdate`, clears the listener map and completes every listener's `Deferred`; a subscriber whose `lastSeen` is behind returns the current value immediately, otherwise registers a fresh `Deferred` and waits. Each subscription is a `Stream.bracket(newId)(cleanup)`, so unsubscription removes the listener.
- **`continuous`** is `Stream.repeatEval(get)` — every pull samples the cell; it never blocks and spins if pulled unthrottled.

`discrete` does not de-duplicate equal writes; `Signal#changes(Eq)` derives one that does. `Stream#hold(initial)` / `holdResource` convert a stream into a `Signal` by running `evalMap(sig.set)` on a background fiber — fs2's analogue of a `BehaviorSubject` / `StateFlow`.

### `Channel`, `Topic`, `Queue`

- **`Channel`** — many producers, **one** consumer (_"This method CANNOT be called concurrently by multiple consumers, if you do so, one of the consumers might become permanently deadlocked"_), `bounded(n)`, `unbounded` or `synchronous`; `close` is graceful (drains enqueued elements first) ([`Channel.scala`][channel]). Each pull serves _all_ queued elements as one chunk.
- **`Topic`** — multicast pub/sub with per-subscriber `maxQueued`; a slow subscriber at its bound _"semantically block[s]"_ `publish1` for everyone ([`Topic.scala`][topic]). There is no replay: late subscribers miss earlier elements.
- cats-effect `Queue` — work distribution (each element to one consumer); `Stream.fromQueueUnterminated` adapts it.

Conflation is available as an operator family (`conflateChunks`, `conflate`, `conflateSemigroup`), each a `Channel.bounded(chunkLimit)` whose consumer `combineAll`s what accumulated.

---

## Lifetime and ownership

Lifetime is lexical and checked by construction, which is fs2's strongest property:

- **`Stream.bracket(acquire)(release)`** / **`Stream.resource(r: Resource[F, O])`** register a finalizer on a new scope; `bracketCase` hands the release an `ExitCase` (`Succeeded`, `Errored(e)`, `Canceled` — the last on _"either stream interruption or overall compiled effect cancelation"_) ([`Stream.scala`][stream-bracket]).
- **The guarantee.** _"A stream will never be interrupted while it is acquiring a resource (via `bracket`) or while it is releasing a resource. The `bracket` function guarantees that if FS2 starts acquiring the resource, the corresponding release action will be run."_ ([`site/guide.md`][fs2-guide])
- **`onFinalize(f)`** is `Stream.bracket(F2.unit)(_ => f) >> this`. The `…Weak` variants omit the scope so finalization attaches to the _enclosing_ scope — needed, for example, when a stream is turned into a `Resource` with `compile.resource` and must outlive the stream's own scope ([`Stream.scala` L2234][stream-onfinalize]).
- **Concurrent operators do not propagate scopes.** _"Stream combinators which require `F` to have a `Concurrent` instance generally do not propagate open scopes. Finalizers may be run concurrently with subsequent operations in the stream"_ ([`Stream.scala`][stream]) — a resource acquired inside a `merge` branch is released when that branch's fiber finishes, not when downstream stops using its output.
- **Fibers are owned by brackets.** `concurrently`, `merge`, `interruptWhen` and `parJoin` each `start` their fibers inside a `Stream.bracket` whose release stops and joins them. The exception found in this survey is `debounce`'s timer fiber ([above](#debounce-is-a-fixed-duration-trailing-throttle-not-a-restart-on-input-debounce)).
- **The edge.** A program typically ends in `compile.drain` inside `IOApp.run`; callback-driven code (a GUI toolkit) crosses into `IO` with cats-effect's `Dispatcher` ([`Dispatcher.scala`][ce-dispatcher]), itself a `Resource` whose release cancels outstanding work.

---

## Testing

cats-effect's `TestControl` ([`TestControl.scala`][ce-testcontrol]) is the virtual-time harness, and fs2's own suite uses it for every time operator. Per its scaladoc and the [test-runtime guide][ce-test-runtime-doc]:

- It is a single-threaded mock runtime where _"no time is considered to have elapsed as a consequence of ''compute''"_; only `IO.sleep` advances the clock.
- When several fibers are ready it picks _randomly_ (seeded, reproducible via `seed`), _"intended to simulate different scheduling interleavings"_.
- **`tick`** runs all ready fibers without advancing time; **`tickOne`** runs one; **`advance(d)`** moves the clock; **`advanceAndTick(d)`**; **`tickFor(d)`**; **`tickAll`** runs to quiescence, jumping the clock to each next timer; **`nextInterval`**, **`results`**, **`isDeadlocked`** observe.
- **`executeEmbed(program)`** = `execute` + `tickAll` + result, raising `NonTerminationException` on deadlock. Interaction with an external thread (`IO.async` waiting on a foreign callback, `evalOn`) reads as a deadlock.

fs2's debounce test is the model ([`StreamCombinatorsSuite.scala`][combinators-suite]):

```scala
// core/shared/src/test/scala/fs2/StreamCombinatorsSuite.scala
test("debounce") {
  val delay = 200.milliseconds
  TestControl.executeEmbed {
    (Stream(1, 2, 3) ++ Stream.sleep_[IO](delay * 2) ++ Stream() ++ Stream(4, 5) ++ Stream
      .sleep_[IO](delay / 2) ++ Stream(6))
      .debounce(delay)
      .assertEmits(List(3, 6))
  }
}
```

A 400 ms scenario runs in microseconds and asserts exact emissions. For stepwise inspection, `TestControl.execute(program)` returns the control handle, and the test interleaves `advanceAndTick(…)` with `results`. Driving the program's inputs from _outside_ the mock runtime (an outer `Ref` set between ticks) is explicitly discouraged as _"quite tricky"_; scripting the inputs inside the program with `IO.sleep` (as below) is the supported shape.

> [!NOTE]
> `execute` builds the test runtime with `ctx.deriveBlocking()` ([`TestControl.scala`][ce-testcontrol]), so `IO.blocking`
> appears to run on the mocked single thread rather than a real pool — real file I/O inside a `TestControl` run takes
> wall time but no virtual time (reading of the source). Pure fakes for the hash are the reliable choice.

---

## The worked pipeline

Query field → debounce N ms (N adjustable at runtime) → hash the file set with latest-wins cancellation → show the result; a toggle enables the whole pipeline, and switching it off cancels a pending debounce and an in-flight hash. In fs2 3.16 / cats-effect 3.7 (Scala 3 syntax):

```scala
import cats.effect.IO
import cats.syntax.all.*
import fs2.Stream
import fs2.concurrent.SignallingRef
import fs2.hashing.{Hash, HashAlgorithm, Hashing}
import fs2.io.file.{Files, Path}
import scala.concurrent.duration.*

enum Result:
  case Idle
  case Running(query: String)
  case Done(query: String, digest: Hash)
  case Failed(query: String, error: Throwable)

final case class Inputs(
    query: SignallingRef[IO, String],            // written by the UI per keystroke
    interval: SignallingRef[IO, FiniteDuration], // written by the numeric field
    enabled: SignallingRef[IO, Boolean]          // written by the toggle
)

// 64 KiB `F.blocking` read + `Sync.delay` digest update per chunk: a cancel point every chunk.
def hashFileSet(paths: Stream[IO, Path]): IO[Hash] =
  paths
    .flatMap(p => Files[IO].readAll(p))
    .through(Hashing[IO].hash(HashAlgorithm.SHA256))
    .compile
    .lastOrError

def pipeline(in: Inputs, resolve: String => Stream[IO, Path]): Stream[IO, Result] =
  in.enabled.discrete.changes.switchMap {
    case false => Stream.emit(Result.Idle)
    case true =>
      in.query.discrete.changes.switchMap { q =>
        // Trailing debounce: every keystroke restarts this inner stream, and the
        // interval is read when the timer is armed, so a change applies from the next keystroke.
        Stream.exec(in.interval.get.flatMap(IO.sleep)) ++
          Stream.emit(Result.Running(q)) ++
          Stream.eval(hashFileSet(resolve(q)).attempt).map {
            case Right(h) => Result.Done(q, h)
            case Left(e)  => Result.Failed(q, e)
          }
      }
  }

// UI edge: the frame reads `latest.get` (via a Dispatcher) and is woken when it changes.
def run(in: Inputs, resolve: String => Stream[IO, Path], latest: SignallingRef[IO, Result], wake: IO[Unit]): IO[Unit] =
  pipeline(in, resolve).foreach(r => latest.set(r) >> wake).compile.drain
```

The built-in `debounce` is deliberately not used: its duration is a fixed `FiniteDuration` and it does not restart on input ([Time and scheduling](#debounce-is-a-fixed-duration-trailing-throttle-not-a-restart-on-input-debounce)). The `switchMap` + `sleep` idiom gives a true trailing debounce, and the _same_ `switchMap` provides latest-wins for the hash, so one operator owns both cancellations.

**Trace** (N = 300 ms, `enabled = true`):

1. **Keystroke during debounce.** t=0 `query.set("a")`: `discrete` wakes the outer-inner `switchMap`, which starts inner `"a"`, now in `IO.sleep(300ms)`. t=120 `query.set("ab")`: `haltedF` completes `"a"`'s `halt`; inner `"ab"` blocks on `guard.acquire`. `"a"`'s interruptible scope races the `sleep` against `halt`, cancels the sleep (no finalizers), closes, releases the permit; `"ab"` starts its own 300 ms sleep. Nothing reaches the UI. Keystrokes faster than the subscriber pulls are conflated by `discrete`, which is harmless here.
2. **Keystroke during hash.** t=420 `"ab"` emits `Running("ab")` and starts the hash. t=500 `query.set("abc")`: `"ab"` is halted while inside `Stream.eval(hashFileSet(…))`; the race cancels that `IO`. Its inner `compile` observes cancellation at the next run-loop boundary — after the current 64 KiB `F.blocking` read or `delay` digest update returns — then releases the file handle (the `readAll` resource) and the `Hasher`. `cancel` blocks until that is done; then `"abc"` acquires the permit and starts a fresh 300 ms timer. The UI still shows `Running("ab")` until t≈800, when `Running("abc")` arrives.
3. **Interval change.** `interval.set(1.second)` emits nothing and restarts nothing: the running inner already read 300 ms. The next keystroke's timer uses 1 s. Restarting on an interval change instead means switching on the pair — `(in.query, in.interval).tupled.discrete` through `Signal`'s `Applicative` — at the cost of the non-deterministic zip noted under [Evaluation model](#evaluation-model).
4. **Toggle off.** `enabled.set(false)`: the outer `switchMap` halts the whole `true` branch, an interruptible scope containing the inner `switchMap`, its `parJoin(2)` fibers, any pending `sleep` and any in-flight hash. Interruption propagates down the scope tree; every finalizer runs, children first; when the last permit is released the `false` branch emits `Result.Idle`. A pending debounce never fires and a half-hashed result is never emitted.

**Fit for a per-frame UI.** The pipeline itself fits well: latest-wins, the wait-for-teardown guarantee, scoped resources and virtual-time tests are exactly what sparkles wants. The edges fit less well. The output is push-shaped (`foreach`), so an immediate-mode frame needs a cell (`latest: SignallingRef`) read each frame plus an explicit wake, and every UI write crosses the effect boundary through a `Dispatcher` (`unsafeRunAndForget(in.query.set(text))`). There is no frame clock and no glitch-free derived state: anything the widget tree _derives_ (enabled-and-non-empty, say) is either recomputed per frame from `get`s or becomes another asynchronous stream. And cancellation latency is "one effect step", so CPU work must be chunked or `cede`d to be responsive.

---

## Strengths

- **One interpreter, one cancellation story.** Every operator reduces to `Pull` + scopes, and every concurrent operator reduces to cats-effect fibers whose `cancel` backpressures, so "does cancel wait?" has one answer everywhere it was checked: yes.
- **`switchMap` serialises teardown.** The next inner never overlaps the previous one's finalizers — the property a latest-wins file hash needs so two hashes never contend for the same files or worker.
- **Resource safety by construction.** `bracket` acquire/release is uninterruptible and always paired; scopes form a tree that closes children first; fibers are owned by brackets.
- **Chunking gives cheap, regular cancel points.** `readAll`'s 64 KiB chunks and per-chunk digest updates make a large hash cancellable within one chunk without user `cede`s.
- **Deterministic virtual-time tests** via `TestControl.executeEmbed`, with randomised interleavings that surface ordering bugs.
- **`Pull` as the extension mechanism** — a user-written operator has exactly the power of a library one.

## Weaknesses

- **`debounce` is misnamed for UI use**: fixed duration, no restart on input, last-of-chunk, and an unscoped timer fiber.
- **No glitch-freedom and no dependency graph.** `Signal` combination is a non-deterministic zip; derived state is a stream, not a memoised node.
- **Concurrent operators drop scopes.** Resources acquired under `merge`/`parJoin` are finalised when the producing fiber ends, which surprises users (documented, but a sharp edge).
- **Heavy machinery per operator.** `switchMap` allocates a `Semaphore`, a `Ref`, a `Deferred` per element and runs through `parJoin(2)`; `merge` allocates a `SignallingRef`, a synchronous `Channel` and three fibers. Fine on the JVM, notable for a `@nogc` design.
- **`Throwable` is the only error channel**, and interruption is a third outcome that error handlers do not see.
- **Cooperative cancellation is coarse at the edges.** `blocking` is uncancelable, `interruptible` relies on JVM thread interrupts, and a `delay` thunk runs to completion; responsiveness depends on how finely work is chunked.

## Key design decisions and trade-offs

| Decision                                                                     | Rationale                                                                     | Trade-off                                                                                    |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Pull-based evaluation over a free `Pull` monad                               | Consumer controls effects; back-pressure for free; one interpreter to verify  | Hot, push-shaped sources (UI events) must be adapted through `Signal`/`Channel`/`Queue`      |
| Chunks are the atomic unit of emission and interruption                      | Unboxed arrays, amortised interpreter overhead, well-defined interrupt points | Chunk structure leaks into semantics (`debounce` sees only `hd.last`, laws hold up to `===`) |
| Interruptible scope tree; `Eval` raced against interrupt                     | Interrupt in-flight effects, not just between steps; children close first     | A `Deferred` and a forked listener fiber per interruptible child scope                       |
| `cancel` backpressures until finalizers finish (cats-effect)                 | No overlapping lifetimes; `switchMap` can promise teardown-before-start       | Cancel latency = longest uncancelable region (a `blocking` read, a long `delay`)             |
| `switchMap` = `evalMap(halt previous)` + one-permit semaphore + `parJoin(2)` | Reuses existing pieces; serialises inner lifetimes                            | Per-element allocation; an erroring inner deliberately never releases the permit             |
| Time via `Temporal` only, durations as `FiniteDuration` args                 | Effect-polymorphic; mockable by `TestControl`                                 | No runtime-variable `debounce`/`metered`; no frame clock                                     |
| Concurrent combinators do not propagate scopes                               | Lets fibers finish and release independently                                  | Resources from `merge`/`parJoin` branches may close before downstream is done with them      |
| `Signal.discrete` conflates                                                  | O(1) state, a slow subscriber never blocks writers                            | Every-update consumers need a `Channel`/`Queue`; no glitch-free combination                  |

## Sources

- fs2 source at `f679d5b45054`: [`Stream.scala`][stream], [`Pull.scala`][pull], [`internal/Scope.scala`][scope], [`internal/InterruptContext.scala`][interrupt-ctx], [`concurrent/Signal.scala`][signal], [`concurrent/Channel.scala`][channel], [`concurrent/Topic.scala`][topic], [`hashing/Hashing.scala`][fs2-hashing], [`HasherCompanionPlatform.scala`][fs2-hasher-jvm], [`io/file/Files.scala`][fs2-files], [`FileHandlePlatform.scala`][fs2-filehandle], [`build.sbt`][fs2-build], [`README.md`][fs2-readme], [`LICENSE`][fs2-license].
- fs2 tests: [`StreamCombinatorsSuite.scala`][combinators-suite], [`StreamSwitchMapSuite.scala`][switchmap-suite].
- fs2 guide: [`site/guide.md`][fs2-guide] (fs2.io "Guide", incl. Appendix A1 on interruption), [`site/concurrency-primitives.md`][fs2-concurrency-doc]; [fs2.io][fs2-site].
- cats-effect source at `de84c01f76b2`: [`IOFiber.scala`][ce-iofiber-loop], [`IO.scala`][ce-io-cede], [`GenSpawn.scala`][ce-genspawn], [`MonadCancel.scala`][ce-monadcancel], [`Sync.scala`][ce-sync], [`TestControl.scala`][ce-testcontrol], [`IORuntimeConfigCompanionPlatform.scala`][ce-rtconfig], [`Dispatcher.scala`][ce-dispatcher], [`build.sbt`][ce-build], [`LICENSE.txt`][ce-license].
- cats-effect docs: [`docs/core/test-runtime.md`][ce-test-runtime-doc] ([rendered][ce-test-runtime-site]), [`docs/typeclasses/monadcancel.md`][ce-monadcancel-doc]; [typelevel.org/cats-effect][ce-site].
- Related deep-dives: [Cats Effect (Scala)][ce-deep-dive], [ZIO (Scala)][zio-deep-dive], [RxJS][rxjs], [Kotlin Flow][kotlin-flow], [Effect-TS][effect-ts], [Rust streams][rust-streams]; the umbrella [index][index], [concepts][concepts], [comparison][comparison]; [async I/O survey][async-io].

<!-- References -->

[fs2-repo]: https://github.com/typelevel/fs2
[ce-repo]: https://github.com/typelevel/cats-effect
[fs2-site]: https://fs2.io/
[ce-site]: https://typelevel.org/cats-effect/
[ce-test-runtime-site]: https://typelevel.org/cats-effect/docs/core/test-runtime
[stream]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala
[stream-concurrently]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L548
[stream-debounce]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L691
[stream-metered]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L725
[stream-handleerror]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L1623
[stream-interruptwhen]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L1764
[stream-switchmap]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L1975
[stream-merge]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L2039
[stream-onfinalize]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L2234
[stream-pareval]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L2283
[stream-bracket]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L3380
[stream-fixedrate]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Stream.scala#L3615
[pull]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/Pull.scala
[scope]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/internal/Scope.scala
[interrupt-ctx]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/internal/InterruptContext.scala
[signal]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/concurrent/Signal.scala
[channel]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/concurrent/Channel.scala
[topic]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/concurrent/Topic.scala
[fs2-hashing]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/main/scala/fs2/hashing/Hashing.scala
[fs2-hasher-jvm]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/jvm/src/main/scala/fs2/hashing/HasherCompanionPlatform.scala
[fs2-files]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/io/shared/src/main/scala/fs2/io/file/Files.scala
[fs2-filehandle]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/io/jvm-native/src/main/scala/fs2/io/file/FileHandlePlatform.scala
[fs2-build]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/build.sbt
[fs2-readme]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/README.md
[fs2-license]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/LICENSE
[fs2-guide]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/site/guide.md
[fs2-concurrency-doc]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/site/concurrency-primitives.md
[combinators-suite]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/test/scala/fs2/StreamCombinatorsSuite.scala#L203
[switchmap-suite]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/test/scala/fs2/StreamSwitchMapSuite.scala#L45
[ce-iofiber-loop]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/core/shared/src/main/scala/cats/effect/IOFiber.scala#L225
[ce-io-cede]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/core/shared/src/main/scala/cats/effect/IO.scala#L1542
[ce-genspawn]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/kernel/shared/src/main/scala/cats/effect/kernel/GenSpawn.scala#L89
[ce-monadcancel]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/kernel/shared/src/main/scala/cats/effect/kernel/MonadCancel.scala#L94
[ce-sync]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/kernel/shared/src/main/scala/cats/effect/kernel/Sync.scala#L64
[ce-testcontrol]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/testkit/shared/src/main/scala/cats/effect/testkit/TestControl.scala
[ce-rtconfig]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/core/jvm/src/main/scala/cats/effect/unsafe/IORuntimeConfigCompanionPlatform.scala
[ce-dispatcher]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/std/shared/src/main/scala/cats/effect/std/Dispatcher.scala
[ce-build]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/build.sbt
[ce-license]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/LICENSE.txt
[ce-test-runtime-doc]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/docs/core/test-runtime.md
[ce-monadcancel-doc]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/docs/typeclasses/monadcancel.md
[ce-deep-dive]: ../algebraic-effects/scala-cats-effect.md
[zio-deep-dive]: ../algebraic-effects/scala-zio.md
[async-io]: ../async-io/index.md
[rxjs]: ./rxjs.md
[kotlin-flow]: ./kotlin-flow.md
[effect-ts]: ./effect-ts.md
[rust-streams]: ./rust-streams.md
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
