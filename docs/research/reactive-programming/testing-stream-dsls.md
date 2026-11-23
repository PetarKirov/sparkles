# Testing Stream Libraries: Marble Strings, Recorded Ticks, Probes and Virtual Runtimes

How six stream ecosystems let a test script inputs over virtual time and assert outputs, and, the hard part, what each can say about cancelled and joined work.

This page is a theme survey, not a single-library deep-dive. It covers the test tooling of [RxJS](#rxjs-marble-testing) (`TestScheduler.run` marble diagrams, and the `@rxjs/test` package that RxJS 9 replaced it with), [Rx.NET](#rx-net-testscheduler-and-recorded-notifications) (`TestScheduler` with tick-stamped `Recorded<Notification<T>>`), [Swift Async Algorithms](#swift-async-algorithms-asyncsequencevalidation) (the `validate { … }` diagram DSL), [Kotlin](#kotlin-kotlinx-coroutines-test-and-turbine) (`kotlinx-coroutines-test` plus Cash App's Turbine), [Pekko Streams](#pekko-streams-testkit-probes) (`TestSource`/`TestSink` probes) and [Effect TS and cats-effect/fs2](#effect-ts-testclock-and-cats-effect-testcontrol) (virtual clocks and mock runtimes with outcome assertions and no notation). The question is the one open as Q12.3 for the D library: how should a test **script** inputs (cell writes, `TestClock` advances, `TestCpuPool` job completions, clicks) and **assert** outputs (values, cancellations, joins, timings)? Each section works the same scenario. A query `"ab"` is debounced 500 ms and a hash starts. A keystroke `"abc"` arrives while the hash is running. The old hash is cancelled, a new debounce runs, a new hash runs, and its result is shown.

**Last reviewed:** November 24, 2026

> [!NOTE]
> The worked tests are written by this survey in each system's idiom. **None has been compiled or run.** Each is marked
> _untested_. Where an identifier's existence was checked against the pinned source, the text says so. Where it was not,
> the identifier is marked _(unverified)_. Throughout, the pipeline under test is "switch per keystroke, then debounce,
> then hash" (`switchMap(q => timer(500) → hash(q))`), so a keystroke cancels both a pending debounce and an in-flight hash
> at the moment it arrives. Hashes take 1 s of virtual time.

---

## RxJS: marble testing

The [RxJS deep-dive][rxjs] covers the library. RxJS 7's `TestScheduler.run(callback)` is the reference marble DSL, and every later diagram notation cites it. At the surveyed revision (`master`, `9.0.0-beta.0`, 2026-11-18) RxJS 9 has removed it from the public API. The replacement is a separate package, `@rxjs/test`, with a function-first `rxTest`.

### Scripting inputs

Inputs are marble strings turned into test sources. `cold(marbles, values?, error?)` starts its timeline at each subscription; `hot(...)` runs on absolute time, with `^` marking frame zero. The RxJS 7 guide lists the grammar: `-` is one frame, `[a-z0-9]` emits a value looked up in `values`, `|` completes, `#` errors, `(abc)` groups synchronous events, and `^` is the subscription point ([`marble-testing.md`][rx-guide]). Side inputs that are not observables are scripted as ordinary code between `flush()` calls. `animate('---x---x')` scripts `requestAnimationFrame` paints.

### Representing time

Time is position in the string. Inside `run`, one frame is one virtual millisecond. Outside `run`, a frame is 10 ms, `maxFrames = 750`, and the guide notes _"After 750 they are silently ignored"_ ([`marble-testing.md`][rx-guide]). The time-progression syntax (`a 500ms b`, `1.5m`) was added so that long delays need no dashes. It comes with a known off-by-one: _"You may have to subtract 1 millisecond from the time you want to progress because the alphanumeric marbles … advance time 1 virtual frame themselves already"_. A `( … )` group advances time by its character width, `(abc)` by 5 frames, and the guide calls this _"a known pain point in real-world testing"_. `run` virtualises time by swapping delegates on RxJS's own providers (`timeoutProvider.delegate`, `intervalProvider.delegate`, `animationFrameProvider.delegate`, `dateTimestampProvider.delegate`) for the duration of the callback ([`TestScheduler.ts` (7.x)][rx7-ts]). Promises and anything else outside those providers stay real, and the guide's "Known issues" section says so.

### Asserting outputs

`expectObservable(actual, subscriptionMarbles?).toBe(marbles, values?, error?)` schedules a comparison that runs when the scheduler flushes. Both sides become arrays of `{ frame, notification: { kind: 'N' | 'E' | 'C', value?, error? } }` and are compared by a user-supplied `assertDeepEqual`. `expectSubscriptions(source.subscriptions).toBe('^---!')` asserts the **subscription log** of a test source: when it was subscribed (`^`) and unsubscribed (`!`). Effects other than notifications (a `tap` counter) are checked with a plain `expect` after an explicit `flush()`.

### Concurrency and ordering

Everything runs on one thread, synchronously, in frame order. Grouping `(ab)` is the only way to say "same frame, this order". RxJS 9's `@rxjs/test` defines tie-breaks inside a frame: _"observation boundaries run first, observation starts run second, and ordinary source work runs afterward"_ ([`TESTING_DESIGN.md`][rx9-design]). Because it now patches realm globals (`setTimeout`, `Date`, `performance.now`, `requestAnimationFrame`, `AbortSignal.timeout`), _"Top-level `rxTest` calls in one realm are serialized FIFO"_ under a `Symbol.for('@rxjs/test/realm-lock/v1')` lock. Tests in one worker cannot run concurrently.

### Cancellation and teardown

This is the only DSL in the survey that **asserts unsubscription as a first-class timeline**. RxJS 7's own `switchMap` spec checks that the inner `x` was cut off when `y` arrived ([`switchMap-spec.ts` (7.x)][rx7-switchmap]):

```ts
const x = cold('           --a--b--c--d--e--|           ');
const xsubs = '   ---------^---------!                  ';
const y = cold('                     ---f---g---h---i--|');
const ysubs = '   -------------------^-----------------!';
const e1 = hot('  ---------x---------y---------|        ');
const expected = '-----------a--b--c----f---g---h---i--|';
```

What it cannot express is **join**. RxJS unsubscription is synchronous teardown, so "cancelled" and "finished cancelling" are the same frame by construction, and there is no notation for a teardown that takes time. RxJS 9 keeps `^`/`!` but redefines them over `AbortSignal`: _"a notification at the exact `!` frame is excluded, and the observation's `AbortSignal` is cancelled before ordinary source work scheduled for that frame"_ ([`TESTING_DESIGN.md`][rx9-design]).

### Failure output

`TestScheduler` itself only hands the two arrays to your comparator. RxJS 7's in-repo `observableMatcher` defines the house format: one JSON object per notification, actual block, then expected block ([`observableMatcher.ts` (7.x)][rx7-matcher]):

```ts
let message = '\nExpected \n';
actual.forEach((x: any) => (message += `\t${stringify(x)}\n`));
message += '\t\nto deep equal \n';
expected.forEach((x: any) => (message += `\t${stringify(x)}\n`));
```

The output is a frame-by-frame list such as `{"frame":5,"notification":{"kind":"N","value":"b"}}`. It is not re-rendered as a marble string, so a failing test shows the reader frame numbers and has to be mapped back to the diagram. RxJS 9's default adapter throws `RxTestAssertionError` with only `` `rxTest ${assertion.kind} assertion failed.` `` and the raw `actual`/`expected` attached ([`assertions.ts`][rx9-assert]). Readable diffs are delegated to the test framework through `assertDeepEqual`.

### Regrets and limits

- **Two dialects.** The guide states that `TestScheduler` _"was actually intended for testing RxJS itself by the maintainers, rather than for use in regular user apps"_. `run()` was added in v6 to change the defaults "in a non-breaking way", which left two grammars that disagree on whitespace, frame size and time progression ([`marble-testing.md`][rx-guide]).
- **RxJS 9 removed the class.** _"The RxJS 7 manual-mode `TestScheduler`, mutable `frameTimeFactor`, `maxFrames`, and static parsing methods are not public"_ ([`TESTING_DESIGN.md`][rx9-design]). The new `rxTest` returns a `Promise`, drains real microtasks between virtual tasks, and splits "cold" into three source models (`cold`, `hot`, `observable`) because _"One ambiguous `cold` helper would make tests misleading"_.
- **Alignment is the user's job.** The RxJS 9 design spends a section on in-string padding that must match the source-column offset of the opening quote exactly. Whitespace is ignored, so a misaligned diagram still parses and silently means something else.
- **Migration cost is measurable.** The 7→9 port carried 2,338 marble registrations, of which 418 needed "harness rewrites" and 215 remain "expected failure" ([`RXJS_7_MARBLE_TEST_PORT_NOTES.md`][rx9-port]).

### Worked test: keystroke during hash

```ts
// RxJS 7 TestScheduler.run — untested
testScheduler.run(({ hot, cold, expectObservable, expectSubscriptions }) => {
  const keys = hot('a 699ms b', { a: 'ab', b: 'abc' }); // "ab" at 0, "abc" at 700
  const hashes: Record<string, ColdObservable<string>> = {
    ab: cold('1s (x|)', { x: 'H(ab)' }), // a hash takes 1000 frames
    abc: cold('1s (y|)', { y: 'H(abc)' }),
  };
  const result = keys.pipe(
    switchMap(q => timer(500).pipe(switchMap(() => hashes[q]))),
  );

  expectObservable(result).toBe('2200ms y', { y: 'H(abc)' });
  expectSubscriptions(hashes.ab.subscriptions).toBe('500ms ^ 199ms !'); // started 500, cancelled 700
  expectSubscriptions(hashes.abc.subscriptions).toBe('1200ms ^ 999ms !'); // 1200 → completes 2200
});
```

The cancel is asserted. The join is not expressible, and the `199ms`/`999ms` arithmetic is the documented off-by-one.

---

## Rx.NET: `TestScheduler` and recorded notifications

The [Rx.NET deep-dive][rx-dotnet] covers the library. `Microsoft.Reactive.Testing` uses no notation. Inputs and outputs are **lists of tick-stamped notification values**, and the same list type sits on both sides of the assertion.

### Scripting inputs

`scheduler.CreateHotObservable(OnNext(300, "ab"), OnCompleted<string>(900))` and `CreateColdObservable(...)` take `params Recorded<Notification<T>>[]`, built with `ReactiveTest.OnNext(long ticks, T value)`, `OnError`, `OnCompleted` ([`ReactiveTest.cs`][rxnet-reactivetest]). Hot times are absolute; cold times are relative to each subscription. Non-observable inputs are `scheduler.Schedule(TimeSpan.FromTicks(n), action)` or imperative code between `AdvanceTo`/`AdvanceBy` calls ([`VirtualTimeScheduler.cs`][rxnet-vts]).

### Representing time

Time is a `long` in `TimeSpan` ticks (100 ns). The book: _"One tick corresponds to 100ns, so 1 second is 10,000,000 ticks"_ ([`16_TestingRx.md`][rxnet-intro]). `Start(create)` uses three magic constants, `Created = 100`, `Subscribed = 200`, `Disposed = 1000` ([`ReactiveTest.cs`][rxnet-reactivetest]). The book defends them by habit: _"developers working in the code base day in, day out soon get used to the idea that creation occurs at time 100, and subscription at time 200, and that you test everything you need to before 1000"_. The scheduler has to be **passed explicitly** to every time operator (`xs.Throttle(TimeSpan.FromTicks(20), scheduler)`, [`ThrottleTest.cs`][rxnet-throttletest]). The book's remedy is an injected `ISchedulerProvider`.

### Asserting outputs

`Start(create, created, subscribed, disposed)` schedules creation, subscription and disposal at those ticks, runs the clock, and returns an `ITestableObserver<T>` whose `Messages` is the recorded `IList<Recorded<Notification<T>>>` ([`TestScheduler.cs`][rxnet-ts]). The assertion is `res.Messages.AssertEqual(OnNext(230, 1), …, OnCompleted<int>(400))`, which is element-wise equality of value objects.

### Concurrency and ordering

Single-threaded virtual time. One quirk shapes every expected list: `ScheduleAbsolute` bumps any `dueTime <= Clock` to `Clock + 1` ([`TestScheduler.cs`][rxnet-ts]). "Immediate" work therefore happens one tick later, and the book's cold-source example shows every value at `10000001` rather than `10000000`. Same-tick collisions run in scheduling order.

### Cancellation and teardown

Rx.NET is as strong as RxJS here. Every test observable records `Subscriptions` as `Subscription(subscribe, unsubscribe)` pairs ([`ITestObservable.cs` via `ITestObserver.cs`][rxnet-itestobserver], [`Subscription.cs`][rxnet-subscription]). `Switch` is tested with `ys1.Subscriptions.AssertEqual(Subscribe(300, 400))`: inner `ys1` was disposed at 400 when `ys2` arrived ([`SwitchTest.cs`][rxnet-switchtest]). The same test preserves a semantic change under `#if !NO_PERF`, with the comment _"BREAKING CHANGE v2 > v1.x -> More aggressive disposal behavior"_ (`Subscribe(400, 450)` versus `Subscribe(400, 500)`). Disposal **timing** is part of the contract and the test pins it. As in RxJS, `Dispose` is synchronous, so join does not exist as a separate event.

### Failure output

`ReactiveAssert` renders both lists on two aligned lines ([`ReactiveAssert.cs`][rxnet-assert]):

```text
Expected: [OnNext(1)@230, OnNext(2)@260, OnCompleted()@400]
Actual..: [OnNext(1)@230, OnNext(2)@261, OnCompleted()@400]
```

The format comes from `Recorded.ToString()` (`Value + "@" + Time`, [`Recorded.cs`][rxnet-recorded]), `Notification.ToString()` (`OnNext({0})`, `OnError({type})`, `OnCompleted()`, [`Notification.cs`][rxnet-notification]) and `Subscription.ToString()` (`(200, 400)` or `(200, Infinite)`). The `Actual..:` padding is deliberate column alignment. The example values above are illustrative, not copied from a real failure.

### Regrets and limits

The magic constants and 100 ns ticks make tests read as arithmetic. A one-second debounce is `TimeSpan.FromSeconds(1).Ticks` everywhere. Explicit scheduler parameters leak into production signatures. The `+1` rule produces off-by-one expectations that look like bugs. On the positive side, the notation is plain data, so a helper can generate it, and the failure format stays readable at any length because each event is self-describing.

### Worked test: keystroke during hash

```csharp
// Rx.NET TestScheduler — untested; times in ticks, debounce 500, hash 1000
var s = new TestScheduler();
var keys = s.CreateHotObservable(OnNext(300, "ab"), OnNext(1000, "abc"));
var hAb  = s.CreateColdObservable(OnNext(1000, "H(ab)"),  OnCompleted<string>(1000));
var hAbc = s.CreateColdObservable(OnNext(1000, "H(abc)"), OnCompleted<string>(1000));
var hashes = new Dictionary<string, IObservable<string>> { ["ab"] = hAb, ["abc"] = hAbc };

var res = s.Start(() => keys
    .Select(q => Observable.Timer(TimeSpan.FromTicks(500), s).SelectMany(_ => hashes[q]))
    .Switch(), created: 100, subscribed: 200, disposed: 5000);

res.Messages.AssertEqual(OnNext(2500, "H(abc)"));
hAb.Subscriptions.AssertEqual(Subscribe(800, 1000));   // started after debounce, cut by keystroke
hAbc.Subscriptions.AssertEqual(Subscribe(1500, 2500));
```

---

## Swift Async Algorithms: `AsyncSequenceValidation`

The [Swift deep-dive][swift-async] covers the library. Philippe Hausler's validation DSL is a direct descendant of RxJS marbles, as its design note credits _"https://rxjs.dev/guide/testing/marble-testing and the graphical representations from https://rxmarbles.com"_ ([`Validation.md`][sw-validation]). It is built from a result builder and a hook into the concurrency runtime.

### Scripting inputs

Inside `validate { … }` the result builder takes up to three input diagram strings, then the sequence expression under test (`$0.inputs[0].debounce(for: .steps(3), clock: $0.clock)`), then the expected-output diagram ([`TestDebounce.swift`][sw-debounce-test]). Input elements are always `String`, a deliberate restriction: _"By restricting the domain space of values to `String` we can describe the events as a domain specific language"_ ([`Validation.md`][sw-validation]). Only these diagram-driven `AsyncSequence` inputs can be scripted. There is no slot for a side input such as a toggle written mid-test.

### Representing time

A custom `AsyncSequenceValidationDiagram.Clock` counts integral **steps**, one per symbol, so `"a--b"` puts `b` at step 3. `minimumResolution` is fixed at `.steps(1)` and `tolerance` is ignored, _"because there is no sub-step granularity besides the order of execution"_. Spaces are alignment-only. Code under test must take the diagram's clock as a parameter (`clock: $0.clock`), so production operators have to be generic over `Clock`.

### Asserting outputs

The expected diagram is parsed into `(Instant, Result<String?, Error>)` events and compared with what the consumer task received at each step. The theme symbols are `-` step, `|` finish, `^` thrown error, `;` cancel, `[ab]` same-step group, `'foo'` multi-character value, and `,` delay-next ([`Validation.md`][sw-validation]). Themes are pluggable; the design note shows an emoji theme.

### Concurrency and ordering

Determinism comes from the runtime, not the code under test. `validate` installs `swift_task_enqueueGlobal_hook` so every job enqueued anywhere goes to one `TaskDriver` thread and runs in lockstep with the clock ([`Test.swift`][sw-test]). The design note: _"input 0 is emitted first, then input 1, etc. After the ordering of input events, the jobs enqueued onto that task driver thread are executed in order of receipt"_. The hook and `Context.clock` are process-global `static` state, so validation tests cannot run concurrently with each other. That is an inference from the code; the doc does not state it.

### Cancellation and teardown

`;` in the **expected** diagram does not assert anything. The driver calls `runner.cancel()` on the consumer task at that step (`if cancelEvents.contains(diagram.queue.now.advanced(by: .steps(1))) { runner.cancel() }`, [`Test.swift`][sw-test]). Cancellation can therefore be **scripted** downstream but not **observed** upstream. When an input iterator is cancelled, its `onCancel` handler only removes a queue token ([`Input.swift`][sw-input]) and records nothing, so a test cannot check that an inner sequence was torn down. The doc admits the gap: expectations _"notably avoids cancellation and steps, since those are better expressed through the failure reporting system"_. One more data point: the package's own `flatMapLatest` tests do not use `validate` at all. They are ordinary `async` tests with real `Task.sleep(nanoseconds: 10_000_000)` ([`TestFlatMapLatest.swift`][sw-fml-test]).

### Failure output

Two layers. Each mismatch becomes an `ExpectationFailure` whose description is a sentence with a step number, such as `expected "X" but got "C" at tick 6` or `unexpected finish` ([`Expectation.swift`][sw-expectation], [`TestValidationTests.swift`][sw-validation-tests]). The XCTest glue then **re-renders both timelines as diagrams** with the same theme ([`ValidationTest.swift`][sw-xctest]):

```swift
let expected = result.reconstituteExpected(theme: theme)
let actual = result.reconstituteActual(theme: theme)
if expected != actual {
  XCTFail("Validation failure:\nExpected:\n\(expected)\nActual:\n\(actual)", file: file, line: line)
}
```

This is the only system in the survey that prints the failure in the same notation the test was written in.

### Regrets and limits

The "Future Directions" section lists what is missing: unordered groups (`{ }`) for races the runtime cannot order, mapping other clocks onto diagram steps, and checking iteration past termination. String-only values push every test through a `map` to `String`. The global enqueue hook is an unofficial runtime entry point declared in a private C header (`_CAsyncSequenceValidationSupport.h`).

### Worked test: keystroke during hash

```swift
// AsyncSequenceValidation — untested; debounce 3 steps, hash 4 steps.
// "a" stands for query "ab", "b" for "abc".
validate { diagram in
  "a----b-------|"
  diagram.inputs[0].flatMapLatest { q in
    [q].async.map { q in
      try await diagram.clock.sleep(for: .steps(3)) // the per-query debounce
      try await diagram.clock.sleep(for: .steps(4)) // the "hash"
      return q.uppercased()
    }
  }
  "------------B|"
}
```

Output `B` at step 12 shows the old hash produced nothing. **Nothing in the notation records that hash `a` was cancelled at step 5, or that it finished cancelling.** A test needing that would have to send side-channel strings into an actor and assert them after `validate` returns.

---

## Kotlin: `kotlinx-coroutines-test` and Turbine

The [Kotlin Flow deep-dive][kotlin-flow] covers the library. Kotlin splits testing into two layers that use no notation. `kotlinx-coroutines-test` provides virtual time and dispatchers (`runTest`, `TestScope`, `TestCoroutineScheduler`). Turbine adds a pull-style expectation queue on top of a `Flow`.

### Scripting inputs

Inputs are plain Kotlin. The test writes `MutableStateFlow.value`, `emit`s into a `MutableSharedFlow`, sends to a `Channel`, or calls a fake. Turbine adds a standalone `Turbine<T>()` to put inside fakes (`goTos.add(screen)`). Its README promises: _"Use them everywhere, and you might never need `runCurrent()` again"_ ([`README.md` (Turbine)][tb-readme]).

### Representing time

`TestCoroutineScheduler` keeps a virtual millisecond clock. `delay` inside `runTest` is skipped while relative order is kept. Control is imperative: `runCurrent()`, `advanceTimeBy(d)`, `advanceUntilIdle()`, `currentTime` ([`README.md` (coroutines-test)][kt-readme]). `advanceTimeBy` is half-open: it runs _"the tasks scheduled for `currentTime()..<currentTime() + delayTimeMillis`"_ ([`TestCoroutineScheduler.kt`][kt-scheduler]). A task due exactly at the target needs a following `runCurrent()`. Turbine's own `await*` timeouts are **wall-clock**: _"This is a wall clock time timeout that ignores `runTest`'s virtual clock time. The default timeout length is three seconds"_.

### Asserting outputs

Inside `flow.test { … }`, `awaitItem()`, `awaitComplete()`, `awaitError()`, `expectNoEvents()`, `expectMostRecentItem()`, `skipItems(n)` consume a queue of `Event`s ([`ReceiveTurbine.kt`][tb-receive]). At the end of the block, `test` cancels collection and calls `ensureAllEventsConsumed()`, so an unasserted event fails the test. That is exhaustiveness by default, as with a recorded transcript.

### Concurrency and ordering

The dispatcher choice decides ordering. `StandardTestDispatcher` queues every launch until the scheduler runs it. `UnconfinedTestDispatcher` enters child coroutines eagerly, and its KDoc warns that it _"can only be used reliably for testing functionality, not the specific order of actions"_ ([`TestCoroutineDispatchers.kt`][kt-dispatchers]). Turbine collects on `UnconfinedTestDispatcher` internally to avoid conflation, and its README states the cost: _"we are currently forced to depend on an unstable API from kotlinx.coroutines test artifact: `UnconfinedTestDispatcher`. Without this usage of Turbine with `runTest` would break"_ ([`README.md` (Turbine)][tb-readme]). Code that hops to `Dispatchers.Default`/`IO` leaves virtual time entirely, so the README asks for dispatchers to be injected. `Dispatchers.setMain` is process-global, which blocks parallel test execution for code that uses `Main` (an inference).

### Cancellation and teardown

Neither layer has a cancellation assertion. Tests observe cancellation through side effects in `finally`/`catch (e: CancellationException)` or `Job.isCancelled`. `backgroundScope` gives a scope that is cancelled at test end, so `runTest` does not wait forever for an infinite collector. kotlinx.coroutines' own test suite shows the idiom a library author reaches for: **numbered checkpoints**. `expect(n)` asserts that this is the n-th action, `finish(n)` the last, and `hang { … }` suspends until cancelled and then runs its block ([`TestBase.common.kt`][kt-testbase]). `flatMapLatest` is tested by putting `hang { expect(value) }` in each superseded inner and `finish(4)` at the end ([`FlatMapLatestTest.kt`][kt-fml-test]). That asserts both that each inner was cancelled and the order in which the cancellations ran, which is the closest thing to a join assertion in this survey. Its failure text is `Expecting action index 3 but it is actually 4`.

### Failure output

Turbine reports unconsumed events as a list and attaches an unconsumed error as `cause` ([`README.md` (Turbine)][tb-readme]):

```text
app.cash.turbine.TurbineAssertionError: Unconsumed events found:
 - Error(RuntimeException)
Caused by: java.lang.RuntimeException: broken!
```

A mismatch reads `Expected complete for turbine 1 but found Item(1)` (named turbines exist for this). A missing event times out as `No value produced in 1s`. There are no timestamps in any message, because virtual time is not part of the assertion model.

### Regrets and limits

The changelogs record how unsettled timeouts have been. `runTest` gained a 10 s whole-test timeout in 1.7.0, _"10 seconds by default (#3270)"_, and 1.8.0 changed it to 60 s ([`CHANGES.md`][kt-changes]). Turbine removed its own timeout in 0.8.0 (_"The new `runTest` API … enforces a timeout automatically"_), restored a 1 s wall-clock timeout in 0.11.0 and raised it to 3 s in 0.12.2 ([`CHANGELOG.md` (Turbine)][tb-changelog]). Shared flows lose items emitted before `test` subscribes; the README devotes a section to it. Picking between `Standard` and `Unconfined` is a per-test decision that changes which orderings are observable.

### Worked test: keystroke during hash

```kotlin
// kotlinx-coroutines-test + Turbine — untested
@Test fun keystrokeDuringHash() = runTest {
    val query = MutableSharedFlow<String>(extraBufferCapacity = 8)
    val hashLog = Turbine<String>(name = "hashLog")
    fun hash(q: String) = flow {
        hashLog.add("start $q")
        try { delay(1_000); emit("H($q)") }
        catch (e: CancellationException) { hashLog.add("cancel $q"); throw e }
    }
    query.flatMapLatest { q -> flow { delay(500); emitAll(hash(q)) } }.test(name = "results") {
        query.emit("ab")
        advanceTimeBy(500); runCurrent()          // half-open: the 500 ms task needs runCurrent
        assertEquals("start ab", hashLog.awaitItem())
        advanceTimeBy(200); query.emit("abc"); runCurrent()
        assertEquals("cancel ab", hashLog.awaitItem())
        advanceTimeBy(500); runCurrent()
        assertEquals("start abc", hashLog.awaitItem())
        advanceTimeBy(1_000); runCurrent()
        assertEquals("H(abc)", awaitItem())
        cancelAndIgnoreRemainingEvents()
    }
    hashLog.ensureAllEventsConsumed()
}
```

---

## Pekko Streams: testkit probes

The [Pekko Streams deep-dive][pekko] covers the library. Pekko tests a stream by materialising it against **probes**: a `TestPublisher.Probe` stands in for an upstream, a `TestSubscriber.Probe` for a downstream. The test drives each side by hand, including demand.

### Scripting inputs

`TestSource[T]()` materialises to a `TestPublisher.Probe[T]`, which has `sendNext`, `sendComplete`, `sendError`, and `expectRequest()` to wait for demand ([`StreamTestKit.scala`][pk-stk], [`TestSource.scala`][pk-testsource]). Inner streams are scripted by handing out `Source.fromPublisher(TestPublisher.probe[Int]())`. At this revision the factory is `TestSource[T]()`; `TestSource.probe` does not exist in the source tree.

### Representing time

By default there is no virtual time. Probe expectations block the test thread with **real** timeouts (`expectNext(d: FiniteDuration)`, `expectNoMessage(max)`), and operators like `delay` use the real scheduler. Virtual time means reconfiguring the whole actor system with `pekko.scheduler.implementation = "org.apache.pekko.testkit.ExplicitlyTriggeredScheduler"` and calling `timePasses(d)`, which _"executing all outstanding jobs on the calling thread before returning"_ ([`ManualTime.scala`][pk-manualtime]). `ManualTime` is the typed wrapper; stream specs cast `system.scheduler` themselves (`AggregateWithBoundarySpec`). Stage execution stays asynchronous on actors, so even `ManualTime.expectNoMessageFor` _"waits for the configured `pekko.actor.testkit.typed.expect-no-message-default` duration so that asynchronously dispatched messages can arrive"_.

### Asserting outputs

`TestSink[T]()` materialises to a `TestSubscriber.Probe[T]` with `request(n)`, `expectNext(e1, e2, es*)`, `expectNextUnordered`, `expectComplete()`, `expectError()`, `expectNoMessage`, `cancel()` ([`StreamTestKitDocSpec.scala`][pk-docspec]):

```scala
sourceUnderTest.runWith(TestSink[Int]()).request(2).expectNext(4, 8).expectComplete()
```

Assertions are sequential and fluent (`this.type`), with no timeline. **Demand** is part of the script: nothing flows until `request(n)`, so a test can show that an operator does not over-request.

### Concurrency and ordering

Real concurrency: the graph runs on its own actors while the test thread waits on probe queues. Ordering is asserted only per probe, and `expectNextUnordered` exists because cross-source order is not deterministic. Pekko leans into this. A **fuzzing mode** (`pekko.stream.materializer.debug.fuzzing-mode = on`) _"exercises concurrent execution paths more aggressively … and therefore helps exposing race conditions in tests"_ ([`stream-testkit.md`][pk-docs]). Here randomness is a test strategy, not a defect to remove.

### Cancellation and teardown

Cancellation is a **first-class expectation on the upstream probe**: `expectCancellation()` and `expectCancellationWithCause(cause)`, the latter failing with `Expected cancellation cause to be $expectedCause but was $cause` ([`StreamTestKit.scala`][pk-stk]). `switchMap` is tested as `mainPub.sendNext(Source.fromPublisher(subPub)); subPub.expectRequest(); mainPub.sendError(ex); subPub.expectCancellation()` ([`FlowSwitchSpec.scala`][pk-switch]), and `flatMapMerge` the same way for every substream ([`FlowFlattenMergeSpec.scala`][pk-flatten]). The probe sees the cancel **signal**. It cannot see whether the cancelled inner's resources have been released (join); that needs a materialised `Future` or a `watchTermination`.

### Failure output

Probe failures are classic `TestKit` assertion strings, one event at a time: `timeout (3 seconds) during expectMsg while waiting for OnNext(4)` or `expected OnNext(4), found OnComplete` ([`TestKit.scala`][pk-testkit]; the event names in these examples are illustrative). `expectNext` adds `Expected OnNext(_), yet no element signaled during $t`. Nothing prints the history leading up to the failure.

### Regrets and limits

Real-time waits make suites slow and timing-sensitive. Every negative assertion (`expectNoMessage`) costs its full timeout, and a long-enough GC pause turns into a failure. Virtual time is system-wide configuration rather than a per-test value, and it does not make stage execution synchronous. The model does fit **demand and cancellation** better than any notation here, because the probe is itself a Reactive Streams endpoint.

### Worked test: keystroke during hash

```scala
// Pekko Streams testkit with ExplicitlyTriggeredScheduler — untested
val ets = system.scheduler.asInstanceOf[ExplicitlyTriggeredScheduler]
val hAb, hAbc = TestPublisher.probe[String]()
val hashes = Map("ab" -> hAb, "abc" -> hAbc)
val (keys, results) = TestSource[String]()
  .switchMap(q => Source.single(q).delay(500.millis).flatMapConcat(q => Source.fromPublisher(hashes(q))))
  .toMat(TestSink[String]())(Keep.both).run()

results.request(1)
keys.sendNext("ab")
ets.timePasses(500.millis)
hAb.expectRequest()                 // hash "ab" started (subscribed and pulled)
ets.timePasses(200.millis)
keys.sendNext("abc")
hAb.expectCancellation()            // superseded hash cancelled
ets.timePasses(500.millis)
hAbc.expectRequest()
hAbc.sendNext("H(abc)").sendComplete()
results.expectNext("H(abc)")
```

---

## Effect TS `TestClock` and cats-effect `TestControl`

The [Effect TS][effect-ts] and [fs2][fs2] deep-dives cover the libraries. Neither ecosystem has a stream notation. A test is an ordinary program run under a substituted clock (Effect) or a substituted runtime (cats-effect). Assertions are on **outcomes**: `Exit` or `Outcome` values that include interruption.

### Scripting inputs

Inputs are effects in the test body: `Queue.offer`, `Ref.set`, `Deferred.succeed`, forked fibers. In Effect v4 the `TestServices` module is gone, and every member's migration note reads _"Use Vitest metadata/options for runner concerns, an ordinary Ref or Context.Reference for application-owned test state, and FiberSet for explicit fiber tracking"_ ([`effect__TestServices.yaml`][ef-mig-services]). cats-effect inputs are likewise ordinary `IO` values inside the program handed to `TestControl.execute`.

### Representing time

Effect: `TestClock.adjust(d)` and `setTime(t)` move a virtual clock, and _"all effects scheduled to take place on or before that time will automatically run in order"_ ([`TestClock.ts`][ef-testclock]). `it.effect` from `@effect/vitest` provides it per test along with a fresh `Scope`, and `it.live` opts out ([`README.md` (vitest)][ef-vitest]). The clock **warns** instead of hanging: _"A test is using time, but is not advancing the test clock, which may result in the test hanging. Use TestClock.adjust to manually advance the time."_ cats-effect: `TestControl` is _"a mock runtime for Cats Effect `IO`"_ whose time _"only advances in response to external reconfiguration"_ ([`test-runtime.md`][ce-docs]). The controls are `tick` (run until every fiber sleeps, without advancing time), `nextInterval` (the smallest pending sleep), `advance`, `advanceAndTick`, `tickFor` and `tickAll` ([`TestControl.scala`][ce-testcontrol]).

### Asserting outputs

Effect: `Fiber.await(fiber)` or `Effect.exit(eff)` yields an `Exit`, asserted with Vitest's `expect(...).toStrictEqual(Exit.succeed(2))`. cats-effect: `control.results` is `Option[Outcome[Id, Throwable, A]]`. `None` means still running, and `Some(Outcome.canceled)` is a value you can assert. `executeEmbed` folds it into the test's `IO`, turning cancellation and non-termination into `CancellationException` and `NonTerminationException`. fs2 adds `assertEmits(List(…))` over `compile.toList` ([`Fs2Suite.scala`][fs2-suite]). Its `debounce` test is one line inside `executeEmbed` ([`StreamCombinatorsSuite.scala`][fs2-combinators]).

### Concurrency and ordering

This is the sharpest contrast in the survey. `TestControl` runs on one thread but is **deliberately not FIFO**: _"it randomly selects between all pending fibers at each yield point. This makes it considerably better at identifying subtle sequencing bugs"_ ([`test-runtime.md`][ce-docs]). The randomness is seeded and reproducible: `control.seed` is _"the base64-encoded seed which governs the random task interleaving during each [[tick]]. This is useful for reproducing test failures"_, and `execute(program, seed = Some(…))` replays it ([`TestControl.scala`][ce-testcontrol]). Effect's `TestClock` runs woken sleepers in deadline order and needs the tracking scheduler that `TestClock.layer()` installs: _"providing a clock from `make` by hand does not install the tracking scheduler"_. Because the clock is a per-test service rather than a global, `it.effect` tests run concurrently under Vitest (`ctx.expect` keeps assertions per test).

### Cancellation and teardown

Interruption is an outcome, so it can be asserted directly. Effect's own suite has `adjust - skips the cancelled deadline (interrupted sleep)` ([`TestClock.test.ts`][ef-testclock-test]). In both systems **join is native**: `Fiber.join`/`fiber.join` waits for the fiber's finalizers, and `Outcome.canceled` is only produced after they have run. fs2 turns join into a property. `"inner stream finalizer always runs before switching"` sets a `Ref` flag in the inner's `onFinalize(IO.sleep(100.millis) >> ref.set(true))` and fails if the next inner starts before it ([`StreamSwitchMapSuite.scala`][fs2-switchmap]). It runs under `forAllF` over arbitrary streams.

### Failure output

No stream-specific format. Effect delegates to Vitest's structural diff of `Exit` values. cats-effect delegates to MUnit's `assertEquals` on `Outcome` (format not reproduced here). The diagnostic both have is about **time misuse**: Effect's warnings (including _"A fiber woken by the test clock is still running without suspending, so the test clock stopped waiting for it"_), and cats-effect's deadlock detection (`isDeadlocked`, `NonTerminationException` for `IO.never`).

### Regrets and limits

The cats-effect docs list traps. Advancing before the program reaches its `sleep` does nothing useful, so the docs teach `tick` → `advance` → `tick`. A fiber that loops on `IO.cede` keeps `tick` from ever returning. And `TestControl` _"may mask concurrency bugs and race conditions"_ because it is single-threaded. Effect v4's migration notes remove the introspection that v3 had: `TestClock.sleeps` (the pending-sleep list) has no replacement. The suggested pattern is to _"Test observable behavior by forking sleepers, adjusting time, and joining or asserting the fibers"_ ([`effect__TestClock.yaml`][ef-mig-clock]).

### Worked test: keystroke during hash

```scala
// fs2 + cats-effect TestControl — untested
test("keystroke during hash") {
  val program = for {
    log  <- IO.ref(Vector.empty[String])
    keys <- Queue.unbounded[IO, Option[String]]
    hash  = (q: String) => (log.update(_ :+ s"start $q") >> IO.sleep(1.second).as(s"H($q)"))
                             .onCancel(log.update(_ :+ s"cancel $q"))
    fib  <- Stream.fromQueueNoneTerminated(keys)
              .switchMap(q => Stream.sleep_[IO](500.millis) ++ Stream.eval(hash(q)))
              .take(1).compile.lastOrError.start
    _    <- keys.offer(Some("ab")) >> IO.sleep(700.millis) >> keys.offer(Some("abc"))
    out  <- fib.joinWithNever
    l    <- log.get
  } yield (out, l)
  TestControl.executeEmbed(program)
    .assertEquals(("H(abc)", Vector("start ab", "cancel ab", "start abc")))
}
```

Here `"cancel ab"` precedes `"start abc"` only because of the 500 ms debounce in between, so this log does not prove the join. To prove it, make the cancel slow (`onCancel(IO.sleep(1.second) >> log…)`) and assert the log order and the final virtual time. That is the shape of fs2's own `"inner stream finalizer always runs before switching"` property. The Effect TS version is the same shape: `it.effect`, a `Queue`, `Stream.switchMap`, `Effect.onInterrupt` logging, `TestClock.adjust("700 millis")`, then `Fiber.join` (names `Stream.switchMap`, `Stream.fromQueue`, `Effect.onInterrupt`, `Effect.forkChild` exist at the pinned SHA; the argument shapes are unverified).

---

## Comparison

| System                                                                        | Input notation                              | Time                                                                      | Assertion style                                   | Concurrency handling                                                    | Cancel observable?                                                               | Failure diff                                                                   |
| ----------------------------------------------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| [RxJS 7 `run`](#rxjs-marble-testing)                                          | Marble strings (`cold`/`hot`), `values` map | 1 frame = 1 ms; position in string; `500ms` tokens                        | Whole-timeline equality, deferred to flush        | Single thread; provider delegates swapped                               | **Yes**: `expectSubscriptions('^--!')`; join not expressible (sync teardown)     | JSON object per frame, actual block then expected block                        |
| [RxJS 9 `rxTest`](#rxjs-marble-testing)                                       | Same grammar; three source models           | Realm globals patched; async drain                                        | Same, via pluggable `assertDeepEqual`             | Serialised per realm by a global lock                                   | Yes (`AbortSignal`-based `^`/`!`)                                                | Delegated to framework; default carries raw arrays                             |
| [Rx.NET](#rx-net-testscheduler-and-recorded-notifications)                    | `OnNext(ticks, v)` lists                    | 100 ns ticks; 100/200/1000 defaults; `+1` for "now"                       | `Messages.AssertEqual(...)` element-wise          | Single thread; scheduler passed explicitly                              | **Yes**: `Subscriptions.AssertEqual(Subscribe(300, 400))`; no join               | `Expected: [OnNext(1)@230, …]` / `Actual..: […]`                               |
| [Swift validation](#swift-async-algorithms-asyncsequencevalidation)           | Diagram strings, `String` values only       | Integral steps, one per symbol; injected `Clock`                          | Whole-timeline per step                           | Global enqueue hook; one driver thread; not parallel                    | Scripted (`;` cancels the consumer), **not observable** upstream                 | Per-event sentence `at tick N` **plus both timelines re-rendered as diagrams** |
| [Kotlin + Turbine](#kotlin-kotlinx-coroutines-test-and-turbine)               | Plain calls (`emit`, `value =`)             | Virtual ms; `advanceTimeBy` half-open; Turbine timeouts wall-clock        | Sequential `awaitItem()`; exhaustive at block end | Dispatcher choice (`Standard` vs `Unconfined`) changes observable order | Only via side effects; library's own tests use `expect(n)`/`hang {}` checkpoints | `Expected complete … but found Item(1)`; unconsumed-event list                 |
| [Pekko probes](#pekko-streams-testkit-probes)                                 | Probe calls (`sendNext`, `request(n)`)      | Real time by default; system-wide `ExplicitlyTriggeredScheduler` optional | Sequential fluent `expectNext`; demand explicit   | Truly concurrent; `expectNextUnordered`; fuzzing mode                   | **Yes**: `expectCancellation()`, with cause; no join                             | `TestKit` one-line `timeout … while waiting for …` / `expected …, found …`     |
| [Effect `TestClock`](#effect-ts-testclock-and-cats-effect-testcontrol)        | Effects in the test body                    | Per-test clock service; `adjust`; warns when unadvanced                   | `Exit` values with framework `expect`             | Deadline order; per-test so tests run concurrently                      | **Yes** as `Exit` interruption; **join native** (`Fiber.join`)                   | Framework structural diff                                                      |
| [cats-effect `TestControl`](#effect-ts-testclock-and-cats-effect-testcontrol) | `IO` program                                | Mock runtime; `tick`/`advance`/`nextInterval`                             | `results: Option[Outcome]`                        | **Seeded random** interleaving; seed reported for replay                | **Yes** as `Outcome.canceled`; join native; fs2 asserts join order as a property | Framework diff; deadlock reported as `NonTerminationException`                 |

---

## Lessons for the D harness

1. **Make cancellation a recorded event in the transcript, not a side effect the test has to instrument.** Only the two Rx schedulers ([RxJS](#rxjs-marble-testing), [Rx.NET](#rx-net-testscheduler-and-recorded-notifications)) and Pekko's probes ([Pekko](#pekko-streams-testkit-probes)) assert cancellation without help. Kotlin, Swift and fs2 tests all hand-write a `catch`/`onCancel` log. The D `TestCpuPool` already sees the token, so it should write `cancel` lines itself.
2. **Record join as a separate event from cancel.** RxJS and Rx.NET cannot tell them apart because teardown is synchronous ([RxJS § Cancellation](#rxjs-marble-testing)). The D design's cancel-and-join scopes can tell them apart, and fs2's `"inner stream finalizer always runs before switching"` shows the property is worth testing ([Effect/cats-effect § Cancellation](#effect-ts-testclock-and-cats-effect-testcontrol)). A transcript line pair such as `t=700 cancel hash#1 (superseded)` … `t=700 joined hash#1` makes the order checkable, with the `InterruptKind` included.
3. **Prefer a byte-exact, timestamped transcript over a marble grammar for whole pipelines.** Marble strings are compact for one operator but have documented traps: the 1-frame value width, the group-width rule, whitespace alignment, and two dialects ([RxJS § Regrets](#rxjs-marble-testing)). Swift restricts values to `String` to make them work ([Swift § Scripting](#swift-async-algorithms-asyncsequencevalidation)). Rx.NET's `OnNext(230, 1)` list proves that plain timestamped records are enough for `Switch` and `Throttle` ([Rx.NET](#rx-net-testscheduler-and-recorded-notifications)), and the existing `checkWriter` diff already gives a readable failure for free.
4. **If a compact notation is offered, render failures back into it.** Swift's re-rendered `Expected:`/`Actual:` diagrams are the most readable failure in the survey. RxJS's frame-numbered JSON forces mental re-alignment ([Swift § Failure output](#swift-async-algorithms-asyncsequencevalidation), [RxJS § Failure output](#rxjs-marble-testing)). A D `marble!"…"` helper, if any, should be a pretty-printer for transcripts, not a second assertion engine.
5. **Assert exhaustively by default.** Turbine's `ensureAllEventsConsumed` and the whole-timeline comparisons of RxJS and Rx.NET catch the unexpected extra emission or the forgotten cancel ([Kotlin § Asserting](#kotlin-kotlinx-coroutines-test-and-turbine)). A transcript comparison is exhaustive by construction. Do not add a per-event "expect next" API that lets events go unchecked.
6. **Keep every time source inside the capability row, with no wall-clock fallback.** Kotlin's virtual-time leaks through `Dispatchers.IO`, Turbine's wall-clock timeouts (1 s → none → 1 s → 3 s), and Pekko's real-time probes are the documented complaints ([Kotlin § Regrets](#kotlin-kotlinx-coroutines-test-and-turbine), [Pekko § Time](#pekko-streams-testkit-probes)). Because the D `TestClock` is the only clock, a stuck test can be reported as a deadlock, the way cats-effect's `isDeadlocked` and Effect's "not advancing the test clock" warning do, instead of timing out.
7. **Give `advance` closed-interval semantics, plus `advanceToNext` and `nextDeadline`.** Kotlin's half-open `advanceTimeBy` needs a trailing `runCurrent()` ([Kotlin § Time](#kotlin-kotlinx-coroutines-test-and-turbine)). Rx.NET's `+1` rule shifts every "immediate" event ([Rx.NET § Ordering](#rx-net-testscheduler-and-recorded-notifications)). cats-effect's `nextInterval` and `tickFor` show the value of asking for the next deadline instead of guessing it ([cats-effect § Time](#effect-ts-testclock-and-cats-effect-testcontrol)).
8. **Make scheduling non-determinism a seeded, reported parameter of `TestSched`.** cats-effect's random-but-seeded fiber selection and Pekko's fuzzing mode find ordering bugs that FIFO virtual time hides ([cats-effect § Concurrency](#effect-ts-testclock-and-cats-effect-testcontrol), [Pekko § Concurrency](#pekko-streams-testkit-probes)). The task-DAG harness's scrambled completion orders are the same idea. Print the seed on failure, and let the transcript differ only where the test declares an unordered group (the `{ }` Swift lists as future work).
9. **Keep the harness free of process-global state so tests run in parallel.** RxJS 9 serialises tests per realm because it patches globals, and Swift's enqueue hook and Kotlin's `setMain` are global too ([RxJS § Concurrency](#rxjs-marble-testing), [Swift § Concurrency](#swift-async-algorithms-asyncsequencevalidation)). Effect's per-test `TestClock` service is the model that parallelises ([Effect § Concurrency](#effect-ts-testclock-and-cats-effect-testcontrol)), and the D design already threads the clock through `C`.
10. **Script demand and CPU completion explicitly, as probes do.** Pekko's `request(n)` and `expectRequest()` make backpressure testable ([Pekko § Asserting](#pekko-streams-testkit-probes)). The D equivalent is a `TestCpuPool` whose jobs stay pending until `pool.complete(job, result)`. "Keystroke during hash" then needs no hash duration in virtual time: the test types `"abc"` while job #1 is pending and asserts its token was cancelled and joined before job #2 is submitted.

---

## Sources

- RxJS (`ReactiveX/rxjs`, `60d632c3878d`, 2026-11-18, `9.0.0-beta.0`): [`marble-testing.md`][rx-guide], [`TESTING_DESIGN.md`][rx9-design], [`RXJS_7_MARBLE_TEST_PORT_NOTES.md`][rx9-port], [`assertions.ts`][rx9-assert], [`types.ts`][rx9-types], [`marble-parser.ts`][rx9-parser]. RxJS 7.x (`e5351d02e225`, the port's pinned source): [`TestScheduler.ts`][rx7-ts], [`observableMatcher.ts`][rx7-matcher], [`switchMap-spec.ts`][rx7-switchmap].
- Rx.NET (`dotnet/reactive`, `d257d1b58fe3`): [`TestScheduler.cs`][rxnet-ts], [`ReactiveTest.cs`][rxnet-reactivetest], [`ReactiveAssert.cs`][rxnet-assert], [`Recorded.cs`][rxnet-recorded], [`Subscription.cs`][rxnet-subscription], [`ITestObserver.cs`][rxnet-itestobserver], [`Notification.cs`][rxnet-notification], [`VirtualTimeScheduler.cs`][rxnet-vts], [`SwitchTest.cs`][rxnet-switchtest], [`ThrottleTest.cs`][rxnet-throttletest], [`16_TestingRx.md`][rxnet-intro].
- Swift Async Algorithms (`apple/swift-async-algorithms`, `088f92a30c10`, 2026-11-18): [`Validation.md`][sw-validation], [`Test.swift`][sw-test], [`Expectation.swift`][sw-expectation], [`Input.swift`][sw-input], [`ValidationTest.swift`][sw-xctest], [`TestDebounce.swift`][sw-debounce-test], [`TestValidationTests.swift`][sw-validation-tests], [`TestFlatMapLatest.swift`][sw-fml-test].
- kotlinx.coroutines (`Kotlin/kotlinx.coroutines`, `7f4d6cf24149`, 2026-11-18): [`kotlinx-coroutines-test/README.md`][kt-readme], [`TestCoroutineScheduler.kt`][kt-scheduler], [`TestCoroutineDispatchers.kt`][kt-dispatchers], [`CHANGES.md`][kt-changes], [`TestBase.common.kt`][kt-testbase], [`FlatMapLatestTest.kt`][kt-fml-test].
- Turbine (`cashapp/turbine`, `4590489b93f2`, 2026-11-21, README version 1.2.1): [`README.md`][tb-readme], [`CHANGELOG.md`][tb-changelog], [`ReceiveTurbine.kt`][tb-receive], [`Turbine.kt`][tb-turbine], [`channel.kt`][tb-channel].
- Pekko (`apache/pekko`, `df133f7de2d5`): [`stream-testkit.md`][pk-docs], [`StreamTestKitDocSpec.scala`][pk-docspec], [`StreamTestKit.scala`][pk-stk], [`TestSource.scala`][pk-testsource], [`TestKit.scala`][pk-testkit], [`ManualTime.scala`][pk-manualtime], [`FlowSwitchSpec.scala`][pk-switch], [`FlowFlattenMergeSpec.scala`][pk-flatten].
- Effect (`Effect-TS/effect`, `e3aca1f1484e`, 2026-11-20, `effect` 4.1.5): [`TestClock.ts`][ef-testclock], [`TestClock.test.ts`][ef-testclock-test], [`@effect/vitest` README][ef-vitest], [`effect__TestClock.yaml`][ef-mig-clock], [`effect__TestServices.yaml`][ef-mig-services].
- cats-effect (`typelevel/cats-effect`, `de84c01f76b2`, 2026-09-28): [`test-runtime.md`][ce-docs], [`TestControl.scala`][ce-testcontrol]. fs2 (`typelevel/fs2`, `f679d5b45054`, 2026-11-19): [`StreamCombinatorsSuite.scala`][fs2-combinators], [`StreamSwitchMapSuite.scala`][fs2-switchmap], [`Fs2Suite.scala`][fs2-suite].
- Sibling deep-dives: [RxJS][rxjs], [Rx.NET][rx-dotnet], [Swift Async Algorithms][swift-async], [Kotlin Flow][kotlin-flow], [Pekko Streams][pekko], [Effect TS][effect-ts], [fs2][fs2]; umbrella [index][index], [comparison][comparison].

<!-- References -->

[rx-guide]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/apps/rxjs.dev/content/guide/testing/marble-testing.md
[rx9-design]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/docs/rxjs-next/TESTING_DESIGN.md
[rx9-port]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/docs/rxjs-next/RXJS_7_MARBLE_TEST_PORT_NOTES.md
[rx9-assert]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/test/src/assertions.ts
[rx9-types]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/test/src/types.ts
[rx9-parser]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/test/src/marble-parser.ts
[rx7-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/testing/TestScheduler.ts
[rx7-matcher]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/spec/helpers/observableMatcher.ts
[rx7-switchmap]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/spec/operators/switchMap-spec.ts
[rxnet-ts]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/Microsoft.Reactive.Testing/TestScheduler.cs
[rxnet-reactivetest]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/Microsoft.Reactive.Testing/ReactiveTest.cs
[rxnet-assert]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/Microsoft.Reactive.Testing/ReactiveAssert.cs
[rxnet-recorded]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/Microsoft.Reactive.Testing/Recorded.cs
[rxnet-subscription]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/Microsoft.Reactive.Testing/Subscription.cs
[rxnet-itestobserver]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/Microsoft.Reactive.Testing/ITestObserver.cs
[rxnet-notification]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Notification.cs
[rxnet-vts]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Concurrency/VirtualTimeScheduler.cs
[rxnet-switchtest]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/tests/Tests.System.Reactive/Tests/Linq/Observable/SwitchTest.cs
[rxnet-throttletest]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/tests/Tests.System.Reactive/Tests/Linq/Observable/ThrottleTest.cs
[rxnet-intro]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/IntroToRx/16_TestingRx.md
[sw-validation]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncSequenceValidation/AsyncSequenceValidation.docc/Validation.md
[sw-test]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncSequenceValidation/Test.swift
[sw-expectation]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncSequenceValidation/Expectation.swift
[sw-input]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncSequenceValidation/Input.swift
[sw-xctest]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Sources/AsyncAlgorithms_XCTest/ValidationTest.swift
[sw-debounce-test]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Tests/AsyncAlgorithmsTests/TestDebounce.swift
[sw-validation-tests]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Tests/AsyncAlgorithmsTests/TestValidationTests.swift
[sw-fml-test]: https://github.com/apple/swift-async-algorithms/blob/088f92a30c103ddc470d771f770249271066a123/Tests/AsyncAlgorithmsTests/TestFlatMapLatest.swift
[kt-readme]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-test/README.md
[kt-scheduler]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-test/common/src/TestCoroutineScheduler.kt
[kt-dispatchers]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-test/common/src/TestCoroutineDispatchers.kt
[kt-changes]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/CHANGES.md
[kt-testbase]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/test-utils/common/src/TestBase.common.kt
[kt-fml-test]: https://github.com/Kotlin/kotlinx.coroutines/blob/7f4d6cf2414937b50291df6169a69afbaf9c5a20/kotlinx-coroutines-core/common/test/flow/operators/FlatMapLatestTest.kt
[tb-readme]: https://github.com/cashapp/turbine/blob/4590489b93f29ec7ab9dd70bbbadc3baefd58c32/README.md
[tb-changelog]: https://github.com/cashapp/turbine/blob/4590489b93f29ec7ab9dd70bbbadc3baefd58c32/CHANGELOG.md
[tb-receive]: https://github.com/cashapp/turbine/blob/4590489b93f29ec7ab9dd70bbbadc3baefd58c32/src/commonMain/kotlin/app/cash/turbine/ReceiveTurbine.kt
[tb-turbine]: https://github.com/cashapp/turbine/blob/4590489b93f29ec7ab9dd70bbbadc3baefd58c32/src/commonMain/kotlin/app/cash/turbine/Turbine.kt
[tb-channel]: https://github.com/cashapp/turbine/blob/4590489b93f29ec7ab9dd70bbbadc3baefd58c32/src/commonMain/kotlin/app/cash/turbine/channel.kt
[pk-docs]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/stream/stream-testkit.md
[pk-docspec]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/test/scala/docs/stream/StreamTestKitDocSpec.scala
[pk-stk]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream-testkit/src/main/scala/org/apache/pekko/stream/testkit/StreamTestKit.scala
[pk-testsource]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream-testkit/src/main/scala/org/apache/pekko/stream/testkit/scaladsl/TestSource.scala
[pk-testkit]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/testkit/src/main/scala/org/apache/pekko/testkit/TestKit.scala
[pk-manualtime]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/actor-testkit-typed/src/main/scala/org/apache/pekko/actor/testkit/typed/scaladsl/ManualTime.scala
[pk-switch]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream-tests/src/test/scala/org/apache/pekko/stream/scaladsl/FlowSwitchSpec.scala
[pk-flatten]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream-tests/src/test/scala/org/apache/pekko/stream/scaladsl/FlowFlattenMergeSpec.scala
[ef-testclock]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/src/testing/TestClock.ts
[ef-testclock-test]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/effect/test/TestClock.test.ts
[ef-vitest]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/packages/vitest/README.md
[ef-mig-clock]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/migration/annotations/effect__TestClock.yaml
[ef-mig-services]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/migration/annotations/effect__TestServices.yaml
[ce-docs]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/docs/core/test-runtime.md
[ce-testcontrol]: https://github.com/typelevel/cats-effect/blob/de84c01f76b2f42fcee9d43aba66c82992add103/testkit/shared/src/main/scala/cats/effect/testkit/TestControl.scala
[fs2-combinators]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/test/scala/fs2/StreamCombinatorsSuite.scala
[fs2-switchmap]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/test/scala/fs2/StreamSwitchMapSuite.scala
[fs2-suite]: https://github.com/typelevel/fs2/blob/f679d5b45054c133406ba1f5b08b403efd705aff/core/shared/src/test/scala/fs2/Fs2Suite.scala
[rxjs]: ./rxjs.md
[rx-dotnet]: ./rx-dotnet.md
[swift-async]: ./swift-async-algorithms.md
[kotlin-flow]: ./kotlin-flow.md
[pekko]: ./pekko-streams.md
[effect-ts]: ./effect-ts.md
[fs2]: ./fs2.md
[index]: ./index.md
[comparison]: ./comparison.md
