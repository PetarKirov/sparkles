# Reflex (Haskell)

A fully deterministic, higher-order push-pull FRP library: `Event`, `Behavior` and `Dynamic` are abstract types indexed by a timeline `t`, all reachable only through typeclasses (`Reflex`, `MonadSample`, `MonadHold`, `PerformEvent`, `TriggerEvent`, …), run by the Spider engine's height-ordered frames, with [reflex-dom][rd-quickref] building retained-mode DOM UIs on top.

| Field             | Value                                                                                                                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Haskell (GHC 8.4 – 9.14 and GHCJS, per `tested-with` in [`reflex.cabal`][cabal])                                                                                                                                                      |
| License           | BSD3 ([`reflex.cabal`][cabal])                                                                                                                                                                                                        |
| Repository        | reflex-frp/reflex ([`README.md`][readme]); reflex-frp/reflex-dom for the DOM layer                                                                                                                                                    |
| Documentation     | [`Quickref.md`][quickref], [reflex-frp.org][site], [Hackage][hackage], Ryan Trinkle's NY Haskell talk ([slides][nyhug-slides], [video][nyhug-video])                                                                                  |
| Category          | Discrete-time, higher-order push-pull FRP; one engine (Spider), plus a denotational reference implementation (`Reflex.Pure`)                                                                                                          |
| Versions surveyed | reflex `master` at `f443526bd2a9` (2026-11-22; cabal version `0.10.0.0` plus an _Unreleased_ ChangeLog section); reflex-dom `master` at `de31ceff3d99` (2026-11-23)                                                                   |
| Core abstraction  | `Event t a` (discrete occurrences), `Behavior t a` (a value at every instant, sampled, never observed for change), `Dynamic t a` (a `Behavior` and an `Event` that move together); `Incremental t p` (a `Dynamic` updated by patches) |

> [!NOTE]
> The subject is the `reflex` library and its Spider engine. reflex-dom is cited only
> for how a UI obtains `Dynamic`s and `Event`s from widgets (`inputElement`) and for the
> `MonadWidget` constraint bundle. Obelisk, reflex-vty and reflex-native were not
> examined. Talks are cited from their published slides, not from the video.

---

## Overview

### What it solves

Reflex lets a program describe an interactive system as a pure network of time-indexed values, built once in a monad and then driven by external triggers. Its distinguishing claims among FRP libraries are that the network is **higher-order** (events of events, behaviours of events, networks rebuilt by events) without the space-time leaks of classic FRP, and that propagation cost is independent of network size. Trinkle's slides put the latter bluntly: _"In Reflex, overall application size has no impact on event propagation time"_, and _"Practical FRP should support dynamic data flow … In Reflex.Dom, widgets can be created, laid out, or destroyed within the FRP semantics"_ ([NY Haskell slides][nyhug-slides]).

### Design philosophy

From the package description ([`README.md`][readme], identical in [`reflex.cabal`][cabal]):

> _"Interactive programs without callbacks or side-effects. Functional Reactive Programming (FRP) uses composable events and time-varying values to describe interactive systems as pure functions. … Reflex is a fully-deterministic, higher-order Functional Reactive Programming interface and an engine that efficiently implements that interface."_

The phrase "an interface and an engine" is literal. The `Reflex` class in [`Reflex/Class.hs`][class] declares the types and ~20 primitives; Spider ([`Reflex/Spider/Internal.hs`][spider]) is the production instance; [`Reflex/Pure.hs`][pure] is the specification: _"a pure implementation of Reflex, which is intended to serve as a reference for the semantics of the Reflex class. All implementations of Reflex should produce the same results as this implementation"_. The current unreleased ChangeLog states the direction of travel: _"The goal of this release is to bring hosts closer to Reflex's denotational model of time as implemented by `Reflex.Pure`"_ ([`ChangeLog.md`][changelog]).

Compared with its siblings, Reflex is [Sodium][sodium]'s closest relative (both discrete, transactional, glitch-free, with a value/stream split), but where Sodium exposes concrete classes, Reflex abstracts the _engine_ behind a type parameter and every effect behind a capability class.

---

## How it works

### Three types and a timeline

The `Reflex` class ([`Reflex/Class.hs` L246–L387][class-reflex]) owns the data families:

```haskell
class ( MonadHold t (PushM t), MonadSample t (PullM t), MonadFix (PushM t)
      , Functor (Dynamic t), Applicative (Dynamic t), Monad (Dynamic t) ) => Reflex t where
  data Behavior t :: Type -> Type
  data Event t :: Type -> Type
  data Dynamic t :: Type -> Type
  data Incremental t :: Type -> Type
  never    :: Event t a
  constant :: a -> Behavior t a
  push     :: (a -> PushM t (Maybe b)) -> Event t a -> Event t b
  pull     :: PullM t a -> Behavior t a
  switch   :: Behavior t (Event t a) -> Event t a
  coincidence :: Event t (Event t a) -> Event t a
  current  :: Dynamic t a -> Behavior t a
  updated  :: Dynamic t a -> Event t a
  -- … mergeG, fanG, unsafeBuildDynamic, unsafeBuildIncremental, coercions
```

The doc comments define the split precisely: a `Behavior` _"can be sampled at will, but it is not possible to be notified when they change"_; an `Event` _"during any given frame … is either occurring or not occurring"_; a `Dynamic` is _"Basically a combination of a 'Behavior' and an 'Event', with a rule that the 'Behavior' will change if and only if the 'Event' fires"_ ([`Reflex/Class.hs`][class-reflex]).

The `t` parameter is the **timeline**: _"Timelines are fully-independent FRP contexts, and the type of the timeline determines the FRP engine to be used"_ ([`Reflex/Class.hs`][class-reflex]). `type Spider = SpiderTimeline Global` is the statically allocated default; `withSpiderTimeline` reifies a fresh one with a rank-2 continuation, so values from two timelines cannot be mixed — the ST-monad trick ([`Spider/Internal.hs` L2621, L2841][spider]).

### A frame, phase by phase

A **frame** is Reflex's transaction: one batch of trigger firings, one propagation, one set of state updates. `runFrame` and `propagateAndRead` in [`Spider/Internal.hs`][spider] do, in order:

1. Take the timeline lock (`_spiderTimeline_lock :: MVar ()`); frames on a timeline are serialised.
2. Write each root trigger's occurrence and `propagate` it depth-first to its subscribers. Pure push nodes (`fmap`, `push`, `gate`) run immediately.
3. Nodes that join several parents — `merge`, `coincidence`, a reconnected `switch` — do not run when the first parent fires. They `scheduleMerge` themselves into a `HeightQueue` keyed by their **height**; the loop then drains the queue lowest-height-first (`heightQueueNext`, _"Running height …"_) ([`Spider/Internal.hs` L1649–L1675][spider-propagate], [`Spider/Height.hs`][height]).
4. Clear occurrences; apply every deferred `hold` assignment (`writeIORef vRef v`) and invalidate the pulled `Behavior`s that read them.
5. Re-subscribe `switch` nodes whose behaviour changed, apply merge patches, unsubscribe the old parents, recalculate heights.

A node's height is one more than its highest parent (`heightBagSuccHeight`). A merge whose height is not above the current height is a **causality loop**: `checkCycle` throws `EventLoopException` (_"causality loop detected"_) ([`Spider/Internal.hs` L1809, L2081][spider]). Reflex does not reject cycles statically; it detects them while propagating.

### Getting values in and out

External input enters through a trigger. `TriggerEvent` offers `newTriggerEvent :: m (Event t a, a -> IO ())`; the standard `TriggerEventT` writes each invocation to a `Chan`, and the host's loop (`runHeadlessApp`, reflex-dom's main loop) reads that `Chan` and fires one frame per batch ([`TriggerEvent/Class.hs`][trigger-class], [`TriggerEvent/Base.hs`][trigger-base], [`Host/Headless.hs`][headless]). Output leaves through `PerformEvent`: `performEvent :: Event t (Performable m a) -> m (Event t a)`, whose result _"will generally occur later than the input 'Event', since most 'Performable' actions cannot be performed during 'Event' propagation"_ ([`PerformEvent/Class.hs`][perform-class]). Effects therefore run between frames, and their results start new frames.

---

## Evaluation model

- **Push-pull.** `Event`s are pushed from triggers; `Behavior`s are pulled and cached, recomputed only after an invalidation (`pull` _"will be recomputed whenever any of the read 'Behavior's changes"_). `Dynamic` carries both halves, so a consumer chooses notification (`updated`) or sampling (`current`).
- **Lazy subscription, hot streams.** An `Event` node exists only while something subscribes; nodes are held by weak references and since 0.10 _"garbage collected together with the last subscriber"_ ([`ChangeLog.md`][changelog]). [`Quickref.md`][quickref] notes that `traceEvent` _"Only prints if Event is ultimately used."_ There is no cold/replay notion: an occurrence missed is gone; a `Behavior` always has a value.
- **Glitch-free.** Height ordering means a merge sees all simultaneous parents before it runs; `hold` updates apply at the end of the frame, so every `sample` in a frame sees the same, _old_ value. `hold`'s doc: _"if the occurrence that sets the 'Behavior' (or one that is simultaneous with it) is used to sample the 'Behavior', it will see the **old** value"_ (Haddock emphasis rendered as bold) ([`Reflex/Class.hs` L452–L459][class-hold]).
- **Simultaneity is first-class.** Two events firing in one frame _coincide_; combinators must say what happens then (`leftmost` is left-biased, `align` yields `These a b`, `mergeWith` combines). Much of the API's variant naming (`Promptly`, below) exists to answer the coincidence question.
- **Synchronous within a frame, batched across.** One frame is atomic and single-threaded; `performEvent` results start a later frame.

## Composition

The operator surface is large: a single-line signature grep finds 75 top-level functions in [`Reflex/Class.hs`][class] and 38 in [`Reflex/Dynamic.hs`][dynamic] (an undercount: multi-line signatures are missed), on top of ~20 class methods and everything granted by instances (`Functor`, `Applicative`, `Monad` on `Behavior`/`Dynamic`; `Semigroup` and `Filterable` on `Event`; `Align` from `semialign`). Families, by what they produce:

| Purpose                    | Combinators                                                                                                               |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Event → Event              | `fmap`, `fmapMaybe`/`mapMaybe`, `ffilter`, `push`, `pushAlways`, `difference`, `headE`/`tailE`/`headTailE`                |
| Sample a value at an event | `tag`, `attach`, `attachWith`, `attachWithMaybe`, `gate`, `<@>`, `<@`; `tagPromptlyDyn`, `attachPromptlyDyn…`             |
| Combine events             | `<>`, `leftmost`, `mergeWith`, `mergeList`, `merge` (over a `DMap`), `mergeMap`, `align`/`alignWith`                      |
| Fan out                    | `fan`/`fanMap` → `EventSelector`, `select`; `fanEither`, `fanThese`; `demux`/`demuxed` for `Dynamic`                      |
| State                      | `hold`, `holdDyn`, `foldDyn`, `foldDynMaybe`, `foldDynM`, `count`, `toggle`, `accum*`, `mapAccum*`, `holdUniqDyn`         |
| Higher-order (flatten)     | `switch`, `switchHold`, `switchDyn`, `switchHoldPromptly`, `switchPromptlyDyn`, `coincidence`, `join`, `switcher`         |
| Dynamic networks           | `runWithReplace` (`Adjustable`), `networkHold`, `networkView`, `listWithKey`, `listHoldWithKey`, `listWithKeyShallowDiff` |
| Effects and time           | `performEvent`, `performEvent_`, `performEventAsync`, `delay`, `debounce`, `throttle`, `batchOccurrences`, `tickLossy`    |

`gate :: Behavior t Bool -> Event t a -> Event t a` is literally our toggle: _"only occurs if the supplied 'Event' occurs and the 'Behavior' is true at the time of occurrence"_, defined as one `attachWithMaybe` ([`Reflex/Class.hs` L1200–L1203][class-gate]).

`fan` is the efficient one-to-many primitive: _"Using 'EventSelector's and the 'fan' primitive is far more efficient than (but equivalent to) using 'mapMaybe' to select only the relevant occurrences"_ ([`Reflex/Class.hs` L595–L607][class-selector]). A `fanMap` over `Map k a` delivers each key only to that key's subscribers: O(log n) per occurrence rather than O(n) filters.

**Collections** are where `Incremental` matters. `Incremental t p` is _"a more general form of a 'Dynamic'. Instead of always fully replacing the value, only parts of it can be patched"_ (`PatchMap`, `PatchIntMap`, `PatchMapWithMove`). `listWithKey` turns a `Dynamic (Map k v)` into one child network per key, built and torn down by diff ([`Reflex/Collection.hs` L82][collection]); since 0.9 it filters unchanged children, which _"imposes an `Eq` constraint on the child values"_ ([`ChangeLog.md`][changelog]). Compare the incremental-computation background in [../parsing/theory/incremental.md][incremental] and [jane-street-incremental.md][jsi].

**Writer-like channels upward**: `EventWriter t w m` (`tellEvent :: Event t w -> m ()`) lets a child emit into a monoid collected by its parent; `Requester t m` emits requests and receives responses, _"Semantically, the response event occurs at a later time than the request event"_ ([`EventWriter/Class.hs`][eventwriter], [`Requester/Class.hs`][requester]). `PerformEventT` is itself implemented as a `RequesterT` ([`PerformEvent/Base.hs` L77][perform-base]).

### API structure and naming

**Source / transform / sink.** Reflex separates them by _capability_, not by type:

- _Sources_ are created only in a monad holding a source capability: `TriggerEvent` (`newTriggerEvent`), `PostBuild`/`now` (the build instant), `MonadHold` (`hold` creates state). Widgets in reflex-dom are sources: `inputElement` returns `_inputElement_value :: Dynamic t Text` and `_inputElement_input :: Event t Text` ([`Builder/Class.hs` L113, L332–L335][rd-builder]).
- _Transforms_ are pure functions when they need no "now" (`fmap`, `gate`, `switch`, `leftmost`) and monadic when they create state (`holdDyn`, `foldDyn`, `switchHold`, `debounce`). The monad is the marker of statefulness.
- _Sinks_ are `performEvent_`, a host's read phase, or (in reflex-dom) a widget that consumes a `Dynamic` (`dynText`, `elDynAttr`). There is no `subscribe`/`listen` in user code.

**The Quickref is organised by return type and capability**, not by operator name: sections _"Functions producing Event"_, _"Functions producing Behavior"_, _"Functions producing Dynamic"_, _"Flattening functions"_, then capability sections, with every signature simplified (`t` and constraints erased) and tagged ([`Quickref.md`][quickref]):

```haskell
[ ]   -- Pure function
[S]   -- Function runs in any monad supporting MonadSample
[H]   -- Function runs in any monad supporting MonadHold
-- later: [B] PostBuild, [A] Adjustable, [T] TriggerEvent, [P] PerformEvent
[P,T]   delay :: NominalDiffTime -> Event t a -> m (Event t a)
```

That annotation scheme is the most transferable idea in the document: the reader learns, per function, _what context it needs_, which is exactly the question a D user asks of an operator (does it need a `Scope`, a fiber, nothing?).

**Modules** pair a class with its standard implementation: `Reflex.X.Class` declares the capability, `Reflex.X.Base` provides the `XT` transformer (`PerformEvent`, `TriggerEvent`, `PostBuild`, `EventWriter`, `DynamicWriter`, `BehaviorWriter`, `Requester`, `Query`). Primitives live in the `Reflex` class; derived operators are free functions in `Reflex.Class`, `Reflex.Dynamic`, `Reflex.Time`, `Reflex.Network`, `Reflex.Collection`; `Reflex` re-exports everything.

**Name families** (from [`Reflex/Class.hs`][class], [`Reflex/Dynamic.hs`][dynamic]):

| Pattern              | Meaning                                                     | Examples                                                                             |
| -------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| suffix = result type | which of the three types comes back                         | `holdDyn`, `foldDyn`, `zipDyn`, `switchDyn`; `accumB`, `mapAccumB`; `headE`, `tailE` |
| `Hold` infix         | creates state, needs `MonadHold`                            | `switchHold`, `holdUniqDyn`, `listHoldWithKey`, `networkHold`                        |
| `Promptly`           | at a coincidence, use the **new** value/event               | `switchHoldPromptly`, `switchPromptlyDyn`, `tagPromptlyDyn`, `attachPromptlyDyn`     |
| `With`               | takes a combining function                                  | `attachWith`, `zipDynWith`, `alignWith`, `mergeWith`                                 |
| `Maybe`              | the function may drop (return `Nothing`)                    | `fmapMaybe`, `attachWithMaybe`, `foldDynMaybe`, `mapAccumMaybeDyn`                   |
| `M`                  | the function runs in `PushM` (may sample/hold)              | `foldDynM`, `accumM`, `mapAccumMaybeM`                                               |
| `_`                  | discard the result                                          | `performEvent_`, `selectViewListWithKey_`                                            |
| `'`                  | a generalisation, or "also return the element"              | `tickLossyFrom'`, reflex-dom `el'`, `elAttr'`                                        |
| `Cheap`              | uncached; _"may be run multiple times without any caching"_ | `pushCheap`, `fmapCheap`, `tagCheap`, `mergeWithCheap`                               |
| `ffor`               | flipped `fmap` (lambda last)                                | `ffor`, `fforMaybe`, `ffor2`, `ffor3`                                                |

The families compose mechanically, which is both the system's strength and its cost: `attachPromptlyDynWithMaybe`, `mapAccumMaybeMB`, `switchHoldPromptOnly`. Every name is predictable; many are long.

`Promptly` is marked as the dangerous direction everywhere it appears. `switchHold`'s doc: _"Use this rather than 'switchHoldPromptly' and 'switchHoldPromptOnly' unless you are absolutely sure you need to act on the new event in the coincidental case"_; `switchPromptlyDyn`'s: _"The timing requirements that switching before imposes are likely to bring down your app unless you are very careful"_ ([`Reflex/Class.hs` L1075–L1112][class-switch], [`Reflex/Dynamic.hs` L178–L197][dynamic-switch]). The safe default got the short name.

**A user-defined operator** is an ordinary polymorphic function whose constraints list the capabilities it uses. `debounce` itself ([`Reflex/Time.hs` L224–L229][time-debounce]):

```haskell
debounce :: (MonadFix m, MonadHold t m, PerformEvent t m, TriggerEvent t m, MonadIO (Performable m))
         => NominalDiffTime -> Event t a -> m (Event t a)
debounce dt e = do
  n :: Dynamic t Integer <- count e
  let tagged = attachPromptlyDynWith (,) n e
  delayed <- delay dt tagged
  return $ attachWithMaybe (\n' (t, v) -> if n' == t then Just v else Nothing) (current n) delayed
```

**Regrets and renames** ([`ChangeLog.md`][changelog], `DEPRECATED` pragmas in source):

- `switchPromptly` → `switchHoldPromptly`, `switchPromptOnly` → `switchHoldPromptOnly`: _"The 'switchHold\*' naming convention was chosen because those functions are more closely related to each other than they are to 'switch'."_ ([`Reflex/Class.hs` L1789–L1798][class-deprecated]). Naming by _what it builds from_ (a hold) won over naming by _what it resembles_.
- `MonadDynamicWriter` → `DynamicWriter` (0.6.0.0) and `MonadBehaviorWriter` → `BehaviorWriter` (0.7.0.0, _"for consistency with `EventWriter`/`DynamicWriter`"_): the `Monad` prefix was dropped from capability names, but `MonadHold`/`MonadSample` kept it.
- `FunctorMaybe` deprecated for Witherable's `Filterable` (0.6.0.0) ([`FunctorMaybe.hs`][functormaybe]): a home-grown class replaced by the ecosystem one.
- `mergeIntMap` → `mergeInt` (0.10.0.0); `distributeListOverDynPure` → `distributeListOverDyn`.
- _Unreleased_: `PostBuild` deprecated — _"Use `now` of `MonadHold` instead"_ — and `getPostBuild` is now `now`; `NotReady` _"is an artifact from early reflex development and no longer has a purpose"_; `SpiderHost` lost its `MonadSample`/`MonadHold` instances because _"Each `sample`, `hold` or `subscribeEvent` in `SpiderHost` used to run at its own instant, so you could miss an occurrence of `now`."_ A capability class was retired once a primitive (`now`, added to `MonadHold` in 0.7.2/0.8.0) subsumed it.
- reflex-dom: `TextInput`/`textInput` deprecated — _"Use 'inputElement' directly"_ ([`Widget/Input.hs` L55][rd-input]); `MonadWidget` survives in `Reflex.Dom.Old` as an 18-constraint synonym class ([`Old.hs` L105–L129][rd-old]).

**The ergonomic cost of the capability style** is visible in those constraint lists: `debounce` needs five; `MonadHeadlessApp` is a 23-constraint tuple ([`Host/Headless.hs` L25][headless]); `MonadWidget` bundles 18 constraints plus CPP. Errors from a missing `MonadFix` or a mismatched `Performable m` are notoriously opaque, which is why the Quickref erases constraints entirely. Compare the mtl-style discussion in [../algebraic-effects/haskell-mtl.md][mtl].

## Time and scheduling

There is no clock in the core: time is the sequence of frames. Wall-clock time lives in [`Reflex/Time.hs`][time] and is built entirely from `performEventAsync` plus `forkIO`:

```haskell
delay :: (PerformEvent t m, TriggerEvent t m, MonadIO (Performable m)) => NominalDiffTime -> Event t a -> m (Event t a)
delay dt e = performEventAsync $ ffor e $ \a cb -> liftIO $ void $ forkIO $ do
  Concurrent.delay $ ceiling $ dt * 1000000
  cb a
```

Every occurrence forks a GHC thread that sleeps and then triggers a new frame ([`Reflex/Time.hs` L120–L123][time-delay]). Durations are `NominalDiffTime` (seconds, picosecond resolution); timers are lossy `TickInfo` streams (`_tickInfo_lastUTC`, `_tickInfo_n`, `_tickInfo_alreadyElapsed`) from `tickLossy`/`clockLossy`, which drop ticks _"If the system starts running behind"_ ([`Reflex/Time.hs` L45–L95][time-tick]).

**Debounce** (quoted above) is generation counting, not timer cancellation: `count e` numbers every occurrence; each is delayed tagged with its number; when it returns, it passes only if `current n` still equals its tag. Older timers still sleep and still fire a frame, which `attachWithMaybe` discards. `throttle` and `batchOccurrences` are state machines over `align e delayed`, tied in a loop with `rec` (`RecursiveDo`) ([`Reflex/Time.hs` L224–L280][time-debounce]).

**Can the duration change at runtime?** Not in the library: `debounce`, `throttle`, `delay` take a plain `NominalDiffTime`. Two workarounds exist. Rebuild the debouncer with `networkHold` on each change, which discards its pending occurrence along with the old subnetwork. Or write a five-line `debounceB` that samples a `Behavior t NominalDiffTime` in the `performEventAsync` (shown in [the worked pipeline](#the-worked-pipeline)). One function takes the lag as a parameter: `throttleBatchWithLag :: (Event t () -> m (Event t ())) -> Event t a -> m (Event t a)` — _"For example, using `delay 20` would give a simple time-based throttle."_ That is the only hook for injecting a different clock.

There are no schedulers or dispatchers. Within a frame, order is height order; across frames, order is the trigger `Chan`'s FIFO.

## Concurrency and cancellation

- **One frame at a time per timeline**, under `_spiderTimeline_lock`. Triggers may be called from any thread; they enqueue on the `Chan` and the host thread fires them.
- **Async work** is `performEventAsync`: _"NOTE: Despite the name, 'performEventAsync' does not run its action in a separate thread - although the action is free to invoke forkIO and then call the callback whenever it is ready"_ ([`PerformEvent/Class.hs`][perform-class]). CPU-bound work runs in a forked thread; the result re-enters as a trigger.
- **Latest-wins is `switch`, and it is about events, not work.** `switchHold never eOfE` or `switchDyn` listens to the newest inner event; the old one is unsubscribed at the end of the switching frame. Nothing reaches the thread that would have fed it.
- **No cancellation primitive exists.** `Adjustable` says so outright: _"obviously, IO (and some other side-effects) cannot be undone, so it is up to the instance implementer to determine what the best meaning for this class is in such cases"_ ([`Adjustable/Class.hs` L43–L48][adjustable]). When `runWithReplace`/`networkHold` replaces a subnetwork, its forked threads keep running; their trigger callbacks fire into an event nobody subscribes to, and the occurrence is dropped. Stale results are _discarded_, never _prevented_.
- **Real cancellation is manual**: keep a `ThreadId` in an `IORef` and `killThread` it from a `performEvent_`. GHC's `throwTo` _"does not return until the exception has been raised in the target thread"_ ([base `Control.Exception`][throwto]) — it waits for delivery, not for the thread's cleanup to finish. That is cancel without join.

## Errors and completion

Neither applies in the stream sense. An `Event` has no error channel and no completion: it is a set of occurrences over all time (`never` is the empty one). Failure is a value (`Event t (Either e a)`, split by `fanEither`) or a Haskell exception: an exception thrown inside `performEvent` propagates to the host and ends the program unless caught there; `EventLoopException` reports a causality cycle at run time. "Done" is modelled as an event too: `runHeadlessApp` takes a network returning `Event t a` and _"The FRP network is closed at the first occurrence of the resulting 'Event'"_ ([`Host/Headless.hs`][headless]). One-shot behaviour comes from `headE`.

## State and sharing

- **Cells**: `Behavior` (no notification) and `Dynamic` (notification). `Dynamic` exists because neither half suffices for a UI: a widget needs the current value at build time _and_ an event to patch the DOM. Pure `fmap` over a `Dynamic` keeps both in sync without a `hold`, which a `Behavior`+`Event` pair could not.
- **Conflation**: `Dynamic`'s `updated` fires on every assignment, even to an equal value. `holdUniqDyn :: Eq a => Dynamic t a -> m (Dynamic t a)` filters (_"only signals changes if the values actually change"_), and `UniqDynamic` makes this the type's invariant ([`Reflex/Dynamic.hs` L114–L123][dynamic-uniq], [`Dynamic/Uniq.hs`][uniq]). Within one frame, a trigger may fire only once (_"one trigger fired twice in one frame"_ is a debug assertion), so multiple writes to a trigger between frames are batched by the host, not conflated by the library.
- **Multicast** is the default: every `Event` node is shared by all subscribers (`cacheEvent`), and `fan` makes keyed multicast cheap. There is no `share()` operator because there is nothing unshared.
- **Sampling freshness**: `tag (current d) e` sees the old value at a coincidence; `tagPromptlyDyn d e` the new one — and _"the output 'Event' may not be used to directly change the input 'Dynamic', because that would mean its value depends on itself. **When creating cyclic data flows, generally `tag (current d) e` is preferred.**"_ (Haddock markup normalised) ([`Reflex/Dynamic.hs` L259–L270][dynamic-tag]).
- **Cycles** are declared with `mdo`/`rec` (`MonadFix m`): a `foldDyn` can read an event defined below it. Delaying through `current`/`hold` breaks the instant; reading through `updated`/`Promptly` creates a same-frame dependency, which is where `EventLoopException`s come from.

## Lifetime and ownership

Ownership is the **network position**, and teardown is **garbage collection**. Nodes subscribe through weak bags (`Data.WeakBag`); an unreferenced subtree is collected with its last subscriber. Structural lifetime comes from `Adjustable`: a subnetwork built by `runWithReplace`, `networkHold`, `dyn`/`widgetHold` (reflex-dom) or a `listWithKey` child lives until the next replacement, at which point its subscriptions are dropped (`switchSubscriptionsToKill`, `mergeSubscriptionsToKill` in `runFrame`). The lifetime is _lexical in the build monad_ — a child network created inside a parent's `runWithReplace` slot dies with that slot — which is close to structured scopes, except that effects started by the child (forked threads) are not owned. `newEventWithLazyTriggerWithOnComplete` adds setup/teardown for external listeners, with the caveat that _"there is no guarantee that the teardown will be executed promptly, or even at all"_ ([`TriggerEvent/Class.hs`][trigger-class]). The 0.10 ChangeLog lists half a dozen fixed leaks and finalizer races (`fanInt` retention, `cacheEvent` thunks, `switch` races): GC-driven teardown is hard to make correct.

## Testing

- **Semantics** are tested against the reference implementation: test networks are written against a `TestPlan` class (`plan :: [(Word, a)] -> m (Event t a)` schedules occurrences at frame numbers) and run on `Pure Int` (time = `Int`) and on Spider, with outputs compared ([`test/Reflex/TestPlan.hs`][testplan], [`test/Reflex/Test/CrossImpl.hs`][crossimpl]). This is the strongest part: an executable denotation.
- **Applications** use `runHeadlessApp` ([`test/Headless.hs`][test-headless]) or the third-party [`reflex-test-host`][rth] (0.1.2.3, 2023-11-25), whose `runAppSimple :: (Event t eIn -> TestGuestT t m (Event t eOut)) -> [eIn] -> IO [[Maybe eOut]]` feeds one input per frame and returns per-frame outputs.
- **No virtual time.** Both units are frames. `Reflex.Time` calls `forkIO` and `Concurrent.delay` directly, so a test of `debounce` sleeps for real and is timing-sensitive. A deterministic debounce test means writing the operator over an injected lag (the `throttleBatchWithLag` shape) and passing a lag that is a test-controlled trigger. Reflex has nothing like `TestClock`.

## The worked pipeline

reflex-dom, with two small user-defined operators: a debounce whose duration is a `Behavior` and which can be reset, and a latest-wins async runner with manual thread killing.

```haskell
{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (evaluate)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (traverse_)
import Data.IORef
import Data.Time.Clock (NominalDiffTime)
import Reflex.Dom

-- Debounce whose duration is sampled per occurrence; `reset` invalidates a pending one.
debounceB :: (MonadHold t m, MonadFix m, PerformEvent t m, TriggerEvent t m, MonadIO (Performable m))
          => Behavior t NominalDiffTime -> Event t () -> Event t a -> m (Event t a)
debounceB dur reset e = do
  gen <- count (leftmost [() <$ e, reset]) :: m (Dynamic t Int)
  fired <- performEventAsync $ ffor (attach dur (attachPromptlyDyn gen e)) $ \(d, gx) cb ->
    liftIO . void . forkIO $ threadDelay (ceiling (d * 1e6)) >> cb gx
  pure $ attachWithMaybe (\g (g', x) -> if g == g' then Just x else Nothing) (current gen) fired

-- Latest-wins worker: a new request (or `reset`) kills the running thread; stale results are dropped.
latestAsync :: (MonadIO m, MonadHold t m, MonadFix m, PerformEvent t m, TriggerEvent t m, MonadIO (Performable m))
            => Event t () -> (a -> IO b) -> Event t a -> m (Event t b)
latestAsync reset work e = do
  gen <- count (leftmost [() <$ e, reset]) :: m (Dynamic t Int)
  running <- liftIO (newIORef Nothing)
  let stop = readIORef running >>= traverse_ killThread
  performEvent_ $ liftIO stop <$ reset
  done <- performEventAsync $ ffor (attachPromptlyDyn gen e) $ \(g, x) cb -> liftIO $ do
    stop
    tid <- forkIO $ work x >>= evaluate >>= \r -> cb (g, r)
    writeIORef running (Just tid)
  pure $ attachWithMaybe (\g (g', r) -> if g == g' then Just r else Nothing) (current gen) done

app :: MonadWidget t m => m ()
app = do
  q   <- inputElement def
  ivl <- inputElement $ def & inputElementConfig_initialValue .~ "300"
  btn <- button "on/off"
  enabled <- toggle True btn                                        -- Dynamic t Bool
  let durB    = current (parseMs <$> _inputElement_value ivl)       -- Behavior t NominalDiffTime
      off     = () <$ ffilter not (updated enabled)
      queries = gate (current enabled) (_inputElement_input q)      -- the toggle is `gate`
  debounced <- debounceB durB off queries
  digests   <- latestAsync off hashFileSet debounced
  status <- holdDyn "idle" $ leftmost [showDigest <$> digests, "hashing…" <$ debounced, "off" <$ off]
  el "div" $ dynText status
```

**Trace** (frames F1, F2, …; each user action or thread callback is one frame):

- _Keystroke during debounce._ F1: `_inputElement_input` fires; `gate` samples `enabled` (True); `count` makes `gen` = n+1 and `attachPromptlyDyn` tags the occurrence n+1 in the same frame; `durB` is sampled (300 ms); after the frame, `performEventAsync` forks a sleeper. The previous sleeper (tag n) is still asleep. When it wakes it fires frame F2, where `attachWithMaybe` sees `current gen` = n+1 ≠ n and drops it. One sleeping thread and one wasted frame per keystroke; nothing is cancelled.
- _Keystroke during hash._ The new query's debounce completes in some frame Fk; `latestAsync`'s `gen` increments; after the frame the action runs `stop` (`killThread` on the hashing thread, blocking until the exception is _delivered_, not until the thread unwinds) and forks a new hash. Had we used the library idiom (`performEventAsync` without the `IORef`), the old hash would run to completion and its result would be dropped by the generation filter.
- _Interval change._ Editing `ivl` updates its `Dynamic`; `durB` changes at the end of that frame. A pending sleeper keeps the duration it was forked with; the next keystroke uses the new one. With library `debounce` plus `networkHold` instead, the pending query would be lost.
- _Toggle off._ `btn` fires; `enabled` becomes False at frame end; `off` fires in the same frame, incrementing both generations, so the pending sleeper's and any in-flight hash's results will be dropped; `performEvent_` kills the hash thread after the frame. The debounce sleeper is not killed — it wakes, starts a frame, and is filtered. `gate` sees False from the next frame on (in the toggle frame itself it still samples True, which is harmless here because no keystroke coincides).

**Fit with a per-frame UI.** Reflex is the opposite of rebuild-every-frame: the network and the DOM are built once and patched by events, and a Reflex "frame" is a transaction, not a render tick. What transfers is the shape of state: our frame-polled `Cell!T` is a `Behavior` (`sample`/`current`), and a `Cell` plus its version counter is a `Dynamic` (the version bump is `updated`). What does not transfer is cancellation: on a structured-concurrency loop, the generation-counter pattern that Reflex needs for both debounce and latest-wins collapses into cancelling the child scope.

## Strengths

- The most complete higher-order FRP vocabulary in production use: `switch`/`switchHold`/`switchDyn`, `runWithReplace`, `listWithKey`, `Incremental` patches, keyed `fan`.
- Glitch-freedom and simultaneity are specified (a reference implementation) and enforced (height-ordered merges, end-of-frame `hold`).
- Cost scales with what changes, not with the network: lazy subscription, `fan`/`select`, `demux`, `Incremental` merges.
- A clean source/transform/sink split by capability: pure operators are visibly pure; anything stateful is monadic; effects are named by class.
- Quickref's organisation by result type with capability tags is an excellent reference format.
- Naming is systematic and safe-by-default (`switchHold` short, `switchHoldPromptly` long and warned against).

## Weaknesses

- No cancellation: async work is fire-and-forget, latest-wins is discard-on-arrival, and `Adjustable` admits IO cannot be undone.
- No virtual time: `Reflex.Time` hard-codes `forkIO` + wall-clock delay; time-based operators cannot be tested deterministically without rewriting them.
- Time operators take fixed `NominalDiffTime`; a runtime-adjustable debounce is user code.
- Large constraint sets (`MonadWidget`, `MonadHeadlessApp`) and opaque type errors; the `t` parameter appears in every signature.
- GC-driven teardown has produced a long tail of leaks and finalizer races (0.10 ChangeLog).
- Causality loops are detected at run time, not prevented; the `Promptly` variants are documented as likely to "bring down your app".
- No error or completion channel; "done" and "failed" must be modelled as ordinary events.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                              | Trade-off                                                                                              |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `Event`/`Behavior`/`Dynamic` as three types                         | Separate notification from sampling; `Dynamic` gives a UI both at once | Three variants of every combinator (`tag`/`tagPromptlyDyn`, `hold`/`holdDyn`)                          |
| Engine behind a type-indexed class (`Reflex t`)                     | Swappable engines, a pure reference, timeline isolation                | `t` everywhere; dictionary passing unless specialised (`SPECIALIZE`, `-fexpose-overloaded-unfoldings`) |
| Capability classes (`MonadHold`, `PerformEvent`, …)                 | Constraints document and restrict what a function may do               | Constraint explosion; opaque errors; bundles like `MonadWidget` erase the precision again              |
| Frames with height-ordered merges, end-of-frame `hold`              | Glitch-free, deterministic simultaneity                                | Run-time causality-loop detection; `Promptly` coincidence semantics are subtle                         |
| Effects only via `performEvent`, results in a later frame           | Keeps propagation pure                                                 | Every async step is an extra frame; no ownership of forked work                                        |
| Latest-wins = `switch` (unsubscribe), not cancel                    | Purely semantic; needs no runtime support                              | Stale work runs to completion; generation counters everywhere                                          |
| Time from `forkIO` + wall clock                                     | Simple; works on GHC and GHCJS                                         | No virtual time; non-deterministic tests                                                               |
| GC + weak references for teardown                                   | No explicit dispose in user code                                       | Leaks and finalizer races; teardown timing unspecified                                                 |
| Retire classes once a primitive subsumes them (`PostBuild` → `now`) | Fewer capabilities, closer to the denotation                           | Breaking churn across releases                                                                         |

## Sources

- reflex at `f443526bd2a9d4ba43f65f3a755d21e61082f4e0`: [`README.md`][readme], [`Quickref.md`][quickref], [`ChangeLog.md`][changelog], [`reflex.cabal`][cabal]; [`Reflex/Class.hs`][class], [`Reflex/Dynamic.hs`][dynamic], [`Reflex/Dynamic/Uniq.hs`][uniq], [`Reflex/Time.hs`][time], [`Reflex/PerformEvent/Class.hs`][perform-class], [`Reflex/PerformEvent/Base.hs`][perform-base], [`Reflex/TriggerEvent/Class.hs`][trigger-class], [`Reflex/TriggerEvent/Base.hs`][trigger-base], [`Reflex/PostBuild/Class.hs`][postbuild], [`Reflex/Adjustable/Class.hs`][adjustable], [`Reflex/Network.hs`][network], [`Reflex/Collection.hs`][collection], [`Reflex/EventWriter/Class.hs`][eventwriter], [`Reflex/Requester/Class.hs`][requester], [`Reflex/FunctorMaybe.hs`][functormaybe], [`Reflex/Spider/Internal.hs`][spider], [`Reflex/Spider/Height.hs`][height], [`Reflex/Host/Class.hs`][host-class], [`Reflex/Host/Headless.hs`][headless], [`Reflex/Pure.hs`][pure]; tests [`TestPlan.hs`][testplan], [`CrossImpl.hs`][crossimpl], [`Headless.hs`][test-headless].
- reflex-dom at `de31ceff3d995381da661dc25b50e5b99fdd6316`: [`Quickref.md`][rd-quickref], [`Reflex/Dom/Builder/Class.hs`][rd-builder], [`Reflex/Dom/Widget/Input.hs`][rd-input], [`Reflex/Dom/Old.hs`][rd-old].
- [reflex-frp.org][site]; [Hackage: reflex][hackage]; [Hackage: reflex-test-host][rth]; Ryan Trinkle, _Reflex: Practical Functional Reactive Programming_, NY Haskell User's Group ([slides][nyhug-slides], [video][nyhug-video]); [base `Control.Exception.throwTo`][throwto].
- Related: [index][index], [concepts][concepts], [comparison][comparison], [Sodium][sodium], [RxJS][rxjs], [Elm][elm], [Yampa][yampa], [synchronous languages][synchronous], [Jane Street Incremental][jsi], [Effect-TS][effect-ts], [mtl][mtl].

<!-- References -->

[readme]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/README.md
[quickref]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/Quickref.md
[changelog]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/ChangeLog.md
[cabal]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/reflex.cabal
[class]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Class.hs
[class-reflex]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Class.hs#L246-L387
[class-hold]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Class.hs#L443-L490
[class-selector]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Class.hs#L595-L618
[class-switch]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Class.hs#L1075-L1115
[class-gate]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Class.hs#L1200-L1203
[class-deprecated]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Class.hs#L1789-L1798
[dynamic]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Dynamic.hs
[dynamic-uniq]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Dynamic.hs#L114-L123
[dynamic-switch]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Dynamic.hs#L178-L201
[dynamic-tag]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Dynamic.hs#L259-L270
[uniq]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Dynamic/Uniq.hs
[time]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Time.hs
[time-tick]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Time.hs#L45-L100
[time-delay]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Time.hs#L119-L123
[time-debounce]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Time.hs#L222-L290
[perform-class]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/PerformEvent/Class.hs
[perform-base]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/PerformEvent/Base.hs#L75-L100
[trigger-class]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/TriggerEvent/Class.hs
[trigger-base]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/TriggerEvent/Base.hs
[postbuild]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/PostBuild/Class.hs
[adjustable]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Adjustable/Class.hs#L43-L53
[network]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Network.hs
[collection]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Collection.hs#L82-L88
[eventwriter]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/EventWriter/Class.hs
[requester]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Requester/Class.hs
[functormaybe]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/FunctorMaybe.hs
[spider]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Spider/Internal.hs
[spider-propagate]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Spider/Internal.hs#L1649-L1675
[height]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Spider/Height.hs
[host-class]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Host/Class.hs
[headless]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Host/Headless.hs
[pure]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Pure.hs
[testplan]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/test/Reflex/TestPlan.hs
[crossimpl]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/test/Reflex/Test/CrossImpl.hs
[test-headless]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/test/Headless.hs
[rd-quickref]: https://github.com/reflex-frp/reflex-dom/blob/de31ceff3d995381da661dc25b50e5b99fdd6316/Quickref.md
[rd-builder]: https://github.com/reflex-frp/reflex-dom/blob/de31ceff3d995381da661dc25b50e5b99fdd6316/reflex-dom-core/src/Reflex/Dom/Builder/Class.hs
[rd-input]: https://github.com/reflex-frp/reflex-dom/blob/de31ceff3d995381da661dc25b50e5b99fdd6316/reflex-dom-core/src/Reflex/Dom/Widget/Input.hs#L55
[rd-old]: https://github.com/reflex-frp/reflex-dom/blob/de31ceff3d995381da661dc25b50e5b99fdd6316/reflex-dom-core/src/Reflex/Dom/Old.hs#L105-L129
[site]: https://reflex-frp.org/
[hackage]: https://hackage.haskell.org/package/reflex
[rth]: https://hackage.haskell.org/package/reflex-test-host
[nyhug-slides]: https://reflex-nyhug.obsidian.systems/
[nyhug-video]: https://www.youtube.com/watch?v=mYvkcskJbc4
[throwto]: https://hackage.haskell.org/package/base/docs/Control-Exception.html#v:throwTo
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[sodium]: ./sodium.md
[rxjs]: ./rxjs.md
[elm]: ./elm.md
[yampa]: ./yampa.md
[synchronous]: ./synchronous-languages.md
[jsi]: ./jane-street-incremental.md
[effect-ts]: ./effect-ts.md
[incremental]: ../parsing/theory/incremental.md
[mtl]: ../algebraic-effects/haskell-mtl.md
