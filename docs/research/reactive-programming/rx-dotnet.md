# Rx.NET, Ix.NET and AsyncRx.NET (C# / .NET)

The original ReactiveX: push-based `IObservable<T>` queries written with LINQ operator names as extension methods, with pluggable `IScheduler`s and virtual time. Its siblings in the same repository cover the pull side: Ix.NET (`System.Interactive`, extra operators for `IEnumerable<T>`), `System.Linq.Async` (LINQ for `IAsyncEnumerable<T>`, now superseded by the .NET 10 runtime) and the unreleased AsyncRx.NET (`IAsyncObservable<T>`).

| Field             | Value                                                                                                                                                                                                                                                          |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C# (.NET Standard 2.0, .NET 8/9/10; UWP and .NET Framework targets kept for binary compatibility)                                                                                                                                                              |
| License           | MIT ([`LICENSE`][license])                                                                                                                                                                                                                                     |
| Repository        | [dotnet/reactive][repo] (`Rx.NET/`, `Ix.NET/`, `AsyncRx.NET/`), surveyed at `d257d1b58fe3`, 2026-11-10                                                                                                                                                         |
| Documentation     | The book _Introduction to Rx.NET_, now in the repository at [`Rx.NET/Documentation/IntroToRx/`][intro-why]; ADRs in [`Rx.NET/Documentation/adr/`][adr-split], [`Ix.NET/Documentation/adr/`][adr-ix-async], [`AsyncRx.NET/Documentation/adr/`][adr-asyncrx-pkg] |
| Category          | Push-based reactive streams (Rx); pull-based sequence operators (Ix, `System.Linq.Async`); async push (AsyncRx)                                                                                                                                                |
| Versions surveyed | `System.Reactive` **7.0.0** ([`Rx.v7.md`][rx-v7]; tree reads `7.1.0-preview`), Ix.NET / `System.Linq.Async` **7.0.1** ([`Ix.v7.md`][ix-v7]), AsyncRx.NET `6.0.0-alpha` (never released, per [`Rx-Roadmap-2023.md`][roadmap])                                   |
| Core abstraction  | `IObservable<T>` / `IObserver<T>` (in the BCL since .NET 4), the dual of `IEnumerable<T>` / `IEnumerator<T>`; a subscription is an `IDisposable`                                                                                                               |

> [!NOTE]
> Everything below is **Rx.NET 7** unless marked _Ix_, _`System.Linq.Async`_ or _AsyncRx_. Operator counts are this survey's
> own `grep` over the `public static` declarations in `Rx.NET/Source/src/System.Reactive/Linq/Observable.*.cs`; they are
> approximate. Erik Meijer's papers are cited by URL but **could not be fetched** for this survey (ACM returned HTTP 403);
> claims attributed to them are paraphrase, not quotation.

---

## Overview

### What it solves

Rx models a sequence of events as a first-class value that LINQ operators can filter, project, merge and time-shift. The book states the idea in one sentence: _"`IObservable<T>` and `IObserver<T>` were designed to preserve the exact meaning of `IEnumerable<T>` and `IEnumerator<T>`, changing only the detailed mechanism of consumption"_ ([`02_KeyTypes.md`][intro-keytypes]). That is the duality from Meijer's work ([_Your Mouse is a Database_][meijer-mouse], ACM Queue, 2012; _Subject/Observer is Dual to Iterator_ [(unverified)][meijer-dual]): invert the arrows of `IEnumerable`'s `GetEnumerator` and `MoveNext`/`Current`/`throw` and you get `Subscribe` and `OnNext`/`OnCompleted`/`OnError`. The pull side therefore needs no new theory, just different plumbing. Ix.NET kept the pull side and added the same extra operators (`Buffer`, `Scan`, `Share`, `Memoize`, `Catch`, `Retry`) to `IEnumerable<T>`. Starting in 2010, Ix also incubated an `IAsyncEnumerable<T>` that .NET Core 3.0 later adopted ([`0002-System-Linq-Async-In-Net10.md`][adr-ix-async]).

### Design philosophy

The book is explicit that push and pull are separate tools, not one tool used two ways:

> _"Rx's `IObservable<T>` is not a replacement for `IEnumerable<T>` or `IAsyncEnumerable<T>`. It would be a mistake to take something that is naturally pull based and force it to be push based."_ ([`01_WhyRx.md`][intro-why])

It also says that `IAsyncEnumerable<T>` took over part of Rx's original role: _"the choice to use Rx to now tends to boil down to whether a 'pull' model (exemplified by `foreach` or `await foreach`) or a 'push' model … is a better fit for the concepts being modelled"_ ([`01_WhyRx.md`][intro-why]). The other design commitments are LINQ itself (operators get the names that C# query syntax binds to), concurrency as a parameter ("the application should define the concurrency model", [`C_UsageGuidelines.md`][intro-guidelines]), and a very strong backwards-compatibility stance. That stance runs through every recent ADR.

---

## How it works

Rx.NET's public operator surface is **one `static partial class Observable`** in `System.Reactive.Linq`, split across category files (`Observable.Time.cs`, `Observable.Multiple.cs`, `Observable.StandardSequenceOperators.cs`, …). Each method is a thin argument-checking facade that forwards to a private `IQueryLanguage` instance ([`Observable_.cs`][observable-underscore]):

```csharp
// Rx.NET/Source/src/System.Reactive/Linq/Observable_.cs
#pragma warning disable IDE1006 // Naming Styles: 3rd party code is known to reflect for this specific field name
private static IQueryLanguage s_impl = QueryServices.GetQueryImpl<IQueryLanguage>(new QueryLanguage());
```

`QueryServices` asks the "platform enlightenment" provider for an override, or else returns the default ([`QueryServices.cs`][queryservices]). `QueryLanguage.*.cs` then constructs an internal operator object. For example, `Throttle` without a scheduler becomes `Throttle_(source, dueTime, SchedulerDefaults.TimeBasedOperations)` ([`QueryLanguage.Time.cs`][ql-time]). Each operator is a `Producer<TSource, TSink>` subclass in `System.Reactive.Linq.ObservableImpl` with a nested `_ : Sink` that is the per-subscription state machine ([`Producer.cs`][producer], [`Sink.cs`][sink]). `Subscribe` creates the sink, the sink subscribes upstream, and the chain of sinks is the running query. This is the same subscribe-time chain RxJS builds ([rxjs.md][rxjs]).

Every `Observable` operator is mirrored by `Qbservable` over `IQbservable<T>`, which takes `Expression<Func<…>>` lambdas so that a provider can inspect or remote the query, as `IQueryable<T>` does ([`0008-trimming-vs-qbservable.md`][adr-qbservable]). The pull-side packages repeat the facade-class shape: `EnumerableEx` (Ix, [`Share.cs`][ix-share]), `AsyncEnumerable` / `AsyncEnumerableEx` (`System.Linq.Async` / `System.Interactive.Async`), and `AsyncObservable` + `AsyncObserver` (AsyncRx, [`Throttle.cs` (AsyncRx)][asyncrx-throttle]).

---

## Evaluation model

- **Push, synchronous.** `OnNext` is a direct virtual call down the sink chain on whatever thread the producer is running on. No queue sits between operators unless one is added with `ObserveOn`.
- **Lazy and cold by default.** `Observable.Create`, `Timer` and `FromAsync` do nothing until `Subscribe`, and run once per subscriber. Hot sources are `Subject<T>` variants, `FromEventPattern`, and `Publish`ed connectables.
- **Serialized, not batched.** The grammar is `OnNext* (OnError | OnCompleted)?`, and calls must not overlap. The book points out that this is the only back pressure Rx has: _"This rule is the only form of back pressure built into Rx.NET: since the rules forbid calling `OnNext` if a previous call to `OnNext` is still in progress, this enables an `IObserver<T>` to limit the rate at which items arrive"_. It adds that once `ObserveOn` introduces a queue, this back pressure _"only propagates as far as the code pulling items off the queue"_ ([`02_KeyTypes.md`][intro-keytypes]).
- **Not glitch-free.** `CombineLatest` over a diamond emits once per upstream notification, so it shows intermediate states. Rx has no topological propagation (contrast [sodium.md][sodium], [solid-signals.md][solid]).
- **The pull side** (`IEnumerable<T>`, `IAsyncEnumerable<T>`) is consumer-driven. `await foreach` calls `MoveNextAsync()`, cancellation enters through `GetAsyncEnumerator(CancellationToken)`, `WithCancellation` sets that token, and `[EnumeratorCancellation]` marks the iterator parameter that receives it ([`EnumeratorCancellationAttribute`][ms-enumcancel], [`TaskAsyncEnumerableExtensions`][ms-taskasyncext]). `ConfigureAwait(false)` on the enumerable controls where continuations resume. That is the .NET analogue of choosing a dispatcher, and it is per loop rather than per operator.

The D design (a pull stream stepped on a fiber) sits on the `IAsyncEnumerable<T>` side of this duality. Rx's push semantics show what that choice gives up: hot multicast without explicit fan-out nodes, and synchronous delivery.

---

## Composition

`Observable` exposes about **711 public overloads under about 139 names** (this survey's count across 18 partial files). The largest overload families are `ToAsync` (68), `FromAsyncPattern` (30), `Min`/`Max` (24 each), `FromEventPattern` (22), `Zip` (19), `SelectMany` (19), `CombineLatest` (18) and `Replay` (16). The core is LINQ (`Select`, `Where`, `SelectMany`, `GroupBy`, `Aggregate`). Rx adds `Scan`, `Buffer`/`Window`, `Merge`/`Concat`/`Switch`/`Amb`, `CombineLatest`/`Zip`/`WithLatestFrom`, `TakeUntil`/`SkipUntil` ([`Observable.Multiple.cs`][obs-multiple]), plus the time family (`Throttle`, `Sample`, `Delay`, `Timeout`, `Timer`, `Interval`). Derived values are built by composing operators, or by query syntax: two `from` clauses compile to `SelectMany` ([`06_Transformation.md`][intro-transform]).

### API structure and naming

**Sources, transforms and sinks all live on one static class and are told apart by signature.** A _source_ is a plain static method (`Observable.Return`, `Observable.Create`, `Observable.Timer`, `Observable.FromAsync`). A _transform_ is an extension method whose first parameter is `this IObservable<TSource>`. A _sink_ is one of the `Subscribe` extension overloads, `ForEachAsync`, `ToTask`, the awaiter in `Observable.Awaiter.cs` (so that `await xs` yields the last value), or a blocking operator from `Observable.Blocking.cs` (`First`, `Last`, `Single`, `Wait`, `ForEach`, `Latest`, `MostRecent`, `Next`). The `Qbservable` paper makes the same split: _"Factory-like operators … such as `Range` are implemented as extension methods for `IQbservableProvider`. Combinator-like operators … such as `Where` are implemented as extension methods for `IQbservable<T>`"_ ([`0008-trimming-vs-qbservable.md`][adr-qbservable]).

**Extension methods are the operator mechanism**, and they are the closest C# analogue of D's UFCS. `xs.Where(p).Select(f)` resolves to static calls in whichever namespace is imported, so a third party can add operators without touching `IObservable<T>`. Two costs show up in the repository:

- **Ambiguity is fatal.** When `System.Linq.Async` and the .NET 10 `System.Linq.AsyncEnumerable` both define `Select` on `IAsyncEnumerable<T>`, the result is _"ambiguity errors any place you try to use LINQ for `IAsyncEnumerable<T>`"_ ([`Ix.v7.md`][ix-v7]). Even static, non-extension methods collide, because the class name is ambiguous: _"If `System.Linq.Async` were to continue to define a public `AsyncEnumerable` type, then calls to `AsyncEnumerable.Range` would fail to compile"_. The fix was to rename the old class `AsyncEnumerableDeprecated` in the reference assemblies and ship it twice at runtime ([`0002-System-Linq-Async-In-Net10.md`][adr-ix-async]). The same mechanism rules out a "clean break" Rx: quoting David Karnok, _"if old Rx and new Rx needed to be interoperated, whose Select() will be applied on that IObservable?"_ ([`0005-package-split.md`][adr-split]).
- **One class name per family.** Everything is called `Observable.X`. Operators outside the standard set went to `ObservableEx` (marked `[Experimental]`), `EnumerableEx` and `AsyncEnumerableEx`. The `Ex` suffix now violates the analyzer's naming rule and is frozen: _"(Don't use Ex suffix.) This has been a public type for many years, so we can't rename it now."_ ([`ObservableEx.cs`][observableex]).

**Names are LINQ names, not functional-programming names.** `Select`/`Where`/`SelectMany`/`Aggregate` are what C# query expressions bind to by pattern, so Rx had to use them for `from x in xs where … select …` to work. A separate package supplies the names other ecosystems use: _"Rx uses the standard LINQ names for its operators. This package enables applications that wish to to use certain names common in other programming systems"_. It defines exactly three aliases, `Map` = `Select`, `FlatMap` = `SelectMany` and `Filter` = `Where`, in namespace `System.Reactive.Observable.Aliases` ([`NuGet.Readme.md`][aliases-readme], [`Observable.Aliases.cs`][aliases]).

**Variants are mostly overloads, not names.** This is the opposite of RxJS's `switchMap`/`concatMap`/`exhaustMap` naming.

| Axis                 | Mechanism                                                                                                               | Example                                                                                                                |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Scheduler            | trailing `IScheduler` parameter; the parameterless overload uses `SchedulerDefaults`                                    | `Throttle(TimeSpan)` / `Throttle(TimeSpan, IScheduler)` ([`Observable.Time.cs`][obs-time])                             |
| Relative vs absolute | `TimeSpan` vs `DateTimeOffset` overload                                                                                 | `Timer`, `Delay`, `Timeout`, `Generate`                                                                                |
| Static vs dynamic    | `TimeSpan` vs `Func<TSource, IObservable<TOther>>` duration selector                                                    | `Throttle<TSource, TThrottle>(…, throttleDurationSelector)`, `Delay`, `Timeout`, `Sample(IObservable<TSample>)`        |
| Inner kind           | overloads on `IObservable`, `Task`, `IEnumerable` and `Func<…, CancellationToken, Task>`                                | 19 `SelectMany` overloads ([`Observable.StandardSequenceOperators.cs`][obs-std]); `Switch(IObservable<Task<TSource>>)` |
| Index                | selector gains an `int` parameter                                                                                       | `Select(Func<TSource, int, TResult>)`                                                                                  |
| Merge strategy       | **separate operators**, not a family: `SelectMany` (merge), `Select(…).Switch()` (latest), `Select(…).Concat()` (queue) | there is no `SelectLatest` / `SwitchMap` in Rx.NET                                                                     |
| Shape suffixes       | `…Async` = returns a single-value `IObservable`/`Task` (non-blocking); `…OrDefault`; `…Until`                           | `FirstAsync` vs blocking `First`; `GroupByUntil`; `TakeUntil(CancellationToken)` (6.1)                                 |

**A user-defined operator** is just another extension method that composes operators or wraps `Observable.Create`. The guidelines say to _"Avoid creating your own implementations of the `IObservable<T>` interface. Use `Observable.Create`"_ ([`C_UsageGuidelines.md`][intro-guidelines]). The built-in `Producer`/`Sink` base classes are `internal`, so users cannot write operators the way the library does.

```csharp
public static IObservable<T> DebounceDynamic<T>(
    this IObservable<T> source, Func<TimeSpan> due, IScheduler scheduler) =>
    source.Throttle(_ => Observable.Timer(due(), scheduler)); // per-element duration
```

**AsyncRx splits every operator in two.** `AsyncObservable.Throttle(this IAsyncObservable<T>, …)` is the source-side wrapper. `AsyncObserver.Throttle(IAsyncObserver<T> observer, TimeSpan)` returns `(IAsyncObserver<TSource>, IAsyncDisposable)`, an observer transformer that carries the logic ([`Throttle.cs` (AsyncRx)][asyncrx-throttle]). Writing the operator logic once as a sink-to-sink function, with subscription plumbing as a generic wrapper, separates transform from wiring more cleanly than Rx.NET's `Producer`/`Sink` pair.

**What the project renamed, regretted or obsoleted:**

- **`Throttle`.** It is a debounce, and RxJS's `throttle` is a rate limiter (see [Time and scheduling](#time-and-scheduling)). The package-split ADR's hypothetical shows how widely this is felt: _"Imagine for the sake of argument that Rx 7 adds a `RateLimit` operator to deal with the fact that almost nobody likes `Throttle`"_ ([`0005-package-split.md`][adr-split]).
- **The `Await` / `AwaitWithCancellation` suffix family** in `System.Linq.Async` (`SelectAwait`, `WhereAwait`, `SelectAwaitWithCancellation`). The .NET 10 replacement collapsed these into overloads: _"`System.Linq.AsyncEnumerable` requires all `async` callbacks to accept a cancellation token (which they are free to ignore of course) and does not use different names for these forms"_ ([`0002-System-Linq-Async-In-Net10.md`][adr-ix-async]). The old methods now carry `[Obsolete("Use Select. … the SelectAwait functionality now exists as overloads of Select. You will need to modify your callback to take an additional CancellationToken argument.")]` ([`Select.cs` (`System.Linq.Async`)][linqasync-select]). The same ADR drops the `IComparer`-less twin overloads in favour of optional parameters, gives projection variants distinct names (`MaxByAsync`), and calls `ToEnumerable` (sync over async) _"a bad idea and that should probably have never existed"_.
- **`MinBy`/`MaxBy` → `MinByWithTies`/`MaxByWithTies`** after .NET 6 shipped BCL operators with the same names but different semantics. The rename was made in Ix but missed in `System.Interactive.Async`, so the clash came back in .NET 10 ([`0002-System-Linq-Async-In-Net10.md`][adr-ix-async]).
- **`FromAsyncPattern`** (the APM `Begin`/`End` bridge) is `[Obsolete(Constants_Linq.UseTaskFromAsyncPattern)]` across all its overloads ([`Observable.Async.cs`][obs-async]).
- **Packaging, repeatedly.** The project went from four packages (`Rx-Core`, `Rx-Interfaces`, `Rx-Linq`, `Rx-PlatformServices`, whose names did not match their assemblies) to the 4.0 "great unification" into one `System.Reactive`, and then split UI frameworks out again in 7.0. The ADR's verdict on the unification is _"This simplification was ingenious, and it worked brilliantly. Until it didn't."_, and on the separate interfaces package, _"the rationale behind the packaging decision was apparently forgotten"_ ([`0005-package-split.md`][adr-split]). AsyncRx learned from this: it merged seven never-published packages into one `System.Reactive.Async`, keeping no separate interfaces package because the interfaces are not _"fully baked"_ ([`0001-package-unification.md`][adr-asyncrx-pkg]).

---

## Time and scheduling

`IScheduler` is three methods plus a clock ([`IScheduler.cs`][ischeduler]):

```csharp
DateTimeOffset Now { get; }
IDisposable Schedule<TState>(TState state, Func<IScheduler, TState, IDisposable> action);
IDisposable Schedule<TState>(TState state, TimeSpan dueTime, Func<IScheduler, TState, IDisposable> action);
IDisposable Schedule<TState>(TState state, DateTimeOffset dueTime, Func<IScheduler, TState, IDisposable> action);
```

The `TState` argument exists so that operators can pass a static, non-capturing lambda and allocate nothing per scheduled item. AsyncRx dropped it in 2017 and restored it in an ADR that explains the reasoning: _"the interface is public API and sets the ceiling on what any implementation can achieve, so it is precisely the place to get right first"_ ([`0002-scheduler-state-argument.md`][adr-asyncrx-state]). Default schedulers are chosen per operator category ([`SchedulerDefaults.cs`][schedulerdefaults]): `ConstantTimeOperations` and `TailRecursion` use `ImmediateScheduler`, `Iteration` uses `CurrentThreadScheduler`, and `TimeBasedOperations` and `AsyncConversions` use `DefaultScheduler` (the thread pool). The virtual-time schedulers derive from `VirtualTimeSchedulerBase<TAbsolute, TRelative>` (`Start`, `Stop`, `AdvanceTo`, `AdvanceBy`, `Sleep`; [`VirtualTimeScheduler.cs`][vts]). `HistoricalScheduler` uses `DateTimeOffset`/`TimeSpan`, for replaying recorded data ([`HistoricalScheduler.cs`][historical]). `TestScheduler` uses `long` ticks ([`TestScheduler.cs`][testscheduler]).

**Debounce is `Throttle`.** Its doc comment: _"Ignores elements from an observable sequence which are followed by another element within a specified relative time duration"_. It also warns that _"For streams that never have gaps larger than or equal to `dueTime` between elements, the resulting stream won't produce any elements"_ ([`Observable.Time.cs`][obs-time]). The implementation ([`Throttle.cs`][throttle]) works as follows:

- `OnNext` stores the value, increments a `ulong _id` under `_gate`, disposes the previous timer through a `SerialDisposableValue`, and schedules `Propagate(currentid)` after `_dueTime`.
- `Propagate` forwards only if `_hasValue && _id == currentid`. The id check catches a timer whose disposal lost the race with its firing.
- `OnCompleted` **flushes** the pending value before completing. `Dispose` only cancels the timer and does not flush.

The book flags the naming clash with RxJS: _"In RxJS, throttle doesn't shut off completely when the source exceeds the specified rate: it just drops enough items that the output never exceeds the specified rate. So RxJS's throttle implementation is a kind of rate limiter, whereas Rx.NET's `Throttle` is more like a self-resetting circuit breaker that shuts off completely during an overload."_ ([`12_Timing.md`][intro-timing]). Rx.NET has **no rate-limiting throttle operator**. The nearest are `Sample(TimeSpan)` and `Sample(IObservable<TSample>)`.

**Changing the duration at runtime.** `_dueTime` is `readonly` and fixed when the operator is constructed. The duration-selector overload, `Throttle(Func<TSource, IObservable<TThrottle>>)`, subscribes a fresh "throttle observable" per element and forwards the element on that observable's first `OnNext` or its `OnCompleted`. So `xs.Throttle(_ => Observable.Timer(current(), s))` reads the current interval on every element. A change takes effect from the next element. To re-arm immediately when the interval changes, combine it into the source (see [The worked pipeline](#the-worked-pipeline)).

AsyncRx's `Throttle` is the same algorithm over `AsyncGate`, `SerialAsyncDisposable` and `IAsyncScheduler.ScheduleAsync`, whose action receives a `CancellationToken` ([`Throttle.cs` (AsyncRx)][asyncrx-throttle], [`IAsyncScheduler.cs`][iasyncscheduler]).

---

## Concurrency and cancellation

**Latest-wins is `Select(f).Switch()`.** _"Each time its source produces a new nested `IObservable<T>`, `Switch` unsubscribes from the previous nested source … and subscribes to the latest one"_ ([`09_CombiningSequences.md`][intro-combining]). In [`Switch.cs`][switch], `OnNext` increments `_latest`, creates an `InnerObserver(this, id)`, and assigns it to `_innerSerialDisposable.Disposable`. That assignment **synchronously disposes the previous inner subscription** before the new one subscribes. Inner `OnNext`s are forwarded only while `_parent._latest == _id`. There is also `Switch(IObservable<Task<TSource>>)`, but a `Task` cannot be cancelled by unsubscribing from it.

**How cancellation reaches running work.** Only through a `CancellationToken` tied to the subscription. `Observable.FromAsync(Func<CancellationToken, Task<TResult>>)` documents: _"When a subscription to the resulting sequence is disposed, the CancellationToken that was fed to the asynchronous function will be signaled"_ ([`Observable.Async.cs`][obs-async]). `Observable.Create(Func<IObserver<TResult>, CancellationToken, Task>)` promises _"best-effort cancellation"_ ([`Observable.Creation.cs`][obs-creation]). `SelectMany` has `Func<TSource, CancellationToken, Task<TResult>>` overloads, but `SelectMany` merges and is not latest-wins.

**A cancel does not wait.** The subscription behind the token-taking `Create` overload ([`QueryLanguage.Creation.cs`][ql-creation]) shows this:

```csharp
public void Dispose()
{
    _cts.Cancel();
    _subscription.Dispose();
}
```

`Dispose` returns as soon as the token is signalled. The `Task` keeps running until it observes the token, and its late result or `OperationCanceledException` goes nowhere. So under `Switch`, a new hash starts **while the old one is still unwinding**. Two CPU-bound hashes can overlap, and nothing tells the caller when the cancelled one has released its resources. Rx.NET has no cancel-and-join.

AsyncRx is closer to join semantics. `SerialAsyncDisposable.AssignAsync` does `await old.DisposeAsync()`, and AsyncRx's `Switch` awaits that before it subscribes the next inner ([`SerialAsyncDisposable.cs`][asyncrx-serial], [`Switch.cs` (AsyncRx)][asyncrx-switch]). Whether that also waits for the inner's running work depends on that inner source's `DisposeAsync` (not verified for task-backed sources). AsyncRx's own ADR lists the cancellation story as unsettled, citing dotnet/reactive#1296 ([`0001-package-unification.md`][adr-asyncrx-pkg]).

**CPU-bound work** goes on `Task.Run`, `SubscribeOn` or `ObserveOn` with a pool scheduler. The book steers heavy parallel compute to TPL Dataflow or PLINQ ([`01_WhyRx.md`][intro-why]).

---

## Errors and completion

`OnError` and `OnCompleted` are terminal, mirroring a throwing or ending `foreach` ([`02_KeyTypes.md`][intro-keytypes]). Exceptions are passed as values, not thrown. ADR 0004 records the consequence: _"Rx does not generally use exceptions in the way the runtime expects. In particular it does not normally use the MSIL `throw` instruction to raise an exception."_ When `await` turns `OnError` back into a throw, reusing one exception instance makes its `StackTrace` grow on every rethrow (dotnet/reactive#2187; [`0004-onerror-to-throw.md`][adr-onerror]). Rx 6.1 added a `ResetExceptionDispatchState` operator as a workaround ([`Rx.v6.md`][rx-v6]). Recovery operators are `Catch` (by exception type), `Retry`, `OnErrorResumeNext` and `Finally`. A subscriber with no `OnError` handler rethrows on the producer's thread, so the guideline is _"Always provide an `OnError` handler"_ ([`C_UsageGuidelines.md`][intro-guidelines]). Completion propagates through `Switch` only after the outer source has completed **and** the latest inner has completed ([`Switch.cs`][switch]).

---

## State and sharing

- **Value cell:** `BehaviorSubject<T>` has a constructor initial value, a `Value` property, `TryGetValue`, and replays the current value on `Subscribe` ([`BehaviorSubject.cs`][behaviorsubject]). It does not suppress repeats, so de-duplication needs `DistinctUntilChanged`.
- **Multicast:** `Publish()` returns an `IConnectableObservable<T>` that runs the source only on `Connect`. `Publish(initialValue)` uses a `BehaviorSubject` ([`15_PublishingOperators.md`][intro-publish]). `RefCount` connects on the first subscriber and disposes at zero. In Rx 6 it gained `minObservers` and `disconnectDelay` overloads ([`Observable.Binding.cs`][obs-binding]), and three bugs in their interaction were fixed in 6.0.2 (dotnet/reactive#2173, #2214, #2215; [`Rx.v6.md`][rx-v6]). `Replay` has 16 overloads.
- **Pull-side sharing (Ix):** `EnumerableEx.Share` lets several enumerators pull from one source, with each element going to whoever pulls it first (_"e2 'steals' element 2"_). `Memoize` and `Publish` buffer the source for later consumers ([`Share.cs`][ix-share]). Sharing a pull source therefore needs an explicit choice of steal, buffer or replay.
- **Conflation:** Rx has no conflate operator. `Sample` comes closest. The push-to-pull bridge `ToAsyncEnumerable(this IObservable<T>)` buffers into an **unbounded** `ConcurrentQueue<TSource>` ([`ToAsyncEnumerable.Observable.cs`][ix-toasyncenum]), so a slow `await foreach` grows memory instead of seeing only the latest value.

---

## Lifetime and ownership

A subscription is an `IDisposable` with no parent. Ownership is by convention, built from `CompositeDisposable`, `SerialDisposable`, `SingleAssignmentDisposable` and, since 6.1, `DisposeWith` and `TakeUntil(CancellationToken)` ([`Rx.v6.md`][rx-v6]). Teardown runs upstream through the sink chain. Nothing scopes a subscription to a component, so a subscription that is never disposed leaks the producer and every closure captured downstream, which is the classic event-handler leak. The guideline _"Dispose of subscriptions only if you need to unsubscribe from them early"_ ([`C_UsageGuidelines.md`][intro-guidelines]) is safe only for sequences that complete. AsyncRx makes subscribe and dispose asynchronous (`ValueTask<IAsyncDisposable> SubscribeAsync`, [`IAsyncObservable.cs`][iasyncobservable]; `OnNextAsync`/`OnErrorAsync`/`OnCompletedAsync`, [`IAsyncObserver.cs`][iasyncobserver]). That is where an awaitable "teardown finished" first appears in the family.

---

## Testing

`Microsoft.Reactive.Testing` provides `TestScheduler`, a `VirtualTimeScheduler<long, long>` in ticks, with `CreateHotObservable`, `CreateColdObservable`, `CreateObserver` and `Start(create, created, subscribed, disposed)`. The defaults are `Created = 100`, `Subscribed = 200` and `Disposed = 1000` ([`TestScheduler.cs`][testscheduler], [`ReactiveTest.cs`][reactivetest]). Rx's own debounce test is fully deterministic ([`ThrottleTest.cs`][throttletest]):

```csharp
var xs = scheduler.CreateHotObservable(
    OnNext(150, 0), OnNext(210, 1), OnNext(240, 2), OnNext(270, 3), OnNext(300, 4),
    OnCompleted<int>(400));
var res = scheduler.Start(() => xs.Throttle(TimeSpan.FromTicks(20), scheduler));
res.Messages.AssertEqual(
    OnNext(230, 1), OnNext(260, 2), OnNext(290, 3), OnNext(320, 4), OnCompleted<int>(400));
xs.Subscriptions.AssertEqual(Subscribe(200, 400));
```

The catch is that **virtual time is opt-in per call site**. Every time-based operator must be passed the scheduler, or it silently falls back to `DefaultScheduler` and wall-clock time. The book's answer is an `ISchedulerProvider` interface injected into every class that builds queries ([`16_TestingRx.md`][intro-testing]). Contrast an ambient `TestClock` in the loop (Kotlin's `runTest`, [kotlin-flow.md][kotlin-flow]).

---

## The worked pipeline

```csharp
IObservable<HashState> Pipeline(
    IObservable<string> query,              // e.g. Observable.FromEventPattern(...TextChanged)
    BehaviorSubject<TimeSpan> interval,     // the numeric field
    BehaviorSubject<bool> enabled,          // the toggle
    IScheduler time,                        // DefaultScheduler.Instance, or a TestScheduler
    IScheduler ui) =>                       // the UI loop's scheduler
    enabled
        .DistinctUntilChanged()
        .Select(on => !on
            ? Observable.Return<HashState>(HashState.Off)
            : query
                .CombineLatest(interval, (q, n) => (q, n))           // an interval change re-arms the debounce
                .Throttle(p => Observable.Timer(p.n, time))          // debounce with a per-element duration
                .Select(p => p.q)
                .DistinctUntilChanged()                              // an interval change alone does not re-hash
                .Select(q => Observable
                    .FromAsync(ct => Task.Run(() => HashFileset(q, ct), ct), time)
                    .Select(d => (HashState)new HashState.Done(d))
                    .StartWith(HashState.Pending))
                .Switch()                                            // latest-wins over hashes
                .Catch((Exception e) => Observable.Return<HashState>(new HashState.Failed(e))))
        .Switch()                                                    // toggle: latest-wins over the whole pipeline
        .ObserveOn(ui);

// HashFileset must poll ct.ThrowIfCancellationRequested() between files.
using var sub = Pipeline(...).Subscribe(s => { view.State = s; host.WakeIn(0); });
```

Per-event trace (`N = 300 ms`):

1. **Keystroke during the debounce.** The new `(q, N)` pair reaches `Throttle`'s sink. `_id` is incremented, `_serialCancelable.Disposable = null` disposes the pending `Timer` subscription, and a new `Timer(N)` is subscribed. Even if the old timer had already fired on a pool thread, its `ThrottleObserver` sees `_id != _currentid` and forwards nothing.
2. **Keystroke during the hash.** The keystroke only re-arms `Throttle`, so **the running hash continues** until the debounce fires N ms later. Then the inner `Switch` receives a new `FromAsync`. Assigning it to `_innerSerialDisposable` disposes the old one, which runs `CancellationTokenSource.Cancel()` and returns at once. The new `Task.Run` starts immediately, while the old hash is still running on another pool thread until its next `ThrowIfCancellationRequested`. Its result is dropped because the observer is detached. To cancel on the keystroke itself, move the timer inside the switch: `query.Select(q => Observable.Timer(N, time).SelectMany(_ => FromAsync(...))).Switch()`. That form is debounce and latest-wins in one operator.
3. **Interval change.** `interval.OnNext(800ms)` makes `CombineLatest` emit `(q, 800)`. `Throttle` treats it as a new element and re-arms an 800 ms timer. When it fires, `DistinctUntilChanged` drops the unchanged `q`. With the simpler `query.Throttle(_ => Timer(interval.Value))`, the new interval would only apply to the next keystroke.
4. **Toggle off.** `enabled.OnNext(false)` makes the outer `Switch` dispose the whole inner chain. `Throttle.Dispose` cancels the timer, so **a pending debounce is discarded, not flushed** (the flush happens only on `OnCompleted`). The inner `Switch` disposes `FromAsync`, which signals `ct`. `Return(Off)` is then emitted at once, before the cancelled hash has finished. Toggling back on re-subscribes `query`/`interval`, and because `interval` is a `BehaviorSubject` it replays the current value. A plain `Subject` query, though, does not replay the last text, so no hash runs until the next keystroke.

**Fit for a per-frame UI.** Push suits event sources such as keystrokes and the toggle. An immediate-mode frame, however, wants to _read_ a value, so the sink has to write a cell and call `wakeIn`, as above. That `Subscribe` lambda becomes the bridge Rx does not supply. `ObserveOn(ui)` needs an `IScheduler` implemented on the event loop. Missing a scheduler argument anywhere breaks determinism without any error. The parts that map directly onto the D design are `Throttle`'s id-gated timer (latest-wins by generation counter), `Switch` (dispose-then-subscribe), and the `CancellationToken` overloads. What D's scoped design adds is the join after cancel and the ambient clock.

---

## Strengths

- **The duality is executable.** `IEnumerable`, `IAsyncEnumerable`, `IObservable` and `IAsyncObservable` share operator names and semantics, which makes the trade-offs between them easy to compare.
- **An open operator set through extension methods.** Anyone can add operators, and query syntax works on any type that has the right method names.
- **The scheduler abstraction is minimal and allocation-aware** (the `TState` argument). Virtual time comes in three flavours: `TestScheduler`, `HistoricalScheduler`, and a generic `VirtualTimeScheduler<TAbsolute, TRelative>`.
- **The algorithms are mature and readable.** `Throttle` and `Switch` are each about 100 lines, built on a gate, a serial disposable and a generation counter.
- **Unusually honest design records.** The ADRs and the book document mistakes, naming confusion and compatibility constraints at length.

## Weaknesses

- **`Throttle` means debounce**, which conflicts with RxJS and with common usage. The project itself admits _"almost nobody likes `Throttle`"_.
- **Cancellation does not wait.** Latest-wins can run old and new CPU work at the same time, and teardown completion cannot be observed (except partially in the unreleased AsyncRx).
- **Lifetime is unstructured.** Subscriptions are parentless `IDisposable`s, and leaks are a convention problem.
- **Testability depends on threading an `IScheduler` through every call site.** The parameterless overloads silently use the real clock.
- **The surface is huge** (about 711 `Observable` overloads). Overload resolution against lambdas with `Task`, `IObservable` and `IEnumerable` returns is hard to read in error messages.
- **The extension-method namespace is global per type.** Two libraries offering `Select` on the same interface cannot coexist. That collision drove the `System.Linq.Async` v7 contortions.
- **No conflation, and only implicit back pressure.** The push-to-pull bridge buffers without limit.

## Key design decisions and trade-offs

| Decision                                                                                   | Rationale                                                              | Trade-off                                                                                                          |
| ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| LINQ names (`Select`/`Where`/`SelectMany`)                                                 | C# query syntax binds to them; LINQ-to-Objects users already know them | Off-putting to FP users; needed a `Map`/`FlatMap`/`Filter` alias package                                           |
| Operators as extension methods on one static `Observable` class                            | Open extension and fluent chains without changing the interface        | Name collisions across libraries are unfixable without renaming classes (`AsyncEnumerableDeprecated`)              |
| Variants as overloads (scheduler, `TimeSpan`/`DateTimeOffset`, `Task`/`CancellationToken`) | Fewer names to learn                                                   | About 711 overloads; ambiguous lambdas; `System.Linq.Async`'s name-suffix variants had to be reverted to overloads |
| Scheduler as an optional trailing parameter                                                | Concurrency stays visible and replaceable per operator                 | Virtual time is lost silently wherever the argument is forgotten                                                   |
| `Throttle` = debounce, by an id-gated timer                                                | Simple and correct latest-value semantics                              | A naming clash with RxJS that the project now regrets; the duration is fixed unless the selector overload is used  |
| Cancellation = `IDisposable.Dispose` + `CancellationToken`                                 | Synchronous, cheap teardown                                            | No join, so cancelled work overlaps its replacement                                                                |
| Facade → `IQueryLanguage` indirection (`s_impl`)                                           | Platform "enlightenments" can swap implementations                     | Third parties reflect on the private field, which freezes even internals                                           |
| Extreme binary compatibility (ref/lib split, hidden types)                                 | Plug-in hosts and transitive dependencies must keep working            | Very long deprecation horizons (_"likely not before 2030"_) and duplicated runtime code                            |

---

## Sources

- [dotnet/reactive repository][repo] · [`LICENSE`][license]
- _Introduction to Rx.NET_: [`01_WhyRx.md`][intro-why], [`02_KeyTypes.md`][intro-keytypes], [`06_Transformation.md`][intro-transform], [`09_CombiningSequences.md`][intro-combining], [`11_SchedulingAndThreading.md`][intro-sched], [`12_Timing.md`][intro-timing], [`15_PublishingOperators.md`][intro-publish], [`16_TestingRx.md`][intro-testing], [`C_UsageGuidelines.md`][intro-guidelines]
- ADRs: [`0004-onerror-to-throw.md`][adr-onerror], [`0005-package-split.md`][adr-split], [`0008-trimming-vs-qbservable.md`][adr-qbservable], [Ix `0002-System-Linq-Async-In-Net10.md`][adr-ix-async], [AsyncRx `0001-package-unification.md`][adr-asyncrx-pkg], [AsyncRx `0002-scheduler-state-argument.md`][adr-asyncrx-state]
- Release notes: [`Rx.v6.md`][rx-v6], [`Rx.v7.md`][rx-v7], [`Ix.v7.md`][ix-v7], [`Rx-Roadmap-2023.md`][roadmap]
- Rx.NET source: [`Observable_.cs`][observable-underscore], [`QueryServices.cs`][queryservices], [`Observable.Time.cs`][obs-time], [`QueryLanguage.Time.cs`][ql-time], [`Throttle.cs`][throttle], [`Switch.cs`][switch], [`Observable.Creation.cs`][obs-creation], [`QueryLanguage.Creation.cs`][ql-creation], [`Observable.Async.cs`][obs-async], [`Observable.Binding.cs`][obs-binding], [`Observable.Multiple.cs`][obs-multiple], [`Observable.StandardSequenceOperators.cs`][obs-std], [`ObservableEx.cs`][observableex], [`Producer.cs`][producer], [`Sink.cs`][sink], [`IScheduler.cs`][ischeduler], [`SchedulerDefaults.cs`][schedulerdefaults], [`VirtualTimeScheduler.cs`][vts], [`HistoricalScheduler.cs`][historical], [`BehaviorSubject.cs`][behaviorsubject], [`Observable.Aliases.cs`][aliases], [`NuGet.Readme.md` (aliases)][aliases-readme]
- Testing: [`TestScheduler.cs`][testscheduler], [`ReactiveTest.cs`][reactivetest], [`ThrottleTest.cs`][throttletest]
- Ix / `System.Linq.Async`: [`Share.cs`][ix-share], [`ToAsyncEnumerable.Observable.cs`][ix-toasyncenum], [`Select.cs`][linqasync-select]
- AsyncRx.NET: [`IAsyncObservable.cs`][iasyncobservable], [`IAsyncObserver.cs`][iasyncobserver], [`IAsyncScheduler.cs`][iasyncscheduler], [`Throttle.cs` (AsyncRx)][asyncrx-throttle], [`Switch.cs` (AsyncRx)][asyncrx-switch], [`SerialAsyncDisposable.cs`][asyncrx-serial]
- .NET docs: [`EnumeratorCancellationAttribute`][ms-enumcancel], [`TaskAsyncEnumerableExtensions`][ms-taskasyncext]
- Erik Meijer, [_Your Mouse is a Database_][meijer-mouse] (ACM Queue, 2012) and [_Subject/Observer is Dual to Iterator_][meijer-dual] (FIT 2010); neither could be fetched for this survey
- Siblings: [RxJS][rxjs] · [Kotlin Flow][kotlin-flow] · [Swift Async Algorithms][swift-async] · [Rust streams][rust-streams] · [Effect-TS][effect-ts] · [Sodium][sodium] · [Solid signals][solid] · [Clojure transducers][transducers] · [Pekko Streams][pekko] · [concepts][concepts] · [comparison][comparison] · [async I/O survey][async-io]

<!-- References -->

[repo]: https://github.com/dotnet/reactive
[license]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/LICENSE
[intro-why]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/IntroToRx/01_WhyRx.md
[intro-keytypes]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/IntroToRx/02_KeyTypes.md
[intro-transform]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/IntroToRx/06_Transformation.md
[intro-combining]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/IntroToRx/09_CombiningSequences.md
[intro-sched]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/IntroToRx/11_SchedulingAndThreading.md
[intro-timing]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/IntroToRx/12_Timing.md
[intro-publish]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/IntroToRx/15_PublishingOperators.md
[intro-testing]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/IntroToRx/16_TestingRx.md
[intro-guidelines]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/IntroToRx/C_UsageGuidelines.md
[adr-onerror]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/adr/0004-onerror-to-throw.md
[adr-split]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/adr/0005-package-split.md
[adr-qbservable]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/adr/0008-trimming-vs-qbservable.md
[adr-ix-async]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Ix.NET/Documentation/adr/0002-System-Linq-Async-In-Net10.md
[adr-asyncrx-pkg]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/AsyncRx.NET/Documentation/adr/0001-package-unification.md
[adr-asyncrx-state]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/AsyncRx.NET/Documentation/adr/0002-scheduler-state-argument.md
[rx-v6]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/ReleaseHistory/Rx.v6.md
[rx-v7]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/ReleaseHistory/Rx.v7.md
[ix-v7]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Ix.NET/Documentation/ReleaseHistory/Ix.v7.md
[roadmap]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Documentation/Rx-Roadmap-2023.md
[observable-underscore]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/Observable_.cs
[queryservices]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Internal/QueryServices.cs
[obs-time]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/Observable.Time.cs
[ql-time]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/QueryLanguage.Time.cs
[throttle]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/Observable/Throttle.cs
[switch]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/Observable/Switch.cs
[obs-creation]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/Observable.Creation.cs
[ql-creation]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/QueryLanguage.Creation.cs
[obs-async]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/Observable.Async.cs
[obs-binding]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/Observable.Binding.cs
[obs-multiple]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/Observable.Multiple.cs
[obs-std]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/Observable.StandardSequenceOperators.cs
[observableex]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Linq/ObservableEx.cs
[producer]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Internal/Producer.cs
[sink]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Internal/Sink.cs
[ischeduler]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Concurrency/IScheduler.cs
[schedulerdefaults]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Concurrency/SchedulerDefaults.cs
[vts]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Concurrency/VirtualTimeScheduler.cs
[historical]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Concurrency/HistoricalScheduler.cs
[behaviorsubject]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive/Subjects/BehaviorSubject.cs
[aliases]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive.Observable.Aliases/Observable.Aliases.cs
[aliases-readme]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/System.Reactive.Observable.Aliases/build/NuGet.Readme.md
[testscheduler]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/Microsoft.Reactive.Testing/TestScheduler.cs
[reactivetest]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/src/Microsoft.Reactive.Testing/ReactiveTest.cs
[throttletest]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Rx.NET/Source/tests/Tests.System.Reactive/Tests/Linq/Observable/ThrottleTest.cs
[ix-share]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Ix.NET/Source/System.Interactive/System/Linq/Operators/Share.cs
[ix-toasyncenum]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Ix.NET/Source/System.Interactive.Async/System/Linq/Operators/ToAsyncEnumerable.Observable.cs
[linqasync-select]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/Ix.NET/Source/System.Linq.Async/System/Linq/Operators/Select.cs
[iasyncobservable]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/AsyncRx.NET/System.Reactive.Async/IAsyncObservable.cs
[iasyncobserver]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/AsyncRx.NET/System.Reactive.Async/IAsyncObserver.cs
[iasyncscheduler]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/AsyncRx.NET/System.Reactive.Async/Concurrency/IAsyncScheduler.cs
[asyncrx-throttle]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/AsyncRx.NET/System.Reactive.Async/Linq/Operators/Throttle.cs
[asyncrx-switch]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/AsyncRx.NET/System.Reactive.Async/Linq/Operators/Switch.cs
[asyncrx-serial]: https://github.com/dotnet/reactive/blob/d257d1b58fe3f0ec194ed9f6235fa5a0da180bf0/AsyncRx.NET/System.Reactive.Async/Disposables/SerialAsyncDisposable.cs
[ms-enumcancel]: https://learn.microsoft.com/en-us/dotnet/api/system.runtime.compilerservices.enumeratorcancellationattribute
[ms-taskasyncext]: https://learn.microsoft.com/en-us/dotnet/api/system.threading.tasks.taskasyncenumerableextensions
[meijer-mouse]: https://queue.acm.org/detail.cfm?id=2169076
[meijer-dual]: http://csl.stanford.edu/~christos/pldi2010.fit/meijer.duality.pdf
[rxjs]: ./rxjs.md
[kotlin-flow]: ./kotlin-flow.md
[swift-async]: ./swift-async-algorithms.md
[rust-streams]: ./rust-streams.md
[effect-ts]: ./effect-ts.md
[sodium]: ./sodium.md
[solid]: ./solid-signals.md
[transducers]: ./clojure-transducers.md
[pekko]: ./pekko-streams.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[async-io]: ../async-io/index.md
