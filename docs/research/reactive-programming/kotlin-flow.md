# Kotlin Flow (Kotlin / kotlinx.coroutines)

Cold, suspending, sequential streams built directly on Kotlin coroutines and structured concurrency, with `StateFlow`/`SharedFlow` as the hot, multicast layer on top. It is the reactive stack of Android and Kotlin Multiplatform.

| Field             | Value                                                                                                                             |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Kotlin 2.2.20 (Multiplatform: JVM, JS, Wasm, Native)                                                                              |
| License           | Apache-2.0 ([`LICENSE.txt`][license])                                                                                             |
| Repository        | [Kotlin/kotlinx.coroutines][repo] (`kotlinx-coroutines-core`, `kotlinx-coroutines-test`)                                          |
| Documentation     | [Flow guide][docs-flow] · [Cancellation and timeouts][docs-cancel] · [API reference][api] · [`kotlinx-coroutines-test`][api-test] |
| Category          | Push-based streams with suspension backpressure; coroutine library, not a language feature                                        |
| Versions surveyed | `1.11.0` (top of [`CHANGES.md`][changes]; [`gradle.properties`][gradle] reads `version=1.11.0-SNAPSHOT`) at `7f4d6cf`, 2026-11-18 |
| Core abstraction  | `Flow<T>` — an interface with one method, `suspend fun collect(collector: FlowCollector<T>)`                                      |

> [!NOTE]
> Line references are to commit `7f4d6cf2414937b50291df6169a69afbaf9c5a20` (2026-11-18). `debounce`, `sample` and `timeout` are still `@FlowPreview`; `transformLatest`, `flatMapLatest` and `mapLatest` are still `@ExperimentalCoroutinesApi` — after seven years in the API, the latest-wins family is not formally stable.

---

## Overview

### What it solves

Kotlin coroutines give one value per `suspend` call. `Flow` extends that to _many_ values over time without introducing a second concurrency model: an operator is an ordinary `suspend` function, a subscription is a coroutine, an unsubscription is that coroutine's cancellation, and backpressure is the fact that `emit` suspends until the downstream `collect` lambda returns. Where [RxJS][rxjs] needs `Subscription`, `Scheduler` and a disposal protocol, `Flow` borrows all three from the coroutine machinery it sits on: `CoroutineScope`/`Job` for lifetime, `CoroutineDispatcher` for scheduling, and `CancellationException` for teardown.

The second problem it solves is _state_: `StateFlow` is a conflated, always-initialised, thread-safe value cell that is also a `Flow`, which is what Android UI layers (and [Jetpack Compose][compose] via `collectAsState`) consume.

### Design philosophy

Two invariants are written into the contract of the interface itself ([`flow/Flow.kt`][flow-kt]):

> _"All implementations of the `Flow` interface must adhere to two key properties described in detail below: Context preservation. Exception transparency. These properties ensure the ability to perform local reasoning about the code with flows and modularize the code in such a way that upstream flow emitters can be developed separately from downstream flow collectors."_

And on cold-by-default ([same file][flow-kt]):

> _"Intermediate operations do not execute any code in the flow and are not suspending functions themselves. They only set up a chain of operations for future execution and quickly return. This is known as a *cold flow* property."_

The rest of the design follows: sequential by default (_"all flow operations are executed sequentially in the same coroutine, with an exception for a few operations specifically designed to introduce concurrency"_), a small number of channel-backed operators that introduce concurrency explicitly, and cancellation that is _cooperative_ because it is coroutine cancellation (see [Concurrency and cancellation](#concurrency-and-cancellation)).

---

## How it works

A `Flow` is a value holding a suspending procedure. `flow { emit(x) }` builds one; `collect` runs it _in the collector's coroutine_, calling the collector's `emit` inline. A chain `source.map(f).filter(p).collect(g)` therefore runs as nested function calls on one coroutine's stack — no queue, no thread hop, no allocation per element beyond what `f`/`p` allocate.

```kotlin
public interface Flow<out T> {
    public suspend fun collect(collector: FlowCollector<T>)
}
```

Concurrency enters only through **channel flows** ([`flow/internal/ChannelFlow.kt`][channelflow-kt]): `buffer`, `conflate`, `flowOn`, `channelFlow`, `callbackFlow`, `produceIn`, and the `*Latest`/`flatMapMerge` operators (all subclasses of `ChannelFlow`). Each launches a producer coroutine that sends into a `Channel` and a consumer that receives from it. Adjacent channel flows **fuse** through `FusibleFlow.fuse(context, capacity, onBufferOverflow)` so a chain like `.flowOn(Dispatchers.IO).buffer(10).conflate()` creates one channel, not three ([`flow/operators/Context.kt`][context-kt]: _"Adjacent applications of [channelFlow], [flowOn], [buffer], and [produceIn] are always fused so that only one properly configured channel is used for execution."_). `conflate()` is literally `buffer(CONFLATED)`, desugared to `(capacity = 0, DROP_OLDEST)`.

Time-based operators (`debounce`, `sample`, `timeout`) are built on `scopedFlow` ([`flow/internal/FlowCoroutine.kt`][flowcoroutine-kt]): a `flow { flowScope { … } }` that gives the operator a private `CoroutineScope` in which to `produce` the upstream into a channel and then `select` between "next value" and "timer fired".

Hot flows are separate implementations of the same interface: `MutableSharedFlow` ([`flow/SharedFlow.kt`][sharedflow-kt]) is a lock-protected ring buffer of slots with one slot per subscriber; `MutableStateFlow` ([`flow/StateFlow.kt`][stateflow-kt]) is a single value plus per-collector slots, documented as _"optimized for memory consumption and allocation-freedom"_.

---

## Evaluation model

- **Push, with suspension as backpressure.** Values are pushed by `emit`, but `emit` is a `suspend` call that returns only when the downstream has processed the value. A slow collector therefore slows the producer — the Reactive Streams `request(n)` dance collapses into a function return. The docs claim _"Flow is [Reactive Streams] compliant"_ via `kotlinx-coroutines-reactive` ([`Flow.kt`][flow-kt]).
- **Cold and lazy by default.** Each `collect` re-runs the whole upstream: _"Each call to `collect()` runs the entire cold flow from the beginning"_ ([`docs/topics/coroutines-flow.md`][topic-flow]). The type does not say whether a flow is cold or hot — `SharedFlow`/`StateFlow` are hot subtypes, and `shareIn`/`stateIn`/`produceIn` convert.
- **Synchronous within a coroutine, batched across channels.** Without channel operators the whole chain runs synchronously per element. A `flowOn` across dispatchers inserts a `BUFFERED` (64-element default) channel, so the producer races ahead of the consumer.
- **No glitch-freedom.** There is no dependency graph and no topological propagation. `combine` ([`flow/internal/Combine.kt`][combine-kt]) runs one coroutine per source, funnels `Update(index, value)` into a shared channel, and calls `yield()` after every send _"to emulate fairness"_; the consumer drains a batch and bails out as soon as it sees _"two values from the same source"_. A diamond (`a.map(f)` combined with `a.map(g)`) can and does emit an inconsistent intermediate pair. `StateFlow` updates are conflated by `equals`, which _hides_ some intermediate states but guarantees nothing transactional. Contrast the push-pull signal graphs in [Solid signals][solid] and [TC39 signals][tc39].

---

## Composition

The operator surface is moderate — about 80 distinct public operator names (counting overloads once) across `flow/operators/*.kt` and `flow/terminal/*.kt` (`Transform.kt`, `Limit.kt`, `Merge.kt`, `Zip.kt`, `Delay.kt`, `Distinct.kt`, `Errors.kt`, `Emitters.kt`, `Share.kt`, `Context.kt`), much smaller than RxJS. It stays small because `transform { value -> … emit(…) }` and plain `suspend` lambdas make most bespoke operators one-liners: `map`, `filter`, `onEach` are `transform` specialisations, and a "delay then emit" is just `delay(n); emit(x)` inside a lambda.

| Family        | Operators                                                                                                   |
| ------------- | ----------------------------------------------------------------------------------------------------------- |
| Builders      | `flow {}`, `flowOf`, `asFlow`, `channelFlow {}`, `callbackFlow {}`, `MutableStateFlow`, `MutableSharedFlow` |
| Element-wise  | `map`, `filter`, `transform`, `onEach`, `scan`/`runningFold`, `distinctUntilChanged[By]`                    |
| Flattening    | `flatMapConcat`, `flatMapMerge(concurrency)`, `flatMapLatest`, `transformLatest`, `mapLatest`, `merge`      |
| Combining     | `combine` (2–5 arity + `Iterable`), `combineTransform`, `zip`                                               |
| Time          | `debounce` (4 overloads), `sample`, `timeout`                                                               |
| Buffering     | `buffer(capacity, onBufferOverflow)`, `conflate`, `flowOn`                                                  |
| Errors / life | `catch`, `retry`, `retryWhen`, `onCompletion`, `onStart`, `onEmpty`                                         |
| Sharing       | `shareIn`, `stateIn` (both scope-taking)                                                                    |
| Terminal      | `collect`, `collectLatest`, `launchIn`, `first`, `single`, `toList`, `reduce`, `fold`                       |

Derived values are flows: `val total = a.combine(b) { x, y -> x + y }` is cold until collected, and becomes a readable cell only through `stateIn(scope, started, initial)`. There is no `computed`/`derived` cell with synchronous `.value` reads that recompute on demand — the missing piece that motivates the signals libraries.

---

## Time and scheduling

**Clocks.** There is no clock object in the API. Time is `delay(ms)`/`select { onTimeout(ms) }`, which ask the current `CoroutineDispatcher` (via its `Delay` interface, [`Delay.kt`][delay-core-kt]) to resume later. The clock is therefore whatever the dispatcher implements: wall-clock for `Dispatchers.Default`/`Main`, virtual time for a `TestDispatcher`. A dispatcher is a scheduler; `Dispatchers.Main` integrates with the host UI loop (Android `Looper`, Swing, JavaFX).

**No frames.** Flow has no notion of a frame. UI integration is "collect on `Dispatchers.Main` and write into the UI state"; frame alignment is the UI toolkit's problem (Compose snapshots, see [Jetpack Compose][compose]).

**How `debounce` is implemented** ([`flow/operators/Delay.kt`][delay-kt]). All four overloads — `debounce(timeoutMillis: Long)`, `debounce(timeoutMillis: (T) -> Long)`, `debounce(timeout: Duration)`, `debounce(timeout: (T) -> Duration)` — funnel into one private `debounceInternal(timeoutMillisSelector: (T) -> Long)`; the constant overload is `debounceInternal { timeoutMillis }`. Its core is a `scopedFlow` that `produce`s the upstream into a rendezvous channel and loops on a `select`:

```kotlin
// kotlinx-coroutines-core/common/src/flow/operators/Delay.kt (abridged)
while (lastValue !== DONE) {
    var timeoutMillis = 0L
    if (lastValue != null) {
        timeoutMillis = timeoutMillisSelector(NULL.unbox(lastValue))
        require(timeoutMillis >= 0L) { "Debounce timeout should not be negative" }
        if (timeoutMillis == 0L) { downstream.emit(NULL.unbox(lastValue)); lastValue = null }
    }
    select<Unit> {
        if (lastValue != null) onTimeout(timeoutMillis) {
            downstream.emit(NULL.unbox(lastValue)); lastValue = null
        }
        values.onReceiveCatching { value ->
            value.onSuccess { lastValue = it }
                .onFailure {
                    it?.let { throw it }
                    if (lastValue != null) downstream.emit(NULL.unbox(lastValue)) // flush on completion
                    lastValue = DONE
                }
        }
    }
}
```

Every arriving value re-enters the loop, so the `onTimeout` clause is re-registered from zero: the timer restarts on each value. The upstream end flushes the pending value; an upstream error is rethrown and the pending value is dropped.

**Can the duration change at runtime?** Yes, through the selector overload — and this is the most precise answer any surveyed library gives. The selector is called **once per arriving value, at arrival time**, and its result is that value's quiet period. A selector that reads a cell (`debounce { interval.value }`) thus picks up a new interval on the _next_ value; a timer already armed keeps the duration it was armed with. Returning `0` emits immediately — [`DebounceTest.kt`][debounce-test]'s `testDebounceSelectorBasic` uses `if (it == 1) 0 else 1000` to pass the first value through undelayed. To make an interval change itself restart the timer, the interval must be an _input_ (`combine(query, interval)` then `debounce { (_, n) -> n }`), see [The worked pipeline](#the-worked-pipeline).

**`sample(periodMillis)`** uses a `CONFLATED` producer plus a `fixedPeriodTicker` (`produce(capacity = 0) { delay; send(Unit) }`) and emits the latest value per tick; its period is fixed at construction, and the source carries a `// todo: shall be start sampling only when an element arrives or sample aways as here?`.

---

## Concurrency and cancellation

**Latest-wins** is `transformLatest`, with `mapLatest`, `flatMapLatest` and `collectLatest` as thin wrappers ([`flow/operators/Merge.kt`][merge-ops-kt], [`flow/terminal/Collect.kt`][collect-kt]). The whole mechanism is a dozen lines in `ChannelFlowTransformLatest` ([`flow/internal/Merge.kt`][merge-internal-kt]):

```kotlin
override suspend fun flowCollect(collector: FlowCollector<R>) {
    coroutineScope {
        var previousFlow: Job? = null
        flow.collect { value ->
            previousFlow?.apply {
                cancel(ChildCancelledException())
                join()
            }
            // Do not pay for dispatch here, it's never necessary
            previousFlow = launch(start = CoroutineStart.UNDISPATCHED) {
                collector.transform(value)
            }
        }
    }
}
```

Three findings:

1. **A cancel waits for the cancelled work to finish.** `cancel(…)` is followed by `join()`, which per [`Job.kt`][job-kt] _"Suspends the coroutine until this job is complete"_ and _"the job becomes complete only when all its children are complete"_. At most one `transform` body is ever alive; a new value cannot start work until the old work has acknowledged cancellation and run its `finally` blocks. While the old work is unwinding, the upstream `collect` is suspended in `join()`.
2. **`ChildCancelledException`** cancels the child without cancelling the enclosing scope — a sibling-local cancel, the same trick `sample` uses on its ticker.
3. **`UNDISPATCHED` start** runs the new body inline up to its first suspension, so a latest-wins hop costs no dispatcher round-trip. `collectLatest` adds `buffer(0)` so that sequential sources like `flowOf(1, 2, 3)` really drop the earlier values.

**How cancellation reaches running work.** It is cooperative ([`docs/topics/coroutines-cancellation.md`][topic-cancel]):

> _"In Kotlin, coroutine cancellation is *cooperative*. Coroutines react to cancellation only when they cooperate by suspending or checking for cancellation explicitly."_

Cancelling a `Job` sets a flag and resumes any suspended `suspendCancellableCoroutine` with `CancellationException`; code that never suspends never notices. The tools are `ensureActive()` (throws if cancelled, [`Job.kt`][job-kt]/[`CoroutineScope.kt`][scope-kt]), `isActive`, and `yield()` ([`Yield.kt`][yield-kt]), which also lets other coroutines on the same dispatcher run. The `flow {}` builder calls `ensureActive` on every `emit` ([`flow/Builders.kt`][builders-kt]: _"Emissions from [flow] builder are [cancellable] by default — each call to [emit] also calls [ensureActive]"_).

**CPU-bound work** goes to `withContext(Dispatchers.Default) { … }`. `withContext` is a scoped coroutine: when the caller is cancelled, the block's `Job` is cancelled, but `withContext` does not return until the block completes. Its return path has a _"prompt cancellation guarantee"_ ([`Builders.common.kt`][builders-common-kt]) — a result produced after the caller was cancelled is discarded and `CancellationException` thrown — so a late hash result is never delivered. For blocking JVM calls, `runInterruptible(context) { … }` ([`jvm/src/Interruptible.kt`][interruptible-kt]) maps cancellation to `Thread.interrupt()`; it is JVM-only and only helps code that honours interrupts.

> [!IMPORTANT]
> Put together: in `mapLatest { withContext(Dispatchers.Default) { hash(it) } }`, a new value cancels the old hash and then **blocks** until the hashing loop next calls `ensureActive()`/`yield()`. Cancellation latency equals the hash's check interval; a hash that never checks runs to completion, and the next one starts only afterwards. The library guarantees serialisation and no stale delivery, not prompt stop.

---

## Errors and completion

- **Exceptions, not values.** A flow completes normally (the `collect` call returns) or exceptionally (it throws). `Throwable` is the error channel; there is no typed error parameter as in [Effect][effect-ts] or ZIO ([`scala-zio.md`][zio]).
- **Exception transparency** is enforced at runtime: _"Flow machinery enforces exception transparency at runtime and throws [IllegalStateException] on any attempt to emit a value, if an exception has been thrown on previous attempt"_ ([`Flow.kt`][flow-kt]). An upstream may not swallow a downstream exception.
- **`catch` is positional.** It _"catches exceptions in emitData and computeOne"_ — everything above it — and is transparent to downstream failures and to cancellation ([`flow/operators/Errors.kt`][errors-kt]). `retry`/`retryWhen` re-collect the upstream; `onCompletion` is the declarative `finally`.
- **Cancellation is an exception** (`CancellationException`), and every operator must let it pass. This is the single biggest footgun: a `catch (e: Exception)` inside a `transform` swallows cancellation.
- **Hot flows never complete.** `StateFlow` and `SharedFlow` _"never complete"_; `SharedFlow.collectLatest` returns `Nothing`. A `StateFlow` _"cannot be closed … and can never represent a failure"_ ([`StateFlow.kt`][stateflow-kt]). Under `shareIn`/`stateIn`, an upstream failure _"terminates the sharing coroutine without affecting any of the subscribers, and will be handled by the [scope]"_ ([`flow/operators/Share.kt`][share-kt]) — subscribers just stop receiving. Errors that must reach the UI are modelled as values (`Result<T>` or a sealed `UiState`).

---

## State and sharing

| Type                | Hot | Replay                | Overflow                                  | Equality conflation | Completes |
| ------------------- | --- | --------------------- | ----------------------------------------- | ------------------- | --------- |
| `Flow` (cold)       | no  | n/a — re-runs         | suspends `emit`                           | no                  | yes       |
| `MutableSharedFlow` | yes | `replay` (default 0)  | `SUSPEND` / `DROP_OLDEST` / `DROP_LATEST` | no                  | never     |
| `MutableStateFlow`  | yes | 1, always initialised | conflated (latest wins)                   | `Any.equals`        | never     |

- **`StateFlow` is a conflated value cell.** _"Updates to the [value] are always [conflated]. So a slow collector skips fast updates, but always collects the most recently emitted value"_; it is specified as `MutableSharedFlow(replay = 1, onBufferOverflow = DROP_OLDEST)` plus `distinctUntilChanged()` ([`StateFlow.kt`][stateflow-kt]). `value` is readable synchronously from any thread; `update { }` is a CAS loop. Updating costs `O(N)` in subscribers.
- **`SharedFlow` buffer semantics** ([`SharedFlow.kt`][sharedflow-kt]): `replay` + `extraBufferCapacity` slots; `onBufferOverflow` other than `SUSPEND` makes `emit` never suspend. A subtle rule: _"Buffer overflow condition can happen only when there is at least one subscriber that is not ready to accept the new value."_ With zero subscribers, `emit` never suspends and everything beyond `replay` is dropped — events sent before the UI subscribes vanish.
- **Fusion with state.** `flowOn`, `conflate`, `buffer(CONFLATED|RENDEZVOUS)`, `distinctUntilChanged` and `cancellable` applied to a `StateFlow` _"has no effect"_ — they are fused away.
- **`stateIn`/`shareIn`** convert cold to hot inside a caller-provided scope, controlled by `SharingStarted` ([`SharingStarted.kt`][sharingstarted-kt]): `Eagerly`, `Lazily`, or `WhileSubscribed(stopTimeoutMillis = 0, replayExpirationMillis = Long.MAX_VALUE)`. `WhileSubscribed` starts the upstream on the first subscriber and stops it `stopTimeoutMillis` after the last leaves; `SharingStarted` is itself a `fun interface` mapping `subscriptionCount: StateFlow<Int>` to a `Flow<SharingCommand>`, so custom policies are user code. The Android idiom `WhileSubscribed(5_000)` exists to survive configuration changes without restarting work.

---

## Lifetime and ownership

- **Every collection is owned by a coroutine, every coroutine by a scope.** `flow.launchIn(scope)` / `scope.launch { flow.collect { } }`; cancelling the scope cancels the collector, which cancels the upstream chain inside it, including every channel-flow producer, which are child coroutines. There is no `Subscription` object to forget to dispose — the leak shape is instead "launched in a scope that lives too long" (`GlobalScope`; the `flow {}` docs list `GlobalScope.launch { … }` emission as prohibited).
- **Context preservation** pins where code runs: _"There is only one way to change the context of a flow: the [flowOn] operator that changes the upstream context"_ ([`Flow.kt`][flow-kt]); `flowOn` rejects a context containing a `Job` (`checkFlowContext`), so a flow cannot escape its collector's lifetime.
- **Callback bridges must clean up.** `callbackFlow` requires `awaitClose { api.unregister(callback) }`: _"Using [awaitClose] is mandatory in order to prevent memory leaks when the flow collection is cancelled"_, and the builder throws `IllegalStateException` if the block returns without it ([`Builders.kt`][builders-kt]).
- **Hot flows hold a scope.** `stateIn(scope, …)` launches a sharing coroutine in `scope`; it lives until `scope` is cancelled (or `WhileSubscribed` stops it). The cell itself outlives the upstream and keeps its last value.

---

## Testing

`kotlinx-coroutines-test` ([`TestBuilders.kt`][testbuilders-kt], [`TestCoroutineScheduler.kt`][testscheduler-kt]) provides virtual time:

- `runTest { }` runs the body on a `TestScope` whose dispatchers share a `TestCoroutineScheduler`; it _"will skip delays"_ — _"Delay skipping is achieved by using virtual time"_. A 60-second wall-clock timeout guards against real hangs.
- `StandardTestDispatcher` queues tasks and runs them only when the scheduler is driven: `runCurrent()`, `advanceUntilIdle()`, `advanceTimeBy(ms)`, with `currentTime` readable. `UnconfinedTestDispatcher` enters `launch` eagerly ([`TestCoroutineDispatchers.kt`][testdispatchers-kt]).
- `advanceTimeBy(d)` runs tasks scheduled for `currentTime ..< currentTime + d` — **exclusive** of the end, so a debounce armed for exactly `d` needs a following `runCurrent()` to fire.
- `backgroundScope` ([`TestScope.kt`][testscope-kt]) hosts never-completing collectors (any `StateFlow` collection) and is cancelled at the end of the test.
- **Only test dispatchers are virtual.** `runTest`'s own docs warn that `delay` inside `Dispatchers.Default` _"doesn't know about TestCoroutineScheduler"_. A pipeline that hard-codes `withContext(Dispatchers.Default)` is not deterministically testable; inject the dispatcher.

A deterministic debounce test:

```kotlin
@Test fun debouncesAndCancels() = runTest {
    val query = MutableStateFlow("")
    val out = mutableListOf<String>()
    backgroundScope.launch { // runTest's StandardTestDispatcher: queued, not started
        query.drop(1).debounce(300).mapLatest { q -> delay(1_000); "hash($q)" }.toList(out)
    }
    runCurrent() // subscribe now, so drop(1) drops the initial "" and not "a"
    query.value = "a"; advanceTimeBy(200)
    query.value = "ab"; advanceTimeBy(300); runCurrent() // debounce fires at t=500
    advanceTimeBy(500)                                   // hash half done
    query.value = "abc"; advanceTimeBy(300); runCurrent() // old hash cancelled
    advanceUntilIdle()
    assertEquals(listOf("hash(abc)"), out)
}
```

The library's own suite uses the same pattern (`DebounceTest.kt`, `FlatMapLatestTest.kt`, `TransformLatestTest.kt` under [`common/test/flow/operators/`][debounce-test]). The community library [Turbine][turbine] wraps a flow in `flow.test { assertEquals("one", awaitItem()); awaitComplete() }`, turning emissions into an awaitable queue on top of `runTest`.

---

## The worked pipeline

```kotlin
class FilesetViewModel(
    private val scope: CoroutineScope,
    private val cpu: CoroutineDispatcher = Dispatchers.Default, // injectable for tests
) {
    val query    = MutableStateFlow("")
    val interval = MutableStateFlow(300L)   // from the numeric field
    val enabled  = MutableStateFlow(true)   // the toggle

    val result: StateFlow<HashState> = enabled
        .flatMapLatest { on ->
            if (!on) flowOf(HashState.Off)
            else combine(query, interval, ::Pair)
                .debounce { (_, n) -> n }               // per-value duration
                .map { (q, _) -> q }
                .distinctUntilChanged()                 // an interval change alone does not re-hash
                .mapLatest { q ->
                    HashState.Done(withContext(cpu) { hashFileset(q) }) // ensureActive() inside the loop
                }
                .onStart { emit(HashState.Pending) }
                .catch { e -> emit(HashState.Failed(e)) }
        }
        .stateIn(scope, SharingStarted.WhileSubscribed(5_000), HashState.Off)
}

suspend fun hashFileset(q: String): Digest {
    val h = Blake3()
    for (file in walk(q)) { currentCoroutineContext().ensureActive(); h.update(read(file)) }
    return h.digest()
}
```

Per-event trace (times in ms; `N = 300`):

1. **Keystroke during debounce.** `query.value = "ab"` at t=200 conflates into the `StateFlow`; its collector in `combine` sends `Update(0, "ab")`, `combine` emits `("ab", 300)`; `debounce`'s `produce` coroutine hands it over the rendezvous channel; `onReceiveCatching` wins the `select`, replaces `lastValue`, and the loop re-arms `onTimeout(300)` from t=200. The t=0 timer is simply abandoned with the losing `select` clause. Nothing downstream runs.
2. **Keystroke during hash.** At t=500 the debounce emits `"ab"`; `mapLatest` launches `UNDISPATCHED` and enters `withContext(cpu)`. A keystroke at t=700 only restarts the debounce — **the running hash is not cancelled yet**. At t=1000 `"abc"` reaches `transformLatest`, which calls `cancel(ChildCancelledException())` on the old `Job`, then `join()`s: the upstream collector suspends until the hashing loop's next `ensureActive()` throws and `withContext` unwinds. The cancelled result is never emitted (prompt-cancellation guarantee), then the `"abc"` hash launches. Cancelling on the keystroke itself requires moving the delay inside the latest-wins operator: `query.transformLatest { q -> delay(interval.value); emit(withContext(cpu) { hashFileset(q) }) }`.
3. **Interval change.** `interval.value = 800` is a new `combine` emission `("abc", 800)`: debounce stores it and arms an 800 ms timer — the change _restarts_ the quiet period with the new length. After it fires, `distinctUntilChanged` drops the unchanged `"abc"`, so no re-hash. With the simpler `query.debounce { interval.value }`, the new value would only apply to the next keystroke.
4. **Toggle off.** `enabled.value = false` reaches `flatMapLatest`, which cancels and joins the inner flow: that cancels `debounce`'s `flowScope` (its `produce` child and pending `onTimeout` go with it — **a pending debounce is discarded, not flushed**, because the upstream was cancelled rather than completed) and the `mapLatest` scope, cancelling the hash at its next check. Only then does `flowOf(HashState.Off)` emit. Toggling on again re-collects `query`, whose replayed current value re-triggers a full debounce and hash.

**Fit for a per-frame UI.** The pipeline maps well onto an event-loop host: `StateFlow` is exactly the "cell the frame reads" — an immediate-mode frame reads `result.value` synchronously, with no subscription. What is missing is the _wake_: Flow assumes the collector drives rendering (`Dispatchers.Main` + Compose recomposition), so a frame-rebuilding app must add a collector whose only job is to call the host's `wakeIn`/request-redraw. Debounce timers live in the dispatcher, not the frame clock, so a debounce does not need frames to keep ticking, but nor can it be aligned to them. Writes from widgets (`query.value = text`) are synchronous and thread-safe, which suits "rebuild the tree, diff, write cells".

---

## Strengths

- **One concurrency model.** Streams reuse coroutines' scope, cancellation, dispatchers and test scheduler; there is no parallel subscription/scheduler universe to learn.
- **Latest-wins is serialising and leak-free by construction** — `cancel` + `join` inside a `coroutineScope` means no two `transform` bodies overlap and no stale result escapes.
- **`debounce` with a per-value selector** is the cleanest runtime-adjustable debounce in the survey, and its implementation is a ~45-line `select` loop.
- **`StateFlow`** is a small, allocation-free, thread-safe value cell that is also a stream; `stateIn` + `WhileSubscribed` gives demand-driven upstreams with a grace period.
- **Operator fusion** keeps channel-based operators cheap; plain operators are inline calls.
- **Virtual-time testing** is first-class and shared with the rest of the coroutine ecosystem.

## Weaknesses

- **Cancellation is cooperative and the cancel waits**: a non-checking CPU loop blocks the next latest-wins run; `runInterruptible` exists only on the JVM.
- **No glitch-freedom**: `combine` over a diamond produces inconsistent intermediate tuples; there is no transaction or batch API.
- **Errors are exceptions**; cancellation is an exception too, so `catch (e: Exception)` silently breaks cancellation. Hot flows cannot carry failure at all.
- **Cold/hot is invisible in the type** (`Flow` may be either), and `SharedFlow` drops emissions with zero subscribers.
- **Stability**: `debounce`/`sample` remain `@FlowPreview` and the `*Latest` family `@ExperimentalCoroutinesApi`.
- **Virtual time only covers test dispatchers**; hard-coded `Dispatchers.Default` escapes it.

---

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                                  | Trade-off                                                                    |
| ------------------------------------------------ | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `Flow` = one `suspend fun collect`               | Reuse coroutines for scheduling, lifetime, backpressure                    | Every consumer must be a coroutine; no synchronous subscribe                 |
| Cold by default, hot via `shareIn`/`stateIn`     | Local reasoning; nothing runs until collected                              | Hot/cold not visible in the type; hot needs an explicit scope                |
| Context preservation, `flowOn` only upstream     | Collector's context is never hijacked                                      | Context switches insert a channel and may drop in-flight items on cancel     |
| Exception transparency enforced at runtime       | `catch` placement is meaningful; upstream cannot swallow downstream errors | Errors untyped; cancellation shares the exception channel                    |
| `transformLatest` = `cancel` + `join` + `launch` | Never two bodies alive; finally-blocks run before the next starts          | Latency of a switch = cancelled work's cancellation-check interval           |
| `debounce` selector called per value at arrival  | Runtime-adjustable duration without a separate signal                      | An armed timer keeps its old duration; interval change needs `combine`       |
| `StateFlow` conflates by `equals`                | Cheap, allocation-free state; slow collectors see the latest value         | Intermediate states lost; no glitch-free derivation; cannot fail or complete |
| Channel-based operators fuse                     | One channel per chain of buffering operators                               | Fusion rules are subtle (`flowOn` order precedence, `StateFlow` no-ops)      |
| Virtual time in `TestCoroutineScheduler`         | Deterministic `delay`/`debounce` tests in microseconds                     | Only for code whose dispatcher is injectable                                 |

---

## Sources

- [Kotlin/kotlinx.coroutines repository][repo] · [`CHANGES.md`][changes] · [`gradle.properties`][gradle] · [`LICENSE.txt`][license]
- [`flow/Flow.kt` — interface contract, context preservation, exception transparency][flow-kt]
- [`flow/Builders.kt` — `flow`, `channelFlow`, `callbackFlow`, `awaitClose`][builders-kt]
- [`flow/operators/Delay.kt` — `debounce`, `sample`, `timeout`][delay-kt]
- [`flow/operators/Merge.kt` — `transformLatest`, `flatMapLatest`, `mapLatest`][merge-ops-kt] · [`flow/internal/Merge.kt` — `ChannelFlowTransformLatest`][merge-internal-kt]
- [`flow/terminal/Collect.kt` — `collectLatest`][collect-kt]
- [`flow/operators/Context.kt` — `buffer`, `conflate`, `flowOn`, fusion][context-kt] · [`flow/internal/ChannelFlow.kt` — `FusibleFlow`, `ChannelFlow`][channelflow-kt] · [`flow/internal/FlowCoroutine.kt` — `scopedFlow`][flowcoroutine-kt]
- [`flow/internal/Combine.kt` — `combine` batching][combine-kt]
- [`flow/StateFlow.kt`][stateflow-kt] · [`flow/SharedFlow.kt`][sharedflow-kt] · [`flow/SharingStarted.kt`][sharingstarted-kt] · [`flow/operators/Share.kt`][share-kt] · [`flow/operators/Errors.kt`][errors-kt]
- [`Job.kt` — `join`, `ensureActive`][job-kt] · [`CoroutineScope.kt`][scope-kt] · [`Yield.kt`][yield-kt] · [`Builders.common.kt` — `withContext`][builders-common-kt] · [`Delay.kt`][delay-core-kt] · [`jvm/src/Interruptible.kt` — `runInterruptible`][interruptible-kt]
- [`kotlinx-coroutines-test`: `TestBuilders.kt`][testbuilders-kt] · [`TestCoroutineScheduler.kt`][testscheduler-kt] · [`TestCoroutineDispatchers.kt`][testdispatchers-kt] · [`TestScope.kt`][testscope-kt] · [`DebounceTest.kt`][debounce-test]
- [`docs/topics/coroutines-flow.md`][topic-flow] · [`docs/topics/coroutines-cancellation.md`][topic-cancel]
- [Kotlin docs: Asynchronous Flow][docs-flow] · [Cancellation and timeouts][docs-cancel] · [API reference][api] · [`kotlinx-coroutines-test` API][api-test]
- [Turbine (Cash App) — Flow testing library][turbine]
- Related: [RxJS][rxjs] · [Effect-TS][effect-ts] · [Swift Async Algorithms][swift-aa] · [Jetpack Compose][compose] · [Solid signals][solid] · [TC39 signals][tc39] · [Concepts][concepts] · [Comparison][comparison] · [ZIO][zio] · [Async I/O survey][async-io]

<!-- References -->

[repo]: https://github.com/Kotlin/kotlinx.coroutines/tree/7f4d6cf2414937b50291df6169a69afbaf9c5a20
[changes]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/CHANGES.md
[gradle]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/gradle.properties
[license]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/LICENSE.txt
[flow-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/Flow.kt
[builders-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/Builders.kt
[delay-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/operators/Delay.kt
[merge-ops-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/operators/Merge.kt
[merge-internal-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/internal/Merge.kt
[collect-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/terminal/Collect.kt
[context-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/operators/Context.kt
[channelflow-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/internal/ChannelFlow.kt
[flowcoroutine-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/internal/FlowCoroutine.kt
[combine-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/internal/Combine.kt
[stateflow-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/StateFlow.kt
[sharedflow-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/SharedFlow.kt
[sharingstarted-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/SharingStarted.kt
[share-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/operators/Share.kt
[errors-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/flow/operators/Errors.kt
[job-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/Job.kt
[scope-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/CoroutineScope.kt
[yield-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/Yield.kt
[builders-common-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/Builders.common.kt
[delay-core-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/src/Delay.kt
[interruptible-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/jvm/src/Interruptible.kt
[testbuilders-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-test/common/src/TestBuilders.kt
[testscheduler-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-test/common/src/TestCoroutineScheduler.kt
[testdispatchers-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-test/common/src/TestCoroutineDispatchers.kt
[testscope-kt]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-test/common/src/TestScope.kt
[debounce-test]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/test/flow/operators/DebounceTest.kt
[topic-flow]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/docs/topics/coroutines-flow.md
[topic-cancel]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/docs/topics/coroutines-cancellation.md
[docs-flow]: https://kotlinlang.org/docs/flow.html
[docs-cancel]: https://kotlinlang.org/docs/cancellation-and-timeouts.html
[api]: https://kotlinlang.org/api/kotlinx.coroutines/
[api-test]: https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-test/
[turbine]: https://github.com/cashapp/turbine/blob/4590489b93f29ec7ab9dd70bbbadc3baefd58c32/README.md
[rxjs]: ./rxjs.md
[effect-ts]: ./effect-ts.md
[swift-aa]: ./swift-async-algorithms.md
[compose]: ./jetpack-compose.md
[solid]: ./solid-signals.md
[tc39]: ./tc39-signals.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[zio]: ../algebraic-effects/scala-zio.md
[async-io]: ../async-io/index.md
