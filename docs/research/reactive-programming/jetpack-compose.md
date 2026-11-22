# Jetpack Compose Runtime (Kotlin)

The state-and-effects core of Android's declarative UI toolkit: transactional `MutableState` cells versioned by a multi-version-concurrency `Snapshot` system, a `Recomposer` that re-runs only the composable functions whose read state changed (once per display frame), and key-scoped coroutine effects (`LaunchedEffect`, `DisposableEffect`) whose lifetime is a position in the UI tree.

| Field             | Value                                                                                                                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Kotlin (Multiplatform: `commonMain` runtime; Android, JVM desktop, iOS, web hosts)                                                                                                              |
| License           | Apache-2.0 ([`LICENSE.txt`][license])                                                                                                                                                           |
| Repository        | [androidx/androidx][repo] (`compose/runtime/runtime/`)                                                                                                                                          |
| Documentation     | [Side-effects in Compose][d-effects] · [Thinking in Compose][d-mental] · [State and Jetpack Compose][d-state] · [API reference][d-api]                                                          |
| Category          | Fine-grained observable state + per-frame incremental re-execution (a "signals"-like model fused with structured-concurrency effects)                                                           |
| Versions surveyed | `androidx.compose.runtime` **1.14.0-alpha02** (`COMPOSE_RUNTIME` in [`libraryversions.toml`][versions]), `androidx-main` commit `296313a488a0`, 2026-11-21                                      |
| Core abstraction  | `State<T>` / `MutableState<T>`: a snapshot-isolated value cell whose reads are recorded by the observer of the current `Snapshot`; effects are `RememberObserver`s whose identity is their keys |

> [!NOTE]
> Compose is a UI framework, not a reactive-streams library; this deep-dive covers only the
> **runtime** (`androidx.compose.runtime`) and the two UI-module files that wire it to a host
> (the global snapshot write pump and the test clock). Streams proper are delegated to
> kotlinx.coroutines `Flow` — see [Kotlin Flow][kotlin-flow]. The same runtime drives a
> terminal UI in [Mosaic][mosaic], which is the closest existing analogue to a sparkles app.
> Which version is the current _stable_ release on 2026-11-22 was not checked _(unverified)_.

---

## Overview

### What it solves

A Compose UI is a function from state to a UI tree that is _conceptually_ re-run on every change — the immediate-mode programming model — while actually re-executing only the parts whose inputs changed. The [mental-model guide][d-mental] states the contract:

> _"Recomposition is the process of calling your composable functions again when inputs change. When Compose recomposes based on new inputs, it calls only the functions or lambdas that might have changed, and skips the rest."_

and what that demands of user code:

> _"Composable functions might be re-executed as often as every frame, such as when an animation is being rendered."_

The runtime therefore has to answer three questions a sparkles app answers today with "rebuild everything every frame": _which state did this function read_ (snapshot read observers), _when should it re-run_ (the `Recomposer`, aligned to a `MonotonicFrameClock`), and _where does long-running work live_ if the function itself must be pure and may be re-run, skipped or discarded (effects bound to the tree, running as coroutines).

### Design philosophy

1. **Composition is pure, optimistic and discardable; effects are not.** The [side-effects guide][d-effects]: _"Due to composables' lifecycle and properties such as unpredictable recompositions, executing recompositions of composables in different orders, or recompositions that can be discarded, composables should ideally be side-effect free."_ and _"An **effect** is a composable function that doesn't emit UI and causes side effects to run when a composition completes."_ Effects run only when the composition's changes are _applied_, never during the speculative pass.
2. **State is the conflated thing, events are not.** The `snapshotFlow` KDoc ([`SnapshotFlow.kt`][snapshotflow]) draws the line every Compose API respects: _"Observable **state** raises change events when the state changes from one value to a new, unequal value. State change events are **conflated;** only the most recent state matters. Observers of state changes must therefore be **idempotent**."_
3. **An effect's identity is its keys.** There is no `switchMap`; there is `remember(keys)`. When a key changes, the old effect object is forgotten (its coroutine cancelled) and a new one is remembered (a new coroutine launched). Every latest-wins behaviour in Compose is this one mechanism ([`Effects.kt`][effects], `LaunchedEffectNoParamError`: _"…determine when its previous effect coroutine should be cancelled and a new effect launched for the new key."_).
4. **No time operators in the runtime.** Time is either the frame clock (`withFrameNanos`, for animation) or kotlinx.coroutines `delay` inside an effect. Debounce is an idiom, not an API.

---

## How it works

### Snapshots: MVCC for UI state

Every `StateObject` (`mutableStateOf`, `mutableStateListOf`, `derivedStateOf`, …) keeps a linked list of `StateRecord`s tagged with snapshot ids. A `Snapshot` is a view: _"All state objects will have the same value in the snapshot as they had when the snapshot was created unless they are explicitly changed in the snapshot"_ ([`Snapshot.kt`][snapshot]). The entry points:

| API                                                         | Role                                                                                                                   |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `Snapshot.takeSnapshot(readObserver)`                       | read-only view; `readObserver` is called for every state object read inside `enter { }`                                |
| `Snapshot.takeMutableSnapshot(readObserver, writeObserver)` | isolated writable view; `apply()` publishes all writes atomically or returns `SnapshotApplyResult.Failure` on conflict |
| `Snapshot.withMutableSnapshot { }`                          | take, run, apply in one call                                                                                           |
| `Snapshot.registerApplyObserver { changed, snapshot -> }`   | told the `Set` of objects changed whenever a snapshot is applied to global state                                       |
| `Snapshot.registerGlobalWriteObserver { obj -> }`           | told of the _first_ write to a global-snapshot object since the last `sendApplyNotifications()`                        |
| `Snapshot.sendApplyNotifications()`                         | advance the global snapshot, delivering pending global writes to apply observers                                       |
| `SnapshotMutationPolicy<T>`                                 | `equivalent(a, b)` decides whether a write is a change; `merge(previous, current, applied)` resolves an apply conflict |

Writes made outside any explicit snapshot (an `onClick` setting `query = "a"`) land in the **global snapshot** and are _not_ yet announced: [`Snapshot.kt`][snapshot-send] — _"Apply notifications for state objects modified outside snapshot are deferred until method is called."_ Something must pump them. On Android that is [`GlobalSnapshotManager`][gsm], a conflating one-slot channel:

```kotlin
val channel = Channel<Unit>(1)
CoroutineScope(AndroidUiDispatcher.Main).launch {
    channel.consumeEach {
        sent.set(false)
        Snapshot.sendApplyNotifications()
    }
}
Snapshot.registerGlobalWriteObserver {
    if (sent.compareAndSet(false, true)) {
        channel.trySend(Unit)
    }
}
```

So a burst of writes in one main-thread task costs one notification, delivered on the next main-loop turn — a batched, not synchronous, propagation step that sits _before_ the frame step below.

The three stock policies ([`SnapshotMutationPolicy.kt`][policy]) are `structuralEqualityPolicy()` (`==`, the default), `referentialEqualityPolicy()` (`===`) and `neverEqualPolicy()` (every write is a change — the escape hatch for event-like state).

### The `Recomposer` and the frame clock

[`Recomposer`][recomposer] is _"The scheduler for performing recomposition and applying updates to one or more [Composition]s."_ Its `runRecomposeAndApplyChanges()` loop ([`Recomposer.kt` L577][recomposer-run]):

1. registers an apply observer that adds each changed object to `snapshotInvalidations` — skipping objects that a `StateObjectImpl` knows were never read in composition ([L1106][recomposer-observer]);
2. suspends in `awaitWorkAvailable()` until there is an invalidation;
3. `parentFrameClock.withFrameNanos { frameTime -> … }` — _"Align work with the next frame to coalesce changes"_ ([L638][recomposer-frame]);
4. inside the frame: first sends the frame time to every coroutine awaiting the `Recomposer`'s own `BroadcastFrameClock` (animations), calls `Snapshot.sendApplyNotifications()` so their writes count, then recomposes invalidated scopes, then applies changes and dispatches `RememberObserver` callbacks and `SideEffect`s.

[`MonotonicFrameClock`][frameclock] is a `CoroutineContext.Element` with one method: _"Suspends until a new frame is requested, immediately invokes [onFrame] with the frame time in nanoseconds in the calling context of frame dispatch, then resumes with the result from [onFrame]."_ The host supplies it (Android's `AndroidUiFrameClock` over `Choreographer`); the test supplies a virtual one. Calling `withFrameNanos` _is_ requesting a frame, so an idle UI requests none.

### Effects are `RememberObserver`s

`remember(keys) { calc }` stores `calc()` in the slot table and recomputes it when any key is unequal to the stored one. A remembered object that implements `RememberObserver` gets `onRemembered()` when the composition that created it is applied, `onForgotten()` when it leaves (or is replaced because its keys changed), and `onAbandoned()` if the composition was discarded first. The dispatcher sends **all forgets before any remembers** ([`RememberEventDispatcher.kt` L209][remember-dispatch]: _"Send forgets and node callbacks"_ … _"Send remembers"_).

`LaunchedEffect` is four lines on top of that ([`Effects.kt` L566][effects-launched]):

```kotlin
public fun LaunchedEffect(key1: Any?, block: suspend CoroutineScope.() -> Unit) {
    val applyContext = currentComposer.applyCoroutineContext
    remember(key1) { LaunchedEffectImpl(applyContext, block) }
}
```

and `LaunchedEffectImpl` ([L492][effects-impl]) launches on remember and cancels on forget:

```kotlin
override fun onRemembered() {
    // This should never happen but is left here for safety
    job?.cancel("Old job was still running!")
    job = scope.launch(block = task)
}

override fun onForgotten() {
    job?.cancel(ExitedCompositionCancellationException())
    job = null
}
```

The rest of the effect family is the same move with a different payload:

| API                                 | Built from                                                            | Runs                                          | Source                               |
| ----------------------------------- | --------------------------------------------------------------------- | --------------------------------------------- | ------------------------------------ |
| `SideEffect { }`                    | `recordSideEffect`                                                    | after **every** successful apply              | [`Effects.kt`][effects]              |
| `DisposableEffect(k) { onDispose }` | `remember(k) { DisposableEffectImpl }`                                | effect on remember, `dispose` on forget       | [`Effects.kt`][effects]              |
| `LaunchedEffect(k) { suspend … }`   | `remember(k) { LaunchedEffectImpl }`                                  | coroutine per key value                       | [`Effects.kt`][effects]              |
| `rememberCoroutineScope()`          | `remember { RememberedCoroutineScope }`                               | scope for event handlers; cancelled on forget | [`Effects.kt`][effects-scope]        |
| `produceState(init, k) { … }`       | `remember { mutableStateOf(init) }` + `LaunchedEffect(k)`             | producer coroutine writing `value`            | [`ProduceState.kt`][produce]         |
| `rememberUpdatedState(v)`           | `remember { mutableStateOf(v) }.apply { value = v }`                  | a cell an old effect reads without restarting | [`SnapshotState.kt` L339][updated]   |
| `Flow.collectAsState(init)`         | `remember { mutableStateOf(init) }` + `LaunchedEffect(flow, context)` | `collect { state.value = it }`                | [`SnapshotFlow.kt` L98][collectinto] |

---

## Evaluation model

**Push-invalidate, pull-recompute, batched per frame.** A write pushes only a _dirty mark_: apply observers receive the changed set and the `Recomposer` records which recompose scopes read those objects. Values are pulled when the scope re-runs on the next frame and reads them again, re-recording its dependencies (dynamic dependency tracking, as in [Solid][solid-signals] and [TC39 signals][tc39-signals]).

- **Lazy vs eager.** Composition is eager-on-frame: an invalid scope is recomposed on the next frame whether or not anything will look at it. `derivedStateOf` is lazy and cached: it recomputes on read only if a dependency's record changed — `isValid` compares the snapshot id/write count and then a hash of dependency record ids ([`DerivedState.kt` L111][derived-valid]).
- **Cold vs hot.** `State` is always hot (it has a current value; reading never starts work). `snapshotFlow` is a cold `Flow` — the docs: _"Use `snapshotFlow` to convert `State<T>` objects into a cold Flow"_ ([side-effects][d-effects]).
- **Glitch-freedom.** Yes, by construction rather than by topological ordering: a recomposition runs inside one snapshot, so every read in that pass sees one consistent version of all state; a half-applied update is never visible, because a mutable snapshot's writes become visible atomically on `apply()`.
- **Synchronous vs batched.** Batched twice: global writes are coalesced into one `sendApplyNotifications()` by the platform pump, and invalidations into one recomposition per frame. There is no synchronous propagation path at all — a write followed by a read of a _derived UI_ in the same callback sees the old UI.

## Composition

The runtime's "operators" are few and value-shaped, not stream-shaped:

| Need                         | Compose                                                           | Notes                                                                                                                                             |
| ---------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| derived value                | plain expression in the composable, or `derivedStateOf { }`       | the docs warn `derivedStateOf` is for _"when your inputs … are changing more often than you need to recompose"_ ([side-effects guide][d-effects]) |
| distinct-until-changed       | `SnapshotMutationPolicy.equivalent`; `derivedStateOf(policy) { }` | built into every write                                                                                                                            |
| state → stream               | `snapshotFlow { }`                                                | emits on change, `!=` filtered                                                                                                                    |
| stream → state               | `collectAsState`, `produceState`                                  | conflating                                                                                                                                        |
| switch / latest-wins         | change a key of `LaunchedEffect` / `produceState`                 | the only built-in concurrency combinator                                                                                                          |
| merge / combine / scan / zip | none — read several states in one block, or go to `Flow`          |                                                                                                                                                   |

The surface is ~10 functions. Everything with time or multiplicity in it — `debounce`, `sample`, `retry`, `combine`, `flatMapLatest` — comes from [Kotlin Flow][kotlin-flow] via `snapshotFlow`. Compose's composition primitive is _the composable function itself_: an `if (enabled) { LaunchedEffect(...) }` adds or removes an effect, which is how conditional subscription is expressed.

## Time and scheduling

**Clocks.** Two, and they are different things:

- The **frame clock** (`MonotonicFrameClock` in the coroutine context): frame-aligned, monotonically increasing, _"may be normalized to the target time for the frame, not necessarily a direct, 'now' value"_ ([`MonotonicFrameClock.kt`][frameclock]). Used by recomposition and animation. A `withFrameNanos` call with no frame clock in context throws.
- **Coroutine time** (`delay`, `withTimeout`): the dispatcher's `Delay`. Effects run on the composition's _apply dispatcher_ (Android: `AndroidUiDispatcher.Main`). Whether its `delay` is backed by the main `Handler` or kotlinx's default delay thread was not checked _(unverified)_; in tests it is the `TestCoroutineScheduler`.

**Schedulers.** The `Recomposer` owns no thread; it runs in whatever coroutine context `runRecomposeAndApplyChanges()` is called from, and effects inherit `applyCoroutineContext` unless they `withContext` elsewhere.

**Debounce: there is none in the runtime.** Two idioms replace it.

_Restart-as-debounce_ — key the effect on the input and `delay` first:

```kotlin
LaunchedEffect(query) {
    delay(300)          // cancelled if `query` changes before it elapses
    result = search(query)
}
```

Each new `query` forgets the old `LaunchedEffectImpl` (cancelling it mid-`delay`) and remembers a new one. This is debounce _and_ latest-wins in one mechanism: if the old effect has already passed the delay and is inside `search`, the same cancellation reaches the search. Its quantum is the frame: the timer starts when the recomposition caused by the keystroke is applied, not at the keystroke.

_Flow debounce_ — bridge to a stream once, and let kotlinx.coroutines do it:

```kotlin
LaunchedEffect(Unit) {
    snapshotFlow { query }
        .debounce(300)
        .collectLatest { q -> result = search(q) }
}
```

`snapshotFlow` is conflated by construction: one `Channel<Unit>(1)` per collector, `trySend(Unit)` from the apply observer, and a re-run of `block` on each receive that emits only when `newValue != lastValue` ([`SnapshotFlow.kt` L538][snapshotflow-impl]). Many writes between two receives yield one re-evaluation of `block` with the latest value.

**Runtime-adjustable duration.** Both idioms support it, with different semantics:

| Variant                                                                                                              | Changing the interval…                                                                                                                                                 |
| -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LaunchedEffect(query, intervalMs) { delay(intervalMs); … }`                                                         | restarts the effect: the pending debounce restarts from zero **and an in-flight hash is cancelled** even though the query did not change                               |
| `LaunchedEffect(query) { delay(currentInterval); … }` with `val currentInterval by rememberUpdatedState(intervalMs)` | takes effect from the next keystroke; a pending `delay` keeps the duration it read when it started                                                                     |
| `snapshotFlow { query to intervalMs }.debounce { it.second }`                                                        | the interval is per element (`debounce(timeoutMillis: (T) -> Long)`, see [Kotlin Flow][kotlin-flow]); an interval change is itself an emission and restarts the window |

## Concurrency and cancellation

**Latest-wins** is "change the key". Cancellation reaches running work through ordinary kotlinx.coroutines structured concurrency: the effect's `Job` is cancelled with `ExitedCompositionCancellationException` (a `CancellationException`, [`Effects.kt`][effects-exited]: _"The coroutine was canceled because it left the composition"_), which resumes any suspended `delay`/`withContext`/`await` with that exception.

**CPU-bound work** goes to another dispatcher with `withContext(Dispatchers.Default) { … }`. Cancellation there is _cooperative_: the block keeps running until it calls a suspending function or checks `ensureActive()`/`isActive`. `withContext` does not return to the caller until its block finishes, and on return it throws if the caller was cancelled, so a stale result is never written back.

**A cancel does not wait.** `onForgotten()` calls `job.cancel()` — it never `join()`s — and the new effect's `onRemembered()` launches immediately after in the same apply pass (forgets are dispatched before remembers, but neither waits for the coroutine). So for a brief window the old hash can still be burning a `Default` thread while the new effect is already in its debounce `delay`. Nothing in Compose bounds that overlap; a hash that never checks for cancellation simply runs to completion and is discarded. The KDoc comment `"Old job was still running!"` shows the one case where the runtime defends against two jobs from the _same_ `LaunchedEffectImpl`.

**Event-driven work** (a button press, not a state change) is _not_ meant to go through keys: the KDoc explicitly says `LaunchedEffect` _"should **not** be used to (re-)launch ongoing tasks in response to callback events by way of storing callback data in [MutableState] passed to [key1]. Instead, see [rememberCoroutineScope]"_ ([`Effects.kt` L566][effects-launched]). Latest-wins for events is then hand-written: keep the `Job`, `cancel()` it before `scope.launch` again.

## Errors and completion

`State` has neither: a cell always holds a value and never completes. Errors are therefore _values in state_ (`Result`, a sealed `Loading/Done/Failed`) or exceptions in effect coroutines.

An exception escaping a `LaunchedEffect` goes to `LaunchedEffectImpl.handleException`, which forwards to the parent context's `CoroutineExceptionHandler` _"`?: throw exception`"_ ([L492][effects-impl]). The effect's `Job` is a child of the composition's effect job, and the `Recomposer`'s `effectJob` is a plain `Job`, not a `SupervisorJob` ([`Recomposer.kt` L292][recomposer-effectjob]), whose completion handler moves the `Recomposer` to `ShuttingDown`. In practice an uncaught effect exception is fatal to the composition (on Android, to the app); catch inside the effect and write a failure value.

`Flow` completion through `collectAsState` simply leaves the last value in the state; a `Flow` error propagates out of the `LaunchedEffect` that `collectInto` launched, with the consequence above. Catching `Exception` broadly inside an effect also catches `CancellationException` — the classic coroutine footgun, which breaks latest-wins silently.

## State and sharing

- **Value cells:** `mutableStateOf` (+ primitive `mutableIntStateOf`/`mutableLongStateOf`/… that avoid boxing), `mutableStateListOf`/`MapOf`/`SetOf`, `derivedStateOf`. All are multicast by nature: any number of readers, each tracked by the reader's own snapshot observer.
- **Conflation everywhere:** writes of an `equivalent` value are not changes; `produceState` _"conflates values; … observers may only see the latest value if several values are set in rapid succession"_ ([`ProduceState.kt`][produce]); `snapshotFlow` re-evaluates once per batch; recomposition runs once per frame.
- **Isolation and merging:** a background thread may `Snapshot.withMutableSnapshot { … }` to update several cells atomically; concurrent conflicting applies call the policy's `merge(previous, current, applied)` ([`SnapshotMutationPolicy.kt` L58][policy-merge]) and fail with `SnapshotApplyConflictException` if it returns `null`. This is a real MVCC transaction model, unusual among UI state libraries.
- **No events.** There is no `Subject`/`SharedFlow` in the runtime; an event that must not be conflated (two identical clicks) belongs in a `Channel`/`SharedFlow`, or in `neverEqualPolicy()` state as a workaround.

## Lifetime and ownership

Ownership is **positional**: every remembered object, effect and `rememberCoroutineScope` belongs to a slot in the composition, and leaves when that call site is no longer executed (an `if` turns false, a list item is removed, the screen is popped) or its keys change. Teardown is guaranteed and paired — `DisposableEffect`: _"There is guaranteed to be one call to [dispose] for every call to [effect]"_ ([`Effects.kt`][effects]). `Recomposer.cancel()` tears the whole tree's effects down; `join()` awaits it.

Leaks happen at the seams: a manually taken `Snapshot` that is never disposed (_"Leaving a snapshot active could cause hard to diagnose memory leaks"_, [`Snapshot.kt`][snapshot]); a lambda captured by a long-lived effect that sees stale values (fixed with `rememberUpdatedState`); a coroutine launched into a scope that outlives the composition (`GlobalScope`, a `ViewModel` scope) which positional ownership cannot see.

## Testing

`ComposeContentTestRule` (from `createComposeRule()`) exposes `mainClock: MainTestClock` ([`ComposeTestRule.jvmAndAndroid.kt`][testrule]), which _"is ultimately responsible for driving all recompositions, all subscribers to [withFrameNanos] … and all coroutines launched with [LaunchedEffect]"_ ([`MainTestClock.kt`][testclock]). The controls:

- `mainClock.autoAdvance = false` — stop the framework advancing time while it waits for idleness.
- `advanceTimeBy(ms)` — rounded **up to whole 16 ms frames** unless `ignoreFrameDuration = true`; `advanceTimeByFrame()`; `advanceTimeUntil { cond }`.
- `mainClock.scheduler: TestCoroutineScheduler` — the scheduler the `Recomposer` and effects run on. `delay`s in effects follow it: _"code like `repeat(2) { delay(1000) }` will complete with a single call to [advanceTimeBy(2000)]"_.
- The v2 `runComposeUiTest` uses a `StandardTestDispatcher` by default ([`v2/ComposeUiTest.kt`][uitest-v2]: _"tasks are queued on the scheduler rather than running eagerly"_), matching `runTest`.

Work moved to `Dispatchers.Default` escapes virtual time; inject the hashing dispatcher and give the test a `StandardTestDispatcher(rule.mainClock.scheduler)` so the debounce and the "hash" share one clock:

```kotlin
@get:Rule val rule = createComposeRule()

@Test fun debouncesAndCancels() {
    val hashDispatcher = StandardTestDispatcher(rule.mainClock.scheduler)
    val hasher = FakeHasher(costMs = 500)
    rule.mainClock.autoAdvance = false
    rule.setContent { FilesetQuery(hasher, hashDispatcher) }

    rule.onNodeWithTag("query").performTextInput("a")
    rule.mainClock.advanceTimeBy(200)                 // inside the 300 ms window
    rule.onNodeWithTag("query").performTextInput("b")
    rule.mainClock.advanceTimeBy(299)
    assertEquals(emptyList(), hasher.started)         // "a" never hashed
    rule.mainClock.advanceTimeBy(32)                  // frame quantum + slack
    assertEquals(listOf("ab"), hasher.started)
    rule.mainClock.advanceTimeBy(500)
    rule.onNodeWithTag("result").assertTextEquals("ab: done")
}
```

The `snapshotFlow` variant can be tested without a UI under `runTest`, with one trap: no `GlobalSnapshotManager` is running, so a bare `query.value = "a"` is never announced. Write through `Snapshot.withMutableSnapshot { query.value = "a" }` (apply notifies) or call `Snapshot.sendApplyNotifications()` after each write, then `advanceTimeBy`.

## The worked pipeline

Idiomatic Compose keeps the four inputs as state and expresses the whole pipeline as one keyed effect that exists only while the toggle is on:

```kotlin
sealed interface HashView {
    data object Idle : HashView
    data class Running(val query: String) : HashView
    data class Done(val query: String, val digest: Digest) : HashView
    data class Failed(val query: String, val error: IOException) : HashView
}

@Composable
fun FilesetQuery(
    hasher: FileSetHasher,
    hashDispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    var query by remember { mutableStateOf("") }
    var intervalMs by remember { mutableLongStateOf(300L) }
    var enabled by remember { mutableStateOf(true) }
    var view by remember { mutableStateOf<HashView>(HashView.Idle) }

    if (enabled) {
        // Identity = (query, intervalMs): a change to either cancels this
        // coroutine — pending delay or running hash — and launches a fresh one.
        LaunchedEffect(query, intervalMs) {
            delay(intervalMs)                                   // debounce
            view = HashView.Running(query)
            view = try {
                HashView.Done(query, withContext(hashDispatcher) { hasher.hash(query) })
            } catch (e: IOException) {                          // never catch CancellationException
                HashView.Failed(query, e)
            }
        }
    }

    Column {
        TextField(query, { query = it }, Modifier.testTag("query"))
        NumberField(intervalMs, { intervalMs = it.coerceIn(0, 5_000) })
        Switch(enabled, { enabled = it; if (!it) view = HashView.Idle })
        Text(view.label(), Modifier.testTag("result"))
    }
}

// On the worker: cooperative cancellation, one check per chunk.
suspend fun FileSetHasher.hash(query: String): Digest {
    val h = Blake3()
    for (file in files.matching(query)) file.chunks().forEach { chunk ->
        currentCoroutineContext().ensureActive()
        h.update(chunk)
    }
    return h.finish()
}
```

Per-event trace (frame period 16 ms, debounce 300 ms):

1. **Keystroke during debounce** (`"a"` → `"ab"` at t = 200 ms of a pending window). `onValueChange` writes `query` in the global snapshot → the global write observer fires once and posts to the pump → next main-loop turn: `sendApplyNotifications()` → the `Recomposer`'s apply observer marks the `FilesetQuery` scope invalid and requests a frame → at the frame, `FilesetQuery` re-runs, `remember(query, intervalMs)` sees a new key → apply: forget old `LaunchedEffectImpl` (`job.cancel()` resumes its `delay` with `CancellationException`; the coroutine ends at once), then remember the new one, which launches and enters `delay(300)`. The window restarts at the _frame_, up to one frame after the keystroke.
2. **Keystroke during hash.** Same path to the forget. The old coroutine is suspended in `withContext(hashDispatcher)`; its cancellation propagates into the worker block, which stops at its next `ensureActive()` (mid-chunk work finishes first). The new effect launches _without waiting_ — the old worker may overlap the new debounce for up to one chunk. When the old `withContext` unwinds, it throws, so `view = Done(old)` never executes; `view` still says `Running(old)` until the new effect writes `Running(new)` 300 ms later — a UI that wants "stale" feedback must write it on the keystroke itself.
3. **Interval change** (`300` → `800`). `intervalMs` is a key, so this is indistinguishable from a keystroke: any pending debounce restarts with 800 ms, and **an in-flight hash of an unchanged query is cancelled and redone**. Keying on `query` alone and reading `rememberUpdatedState(intervalMs)` avoids the spurious rehash at the cost of the new interval only applying from the next keystroke — the [Time and scheduling](#time-and-scheduling) table.
4. **Toggle off.** `enabled = false` → next frame `if (enabled)` is false, the `LaunchedEffect` call site is gone → `onForgotten()` cancels the job, whether it is in `delay` (pending debounce dropped) or in `withContext` (hash cancelled, cooperatively, not awaited). Toggling on later creates a fresh effect with the current `(query, intervalMs)`, so the pipeline re-runs once for the current query — Compose does not remember that the result was already computed.

**Fit for a per-frame UI.** This is the closest model in the survey to sparkles' shape: the UI really is re-executed per frame, and _the tree itself is the subscription graph_ — an effect's existence is decided by whether this frame's build reaches it, and its restart by whether its keys differ from last frame's. A D port needs only `remember`-with-keys in the widget tree, an `onRemembered/onForgotten` pair per slot, and an `event-horizon` scope per effect. The misfits: (a) latency is quantized to frames, and the debounce starts at the frame, not the event; (b) "key changed" is the only switch, so _which_ inputs restart the work (interval vs query) must be designed per effect; (c) cancellation is fire-and-forget, so CPU-bound work overlaps its successor unless the library adds an optional "await the cancelled sibling" policy; (d) sparkles apps rebuild every frame unconditionally, so the snapshot-read-tracking half of Compose (deciding _whether_ to re-run) is unnecessary, while the keyed-effect half (deciding _what lives_) is exactly what is missing.

---

## Strengths

- One mechanism — keyed `remember` + `RememberObserver` — gives debounce, latest-wins, conditional pipelines and guaranteed teardown, with no operator vocabulary to learn.
- Glitch-free by snapshot isolation, and transactional: multi-cell updates from any thread apply atomically, with policy-driven conflict merging.
- Conflation is uniform and principled (state is lossy; events are not state), stated in the source and respected by every API.
- Effects are ordinary structured-concurrency coroutines; nothing new is needed for cancellation, timeouts or worker threads.
- Deterministic tests: one `TestCoroutineScheduler` drives frames, `delay`s and (with injection) worker dispatchers.

## Weaknesses

- No time or combination operators; anything beyond "restart on key" means bridging to `Flow` and back (`snapshotFlow` … `collectAsState`).
- Keys are a manual, error-prone dependency list — the docs devote a section to _"Restarting effects less than they should could cause bugs … more than they should could be inefficient"_.
- Cancellation never awaits the cancelled work; CPU-bound successors overlap, and a non-cooperative worker is silently wasted.
- Frame quantization of every reaction; and global writes need a platform pump (`GlobalSnapshotManager`), an easy-to-miss piece in hosts and tests.
- An uncaught effect exception is fatal to the composition; errors must be manually reified as state.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                                 | Trade-off                                                                                 |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| MVCC snapshots for all UI state                             | Composition can run speculatively, be discarded, and (in future) run in parallel          | Record bookkeeping on every state object; `Snapshot` lifetimes must be managed            |
| Push dirty marks, pull values on the next frame             | Coalesces any number of writes into one recomposition; glitch-free reads                  | Every reaction waits for a frame; no synchronous derived read after a write               |
| Effect identity = its keys (`remember(keys)`)               | Latest-wins and teardown fall out of the slot table with no stream operators              | Keys are hand-maintained; restart granularity is all-or-nothing per effect                |
| Cancel on forget, never join                                | Applying changes must not block on user coroutines; the UI thread stays responsive        | Cancelled and new work overlap; no back-pressure on CPU-bound successors                  |
| Conflate state everywhere (`equivalent`, one-slot channels) | State is idempotent by definition; dropping intermediates is always correct for rendering | Events cannot be modelled as state; needs a separate channel abstraction                  |
| Time lives in coroutines (`delay`) and the frame clock only | Keeps the runtime tiny and reuses kotlinx.coroutines and its test scheduler               | Debounce/throttle are idioms with subtly different semantics, not one documented operator |
| Effects run only after a successful apply                   | A discarded speculative composition never starts or leaks work                            | Effects start one apply later than the state change that caused them                      |

## Sources

- androidx at `296313a488a01c84ddcb0801d4efee640a14070c` (2026-11-21): [`Effects.kt`][effects], [`SnapshotFlow.kt`][snapshotflow], [`ProduceState.kt`][produce], [`SnapshotState.kt`][updated], [`SnapshotMutationPolicy.kt`][policy], [`DerivedState.kt`][derived-valid], [`MonotonicFrameClock.kt`][frameclock], [`Recomposer.kt`][recomposer], [`snapshots/Snapshot.kt`][snapshot], [`internal/RememberEventDispatcher.kt`][remember-dispatch], [`GlobalSnapshotManager.android.kt`][gsm], [`MainTestClock.kt`][testclock], [`v2/ComposeUiTest.kt`][uitest-v2], [`ComposeTestRule.jvmAndAndroid.kt`][testrule], [`libraryversions.toml`][versions], [`LICENSE.txt`][license].
- Android Developers: [Side-effects in Compose][d-effects], [Thinking in Compose][d-mental], [State and Jetpack Compose][d-state], [`androidx.compose.runtime` reference][d-api] (fetched 2026-11-22).
- Related deep-dives: [Kotlin Flow][kotlin-flow], [RxJS][rxjs], [Solid signals][solid-signals], [TC39 signals][tc39-signals], [Elm][elm], [Mosaic][mosaic], [incremental computation][incremental]; umbrella [index][index], [concepts][concepts], [comparison][comparison]; sparkles [`event-horizon` spec][eh-spec].

<!-- References -->

[repo]: https://github.com/androidx/androidx/tree/296313a488a01c84ddcb0801d4efee640a14070c
[license]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/LICENSE.txt
[versions]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/libraryversions.toml#L35
[effects]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Effects.kt
[effects-impl]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Effects.kt#L492
[effects-launched]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Effects.kt#L566
[effects-exited]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Effects.kt#L648
[effects-scope]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Effects.kt#L865
[snapshotflow]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/SnapshotFlow.kt#L604
[snapshotflow-impl]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/SnapshotFlow.kt#L538
[collectinto]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/SnapshotFlow.kt#L98
[produce]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/ProduceState.kt#L78
[updated]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/SnapshotState.kt#L339
[policy]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/SnapshotMutationPolicy.kt#L40
[policy-merge]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/SnapshotMutationPolicy.kt#L58
[derived-valid]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/DerivedState.kt#L111
[frameclock]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/MonotonicFrameClock.kt
[recomposer]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Recomposer.kt#L186
[recomposer-effectjob]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Recomposer.kt#L292
[recomposer-run]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Recomposer.kt#L577
[recomposer-frame]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Recomposer.kt#L638
[recomposer-observer]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Recomposer.kt#L1106
[snapshot]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/snapshots/Snapshot.kt#L45
[snapshot-send]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/snapshots/Snapshot.kt#L700
[remember-dispatch]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/internal/RememberEventDispatcher.kt#L209
[gsm]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/platform/GlobalSnapshotManager.android.kt#L38
[testclock]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test/src/commonMain/kotlin/androidx/compose/ui/test/MainTestClock.kt#L81
[uitest-v2]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test/src/commonMain/kotlin/androidx/compose/ui/test/v2/ComposeUiTest.kt#L43
[testrule]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test-junit4/src/jvmAndAndroidMain/kotlin/androidx/compose/ui/test/junit4/ComposeTestRule.jvmAndAndroid.kt#L405
[d-effects]: https://developer.android.com/develop/ui/compose/side-effects
[d-mental]: https://developer.android.com/develop/ui/compose/mental-model
[d-state]: https://developer.android.com/develop/ui/compose/state
[d-api]: https://developer.android.com/reference/kotlin/androidx/compose/runtime/package-summary
[kotlin-flow]: ./kotlin-flow.md
[rxjs]: ./rxjs.md
[solid-signals]: ./solid-signals.md
[tc39-signals]: ./tc39-signals.md
[elm]: ./elm.md
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[mosaic]: ../tui-libraries/mosaic.md
[incremental]: ../parsing/theory/incremental.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
