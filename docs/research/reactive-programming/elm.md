# Elm: signals, then The Elm Architecture (Elm)

The language that shipped first-order FRP to the browser and then removed it: Elm 0.17 (2016-05-10) deleted `Signal` and replaced it with The Elm Architecture, a single `Model`/`update`/`view` loop whose effects are data (`Cmd`, `Sub`) that the runtime interprets. It is the strongest case on record that an application does not need a stream library.

| Field             | Value                                                                                                                                                                                                                                                                                        |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Elm (pure, strict, ML-family; compiles to JavaScript)                                                                                                                                                                                                                                        |
| License           | BSD-3-Clause (`elm.json` of [`elm/core`][core-json], [`elm/time`][time-json], [`elm/browser`][browser-json], [`elm/http`][http-json])                                                                                                                                                        |
| Repository        | [elm/core][core-platform] (runtime kernel), [elm/time][time-elm], [elm/browser][browser-js], [elm/http][http-elm]; website and news posts in [elm/elm-lang.org][farewell]; pre-0.17 signals in [elm-lang/core 3.0.0][legacy-signal]                                                          |
| Documentation     | [guide.elm-lang.org][guide] ([The Elm Architecture][guide-arch], [Commands and Subscriptions][guide-effects], [Time][guide-time]); [package.elm-lang.org][pkg-core]                                                                                                                          |
| Category          | Model-update loop with managed effects (formerly: discrete, first-order, push-based FRP)                                                                                                                                                                                                     |
| Versions surveyed | `elm/core` **1.0.5** (commit `65cea00afa0d`, 2021-04-12); `elm/time` 1.0.0 (`dc3b75b7366e`, 2018-08-29); `elm/browser` 1.0.2 (`1d28cd625b3c`, 2019-11-06); `elm/http` 2.0.0 (`81b6fdc67d8e`, 2019-11-08); legacy `elm-lang/core` **3.0.0** (`09f3dd2b11f3`, 2015-11-22) for the `Signal` era |
| Core abstraction  | `update : msg -> model -> ( model, Cmd msg )` plus `subscriptions : model -> Sub msg`; a `Task x a` is a lazy, cancellable description of one asynchronous step, run by a cooperative `Process` scheduler                                                                                    |

> [!NOTE]
> Elm is the only subject in this survey that is a _retreat_ from FRP rather than an
> instance of it. Read it as the counter-argument: for the sparkles design it asks
> whether the reactive library is needed at all, given that every sparkles app
> already owns a frame loop that rebuilds its widget tree from state — which is
> what `view : Model -> Html Msg` is.

---

## Overview

### What it solves

Elm began as Evan Czaplicki's senior thesis, [_Elm: Concurrent FRP for Functional GUIs_][thesis] (2012-03-30), which set out to fix two efficiency problems of earlier FRP — the abstract names them _"global delays and needless recomputation"_. Elm 0.1–0.16 exposed that design as `Signal a`: a static graph of `map`/`foldp`/`merge` nodes rooted at input signals such as `Mouse.position`, with `main : Signal Html` at the sink.

As idiomatic Elm converged on one shape — a single `foldp` over a merged signal of actions feeding a `view` — the graph became plumbing. The [start-app][start-app] package hid it, and Elm 0.17 deleted it. What remained solves the same problem (interactive programs over time-varying input) with three pure functions and a runtime that owns every side effect: HTTP, timers, sockets, animation frames.

### Design philosophy

The release post, [_A Farewell to FRP_][farewell] (source [`pages/news/farewell-to-frp.elm`][farewell], published at [elm-lang.org/news/farewell-to-frp][farewell-web], dated `Skeleton.Date 2016 5 10`), states the removal bluntly:

> _"To put this in more alarmist terms, **everything related to signals has been replaced with something simpler and nicer.**"_

and its motive is pedagogical, not semantic:

> _"I think anyone who has taught Elm recently would agree that signals are one of the few stumbling blocks left. They made Elm easier than its peers, but they did not make Elm *easy*."_

The post credits concurrency, not streams, as the real foundation — _"Elm is just a functional language that takes concurrency very seriously"_ — tracing it to tasks in 0.15 ([`0.15.elm`][news-015], 2015-04-20, _"Asynchrony with Tasks"_) and a scheduler that _"[takes] some basic insights from the BEAM VM used by Erlang and Elixir."_ It closes by noting that the thesis had more in common with synchronous languages than with FRP: _"I might argue that Elm was *never* about FRP."_ (compare [synchronous languages][sync]).

The managed-effects principle is restated in the module docs of both effect types, [`Platform/Cmd.elm`][core-cmd] and [`Platform/Sub.elm`][core-sub]:

> _"Elm has **managed effects**, meaning that things like HTTP requests or writing to disk are all treated as *data* in Elm. When this data is given to the Elm runtime system, it can do some “query optimization” before actually performing the effect."_

The guide records the architecture's reach: _"projects like Redux have been inspired by The Elm Architecture"_ ([guide][guide-arch]); Go's [Bubble Tea][bubbletea] is a direct port of the same `Init`/`Update`/`View` triple with `tea.Cmd`.

---

## How it works

### Before 0.17: the signal graph

The legacy `Signal` module ([`src/Signal.elm`][legacy-signal] at 3.0.0) exports exactly `merge`, `mergeMany`, `map`…`map5`, `constant`, `dropRepeats`, `filter`, `filterMap`, `sampleOn`, `foldp`, and the `Mailbox`/`Address` pair; time-based operators live in [`src/Time.elm`][legacy-time] (`every`, `fps`, `fpsWhen`, `timestamp`, `delay`, `since`). The thesis forbids `Signal (Signal a)` by a two-level type system so the graph is fixed at startup:

> _"Imagine if a stateful signal – dependent on mouse inputs – was switched out of the Elm program. Should it still update on mouse inputs? Should it only update when it is in the program? When working directly with signals, neither answer is pleasant. Elm opts to avoid this behavior by ruling out switching."_ ([thesis][thesis] §3.2)

Propagation is a _global event dispatcher_: every event is broadcast to **every** input node, and nodes that did not change forward a "no change" message so downstream nodes can skip recomputation (thesis §4.2). The shipped runtime is literally that: in [`Native/Signal.js`][legacy-native], `input`'s `notify` computes `var update = targetId === node.id;` and calls `broadcastToKids(node, timestamp, update)` regardless. The thesis's `async` primitive (run a subgraph concurrently, unsynchronised with the rest) does not appear in the 3.0.0 `Signal` exports — the JavaScript runtime was single-threaded.

### After 0.17: one loop, two kinds of effect data

A program is three functions ([`Platform.elm`][core-platform]):

```elm
worker
  : { init : flags -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }
  -> Program flags model msg
```

(`Browser.element` adds `view : model -> Html msg`.) The whole runtime loop is one closure in [`Elm/Kernel/Platform.js`][k-platform]:

```ts
function sendToApp(msg, viewMetadata) {
  var pair = A2(update, msg, model);
  stepper((model = pair.a), viewMetadata);
  _Platform_enqueueEffects(managers, pair.b, subscriptions(model));
}
```

Every message — click, timer tick, HTTP reply — runs `update`, hands the new model to the view `stepper`, and then hands **both** the returned `Cmd` bag **and a freshly computed `subscriptions model`** to the effect managers. `Cmd`/`Sub` values are trees of `LEAF`/`NODE`/`MAP` "bags"; `_Platform_dispatchEffects` walks them, groups leaves by their home effect manager, and `rawSend`s each manager its list. Effects are queued (`_Platform_effectsQueue`) so a synchronous command issued from `init` cannot overtake the batch that produced it — a fix the source comment ties to `elm/core#980`.

An **effect manager** is a long-lived `Process` with `init`, `onEffects` (receive this round's cmds/subs), and `onSelfMsg` (receive its own timer/socket events). `Task` is one: `onEffects` spawns one process per `Perform` command, whose last step is `Platform.sendToApp router` ([`Task.elm`][core-task] `spawnCmd`). Writing new managers is deliberately closed off — [`Platform.elm`][core-platform]: _"An extremely tiny portion of library authors should ever write effect managers. Fundamentally, Elm needs maybe 10 of them total."_ (Since 0.19 the compiler accepts `effect module` only in core-team packages — _unverified here; not checked against the compiler source_.)

### Tasks and processes

`Task x a` is a data structure built by `_Scheduler_succeed`/`fail`/`binding`/`andThen`/`onError`/`receive` ([`Scheduler.js`][k-scheduler]). A `BINDING` wraps a JavaScript callback and may return a kill function; [`Process.sleep`][k-process] is the canonical one:

```ts
function _Process_sleep(time) {
  return __Scheduler_binding(function (callback) {
    var id = setTimeout(function () {
      callback(__Scheduler_succeed(__Utils_Tuple0));
    }, time);

    return function () {
      clearTimeout(id);
    };
  });
}
```

[`Process.elm`][core-process] exports `spawn : Task x a -> Task y Id`, `sleep : Float -> Task x ()`, and `kill : Id -> Task x ()`, documented as _"The `kill` function will force a process to bail on whatever task it is running. So if there is an HTTP request in flight, it will also abort the request."_ The Erlang-style `send`/mailbox API sketched under "Future Plans" in that module was never made public.

---

## Evaluation model

- **Push, eager, one value at a time.** An event becomes one `Msg`, `update` runs to completion, then effects dispatch. There is no lazy pull anywhere in the application model; `view` is a pure function of the model, recomputed (modulo `Html.Lazy` memoisation) after updates.
- **Glitch-free by construction.** There is one state value, not a graph of derived cells, so no observer can see a half-propagated state. The pre-0.17 runtime achieved glitch-freedom the expensive way — broadcasting every event to every input node with "no change" markers (above).
- **Batched to the frame for rendering only.** `_Browser_makeAnimator` in [`Browser.js`][browser-js] coalesces views: a non-synchronous model update sets `PENDING_REQUEST` and schedules one `requestAnimationFrame`, so ten messages in one frame cost ten `update`s but one `view`. `update` itself is never batched.
- **Cold vs hot.** Not applicable as such: a `Task` is cold (inert data until performed); a `Sub` is a standing _declaration_ the runtime makes hot while it is present and tears down when absent.

## Composition

The application composes through **data**, not operators. The whole surface is: `Cmd.batch`/`Cmd.map`/`Cmd.none`, `Sub.batch`/`Sub.map`/`Sub.none` (four functions each, [`Sub.elm`][core-sub]); `Task.map`…`map5`, `andThen`, `sequence`, `onError`, `mapError`, `perform`, `attempt` ([`Task.elm`][core-task]); `Process.spawn`/`sleep`/`kill`. There is no `debounce`, `switchMap`, `combineLatest`, `scan`, or `zip` — and none is needed, because:

- **Derived values** are ordinary functions of the model, computed in `view` (or cached in the model by `update`).
- **`scan`/`foldp`** _is_ `update`.
- **`merge`** is the `Msg` union type: every source is a constructor.
- **Concurrency of independent tasks** comes from separate `Cmd`s (each spawns its own process); `Task.map2` is _sequential_ — its doc warns _"`map2` does each task in order"_.

Contrast [RxJS][rxjs]'s ~115 operators: Elm moved every one of them into hand-written `update` branches.

## Time and scheduling

**Clocks.** Two sources: `Process.sleep` (one-shot `setTimeout`) and `Time.every` (periodic `setInterval`, [`Time.js`][k-time]); `Browser.Events.onAnimationFrame` ([`Events.elm`][browser-events]) for frame-locked work. `Time.every` is explicitly _"not for animation"_ ([`Time.elm`][time-elm]).

**Scheduler.** [`_Scheduler_enqueue`][k-scheduler] is a run-to-completion work queue; `_Scheduler_step` loops over a process's `root` until it reaches a `BINDING` (registers the JS callback and returns) or an empty `RECEIVE`. There is no step budget or yield counter in the surveyed source.

> [!WARNING]
> `Process.spawn`'s doc says _"if a task is taking too long, we will pause it at an
> `andThen` and switch over to other stuff."_ The surveyed `_Scheduler_step` does not
> do this: an `AND_THEN` node is pushed onto `proc.__stack` and stepping continues
> without yielding. Processes interleave only at bindings (timers, I/O). A long pure
> computation blocks the whole program — and Elm has no threads to move it to.

**Debounce** is not a library function; the idiom is a sequence number in the model:

```elm
QueryChanged q ->
    let seq = model.seq + 1 in
    ( { model | query = q, seq = seq }
    , Process.sleep model.debounceMs |> Task.perform (\_ -> Fire seq) )

Fire seq ->
    if seq == model.seq then ( model, runSearch model.query ) else ( model, Cmd.none )
```

Each keystroke starts a new `sleep` process; earlier timers are **not** cancelled — `Task.perform` routes through `spawnCmd`, which never returns the `Process.Id` to the application, so `update` has no handle to `kill`. Every stale timer still fires and costs one `update` call that the counter comparison discards. This is latest-wins by **discarding**, not by cancelling. The duration is read from the model when the `Cmd` is built, so it is trivially adjustable at runtime; an in-flight sleep keeps the duration it started with.

**A subscription-based variant** does get cancellation. `Time.every`'s manager ([`Time.elm`][time-elm] `onEffects`) keys its running timers by interval in a `Dict Float Platform.ProcessId` and `Dict.merge`s the new subscription list against it every round: intervals only in the new list are spawned, intervals only in the old one get `Process.kill id` (which runs `clearInterval`). Changing the interval in the model therefore kills the old timer and starts a new one on the next `update`; returning `Sub.none` kills it outright.

## Concurrency and cancellation

- **Latest-wins** is application code: a counter or request ID in the model, compared when the result arrives. Nothing stops the superseded work.
- **Real cancellation exists only inside effect managers.** `Process.kill` ([`Scheduler.js`][k-scheduler]) calls the root binding's `__kill` if the process is parked on one, sets `proc.__root = null`, and succeeds **immediately** — it does not wait, because the binding's abort (e.g. `clearTimeout`, `xhr.abort()`) is synchronous. `elm/http` exposes this as `Http.cancel : String -> Cmd msg` keyed by a `tracker` string: its manager keeps `reqs : Dict String Process.Id` and runs `Process.kill pid` on `Cancel tracker` ([`Http.elm`][http-elm]), whose binding sets `xhr.__isAborted = true; xhr.abort();` ([`Http.js`][k-http]). That is the only user-facing cancellation of in-flight work in the core packages.
- **Kill is not a structured cancel.** `_Scheduler_kill` only aborts a parked `BINDING` that returned a kill function; the binding's continuation (`proc.__root = newRoot; _Scheduler_enqueue(proc);`) does not check whether the process was killed, so a binding with no kill function can resume a killed process when its callback fires (read from source; no issue located). There is no parent/child relation between processes and no finaliser.
- **CPU-bound work** has no home in Elm. The hash in the worked pipeline must leave Elm through a `port` to a JavaScript Web Worker, and cancellation becomes the JavaScript side calling `worker.terminate()`.
- **Subscriptions as structured lifetime.** Because `subscriptions model` is re-evaluated after every `update`, a toggle gates any set of standing sources with `if model.on then ... else Sub.none`; the managers diff and tear down. This is the one place Elm's model gives structured, state-driven cancellation for free.

## Errors and completion

`Task x a` carries a typed error; `Task.perform` demands `Task Never a`, so an unhandled failure is a type error, and `Task.attempt` folds both outcomes into a `Result x a` message. There are no runtime exceptions in Elm code; failures are values in `Msg`. **Completion does not exist as a concept**: a `Sub` is present or absent, never "completed"; a `Cmd` delivers at most one message (or none, for fire-and-forget commands like `Cmd.none` or a port send). There is no "stream terminated with error" state to propagate — what would be an `onError` handler in [RxJS][rxjs] is a `case` branch in `update`.

## State and sharing

All state is one immutable `Model`; sharing is passing the model (or a field) to whichever `view` function needs it. There is no `BehaviorSubject`, no multicast, no ref-counted connection — a `Sub` requested by several components (e.g. two `Time.every 1000` leaves) is **deduplicated by the effect manager**: `addMySub` groups taggers per interval, so one `setInterval` fans out to all of them (`onSelfMsg`'s `tellTaggers`). Conflation is implicit in rendering (one `view` per animation frame) but not in `update`: every message is processed.

## Lifetime and ownership

The runtime owns every resource. A subscription lives exactly as long as some branch of `subscriptions model` returns it; WebSocket connections in 0.17 were _"opened if anyone is subscribed to it, and ... closed if no one needs it anymore"_ ([farewell][farewell]). A `Cmd`-spawned task's process ends when its task does. Leaks of the RxJS kind (a forgotten `unsubscribe`) are impossible in application code because there is nothing to unsubscribe — the cost is that the only owner is the model, so resource lifetime must be encoded as model state.

## Testing

`update` is a pure function: `update (Fire 3) { model | seq = 4 }` can be asserted directly with `elm-explorations/test`, and stale-result logic is the easiest part to test. `Cmd` is opaque, however — the [elm-program-test guide][ept-cmds] states _"Elm does not currently provide a way to inspect `Cmd` values to see which commands they represent."_ Its workaround is to make `update` return a user-defined `Effect` type, interpret it with `withSimulatedEffects`, and then drive virtual time with `advanceTime : Int -> ProgramTest model msg effect -> ProgramTest model msg effect`, which _"will cause any pending `Task.sleep`s to trigger if their delay has elapsed"_ ([`ProgramTest.elm`][ept-src]). A deterministic debounce test is therefore possible, but only after the application has been rewritten around an effect-description type. Separately, the Elm 0.18 debugger records and replays the exact `Msg` sequence of a session ([_The Perfect Bug Report_][news-018], 2016-11-14) — the payoff of routing every input through one queue.

## The worked pipeline

The CPU-bound hash cannot run in Elm, so it goes out a `port` to a Web Worker; everything else is TEA.

```elm
port module Main exposing (main)

port startHash : { id : Int, query : String } -> Cmd msg
port cancelHash : () -> Cmd msg
port hashDone : ({ id : Int, digest : String } -> msg) -> Sub msg

type alias Model =
    { query : String, debounceMs : Float, enabled : Bool
    , debounceSeq : Int  -- bumped by every keystroke and by toggling
    , hashId : Int       -- id of the only hash whose result we accept
    , result : Maybe String }

type Msg
    = QueryChanged String | IntervalChanged String | Toggled Bool
    | DebounceFired Int | HashDone { id : Int, digest : String }

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        QueryChanged q ->
            let seq = model.debounceSeq + 1 in
            ( { model | query = q, debounceSeq = seq }
            , if model.enabled then
                Process.sleep model.debounceMs |> Task.perform (\_ -> DebounceFired seq)
              else Cmd.none )

        IntervalChanged s ->
            ( { model | debounceMs = String.toFloat s |> Maybe.withDefault model.debounceMs }
            , Cmd.none )

        Toggled on ->
            ( { model | enabled = on, debounceSeq = model.debounceSeq + 1, hashId = model.hashId + 1 }
            , if on then Cmd.none else cancelHash () )

        DebounceFired seq ->
            if seq /= model.debounceSeq then ( model, Cmd.none )  -- stale timer: discard
            else
                let id = model.hashId + 1 in
                ( { model | hashId = id }, startHash { id = id, query = model.query } )

        HashDone r ->
            if r.id /= model.hashId then ( model, Cmd.none )     -- superseded hash: discard
            else ( { model | result = Just r.digest }, Cmd.none )

subscriptions : Model -> Sub Msg
subscriptions model =
    if model.enabled then hashDone HashDone else Sub.none
```

```ts
// JavaScript side: the only place the hash can actually be cancelled.
let worker: Worker | null = null;
app.ports.startHash.subscribe(({ id, query }) => {
  worker?.terminate(); // latest-wins: kill the running hash
  worker = new Worker('hash-fileset.js');
  worker.onmessage = e => app.ports.hashDone.send({ id, digest: e.data });
  worker.postMessage(query);
});
app.ports.cancelHash.subscribe(() => {
  worker?.terminate();
  worker = null;
});
```

**Trace** (debounce 300 ms):

1. **Keystroke during debounce.** `QueryChanged "ab"` at t=100 ms bumps `debounceSeq` 1→2 and spawns a second `sleep` process. The first timer (seq 1, started t=0) is _not_ cleared; at t=300 it fires `DebounceFired 1`, `update` sees `1 /= 2` and returns `Cmd.none`. At t=400 `DebounceFired 2` matches and issues `startHash { id = 1 }`. Cost: one wasted `setTimeout` and one wasted `update` per superseded keystroke.
2. **Keystroke during hash.** Hash 1 is running in the worker. `QueryChanged` starts a new debounce; until it fires, hash 1 keeps running. When `DebounceFired` matches, `startHash { id = 2 }` reaches JS, which `terminate()`s worker 1 and starts worker 2. Had hash 1 finished first, its `HashDone { id = 1 }` would be discarded by the `hashId` check. Cancellation of the running hash comes from JavaScript, not Elm; Elm only guarantees the stale answer is never shown.
3. **Interval change.** `IntervalChanged "800"` updates `debounceMs`. A sleep already in flight keeps its 300 ms; the next keystroke uses 800 ms. No timer is rescheduled because none is reachable.
4. **Toggle off.** `Toggled False` bumps both counters (so a pending `DebounceFired` and any in-flight `HashDone` are stale), sends `cancelHash ()` (the worker is terminated), and `subscriptions` now returns `Sub.none`, so the runtime unsubscribes the `hashDone` port. The pending `sleep` still fires and is discarded.

**Fit for a per-frame UI.** The shape maps directly onto a sparkles app: `Model` is the app state, `view` is the per-frame widget-tree rebuild, `Msg` is the input queue, and `wakeIn` is what `Process.sleep` compiles to. The misfit is cancellation: TEA guarantees _correctness_ of latest-wins (stale results are ignored) but not _economy_ (stale work keeps running unless an effect manager or the host can kill it). On `event-horizon`, where `sleep` and worker tasks are cancellable scope children, the counter pattern is a fallback, not a necessity.

## Strengths

- **Fewest concepts of any subject surveyed.** Three functions, two effect types, no operators; the release post estimates _"95% of code stays exactly the same"_ while signals, addresses and mailboxes disappeared.
- **Glitch-freedom and determinism for free.** One model, one message at a time; the debugger can export and replay a whole session.
- **State-driven resource lifetime.** `subscriptions model` makes "is this source active?" a pure function of state, and the managers' diff (`Dict.merge` in `Time.elm`) does setup/teardown — the toggle in the worked pipeline is one `if`.
- **Effects as data** make `update` trivially unit-testable and let managers deduplicate (one `setInterval` per distinct interval).
- **Influence.** Redux, Bubble Tea, and most "unidirectional data flow" frameworks descend from it.

## Weaknesses

- **No cancellation from application code.** `Task.perform` hides the `Process.Id`; `Process.kill` is reachable only from tasks you `spawn` yourself, and a spawned task cannot deliver a result to `update`. Latest-wins is discard-only.
- **Boilerplate.** Every operator RxJS provides becomes a `Msg` constructor, a model field (counter, timestamp, request ID) and an `update` branch; debounce alone needs two of each.
- **Opaque `Cmd`.** Tests must re-architect around an `Effect` type to observe or simulate effects.
- **No parallelism, no preemption.** The scheduler interleaves only at bindings despite the documentation's claim; CPU-bound work must exit through ports.
- **Closed extension point.** New effect managers are discouraged (and restricted to core packages since 0.19, unverified here), so new resource kinds (e.g. a cancellable worker) cannot get the `Http.cancel` treatment.
- **Every stale timer still runs `update`**, and `subscriptions` is re-evaluated and diffed after every message — cheap in practice, but O(subscriptions) per event.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                                                | Trade-off                                                                                               |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Remove `Signal` (0.17); one `update` loop                  | Signals were _"one of the few stumbling blocks left"_; `foldp` over merged actions was already the idiom | Lose declarative time operators (`delay`, `since`, `sampleOn`); every one is re-implemented in `update` |
| Forbid `Signal (Signal a)` (thesis)                        | Switching stateful `foldp` nodes in and out has no pleasant semantics                                    | No dynamic graphs; motivated the move to state-driven `subscriptions`                                   |
| Effects as data (`Cmd`, `Sub`) interpreted by managers     | "Query optimisation", deduplication, testability, replay                                                 | `Cmd` is opaque to user code and tests; new effect kinds need a manager                                 |
| `subscriptions : model -> Sub msg`, diffed every update    | Lifetime becomes a pure function of state; no manual unsubscribe                                         | Re-evaluation per message; diff granularity is the manager's key (`Time.every` keys on interval only)   |
| `Task.perform` hides the process `Id`                      | Commands are fire-and-forget data; nothing to leak or mismanage                                          | No cancellation of in-flight tasks; latest-wins is discard-by-counter                                   |
| `Process.kill` aborts a parked binding and returns at once | Single-threaded JS: the abort (`clearTimeout`, `xhr.abort`) is synchronous, so there is nothing to await | No structured cancellation, no finalisers, no parent/child scopes                                       |
| Cooperative scheduler, no worker threads                   | Determinism; JS is single-threaded                                                                       | CPU-bound work blocks the UI or must leave Elm through ports                                            |

## Sources

- [_A Farewell to FRP_ — source `pages/news/farewell-to-frp.elm`][farewell] · [published post][farewell-web]
- [Elm 0.15 _Asynchrony with Tasks_ — `pages/news/0.15.elm`][news-015] · [Elm 0.18 _The Perfect Bug Report_ — `pages/news/the-perfect-bug-report.elm`][news-018]
- [Czaplicki, _Elm: Concurrent FRP for Functional GUIs_ (thesis, 2012)][thesis] · [copy in the website repo][thesis-src]
- [Upgrading to 0.17 — `upgrade-docs/0.17.md`][upgrade-017]
- `elm/core` 1.0.5: [`Platform.elm`][core-platform] · [`Platform/Cmd.elm`][core-cmd] · [`Platform/Sub.elm`][core-sub] · [`Task.elm`][core-task] · [`Process.elm`][core-process] · [`Elm/Kernel/Platform.js`][k-platform] · [`Elm/Kernel/Scheduler.js`][k-scheduler] · [`Elm/Kernel/Process.js`][k-process]
- `elm/time` 1.0.0: [`Time.elm`][time-elm] · [`Elm/Kernel/Time.js`][k-time]
- `elm/browser` 1.0.2: [`Elm/Kernel/Browser.js`][browser-js] · [`Browser/Events.elm`][browser-events]
- `elm/http` 2.0.0: [`Http.elm`][http-elm] · [`Elm/Kernel/Http.js`][k-http]
- Legacy `elm-lang/core` 3.0.0: [`Signal.elm`][legacy-signal] · [`Time.elm`][legacy-time] · [`Native/Signal.js`][legacy-native]
- [guide.elm-lang.org][guide] — [The Elm Architecture][guide-arch] · [Commands and Subscriptions][guide-effects] · [Time][guide-time]
- [elm-program-test: testing `Cmd`s][ept-cmds] · [`ProgramTest.elm`][ept-src] (commit `195131b038ca`, 2026-02-18)
- Related: [RxJS][rxjs] · [Effect-TS][effect-ts] · [Sodium][sodium] · [Synchronous languages][sync] · [Bubble Tea][bubbletea] · [Concepts][concepts] · [Comparison][comparison] · [Index][index]

<!-- References -->

[farewell]: https://github.com/elm/elm-lang.org/blob/dc6062b356f8879b8f21c791da77bafdda5ab1db/pages/news/farewell-to-frp.elm
[farewell-web]: https://elm-lang.org/news/farewell-to-frp
[news-015]: https://github.com/elm/elm-lang.org/blob/dc6062b356f8879b8f21c791da77bafdda5ab1db/pages/news/0.15.elm
[news-018]: https://github.com/elm/elm-lang.org/blob/dc6062b356f8879b8f21c791da77bafdda5ab1db/pages/news/the-perfect-bug-report.elm
[thesis]: https://elm-lang.org/assets/papers/concurrent-frp.pdf
[thesis-src]: https://github.com/elm/elm-lang.org/blob/dc6062b356f8879b8f21c791da77bafdda5ab1db/static/assets/papers/concurrent-frp.pdf
[upgrade-017]: https://github.com/elm-lang/elm-platform/blob/bc771392655ec747fceb4acbe8eb9ad8b785cd23/upgrade-docs/0.17.md
[start-app]: https://github.com/evancz/start-app/tree/6f1fd8667288cd2c6abe412ba9f25fcfbf10f40e
[core-json]: https://github.com/elm/core/blob/65cea00afa0de03d7dda0487d964a305fc3d58e3/elm.json
[core-platform]: https://github.com/elm/core/blob/65cea00afa0de03d7dda0487d964a305fc3d58e3/src/Platform.elm
[core-cmd]: https://github.com/elm/core/blob/65cea00afa0de03d7dda0487d964a305fc3d58e3/src/Platform/Cmd.elm
[core-sub]: https://github.com/elm/core/blob/65cea00afa0de03d7dda0487d964a305fc3d58e3/src/Platform/Sub.elm
[core-task]: https://github.com/elm/core/blob/65cea00afa0de03d7dda0487d964a305fc3d58e3/src/Task.elm
[core-process]: https://github.com/elm/core/blob/65cea00afa0de03d7dda0487d964a305fc3d58e3/src/Process.elm
[k-platform]: https://github.com/elm/core/blob/65cea00afa0de03d7dda0487d964a305fc3d58e3/src/Elm/Kernel/Platform.js
[k-scheduler]: https://github.com/elm/core/blob/65cea00afa0de03d7dda0487d964a305fc3d58e3/src/Elm/Kernel/Scheduler.js
[k-process]: https://github.com/elm/core/blob/65cea00afa0de03d7dda0487d964a305fc3d58e3/src/Elm/Kernel/Process.js
[time-json]: https://github.com/elm/time/blob/dc3b75b7366e59b99962706f7bf064d3634a4bba/elm.json
[time-elm]: https://github.com/elm/time/blob/dc3b75b7366e59b99962706f7bf064d3634a4bba/src/Time.elm
[k-time]: https://github.com/elm/time/blob/dc3b75b7366e59b99962706f7bf064d3634a4bba/src/Elm/Kernel/Time.js
[browser-json]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/elm.json
[browser-js]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Elm/Kernel/Browser.js
[browser-events]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Browser/Events.elm
[http-json]: https://github.com/elm/http/blob/81b6fdc67d8e5fb25644fd79e6b0edbe2e14e474/elm.json
[http-elm]: https://github.com/elm/http/blob/81b6fdc67d8e5fb25644fd79e6b0edbe2e14e474/src/Http.elm
[k-http]: https://github.com/elm/http/blob/81b6fdc67d8e5fb25644fd79e6b0edbe2e14e474/src/Elm/Kernel/Http.js
[legacy-signal]: https://github.com/elm-lang/core/blob/09f3dd2b11f34987bf6b32201fd1899baff5d646/src/Signal.elm
[legacy-time]: https://github.com/elm-lang/core/blob/09f3dd2b11f34987bf6b32201fd1899baff5d646/src/Time.elm
[legacy-native]: https://github.com/elm-lang/core/blob/09f3dd2b11f34987bf6b32201fd1899baff5d646/src/Native/Signal.js
[pkg-core]: https://package.elm-lang.org/packages/elm/core/latest/
[guide]: https://guide.elm-lang.org/
[guide-arch]: https://guide.elm-lang.org/architecture/
[guide-effects]: https://guide.elm-lang.org/effects/
[guide-time]: https://guide.elm-lang.org/effects/time.html
[ept-cmds]: https://elm-program-test.netlify.app/cmds.html
[ept-src]: https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest.elm
[rxjs]: ./rxjs.md
[effect-ts]: ./effect-ts.md
[sodium]: ./sodium.md
[sync]: ./synchronous-languages.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[bubbletea]: ../tui-libraries/bubbletea.md
