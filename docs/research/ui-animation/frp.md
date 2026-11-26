# Animation as FRP: Fran, Yampa, Elm, Reflex (Haskell, Elm)

Functional reactive programming was invented to describe animation: Fran (1997) made an animation a value, `Behavior a` = a function of continuous time, so a tween is literally `\t -> lerp a b (ease ((t - t0) / d))` and sampling is the runtime's business; its descendants keep the purity but move the clock to a driver (Yampa), to runtime messages (Elm), or to timer threads (Reflex).

| Field                    | Value                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | Haskell (Fran, Yampa, dunai/Rhine, Reflex); Elm (compiles to JavaScript)                                                                                                                                                                                                                                                                                                                                                                                             |
| License                  | Yampa, dunai, Rhine, Reflex, reflex-dom: BSD-3-Clause; `elm/browser`, `mgold/elm-animation`, `mdgriffith/elm-animator`: BSD-3-Clause (each `elm.json`); Fran 1.16: a Microsoft Research download licence linked from the [Fran home page][fran-home]                                                                                                                                                                                                                 |
| Repository               | Fran: none (zip releases on [conal.net/fran][fran-home]); [ivanperez-keera/Yampa][y-repo]; [ivanperez-keera/dunai][d-repo]; [turion/rhine][r-repo]; [elm/browser][eb-repo]; [mgold/elm-animation][ea-repo]; [mdgriffith/elm-animator][ear-repo]; [reflex-frp/reflex][rx-repo], [reflex-frp/reflex-dom][rd-repo]                                                                                                                                                      |
| Documentation            | Elliott & Hudak, [_Functional Reactive Animation_][fran-paper] ([author's page][fran-page]); Peterson, Elliott & Ling, [_Fran 1.1 Users Manual_][fran-manual] (1998-06-17); Elliott, [_Composing Reactive Animations_][fran-tutorial]; Courtney, Nilsson & Peterson, [_The Yampa Arcade_][arcade] ([PDF][arcade-pdf]); Elliott, [_Push-Pull Functional Reactive Programming_][push-pull] ([PDF][push-pull-pdf]); module docs of the sources below                    |
| Category                 | Animation as a pure value of time (Fran, elm-animation, elm-animator) or as a sampled signal function stepped by a host (Yampa, Rhine); time as a discrete event stream (Elm subscriptions, Reflex ticks)                                                                                                                                                                                                                                                            |
| Versions surveyed        | Fran 1.16 (docs for 1.1, 1998); Yampa `0.15.1` at `9dda030` (2026-10-21); dunai `407ff00` (2026-10-21); Rhine `1.8` at `698b693` (2026-09-21); `elm/browser` 1.0.2 at `1d28cd6` (2019-11-06); legacy `elm-lang/core` 3.0.0 at `09f3dd2` (2015-11-22); `mgold/elm-animation` 2.0.0 at `cb278e8` (2020-01-28); `mdgriffith/elm-animator` `master` (`elm.json` 2.0.0) at `12ca2ee` (2026-09-25); Reflex at `f443526` (2026-11-22); reflex-dom at `de31cef` (2026-11-23) |
| Animation state lives in | Fran: nowhere but the behaviour value (the runtime keeps only sampling state); Yampa: inside the running signal function (integrator accumulators in its continuation); Elm: in the `Model`, as an `Animation` record or a `Timeline state`; Reflex: in `Dynamic`s held by the network (`holdDyn`/`foldDyn`)                                                                                                                                                         |

> [!NOTE]
> This page covers four subjects, one `###` section each under
> [How it works](#how-it-works), and compares them along the catalog's spine in
> [Analysis](#analysis). The reactive-programming catalog already describes each
> as a reactive _runtime_ — [Yampa][rp-yampa], [Elm][rp-elm], [Reflex][rp-reflex],
> the shared [vocabulary][rp-concepts] and [how each is tested][rp-testing] — and
> those mechanics are not repeated here: this page is about what each one does
> with _animation_. The vocabulary (tween, closed form, retargeting) is the
> catalog's own [concepts page][concepts].

---

## Overview

### What it solves

The problem Fran set out to remove is the gap between what an animation _is_ and the frame loop that presents it. Elliott's tutorial states it:

> _"behaviors like motion and growth are generally gradual, continuous phenomena. Moreover, many such behaviors go on simultaneously. Computers, on the other hand, cannot directly accommodate either of these basic properties, because they do their work in discrete steps rather than continuously, and they only do one thing at a time. Graphics programmers have to spend much of their effort bridging the gap between what an animation is and how to present it on a computer."_ ([_Composing Reactive Animations_][fran-tutorial])

Fran's answer is to make the animation a first-class value over continuous time and leave the frame loop to the library. The paper's abstract ([author's page][fran-page]) names the two types and the claim that animation falls out of them:

> _"Behaviors are time-varying, reactive values, while events are sets of arbitrarily complex conditions, carrying possibly rich information. Most traditional values can be treated as behaviors, and when images are thus treated, they become animations."_

Every later system on this page keeps one half of that and gives up the other. Yampa keeps continuous-time semantics and the physics (integrals, switching) but makes signal functions, not signals, the values, to remove Fran's leaks. Elm keeps the pure view and drops time as a value: time arrives as a message, and an animation is whatever the model stores. Reflex keeps first-class `Behavior`s but over discrete frames, and has no animation layer of its own.

### Design philosophy

1. **Time is continuous; sampling is an implementation detail.** The push-pull paper restates Fran's position: _"Behaviors can change continuously (not just frequently), with discretization introduced automatically during rendering. The choice of continuous time makes programs simpler and more composable than the customary (for computer programming) choice of discrete time, just as is the case with continuous space for modeled imagery. For instance, vector and 3D graphics representations are inherently scalable (resolution-independent), as compared to bitmaps"_ ([_Push-Pull FRP_][push-pull-pdf] §1). An animation written against `time` does not know the frame rate.
2. **The denotation is a function.** _"Semantically, a (reactive) behavior is just a function of time, while an event … is a list of time/value pairs"_, written `type B a = T → a` ([_Push-Pull FRP_][push-pull-pdf] §2). The Fran manual says the same operationally: _"the type Behavior T is the same as Time -> T in that it maps time values onto values of type T"_ ([manual][fran-manual]). Lifting is pointwise: `at (fmap f b) = f ∘ at b`.
3. **Describe what is, not what to do.** _"events and behaviors describe things that exist, rather than actions that have happened or are to happen (i.e., what is, not what does)"_ ([_Push-Pull FRP_][push-pull-pdf] §2). The tutorial contrasts this with imperative code that must _"explicitly simulate rate-based animation by making lots of little discrete steps, accumulating approximations"_ ([tutorial][fran-tutorial]).
4. **The driver owns the clock (Yampa).** _"Reactimate approximates the continuous-time model presented here by performing discrete sampling of the signal function, invoking sense at the start and actuate at the end of each time step"_ ([_The Yampa Arcade_][arcade-pdf] §3.6).
5. **Time is just another input (Elm).** `elm/time`'s `Time.every` carries the warning _"**This function is not for animation.** Use the [`onAnimationFrame`] function for that sort of thing! It syncs up with repaints"_ ([`Time.elm`][et-every]); the animation libraries then treat the frame timestamp as an argument: elm-animation's `animate` _"takes the current time and an animation, and produces the current value"_ ([`README.md`][ea-readme]).

---

## How it works

### Fran

**Behaviours, events, reactivity.** A `Behavior a` is a value at every real time; `time :: Behavior Time` is the identity behaviour, and numeric classes are lifted so `wiggle = sin (pi * time)` oscillates with period 2 s. An `Event a` is _"a time-sorted list of occurrences"_, `[(Time, a)]`. `untilB :: GBehavior bv => bv -> Event bv -> bv` _"changes the course of a behavior when an event occurs"_; `switcher` does so repeatedly; `stepper` builds a piecewise-constant behaviour from an event; `snapshot :: Event a -> Behavior b -> Event (a, b)` samples a behaviour at each occurrence ([manual][fran-manual]). Images are behaviours too: `ImageB` composes with `over`, `move :: Vector2B -> ImageB -> ImageB`, `stretch :: RealB -> ImageB -> ImageB`, `withColor`, so _"when images are thus treated, they become animations"_.

**A tween is a behaviour.** Fran ships no tween combinator because none is needed; a tween is a lifted expression in `time`. As a sketch in the manual's vocabulary (untested — the 1.16 implementation runs on Hugs 98 under Windows and its author calls it stale on the [home page][fran-home]):

```haskell
-- the denotation of a tween: a pure function of time
tween :: Time -> DTime -> RealVal -> RealVal -> RealB
tween t0 d a b = lift1 f time
  where f t = a + (b - a) * ease (clamp 0 1 ((t - t0) / d))
        ease x = (1 - cos (pi * x)) / 2
        clamp lo hi = max lo . min hi

panel u = move (vector2XY (tween 0 0.75 (-1) 1) 0) (stretch 0.2 (withColor red circle))
```

Nothing is stored between frames: the runtime evaluates the behaviour at whatever instants it presents. Because the meaning is independent of the sampling instants, a 30 Hz and a 144 Hz presentation are samples of the same function.

**Time transformation.** `timeTransform :: GBehavior bv => bv -> Behavior Time -> bv` _"yields a new behavior which is evaluated in a transformed time-frame"_, and ``later dt b = b `timeTransform` (time - dt)``, ``faster x b = b `timeTransform` (time * x)`` and `slower x = faster (1/x)` are defined from it ([manual][fran-manual]). The tutorial staggers a sentence along the mouse path with `delayAnims dt anims = overs (zipWith later [0, dt ..] anims)` ([tutorial][fran-tutorial]). The display routine itself is a time transform: `userDelay bv u = later (constantB (userStartTime u)) bv`, so every displayed animation starts at its own local time 0 ([manual][fran-manual]). Time transformation is how Fran composes in time, and it is only possible because a behaviour is a function, not a running process.

**Physics by integration.** `integral :: (VectorSpace v) => Behavior v -> User -> Behavior v`; integrals may be mutually recursive, and the bouncing ball accumulates collision impulses as an event sum ([manual][fran-manual], example 11):

```haskell
example11 u = withColor red (moveXY 0 pos (stretch 0.1 circle))
 where
   pos     = p0 + integral vel u
   vel     = v0 + integral acc u + sumE impulse
   impulse = collide `snapshot_` vel ==> (* (-1.9))
   collide = predicate (pos <=* (-1) &&* vel <* 0) u
   acc     = -1
   p0      = -1
   v0      = 2
```

This is where the resolution independence ends. The `User` argument _"supplies the integration start time and a sampling clock which determines the step size used by the underlying numerical method"_, and `predicate` uses the same clock: _"Care must be taken since sampling may miss occurrences of the boolean behavior"_, which is why the collision tests `<=*` rather than equality ([manual][fran-manual]). A closed-form behaviour (a tween) is exact at any sample; an integrated one (a spring, a fall) is only as good as the sampling clock the runtime supplies. The ICFP paper's interval-analysis event detection was the attempt to make `predicate` exact; the 1.1 manual records that _"Some previous versions of Fran were able to detect even equality events"_.

**Leaks, and what push-pull changed.** A first-class behaviour denotes the whole history of a signal, so a late consumer (an `integral` started inside an `untilB`, a `snapshot` taken long after construction) can force the runtime to retain or recompute old samples. That is the space/time-leak story Yampa was designed to remove; it is told on the [Yampa page][rp-yampa-philosophy]. The push-pull paper names the cost for animation directly: sampling `switcher` _"involves searching through an event for the last occurrence before t. This search becomes costlier as t increases, wasting time as well as space"_, and _"in practice, behaviors are sampled with monotonically increasing times"_ ([_Push-Pull FRP_][push-pull-pdf] §3). Its fix decomposes a behaviour into discrete phases (`Reactive`, pushed) and, within each phase, a time function (pulled):

```haskell
data Reactive a = a `Stepper` Event a
data Fun t a    = K a | Fun (t -> a)
```

`K` marks a constant phase, so _"Wherever phases are constant (a common case), sampling happens only once per phase, driven by occurrences of relevant events"_ ([_Push-Pull FRP_][push-pull-pdf] §3). For animation this is the precise statement of "request frames only while something moves": a settled animation is a `K` phase and needs no samples.

### Yampa

**Signal functions, not signals.** A program is one `SF Input Output`; `integral` and `time` are signal functions, not values of time ([Yampa page][rp-yampa]). `time = localTime = constant 1.0 >>> integral`, which _"Outputs the time passed since the signal function instance was started"_ ([`Time.hs`][y-time]), so a tween is an `arr` after `localTime` and restarts at 0 whenever it is switched in. `integral` is _"Integration using the rectangle rule"_: each step adds `dt *^ aPrev` to the accumulator held in the next continuation ([`Integration.hs`][y-integral]). `imIntegral` and `trapezoidIntegral` are the alternatives; `derivative` is _"A very crude version of a derivative … Use at your own risk."_

**The bouncing ball.** The library's own SDL example ([`MainBouncingBox.hs`][y-bounce]) is the arrowized form of Fran's example 11, with the collision as a switch rather than an impulse sum:

```haskell
falling :: Double -> Double -> SF () (Double, Double)
falling y0 v0 = proc () -> do
  vy <- (v0+) ^<< integral -< gravity
  py <- (y0+) ^<< integral -< vy
  returnA -< (py, vy)

bounce :: Double -> Double -> SF () (Double, Double)
bounce y vy = switch (falling y vy >>> (Yampa.identity &&& hitBottom))
                     (\(y, vy) -> bounce y (-vy))
```

`switch` replaces the running `falling` with a fresh one started from the position and velocity carried by the event. That is retargeting in its most explicit form: the continuation receives `(value, derivative)` at the switching instant and starts a new motion from them ([`Switches.hs`][y-switch]).

**Space Invaders.** _The Yampa Arcade_ answered a public challenge that _"getting an alien spaceship to move slowly downward, moving randomly to the left and right, and bouncing off the walls, turned out to be a major headache"_ in reactive animation ([PDF][arcade-pdf] §1). Its gun is a damped spring written as two integrals in a `rec` loop ([PDF][arcade-pdf] §4):

```haskell
simpleGun (Point2 x0 y0) = proc gi -> do
  (Point2 xd _) <- ptrPos -< gi
  rec
    -- Controller
    let ad = 10 * (xd - x) - 5 * v
    -- Physics
    v <- integral -< clampAcc v ad
    x <- (x0+) ^<< integral -< v
  fire <- leftButtonPress -< gi
  returnA -< SimpleGunState { sgsPos = (Point2 x y0), sgsVel = (vector2 v 0), sgsFired = fire }
```

The pointer is the spring's target, so the target changes every frame and the motion stays smooth because `(x, v)` is the state: there is no separate retarget operation. The game objects (gun, aliens, missiles) form a dynamic collection under `dpSwitch`, whose `killOrSpawn` function _"observes the output of the collection … and determines when signal functions are added to or removed from the collection"_ ([PDF][arcade-pdf] §5.1). A destroyed alien's signal function stops being stepped at once; an explosion would have to be a new object spawned in its place.

**The driver owns the clock.** `reactimate init sense actuate sf` loops: `actuate` the output, then `sense False` returns `(dt, Maybe a)` and the SF is stepped with that `dt` ([`Simulation.hs`][y-reactimate]). The SF never reads a clock. The SDL example makes the ownership vivid: its `yampaSDLTimeSense` reads `SDL.getTicks` (milliseconds) and returns `fromIntegral dt / 100` ([`YampaSDL.hs`][y-sdl-time]), so the "seconds" its physics integrate are tenths of a second and the whole simulation runs ten times faster than its constants say. Nothing inside the SF can notice. `embedSynch` runs an embedded SF _"at a given (but variable) ratio >= 0 to the outer time flow. When the ratio is 0, the embedded signal function is paused"_ ([`Simulation.hs`][y-embed]) — Fran's `faster`, available only as a driver-level rate.

**dunai and Rhine** make the clock a type. BearRiver's `SF m = MSF (ClockInfo m)` reads `dt` from a `ReaderT` ([Yampa page § Related designs][rp-yampa-related]); Rhine's `Clock` class gives each signal function a clock with its own `Time` and `Tag`. `FixedStep n` is _"A pure (side effect free) clock with fixed step size … The tick rate is in the type signature, which prevents composition of signals at different rates"_ ([`FixedStep.hs`][r-fixedstep]); `GlossSimClockIO` (`Time = Seconds Float`) blocks on the gloss backend's simulation ticks ([`Gloss/IO.hs`][r-gloss-clock]). An animation's frame clock and a physics fixed step are then two clocks joined by a resampling buffer, checked at compile time.

### Elm

**Time is a message.** `Browser.Events.onAnimationFrame : (Time.Posix -> msg) -> Sub msg` and `onAnimationFrameDelta : (Float -> msg) -> Sub msg` _"hook into JavaScript's `requestAnimationFrame` function"_; the delta variant gives _"the time in milliseconds since the previous frame … nice for stepping animations by a time delta"_ ([`Events.elm`][eb-events]). The effect manager behind them ([`AnimationManager.elm`][eb-am]) holds one pending `rAF` process for all subscribers: when the subscription list becomes empty it `Process.kill`s that process; on each frame it re-arms `rAF` and sends every tagger the new time, or `newTime - oldTime` for the delta form. The kernel's `_Browser_rAF` resolves with `Date.now()`, not with the timestamp `requestAnimationFrame` passes its callback ([`Browser.js`][eb-raf]), so Elm animations sample wall-clock milliseconds at callback time rather than the frame's vsync time. The view is batched separately: `_Browser_makeAnimator` draws at most once per animation frame however many messages arrive ([`Browser.js`][eb-animator]; [Elm page][rp-elm-eval]).

The application therefore keeps the clock itself, in the model, as elm-animation's `Retarget` example does ([`Retarget.elm`][ea-ex-model]):

```elm
type alias Model =
    { clock : Clock
    , x : Animation
    , y : Animation
    -- …
    }

updateTick : Float -> Model -> Model
updateTick dt model =
    let
        clock = model.clock + (if model.slow then dt / 5 else dt)
    -- …
```

Holding shift divides every delta by five, slowing the whole scene: Fran's `slower 5`, done by the one function that owns the model's clock ([`Retarget.elm`][ea-ex-tick]).

**Before 0.17**, time was a signal: `Time.fps : number -> Signal Time` gives _"a sequence of time deltas as quickly as possible until it reaches the desired FPS"_, and `fpsWhen` adds a `Signal Bool` gate so _"brief animations based on user input"_ run _"without major inefficiencies"_; _"The first time delta after a pause is always zero, no matter how long the pause was"_ ([legacy `Time.elm`][legacy-fps]). An animation was a `foldp` over that signal. 0.17 removed `Signal` ([Elm page][rp-elm]); the gate became `subscriptions : Model -> Sub Msg` returning `onAnimationFrame` only while something moves.

**`mgold/elm-animation`: an animation is a record.** An `Animation` is an opaque wrapper over ([`Animation.elm`][ea-record]):

```elm
type alias AnimRecord =
    { start : Clock
    , delay_ : TimeDelta
    , dos : DurationOrSpeed
    , ramp : Maybe Float -- used for interruptions
    , ease_ : Float -> Float
    , from_ : Value
    , to_ : Value
    }
```

`animate : Clock -> Animation -> Value` is exactly the tween denotation: `fr = clamp 0 1 ((clock - start - delay_) / duration_)`, `from_ + (to_ - from_) * ease_ fr + correction` ([`animate`][ea-animate]). The defaults are 750 ms and the sinusoidal `(1 - cos (pi * x)) / 2`; `speed` replaces the duration with an average rate. The README states the payoff: an animation is constant before its delay and after its end, and with `static` _"you ought to be able to keep animations in your model without worrying about when they aren't actually animating"_ ([`README.md`][ea-readme]). Its doctest samples one value at seven times — `List.map (\t -> animate t myAnim) [0, 1, 2, 3, 4, 5, 6]` — which is a test with virtual time and no harness.

**Retargeting keeps velocity.** `retarget : Clock -> Value -> Animation -> Animation` _"Change[s] the `to` value of a running animation, without an abrupt change in velocity … The animation will retain its average speed (but not necessarily duration)"_ ([`retarget`][ea-retarget]). For a running animation it builds a new record starting _now_ from the current position, with `ramp = Just vel`, where `vel` is `getVelocity clock u`, _"aproximated by looking 10ms forwards and backwards (the central difference)"_ ([`getVelocity`][ea-velocity]). `animate` adds the correction `vel * (clock - start) * (1 - cosineEase fr)`, which starts with the old slope and fades out, so the curve is continuous in value and slope at the interruption. A scheduled animation just gets a new `to`; a finished one starts afresh from its old `to`. The `Retarget` example retargets `x` and `y` on every click and notes the consequence: _"When retargeted, acceleration changes instantly but velocity does not"_ ([`Retarget.elm`][ea-ex-click]).

**`mdgriffith/elm-animator`: a timeline of states.** A `Timeline state` is _"roughly a list of states and the times that they should occur"_ ([`Timeline.elm`][ear-timeline-type]). The app stores one per animated concept (`Timeline Bool` for visibility), subscribes to `onAnimationFrame` only `if Timeline.isRunning model.visible`, and on each tick calls `Timeline.update now` ([getting started][ear-getting-started]). `Timeline.to duration state` is `interrupt [ transitionTo duration state ]`; `interrupt` replaces the pending schedule (_"the latest nonempty schedule wins"_), `queue` appends after the current one finishes, and `wait` inserts a pause ([`interrupt`][ear-interrupt]). Version 1.x spelled these `Animator.go`, `Animator.interrupt`, `Animator.queue` ([`changelog.md`][ear-changelog]).

The view reads values by mapping states to targets, and the value is recomputed from the retained history every time it is read ([`Value.elm`][ear-movement]):

```elm
Animator.Value.float model.visible <|
    \visible -> if visible then Animator.Value.to 1 else Animator.Value.to 0
```

`movement` folds every retained transition up to the timeline's `now` (`Timeline.foldpAll`); an interrupted transition _"contribute[s] [its] position and velocity at the interruption time"_ to the next. So the view is a pure function of the model, and `now` is part of the model, written by `update` ([`InternalAnim/Timeline.elm`][ear-update]). `update` is forward-only — `now = Quantity.max (Time.absolute possiblyNow) timeline.now`, with the note _"we can only move forward with updating … for something like debug mode, we might want to disable this to allow scrubbing"_ — and garbage-collects history older than `maxDelay`, five seconds, because _"View functions may request any delay up to this duration after `update` has already run"_ ([`maxDelay`][ear-maxdelay]). Curves are a Bézier (`standard` = `cubic-bezier(0.4, 0, 0.2, 1)`) or `spring { wobble, quickness }`, both in `0..1`, whose _"Duration still comes from the animation"_ ([`Transition.elm`][ear-spring]). The 2.0 rewrite also renders CSS transitions and keyframes directly (`Animator.transition`), which need no Elm clock at all ([`changelog.md`][ear-changelog]).

### Reflex

Reflex has no animation layer. Its `Behavior t a` is not Fran's: the denotational reference implementation defines `newtype Behavior (Pure t) a = Behavior {unBehavior :: t -> a}` but requires that _"The 'Enum' instance of t must be dense"_ — time is a sequence of discrete frames ([`Reflex/Pure.hs`][rx-pure]), and _"There is no clock in the core"_ ([Reflex page][rp-reflex-time]). Wall-clock time enters as an event:

```haskell
data TickInfo = TickInfo
  { _tickInfo_lastUTC        :: UTCTime         -- UTC time immediately after the last tick
  , _tickInfo_n              :: Integer         -- ticks since the start of the timer
  , _tickInfo_alreadyElapsed :: NominalDiffTime -- time elapsed in the current tick period
  }

tickLossyFromPostBuildTime :: (…) => NominalDiffTime -> m (Event t TickInfo)
```

`tickLossyFromPostBuildTime dt` reads the clock at post-build and then fires _"approximately each time the provided interval elapses. If the system starts running behind, occurrences will be dropped rather than buffered"_; each period is a `forkIO` thread that `Concurrent.delay`s and triggers a frame ([`Reflex/Time.hs`][rx-tick]). An animated value is then user code: `holdDyn` the tick's `_tickInfo_lastUTC` into a `Dynamic t UTCTime`, hold the current animation record in another `Dynamic` (updated by `attach`ing the current time to a retarget event), and `zipDynWith` a tween function over the two — the elm-animation shape rebuilt from `Dynamic`s. The tick is a timer, not a vsync: nothing aligns it with the display, and it runs whether or not anything moves.

reflex-dom's only use of `requestAnimationFrame` is internal: `DomRenderHookT`, _"Shared behavior for HydrationDomBuilderT and HydrationRunnerT"_, runs requested DOM updates inside `DOM.inAnimationFrame'` ([`Immediate.hs`][rd-raf]). The hydration test suite intercepts `window.requestAnimationFrame` (`holdAnimationFrames`/`releaseAnimationFrames`) because _"DOM updates requested by the widget run in animation frames"_ ([`hydration.hs`][rd-hold]). No animation-frame `Event`, tween, spring or transition is exported by either repository at the surveyed revisions (searched for `animat`, `AnimationFrame`, `tween`, `lerp`).

---

## Analysis

### Where animation state lives

- **Fran: in the value, not in a store.** A tween is `tween t0 d a b`; its parameters are captured by the behaviour, and the runtime keeps only what sampling needs (integrator state, the position reached in an event list). No identity-keyed state exists because none is needed: the behaviour _is_ the animation.
- **Yampa: inside the running signal function.** `integral`'s accumulator lives in the continuation `SF'` returned by each step ([`Integration.hs`][y-integral]). It is invisible from outside except through what the SF outputs (the gun outputs `sgsVel` so others can read it) or through `kSwitch`'s frozen continuation ([Yampa page][rp-yampa]).
- **Elm: in the `Model`.** elm-animation stores `Animation` records next to the domain data (`x : Animation`); elm-animator replaces a domain field with `Timeline state` (`visible : Timeline Bool`). Both are plain immutable values that `update` replaces and `view` reads.
- **Reflex: in `Dynamic`s** created by `holdDyn`/`foldDyn` inside the widget that owns the animation, so lifetime follows the widget's subnetwork.

The common ground is that the stored thing is the _animation description_ (start, from, to, curve), not the current value. Only the stepped integrators (Yampa's `integral`, Fran's `integral` behind its `User` clock) hold a current value.

### Declaring an animation

All four are **explicit**: no value change animates by itself. In Fran and Yampa the animation is the program (a behaviour or signal function); the declarative target exists only as a lifted expression (`move (tween …)`) or as the target input of a controller (the gun's `xd`). Elm's libraries are declarative over a target state with an explicit trigger: elm-animator's `Timeline.to (Animator.ms 300) True` declares "go to `True`" and the view maps each state to a target value, which is the nearest thing in this family to implicit animation — the view says what each state looks like, and the timeline interpolates between whichever states it passes through. elm-animator 2.0's `Animator.transition (Animator.ms 200) [ Animator.opacity … ]` is implicit, but only because it compiles to a CSS transition and hands the animation to the browser ([`README.md`][ear-readme]). Reflex has nothing to declare.

None has an imperative controller object with `start`/`stop` methods. "Starting" is constructing a value (`animation now |> to 300`) or switching one in; "stopping" is replacing it.

### Time and the clock

| System        | Time model                                              | Who owns the clock                                                      | What an animation sees                         |
| ------------- | ------------------------------------------------------- | ----------------------------------------------------------------------- | ---------------------------------------------- |
| Fran          | continuous, absolute; `timeTransform` re-maps it        | the display runtime (`displayU`, `userDelay`); `User` supplies sampling | `time`, shifted to local 0 by `userDelay`      |
| Yampa / Rhine | continuous semantics, sampled by `dt`                   | the `reactimate` driver's `sense`; Rhine: a typed `Clock`               | `localTime`, restarting at each switch-in      |
| Elm           | discrete messages carrying `Time.Posix` or a delta (ms) | the runtime's `rAF` effect manager; the app accumulates its own clock   | whatever `Clock` the model passes to `animate` |
| Reflex        | discrete frames; wall time as `TickInfo` events         | a `forkIO` timer thread per `tickLossy`                                 | a `Dynamic t UTCTime` the app holds            |

Fran and elm-animation agree on the one thing that matters for purity: an animation is evaluated _at_ a time given to it, never by reading a clock. Fran's runtime picks the instants; Elm's app picks them (and can scale them, as the `Retarget` example's slow-motion does). Yampa inverts this: the SF is given `dt`, not `t`, so any absolute time is an integral the SF computes. That makes Yampa's driver more powerful (it can scale, pause or replay time) but makes a tween stepped state rather than a closed form. Neither Elm nor Reflex aligns animation to the frame's presentation time: Elm samples `Date.now()` in the callback ([`Browser.js`][eb-raf]); Reflex's ticks are not frames at all.

### Interruption and retargeting

Interruption in FRP is switching, and retargeting is switching to a new behaviour that starts from the old one's current value and derivative.

- **Fran**: `untilB`/`switcher` to a behaviour built from a `snapshot` of the current position and velocity (velocity is available when the motion is defined by `integral`, as in example 11). Nothing does this automatically; a switch to a plain tween from the snapshot keeps the value and loses the slope.
- **Yampa**: `switch`'s continuation receives whatever the event carries; the bouncing ball passes `(y, vy)` and negates `vy` ([`MainBouncingBox.hs`][y-bounce]). A spring-shaped controller (the gun) needs no switch: its target is an input, and `(x, v)` continuity is automatic because they are the integrator state.
- **elm-animation**: `retarget` keeps value and (numerically estimated) velocity and keeps the average speed; the duration changes with the distance ([`retarget`][ea-retarget]). `undo` reverses from the current state. Multi-axis motion must retarget every axis with a synced `duration`, or the axes arrive at different times (the example's comment: _"sync durations, very important"_).
- **elm-animator**: `interrupt` always continues from the sampled position; velocity is continuous only for `spring` transitions, whose `Spring.at` takes the incoming velocity as its initial condition (`InternalAnim/Transition.elm` [`atX`][ear-atx]) — the test _"A spring interruption preserves incoming velocity at the interruption instant"_ checks `{ position = 100, velocity = 200 }` ([`Values.elm`][ear-test-spring]). A Bézier transition's velocity comes from the new curve alone, so a linear interruption has a kink. The changelog says so: _"use timeline springs for velocity-preserving interruptions"_ ([`changelog.md`][ear-changelog]).
- **Reflex**: whatever the user's tween function does.

None of the four composes animations additively (summing several in-flight contributions on one value), although Fran's lifted `+` makes `tween … + tween …` trivially expressible.

### Curves and springs

- **Duration and easing** are a user-supplied `Float -> Float` in elm-animation (default sinusoid, `f 0 == 0` and `f 1 == 1` expected) and a Bézier or linear `Transition` in elm-animator. Fran and Yampa have no easing library; an easing is any lifted function of `time`/`localTime`.
- **Springs as physics** are integrals in Fran and Yampa: the gun's `ad = 10 * (xd - x) - 5 * v` is stiffness 10 and damping 5 (damping ratio `5 / (2 * sqrt 10)` ≈ 0.79, slightly underdamped), stepped by the rectangle rule ([PDF][arcade-pdf] §4, [`Integration.hs`][y-integral]). The result depends on the step: Fran's manual puts the step size in the `User` sampling clock, and the SDL driver's `/ 100` changes what the constants mean.
- **Springs in closed form** are elm-animator's: `spring { wobble, quickness }` in `0..1`, evaluated by `Spring.at` at an elapsed time with no stepping, and fitted to the transition's duration (`settleMax = totalDuration`) ([`atX`][ear-atx], [`Transition.elm`][ear-spring]). A closed-form spring keeps `value(now)` a pure function and can be sampled at any instant; a stepped one cannot ([concepts][concepts-closed-form]).

### Layout animation

Not applicable in any of the four as a layout mechanism, because none has a layout engine that animation participates in:

- **Fran** animates geometry as image transforms: `move`, `stretch` and the 3D `turn3` are behaviours composed into the `ImageB`, applied when the image is rendered — the paint/compose phase. There is no layout; positions are coordinates the program computes.
- **Yampa** has no presentation layer; the actuator renders whatever numbers the SF outputs.
- **Elm** computes geometry in user code (`update`/`view`) and emits it as attributes or styles; the browser lays out. Reading the previous frame's layout is an effect: `Browser.Dom.getElement : String -> Task Error Element` calls `_Browser_withNode`, which waits one `requestAnimationFrame` before reading `getBoundingClientRect()` ([`Browser.js`][eb-withnode], [`Dom.elm`][eb-getelement]). The rect arrives as a message in a later `update`, so a FLIP-style layout animation in Elm is: render, read the committed rect, store `(oldRect, newRect)` in the model, animate a transform from the difference. That is user code driven by last frame's geometry — the shape UI-Q9 ([PR #775][pr775]) asks about — with the read deferred by one frame and the animation applied as a paint-time transform.
- **Reflex** (reflex-dom) builds a retained DOM; geometry readback is a JavaScript FFI call outside the libraries surveyed.

### Enter and exit

None of the four has an exit mechanism; absence is the model's business.

- In **Fran**, an image that should fade out is ``fadingImage `untilB` (doneE -=> emptyImage)``: the program keeps it present until its own event says it is gone. The element is never "removed while painting"; it is present until its behaviour becomes `emptyImage`.
- In **Yampa**, `dpSwitch`'s `killOrSpawn` removes a signal function at an instant; anything that should outlive the kill (an explosion) is spawned as a separate object in the same switch ([PDF][arcade-pdf] §5).
- In **Elm**, a list item that should animate out stays in the model with a "leaving" timeline (`Timeline Bool` going to `False`), and the app deletes it when `Timeline.arrivedAt` reports the end, or when an elm-animation record `isDone`. The view stops building it only after that.
- **Reflex**'s `listWithKey`/`networkHold` tear a widget's subnetwork down when its key disappears, taking its `Dynamic`s with it.

This is the "closing state the store drives" answer to UI-Q10 ([PR #775][pr775]): the item is still built, from state that says it is closing, until the animation that state carries is done.

### Scheduling, reduced motion and testing

**Request frames only while animating.** Elm gets this from `subscriptions` being a function of the model: elm-animator's documented setup subscribes `if Timeline.isRunning model.visible`, and `AnimationManager` kills its pending `rAF` process when no subscription remains ([getting started][ear-getting-started], [`AnimationManager.elm`][eb-am]). Legacy Elm had the same as `fpsWhen`. elm-animation exposes `isDone`/`timeRemaining` for the app to gate on; its own `Retarget` example subscribes unconditionally ([`Retarget.elm`][ea-ex-subs]). Push-pull FRP gives the semantic version: constant `K` phases are sampled once ([_Push-Pull FRP_][push-pull-pdf]). Yampa's driver must keep ticking because an SF cannot report its next deadline ([Yampa page][rp-yampa-time]); Reflex's tick thread runs until its widget is torn down.

**Reduced motion** is handled by none of them. Nothing in `elm/browser`, elm-animation, elm-animator or reflex-dom reads `prefers-reduced-motion` (searched at the surveyed revisions); an Elm app would pass `matchMedia` through flags or a port. Fran's `timeTransform` shows the shape such a preference could take in a pure system: a transform of the time an animation is evaluated at (`faster` toward infinity jumps to the end state), applied once at the root.

**Testing.** Pure time makes tests trivial wherever an animation is a value:

- elm-animation's README doctest samples `animate t myAnim` over a list of times ([`README.md`][ea-readme]).
- elm-animator's tests drive `Timeline.update (Time.millisToPosix 10500)` and assert `Value.float`/`Value.movement`, including fuzzed interruptions checked against an independent two-segment model ([`Values.elm`][ear-test-spring]). The forward-only `update` means a test cannot rewind a timeline; it must rebuild one.
- Yampa's `embed` runs an SF over `(dt, Maybe input)` samples, and a bouncing ball is a list of heights ([Yampa testing][rp-testing-yampa]).
- elm-program-test simulates `Process.sleep` with `advanceTime` but has no animation-frame simulation (no `AnimationFrame` in its source); a test sends the `Tick` message itself ([Elm testing][rp-testing-elm]).
- Reflex has no virtual time; `tickLossy` sleeps for real ([Reflex page][rp-reflex-time]).

### Lessons for sparkles:ui

1. **Store the animation, not its value.** An element-store entry shaped like elm-animation's `AnimRecord` — `(start, from, to, spec)` plus the initial velocity for a retarget — lets a `@safe pure nothrow @nogc` component compute `value(now)` from last frame's committed store and the frame's `now`, both `const` inputs. That is Fran's denotation with the store standing in for the closure. The component never writes the record; it yields a message (or the host derives the change), and the host commits the new record after layout, as UI-Q5 already requires.
2. **Retarget analytically from the old record.** A retarget is a new record whose `from` is `old.value(now)` and whose initial velocity is `old.velocity(now)`. elm-animation estimates velocity by a ±10 ms central difference; a closed-form curve (and a closed-form spring, as in elm-animator and `sparkles:ui`'s `ScrollMotion`, [baseline][baseline-moves]) can return its exact derivative. Springs should be closed-form so a spring is also plain data and the view stays pure; Yampa's rectangle-rule `integral` and the SDL driver's `/ 100` show how stepped physics ties meaning to the frame source.
3. **The host owns one clock, and passes `now`.** Every system here that keeps the view pure gets time as an argument. One `now` per frame (preferably [`FrameStart.target`][baseline-clock]) given to every component removes Elm's "the app accumulates deltas in the model" step and the `Date.now()`-at-callback skew. A time transform at the root (Fran's `faster`, the `Retarget` example's slow-motion, elm-animator's `scale`) is then the place for slow-motion debugging and for reduced motion.
4. **"Still running" and "next deadline" come from the records.** Given `now`, the store can answer whether any record is not yet done and when the next one ends — elm-animator's `isRunning`, push-pull's constant phases — which is what `requestFrame` and `wakeIn` need. Yampa's lack of a deadline query is the failure mode to avoid.
5. **Exit is a closing state in the store (UI-Q10).** None of these systems retains a snapshot of a removed element; each keeps it _present_ while its state says it is leaving (Fran's `untilB` to `emptyImage`, Elm's "leaving" timeline, Yampa's spawned explosion). For `sparkles:ui`, where presence is "built this frame", the analogue is a store entry that outlives the identity's last build until its exit record is done, with the host continuing to paint it from that record.
6. **Layout animation needs last frame's geometry as data (UI-Q9).** Elm's `getElement` delivers the committed rect one frame later as a message; the animation is then a transform from `(oldRect, newRect)` applied at paint. In `sparkles:ui` the previous rect is already in the store, so the same animation can be computed in user code from committed geometry and applied as a paint-time offset, without layout re-running per frame.
7. **Keep evaluation seekable.** elm-animator's forward-only `update` and five-second history window exist to bound a fold over retained history. A record-per-identity store needs no history, so `value(t)` can be sampled at any `t` — which is what makes a recorder-driven test (sample the view at a list of times, as `embed` does) possible.

---

## Strengths

- **One denotation for every animation.** `Time -> a` explains tweens, delays (`later`), speed changes (`faster`) and composition in time without any runtime concept; Fran's time transforms fall out of it.
- **Purity of the view.** Fran, elm-animation and elm-animator keep the animated view a pure function of `(model, time)`; tests are lists of times.
- **Physics as equations.** Fran's and Yampa's integrals let a spring or fall be written as its differential equation, and Yampa's gun shows target-tracking with no retarget operation at all.
- **Retargeting with velocity continuity** is a library function in elm-animation and a property of springs in elm-animator, both over immutable values.
- **State-driven frame scheduling** in Elm: `subscriptions` and `isRunning` make "only tick while moving" a pure function of the model.

## Weaknesses

- **Continuous time is not free.** Integrals and predicates need a sampling clock (Fran's `User`, Yampa's `dt`), so physics is exactly as resolution-dependent as a hand-written loop.
- **Leaks or plumbing.** First-class behaviours leak history (Fran); removing them forces arrow plumbing and makes a tween stepped state (Yampa).
- **No presentation-time clock.** Elm samples `Date.now()` in the `rAF` callback; Reflex uses timer threads; Yampa takes whatever `dt` the driver measures.
- **No exit, layout or reduced-motion support** in any of the four; each is left to the application.
- **Reflex has no animation story** beyond lossy wall-clock ticks.
- **elm-animator's value is a fold over history**, bounded by a forward-only clock and a 5 s retention window.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                                     | Trade-off                                                                                   |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `Behavior a` = function of continuous time (Fran)            | Resolution independence in time; composition in time via `timeTransform`      | History retention (space/time leaks); integrals and events still need a sampling clock      |
| Signals not first-class; `dt` from the driver (Yampa)        | Leak-free, causal, deterministic under `embed`                                | Absolute time is an integral; tweens become stepped state; driver can silently rescale time |
| Retarget by switching with `(value, derivative)`             | Interruption is ordinary control flow; any curve can follow any other         | Continuity is the programmer's job unless the motion is a controller over integrator state  |
| Time as a message; animation as a record in the model (Elm)  | No runtime concept of animation; view stays pure; app can scale its own clock | App accumulates deltas itself; samples `Date.now()`, not the frame's vsync time             |
| `retarget` with a numeric velocity ramp (elm-animation)      | Smooth retargeting of any easing over plain data                              | Velocity by central difference; average speed kept, duration changes; axes need syncing     |
| Timeline of states, value folded from history (elm-animator) | Interruptions compose; springs carry velocity across them                     | Forward-only clock; 5 s retention; Bézier interruptions are not velocity-continuous         |
| Gate frames by `subscriptions model` (Elm)                   | Idle costs nothing; lifetime is a function of state                           | Every animation library must expose a "running" predicate for the app to gate on            |
| No animation layer; ticks via `forkIO` timers (Reflex)       | Time stays outside the deterministic core                                     | No vsync alignment, no virtual time, no tween or spring vocabulary                          |

## Sources

- Elliott & Hudak, [_Functional Reactive Animation_][fran-paper], ICFP 1997 ([author's page][fran-page], abstract quoted from it)
- Peterson, Elliott & Ling, [_Fran 1.1 Users Manual_][fran-manual], 1998-06-17; Elliott, [_Composing Reactive Animations_][fran-tutorial], 1998; [Fran home page][fran-home]
- Elliott, [_Push-Pull Functional Reactive Programming_][push-pull], Haskell Symposium 2009-09-03 ([author's page][push-pull-page], [PDF][push-pull-pdf])
- Courtney, Nilsson & Peterson, [_The Yampa Arcade_][arcade], Haskell Workshop 2003-08-28 ([PDF][arcade-pdf])
- Yampa at `9dda03030c4edfdda6e908f49b5a92d1dda5c8a3`: [`Integration.hs`][y-integral], [`Time.hs`][y-time], [`Simulation.hs`][y-reactimate], [`Switches.hs`][y-switch], [`MainBouncingBox.hs`][y-bounce], [`YampaSDL.hs`][y-sdl-time]
- Rhine at `698b69397ec7d9545cdc9ae48967f970d42e2c28`: [`FixedStep.hs`][r-fixedstep], [`Gloss/IO.hs`][r-gloss-clock]
- `elm/browser` at `1d28cd625b3ce07be6dfad51660bea6de2c905f2`: [`Events.elm`][eb-events], [`AnimationManager.elm`][eb-am], [`Dom.elm`][eb-getelement], [`Elm/Kernel/Browser.js`][eb-animator]; `elm/time` [`Time.elm`][et-every]; legacy `elm-lang/core` 3.0.0 [`Time.elm`][legacy-fps]
- `mgold/elm-animation` at `cb278e818777ff19714aaa57d97f4f121acba815`: [`README.md`][ea-readme], [`Animation.elm`][ea-record], [`examples/Retarget.elm`][ea-ex-model]
- `mdgriffith/elm-animator` at `12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70`: [`README.md`][ear-readme], [`changelog.md`][ear-changelog], [`Animator/Timeline.elm`][ear-getting-started], [`Animator/Value.elm`][ear-movement], [`Animator/Transition.elm`][ear-spring], [`InternalAnim/Timeline.elm`][ear-update], [`InternalAnim/Transition.elm`][ear-atx], [`tests/Values.elm`][ear-test-spring]
- Reflex at `f443526bd2a9d4ba43f65f3a755d21e61082f4e0`: [`Reflex/Time.hs`][rx-tick], [`Reflex/Pure.hs`][rx-pure]; reflex-dom at `de31ceff3d995381da661dc25b50e5b99fdd6316`: [`Immediate.hs`][rd-raf], [`test/hydration.hs`][rd-hold]
- Related pages: [Yampa][rp-yampa] · [Elm][rp-elm] · [Reflex][rp-reflex] · [reactive concepts][rp-concepts] · [testing FRP][rp-testing] · [animation concepts][concepts] · [sparkles baseline][baseline-clock] · [UI authoring decisions][ui-authoring] · [Manim][manim]

<!-- References -->

[fran-paper]: https://doi.org/10.1145/258948.258973
[fran-page]: https://conal.net/papers/icfp97/
[fran-home]: https://conal.net/fran/
[fran-manual]: https://conal.net/fran/UsersMan.htm
[fran-tutorial]: https://conal.net/fran/tutorial.htm
[push-pull]: https://doi.org/10.1145/1596638.1596643
[push-pull-page]: https://conal.net/papers/push-pull-frp/
[push-pull-pdf]: https://conal.net/papers/push-pull-frp/push-pull-frp.pdf
[arcade]: https://doi.org/10.1145/871895.871897
[arcade-pdf]: https://www.antonycourtney.com/pubs/hw03.pdf
[y-repo]: https://github.com/ivanperez-keera/Yampa/tree/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3
[y-integral]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Integration.hs#L56-L104
[y-time]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Time.hs#L40-L46
[y-reactimate]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Simulation.hs#L89-L112
[y-embed]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Simulation.hs#L161-L186
[y-switch]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Switches.hs#L125-L176
[y-bounce]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/examples/yampa-game/MainBouncingBox.hs#L27-L60
[y-sdl-time]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/examples/yampa-game/YampaSDL.hs#L22-L37
[d-repo]: https://github.com/ivanperez-keera/dunai/tree/407ff003fac2296582c0f4597f0004a1e578d3af
[r-repo]: https://github.com/turion/rhine/tree/698b69397ec7d9545cdc9ae48967f970d42e2c28
[r-fixedstep]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/rhine/src/FRP/Rhine/Clock/FixedStep.hs#L34-L40
[r-gloss-clock]: https://github.com/turion/rhine/blob/698b69397ec7d9545cdc9ae48967f970d42e2c28/rhine-gloss/src/FRP/Rhine/Gloss/IO.hs#L142-L158
[eb-repo]: https://github.com/elm/browser/tree/1d28cd625b3ce07be6dfad51660bea6de2c905f2
[eb-events]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Browser/Events.elm#L52-L73
[eb-am]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Browser/AnimationManager.elm#L66-L104
[eb-getelement]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Browser/Dom.elm#L330-L384
[eb-animator]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Elm/Kernel/Browser.js#L110-L135
[eb-raf]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Elm/Kernel/Browser.js#L265-L277
[eb-withnode]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Elm/Kernel/Browser.js#L293-L305
[et-every]: https://github.com/elm/time/blob/dc3b75b7366e59b99962706f7bf064d3634a4bba/src/Time.elm#L414-L422
[legacy-fps]: https://github.com/elm-lang/core/blob/09f3dd2b11f34987bf6b32201fd1899baff5d646/src/Time.elm#L83-L103
[ea-repo]: https://github.com/mgold/elm-animation/tree/cb278e818777ff19714aaa57d97f4f121acba815
[ea-readme]: https://github.com/mgold/elm-animation/blob/cb278e818777ff19714aaa57d97f4f121acba815/README.md
[ea-record]: https://github.com/mgold/elm-animation/blob/cb278e818777ff19714aaa57d97f4f121acba815/src/Animation.elm#L130-L146
[ea-animate]: https://github.com/mgold/elm-animation/blob/cb278e818777ff19714aaa57d97f4f121acba815/src/Animation.elm#L206-L238
[ea-retarget]: https://github.com/mgold/elm-animation/blob/cb278e818777ff19714aaa57d97f4f121acba815/src/Animation.elm#L261-L303
[ea-velocity]: https://github.com/mgold/elm-animation/blob/cb278e818777ff19714aaa57d97f4f121acba815/src/Animation.elm#L383-L395
[ea-ex-model]: https://github.com/mgold/elm-animation/blob/cb278e818777ff19714aaa57d97f4f121acba815/examples/Retarget.elm#L54-L65
[ea-ex-subs]: https://github.com/mgold/elm-animation/blob/cb278e818777ff19714aaa57d97f4f121acba815/examples/Retarget.elm#L87-L95
[ea-ex-click]: https://github.com/mgold/elm-animation/blob/cb278e818777ff19714aaa57d97f4f121acba815/examples/Retarget.elm#L3-L30
[ea-ex-tick]: https://github.com/mgold/elm-animation/blob/cb278e818777ff19714aaa57d97f4f121acba815/examples/Retarget.elm#L169-L181
[ear-repo]: https://github.com/mdgriffith/elm-animator/tree/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70
[ear-readme]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/README.md
[ear-changelog]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/changelog.md
[ear-getting-started]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/src/Animator/Timeline.elm#L15-L54
[ear-timeline-type]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/src/Animator/Timeline.elm#L118-L123
[ear-interrupt]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/src/Animator/Timeline.elm#L345-L398
[ear-movement]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/src/Animator/Value.elm#L83-L114
[ear-spring]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/src/Animator/Transition.elm#L31-L62
[ear-update]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/src/InternalAnim/Timeline.elm#L185-L206
[ear-maxdelay]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/src/InternalAnim/Timeline.elm#L234-L239
[ear-atx]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/src/InternalAnim/Transition.elm#L175-L262
[ear-test-spring]: https://github.com/mdgriffith/elm-animator/blob/12ca2ee7eba6af39bf8a4b75a6845db2f5d6ec70/tests/Values.elm#L73-L166
[rx-repo]: https://github.com/reflex-frp/reflex/tree/f443526bd2a9d4ba43f65f3a755d21e61082f4e0
[rx-tick]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Time.hs#L45-L100
[rx-pure]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Pure.hs#L45-L56
[rd-repo]: https://github.com/reflex-frp/reflex-dom/tree/de31ceff3d995381da661dc25b50e5b99fdd6316
[rd-raf]: https://github.com/reflex-frp/reflex-dom/blob/de31ceff3d995381da661dc25b50e5b99fdd6316/reflex-dom-core/src/Reflex/Dom/Builder/Immediate.hs#L352-L375
[rd-hold]: https://github.com/reflex-frp/reflex-dom/blob/de31ceff3d995381da661dc25b50e5b99fdd6316/reflex-dom-core/test/hydration.hs#L1761-L1786
[pr775]: https://github.com/PetarKirov/sparkles/pull/775
[rp-yampa]: ../reactive-programming/yampa.md
[rp-yampa-philosophy]: ../reactive-programming/yampa.md#design-philosophy
[rp-yampa-related]: ../reactive-programming/yampa.md#related-designs
[rp-yampa-time]: ../reactive-programming/yampa.md#time-and-scheduling
[rp-elm]: ../reactive-programming/elm.md
[rp-elm-eval]: ../reactive-programming/elm.md#evaluation-model
[rp-reflex]: ../reactive-programming/reflex.md
[rp-reflex-time]: ../reactive-programming/reflex.md#time-and-scheduling
[rp-concepts]: ../reactive-programming/concepts.md
[rp-testing]: ../reactive-programming/testing-frp-and-snapshots.md
[rp-testing-yampa]: ../reactive-programming/testing-frp-and-snapshots.md#yampa-sample-streams-and-temporal-logic
[rp-testing-elm]: ../reactive-programming/testing-frp-and-snapshots.md#elm-elm-program-test
[concepts]: ./concepts.md
[concepts-closed-form]: ./concepts.md#closed-form-and-stepped-integration
[baseline-moves]: ./sparkles-baseline.md#what-moves-today
[baseline-clock]: ./sparkles-baseline.md#who-owns-the-clock
[ui-authoring]: ../ui-authoring/index.md#decisions
[manim]: ../manim/index.md
