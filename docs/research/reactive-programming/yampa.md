# Yampa (Haskell)

The reference _arrowized_ FRP library: a program is one signal function `SF a b`, built from arrow combinators and switches and stepped by an external driver with an explicit time delta. Signals are never first-class values.

| Field             | Value                                                                                                                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Haskell (GHC 7.6.3 to 9.x; MicroHs since 0.15.1)                                                                                                                                                |
| License           | BSD-3-Clause ([`yampa/LICENSE`][y-license], [`Yampa.cabal`][y-cabal])                                                                                                                           |
| Repository        | [ivanperez-keera/Yampa][y-repo], surveyed at `9dda030` (2026-10-21). Relatives: [ivanperez-keera/dunai][d-repo] at `407ff00` (2026-10-21), [turion/rhine][r-repo] at `698b693` (2026-09-21)     |
| Documentation     | [Hackage: `Yampa`][hackage], [Haskell wiki][wiki], the module headers of [`FRP.Yampa`][y-top]                                                                                                   |
| Category          | Arrowized FRP (AFRP): synchronous dataflow over sampled continuous and discrete time                                                                                                            |
| Versions surveyed | Yampa `0.15.1` (2026-10-21), dunai `0.14.2` / bearriver `0.15.1`, rhine `1.8`                                                                                                                   |
| Core abstraction  | `SF a b`, a _signal function_: conceptually `Signal a -> Signal b`, operationally a Mealy machine that takes `(DTime, a)` and returns `(b, next SF)`                                            |
| Lineage           | Fran (1997), then FRP Continued / AFRP (2002), then Yampa, then dunai/BearRiver (monadic stream functions, 2016), then Rhine (type-level clocks, 2018). See [Related designs](#related-designs) |

> [!NOTE]
> Yampa has no notion of asynchrony, no scheduler, and no I/O inside a signal function. Every spine section below that asks about threads, cancellation or errors gets the answer "outside, in the driver". That absence is the main finding. Yampa is the cleanest model in the survey of a _frame-ticked_ reactive core, and it shows how much of the [worked pipeline](#the-worked-pipeline) still has to live outside such a core.

---

## Overview

### What it solves

Yampa programs _hybrid_ systems: games, robots, synthesizers, simulations, where continuously varying quantities (positions, integrals, time) mix with discrete occurrences (clicks, collisions, messages). The module header of [`FRP.Yampa`][y-top] states the division of labour:

> _"A Yampa network is structured as a Signal Function: a pure transformation from a time-varying input to that produces a time-varying output. … The first two aspects [obtaining inputs, consuming outputs] lie outside Yampa, and they determine the backends that your system uses. Yampa is backend-agnostic."_

The user writes one pure `SF Input Output`. A backend (SDL, GLFW, Gloss, HTML canvas, Android/iOS through Keera Studios' commercial games, per [`README.md`][y-readme]) senses input once per frame, steps the SF with the frame's `dt`, and actuates the output. That is the same shape as a sparkles app's frame loop.

### Design philosophy

The defining decision dates from [_Functional Reactive Programming, Continued_][frp-continued] (Nilsson, Courtney, Peterson, Haskell Workshop 2002), which recast [Fran][fran]'s first-class behaviours as arrows:

> _"In order to ensure an efficient implementation (one that is free of time and space leaks), signals (time-varying values) are not first class entities in AFRP, unlike the signal functions operating on them. This is one of the most substantial design differences between AFRP and earlier versions of FRP, for example Fran. … this design carries with it an apparent loss in expressive power … Continuation-based switching and dynamic collections of signal functions give AFRP similar expressive power, but without compromising operational aspects."_

And, from the same paper:

> _"We reiterate that this is just a conceptual model: only signal functions are first class entities; signals only exist indirectly, through the signal functions. In particular, there is no type `Signal` in AFRP."_

A first-class `Behavior a` in Fran could be held by any closure, and it denoted the _whole history_ of a signal, so a late consumer could demand old samples and the runtime had to keep them (a space leak) or recompute them (a time leak). A signal function is causal and only ever sees the current sample. History it needs is state _inside_ it. Nothing outside can retain a signal, so nothing outside can leak one. The library has guarded this property since 2003 with a dedicated long-running test, [`yampa-test/tests/Space.hs`][y-space], which runs `arr`, `loop`, `rSwitch`, `pSwitch`, `rpSwitch` and `accum` for two million steps and asks the tester to _"Observe the process size using some tool like top. The process should not grow significantly."_

---

## How it works

The real representation is in [`FRP.Yampa.InternalCore`][y-core], a module hidden unless the package is built with the unsupported `expose-core` flag ([`Yampa.cabal`][y-cabal]):

```haskell
type Time  = Double      -- [s]
type DTime = Double      -- [s]

data SF a b = SF {sfTF :: a -> Transition a b}       -- not yet started: no dt at time 0

data SF' a b where                                   -- running ("future") signal function
  SFArr   :: !(DTime -> a -> Transition a b) -> !(FunDesc a b) -> SF' a b
  SFSScan :: !(DTime -> a -> Transition a b) -> !(c -> a -> Maybe (c, b)) -> !c -> b -> SF' a b
  SFEP    :: !(DTime -> Event a -> Transition (Event a) b) -> !(c -> a -> (c, b, b)) -> !c -> b -> SF' (Event a) b
  SFCpAXA :: !(DTime -> a -> Transition a d) -> !(FunDesc a b) -> !(SF' b c) -> !(FunDesc c d) -> SF' a d
  SF'     :: !(DTime -> a -> Transition a b) -> SF' a b

type Transition a b = (SF' a b, b)                   -- next state, current output
```

Three points matter for a D port:

1. **It is a Mealy machine in continuation encoding.** A step returns the output _and the next machine_. State lives in closures captured by that next machine, so each step that changes state allocates a new closure. [FRP Continued][frp-continued] §4 explains why streams were dropped for this: _"It does not seem to be possible to implement first-class signal function continuations in a stream-based implementation, since the connection between a signal function and its input stream is hidden in a closure."_
2. **Time zero is a different type.** `SF` is the unstarted machine (no `dt` exists yet). `SF'` is the running one. A switch "starts" its continuation by calling `sfTF` without a `dt`. That is why `localTime` restarts at 0 inside a switched-in SF ([`Time.hs`][y-time]).
3. **Constructors carry optimisation hints.** `FunDesc` (`FDI` identity, `FDC` constant, `FDE` event function, `FDG` general) lets `fdComp`, `fdPar` and `fdFanOut` fold stateless pipelines at run time: `arr f >>> arr g` becomes one `FDG (g . f)`, and `switchAux (SFArr _ (FDC (b, NoEvent)))` collapses a switch whose trigger is constantly `NoEvent` into `sfConst b`. This is the subject of Nilsson's _Dynamic Optimization for Functional Reactive Programming using Generalized Algebraic Data Types_ (2005, listed in the README). A D implementation gets the same effect statically from template specialisation.

The arrow instances supply composition (`>>>`, from `Category`), `first`/`second`, parallel `***`, fan-out `&&&`, `ArrowChoice` (`+++`, so `proc` can `case`) and `ArrowLoop` (`loop`). Yampa also has `Functor` and `Applicative` instances: `f <*> x = (f &&& x) >>> arr (uncurry ($))`. So the README's three styles (arrow notation, applicative, raw combinators) are interchangeable:

```haskell
signalFunction :: SF Double Double
signalFunction = proc x -> do
  y <- integral -< x
  t <- time     -< ()
  returnA -< y / t

signalFunction1 = (/) <$> integral <*> time          -- applicative
signalFunction2 = (integral &&& time) >>^ (/)          -- combinators
```

In `proc` notation the names `x`, `y`, `t` stand for _the current sample_, not for signals ([FRP Continued][frp-continued]: _"Paterson's syntactic sugar for arrows effectively allows signals to be named"_). The expression to the left of `-<` must not mention them, which keeps the network static between switches.

**Events** are an option-per-sample: `data Event a = NoEvent | Event a` ([`Event.hs`][y-event]), _"isomorphic to `Maybe`"_ but carrying the promise that occurrences are sparse. A discrete stream is therefore just a continuous signal of type `Event a`, so one `SF` type covers both worlds. `hold`/`accumHold` ([`Hybrid.hs`][y-hybrid]) go from events to continuous values, and `edge`/`edgeBy` ([`EventS.hs`][y-events]) go back.

**Driving.** [`Simulation.hs`][y-sim] has two drivers. `reactimate` owns the main loop:

```haskell
reactimate :: Monad m
           => m a                          -- ^ Initialization action
           -> (Bool -> m (DTime, Maybe a)) -- ^ Input sensing action
           -> (Bool -> b -> m Bool)        -- ^ Actuation (output processing) action
           -> SF a b                       -- ^ Signal function
           -> m ()
```

`sense` returns the elapsed `dt` and optionally a new input. `Nothing` means "same as last sample". `actuate` returns `True` to stop. `reactInit`/`react` invert control for hosts (GLUT, Gtk) that own the loop: `react rh (dt, ma)` does one step against an `IORef`-held state. `embed` is the pure version for tests.

---

## Evaluation model

- **Synchronous, sampled, driver-pulled.** One `react` step evaluates the whole network once, in the order composition fixes. Nothing propagates between steps and nothing runs without a step. This is the synchronous-dataflow hypothesis of [Lustre and Esterel][sync] (the paper calls AFRP _"a powerful synchronous dataflow programming language"_), with continuous time approximated by the sampling.
- **Glitch-free by construction.** Within a step every combinator sees exactly one value per input, computed earlier in the same step. There is no dependency graph to propagate through and no diamond problem. `&&&` simply evaluates both branches on the same sample.
- **Neither push nor pull in the Rx sense.** Inputs are not pushed per occurrence: an `Event` is _sampled_, and two clicks inside one frame are one `Event` (or lost) unless the driver batches them into `Event [Click]`. Outputs are not pulled lazily per consumer. Every step computes every output, although Haskell laziness means unused fields are never forced. `reactimate` `seq`s `a` and `b` on each loop iteration to bound thunk chains.
- **Hot/cold does not apply.** An `SF` is a pure, reusable _description_ (cold). Each `reactimate`/`embed`/switch-start instantiates fresh state. There is no shared running instance to subscribe to, so no multicast question arises ([State and sharing](#state-and-sharing)).
- **Instantaneous feedback** must be broken by a delay (`iPre`, `dSwitch`, `loopPre`) or the step diverges at run time. Lazy evaluation lets `loop` type-check without forcing well-foundedness, and nothing checks it statically.

## Composition

The operator surface is the arrow class plus about 135 export-list entries in [`FRP.Yampa`][y-top]. The module groups are basic SFs, event sources, pointwise event functions, switching, hybrid (hold/accumulate), delays, conditional, loops/integration, noise, simulation and tasks. The only genuinely stateful primitives are a handful (`iPre`, `integral`, `sscan`, `hold`-via-`epPrim`, `edgeBy`, the switches, `afterEachCat`, `delay`). Everything else is defined from them. For example, `fby` is `b0 --> sf >>> pre`, `localTime` is `constant 1.0 >>> integral`, and `after q x` is `afterEach [(q, x)]`.

Derived values are plain composition: a "computed" signal is `arr f` after a fan-out, so there is no separate `computed`/`map` concept. The arrowized style forces every intermediate value to be named in `proc` or plumbed through tuples. Users accept this for games (tens of signals) but it scales poorly to UIs with hundreds of fields.

**The switching family** is how structure changes. Its header in [`Switches.hs`][y-switches] doubles as a naming grammar:

| Combinator             | Who supplies the trigger                     | What replaces what                                                            | Instant of switch              |
| ---------------------- | -------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------ |
| `switch sf k`          | `sf` itself: `SF a (b, Event c)`             | `k c :: SF a b` replaces `sf`, once                                           | `k c` produces this output     |
| `dSwitch sf k`         | same                                         | same                                                                          | `sf`'s output kept; `k c` next |
| `rSwitch sf`           | the input: `SF (a, Event (SF a b)) b`        | each event carries a fresh SF; latest wins, repeatedly                        | immediate                      |
| `drSwitch sf`          | the input                                    | same                                                                          | decoupled                      |
| `kSwitch sf e k`       | a separate observer `SF (a, b) (Event c)`    | `k (frozen sf) c`: the continuation receives the _running_ `sf`, state intact | immediate                      |
| `dkSwitch`             | same                                         | same                                                                          | decoupled                      |
| `pSwitch r sfs e k`    | observer of input + all outputs              | `k (frozen collection) d`: add, remove, reorder running SFs                   | immediate                      |
| `rpSwitch r sfs`       | input events of `col (SF) -> col (SF)`       | each event mutates the live collection                                        | immediate                      |
| `dpSwitch`/`drpSwitch` | as above                                     | as above                                                                      | decoupled                      |
| `…B`/`…Z`/`parC`       | routing: broadcast, zip with list, replicate | –                                                                             | –                              |

Analysed against the survey's concerns:

- **`switch` is one-shot structural lifetime.** The old SF is _dropped_, which is all cancellation is for a pure machine: its state becomes garbage. `rSwitch` is that repeated, and it is the arrowized form of latest-wins (`switchMap`/`flatMapLatest` in [RxJS][rxjs] or [Kotlin Flow][kotlin-flow]). A new inner SF arrives on an input event, the previous one stops being stepped, and the new one starts at local time 0. `rSwitch sf = switch (first sf) ((noEventSnd >=-) . rSwitch)`. The `noEventSnd >=-` masks the triggering event from the new instance's first sample, so it cannot immediately re-switch.
- **`d` (decoupled) exists for feedback.** In `switch`, the output at the switching instant comes from the _new_ SF, so the output depends instantaneously on the trigger. If the trigger is computed from that output (through `loop`), the step diverges. `dSwitch` emits the _old_ SF's output at that instant. The header warns: _"If you use the same SF that originally provoked the switch, you are very likely to fall into an infinite loop. In those cases, the use of `dSwitch` or `-->` may help."_ For a D `Cell`, the analogous question is whether a write made during frame `n` is visible to readers in frame `n` or `n+1`.
- **`k` (continuation) switches turn running state back into values.** `kSwitch` hands `freeze sf1 dt` (an `SF` built from the running `SF'` with the current `dt` baked in) to the continuation. The continuation can resume, discard, store or wrap it. [FRP Continued][frp-continued] calls this _"the ability to 'freeze' running signal functions, turning them back into first class values (with preserved state, of course)"_, and its tailgating-detector example uses `rpSwitch` to add and remove per-car trackers without resetting the others. This is what Yampa offers instead of Fran's dynamic collections of signals. It needs a value-semantics copy of a running machine. In D that is a `struct` move, not a closure capture.
- **`p` (parallel) switches are keyed dynamic collections.** The routing function is rank-2 (`forall sf . a -> col sf -> col (b, sf)`), so routing cannot inspect or duplicate the running SFs. The paper notes this gives them _"second class status"_, while the continuation sees them frozen and first-class. That split (opaque while running, manipulable at a switch point) is a clean model for a keyed `ForEach`/list-of-tasks node.

### API structure and naming

**Source, transform and sink are one type.** There is no separate source or sink type. A source is an `SF a b` that ignores its input: `constant`, `time`, `never`, `now`, `after`, `repeatedly`, `afterEach`, `noise` ([`EventS.hs`][y-events]). A transform is any `SF`. Sinks do not exist inside the language. The driver's `actuate` callback is the only sink, and `embed` (returning `[b]`) is the test sink. Everything composes with the same `>>>`. Yampa is all transform: a closed network whose two open ends are owned by the host.

**Organisation.** There is one prelude module, `FRP.Yampa`, that re-exports everything plus `Control.Arrow`. Sub-modules split by concept: `Basic`, `Event` (pointwise functions _on_ event values: `tag`, `merge`, `filterE`, `gate`), `EventS` (signal functions _producing_ events: `edge`, `after`, `once`), `Hybrid`, `Delays`, `Switches`, `Simulation`, `Task`. The `Event`/`EventS` split (value-level vs signal-level, distinguished by one trailing `S`) recurs in dunai (`arrM` vs `liftTransS`) and is easy to misread. Operators are free functions and infix symbols. A Haskell type has no methods.

**Variant families are prefix and suffix letters, documented as a grammar.** The [`Switches.hs`][y-switches] header:

> _"Switches vary depending on a number of criteria: … /Decoupled/ vs normal switching /(d)/ … How the switching event is provided /( \/r\/k)/ … How many SFs are being handled /( \/p\/par)/ … How the input is router /(B\/Z\/ )/ … These gives a number of different combinations, some of which make no sense, and also helps determine the expected behaviour of a combinator by looking at its name. For example, 'drpSwitchB' is the decoupled (/d/), recurrent (/r/), parallel (/p/) switch with broadcasting (/B/)."_

The same letters appear elsewhere. A `d` prefix means "one sample later": `dHold`, `dAccumHold`, `dTrackAndHold`, `dSwitch`. An `i` prefix means "initialised with a value": `iPre`, `iEdge`. Suffixes: `By` takes a function (`edgeBy`, `accumBy`, `mergeBy`), `Cat` catenates simultaneous occurrences into a list (`afterEachCat`, `delayEventCat`), `E` marks pointwise event functions (`filterE`, `mapFilterE`, `joinE`, `splitE`), and `T` marks the `Task` monad (`constT`, `sleepT`, `snapT`). Initialisation operators are symbolic: `-->` (replace first output), `-:>` (prepend an output), `>--` (replace first input), `-=>` / `>=-` (map first output/input). Legibility depends on the reader. The grammar is learnable and stated in the source, but it yields 22 switch names (`switch` … `drpSwitchZ`, `parC`), and the four initialisation symbols cannot be guessed from their glyphs. The hand-maintained grammar suggests that a language with keyword or template parameters should make these axes parameters, not letters.

**User-defined operators.** A user cannot write a primitive. `SF`'s constructor lives in the hidden `InternalCore`, and [`Time.hs`][y-time] says _"If you really, really, really need to know the time delta, and need to abandon the hybrid/FRP abstraction, see `iterFrom`"_. A new stateful operator is written by composing the stateful kernels: `sscan` (pure fold, [`Scan.hs`][y-scan]), `loopPre` (well-defined feedback through `iPre`, [`Loop.hs`][y-loop]), `localTime`, `edgeBy`, `hold`, and switches. The [worked pipeline](#the-worked-pipeline)'s debounce is such a composite. Keeping the step function sealed is how the library preserves the leak-freedom and causality invariants.

**Regrets and renames.** The [`CHANGELOG`][y-changelog] records 0.13 (2018-11-02): _"Clean API, remove deprecated constructs, move vector and point into separate library, hide Core. Eliminate Forceable and MergeableRecord."_ 0.15 (2025-02-27): _"Deprecate FRP.Yampa.Arrow.arr3,arr4,arr5"_, now marked `{-# DEPRECATED arr3 … #-}` in [`Arrow.hs`][y-arrow]. Rhine's history is far more turbulent (see [Related designs](#related-designs)): `SyncSF` renamed to `ClSF` "and many other renames" in 0.5, the `Schedule` type deleted in 1.0, the dunai `MSF` replaced by `Automaton` in 1.3 (with `iPre` renamed `delay` and `morphS` renamed `hoistS`), and the `SN` GADT turned into a newtype in 1.6.

## Time and scheduling

- **One clock, given as `dt` per step.** Time is the sum of the `dt`s the driver passes. There is no scheduler, timer queue or wall clock inside Yampa. `localTime = constant 1.0 >>> integral`, and [`Time.hs`][y-time] notes that _"the SF switched into will be started at the time of switching"_. Switching therefore also resets local clocks, which is exactly what a restart-on-keystroke debounce wants.
- **Timed operators accumulate `dt` and compare.** `afterEachCat` stores `t` as a negative offset, adds each `dt`, and fires when `t' >= 0` ([`EventS.hs`][y-events]). `delay` keeps a sample queue with per-sample `dt`s ([`Delays.hs`][y-delays]). Firing is therefore quantised to the frame. An event is emitted _"at or as soon after (local) time q as possible"_ (`after`'s doc), and `repeatedly` explicitly avoids an _"event backlog"_: at most one occurrence per sample.
- **No `debounce`.** Yampa ships neither `debounce` nor `throttle`. The idiomatic form is restart-by-switch: on each change event, `rSwitch` into a fresh `after n` (local time 0). Because `after`'s duration is a construction-time constant, a _runtime-adjustable_ `N` needs the duration read from the input signal each sample. The [worked pipeline](#the-worked-pipeline) does this with `localTime` plus a comparison, so changing `N` takes effect on the next sample, including firing immediately if `N` shrinks below the elapsed time.
- **No "next deadline".** Nothing in the SF can tell the driver _when_ the next timed event is due. A host that wants to sleep while idle (sparkles' `wakeIn`) cannot ask Yampa. It must keep ticking at frame rate, or know from outside that a debounce is pending. `reactimate`'s `sense` takes a `Bool` "can block" argument, but the library always passes `False` (`sense False` in the loop). **A D design should give time-based operators a `nextDeadline` query**, which this model lacks.
- **Multi-rate** is out of scope apart from `embedSynch`, which runs an embedded SF at a variable ratio to outer time (0 pauses it). Multi-rate is Rhine's whole reason to exist.

## Concurrency and cancellation

Not applicable inside Yampa, and that absence is the design. An `SF` is pure. It cannot fork, block, perform I/O or observe another thread. Consequences:

- **Latest-wins over _signal functions_ is `rSwitch`**, and "cancellation" is ceasing to step the old SF. It is immediate and complete, and there is nothing to wait for, because the old machine has no running computation outside the step.
- **Latest-wins over _work_ (the hash) is a protocol between the SF and the driver.** The SF emits a command event (`StartHash q`, `CancelHash`). The actuator, in `IO`, cancels the previous worker and spawns a new one, and `sense` feeds the result back as an `Event`. Whether a cancel _waits_ depends on the I/O library the actuator uses. With [`async`][async]'s `cancel`, it does: _"Cancel an asynchronous action by throwing the AsyncCancelled exception to it, and waiting for the Async thread to quit."_ That wait happens on the UI thread inside `actuate`. GHC delivers asynchronous exceptions only at allocation points, so a non-allocating hash loop delays the cancel (general GHC behaviour, not Yampa-specific).
- **Stale results** need a guard. A result that was enqueued before the cancel landed would reach the next `sense`. Either the actuator drains the slot after cancelling or results carry a generation number. Yampa gives no help with this. It is the same race [RxJS][rxjs]'s `switchMap` solves by unsubscribing the inner observable.
- **CPU-bound work** goes to threads outside the network. Rhine's answer is to make "outside" typed: an event clock fed from a `Chan` _"constitute[s] the recommended way of communication between threads in Rhine"_ ([`Clock/Realtime/Event.hs`][r-event]).

## Errors and completion

There is no error channel. Partial operations call `usrErr` (an `error` call, i.e. an exception at evaluation) for misuse such as `repeatedly` with a non-positive period or `delay` with a negative one ([`EventS.hs`][y-events], [`Delays.hs`][y-delays]). Failures of external work arrive as ordinary input values (`Event (Either Err Hash)`), which matches the sparkles convention of errors as `Expected` values.

Completion is not a stream concept either: an SF runs forever, and `actuate` returning `True` ends `reactimate`. _Logical_ completion is modelled by `Task` ([`Task.hs`][y-task]), a continuation monad over `SF a (b, Event c)`: a task produces `b` until it terminates with `c`. `timeOut` and `abortWhen` race a task against `after t ()` or a guard event. `abortWhen`'s doc gives the motive: _"Useful for separating sequencing and termination concerns."_ dunai later generalised this into `MSFExcept`, a monad in the exception type where `>>=` _is_ switching (see [Related designs](#related-designs)).

## State and sharing

- **Value cells** are `hold :: a -> SF (Event a) a` (zero-order hold) and `accumHold :: a -> SF (Event (a -> a)) a`. Both are built on `epPrim`, the only SF' constructor specialised for event input (`SFEP`). `hold` is a [`Cell!T`][concepts] with the version counter implied. Readers sample it every step, so it conflates by construction.
- **Conflation is the default everywhere.** An `Event` is at most one occurrence per sample. Bursts collapse unless a `…Cat` operator collects them.
- **Sharing/multicast** is fan-out (`&&&`) within the network. One SF instance's output is plumbed to many consumers by naming it once in `proc`. Two textual uses of the same `SF` value are two _independent_ instances with separate state. A `Cell` that many readers share must be computed once and routed, which in a large UI makes the arrow plumbing heavy (the problem [Reflex][reflex] and [Sodium][sodium] avoid with first-class `Dynamic`/`Cell`).

## Lifetime and ownership

Lifetime is _structural_: an SF lives exactly as long as the switch that contains it keeps stepping it. There are no subscriptions, disposables, owners, finalisers or teardown hooks, and for a pure machine none are needed. Dropping it is the teardown. The `Space.hs` leak test runs `rSwitch`/`pSwitch`/`rpSwitch` for two million steps precisely because a switch that kept its predecessor reachable would leak.

The catch for an effectful system: **a structural drop cannot release an external resource.** In the pipeline, switching the whole network off with `rSwitch` discards the debounce state correctly but cannot stop the worker thread. The SF must _also_ emit `CancelHash` at the switching instant, and the driver must act on it. A D `Scope` with cancel-and-join fills exactly this gap, so that leaving a switch branch is itself the teardown of the work it started.

## Testing

Determinism is free because time is an argument. `embed :: SF a b -> (a, [(DTime, Maybe a)]) -> [b]` runs an SF on an explicit list of `(dt, input)` samples, and `deltaEncode dt xs` builds such a list from plain samples ([`Simulation.hs`][y-sim]). The haddock of `hold` is itself a test:

```haskell
>>> embed (hold 1) (deltaEncode 0.1 [NoEvent, NoEvent, Event 2, NoEvent, Event 3, NoEvent])
[1,1,2,2,3,3]
```

The unit tests are of this form ([`Test/FRP/Yampa/Switches.hs`][y-test-switches]: `rswitch_t0 = take 20 $ embed (rSwitch (arr (+3))) rswitch_inp1`, compared to a literal list). A debounce test is a list with `dt = 0.1`, keystrokes as `Just q` at chosen indices, and an assertion on which output index carries the `Event`. No `TestClock`, virtual scheduler or `advanceTimeBy` is needed. [`yampa-test`][y-quickcheck] adds QuickCheck generators for random `dt` streams (`uniDistStream`, `generateStreamWith`) and temporal-logic predicates over SFs ([`LTLFuture.hs`][y-ltl]: `Always`, `Eventually`, `Until`, `Next` over `SF a Bool`), so properties like "every query is eventually followed by a hash request within N + dt" can be checked against many sampling schedules. `evalAtZero`/`evalAt` step an SF by hand. Their doc warns that they _"break the FRP abstraction by making samples discrete and step based"_.

## The worked pipeline

Untested sketch (Yampa `0.15.1` API, `async` for the worker). Debounce reads `N` from the input every sample; the toggle is a structural `rSwitch`; the hash lives in the driver.

```haskell
{-# LANGUAGE Arrows #-}
import FRP.Yampa
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.MVar
import Data.IORef

data Input  = Input  { query :: String, intervalS :: DTime, enabled :: Bool
                     , hashDone :: Event Hash }
data Cmd    = StartHash String | CancelHash
data Output = Output { cmd :: Event Cmd, shown :: Maybe Hash }

-- Fires once when local time reaches the *current* interval.
waitThenFire :: String -> SF DTime (Event String)
waitThenFire q = proc n -> do
  t <- localTime   -< ()                    -- restarts at 0 on every switch-in
  e <- iEdge False -< t >= n                -- n is re-read every sample
  once             -< e `tag` q

-- Latest-wins restart: each new query replaces the pending waiter.
debounce :: SF (Event String, DTime) (Event String)
debounce = proc (qE, n) -> rSwitch never -< (n, waitThenFire <$> qE)

pipeline :: SF Input Output
pipeline = proc inp -> do
  qE   <- edgeBy changed "" -< query inp
  fire <- debounce          -< (qE, intervalS inp)
  res  <- hold Nothing      -< Just <$> hashDone inp
  returnA -< Output (StartHash <$> fire) res
  where changed old new = if old /= new then Just new else Nothing

idle :: SF Input Output
idle = constant (Output NoEvent Nothing)

app :: SF Input Output                       -- toggle = structural lifetime
app = proc inp -> do
  on  <- iEdge False -< enabled inp
  off <- edge        -< not (enabled inp)
  out <- rSwitch idle -< (inp, (on `tag` pipeline) `lMerge` (off `tag` idle))
  returnA -< out { cmd = cmd out `lMerge` (off `tag` CancelHash) }

main :: IO ()
main = do
  worker  <- newIORef Nothing
  results <- newEmptyMVar
  let stop = readIORef worker >>= mapM_ cancel >> tryTakeMVar results >> pure ()
      actuate _ out = do
        case cmd out of
          Event (StartHash q) -> do stop
                                    a <- async (hashFileSet q >>= putMVar results)
                                    writeIORef worker (Just a)
          Event CancelHash    -> stop
          NoEvent             -> pure ()
        render (shown out) >> pure False
      sense _ = do (dt, ui) <- pollUiFrame          -- dt from the frame clock
                   done     <- tryTakeMVar results
                   pure (dt, Just ui { hashDone = maybeToEvent done })
  reactimate initialUi sense actuate app
```

**Per-event trace** (frames of `dt = 16 ms`, `N = 300 ms`):

| Event                     | Inside the SF                                                                                                                                        | In the driver                                                                                                      |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Keystroke during debounce | `edgeBy` emits `qE`. `rSwitch` drops the old `waitThenFire` (its `localTime` state is garbage) and starts a new one at `t = 0`. Nothing fires.       | Nothing. No timer existed to cancel.                                                                               |
| Debounce elapses          | In the first frame with `t >= 0.3`, `iEdge` rises, `once` emits, `cmd = StartHash q`.                                                                | `stop` (no-op), then `async` hash. The UI keeps ticking.                                                           |
| Keystroke during hash     | New `qE` restarts the waiter. No command yet: the running hash continues until the new debounce fires.                                               | At the next `StartHash`, `stop` calls `cancel` (blocks until the old thread exits), drains `results`, then spawns. |
| Interval change           | `intervalS` is an input field. The live waiter compares against the new `n` on the next frame, so shrinking below the elapsed `t` fires immediately. | Nothing.                                                                                                           |
| Toggle off                | `off` fires. `rSwitch` replaces `pipeline` with `idle`, discarding the pending waiter and `hold`. `cmd = CancelHash` at the same instant.            | `stop`: cancel-and-wait the worker, drain any queued result.                                                       |
| Result arrives            | `sense` turns the `MVar` into `Event h`. `hold` shows it.                                                                                            | –                                                                                                                  |

**Fit with a per-frame UI.** The core fits a frame loop exactly: `react` is "one frame", inputs are sampled UI state, outputs are a view model plus commands, and the network is deterministic and testable with `embed`. Three things do not fit:

- The driver must tick every frame while anything is pending, because the SF cannot report its next deadline.
- Work and its cancellation live in an untyped, imperative actuator, so the latest-wins guarantee for the hash is a convention, not a property of the composition.
- A UI's many independent fields become one large tuple routed through `proc`, which the arrow style makes verbose.

## Related designs

- **[Fran][fran]** (Elliott & Hudak, ICFP 1997) introduced FRP with first-class `Behavior a` (functions of continuous time) and `Event a` (time-stamped occurrences), combined with `until`, `snapshot` and time transformation. Its expressiveness came from first-class signals, and the cost was the space and time leaks that AFRP was designed to remove. Elliott's later push-pull work (2009, cited in Yampa's README) kept first-class signals and attacked efficiency differently. That branch leads to [Reflex][reflex] and [Sodium][sodium], not to Yampa.
- **[Arrows, Robots, and FRP][arrows-robots]** (Hudak, Courtney, Nilsson, Peterson, AFP 2002, LNCS 2638) is the tutorial presentation of Yampa on mobile robots. It is the standard introduction to `proc` notation, `switch` and `reactimate`.
- **Dunai / BearRiver** ([_FRP, Refactored_][frp-refactored], Perez, Bärenz, Nilsson, Haskell Symposium 2016) generalise the step to a monad: `data MSF m a b = MSF { unMSF :: a -> m (b, MSF m a b) }` ([`InternalCore.hs`][d-core]). Yampa's SF is the special case `m = Reader DTime`. BearRiver is the Yampa API on top: `type SF m = MSF (ClockInfo m)` with `type ClockInfo m = ReaderT DTime m` ([`BearRiver/InternalCore.hs`][d-br-core]). The [`Core.hs`][d-msf] header states the payoff: _"flattening with 'EitherT' gives rise to switching, and flattening with 'ListT' gives rise to parallelism with broadcasting."_ Switching becomes exceptions: `switch sf f = catchS ef f`, and `MSFExcept` is _"a monad in the exception type"_ where _"'>>=' is exception handling"_ ([`MSF/Except.hs`][d-except]). Sequenced phases (`do { try phase1; try phase2 }`) replace switch combinators. That is the same control-flow-as-lifetime idea as [Esterel/Céu][sync] and a close match for an `Effect`-returning sink. The price is that effects re-enter the step, so a dunai network can do I/O but still cannot _wait_ asynchronously within a step.
- **Rhine** ([_Rhine: FRP with Type-Level Clocks_][rhine-paper], Bärenz & Perez, Haskell Symposium 2018) answers "where and when does this run" in the types. `class Clock m cl` has associated `Time cl` and `Tag cl` and an `initClock` that yields an effectful tick stream ([`Clock.hs`][r-clock]). The building blocks are a `ClSF m cl a b` (a signal function readable only under clock `cl`, [`ClSF/Core.hs`][r-clsf]), clocks, and `ResamplingBuffer m cla clb a b` with `put` at `cla` ticks and `get` at `clb` ticks ([`ResamplingBuffer.hs`][r-resbuf], e.g. `keepLast`, a zero-order hold, [`KeepLast.hs`][r-keeplast]). The README's example `ms500 @@ waitClock |@| ms1200 @@ waitClock >-- collect --> printEverySecond @@ waitClock` composes two 500/1200 ms rhines in parallel and resamples them into a 1 s consumer, and _"Uncomment the following for a type error (the clocks don't match): `typeError = ms500 >>> printEverySecond`"_ ([`README.md`][r-readme]). Mapped onto sparkles, the UI frame and the CPU pool would be two clocks, the hash result an event clock fed from a channel, and the boundary a typed buffer. Mixing them without a buffer would be a compile error. The combinator mnemonic is documented (`@` annotates with a clock, `*` composes in parallel, `>` sequentially, [`Combinators.hs`][r-comb]). The history is the instructive part. [`version1.md`][r-v1] removed the `Schedule` type because schedules _"were not composable across monad transformers"_ and _"several schedules were clock-specific, and basically re-implemented the constituent clocks"_. 1.3 dropped dunai's continuation-encoded `MSF` for _"state automata"_ because it _"allows GHC to optimize the code substantially"_ ([`versions.md`][r-versions]). 1.8 replaced the `SN` GADT _"in favour of semantic functions, for a > 100x speedup in some benchmarks"_ ([`ChangeLog.md`][r-changelog]). The new [`automaton`][r-stream] package encodes a stream as `StreamT { state :: s, step :: s -> m (Result s a) }` with an existential `s`, which is a struct plus a step function. That is exactly the D design.
- **netwire** (Ertugrul Söylemez; [Hackage][netwire]) is an arrowized "wire" library in the same family, with inhibition (a wire may produce no value) in place of `Event`. It is mentioned for completeness. No source was surveyed and nothing here depends on it.

## Strengths

- One uniform type, `SF a b`, for sources, transforms, continuous and discrete signals. Composition is total and glitch-free.
- Leak-freedom by construction: no first-class signals means no retained history. This has been tested since 2003.
- A switching family that models structural lifetime precisely, including _frozen_ continuations that let running state be inspected, stored and re-inserted.
- Deterministic testing with no test clock: time is a list of `dt`s, and QuickCheck plus LTL work on top.
- Backend-agnostic, inversion-of-control friendly (`reactInit`/`react`). It has shipped in commercial mobile games.

## Weaknesses

- No asynchrony, I/O, cancellation or error channel inside the model. The worked pipeline's hardest half lives in an untyped actuator.
- No deadline query: a host cannot sleep until the next timed event.
- Continuation encoding allocates per step, and Haskell laziness needs `seq` discipline. Rhine abandoned that encoding for explicit-state automata to get large speedups.
- Arrow plumbing is verbose for wide, shallow UIs. Every shared value must be named once and routed.
- Instantaneous-loop well-foundedness and `Event` sparsity are documented assumptions, not checked ones.
- Combinatorial naming (22 switches, symbolic initialisers) is legible only after learning the grammar.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                                     | Trade-off                                                                                  |
| ----------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Signal functions first-class, signals not       | Eliminates Fran's time and space leaks; causal by construction                | Every shared signal must be routed; dynamic collections need `pSwitch` instead of values   |
| Mealy machine in continuation encoding          | Enables first-class frozen continuations (`kSwitch`, `pSwitch`)               | Closure allocation per stateful step. Rhine moved to explicit `state` + `step` for speed   |
| `dt` passed per step by the driver              | Determinism; `embed` tests with no virtual clock                              | Firing quantised to frames; no way to report the next deadline                             |
| `Event` = option per sample                     | One SF type covers continuous and discrete; conflation is automatic           | Bursts within a frame collapse unless the driver batches them                              |
| Switching as the only structural change         | Lifetime is lexical/structural; dropping a machine is teardown                | Cannot release external resources. Effects need an explicit cancel command                 |
| `d` variants for decoupled switching            | Makes feedback through a switch well-defined                                  | Doubles the API; the choice is subtle and only fails at run time                           |
| Hidden core, sealed primitives                  | Users cannot break causality or leak-freedom                                  | User operators must be composites; `dt` access needs the unsupported `expose-core` flag    |
| No I/O inside SFs (Yampa); monad inside (dunai) | Purity and replayability (Yampa) vs. extensibility (dunai)                    | Yampa pushes work to the driver; dunai lets effects in but still has no asynchronous waits |
| Clocks in types (Rhine)                         | "Where/when" is checked at compile time; typed resampling at clock boundaries | Heavy type-level machinery; the `Schedule` abstraction had to be removed and redesigned    |

## Sources

- [Yampa repository][y-repo] at `9dda03030c4edfdda6e908f49b5a92d1dda5c8a3`: [`FRP.Yampa`][y-top], [`InternalCore.hs`][y-core], [`Switches.hs`][y-switches], [`Simulation.hs`][y-sim], [`Event.hs`][y-event], [`EventS.hs`][y-events], [`Hybrid.hs`][y-hybrid], [`Delays.hs`][y-delays], [`Time.hs`][y-time], [`Scan.hs`][y-scan], [`Loop.hs`][y-loop], [`Task.hs`][y-task], [`Arrow.hs`][y-arrow], [`CHANGELOG`][y-changelog], [`README.md`][y-readme], [`Yampa.cabal`][y-cabal]
- `yampa-test`: [`Space.hs`][y-space], [`Test/FRP/Yampa/Switches.hs`][y-test-switches], [`QuickCheck.hs`][y-quickcheck], [`LTLFuture.hs`][y-ltl]
- [dunai repository][d-repo] at `407ff003fac2296582c0f4597f0004a1e578d3af`: [`InternalCore.hs`][d-core], [`Core.hs`][d-msf], [`MSF/Except.hs`][d-except], [`BearRiver/InternalCore.hs`][d-br-core]
- [rhine repository][r-repo] at `698b69397ec7d9545cdc9ae48967f970d42e2c28`: [`README.md`][r-readme], [`Clock.hs`][r-clock], [`ClSF/Core.hs`][r-clsf], [`ResamplingBuffer.hs`][r-resbuf], [`KeepLast.hs`][r-keeplast], [`Combinators.hs`][r-comb], [`Clock/Realtime/Event.hs`][r-event], [`ChangeLog.md`][r-changelog], [`versions.md`][r-versions], [`version1.md`][r-v1], [`automaton` `Data.Stream`][r-stream]
- Elliott & Hudak, [_Functional Reactive Animation_][fran], ICFP 1997
- Nilsson, Courtney & Peterson, [_Functional Reactive Programming, Continued_][frp-continued], Haskell Workshop 2002
- Hudak, Courtney, Nilsson & Peterson, [_Arrows, Robots, and Functional Reactive Programming_][arrows-robots], AFP 2002, LNCS 2638
- Perez, Bärenz & Nilsson, [_Functional Reactive Programming, Refactored_][frp-refactored], Haskell Symposium 2016
- Bärenz & Perez, [_Rhine: FRP with Type-Level Clocks_][rhine-paper], Haskell Symposium 2018
- [`async` `cancel` documentation][async] (2.2.6)
- Related deep-dives: [RxJS][rxjs] · [Kotlin Flow][kotlin-flow] · [Reflex][reflex] · [Sodium][sodium] · [Elm][elm] · [Synchronous languages][sync] · [Concepts][concepts] · [Comparison][comparison] · [Index][index]

<!-- References -->

[y-repo]: https://github.com/ivanperez-keera/Yampa/tree/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3
[y-top]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa.hs
[y-core]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/InternalCore.hs
[y-switches]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Switches.hs
[y-sim]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Simulation.hs
[y-event]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Event.hs
[y-events]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/EventS.hs
[y-hybrid]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Hybrid.hs
[y-delays]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Delays.hs
[y-time]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Time.hs
[y-scan]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Scan.hs
[y-loop]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Loop.hs
[y-task]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Task.hs
[y-arrow]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Arrow.hs
[y-changelog]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/CHANGELOG
[y-readme]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/README.md
[y-cabal]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/Yampa.cabal
[y-license]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/LICENSE
[y-space]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/tests/Space.hs
[y-test-switches]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/tests/Test/FRP/Yampa/Switches.hs
[y-quickcheck]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/src/FRP/Yampa/QuickCheck.hs
[y-ltl]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/src/FRP/Yampa/LTLFuture.hs
[d-repo]: https://github.com/ivanperez-keera/dunai/tree/407ff003fac2296582c0f4597f0004a1e578d3af
[d-core]: https://github.com/ivanperez-keera/dunai/blob/407ff003fac2296582c0f4597f0004a1e578d3af/dunai/src/Data/MonadicStreamFunction/InternalCore.hs
[d-msf]: https://github.com/ivanperez-keera/dunai/blob/407ff003fac2296582c0f4597f0004a1e578d3af/dunai/src/Data/MonadicStreamFunction/Core.hs
[d-except]: https://github.com/ivanperez-keera/dunai/blob/407ff003fac2296582c0f4597f0004a1e578d3af/dunai/src/Control/Monad/Trans/MSF/Except.hs
[d-br-core]: https://github.com/ivanperez-keera/dunai/blob/407ff003fac2296582c0f4597f0004a1e578d3af/dunai-frp-bearriver/src/FRP/BearRiver/InternalCore.hs
[r-repo]: https://github.com/turion/rhine/tree/698b69397ec7d9545cdc9ae48967f970d42e2c28
[r-readme]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/README.md
[r-clock]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/rhine/src/FRP/Rhine/Clock.hs
[r-clsf]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/rhine/src/FRP/Rhine/ClSF/Core.hs
[r-resbuf]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/rhine/src/FRP/Rhine/ResamplingBuffer.hs
[r-keeplast]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/rhine/src/FRP/Rhine/ResamplingBuffer/KeepLast.hs
[r-comb]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/rhine/src/FRP/Rhine/Reactimation/Combinators.hs
[r-event]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/rhine/src/FRP/Rhine/Clock/Realtime/Event.hs
[r-changelog]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/rhine/ChangeLog.md
[r-versions]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/versions.md
[r-v1]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/version1.md
[r-stream]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/automaton/src/Data/Stream.hs
[hackage]: https://hackage.haskell.org/package/Yampa
[wiki]: https://wiki.haskell.org/Yampa
[netwire]: https://hackage.haskell.org/package/netwire
[async]: https://hackage.haskell.org/package/async-2.2.6/docs/Control-Concurrent-Async.html
[fran]: https://doi.org/10.1145/258948.258973
[frp-continued]: https://doi.org/10.1145/581690.581695
[arrows-robots]: https://doi.org/10.1007/978-3-540-44833-4_6
[frp-refactored]: https://doi.org/10.1145/2976002.2976010
[rhine-paper]: https://doi.org/10.1145/3242744.3242757
[rxjs]: ./rxjs.md
[kotlin-flow]: ./kotlin-flow.md
[reflex]: ./reflex.md
[sodium]: ./sodium.md
[elm]: ./elm.md
[sync]: ./synchronous-languages.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
