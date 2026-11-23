# Comparison: twenty implementations of one pipeline

The capstone of the [reactive-programming survey][index]. Every deep-dive wrote the
same **worked pipeline**: a query field → debounce _N_ ms, _N_ adjustable at
runtime → hash a file set on a worker, a newer query cancelling the running hash →
show the result, with a toggle that switches the whole pipeline off. This page lays
the twenty answers side by side, extracts what they agree on, and maps each
capability onto what [`event-horizon`][eh-docs] has today. Terms are defined in
[concepts].

**Last reviewed:** November 23, 2026

---

## At a glance

| Subject                                | Model              | Latest-wins form                       | Cancel waits?                 | Built-in debounce                        | Interval changeable while waiting?    | Value cell                   | Glitch-free     | Virtual time                                 |
| -------------------------------------- | ------------------ | -------------------------------------- | ----------------------------- | ---------------------------------------- | ------------------------------------- | ---------------------------- | --------------- | -------------------------------------------- |
| [RxJS][rxjs]                           | push               | `switchMap`                            | no                            | `debounceTime` (fixed), `debounce(sel)`  | next value only (`debounce(sel)`)     | `BehaviorSubject`            | no              | `TestScheduler` (7.x); patched globals (9.x) |
| [Effect][effect-ts]                    | pull, chunked      | `Stream.switchMap`                     | yes (`switchMap`)             | `Stream.debounce` (fixed)                | no                                    | `SubscriptionRef`            | n/a             | `TestClock`                                  |
| [Kotlin Flow][kotlin-flow]             | push, suspending   | `transformLatest`                      | yes (join)                    | `debounce { … }`                         | next value only                       | `StateFlow`                  | no              | `runTest` dispatcher                         |
| [Swift][swift-async-algorithms]        | pull               | `flatMapLatest`; `.task(id:)`          | no                            | `debounce(for:)` (fixed)                 | no                                    | none (Observation)           | n/a             | none built in (`swift-clocks`)               |
| [Rust][rust-streams]                   | poll               | `select!` loop; `map_future`           | no                            | none                                     | yes (`Sleep::reset`)                  | `watch`, `Mutable`           | undocumented    | tokio `pause`/`advance`                      |
| [fs2][fs2]                             | pull, chunked      | `switchMap`                            | yes (finalizers)              | `debounce` (fixed, audit-like)           | no                                    | `SignallingRef`              | no              | `TestControl`                                |
| [Solid 2.0][solid-signals]             | push-pull          | async memo                             | never cancels                 | none                                     | n/a                                   | signal                       | yes             | none                                         |
| [TC39][tc39-signals]                   | push-pull          | none                                   | n/a                           | none                                     | n/a                                   | `Signal.State`               | yes             | none                                         |
| [Angular][angular-signals]             | push-pull          | `resource`                             | no                            | `debounced` (experimental)               | next value only                       | `signal`                     | yes             | `TestBed.tick` + fake timers                 |
| [Compose][jetpack-compose]             | snapshot state     | `LaunchedEffect(key)`                  | no                            | none                                     | yes, by keying on it                  | `MutableState`               | yes             | `MainTestClock`                              |
| [Sodium][sodium]                       | transactional push | `switchS`; .NET `MapAsync`             | no                            | none                                     | yes (deadline cell)                   | `Cell`                       | yes             | timer system `runTimersTo`                   |
| [Elm][elm]                             | model-update       | none (sequence number)                 | never cancels                 | none                                     | yes (per sleep)                       | the model                    | n/a             | `elm-program-test` `advanceTime`             |
| [Esterel/Céu][synchronous-languages]   | synchronous        | `par/or`, `abort … when`               | threads: no                   | none (`await N ms`)                      | with a third race branch              | variables                    | by construction | `emit` time from `async`                     |
| [C++ senders][cpp-senders-receivers]   | lazy single-value  | none (scope + stop source per request) | composites: yes; spawned: no  | none                                     | yes (an argument to `schedule_after`) | none                         | n/a             | none (fake a `timed_scheduler`)              |
| [Rx.NET][rx-dotnet]                    | push               | `Select(f).Switch()`                   | no (AsyncRx: yes, unreleased) | `Throttle` (fixed), `Throttle(selector)` | next value only (selector)            | `BehaviorSubject`            | no              | `TestScheduler`, `HistoricalScheduler`       |
| [Pekko Streams][pekko-streams]         | demand-driven      | `switchMap` (1.2.0)                    | no                            | none (`switchMap` + `initialDelay`)      | next value only                       | none                         | n/a             | `ManualTime` (process-wide)                  |
| [Transducers][clojure-transducers]     | push into a step   | none (hand-written `go-loop`)          | never cancels                 | none (`alts!` + `timeout`)               | yes, in hand-written code             | none (atom, sliding channel) | n/a             | none (wall-clock timers)                     |
| [Reflex][reflex]                       | push-pull, frames  | `switchHold`, `switchDyn`              | never cancels                 | `debounce` (fixed)                       | no (user code sampling a `Behavior`)  | `Dynamic`                    | yes             | none (frame-by-frame test plans)             |
| [Yampa][yampa]                         | sampled dataflow   | `rSwitch`                              | n/a (pure)                    | none (`localTime` after a restart)       | yes (compared on every sample)        | none first-class             | by construction | `embed` with explicit `dt`                   |
| [Incremental][jane-street-incremental] | explicit stabilise | `bind`                                 | n/a (no async)                | none (`bind` over `Clock.after`)         | yes (an input of the `bind`)          | `Var`                        | yes             | `Clock.advance_clock`                        |

---

## Latest wins and the cancel-wait split

Every subject can express latest-wins; they differ in what abandoning the old work
means.

1. **Cancel-and-join** ([Kotlin][kotlin-flow], [fs2][fs2], [Effect][effect-ts]'s
   `switchMap`). The replacement starts only after the cancelled run has finished,
   finalizers included. fs2 states it in the scaladoc ("Finializers of each inner
   stream are guaranteed to run before the next inner stream starts") and enforces
   it with a one-permit semaphore; Kotlin's `transformLatest` calls `cancel()`, then
   `join()`, then `launch`. The cost is latency: the switch waits for the old work to
   reach a cancellation point.
2. **Cancel-and-forget** ([RxJS][rxjs], [Swift][swift-async-algorithms],
   [Rust][rust-streams], [Compose][jetpack-compose], [Angular][angular-signals],
   [TC39][tc39-signals] user code, [Sodium][sodium]'s .NET `MapAsync`). The
   replacement starts at once and a generation check drops the stale result. Old and
   new CPU work overlap until the old one notices.
3. **Discard only** ([Solid][solid-signals], [Elm][elm]). Nothing is told to stop;
   the stale result is ignored. Solid's RFC: "Solid drops a superseded run's result
   on its own; stopping the work itself is up to the run."
4. **Lexical abortion** ([Céu][synchronous-languages]). The losing trail of a
   `par/or` dies in the same reaction, finalizers run, and nothing is left to
   discard. A hashing thread is the exception: it is flagged and reaped later.

Effect is split internally: `Stream.switchMap` joins, `FiberHandle.run` and `Atom`
do not. A library that offers latest-wins has to choose one rule and state it.

[C++ senders][cpp-senders-receivers] make the split by construction. The composite
algorithms (`when_all` in C++26, `exec::when_any` in stdexec) request stop on the
other children and complete only after every child has, the rule
`event-horizon`'s [`race`][eh-schedule] already follows. There is no latest-wins
algorithm at all: it is built from a `counting_scope`, a stop source per request
and a generation check, which forgets by default and joins only when each request
is chained on its predecessor's `spawn_future`.

---

## Debounce

**No surveyed library's debounce operator handles an interval that changes while a
wait is pending.** The built-in operators fix the duration at construction
(Effect, Swift, fs2, RxJS `debounceTime`) or read it once per value when the value
arrives (RxJS `debounce(selector)`, Kotlin `debounce { … }`, Angular `debounced`).
fs2's `debounce` is not even a trailing debounce: it fires _N_ after the first value
of a burst.

The consensus is to **build debounce from latest-wins**: the inner work begins with
a sleep on the current interval, and the next value cancels it, whether it is still
sleeping or already hashing.

| Subject                              | Debounce as a sleep inside latest-wins                                          |
| ------------------------------------ | ------------------------------------------------------------------------------- |
| [Effect][effect-ts]                  | `Stream.switchMap(q => sleep(Ref.get(n)) then hash(q))`                         |
| [Kotlin][kotlin-flow]                | `transformLatest { delay(n.value); emit(hash(it)) }`                            |
| [fs2][fs2]                           | `switchMap(q => Stream.sleep(n.get) ++ hash(q))`                                |
| [Compose][jetpack-compose]           | `LaunchedEffect(query) { delay(n); hash(query) }`                               |
| [Swift][swift-async-algorithms]      | `.task(id: query) { try await Task.sleep(for: n); … }`                          |
| [Rust][rust-streams]                 | `map_future` around a `sleep`, or `Sleep::reset(last + n)`                      |
| [Céu][synchronous-languages]         | `par/or do await (n)ms; hash with await QUERY end`                              |
| [Sodium][sodium]                     | a deadline cell fed to the timer system's `at`                                  |
| [C++ senders][cpp-senders-receivers] | `schedule_after(sch, n) \| let_value(hash)` inside a spawned, stoppable request |

This collapse has a second benefit the separate-operator form lacks. With
`debounce` followed by `switchMap`, a keystroke during a hash cancels it only _N_
later, when the debounced value arrives ([Kotlin][kotlin-flow],
[Compose][jetpack-compose] both document the difference). With the sleep inside, the
keystroke cancels the hash at once.

The interval becomes changeable in two strengths. Reading it at the start of each
sleep applies a change from the next keystroke. Making the interval an input of the
latest-wins key ([Compose][jetpack-compose] keys on both; [Céu][synchronous-languages]
adds a third race branch) restarts a pending wait at once, at the cost of
re-hashing an unchanged query.

On cost: RxJS 7's `debounceTime` and Swift's debounce do not re-arm a timer per
value. They record the last arrival and let one long-lived timer re-check its
deadline on waking. RxJS 9 dropped the optimisation (decision D-019).

---

## Cells and streams

Every mature design separates **value cells** from **event streams**:

- Kotlin has `StateFlow` (conflated, always has a value, never completes) beside
  `SharedFlow` and `Flow`.
- Sodium's whole API is `Cell` versus `Stream`, joined only by `hold`, `snapshot`
  and `sample`.
- Compose makes conflation a principle and tells users not to model events as state.
- Signals libraries ([Solid][solid-signals], [TC39][tc39-signals],
  [Angular][angular-signals]) are cells only; their bridges to streams
  ([Angular][angular-signals]'s `toObservable`) are lossy and asynchronous.

The cells differ in what a slow reader sees. `StateFlow`, `watch`, `Mutable` and
signals keep only the latest value; Effect's `SubscriptionRef.changes` replays every
update through an unbounded `PubSub`, so conflation has to be added downstream.

The worked pipeline needs both: the query, the toggle and the interval are cells;
nothing in it is an event that must not be lost.

---

## Errors

Two positions:

- **An error ends the stream** ([RxJS][rxjs], [Kotlin][kotlin-flow] `Flow`,
  [fs2][fs2], [Swift][swift-async-algorithms]). A failed hash inside the inner kills
  the pipeline unless it is caught _inside_ the inner and turned into a value.
- **An error is a value or a status** ([Effect][effect-ts]'s `Exit`/`Cause`,
  [Angular][angular-signals]'s `resource` status, [Solid][solid-signals]'s errored
  node, [TC39][tc39-signals]'s cached exception, [Elm][elm]'s `Result` in a message).

Effect adds the distinction that matters for latest-wins: **interruption is
neither success nor failure**. A superseded hash must not surface as an error, and
must not be mistaken for a result. [C++ senders][cpp-senders-receivers] make it a
channel of its own: every operation completes exactly once, on `set_value`,
`set_error` or `set_stopped`, and `spawn` drops a stopped completion silently,
which is the behaviour a superseded request wants. [Compose][jetpack-compose] shows the failure
mode: a broad `catch` swallows the cancellation and silently breaks latest-wins.

---

## Lifetime and ownership

| Mechanism                                  | Subjects                                                                                                                                             |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Structured scopes (cancel propagates down) | [kotlin-flow], [fs2], [effect-ts], [synchronous-languages] (lexical), [cpp-senders-receivers] (`counting_scope`; destroying one unjoined terminates) |
| Manual subscriptions                       | [rxjs] (`takeUntil(destroy$)`), [swift-async-algorithms] (unstructured `Task`s inside operators)                                                     |
| Injection-context teardown                 | [angular-signals] (`DestroyRef`)                                                                                                                     |
| Owner tree                                 | [solid-signals]                                                                                                                                      |
| Keyed slots in the UI tree                 | [jetpack-compose], SwiftUI `.task(id:)`                                                                                                              |
| Declarations diffed by the runtime         | [elm] (`subscriptions model`)                                                                                                                        |
| Garbage collection                         | [sodium], [tc39-signals] (unwatched nodes)                                                                                                           |

The toggle is the test of a lifetime model. Where lifetime is structural —
Elm's `if model.on then … else Sub.none`, Compose's `if (enabled) LaunchedEffect`,
Céu's `watching` — switching off cancels the pending debounce and the running hash
with no extra code. Where it is an operator (`switchMap(on => on ? src : EMPTY)` in
RxJS, Effect, fs2, Kotlin), the result is the same but must be composed explicitly.
Effect's `Stream.when` looks like a toggle and is not: it checks once, at start.

---

## The frame

Four subjects give a frame a reactive meaning, and they agree on its shape:

- [Sodium][sodium]: one **transaction** is one instant. Every read sees the
  previous transaction's committed values; every `hold` commits at the end.
- [Esterel and Céu][synchronous-languages]: one **reaction** runs every awakened
  trail to completion before the next input is read.
- [Angular][angular-signals]: one change-detection **tick** flushes root effects,
  then refreshes views; each effect-driven hop costs one tick.
- [Compose][jetpack-compose]: global snapshot writes are coalesced, then one
  recomposition runs per frame.

The shared lesson: **inputs are applied between frames, and a frame reads one
consistent snapshot**. Sparkles apps already rebuild their widget tree every frame,
so they need no read tracking to decide what re-runs ([Compose][jetpack-compose]'s
conclusion). What they lack is the lifetime half: which work stays alive between
frames.

Two hazards recur. [Solid][solid-signals]'s pending async value throws when read
outside a tracking scope, and a per-frame rebuild reads everything outside one: a
frame needs a non-throwing read returning pending, a value or an error.
[Sodium][sodium]'s hold delay means that in the transaction where the interval
changes, sampling it still returns the old value.

---

## Virtual time

Everyone who tests debounce deterministically does it with virtual time, and three
lessons recur:

1. **The clock must be injected, not patched.** RxJS 7 passes a scheduler with
   `now()`; RxJS 9 removed schedulers and patches `globalThis` timers, and its own
   decision record admits that timers captured before the patch escape.
2. **The worker executor must be under the test clock too.** Kotlin's
   `Dispatchers.Default`, Compose's off-main work and tokio's blocking pool all
   escape virtual time unless injected; fs2's `TestControl` treats waiting on an
   external thread as a deadlock.
3. **Advancing must run what became due, then wait for it to settle.** Effect's
   `TestClock.adjust` wakes sleepers one deadline at a time and waits until the woken
   fibers are idle; Kotlin's `advanceTimeBy` excludes its end point, so a timer due
   exactly then needs `runCurrent()`.

---

## API structure and naming

The second-wave deep-dives each carry an `API structure and naming` subsection
([Rx.NET][rx-dotnet-api], [Pekko][pekko-api], [transducers][transducers-api],
[Reflex][reflex-api], [Yampa][yampa-api], [Incremental][incr-api]). Read together
with the first wave, they agree on six points, and their regrets are more
instructive than their designs.

**1. Sources, transforms and sinks are different kinds of thing.** The libraries
that make the split a type split age best. [Pekko][pekko-streams] has `Source`,
`Flow` and `Sink` blueprints that do nothing until a `RunnableGraph` is
materialised. [Incremental][jane-street-incremental] has `Var` (input), `Incr`
(derived) and `Observer` (sink), with one one-way conversion between each.
[Transducers][clojure-transducers] separate the transformation from both the
process that applies it and the reducing function that receives it. Effect
makes running a stream a `run*` family that returns the single-value type
([Effect][effect-ts]: `runCollect`, `runDrain`, `runFold`). [Rx.NET][rx-dotnet] puts
all three on one static `Observable` class, split over 18 files, and its
`Qbservable` ADR has to name the split after the fact ("factory-like" versus
"combinator-like" operators).

**2. An operator is written once, for every source kind.** Pekko defines each
operator once in `FlowOps`, and the return type follows the receiver (a `Source`
stays a `Source`). Transducers run the same `map`, `filter`, `dedupe` and `scan` over
collections, lazy sequences and channels; core.async then deprecated its parallel
channel family (`map<`, `filter>`, `unique`) with "Use transducer instead". The
boundary is the same everywhere: per-element operators can be source-independent;
operators that need time (debounce), concurrency (switch) or several inputs (merge)
cannot, and core.async writes those as `go` processes.

**3. A second type channel is expensive.** Pekko's materialised-value parameter
`Mat` forces 27 `…Mat` twins in `scaladsl/Flow.scala`, `Keep.left/right/both`, and a
series of escape hatches (`preMaterialize`, `Sink.source`). Effect's `R` channel is
the same cost paid for dependency injection. A sink that returns one `Effect` and
handles (queues, cells, cancel tokens) created before the pipeline avoid it.

**4. Variant axes become parameters, not names.** Every long-lived library grew a
suffix grammar, and the later releases fold it back into arguments:

| Library                                   | Grammar                                                                 | What happened                                                                     |
| ----------------------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| [Yampa][yampa]                            | `d`/`r`/`k`/`p` prefixes, `B`/`Z`, `Cat`, `By`: 22 switch names         | documented in the source; still the hardest part of the API                       |
| [Reflex][reflex]                          | `Dyn`, `B`, `E`, `With`, `Maybe`, `M`, `'`, `Promptly`, `Cheap`         | stacks to `attachPromptlyDynWithMaybe`; the safe default got the short name       |
| [Rx.NET][rx-dotnet] (`System.Linq.Async`) | `SelectAwait`, `WhereAwait`, `SelectAwaitWithCancellation`              | retired in .NET 10 for overloads that always take a token                         |
| [Effect][effect-ts] v4                    | `catchAll` → `catch`, `catchSome` → `catchFilter`; `fork` → `forkChild` | concurrency and discard moved into an options object (`{ concurrency, discard }`) |
| [Pekko][pekko-streams]                    | `flatMapConcat`/`flatMapMerge`, `…Unordered`, `…Within`, `…Weighted`    | regular, but latest-wins is `switchMap`, outside the `flatMap…` family            |
| [Incremental][jane-street-incremental]    | `_exn`, `map2`…`map15`, `'`, `opt_`; an `Expert` submodule              | mechanical and uniform; the sugar (`Let_syntax`) builds more nodes than `mapN`    |

The renames in Effect v4 are recorded in its migration notes
([`error-handling.md`][eff-mig-errors], [`forking.md`][eff-mig-forking]). Distinct
names are kept for distinct semantics: merge versus switch versus concat, ordered
versus `Unordered`.

**5. A name is chosen for the semantics, once.** The most-cited regret in the survey
is Rx.NET's `Throttle`, which is a debounce; its packaging ADR is premised on
"almost nobody likes `Throttle`". The same word means two things across the
catalog: a trailing debounce ([RxJS][rxjs]' `debounceTime`) and an audit
([fs2][fs2]'s `debounce`). Reflex
renamed `switchPromptly` to `switchHoldPromptly` to group operators by how they are
built. Renames cost a major version in Pekko (`TestSource.probe` → `TestSource()`).

**6. Free-function operators collide.** In .NET 10, two libraries defining `Select`
on `IAsyncEnumerable` became an ambiguity error and forced the
`AsyncEnumerableDeprecated` rename. D's UFCS has the same failure mode: a stream
`map` beside `std.algorithm.map`, or an operator struct named like
`event-horizon`'s own `Mapped` and `Zipped`. One canonical module per operator
family, with aliases in separately imported modules, keeps resolution predictable.

Two documentation practices are worth copying. Pekko's operator index sorts about
230 operators into 17 categories, and every operator page carries the same four
lines: emits when, backpressures when, completes when, cancels when. Reflex's
Quickref groups functions by the type they return and tags each with the capability
it needs to run.

---

## The consensus standard

What a reactive library for a structured-concurrency loop should provide, as far as
twenty designs agree:

1. **Latest-wins is the primitive** — a switch that owns a child scope per value and
   cancels it on the next one. Debounce, toggles and restarts are built from it.
2. **One stated cancel rule.** Join or forget, chosen once and documented; the
   libraries that mix them (Effect) are the ones whose docs have to warn about it.
3. **Value cells distinct from event streams**, cells conflating.
4. **Interruption is a third outcome**, never an error and never a value.
5. **Cancellation reaches CPU work through cancellation points** — chunk boundaries
   or explicit checks — because nothing preempts.
6. **An injectable clock**, with the worker executor reachable from tests.
7. **A frame reads a consistent snapshot**, and a pending value is readable without
   throwing.

## Architectural trade-offs

| Decision           | Option A                                         | Option B                                              |
| ------------------ | ------------------------------------------------ | ----------------------------------------------------- |
| Cancel semantics   | join: serial resources, higher switch latency    | forget: low latency, overlapping CPU work             |
| Debounce           | an operator (familiar, fixed or per-value N)     | a sleep inside latest-wins (one mechanism, dynamic N) |
| Where streams live | a stream library over the loop (Rx, Effect, fs2) | keyed effects in the UI tree (Compose, SwiftUI, Elm)  |
| Evaluation         | push (simple, no backpressure)                   | pull (backpressure, chunking, more machinery)         |
| Glitch handling    | none (streams)                                   | transactions or push-pull (cells)                     |

---

## Delta: what event-horizon has and what is missing

| Capability                         | Prior art                                                       | `event-horizon` today                                                                                           | Gap                                                 |
| ---------------------------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| Lazy single-value effect           | Effect `Effect`, cats-effect `IO`                               | [`Effect`][eh-effect]: `succeed`, `fail`, `map`, `andThen`, `zipPar`, `withRetry`, `withTimeout`                | none for one value; no multi-value stream           |
| Structured scopes and cancel       | Kotlin `CoroutineScope`, fs2 scopes                             | [`Scope`][eh-scope]: `spawn`, `cancel`, `onExit`, `withScope`, `withDeadline`                                   | none                                                |
| Race / first-wins                  | `par/or`, `select!`, `exec::when_any`                           | [`race`][eh-schedule]                                                                                           | none                                                |
| Stop-token joining                 | C++ _stop-when_ (exposition-only); `write_env` replaces instead | the fiber context's interrupt, inherited down a scope                                                           | combine a per-request token with the scope's        |
| Latest-wins switch                 | `switchMap`, `transformLatest`, `LaunchedEffect(key)`           | none as a primitive; hand-written four times (hue's [`FormatFlow`][hue-format], the picker, grep, font preview) | **the core gap**                                    |
| Debounce                           | sleep inside latest-wins                                        | [`sleep`/`sleepUntil`][eh-io], [`Ticker`][eh-io]                                                                | falls out of the switch                             |
| Value cell (multicast, conflating) | `StateFlow`, `watch`, `Mutable`, signals                        | none; [`Channel`][eh-channel] is a unicast queue                                                                | **new**                                             |
| Cross-thread delivery to the UI    | `CrossChannel`, `watch`                                         | [`CrossChannel`][eh-cross] (`tryTake` from any thread), the loop's waker                                        | none                                                |
| CPU work off the loop              | `withContext(Default)`, `blocking`, Workers                     | [`JobQueue`][eh-jobs], `RawCpuPool`, `BlockingPool`, `ForkServer`                                               | cancellation of an accepted job is cooperative only |
| Cancellation point in CPU work     | fs2 chunk steps, `ensureActive`                                 | [`interruptRequested`][eh-cause] for fibers; nothing for pool jobs                                              | a token a worker can poll                           |
| Interruption as a third outcome    | Effect `Exit`/`Cause`                                           | `ECANCELED` as an `IoError`                                                                                     | decide whether a superseded result is an error      |
| Virtual time                       | Effect `TestClock`, `TestControl`                               | [`TestClock`][eh-clock] with `advance`/`advanceToNext`                                                          | the worker pool under the test clock                |
| Frame integration                  | Sodium transactions, Compose frames                             | the UI host's [`wakeIn`][ui-host] per frame; no event-horizon loop on the native window arm                     | **decide where the pipeline runs**                  |

The core gaps are three: **a latest-wins switch**, **a value cell**, and **a decision
on where a pipeline runs relative to the UI frame**. Everything else exists.

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[rxjs]: ./rxjs.md
[effect-ts]: ./effect-ts.md
[kotlin-flow]: ./kotlin-flow.md
[swift-async-algorithms]: ./swift-async-algorithms.md
[rust-streams]: ./rust-streams.md
[fs2]: ./fs2.md
[solid-signals]: ./solid-signals.md
[tc39-signals]: ./tc39-signals.md
[angular-signals]: ./angular-signals.md
[jetpack-compose]: ./jetpack-compose.md
[sodium]: ./sodium.md
[cpp-senders-receivers]: ./cpp-senders-receivers.md
[rx-dotnet]: ./rx-dotnet.md
[pekko-streams]: ./pekko-streams.md
[clojure-transducers]: ./clojure-transducers.md
[reflex]: ./reflex.md
[yampa]: ./yampa.md
[jane-street-incremental]: ./jane-street-incremental.md
[rx-dotnet-api]: ./rx-dotnet.md#api-structure-and-naming
[pekko-api]: ./pekko-streams.md#api-structure-and-naming
[transducers-api]: ./clojure-transducers.md#api-structure-and-naming
[reflex-api]: ./reflex.md#api-structure-and-naming
[yampa-api]: ./yampa.md#api-structure-and-naming
[incr-api]: ./jane-street-incremental.md#api-structure-and-naming
[eff-mig-errors]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/migration/error-handling.md
[eff-mig-forking]: https://github.com/Effect-TS/effect/blob/e3aca1f1484e623cee09b7f3fa18d6ff5d66c0e8/migration/forking.md
[elm]: ./elm.md
[synchronous-languages]: ./synchronous-languages.md
[eh-docs]: ../../libs/event-horizon/index.md
[eh-effect]: ../../../libs/event-horizon/src/sparkles/event_horizon/effect.d
[eh-scope]: ../../../libs/event-horizon/src/sparkles/event_horizon/scope_.d
[eh-schedule]: ../../../libs/event-horizon/src/sparkles/event_horizon/schedule.d
[eh-io]: ../../../libs/event-horizon/src/sparkles/event_horizon/io.d
[eh-channel]: ../../../libs/event-horizon/src/sparkles/event_horizon/channel.d
[eh-cross]: ../../../libs/event-horizon/src/sparkles/event_horizon/cross_channel.d
[eh-jobs]: ../../../libs/event-horizon/src/sparkles/event_horizon/job_queue.d
[eh-cause]: ../../../libs/event-horizon/src/sparkles/event_horizon/cause.d
[eh-clock]: ../../../libs/event-horizon/src/sparkles/event_horizon/clock.d
[hue-format]: ../../../apps/hue/src/format_preview.d
[ui-host]: ../../../libs/ui-app/src/sparkles/ui_app/host.d
