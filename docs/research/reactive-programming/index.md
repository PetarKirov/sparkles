# Reactive Programming: Streams, Signals and FRP

A breadth-first survey of **reactive programming**: push-based streams, pull-based
effectful streams, fine-grained signals, classical and transactional FRP, and the
synchronous languages. It is framed against one concrete engineering goal: a
reactive library for Sparkles built on [`event-horizon`][eh-docs], the repository's
completion-based event loop with structured scopes, fibers and a single-value lazy
[`Effect`][eh-effect]. Every deep-dive answers the same questions in the same order,
and every one ends by writing **the worked pipeline** in its own idiom, so the
twenty answers can be laid side by side in the [comparison][comparison].

The worked pipeline is the first consumer, taken from the
[fileset explorer][fsx-spec]: a query field → debounce _N_ ms, with _N_ adjustable
at runtime → hash a file set on a worker thread, a newer query cancelling the
running hash → show the result. A toggle switches the whole pipeline on and off, and
switching it off cancels a pending debounce and an in-flight hash.

This survey answers ten questions:

1. **What are the models, and what does each one optimise for?** — the
   [master catalog](#master-catalog) and the [taxonomy](#taxonomy).
2. **How is "latest wins" expressed, and does cancelling wait for the cancelled
   work?** — [comparison § Latest wins and the cancel-wait split][cmp-latest].
3. **Is debounce a primitive, and can its duration change while it runs?** —
   [comparison § Debounce][cmp-debounce].
4. **Where does state live, and how do cells differ from event streams?** —
   [comparison § Cells and streams][cmp-cells].
5. **What does one frame see?** — [comparison § The frame][cmp-frame].
6. **How is time made deterministic in tests?** — [comparison § Virtual time][cmp-time].
7. **What does `event-horizon` already have, and what is missing?** —
   [comparison § Delta][cmp-delta].
8. **How do mature libraries structure and name their API, and what did they
   later regret?** — [comparison § API structure and naming][cmp-api].
9. **How do tests script inputs and assert outputs, cancellation included?** —
   [testing], with three theme pages behind it.

10. **How do UI frameworks let components be written over their reactive core,
    and what does keeping a retained tree in sync cost?** — [solid-components]
    (JSX compiled to templates and holes, run-once components, the custom-renderer
    contract) and [flutter] (immutable widgets rebuilt over retained element and
    render trees, identity-based skipping). The [UI component authoring][ui-authoring]
    study turns them into `sparkles:ui`'s decisions, measured across seven
    builders.

The shared vocabulary is defined once in [concepts]; the deep-dives use it.

**Last reviewed:** November 23, 2026

---

## Master catalog

| Subject                   | Ecosystem       | School                           | Versions surveyed                                                                      | Latest-wins primitive                               | Link                      |
| ------------------------- | --------------- | -------------------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------- | ------------------------- |
| RxJS                      | TypeScript      | push streams                     | 7.8.2; 9.0.0-beta.0 (`master`, unpublished)                                            | `switchMap`                                         | [rxjs]                    |
| Effect `Stream`           | TypeScript      | pull streams on fibers           | `effect@4.1.5`; `effect@3.22.5`                                                        | `Stream.switchMap` (v4), `flatMap` `switch`         | [effect-ts]               |
| Kotlin Flow               | Kotlin          | suspending streams               | kotlinx.coroutines 1.11.0                                                              | `transformLatest` / `flatMapLatest`                 | [kotlin-flow]             |
| Swift Async Algorithms    | Swift           | pull streams (async iterators)   | `main` @ `088f92a3` (2026-11-18)                                                       | `flatMapLatest` (proposed); `.task(id:)`            | [swift-async-algorithms]  |
| Rust streams and signals  | Rust            | poll streams + signals           | futures 0.3.34; tokio 1.54.1; futures-signals 0.3.34                                   | `map_future` (futures-signals); `select!` loop      | [rust-streams]            |
| fs2                       | Scala           | pull streams on fibers           | fs2 3.16; cats-effect 3.7                                                              | `switchMap`                                         | [fs2]                     |
| Solid 2.0 signals         | TypeScript      | push-pull signals                | `solid-js@2.0.3`                                                                       | async memo (stale result discarded)                 | [solid-signals]           |
| TC39 Signals              | JavaScript      | push-pull signals (standard)     | Stage 1; `signal-polyfill@0.2.3`                                                       | none (framework code)                               | [tc39-signals]            |
| Angular signals           | TypeScript      | push-pull signals + resources    | 22.4.0-next.0                                                                          | `resource` / `rxResource`                           | [angular-signals]         |
| Jetpack Compose runtime   | Kotlin          | snapshot state + keyed effects   | `compose.runtime` 1.14.0-alpha02                                                       | `LaunchedEffect(key)`                               | [jetpack-compose]         |
| Sodium                    | Java, C#        | transactional FRP                | `master` @ `03d0c0fe` (2026-09-28)                                                     | `switchS` (streams); .NET `MapAsync`                | [sodium]                  |
| Elm                       | Elm             | model-update loop (ex-FRP)       | `elm/core` 1.0.5; `elm-lang/core` 3.0.0 (signals)                                      | none (sequence number, result discarded)            | [elm]                     |
| Esterel and Céu           | Esterel, Céu, C | synchronous languages            | Esterel v5.91; Céu v0.30; HipHop.js                                                    | `par/or`, `abort … when`, `watching`                | [synchronous-languages]   |
| C++ senders and receivers | C++             | single-value operations + scopes | C++26 draft (P2300R10, P3149R11, P2079R10, P3552R3); stdexec @ `f27cd131` (2026-11-21) | none (`counting_scope` + a stop source per request) | [cpp-senders-receivers]   |
| Rx.NET, Ix.NET, AsyncRx   | C#              | push streams (+ pull Ix)         | `System.Reactive` 7.0.0; `System.Linq.Async` 7.0.1; AsyncRx 6.0.0-alpha (unreleased)   | `Select(f).Switch()`                                | [rx-dotnet]               |
| Pekko Streams             | Scala, Java     | demand-driven dataflow graphs    | `main` @ `df133f7d` (2026-11-23; `v2.0.0-RC1`)                                         | `switchMap` (since 1.2.0)                           | [pekko-streams]           |
| Clojure transducers       | Clojure, Java   | source-independent transformers  | Clojure @ `92ce2a85` (2026-11-23); core.async 1.9.865; JDK `Gatherer` (24)             | none (hand-written `go-loop`)                       | [clojure-transducers]     |
| Reflex                    | Haskell         | higher-order push-pull FRP       | reflex 0.10.0.0 @ `f443526b` (2026-11-22); reflex-dom @ `de31ceff`                     | `switchHold`, `switchDyn` (no cancellation)         | [reflex]                  |
| Yampa                     | Haskell         | arrowized FRP (signal functions) | Yampa 0.15.1; dunai 0.14.2; rhine 1.8                                                  | `rSwitch` (the old machine is no longer stepped)    | [yampa]                   |
| Jane Street Incremental   | OCaml           | self-adjusting computation       | `master` @ `371fc83a` (2026-11-03); Salsa 0.28.6; Bonsai @ `3a02b573`                  | `bind` (invalidates the old subgraph)               | [jane-street-incremental] |

> [!NOTE]
> Two subjects sit next to existing catalogs rather than inside them. Effect, ZIO
> and cats-effect as _effect systems_ are covered by
> [algebraic effects][alg-effects] ([Effect][alg-effect-ts], [ZIO][alg-zio],
> [cats-effect][alg-cats]); this tree covers their streaming halves. Incremental
> recomputation is covered twice: as a parsing technique by
> [parsing § incremental][incremental], and as a reactive value graph by
> [jane-street-incremental] (with Adapton, Salsa and Bonsai as related designs).

---

## Taxonomy

### By evaluation model

| Model                               | Who sends the next value                                                  | Subjects                                                                                                 |
| ----------------------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| **Push**                            | the producer calls the consumer                                           | [rxjs], [rx-dotnet], [sodium], [kotlin-flow] (with suspension as backpressure)                           |
| **Pull**                            | the consumer asks for the next value (or chunk)                           | [effect-ts], [fs2], [swift-async-algorithms], [rust-streams], [rx-dotnet] (Ix, `IAsyncEnumerable`)       |
| **Demand-driven graph**             | downstream signals demand, upstream pushes up to it (Reactive Streams)    | [pekko-streams]                                                                                          |
| **Push-pull**                       | invalidation is pushed, values are pulled when read                       | [solid-signals], [tc39-signals], [angular-signals], [jetpack-compose] (snapshot read-tracking), [reflex] |
| **Process-independent transformer** | whichever process applies it (reduce, sequence, channel) pushes into it   | [clojure-transducers] (and Java `Gatherer`)                                                              |
| **Sampled dataflow**                | the driver steps every signal function once per sample, with a time delta | [yampa]                                                                                                  |
| **Explicit stabilisation**          | inputs are set freely; one `stabilize` call propagates in height order    | [jane-street-incremental]                                                                                |
| **Model-update loop**               | the runtime feeds one message at a time to a pure `update`                | [elm]                                                                                                    |
| **Synchronous reaction**            | an input event starts one run-to-completion reaction of all trails        | [synchronous-languages]                                                                                  |
| **Single-value operations**         | a sender completes once, on one of three channels (value, error, stopped) | [cpp-senders-receivers] (streams only as experimental sequence senders)                                  |

### By what a cancel does to running work

| Cancel                                           | Subjects                                                                                                                                                                                                                                                         |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Waits** until the cancelled work finished      | [kotlin-flow] (`transformLatest` joins), [effect-ts] (`switchMap` awaits the old inner's scope), [fs2] (`switchMap` awaits finalizers), Salsa in [jane-street-incremental] (a write waits for every other handle), Java `mapConcurrent` in [clojure-transducers] |
| **Does not wait**; stale output filtered         | [rxjs], [rx-dotnet] (AsyncRx awaits, unreleased), [pekko-streams] (`switchMap`; `mapAsync` futures keep running), [swift-async-algorithms], [rust-streams], [jetpack-compose], [angular-signals], [tc39-signals], [sodium] (.NET `MapAsync`)                     |
| **Never cancels**; only discards the result      | [solid-signals] (cleanup is the run's business), [elm] (stale timers still fire), [reflex] (IO "cannot be undone"), [clojure-transducers] (core.async has no cancel)                                                                                             |
| **Nothing to cancel**: pure graph, no async      | [yampa] (a switched-out machine is not stepped again), [jane-street-incremental] (an invalidated node is not recomputed)                                                                                                                                         |
| **Lexical abortion** in the same reaction        | [synchronous-languages] (threads: flagged, reaped later)                                                                                                                                                                                                         |
| **Joins in composites, forgets in spawned work** | [cpp-senders-receivers] (`when_all` and `exec::when_any` join; a spawned request joins only when chained on its predecessor's `spawn_future`)                                                                                                                    |

### By where time comes from

| Source of time                                      | Subjects                                                                                                                                              |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| An injectable scheduler or clock service            | [rxjs] 7.x, [rx-dotnet] (an `IScheduler` overload per operator), [effect-ts], [swift-async-algorithms] (`Clock` generic), [sodium] (Java/.NET timers) |
| The dispatcher or runtime (virtual time global)     | [kotlin-flow], [fs2] (`TestControl`), [rust-streams] (tokio `pause`), [jetpack-compose], [pekko-streams] (a process-wide scheduler swap)              |
| Platform timers (`setTimeout`), patched in tests    | [rxjs] 9.x, [solid-signals], [tc39-signals], [angular-signals], [elm], [reflex] (`forkIO` + sleep), [clojure-transducers] (core.async `timeout`)      |
| An input event the host feeds                       | [synchronous-languages], [yampa] (`dt` per sample; `embed` in tests), [jane-street-incremental] (`Clock.advance_clock`)                               |
| None in the standard; a `timed_scheduler` extension | [cpp-senders-receivers] (stdexec `schedule_after`/`schedule_at`)                                                                                      |

---

## Milestones

| Date       | Milestone                                                                                            | Link                      |
| ---------- | ---------------------------------------------------------------------------------------------------- | ------------------------- |
| 1992       | Berry & Gonthier publish the semantics of Esterel                                                    | [synchronous-languages]   |
| 1997       | Elliott & Hudak's _Functional Reactive Animation_ (Fran), the first FRP                              | [yampa]                   |
| 2002       | Nilsson, Courtney & Peterson, _Functional Reactive Programming, Continued_: arrowized FRP (Yampa)    | [yampa]                   |
| 2012       | Czaplicki's thesis _Elm: Concurrent FRP for Functional GUIs_                                         | [elm]                     |
| 2013       | Céu at SenSys: structured synchronous reactive programming with lexical abortion                     | [synchronous-languages]   |
| 2014-08-06 | "Transducers are Coming": transformations separated from sources and sinks                           | [clojure-transducers]     |
| 2015-07-18 | Jane Street's "Introducing Incremental"                                                              | [jane-street-incremental] |
| 2016-05-10 | Elm 0.17, "A Farewell to FRP", replaces signals with The Elm Architecture                            | [elm]                     |
| 2016       | _Functional Reactive Programming_ (Blackheath & Jones) documents Sodium's transactions               | [sodium]                  |
| 2022-09-07 | Akka moves to the Business Source License; Apache Pekko forks the Apache-2.0 line                    | [pekko-streams]           |
| 2024-04    | TC39 Signals reaches Stage 1                                                                         | [tc39-signals]            |
| 2024-06    | P2300R10 `std::execution` adopted for C++26 (date from the paper, not plenary minutes)               | [cpp-senders-receivers]   |
| 2025-02-21 | RxJS 7.8.2, the current stable line                                                                  | [rxjs]                    |
| 2025-06    | P3149 `async_scope`, P2079 parallel scheduler and P3552 `task` adopted (dates from the papers)       | [cpp-senders-receivers]   |
| 2026-11-16 | Solid 2.0.0: async-first derivations, the `@solidjs/signals` core                                    | [solid-signals]           |
| 2026-11-18 | RxJS 9.0.0-beta.0 on `master`: the web-platform `Observable`, `AbortSignal`, no schedulers           | [rxjs]                    |
| 2026-11-20 | Effect 4.1.5: v4 stable on the canonical repository, with `Stream.switchMap` and `effect/reactivity` | [effect-ts]               |

---

## Suggested reading paths

- **I am designing the Sparkles reactive library.** Read [concepts], then
  [comparison] end to end, then the three deep-dives closest to `event-horizon`'s
  model: [kotlin-flow] (structured concurrency, cancel-and-join), [fs2]
  (finalizer-ordered `switchMap`, `TestControl`) and [jetpack-compose] (keyed
  effects in a per-frame UI). Then [cpp-senders-receivers], the closest analogue
  to `event-horizon`'s single-value `Effect` and scopes.
- **I want the case against a stream library.** [elm], then
  [synchronous-languages] (latest-wins as control flow), then
  [comparison § Delta][cmp-delta].
- **I want the signal algorithm.** [tc39-signals] (the smallest specification),
  [angular-signals] (the graph the polyfill forked), [solid-signals] (async in the
  graph), then [sodium] (transactions).
- **I want the operator libraries.** [rxjs], [rx-dotnet], [effect-ts],
  [kotlin-flow], [swift-async-algorithms], [rust-streams], [fs2], [pekko-streams].
- **I am naming the API.** [comparison § API structure and naming][cmp-api], then
  the `API structure and naming` subsection of [rx-dotnet] (the most-cited
  naming regret), [pekko-streams] (blueprints and the cost of a second type
  channel), [clojure-transducers] (operators written once for every source) and
  [reflex] (affix families and capability tags).
- **I am designing component authoring for `sparkles:ui`.** [solid-components]
  (what a compiler can split into static template and dynamic holes, and what
  run-once components cost), then [flutter] (rebuilding descriptions every frame,
  keys, and layout and repaint boundaries), then [jetpack-compose] (positional
  identity in a per-frame UI), then the [UI component authoring][ui-authoring]
  study (the decided builder: lazy variadic children, built top-down).
- **I want FRP without a garbage collector.** [yampa] (signal functions as Mealy
  machines), [jane-street-incremental] (explicit stabilisation, a frame-shaped
  step), then [reflex] (what a GC-driven teardown costs).

---

## Sources

Every deep-dive carries its own `Sources` section, pinned to the commits listed in
the [master catalog](#master-catalog). The Sparkles side of the comparison cites the
`event-horizon` sources and specification directly:

- [`event-horizon` documentation][eh-docs] and [specification][eh-spec]
- [`effect.d`][eh-effect], [`scope_.d`][eh-scope], [`clock.d`][eh-clock],
  [`channel.d`][eh-channel], [`cross_channel.d`][eh-cross], [`schedule.d`][eh-schedule],
  [`job_queue.d`][eh-jobs]
- The fileset explorer's [specification][fsx-spec]

<!-- References -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md
[cmp-latest]: ./comparison.md#latest-wins-and-the-cancel-wait-split
[cmp-debounce]: ./comparison.md#debounce
[cmp-cells]: ./comparison.md#cells-and-streams
[cmp-frame]: ./comparison.md#the-frame
[cmp-time]: ./comparison.md#virtual-time
[cmp-delta]: ./comparison.md#delta-what-event-horizon-has-and-what-is-missing
[cmp-api]: ./comparison.md#api-structure-and-naming
[testing]: ./testing.md
[rx-dotnet]: ./rx-dotnet.md
[pekko-streams]: ./pekko-streams.md
[clojure-transducers]: ./clojure-transducers.md
[reflex]: ./reflex.md
[yampa]: ./yampa.md
[jane-street-incremental]: ./jane-street-incremental.md
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
[solid-components]: ./solid-components.md
[flutter]: ./flutter.md
[ui-authoring]: ../ui-authoring/index.md
[sodium]: ./sodium.md
[elm]: ./elm.md
[synchronous-languages]: ./synchronous-languages.md
[cpp-senders-receivers]: ./cpp-senders-receivers.md
[alg-effects]: ../algebraic-effects/index.md
[alg-effect-ts]: ../algebraic-effects/typescript-effect.md
[alg-zio]: ../algebraic-effects/scala-zio.md
[alg-cats]: ../algebraic-effects/scala-cats-effect.md
[incremental]: ../parsing/theory/incremental.md
[fsx-spec]: ../../specs/fileset-explorer/SPEC.md
[eh-docs]: ../../libs/event-horizon/index.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[eh-effect]: ../../../libs/event-horizon/src/sparkles/event_horizon/effect.d
[eh-scope]: ../../../libs/event-horizon/src/sparkles/event_horizon/scope_.d
[eh-clock]: ../../../libs/event-horizon/src/sparkles/event_horizon/clock.d
[eh-channel]: ../../../libs/event-horizon/src/sparkles/event_horizon/channel.d
[eh-cross]: ../../../libs/event-horizon/src/sparkles/event_horizon/cross_channel.d
[eh-schedule]: ../../../libs/event-horizon/src/sparkles/event_horizon/schedule.d
[eh-jobs]: ../../../libs/event-horizon/src/sparkles/event_horizon/job_queue.d
