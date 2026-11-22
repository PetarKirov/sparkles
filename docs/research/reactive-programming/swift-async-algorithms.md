# Swift Async Algorithms and structured concurrency streams (Swift)

Pull-based asynchronous sequences on top of Swift's structured concurrency: the standard library's `AsyncSequence`/`AsyncStream`, cooperative `Task` cancellation and the `Clock` protocol, plus Apple's `swift-async-algorithms` package of time and combining operators (`debounce`, `combineLatest`, `merge`, `flatMapLatest`, `AsyncChannel`, `AsyncTimerSequence`). SwiftUI's `.task(id:)` and the Observation framework complete the UI side.

| Field             | Value                                                                                                                                                                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Swift 6.x (the package manifest declares `swift-tools-version: 6.2`, [`Package.swift`][pkg])                                                                                                                                                |
| License           | Apache-2.0 with Runtime Library Exception ([`LICENSE.txt`][license])                                                                                                                                                                        |
| Repository        | [apple/swift-async-algorithms][repo]                                                                                                                                                                                                        |
| Documentation     | DocC guides under [`Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/`][g-debounce]; proposals under [`Evolution/`][evo-rate]; standard library at [developer.apple.com/documentation/swift][apple-asyncstream]                          |
| Category          | pull-based asynchronous streams over structured concurrency (async iterators, not observers)                                                                                                                                                |
| Versions surveyed | `main` at commit `088f92a30c10` (2026-11-18). Availability macros run `AsyncAlgorithms 1.0` to `1.3` ([`Package.swift`][pkg]); release tags were not in the shallow clone, so the mapping of operators to tagged releases is _(unverified)_ |
| Core abstraction  | `AsyncSequence`, whose iterator's `async next()` returns the next element or `nil` at the end; the consumer pulls, and the producer suspends until it does                                                                                  |

> [!NOTE]
> This deep-dive spans three layers that ship separately: the **Swift standard library**
> (`AsyncSequence`, `AsyncStream`, `Task`, `Clock`; cited from Apple's documentation),
> the **`swift-async-algorithms` package** (cited from source at the SHA above), and the
> **Apple UI frameworks** (SwiftUI `.task(id:)`, Observation). Claims about the first and
> third rest on Apple's documentation, not on source.

---

## Overview

### What it solves

Swift 5.5 (2021) added `async`/`await`, structured tasks and the `AsyncSequence` protocol, so `for await x in seq` became the language-level way to consume values over time. The standard library ships only the sequential operators (`map`, `filter`, `prefix`, …) and one bridge type, `AsyncStream`. Everything about **time** (debounce, throttle, timers) and about **combining several sources** (merge, combineLatest, zip, switching) lives in `swift-async-algorithms`. The README states that scope ([`README.md`][readme]):

> _"AsyncAlgorithms is a package for algorithms that work with *values over time*. That includes those primarily about *time*, like `debounce` and `throttle`, but also algorithms about *order* like `combineLatest` and `merge`. Operations that work with multiple inputs (like `zip` does on `Sequence`) can be surprisingly complex to implement, with subtle behaviors and many edge cases to consider."_

It is the Swift counterpart of [Kotlin Flow][kotlin-flow]: both are cold, suspension-based streams whose operators are coroutines, and neither has an observer interface like [RxJS][rxjs]'s. Swift has one property Kotlin lacks. An `AsyncSequence` has no "collector scope" of its own, so any operator that must run concurrently with its consumer (debounce, merge, flatMapLatest) has to spawn a `Task` internally.

### Design philosophy

The README frames the package as structured concurrency applied to streams ([`README.md`][readme]):

> _"Structured concurrency allows us to write code where intermediate state is simply a local variable, `try` can be used directly on functions that `throw`, and generally treat the logic for asynchronous code similar to that of synchronous code."_

Three consequences shape the API:

1. **Pull, with demand propagated upstream.** No operator runs ahead of its consumer. Even `debounce`, which needs a concurrent upstream reader, only lets that reader pull again after the downstream has called `next()`. Back-pressure is built into the model, not bolted on.
2. **Time is a generic `Clock` parameter.** Every time-based operator takes `clock: C` where `C: Clock`, so tests substitute a manual clock without a scheduler abstraction. This is the `Clock`/`InstantProtocol`/`DurationProtocol` triple from the standard library.
3. **Sendability is part of the signature.** An operator that spawns tasks requires `Base: Sendable, Element: Sendable`. The effects table ([`Effects.md`][g-effects]) lists `AsyncDebounceSequence` as `Sendable` and its iterator as `Not Sendable`: one consumer per iterator, enforced by the compiler.

## How it works

The protocol pair is minimal. Apple's documentation of `AsyncIteratorProtocol` ([docs][apple-iterator]):

> _"The protocol defines a single asynchronous method, `next()`, which either produces the next element of the sequence, or returns `nil` to signal the end of the sequence. … After returning `nil` (or throwing an error) from `next()`, the iterator enters a terminal state, and all future calls to `next()` must return `nil`."_

The same page says iterators handle cancellation themselves: by checking `Task.isCancelled` and returning `nil`, by calling `checkCancellation()`, or by wrapping `next()` in `withTaskCancellationHandler`. That is the whole cancellation contract. There is no `dispose`; a consumer stops by leaving its `for await` loop, which drops the iterator, or by having its task cancelled.

**Bridging from callbacks: `AsyncStream`.** A stream is built from a closure that receives a `Sendable` `Continuation`; `yield(_:)` pushes, `finish()` ends ([docs][apple-asyncstream]). `AsyncStream.makeStream(of:bufferingPolicy:)` returns the `(stream, continuation)` pair directly ([docs][apple-makestream]). The buffer is the only place where push meets pull, and its policy is chosen up front ([docs][apple-bufpolicy]):

| `AsyncStream.Continuation.BufferingPolicy` | When the buffer is full                                     |
| ------------------------------------------ | ----------------------------------------------------------- |
| `.unbounded` (default)                     | _"Continue to add to the buffer, without imposing a limit"_ |
| `.bufferingOldest(n)`                      | _"discard the newly received element"_                      |
| `.bufferingNewest(n)`                      | _"discard the oldest element in the buffer"_                |

`.bufferingNewest(1)` is a conflating latest-value cell, the natural shape for a text field's change events. `AsyncStream.yield` never suspends, so `AsyncStream` has no back-pressure. `AsyncChannel` ([below](#state-and-sharing)) is the back-pressured alternative.

**Operators that need concurrency spawn tasks.** In the package source, these storage types create unstructured `Task { … }`s: `DebounceStorage`, `FlatMapLatestStorage`, `MergeStorage`, `CombineLatestStorage`, `ZipStorage`, `AsyncShareSequence`, the buffer storages and the multi-producer channel. Each type is a lock-protected state machine (`*StateMachine.swift`) plus a storage class that turns the machine's returned actions into continuation resumes and `task.cancel()` calls. `debounce` is typical ([`DebounceStorage.swift`][debounce-storage-task]):

```swift
let task = Task {
  await withThrowingTaskGroup(of: Void.self) { group in
    // The task that consumes the upstream sequence
    group.addTask { … }
    // This is our clock scheduling loop
    group.addTask { … }
  }
}
```

The outer `Task` is unstructured, so it does not inherit the consumer's cancellation. The storage reaches it by hand: the consumer's `next()` runs inside `withTaskCancellationHandler` and its `onCancel` calls `task.cancel()`, and the iterator's `deinit` (through an `InternalClass` wrapper, "to hook the deinit" per [`AsyncDebounceSequence.swift`][debounce-seq]) does the same.

## Evaluation model

- **Pull.** A value moves only when someone awaits `next()`. Push sources (UI callbacks, notifications) enter through an `AsyncStream` buffer or an `AsyncChannel`.
- **Lazy and cold.** Building `query.debounce(for: .milliseconds(250))` stores the base, interval and clock and starts nothing. `makeAsyncIterator()` creates the `DebounceStorage`, and the first `next()` creates its task (state `.initial` → `.startTask`). Each iterator gets a private copy of the pipeline. Hot behaviour needs `share()` ([below](#state-and-sharing)).
- **Asynchronous propagation; no glitch-freedom guarantee.** Every hop through a multi-input operator is a continuation resume handled by the concurrency runtime. `combineLatest(a, b)` emits a tuple per upstream element, so a "diamond" (`combineLatest(x.map(f), x.map(g))`) yields intermediate mixed tuples. Nothing provides a transactional snapshot. That is the job of [signals][solid-signals] and of Observation's transactions ([State and sharing](#state-and-sharing)).
- **Single consumer per iterator.** Iterators of the time and combining operators are `@available(*, unavailable) … Sendable` ([`AsyncDebounceSequence.swift`][debounce-seq]), so an iterator cannot leave its task.

## Composition

- **Standard library:** the `Sequence`-shaped operators on `AsyncSequence` (`map`, `compactMap`, `flatMap` (concatenating), `filter`, `prefix`, `drop(while:)`, `reduce`, `contains`, …) _(names per Apple docs; not re-verified here)_.
- **Package, combining:** `chain`, `combineLatest` (2 and 3 inputs), `merge` (2 and 3), `zip` (2 and 3), `joined(separator:)`, and `flatMapLatest` ([`README.md`][readme], [`FlatMapLatest.md`][g-fml]). The guides give the fixed-arity reason: _"This function family and the associated family of return types are prime candidates for variadic generics. Until that proposal is accepted, these will be implemented in terms of two- and three-base sequence cases"_ ([`Merge.md`][g-merge], [`CombineLatest.md`][g-cl]).
- **Package, time:** `debounce`, `_throttle`, `AsyncTimerSequence`, plus `chunks(ofCount:or:)` with a timer signal.
- **Package, others:** `adjacentPairs`, `chunked`, `compacted`, `removeDuplicates`, `interspersed`, `buffer(policy:)`, `share(bufferingPolicy:)`, `mapError`, and collection initialisers (`Array(seq)`, `Dictionary(…)`, `Set(…)`).

That makes about 25 operators, against roughly 115 in [RxJS][rxjs]. Anything missing is written as an `async` function or a hand-rolled iterator. That is idiomatic in Swift and needs no escape hatch.

> [!IMPORTANT]
> **A `flatMapLatest` exists at this SHA**, as `Evolution/0018-flatMapLatest.md` (status **"Proposed"**)
> with source and tests, gated `@available(AsyncAlgorithms 1.3, *)`
> ([`AsyncFlatMapLatestSequence.swift`][fml-seq], [proposal][evo-fml]). It is not yet listed
> in the README, and its concrete type is internal: the public API returns
> `some AsyncSequence<T.Element, T.Failure> & Sendable`. The proposal rejects RxJS's name:
> _"**`switchMap`**: Used in ReactiveX, but "switch" in Swift has strong association with
> control flow statements"_, and takes RxSwift's `flatMapLatest` instead. The idiomatic
> alternative, which predates the operator, is the hand-rolled cancel-and-replace `Task`
> shown in [Concurrency and cancellation](#concurrency-and-cancellation).

Derived values are ordinary code: `seq.map { … }` or a computed property on an `@Observable` model. There is no memoised derived-value node.

## Time and scheduling

**`Clock`.** The standard library protocol is _"a mechanism in which to measure time, and delay work until a given point in time"_ ([docs][apple-clock]). It has `now: Instant`, `minimumResolution: Duration` and `sleep(until:tolerance:)`. On tolerance, the docs say: _"The clock may reschedule tasks within the tolerance to ensure efficient execution of resumptions by reducing potential operating system wake-ups."_ `Instant: InstantProtocol` supplies `advanced(by:)` and `duration(to:)` ([docs][apple-instant]). The concrete clocks are `ContinuousClock` (keeps counting while the system sleeps), `SuspendingClock` (stops while it sleeps) and user types. A clock is not a scheduler: it does not pick the thread or executor where the woken task resumes. That is the task's actor isolation or executor.

**Executors, not schedulers.** Where code runs is decided by isolation: `@MainActor`, a custom actor, or the global concurrent pool. Swift 6.2's `@concurrent` and default `nonisolated(nonsending)` semantics move a function off the caller's actor _(language feature; cited from memory of SE-0461, not verified here)_. No operator in the package takes a scheduler argument. Operators that spawn `Task`s run on the global executor.

**How `debounce` is implemented.** `debounce(for:tolerance:clock:)` stores the interval as `private let interval: C.Instant.Duration` ([`AsyncDebounceSequence.swift#L42`][debounce-interval]). The storage task runs two children in a task group:

1. The **upstream loop** waits on a continuation until the downstream signals demand, pulls `iterator.next()`, and records each element with `deadline = self.clock.now.advanced(by: self.interval)` ([`DebounceStorage.swift#L175`][debounce-deadline]).
2. The **clock loop** waits for a deadline and calls `try await self.clock.sleep(until: deadline, tolerance: self.tolerance)` ([`DebounceStorage.swift#L261`][debounce-sleep]). On waking it asks the state machine whether the _current_ element's deadline has passed ([`DebounceStateMachine.swift#L546`][debounce-sm]):

```swift
case .debouncing(let task, let upstreamContinuation, let downstreamContinuation, let currentElement):
  guard currentElement.deadline <= self.clock.now else {
    // The deadline is still in the future so we need to sleep again
    return .none
  }
```

A newer element does not cancel the sleeping timer. It only moves the deadline, and the clock loop goes back to sleep until the new one. This is the "lazy re-arm" debounce (one sleeper, re-check on wake), not RxJS-style cancel-and-reschedule. A finish or a thrown error is forwarded at once, with the pending element flushed first (`test_finishDoesntDebounce`, `test_throwDoesntDebounce` in [`TestDebounce.swift`][test-debounce]).

> [!WARNING]
> **The debounce duration cannot change at runtime.** It is a `let` captured at
> construction and copied into the storage (`DebounceStorage.init(base:interval:tolerance:clock:)`).
> There is no overload that takes a duration-producing closure or a sequence of durations,
> and the guide's only alternative is a _reducing_ debounce
> ([`Debounce.md`][g-debounce]). To change N you rebuild the pipeline: cancel the consuming
> task and start a new iterator. Any element pending in the old debounce is lost.

**`throttle` is underscored.** The public entry points are `_throttle(for:clock:reducing:)` and `_throttle(for:clock:latest:)` ([`AsyncThrottleSequence.swift`][throttle]), although proposal SAA-0014 is **"Accepted"** ([`0014-rate-limits.md`][evo-rate]) and the README lists `throttle(for:clock:reducing:)`. The README's stability rule puts it outside the API contract: _"The public API of version 1.0 … will consist of non-underscored declarations"_ ([`README.md`][readme]). The implementation spawns no task and measures elapsed time inside `next()` ([`#L103`][throttle-next]). Its interval is a `let` too.

**`AsyncTimerSequence`** computes `next = (last ?? clock.now).advanced(by: interval)` and sleeps until then, so it does not drift. On cancellation it returns `nil` rather than throwing ([`AsyncTimerSequence.swift`][timer]; guide: _"If at any point in time the task executing that iteration is cancelled the iteration will return `nil`"_, [`Timer.md`][g-timer]). `.repeating(every:)` defaults to `SuspendingClock`.

## Concurrency and cancellation

**Cooperative, flag-based cancellation.** `task.cancel()` sets a flag and runs any registered handlers. Apple's docs on `Task.isCancelled` ([docs][apple-iscancelled]): _"After the value of this property becomes `true`, it remains `true` indefinitely. There is no way to uncancel a task."_ The same page notes that a newer `withTaskCancellationShield(operation:)` can hide the flag inside a region. `Task.checkCancellation()` throws `CancellationError` ([docs][apple-checkcancel]). `withTaskCancellationHandler(operation:onCancel:isolation:)` is the hook that wakes suspended work ([docs][apple-wtch]):

> _"the cancellation handler is **always** and **immediately** invoked when the task is canceled. … If cancellation occurs while the operation is running, the cancellation handler executes **concurrently** with the operation. Cancellation handlers which acquire locks must take care to avoid deadlock."_

Cancellation flows down the structured tree (child tasks, `async let`, task groups), not into unstructured `Task { }`. It never preempts: a CPU-bound loop that does not check stays uncancelled until it returns. The standard library's `Task.sleep` and `clock.sleep` are cancellation points that throw `CancellationError` at once.

**Does a cancel wait for the cancelled work?** `cancel()` does not. Only structure waits: a task group or `async let` scope cannot exit before its children finish, so cancelling a group and then leaving it is a cancel-and-join. In `flatMapLatest`, switching is cancel-and-forget ([`FlatMapLatestStorage.swift#L172`][fml-storage]):

```swift
case .startInnerTask(let inner, let generation, let previousTask, let previousCont):
  if let previousTask = previousTask {
    previousTask.cancel()
    previousCont?.resume(throwing: CancellationError())
  }
  startInnerTask(inner, generation: generation)
```

The old inner `Task` may still be running a CPU-bound step while the new one starts. Stale output is filtered by a **generation counter**, not by joining: the proposal says _"Each new inner sequence is assigned a generation number. Elements from stale generations are discarded"_ ([proposal][evo-fml]). The outer reader pulls the base only while the downstream has demand pending (`outerTaskSuspended`: _"If we have downstream demand, resume immediately"_). A consumer suspended in `next()`, waiting for a hash, therefore still sees a newer query.

**The hand-rolled latest-wins**, idiomatic before `flatMapLatest` and still common, is a stored `Task` handle:

```swift
@MainActor final class Searcher {
  private var current: Task<Void, Never>?
  func submit(_ query: String) {
    current?.cancel()                       // cancel, do not wait
    current = Task { [weak self] in
      guard let digest = try? await hashFileSet(matching: query),
            !Task.isCancelled else { return } // drop a result that lost the race
      self?.show(digest)
    }
  }
}
```

The `!Task.isCancelled` check after the `await` is required. Cancellation does not stop a computation that has already returned, so without it a stale result can still be written.

**CPU-bound work.** `Task.detached` or a `@concurrent` function (Swift 6.2) puts work on the global cooperative pool, which has about one thread per core. A long hash blocks one of those threads, and other tasks are not preempted off it. The hash must check `Task.isCancelled` or call `try Task.checkCancellation()` between files and call `await Task.yield()` to share the pool. A dedicated thread or `DispatchQueue` needs a hand-written bridge through `withCheckedThrowingContinuation` plus `withTaskCancellationHandler`.

## Errors and completion

- **Typed failure.** Since Swift 6.0 (SE-0421, cited from memory), `AsyncSequence` has a `Failure` associated type (`AsyncSequence<Element, Failure>`) and `next(isolation:) async throws(Failure)`. `flatMapLatest` is overloaded three ways to unify `Never` with a real failure, using `mapError { _ in fatalError() }` as a type-level cast ([`AsyncFlatMapLatestSequence.swift`][fml-seq]). `mapError` is a package operator (SAA-0017).
- **`rethrows` propagation.** Most operators are `rethrows`: they throw only if the base throws ([`Effects.md`][g-effects]). An error ends the sequence; there is no `catch`/`retry` operator. Recovery means a `do`/`catch` around the `for try await` loop and a new iterator.
- **Completion is `nil`.** For `flatMapLatest`, the proposal says _"The sequence completes when: 1. The base sequence finishes producing elements, AND 2. The final inner sequence finishes producing elements"_. An error from the base or from any inner sequence _"is immediately propagated and all tasks are cancelled"_ ([proposal][evo-fml]).
- **Cancellation is not an error at the sequence level** for non-throwing sequences. `AsyncTimerSequence` and `AsyncChannel` return `nil` when cancelled. Throwing sequences may surface a `CancellationError`, which the consumer must tell apart from real failures.
- Errors-as-values are a user choice (`Result<T, E>` elements), not a library convention.

## State and sharing

- **No value cell in the stream library.** Neither the standard library nor the package has a `BehaviorSubject`/`StateFlow` equivalent. Current state lives in an `@Observable` class or an actor, and streams carry changes.
- **Observation (SE-0395, Swift 5.9).** `@Observable` macro-expands stored properties into `ObservationRegistrar` accesses. `withObservationTracking(_:onChange:)` _"tracks access to any property within the `apply` closure, and informs the caller of value changes made to participating properties by way of the `onChange` closure"_ ([docs][apple-wot]). SE-0395 says the `onChange` closure _"is then called on the first change"_, so it is one-shot. The proposal's example re-arms it by calling `withObservationTracking` again from inside `onChange` ([SE-0395][se-0395]). This is the dependency-tracking primitive SwiftUI uses to invalidate a view body. It is push-on-invalidate, pull-on-read: closer to [signals][tc39-signals] than to streams.
- **`Observations` (iOS/macOS 26).** An `AsyncSequence` over an `@Observable` expression: _"track changes to types that are marked as `@Observable` by using Swift Concurrency to indicate transactional boundaries starting from the willSet of the first mutation to the next suspension point of the safe access"_ ([docs][apple-observations]). Mutations made within one synchronous stretch coalesce into one element. This is a glitch-free, conflating bridge from state cells into streams.
- **Multicast: `share(bufferingPolicy:)`** (SAA-0015, accepted). Each consumer _"independently can make forward progress and get the same values but do not replay from the beginning of time"_ ([`Share.md`][g-share]). The default policy is `.bounded(1)` ([`AsyncShareSequence.swift`][share]). There is no replay or `shareReplay`.
- **Back-pressured hand-off: `AsyncChannel`.** _"Each value sent by the channel will await the consumption of that value by iteration. … the rate of production cannot exceed the rate of consumption"_ ([`Channel.md`][g-channel]). `send` suspends until a `next()` takes the value, `finish()` resumes every pending sender and receiver, and _"The calls to `send(:)` and `next()` will immediately resume when their supporting task is cancelled"_. `MultiProducerSingleConsumerAsyncChannel` (SAA-0016, "Implemented") adds a buffered, watermark-based strategy (`.watermark(low:high:)`) ([source][mpsc]).
- **Conflation** comes from `AsyncStream`'s `.bufferingNewest(1)`, `buffer(policy:)`, or `removeDuplicates()`.

## Lifetime and ownership

- **The consuming task is the owner.** A pipeline lives exactly as long as the task iterating it. Cancelling that task cancels `next()`, whose `withTaskCancellationHandler` cancels each operator's internal `Task` (debounce: `.resumeDownstreamContinuationWithNilAndCancelTaskAndUpstreamAndClockContinuation`).
- **Dropping the iterator also tears down**, through the `InternalClass.deinit` hook in `AsyncDebounceSequence.Iterator`. The package comments: _"If we get move-only types we should be able to drop this class and use the `deinit` of the `AsyncIterator` struct itself"_ ([`AsyncDebounceSequence.swift`][debounce-seq]).
- **Unstructured tasks leak by default.** A `Task { }` stored nowhere runs to completion. One that captures `self` strongly keeps its object alive while it loops on an infinite `AsyncStream`. Teardown is manual (`task.cancel()` in `deinit` or `onDisappear`) unless SwiftUI owns the task.
- **SwiftUI `.task(id:)`** binds a task to a view's lifetime ([docs][apple-task-id]): _"SwiftUI can automatically cancel the task after the view disappears before the action completes. If the `id` value changes, SwiftUI cancels and restarts the task."_ It compares `id` with `Equatable`, so it is latest-wins built into the view tree. The current signature is `task(id:name:priority:file:line:_:)`. `name`, `file` and `line` _"[are] a no-op prior to iOS 26.4"_; earlier SDKs have `task(id:priority:_:)`. Whether SwiftUI waits for the cancelled task before starting the new one is undocumented _(unverified; assume it does not)_.
- **`AsyncStream.Continuation.onTermination`** runs when the consumer cancels or finishes, and is the place to unregister a callback source.

## Testing

- **No virtual clock ships in the standard library or in the `AsyncAlgorithms` product.** The package's own tests use two test-only clocks. Neither is a product (`Package.swift` exports only `AsyncAlgorithms` and `AsyncStreaming`).
  - `ManualClock` ([`Tests/…/Support/ManualClock.swift`][manual-clock]): `Instant` and `Step` are integer ticks, with `advance()`/`advance(by:)` and a `sleep(until:)` that suspends until the clock passes the deadline.
  - **`AsyncSequenceValidation`**, a marble-diagram DSL with its own `Clock` ([`Validation.md`][g-validation]). It makes scheduling deterministic by installing `swift_task_enqueueGlobal_hook` so every global job runs on its own driver thread ([`Test.swift#L383`][validation-hook]). The guide argues that _"Taking the approach of having explicit ordering of time defined by the diagram allows for the test to be predictable."_ A debounce test ([`TestDebounce.swift`][test-debounce]):

```swift
validate {
  "abcd----e---f-g----|"
  $0.inputs[0].debounce(for: .steps(3), clock: $0.clock)
  "------d----e-----g-|"
}
```

- **Community: `pointfreeco/swift-clocks`** (MIT, 1.1.1) provides `TestClock`, _"a clock whose time can be controlled in a deterministic manner … useful for testing … timers, `debounce`, `throttle`, `timeout`, and more"_, with `advance(by:)` and `run()`, and also `ImmediateClock` and `UnimplementedClock` ([docs][swift-clocks-testclock], [package][swift-clocks]). The pattern is to inject `any Clock<Duration>` into the model.
- **The gap:** `Task.sleep(for:)` without a clock argument, and SwiftUI's `.task(id:)` scheduling, cannot be virtualised. Code that should be testable must take a `Clock` parameter. Driving real tasks under a `TestClock` also needs the consumer to reach its suspension point before `advance` is called, a known source of flaky tests that `AsyncSequenceValidation` solves only by hooking the global executor.

## The worked pipeline

Query field → debounce N ms (N adjustable at runtime) → hash a file set on a worker with latest-wins cancellation → show the result. A toggle enables or disables the whole pipeline.

**Variant A: SwiftUI `.task(id:)` (idiomatic).** The `id` is the whole configuration. Debounce becomes a cancellable `sleep` at the start of a restartable task, and latest-wins comes free:

```swift
struct PipelineKey: Equatable { var query: String; var delay: Duration; var enabled: Bool }

@MainActor @Observable final class Model {
  var query = ""
  var delayMs = 250
  var enabled = true
  var result: Result<String, Error>?
  var key: PipelineKey { .init(query: query, delay: .milliseconds(delayMs), enabled: enabled) }
}

@concurrent
func hashFileSet(matching query: String) async throws -> String {   // off the main actor
  var hasher = Hasher()                                            // stand-in: per-process seeded, not a stable digest
  for file in try listFiles(matching: query) {
    try Task.checkCancellation()                                   // cooperative cancel point
    hasher.combine(try Data(contentsOf: file))
  }
  return String(hasher.finalize(), radix: 16)
}

struct SearchView: View {
  @State private var model = Model()
  var body: some View {
    Form { /* TextField, Stepper, Toggle, result */ }
      .task(id: model.key) {
        let key = model.key
        guard key.enabled else { model.result = nil; return }
        do {
          try await Task.sleep(for: key.delay)                              // the debounce
          let digest = try await hashFileSet(matching: key.query)
          guard !Task.isCancelled else { return }                           // lost the race
          model.result = .success(digest)
        } catch is CancellationError {
        } catch { model.result = .failure(error) }
      }
  }
}
```

**Variant B: `swift-async-algorithms` operators.** The debounce interval is a `let`, so changing N or the toggle restarts the consuming task:

```swift
@MainActor @Observable final class Pipeline {
  @ObservationIgnored private let input = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
  @ObservationIgnored private var runner: Task<Void, Never>?
  var result: String?

  func queryChanged(_ q: String) { input.continuation.yield(q) }
  func configure(enabled: Bool, delay: Duration) {
    runner?.cancel()                       // cancels pending debounce + in-flight hash
    runner = nil
    guard enabled else { return }
    let queries = input.stream
    runner = Task { [weak self] in
      let digests = queries
        .debounce(for: delay)                                    // interval fixed per run
        .flatMapLatest { q in                                    // AsyncAlgorithms 1.3
          AsyncThrowingStream<String, Error> { c in              // one-element inner sequence
            let job = Task {
              do { c.yield(try await hashFileSet(matching: q)); c.finish() }
              catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in job.cancel() }              // switch -> cancel the hash
          }
        }
      do { for try await d in digests { self?.result = d } } catch {}
    }
  }
}
```

> [!WARNING]
> Variant B shares one `AsyncStream` across restarts. That is safe only because a
> restart cancels the old iterator before the next one is created. `AsyncStream` is
> designed for a single consumer, and the behaviour of two concurrent iterators is
> _(unverified)_. The one-element inner sequence needs its own unstructured `Task`
> plus `onTermination` to forward cancellation into the hash: an async function
> cannot be the inner of `flatMapLatest` directly, because no `mapLatest` exists.
> Neither sketch here is compiled.

**Per-event trace (Variant A).**

| Event                     | What happens                                                                                                                                                                                                                                                                                                              |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keystroke during debounce | `model.query` mutates, so Observation invalidates the body and `model.key` differs. SwiftUI cancels the task, and `Task.sleep` throws `CancellationError` at once (handler-driven, no polling). A new task starts a fresh full-N sleep.                                                                                   |
| Keystroke during hash     | The same restart. The old task's flag is set, and its hash stops at the next `checkCancellation()` between files: at most one file's work is wasted. Cancel does not wait, so for that stretch old and new tasks run concurrently. A hash that finished just before the cancel is discarded by `guard !Task.isCancelled`. |
| Interval change           | `key.delay` differs, so the task restarts: the current query is re-debounced with the new N and rehashed, even if its result is already shown. Avoiding the rehash means taking `delay` out of `id` and reading it at sleep time, after which a change no longer affects a sleep already running.                         |
| Toggle off                | `key.enabled` flips, so SwiftUI cancels the running task (pending sleep or in-flight hash). The new task sees `enabled == false`, clears the result and returns.                                                                                                                                                          |

In Variant B, a keystroke during the debounce moves the element deadline, and the clock loop re-checks it on wake ([Time and scheduling](#time-and-scheduling)). A keystroke during a hash lets `flatMapLatest` cancel the inner task, bump the generation and drop the stale result. An interval change or toggle-off cancels `runner`, which tears down debounce and `flatMapLatest` through their cancellation handlers. A query buffered in the old debounce is lost.

**Fit with a per-frame UI.** `.task(id:)` is what sparkles needs: a restartable effect keyed on a value compared each "frame", which here means each body evaluation. An immediate-mode host can reproduce it exactly. Each frame, compute the key and compare it with the last one; if it differs, cancel the scoped fiber and spawn a new one. Neither `debounce` nor `flatMapLatest` is required. The operator form (Variant B) suits a widget tree rebuilt every frame less well: it needs a long-lived push channel into the pipeline and a full rebuild whenever a parameter changes.

## Strengths

- **Cancellation is part of the runtime**: structured propagation, `withTaskCancellationHandler` for wake-ups, and cancellation-aware `sleep`. Operators inherit it.
- **Back-pressure by construction.** Pull plus demand-gated internal readers means no unbounded queue unless you choose `AsyncStream`'s `.unbounded`.
- **`Clock` as a generic parameter**, which gives virtual time with no scheduler hierarchy and a tolerance hint for coalescing wake-ups.
- **Latest-wins at the UI level for free** through `.task(id:)`, which covers most search-as-you-type cases without any stream operator.
- **Carefully specified operators.** Each has a proposal, a guide, a lock-protected state machine and marble-diagram tests.
- **Observation's transactional `Observations`** gives a glitch-free bridge from state into streams.

## Weaknesses

- **Fixed time parameters.** The `debounce` and `_throttle` intervals are `let`; a runtime change means a pipeline restart that loses pending elements.
- **Operators spawn unstructured `Task`s** and rebuild structure by hand through cancellation handlers and `deinit` hooks. The structure of an `AsyncSequence` chain is invisible to the task tree.
- **Cancel does not join.** `flatMapLatest` and `Task.cancel()` let cancelled CPU work overlap its replacement, and correctness depends on generation counters or `isCancelled` re-checks.
- **Small, slow-moving surface.** `throttle` is still underscored, `flatMapLatest` is "Proposed", and arities stop at 3. There is no `retry`, `timeout`, `catch`, or replaying share (`reductions` covers `scan`).
- **No shipped test clock.** `ManualClock` and `AsyncSequenceValidation` are internal to the package's tests; users rely on `swift-clocks`.
- **No glitch-freedom across `combineLatest`**, and no value cell in the stream layer.

## Key design decisions and trade-offs

| Decision                                                                  | Rationale                                                                      | Trade-off                                                                                               |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| Pull (`async next()`) as the only stream protocol                         | Back-pressure and `for await` ergonomics; streams look like loops              | Every push source needs a buffer (`AsyncStream`) or a rendezvous (`AsyncChannel`)                       |
| Time-based operators generic over `Clock`                                 | Testable time without a scheduler abstraction; tolerance for power efficiency  | Durations fixed at construction; no "duration as a stream"                                              |
| Debounce re-checks the deadline on wake instead of cancelling the sleep   | One long-lived clock loop; no task churn per element                           | A wake-up per superseded deadline; latency bounded by the interval plus tolerance                       |
| Concurrency inside operators via unstructured `Task` + locks              | `AsyncSequence` gives an operator no scope of its own                          | Lifetime reconstructed manually (`withTaskCancellationHandler`, `deinit` hooks); harder to reason about |
| `flatMapLatest` cancels without awaiting; generations filter stale output | Switching is immediate; no head-of-line blocking on slow cancellation          | Cancelled CPU work overlaps its successor; resources freed late                                         |
| Cooperative, sticky, non-preemptive cancellation                          | Cheap, predictable, safe for invariants                                        | CPU-bound code must poll `isCancelled`; a non-polling loop is uncancellable                             |
| SwiftUI `.task(id:)` restarts on `Equatable` change                       | Latest-wins tied to view identity and lifetime with no operators               | Restart granularity is the whole task; unrelated key changes (interval) restart work                    |
| Observation's one-shot `onChange` and transactional `Observations`        | Fine-grained invalidation for view bodies; coalesced, glitch-free async bridge | Re-arming is the caller's job; the sequence form needs the iOS 26-era SDK                               |

## Sources

- [apple/swift-async-algorithms][repo] at `088f92a30c103ddc470d771f770249271066a123`: [`README.md`][readme], [`Package.swift`][pkg], [`LICENSE.txt`][license]
- Debounce: [`AsyncDebounceSequence.swift`][debounce-seq], [`DebounceStorage.swift`][debounce-storage-task], [`DebounceStateMachine.swift`][debounce-sm], [`Debounce.md`][g-debounce], [`TestDebounce.swift`][test-debounce]
- Throttle: [`AsyncThrottleSequence.swift`][throttle], [`Throttle.md`][g-throttle], [SAA-0014][evo-rate]
- FlatMapLatest: [SAA-0018][evo-fml], [`FlatMapLatest.md`][g-fml], [`AsyncFlatMapLatestSequence.swift`][fml-seq], [`FlatMapLatestStorage.swift`][fml-storage], [`TestFlatMapLatest.swift`][test-fml]
- Others: [`Merge.md`][g-merge], [`CombineLatest.md`][g-cl], [`Channel.md`][g-channel], [`Share.md`][g-share], [`AsyncShareSequence.swift`][share], [`Timer.md`][g-timer], [`AsyncTimerSequence.swift`][timer], [`Effects.md`][g-effects], [MPSC channel][mpsc]
- Testing: [`ManualClock.swift`][manual-clock], [`Validation.md`][g-validation], [`AsyncSequenceValidation/Test.swift`][validation-hook]; [pointfreeco/swift-clocks on Swift Package Index][swift-clocks], [`TestClock` docs][swift-clocks-testclock]
- Apple documentation: [`AsyncIteratorProtocol`][apple-iterator], [`AsyncStream`][apple-asyncstream], [`makeStream(of:bufferingPolicy:)`][apple-makestream], [`BufferingPolicy`][apple-bufpolicy], [`Task.isCancelled`][apple-iscancelled], [`Task.checkCancellation()`][apple-checkcancel], [`withTaskCancellationHandler`][apple-wtch], [`Clock`][apple-clock], [`InstantProtocol`][apple-instant], [SwiftUI `task(id:…)`][apple-task-id], [`withObservationTracking`][apple-wot], [`Observations`][apple-observations]
- Swift Evolution: [SE-0395 Observation][se-0395]
- Related: [RxJS][rxjs] · [Kotlin Flow][kotlin-flow] · [Rust streams][rust-streams] · [Effect-TS][effect-ts] · [Solid signals][solid-signals] · [TC39 Signals][tc39-signals] · [Jetpack Compose][jetpack-compose] · [Concepts][concepts] · [Comparison][comparison] · [Umbrella][index] · [ZIO][zio] · [Async I/O survey][async-io]

<!-- References -->

[repo]: https://github.com/apple/swift-async-algorithms/tree/088f92a30c103ddc470d771f770249271066a123
[readme]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/README.md
[pkg]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Package.swift
[license]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/LICENSE.txt
[debounce-seq]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/Debounce/AsyncDebounceSequence.swift
[debounce-interval]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/Debounce/AsyncDebounceSequence.swift#L42
[debounce-storage-task]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/Debounce/DebounceStorage.swift#L141
[debounce-deadline]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/Debounce/DebounceStorage.swift#L175
[debounce-sleep]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/Debounce/DebounceStorage.swift#L261
[debounce-sm]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/Debounce/DebounceStateMachine.swift#L546
[test-debounce]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Tests/AsyncAlgorithmsTests/TestDebounce.swift
[throttle]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncThrottleSequence.swift
[throttle-next]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncThrottleSequence.swift#L103
[timer]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncTimerSequence.swift
[fml-seq]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/FlatMapLatest/AsyncFlatMapLatestSequence.swift
[fml-storage]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/FlatMapLatest/FlatMapLatestStorage.swift#L172
[test-fml]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Tests/AsyncAlgorithmsTests/TestFlatMapLatest.swift
[share]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncShareSequence.swift
[mpsc]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/MultiProducerSingleConsumerChannel/MultiProducerSingleConsumerAsyncChannel.swift
[manual-clock]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Tests/AsyncAlgorithmsTests/Support/ManualClock.swift
[validation-hook]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncSequenceValidation/Test.swift#L383
[g-validation]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncSequenceValidation/AsyncSequenceValidation.docc/Validation.md
[g-debounce]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Debounce.md
[g-throttle]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Throttle.md
[g-fml]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/FlatMapLatest.md
[g-merge]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Merge.md
[g-cl]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/CombineLatest.md
[g-channel]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Channel.md
[g-share]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Share.md
[g-timer]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Timer.md
[g-effects]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Effects.md
[evo-rate]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Evolution/0014-rate-limits.md
[evo-fml]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Evolution/0018-flatMapLatest.md
[swift-clocks]: https://swiftpackageindex.com/pointfreeco/swift-clocks
[swift-clocks-testclock]: https://swiftpackageindex.com/pointfreeco/swift-clocks/1.1.1/documentation/clocks/testclock
[apple-iterator]: https://developer.apple.com/documentation/swift/asynciteratorprotocol
[apple-asyncstream]: https://developer.apple.com/documentation/swift/asyncstream
[apple-makestream]: https://developer.apple.com/documentation/swift/asyncstream/makestream(of:bufferingpolicy:)
[apple-bufpolicy]: https://developer.apple.com/documentation/swift/asyncstream/continuation/bufferingpolicy
[apple-iscancelled]: https://developer.apple.com/documentation/swift/task/iscancelled-swift.type.property
[apple-checkcancel]: https://developer.apple.com/documentation/swift/task/checkcancellation()
[apple-wtch]: https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:isolation:)
[apple-clock]: https://developer.apple.com/documentation/swift/clock
[apple-instant]: https://developer.apple.com/documentation/swift/instantprotocol
[apple-task-id]: https://developer.apple.com/documentation/swiftui/view/task(id:name:priority:file:line:_:)
[apple-wot]: https://developer.apple.com/documentation/observation/withobservationtracking(_:onchange:)
[apple-observations]: https://developer.apple.com/documentation/observation/observations
[se-0395]: https://www.swift.org/swift-evolution/#?id=SE-0395
[rxjs]: ./rxjs.md
[kotlin-flow]: ./kotlin-flow.md
[rust-streams]: ./rust-streams.md
[effect-ts]: ./effect-ts.md
[solid-signals]: ./solid-signals.md
[tc39-signals]: ./tc39-signals.md
[jetpack-compose]: ./jetpack-compose.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[zio]: ../algebraic-effects/scala-zio.md
[async-io]: ../async-io/index.md
