# Sodium (Java, C#, cross-language)

A transactional push-based FRP library with a ten-primitive core over two types (`Stream` for discrete events and `Cell` for values that change in steps), in which every input opens a `Transaction` that propagates in rank order, without glitches, against a single consistent snapshot of every cell.

| Field             | Value                                                                                                                                                                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Java (primary here: `nz.sodium`, builds on Java 5+, lambdas from Java 8), C#/F# (`dotnet/`), Scala, Clojure, Haskell (deprecated), embedded C (experiment) in one repository; C++, Kotlin, TypeScript and Rust ports live in separate repositories |
| License           | BSD 3-clause, "Copyright (c) 2012-2015, Stephen Blackheath and Anthony Jones" ([`COPYING`][copying])                                                                                                                                               |
| Repository        | SodiumFRP/sodium ([`README`][readme])                                                                                                                                                                                                              |
| Documentation     | Javadoc in the source; the book _Functional Reactive Programming_, Blackheath & Jones, Manning 2016 ([manning.com][book]); _Denotational Semantics of Sodium 1.1_ ([`Denotational.hs`][denot-hs], PDF beside it)                                   |
| Category          | Discrete, push-based, transactional FRP (first-order `Stream`/`Cell` graph; higher-order via `switchS`/`switchC`)                                                                                                                                  |
| Versions surveyed | `master` at `03d0c0fe446a` (2026-09-28); Java `1.2.1-SNAPSHOT` ([`pom.xml`][pom]); the .NET tree at the same commit                                                                                                                                |
| Core abstraction  | `Stream<A>` (event firings) and `Cell<A>` (a value at every instant), connected only inside a `Transaction`; `StreamSink`/`CellSink` are the only way in, `listen` the only way out                                                                |

> [!NOTE]
> The Java port is the primary subject: it is described as "complete" in the
> [`README`][readme], it ships the `nz.sodium.time` timer system, and its tests are
> generated from the shared Haskell specification in `common-tests/`. The .NET tree
> is cited where it goes further: a `Transaction` contract written out in full,
> and the `Sodium.Frp.Async` `MapAsync` bridge with a `SwitchLatest` strategy. The
> [`README`][readme] says the .NET port is _"not in active development"_ and points
> at a successor, [SodaFlow][sodaflow]; the Async code is nevertheless present at the
> surveyed commit. The separately hosted ports (`sodium-cxx`, `sodium-kotlin`,
> `sodium-typescript`, `sodium-rust`) were **not** examined.

---

## Overview

### What it solves

Sodium is a working implementation of "classic" FRP's two-type model for imperative host
languages. The [`README`][readme] places it in a lineage: _"This is based on Flapjax,
Yampa, scala.React and a number of other Functional Reactive Programming efforts, as well
as a lot of personal experience."_ It is meant for the middle of an application, meaning
the logic between I/O sources (widgets, sockets, timers) and I/O sinks (rendering), and it
draws that boundary itself: [`StreamSink`][streamsink-java] is _"an interface between the
world of I/O and the world of FRP"_, and `Stream.listen` is _"an OPERATIONAL mechanism
… for interfacing between the world of I/O and for FRP"_ ([`Stream.java`][stream-java]).

For this survey its value is that it gives a precise, specified answer to the question
"what does one frame see?". The answer is: one transaction, one snapshot.

### Design philosophy

1. **Two types, ten primitives, and a denotation.** Events (`Stream`) and step-wise values
   (`Cell`) are distinct types. The book's count of ten primitives (`map`, `merge`,
   `hold`, `snapshot`, `filter`, `lift`, `never`, `constant`, `sample`, `switch`) is
   from [the book][book] _(not verified verbatim here)_. The executable denotational
   semantics defines exactly these as GADT constructors: `MapS`, `Snapshot`, `Merge`,
   `Filter`, `SwitchS`, `Never`, `Constant`, `Hold`, `MapC`, `Apply`, `SwitchC`, plus the
   operational `Updates`, `Value`, `Split`, `Execute` ([`Denotational.hs`][denot-hs]).
2. **Transactions are the unit of time.** _"Transactions are serialized process-wide: at
   most one runs at a time, however many threads are involved. … It is what makes a
   transaction atomic with respect to every other thread - no observer can ever see the
   graph half-updated"_ ([`.NET Transaction.cs`][tx-cs]).
3. **Cell steps are not observable.** Anything that exposes the moment a cell changes is
   quarantined in `Operational`: `updates` _"breaks the property of non-detectability of
   cell steps/updates. The rule with this primitive is that you should only use it in
   functions that do not allow the caller to detect the cell updates"_
   ([`Operational.java`][operational-java]).
4. **Functions passed to primitives are pure.** Every combinator's Javadoc says the
   function _"must be referentially transparent"_, with one licensed exception: it _"may
   construct FRP logic or use `Cell#sample()`"_ ([`Stream.java`][stream-java]).

Within this survey Sodium is the _transactional discrete FRP_ data point. Compare
[Elm][elm] (the same model reduced to one update function per message),
[synchronous languages][synchronous] (where "one transaction" is "one reaction" and is
compiled statically), and [Solid signals][solid-signals] / [TC39 signals][tc39] (glitch-free
but with no event type). Vocabulary is in [Concepts][concepts] and the cross-cut in
[Comparison][comparison].

---

## How it works

### The objects

| Concept           | Java type                                                                              | Role                                                                                               |
| ----------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Event stream      | `Stream<A>` ([source][stream-java])                                                    | A `Node` plus the `firings` seen in the current transaction, plus `finalizers` (cleanup listeners) |
| Step-wise value   | `Cell<A>` ([source][cell-java])                                                        | An `updates` stream, the committed `value`, and a pending `valueUpdate` for the open transaction   |
| Input             | `StreamSink<A>`, `CellSink<A>` ([source][streamsink-java], [cell sink][cellsink-java]) | `send(a)` opens (or joins) a transaction; refuses to run inside a callback                         |
| Forward reference | `StreamLoop<A>`, `CellLoop<A>` ([source][streamloop-java], [cell loop][cellloop-java]) | Placeholder used before definition, resolved by `loop(…)` inside the same explicit transaction     |
| Graph vertex      | `Node` ([source][node-java])                                                           | A `rank` and a list of `Target`s, each holding a **weak** reference to its handler                 |
| Clock of logic    | `Transaction` ([source][tx-java])                                                      | A rank-ordered priority queue, a `last` queue, a `post` queue, and two global locks                |
| Output handle     | `Listener` ([source][listener-java])                                                   | `unlisten()`; `append` combines two                                                                |

### A transaction, phase by phase

`Transaction.close()` ([`Transaction.java`][tx-java]) runs three queues in a fixed order:

```java
void close() {
    while (true) {                       // 1. propagation, lowest rank first
        checkRegen();
        if (prioritizedQ.isEmpty()) break;
        Entry e = prioritizedQ.remove();
        entries.remove(e);
        e.action.run(this);
    }
    for (Runnable action : lastQ)        // 2. commit: hold() makes new values visible, firings cleared
        action.run();
    lastQ.clear();
    // 3. postQ: each split()/defer() child index gets a NEW transaction;
    //    index -1 (Transaction.post) runs with no transaction at all.
}
```

1. **Propagation.** `StreamWithSend.send` records the firing and enqueues every listener
   target as `trans.prioritized(target.node, …)`. The queue orders by `Node.rank`, with a
   sequence number breaking ties ([`Transaction.java`][tx-java]). Ranks are kept
   topological by `Node.linkTo`, which calls `ensureBiggerThan` on the target and its
   descendants. If the queue is non-empty when ranks change (a `switch` relinking
   mid-transaction), `toRegen` forces the heap to be rebuilt ([`Node.java`][node-java]).
2. **Commit.** `Cell`'s constructor listens to its stream and, on the first firing in a
   transaction, registers `trans2.last(…)` to copy `valueUpdate` into `value`
   ([`Cell.java`][cell-java]). Until then, `sample()` returns the old value. This is the
   _implicit delay_ of `hold`: _"[`snapshot`] always sees the value of a cell as it was
   before any state changes from the current transaction"_ ([`Stream.java`][stream-java]).
3. **Post.** `Operational.split` puts each list element into `post_(childIx, …)`, and
   `close()` runs each in a fresh child transaction. In the denotation, time is a list of
   integers (`type T = [Int]`) and `split` gives child `n` the time `t++[n]`
   ([`Denotational.hs`][denot-hs]), so the children are ordered _after_ their parent and
   _before_ the next external input.

Nesting is free: `Transaction.run` joins `currentTransaction` if one is open on the same
thread, so a block wrapped in `Transaction.runVoid(…)` makes every `send` inside it
simultaneous ([`Transaction.java`][tx-java]).

---

## Evaluation model

- **Push, eager and hot.** Constructing `s.map(f)` immediately links a listener into
  `s`'s node. Nothing is lazy except `Lazy` initial values (`holdLazy`, `sampleLazy`),
  which exist for `CellLoop`s that are not yet bound ([`Cell.java`][cell-java]). There is
  no subscription step that starts a producer, and no cold stream.
- **Glitch-free by construction.** Rank ordering ensures that a node runs only after all
  its inputs for this transaction. `testLiftGlitch` sends `2` into `a`, lifts `a*3` with
  `a*5`, and asserts `["3 5", "6 10"]`, never `"6 5"` ([`TestCell.java`][testcell-java]).
  `Cell.apply`, the primitive under every `lift`, defers its output with a nested
  `prioritized` call and passes it through `lastFiringOnly`, so one transaction yields one
  output ([`Cell.java`][cell-java]).
- **Synchronous and batched per transaction.** `send` returns after propagation, commit
  and post have all run. External inputs on other threads block on `transactionLock` for
  the whole duration, callbacks included ([`.NET Transaction.cs`][tx-cs]: _"the lock is
  held for the whole transaction, which includes every listener callback it fires"_).
- **Simultaneity is a first-class notion.** Two firings are simultaneous exactly when they
  are in the same transaction. `merge(s, f)` guarantees _"only ever to have one event per
  transaction"_ by coalescing simultaneous firings with `f`, and `orElse` is `merge` with
  `(l, r) -> l` ([`Stream.java`][stream-java]). A bare `StreamSink` **throws** on a second
  `send` in one transaction: _"send() called more than once per transaction, which isn't
  allowed. Did you want to combine the events? Then pass a combining function to your
  StreamSink constructor."_ ([`StreamSink.java`][streamsink-java]).

> [!IMPORTANT]
> The snapshot rule is the whole answer to "what does one frame see". Inside a
> transaction, every `sample`/`snapshot` reads the values committed at the end of the
> _previous_ transaction. Every `hold` written during this one becomes visible together
> in the `last` phase. `testHoldIsDelayed` pins it down: `e.snapshot(e.hold(0))` over
> sends `2, 3` yields `["2 0", "3 2"]` ([`TestCell.java`][testcell-java]).

---

## Composition

Beyond the primitives, the Java `Stream`/`Cell` surface is small, about 30 public
combinators counting arity overloads once ([`Stream.java`][stream-java],
[`Cell.java`][cell-java]):

| Group            | Operators                                                                                                                                                                                          |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Primitives       | `Stream.map`, `merge(s, f)`, `filter`, `hold`, `snapshot`, `new Stream()` (never), `new Cell(a)` (constant), `Cell.map`, `Cell.apply`/`lift` (2–6 cells), `sample`, `Cell.switchS`, `Cell.switchC` |
| Derived          | `mapTo`, `orElse`, `filterOptional`, `gate(Cell<Boolean>)`, `collect` (Mealy machine), `accum`, `once`, `snapshot` over 2–5 cells, `*Lazy` variants                                                |
| Operational      | `Operational.updates`, `value`, `defer`, `split` ([`Operational.java`][operational-java])                                                                                                          |
| I/O and lifetime | `listen`, `listenWeak`, `listenOnce`, `addCleanup`, `Listener.append`, `Transaction.run/runVoid/post/onStart`                                                                                      |
| Recursion        | `StreamLoop.loop`, `CellLoop.loop`, legal only inside an explicit transaction ([`StreamLoop.java`][streamloop-java])                                                                               |

Notably absent from core: `distinctUntilChanged` (the book's `calm` builds it from
`collectLazy`, [`calm.java`][calm-java]), `debounce`, `flatMap`/`switchMap` over async
work, `zip`, `buffer`, retries, and any error operator. Higher-order composition is
`switchS`/`switchC` over a `Cell` of streams/cells. The higher-order value is always a
**cell**, so "which inner is current" is itself step-wise state that obeys the
transaction rule.

`switchS` relinks at the **end** of the transaction, in `trans2.last(…)`, and listens
to the new stream with `suppressEarlierFirings = true`
([`Cell.java`][cell-java]). The consequence is visible in `testSwitchSSimultaneous`: in
the transaction that switches from `ss3` to `ss4`, `ss3`'s `8` is still output and
`ss4`'s `2` is not ([`TestCell.java`][testcell-java]). Switching therefore drops the
old stream cleanly, but only at a transaction boundary. In the denotation the old
stream's occurrences are kept for `t <= t1`, so the switch is inclusive of the switching
instant ([`Denotational.hs`][denot-hs]).

---

## Time and scheduling

**Core has no clock.** Time exists only as the sequence of transactions. Scheduling is
fixed: one global serial order (rank order within a transaction, then `post`
children), with no dispatcher, executor or frame concept.

**`nz.sodium.time` (Java) and `Sodium.Frp.Time` (.NET) add an alarm system.** The Scala
port has no equivalent (`scala/src/main/scala/sodium/` has no time module). The Java
API ([`TimerSystem.java`][timersystem-java]):

- `TimerSystem<T>(TimerSystemImpl<T>)`: `time` is a `Cell<T>` of clock time, and
  `at(Cell<Optional<T>> tAlarm)` is a `Stream<T>` that fires when the clock reaches the
  cell's current alarm.
- `TimerSystemImpl<T>` ([source][timersystemimpl-java]) is the seam: `setTimer(t, callback)`
  returning a cancellable `Timer`, `runTimersTo(t)`, `now()`.
- `MillisecondsTimerSystem` uses `System.currentTimeMillis()` and a daemon thread that
  sleeps until the next deadline ([`MillisecondsTimerSystemImpl.java`][ms-impl-java]).
  `SecondsTimerSystem` is a `Double` of seconds since start ([source][seconds-java]).
- .NET: `ITimerSystem<T>` with `Time` (a `Behavior<T>`) and `At(Cell<Maybe<T>>)`
  ([`ITimerSystem.cs`][itimersystem-cs]). The book's WPF examples drive time from
  rendering frames: `CompositionTargetTimerSystem` sets `now` from
  `RenderingEventArgs.RenderingTime` on every `CompositionTarget.Rendering`
  ([source][composition-cs]). This is a frame clock plugged into the same seam.

**How alarms enter the graph.** `TimerSystem`'s constructor installs a
`Transaction.onStart` hook, _"The main use case of this is the implementation of a
time/alarm system"_ ([`Transaction.java`][tx-java]). Before **every** transaction it reads
`now()`, runs due timers, and for each queued alarm at or before `now` sends the alarm's
time into `time` and then into that alarm's `StreamSink`. Each of those sends is its own
transaction, opened before the triggering one. When the timer thread's callback fires,
it enqueues the event and _"Open[s] and close[s] a transaction to trigger queued events
to run"_ ([`TimerSystem.java`][timersystem-java]). Consequences:

- `time.sample()` is constant for the whole of a transaction. One transaction sees one
  instant.
- `at` **restarts itself**: it `listen`s to `tAlarm`, and on every change it `cancel()`s
  the current `Timer` and sets a new one (or none, for `Optional.empty()`). A cell of
  deadlines is therefore a timer that can be reset, which is all a debounce needs.
- The book's `periodic` timer loops `at`'s output back into its own alarm cell through a
  `CellLoop` ([`timers.java`][timers-java]).

**Debounce is not provided anywhere in the repository.** The only debounce in the tree is
the book's web chapter, which uses **RxJS**'s `debounce(100)` ([`autocomplete.js`][autocomplete-js]).
Two Sodium constructions follow from the source:

```java
// (a) Reset one alarm: a Cell<Optional<Long>> of deadlines; `at` cancels the old Timer.
CellLoop<Optional<Long>> deadline = new CellLoop<>();      // inside Transaction.runVoid
Stream<Long> sFire = sys.at(deadline);
deadline.loop(sQuery.map(q -> Optional.of(sys.time.sample() + delayMs.sample()))
                    .orElse(sFire.map(t -> Optional.<Long>empty()))
                    .hold(Optional.empty()));
Stream<String> sDebounced = sFire.snapshot(query);

// (b) Switch per event: a fresh alarm stream per keystroke; switchS drops the old one.
Stream<String> sDebounced2 = Cell.switchS(
    sQuery.map(q -> sys.at(new Cell<>(Optional.of(sys.time.sample() + delayMs.sample())))
                       .mapTo(q))
          .hold(new Stream<String>()));
```

(b) is the idiom the brief anticipates, and it is correct as FRP. Operationally,
though, it **does not cancel the superseded timer**. `at` cancels only when its alarm cell
changes, and a constant cell never changes. The `Listener` inside `at` is released only
by the dropped stream's `finalize()` ([`Stream.java`][stream-java]), so each old alarm
still fires and opens a transaction into a stream nobody listens to. That is a cost per
keystroke that waits on GC _(derived from the source, not executed)_. (a) cancels
eagerly and is the better form.

**Runtime-adjustable N.** Both forms read `delayMs` when they arm, so a new N applies
from the next restart. To make a change of N re-arm a _pending_ window, snapshot the
`deadline` cell (see [the worked pipeline](#the-worked-pipeline)). Because of the hold
delay, the delay change must use the event's own value, not `delayMs.sample()`, which
in that transaction still returns the old N.

---

## Concurrency and cancellation

Sodium has **no concurrency inside the graph**. Every transaction holds the single
`transactionLock`, and `listenersLock` protects only the listener lists
([`Transaction.java`][tx-java]). Any thread may `send`. Threads are serialized, not
parallel. Blocking inside a callback blocks every input in the process, and the .NET
documentation warns that _"a callback which blocks waiting on a thread that is itself
trying to start a transaction will deadlock"_ ([`.NET Transaction.cs`][tx-cs]).

**Latest-wins inside FRP** is `switchS`: switching unlistens the previous inner stream
in the `last` phase ([`Cell.java`][cell-java]). That handles stream _identity_ but not
_work_. A Sodium stream has no producer to stop, so switching cannot cancel anything
that runs outside the graph.

**CPU-bound work lives outside FRP**, behind the I/O boundary. The book's canonical bridge
is `Lookup.lookup` ([`Lookup.java`][lookup-java]): `listenWeak` on the request stream
starts a `Thread` per request, and the thread ends with `sDefinition.send(def)` into a
`StreamSink`, which is legal because the thread is outside any callback. `IsBusy` derives
the busy cell as `sOut.map(i -> false).orElse(sIn.map(i -> true)).hold(false)`. The book
example has **no** cancellation and no staleness guard: an older reply that arrives later
overwrites a newer one.

**.NET `MapAsync` packages the bridge with a cancellation strategy** ([`MapAsyncExtensions.cs`][mapasync-ext-cs],
[`MapAsyncUtility.cs`][mapasync-util-cs]). It runs `Func<TInput, CancellationToken, Task<TResult>>` per
firing, takes `results` and `errors` `StreamSink`s, exposes
`IsRunning`/`Items` cells, and takes a strategy (`Parallel`, `Queue`, `QueuePerGroup`,
`SwitchLatest`) ([`AsyncConcurrencyStrategy.cs`][asyncstrategy-cs]). `SwitchLatest`'s
`Admit` calls `state.Active?.Cancel()` on the superseded item, and its `OnCompleted`
publishes only `isCurrent = state.Active != null && state.Active.Id == item.Id`. This
is the request-id guard, built into the library.

**Does a cancel wait?** No. Cancellation is a signal, and the guard is what makes it
safe: _"an operation that ignores it still runs to completion, and cancellation only
means its result goes unpublished"_. Disposing likewise _"never gags the pipeline:
whatever is still in flight runs to completion"_ ([`MapAsyncUtility.cs`][mapasync-util-cs]).
`MapAsync`'s own state needs no lock because _"Sodium serializes ALL transactions
process-wide behind one global lock"_ (same file). Here the global lock doubles as the
synchronization primitive for the bridge.

---

## Errors and completion

- **No error channel.** Neither `Stream` nor `Cell` can fail or complete. The denotation
  has no termination: a stream is an infinite list of `(T, a)` occurrences
  ([`Denotational.hs`][denot-hs]). Errors are values (`Optional`, `Either`, a result
  record), and the async bridge carries them on a second stream (`MapAsync`'s `errors`).
- **Java swallows callback exceptions.** `StreamWithSend.send` wraps each handler in
  `try { … } catch (Throwable t) { t.printStackTrace(); }` ([`StreamWithSend.java`][streamwithsend-java]).
  A throwing `map` function does not abort the transaction. It is logged, and that
  branch simply does not fire.
- **.NET propagates.** `TransactionInternal.Run` captures the body's exception, still
  closes the transaction, and rethrows, combining the two in an `AggregateException` if
  closing also throws ([`Core Transaction.cs`][core-tx-cs]). `TimerSystem` takes an
  `Action<Exception> handleException` for its timer thread ([`TimerSystem.cs`][timersystem-cs]).
- **Completion substitutes.** `once()` yields a stream that fires at most once
  ([`Stream.java`][stream-java]). The book's `Promise` builds a one-shot value from
  `once` + `hold(Optional.empty())` ([`Promise.java`][promise-java]). "Done" is a
  state you model, not a protocol.

---

## State and sharing

- **`Cell` is the state primitive.** `hold`, `accum`, `collect` and `CellSink` are the
  only stateful constructions. A `Cell` always has a value (`new Cell(a)`, `hold(init)`),
  so there is no "no value yet" state for consumers to handle.
- **Everything is multicast.** A stream is one `Node` with N `Target`s. Adding a listener
  never re-runs upstream logic, so the cold/hot and `share()` questions do not arise.
- **Conflation is per transaction and explicit.** Simultaneous firings are combined by
  `merge`'s function or a sink's combining function. `CellSink` defaults to _"the last
  one is used"_ ([`CellSink.java`][cellsink-java]), and `Cell` keeps one `valueUpdate`
  per transaction. Across transactions nothing is ever dropped.
- **Late listeners are consistent.** A listener added in a transaction that has already
  fired receives those firings (`firings` replay in `Stream.listen`, _"so that there's no
  order dependency between send and listen"_, [`Stream.java`][stream-java]).
  `Cell.listen` is `value(trans).listen`, which delivers the current value first
  ([`Cell.java`][cell-java]).

---

## Lifetime and ownership

- **Listener-rooted, GC-collected.** `Node.Target` holds its handler through a
  `WeakReference` ([`Node.java`][node-java]). `Stream.listen` keeps the handler alive by
  adding the `Listener` to a static `keepListenersAlive` set until `unlisten()`
  ([`Stream.java`][stream-java]). The graph is therefore owned by whoever holds a
  `Listener`. Intermediate nodes stay alive through strong references from downstream
  to upstream, and they are torn down by `finalize()` running each stream's `finalizers`.
- **Two listen flavours.** `listen` is a leak if you forget `unlisten()`. `listenWeak`
  unregisters when collected, and `addCleanup` must be used only with `listenWeak`
  listeners _"so that things don't get kept alive when they shouldn't"_
  ([`Stream.java`][stream-java]).
- **No scope.** There is no structured owner: `Listener.append` is the only aggregation
  ([`Listener.java`][listener-java]). Cleanup of operational resources (threads, timers)
  is timed by the GC. `MemoryTest1`–`5` are soak programs that print heap size, not
  assertions ([`MemoryTest1.java`][memtest1-java]). The [`README`][readme] notes that the
  C++ port's _"memory management is not quite right yet"_.
- **Global hooks never unregister.** `Transaction.onStart` appends to a static list with
  no removal API ([`Transaction.java`][tx-java]), so every `TimerSystem` ever created
  keeps running its hook before every transaction.

---

## Testing

- **Determinism comes free.** `send` is synchronous and transactions are serialized, so a
  test is a list of sends followed by an assertion on collected outputs. Every
  `TestStream`/`TestCell` case has that shape ([`TestStream.java`][teststream-java],
  [`TestCell.java`][testcell-java]).
- **A cross-language specification.** `common-tests/` holds semantic and operational tests
  in Haskell, and `common-tests.hs` _generates_ `java/src/test/java/nz/sodium/TestCommon.java`
  (_"DO NOT EDIT THIS FILE"_) ([`common-tests.hs`][common-tests-hs],
  [`TestCommon.java`][testcommon-java]). The denotational semantics is executable, and
  .NET has a `DenotationalSemanticsTests.cs` ([source][denot-tests-cs]).
- **Virtual time is possible but not shipped.** `TimerSystem`'s constructor is public
  and takes any `TimerSystemImpl<T>`, so a test implementation with a settable `now()`
  and a sorted timer set gives a deterministic clock. Advancing it is "set `now`, then open
  an empty transaction". The shipped implementations are wall-clock. The only timer test
  (`TimerTests.SimultaneousTimerEvents`) uses `Thread.Sleep(200)` against the system clock
  ([`TimerTests.cs`][timertests-cs]). No debounce test exists, because no debounce exists.

---

## The worked pipeline

Query field → debounce N ms (N adjustable) → hash a file set on a worker with
latest-wins cancellation → show the result, all behind an on/off toggle. Java 17 with
Sodium (records are used for brevity; Sodium itself targets Java 8):

```java
import nz.sodium.*;
import nz.sodium.time.*;
import java.util.Optional;
import java.util.concurrent.*;

record Req(long id, String query) {}
record Res(long id, Optional<String> digest, Optional<Throwable> error) {}

final class HashPipeline {
    // I/O → FRP. Combining functions make "several inputs in one frame" legal (last wins).
    final StreamSink<String>  sQuery   = new StreamSink<>((l, r) -> r);
    final StreamSink<Long>    sDelayMs = new StreamSink<>((l, r) -> r);
    final StreamSink<Boolean> sEnabled = new StreamSink<>((l, r) -> r);
    final StreamSink<Res>     sResult  = new StreamSink<>((l, r) -> r); // fed by the worker
    final Cell<String> view;   // what the frame renders
    final Listener io;         // keeps the operational side alive; unlisten() = dispose

    HashPipeline(TimerSystem<Long> sys, ExecutorService pool) {
        Listener[] keep = new Listener[1];
        view = Transaction.run(() -> {                  // CellLoop needs an explicit transaction
            Cell<String>  query   = sQuery.hold("");
            Cell<Long>    delayMs = sDelayMs.hold(250L);
            Cell<Boolean> enabled = sEnabled.hold(true);
            Lambda1<Long, Optional<Long>> in = n -> Optional.of(sys.time.sample() + n);

            // 1. Debounce: a cell of deadlines; `at` cancels the old Timer on every change.
            CellLoop<Optional<Long>> deadline = new CellLoop<>();
            Stream<Long> sFire = sys.at(deadline);
            Stream<Optional<Long>> sArm =
                sEnabled.map(on -> on ? in.apply(delayMs.sample()) : Optional.<Long>empty())
                .orElse(sQuery.gate(enabled).snapshot(delayMs, (q, n) -> in.apply(n)))
                .orElse(Stream.filterOptional(                // new N re-arms a PENDING window
                    sDelayMs.snapshot(deadline, (n, d) -> d.map(x -> in.apply(n)))))
                .orElse(sFire.map(t -> Optional.<Long>empty()));
            deadline.loop(sArm.hold(Optional.empty()));
            Stream<String> sDebounced = sFire.snapshot(query);

            // 2. Number the requests; `latest` is the only id whose result may be shown.
            Stream<Req> sReq = sDebounced.collect(0L, (q, n) -> new Tuple2<>(new Req(n + 1, q), n + 1));
            Stream<Boolean> sOff = sEnabled.filter(on -> !on);
            Cell<Long> latest = sOff.map(off -> -1L).orElse(sReq.map(Req::id)).hold(-1L);

            // 3. The bridge (operational): start a job, interrupt its predecessor.
            Future<?>[] running = { null };             // touched only under the transaction lock
            Listener lReq = sReq.listen(r -> {
                if (running[0] != null) running[0].cancel(true);
                running[0] = pool.submit(() -> {
                    Res res;
                    try   { res = new Res(r.id(), Optional.of(hashFileSet(r.query())), Optional.empty()); }
                    catch (Throwable t) { res = new Res(r.id(), Optional.empty(), Optional.of(t)); }
                    sResult.send(res);                  // worker thread: its own transaction
                });
            });
            Listener lOff = sOff.listen(off -> { if (running[0] != null) running[0].cancel(true); });
            keep[0] = lReq.append(lOff);

            // 4. Drop stale results; derive what to show.
            Stream<Res> sFresh = Stream.filterOptional(sResult.snapshot(latest,
                (res, id) -> res.id() == id ? Optional.of(res) : Optional.<Res>empty()));
            Cell<Boolean> busy = sOff.map(off -> false).orElse(sFresh.map(r -> false))
                                     .orElse(sReq.map(r -> true)).hold(false);
            Cell<String> shown = sFresh.map(r -> r.digest()
                                     .orElseGet(() -> "error: " + r.error().get())).hold("");
            return shown.lift(busy, enabled, (s, b, on) -> !on ? "(off)" : b ? "hashing…" : s);
        });
        io = keep[0];
    }
}
```

Precise trace (`MillisecondsTimerSystem`, N = 250, times in ms). "T(x)" means one transaction:

| t    | Event                                       | What runs                                                                                                                                                                                                                                                                                                                                                                                          |
| ---- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | construction                                | One transaction builds the graph. `at` `listen`s to `deadline`, sees `Optional.empty()` and sets no timer. `view` = `""`.                                                                                                                                                                                                                                                                          |
| 100  | `sQuery.send("a")`                          | The `onStart` hook first runs T(`time` := 100). Then T(query): `gate` passes, `snapshot` reads `delayMs` = 250 and `sArm` fires `Some(350)`. `at`'s listener (an updates listener, so it runs during propagation) calls `setTimer(350)`. In the `last` phase `query` := `"a"` and `deadline` := `Some(350)`.                                                                                       |
| 200  | `"ab"` (during debounce)                    | `sArm` → `Some(450)`. `at` calls `cancel()` on the 350 timer, removing it from the `TreeSet`, and sets 450. Nothing else changes: the debounce restart is a cell step, not a stream switch.                                                                                                                                                                                                        |
| 450  | timer thread fires                          | The callback enqueues `Event(450)` and opens an empty T. Its `onStart` hook pops the event and runs T(`time` := 450) then T(alarm). In T(alarm): `sFire` → `sDebounced` = `snapshot(query)` = `"ab"` → `sReq` = `Req(1, "ab")`; `sArm` → `empty` (alarm cleared); `latest` := 1 and `busy` := true at commit. During propagation, `lReq` submits job 1 and returns at once. `view` = `"hashing…"`. |
| 600  | `"abc"` (during hash)                       | T: `sArm` → `Some(850)`. Job 1 **keeps running**: latest-wins applies when the next request exists, as with `debounce` → `switchMap`.                                                                                                                                                                                                                                                              |
| 850  | alarm                                       | T(alarm): `sReq` = `Req(2, "abc")`. `lReq` calls `Future.cancel(true)` on job 1 (an interrupt, which does **not** wait) and submits job 2. `latest` := 2.                                                                                                                                                                                                                                          |
| ~870 | job 1 sees interrupt                        | Its `hashFileSet` throws, and the worker sends `Res(1, error)` → T: `snapshot(latest)` reads 2, `filterOptional` drops it, and nothing visible changes. Without the id guard this error would have overwritten the screen.                                                                                                                                                                         |
| 1100 | job 2 completes                             | T: `Res(2, digest)` passes the guard; `shown` := digest and `busy` := false at commit; `view` = digest.                                                                                                                                                                                                                                                                                            |
| 1150 | `"abcd"`, then at 1200 `sDelayMs.send(500)` | 1150: deadline := `Some(1400)`. 1200: the delay branch snapshots `deadline` = `Some(1400)` (pending) and re-arms with the **event's** `n`: `Some(1700)`. `delayMs.sample()` would still return 250 in this transaction. Had no window been pending, `d` would be `empty` and nothing would re-arm.                                                                                                 |
| 1300 | `sEnabled.send(false)`                      | T: `sArm` → `empty`, so `at` cancels the 1700 timer. `sOff` fires: `latest` := −1, `busy` := false, and `lOff` interrupts any running job. `view` = `"(off)"` (computed from the committed `enabled` = false). `query` keeps tracking keystrokes while off (only arming is gated).                                                                                                                 |
| 1400 | `sEnabled.send(true)`                       | T: `sArm` → `Some(1400 + delayMs.sample())` = `Some(1900)`; at 1900 the current query is hashed under a fresh id.                                                                                                                                                                                                                                                                                  |
| end  | `io.unlisten()`                             | Stops starting jobs. The graph and the `at` timers are released only when the GC finalizes them. The `onStart` hook of the `TimerSystem` is never removed.                                                                                                                                                                                                                                         |

**Where it fits a per-frame UI.** The fit is unusually direct. A frame is one transaction:
wrap the frame's input events in `Transaction.runVoid(() -> { … send … })`, and every
keystroke, toggle and N change in that frame becomes simultaneous, with combining
functions deciding the winner. The default `StreamSink` would throw here, which is why
the sinks above pass `(l, r) -> r`. Rendering then reads `view.sample()`, which is
consistent by construction: it can never see `busy` from one transaction and `shown`
from another. Two seams need work for a frame loop. (1) Wake-ups: alarms and worker
results arrive on foreign threads as their own transactions, so the UI must be woken
(`view.listen(v -> wakeNow())`) or, better, the `TimerSystemImpl` should be driven by
the frame clock, as `CompositionTargetTimerSystem` does, with the next deadline fed
to `wakeIn`. (2) Retained graph: Sodium builds the graph once and keeps it, while an
immediate-mode widget tree is rebuilt every frame. The FRP graph must live in
application state, outside the per-frame widget code.

---

## Strengths

- **A precise, specified notion of "the same instant".** Transactions, the hold delay and
  simultaneous-merge rules are documented on each primitive, defined denotationally, and
  tested across ports from one generator.
- **Glitch-freedom and consistent snapshots for free.** Rank-ordered propagation plus a
  separate commit phase means no observer ever sees a half-updated graph.
- **Tiny core, closed under composition.** About ten primitives plus `switchS`/`switchC`
  express state machines (`collect`), recursion (`CellLoop`) and dynamic topology.
- **Explicit simultaneity.** `merge(s, f)` and sink combining functions force a decision
  about colliding events instead of an arbitrary interleaving. A bare sink fails loudly.
- **A clean timer seam.** `TimerSystemImpl` and an `at(Cell<Optional<T>>)` alarm whose
  reset is a cell step make a resettable debounce, and a frame-driven or virtual clock,
  small adapters.
- **A well-shaped async bridge (.NET).** `MapAsync` + `SwitchLatest` = cancel-on-supersede
  plus a publish guard keyed on item identity, with `IsRunning` as a glitch-free cell.

## Weaknesses

- **One global lock.** Every transaction, callbacks included, is serialized process-wide.
  This gives correctness, but no parallelism inside the graph, and a blocking callback
  risks deadlock.
- **No error or completion model.** Java prints and swallows handler exceptions. Streams
  never end. Failure and "done" must be hand-modelled as values.
- **Lifetime is GC- and finalizer-driven.** There are no structured scopes. `finalize()` is
  deprecated in modern Java. Timers created inside a `switchS` keep firing until collected.
  Static `onStart` hooks are never removed.
- **No time operators.** No `debounce`/`throttle`/`delay` in any port examined. The book
  reaches for RxJS when it needs one.
- **Async work is outside the model.** Sodium (outside .NET's add-on) offers nothing
  for starting, cancelling or correlating work. The book's `Lookup` has neither
  cancellation nor a staleness guard.
- **The hold delay is a sharp edge.** A delay change must use the event value, not the
  cell, and `CellLoop` must be resolved inside the same explicit transaction. Both are
  documented, but easy to get wrong.
- **Fragmented, partly unmaintained ports.** The .NET port is officially superseded by
  SodaFlow; four ports live in separate repositories.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                          | Trade-off                                                                                           |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Separate `Stream` and `Cell` types                    | Events and values have different semantics (occurrence vs value-at-time)           | Two of everything (`map`, `switch`, `listen`); `Operational.updates` is needed to cross back        |
| Transaction = logical instant; one global lock        | Atomic, deterministic, glitch-free updates from any thread                         | No parallel propagation; callbacks must not block; the lock is the only concurrency primitive       |
| `hold` updates commit in a `last` phase               | Every read in an instant sees one snapshot; loops (`CellLoop`) become well-defined | One-transaction delay surprises users; "new value now" needs the event's own value                  |
| Rank-ordered priority queue                           | Topological propagation without a separate scheduler                               | Rank fix-ups on relink (`ensureBiggerThan`) and a heap rebuild (`toRegen`) during dynamic switching |
| Simultaneous firings must be combined explicitly      | No hidden interleaving; one event per stream per transaction                       | A plain `StreamSink` throws on a second send; batching a frame requires combining functions         |
| `switchS`/`switchC` switch at end of transaction      | Switching is consistent with the snapshot rule; no double-firing                   | An inner stream cannot be swapped mid-instant; work behind a dropped stream is not cancelled        |
| No clock in core; `TimerSystem` via an `onStart` hook | Time is just another input; the clock is pluggable (wall, seconds, frame)          | Hidden extra transactions before each one; hooks never unregister; no virtual clock shipped         |
| I/O only through sinks and `listen`                   | Keeps FRP code referentially transparent; side effects at the edges                | Async work, cancellation and request correlation are user code (Java) or an add-on library (.NET)   |
| Weak node references + finalizers for teardown        | Graph nodes need no manual disposal; only `Listener`s are roots                    | Release timing depends on the GC; resources such as timers outlive their logical owner              |

---

## Sources

- [SodiumFRP/sodium][readme] at `03d0c0fe446afadcb18c12b4f37ea679ad64eb97` (2026-09-28): [`README`][readme] · [`COPYING`][copying] · [`java/pom.xml`][pom]
- Java core: [`Stream.java`][stream-java] · [`Cell.java`][cell-java] · [`Transaction.java`][tx-java] · [`Node.java`][node-java] · [`StreamWithSend.java`][streamwithsend-java] · [`StreamSink.java`][streamsink-java] · [`CellSink.java`][cellsink-java] · [`StreamLoop.java`][streamloop-java] · [`CellLoop.java`][cellloop-java] · [`Operational.java`][operational-java] · [`Listener.java`][listener-java]
- Java time: [`TimerSystem.java`][timersystem-java] · [`TimerSystemImpl.java`][timersystemimpl-java] · [`MillisecondsTimerSystemImpl.java`][ms-impl-java] · [`SecondsTimerSystemImpl.java`][seconds-java]
- Java tests: [`TestStream.java`][teststream-java] · [`TestCell.java`][testcell-java] · [`TestCommon.java`][testcommon-java] · [`MemoryTest1.java`][memtest1-java] · [`common-tests.hs`][common-tests-hs]
- .NET: [`Sodium.Frp/Transaction.cs`][tx-cs] · [`Sodium.Core.Frp/Transaction.cs`][core-tx-cs] · [`ITimerSystem.cs`][itimersystem-cs] · [`TimerSystem.cs`][timersystem-cs] · [`TimerTests.cs`][timertests-cs] · [`DenotationalSemanticsTests.cs`][denot-tests-cs] · [`AsyncConcurrencyStrategy.cs`][asyncstrategy-cs] · [`MapAsyncExtensions.cs`][mapasync-ext-cs] · [`MapAsyncUtility.cs`][mapasync-util-cs]
- Book companion code: [`Lookup.java`][lookup-java] · [`Promise.java`][promise-java] · [`timers.java`][timers-java] · [`calm.java`][calm-java] · [`CompositionTargetTimerSystem.cs`][composition-cs] · [`autocomplete.js`][autocomplete-js]
- Semantics: [`Denotational.hs`][denot-hs] (the PDF _Denotational Semantics of Sodium - 1.1_ sits beside it)
- Stephen Blackheath and Anthony Jones, _Functional Reactive Programming_, Manning, 2016 — [manning.com/books/functional-reactive-programming][book]
- [SodaFlow][sodaflow], named in the README as the .NET successor (not examined)
- Related in this survey: [index][index] · [Concepts][concepts] · [Comparison][comparison] · [RxJS][rxjs] · [Elm][elm] · [Synchronous languages][synchronous] · [Solid signals][solid-signals] · [TC39 signals][tc39] · [event-horizon spec][eh-spec]

<!-- References -->

[readme]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/README
[copying]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/COPYING
[pom]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/pom.xml
[stream-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/Stream.java
[cell-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/Cell.java
[tx-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/Transaction.java
[node-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/Node.java
[streamwithsend-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/StreamWithSend.java
[streamsink-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/StreamSink.java
[cellsink-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/CellSink.java
[streamloop-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/StreamLoop.java
[cellloop-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/CellLoop.java
[operational-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/Operational.java
[listener-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/Listener.java
[timersystem-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/time/TimerSystem.java
[timersystemimpl-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/time/TimerSystemImpl.java
[ms-impl-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/time/MillisecondsTimerSystemImpl.java
[seconds-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/main/java/nz/sodium/time/SecondsTimerSystemImpl.java
[teststream-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/test/java/nz/sodium/TestStream.java
[testcell-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/test/java/nz/sodium/TestCell.java
[testcommon-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/test/java/nz/sodium/TestCommon.java
[memtest1-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/java/src/test/java/nz/sodium/MemoryTest1.java
[common-tests-hs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/common-tests/common-tests.hs
[denot-hs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/denotational/Reactive/Sodium/Denotational.hs
[tx-cs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/dotnet/src/Sodium/CSharp/Sodium.Frp/Transaction.cs
[core-tx-cs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/dotnet/src/Sodium/Sodium.Core.Frp/Transaction.cs
[itimersystem-cs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/dotnet/src/Sodium/CSharp/Sodium.Frp/Time/ITimerSystem.cs
[timersystem-cs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/dotnet/src/Sodium/CSharp/Sodium.Frp/Time/TimerSystem.cs
[timertests-cs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/dotnet/src/Sodium/CSharp/Sodium.Frp.Tests/TimerTests.cs
[denot-tests-cs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/dotnet/src/Sodium/CSharp/Sodium.Frp.Tests/DenotationalSemanticsTests.cs
[asyncstrategy-cs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/dotnet/src/Sodium/Async/CSharp/Sodium.Frp.Async/AsyncConcurrencyStrategy.cs
[mapasync-ext-cs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/dotnet/src/Sodium/Async/CSharp/Sodium.Frp.Async/MapAsyncExtensions.cs
[mapasync-util-cs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/dotnet/src/Sodium/Async/Sodium.Core.Frp.Async/MapAsyncUtility.cs
[lookup-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/book/real-world/java/lookup/Lookup.java
[promise-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/book/real-world/java/Promise.java
[timers-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/book/continuous-time/java/timers.java
[calm-java]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/book/patterns/java/calm.java
[composition-cs]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/book/continuous-time/c%23/Shared/CompositionTargetTimerSystem.cs
[autocomplete-js]: https://github.com/SodiumFRP/sodium/blob/03d0c0fe446afadcb18c12b4f37ea679ad64eb97/book/web/autocomplete.js
[book]: https://www.manning.com/books/functional-reactive-programming
[sodaflow]: https://morsecode-software.github.io/SodaFlow/
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[rxjs]: ./rxjs.md
[elm]: ./elm.md
[synchronous]: ./synchronous-languages.md
[solid-signals]: ./solid-signals.md
[tc39]: ./tc39-signals.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
