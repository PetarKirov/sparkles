# Flutter animation (Dart)

Flutter animates with retained, per-`State` controller objects: an `AnimationController` owns a `Ticker` that the `SchedulerBinding` calls once per frame in a dedicated _transient-callback_ phase before build, the controller samples a `Simulation` at the elapsed time, and listeners turn the new value into `setState`, `markNeedsLayout` or a composited-layer update. Implicit widgets (`AnimatedContainer`, `TweenAnimationBuilder`) hide the controller inside their `State`; everything else, from `Hero` flights to `AnimatedList` removals, is built from the same three parts.

| Field                    | Value                                                                                                                                                                                                                        |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | Dart 3.13 (the SDK bundled with the surveyed release)                                                                                                                                                                        |
| License                  | BSD-3-Clause ([`LICENSE`][license])                                                                                                                                                                                          |
| Repository               | [flutter/flutter][repo]: [`packages/flutter/lib/src/animation`][src-animation], [`scheduler`][src-scheduler], [`physics`][src-physics], [`widgets`][src-widgets]; tests in [`packages/flutter_test`][src-flutter-test]       |
| Documentation            | [Introduction to animations][d-animations] (docs.flutter.dev, "last updated on 2026-11-23") · [Implicit animations][d-implicit] · [Hero animations][d-hero] · API docs in the source comments cited below                    |
| Category                 | explicit, imperative controllers (`AnimationController`) over a framework frame clock; implicit widgets layered on top; a pull-based `Animation` listenable graph                                                            |
| Versions surveyed        | Flutter **3.47.4** (tag commit `9584c67`, 2026-09-10), the same pin as the [reactive-programming deep-dive][rp-flutter]                                                                                                      |
| Animation state lives in | `State` objects and `RenderObject`s: each `AnimationController` (value, status, `Simulation`, `Ticker`) is a field of a `State` that mixes in `TickerProviderStateMixin`, or of a render object such as `RenderAnimatedSize` |

> [!NOTE]
> This page covers animation only. The widget/element/render-object trees, dirty lists and the frame pipeline that animation plugs into are described in [Flutter widgets, elements and render objects][rp-flutter] and not repeated here; layout itself is in [Flutter layout][layout-flutter]. Vocabulary (model vs presentation value, closed form vs stepped integration, retargeting) follows the catalog's [concepts][concepts]. Every claim below was read at the pinned tag.

---

## Overview

### What it solves

Flutter's widgets are immutable descriptions rebuilt from state, so a value that changes continuously between two states must live somewhere that survives rebuilds and advances on its own. Flutter's answer is an explicit object, the `AnimationController`, created in `initState`, disposed in `dispose`, and driven by a `Ticker` the framework calls once per frame. The rest of the library makes that object composable (`Tween`, `CurvedAnimation`, `Animation.drive`) and hides it where possible (implicit widgets). The official docs name the two families it supports: _"In a tween animation, the beginning and ending points are defined, as well as a timeline, and a curve that defines the timing and speed of the transition"_, and _"In physics-based animation, motion is modeled to resemble real-world behavior"_ ([Introduction to animations][d-animations]).

### Design philosophy

1. **Animation is a phase of the frame, not a side effect.** `WidgetsBinding.drawFrame` lists it first: _"The animation phase: The [handleBeginFrame] method […] invokes all the transient frame callbacks registered with [scheduleFrameCallback], in registration order. This includes all the [Ticker] instances that are driving [AnimationController] objects, which means all of the active [Animation] objects tick at this point"_ ([`binding.dart`][wb-drawframe-doc]). Every animation in a frame therefore sees the same timestamp, and build, layout and paint see the ticked values.
2. **A controller is just a `Simulation` sampled by a `Ticker`.** Duration-and-curve motion is an internal `_InterpolationSimulation`; `fling` is a `SpringSimulation`; `animateWith` accepts any `Simulation` ([`animation_controller.dart`][ac-startsim]). A `Simulation` is a function of time: _"In principle, simulations can be stateless, and thus can be queried with arbitrary times"_ ([`simulation.dart`][sim-doc]).
3. **Values are pulled, not pushed.** `Animatable.evaluate` is `transform(animation.value)`, and `CurvedAnimation.value` applies its curve on read ([`tween.dart`][tween-animatable], [`animations.dart`][curved]). A chain `controller → CurvedAnimation → Tween` stores no intermediate values; only the controller holds state.
4. **The provider controls time; the consumer controls motion.** _"By convention, the [start] and [stop] methods are used by the ticker's consumer (for example, an [AnimationController]), and the [muted] property is controlled by the [TickerProvider] that created the ticker"_ ([`ticker.dart`][ticker-class]). That split lets `TickerMode` silence a whole subtree without the animations knowing.

---

## How it works

### `Ticker` and the transient-callback phase

`SchedulerBinding.scheduleFrameCallback` requests a frame and stores the callback in `_transientCallbacks` ([source][sb-schedulefc]). `handleBeginFrame` computes `_currentFrameTimeStamp = _adjustForEpoch(rawTimeStamp)`, enters `SchedulerPhase.transientCallbacks`, swaps the callback map for an empty one and invokes each callback with that one timestamp ([source][sb-begin]); the phases are `idle → transientCallbacks → midFrameMicrotasks → persistentCallbacks (build/layout/paint) → postFrameCallbacks` ([`SchedulerPhase`][sb-phase]).

A `Ticker` is a self-rescheduling transient callback. `start()` records `_startTime = currentFrameTimeStamp` if called mid-frame, otherwise the first tick sets it; `_tick` calls `_onTick(timeStamp - _startTime!)` and re-registers itself while `shouldScheduleTick` (`!muted && isActive && !scheduled`) holds ([`start`][ticker-start], [`_tick`][ticker-tick]). Callbacks therefore receive **elapsed time since start**, not wall time. A muted ticker _"can still run, but the callback will not be called"_ ([`muted`][ticker-muted]).

`TickerProvider.createTicker` is the only way to get one ([source][ticker-provider]). `SingleTickerProviderStateMixin`/`TickerProviderStateMixin` vend tickers bound to a `State`, mute them from the inherited `TickerMode`, and assert at `dispose` that none is still active (_"was disposed with an active Ticker"_, [source][tpm-dispose]).

### `AnimationController`

The controller holds `_value`, `_status`, `_direction`, the current `_simulation` and the `Ticker` it got from `vsync.createTicker(_tick)` ([constructor][ac-ctor]). Each tick evaluates the simulation at elapsed seconds, clamps to `[lowerBound, upperBound]`, stops when `isDone`, and notifies ([`_tick`][ac-tick]):

```dart
// packages/flutter/lib/src/animation/animation_controller.dart — _tick
void _tick(Duration elapsed) {
  _lastElapsedDuration = elapsed;
  final double elapsedInSeconds =
      elapsed.inMicroseconds.toDouble() / Duration.microsecondsPerSecond;
  _value = clampDouble(_simulation!.x(elapsedInSeconds), lowerBound, upperBound);
  if (_simulation!.isDone(elapsedInSeconds)) {
    _status = (_direction == _AnimationDirection.forward)
        ? AnimationStatus.completed
        : AnimationStatus.dismissed;
    stop(canceled: false);
  }
  notifyListeners();
  _checkStatusChanged();
}
```

`forward`, `reverse` and `animateTo` all route to `_animateToInternal`, which scales the duration by the remaining fraction of the range, calls `stop()`, and starts a fresh `_InterpolationSimulation(_value, target, duration, curve, scale)` ([source][ac-animateto]). `fling` builds a `SpringSimulation` from `value` with the given velocity ([source][ac-fling]); `animateWith(simulation)` takes any simulation ([source][ac-animatewith]). Every start returns a `TickerFuture`, and a superseded one is cancelled rather than completed ([`stop`][ac-stop]). `velocity` is `_simulation!.dx(elapsed)` while animating and `0.0` otherwise ([source][ac-velocity]).

### `Tween`, `Curve`, `CurvedAnimation`

`Animatable<T>.transform(double t)` is the interpolation; `evaluate(animation)` and `animate(parent)` bind it to an `Animation<double>` ([`tween.dart`][tween-animatable]). `Tween<T>` lerps `begin`/`end` ([source][tween-class]); typed subclasses (`ColorTween`, `RectTween`, `EdgeInsetsGeometryTween`, `DecorationTween`) live beside the widgets that use them ([`implicit_animations.dart`][implicit-tweens]). `Curve` is a `ParametricCurve<double>`; `Cubic` is a CSS-style Bézier (`Curves.easeInOut` is `Cubic(0.42, 0.0, 0.58, 1.0)`), with `Interval`, `Threshold` and `Curves` constants alongside ([`curves.dart`][curves-cubic]). `CurvedAnimation` applies `curve`, or `reverseCurve` while the parent runs in reverse, on each read of `value` ([source][curved]).

### `Simulation`s and springs

`Simulation` exposes `x(t)`, `dx(t)` and `isDone(t)` ([source][sim-doc]). `SpringSimulation(spring, start, end, velocity)` solves the damped oscillator in closed form (critically, under- or over-damped `_SpringSolution`) and is done when displacement and velocity are within `tolerance` ([source][spring-sim]). `SpringDescription` takes `mass`, `stiffness`, `damping`; `withDampingRatio(mass, stiffness, ratio)` derives `damping = ratio · 2√(mass·stiffness)`; `withDurationAndBounce(duration, bounce)` _"produces the same result as SwiftUI's `spring(duration:bounce:blendDuration:)` animation"_ ([source][spring-desc]). Scrolling is the main consumer: `BallisticScrollActivity` drives an `AnimationController.unbounded(...).animateWith(simulation)` ([source][ballistic]).

### Implicit animation: `ImplicitlyAnimatedWidget` and `TweenAnimationBuilder`

_"Widgets of this type will not animate when they are first added to the widget tree. Rather, when they are rebuilt with different values, they will respond to those changes by animating the changes over a specified [duration]"_ ([`ImplicitlyAnimatedWidget`][implicit-doc]). The `State` owns a controller and one tween per animated property, visited by the subclass's `forEachTween`. On every `didUpdateWidget`, if any target differs from its tween's `end`, **each tween's `begin` becomes its current evaluated value** and the controller restarts from zero ([`didUpdateWidget`][implicit-update]):

```dart
// packages/flutter/lib/src/widgets/implicit_animations.dart — ImplicitlyAnimatedWidgetState
controller.duration = widget.duration;
if (_constructTweens()) {
  forEachTween((Tween<dynamic>? tween, dynamic targetValue, TweenConstructor<dynamic> constructor) {
    return tween
      ?..begin = tween.evaluate(_animation)
      ..end = targetValue;
  });
  controller.forward(from: 0.0);
  didUpdateTweens();
}
```

Two base states set the cost. `AnimatedWidgetBaseState` adds `controller.addListener(() => setState(...))`, so `AnimatedContainer`, `AnimatedPadding` and `AnimatedAlign` **rebuild their subtree every tick** ([source][implicit-base]). `ImplicitlyAnimatedWidgetState` alone does not: `AnimatedOpacity` builds a `FadeTransition` once, driven by `animation.drive(tween)` ([source][animated-opacity]).

`TweenAnimationBuilder` exposes the same machinery to app code: _"The new animation runs from the current animation value (which may be [Tween.end] of the old [tween], if that animation completed) to [Tween.end] of the new [tween]"_ ([source][tab-doc]); its `forEachTween` passes `widget.tween.end` as the target to the shared retarget logic ([source][tab-state]).

### `AnimatedSwitcher` and `AnimatedList`

`AnimatedSwitcher` compares the new `child` with the current one by `Widget.canUpdate` (type and key). On a change it moves the current `_ChildEntry` (widget, controller, transition) into `_outgoingEntries`, calls `controller.reverse()` on it, and creates a new entry that runs `forward()`; a status listener removes an outgoing entry with `setState` when its animation is dismissed ([`didUpdateWidget`][switcher-update], [`_newEntry`][switcher-entry]). `build` hands the current transition and every outgoing one to `layoutBuilder`, by default a `Stack` ([source][switcher-build], [`defaultLayoutBuilder`][switcher-layout]). The outgoing child is the **old widget description**, kept and rebuilt every frame under a `KeyedSubtree`; its element and state stay mounted.

`AnimatedList` is imperative. The app mutates its own list and then calls `AnimatedListState.insertItem(index)` or `removeItem(index, builder)` through a `GlobalKey` ([`removeItem`][list-remove]). A removal records an `_ActiveItem.outgoing(controller, itemIndex, builder)`, reverses the controller, and only when it completes decrements `_itemsCount`; until then `_itemBuilder` calls the **removed-item builder** for that index instead of `itemBuilder` ([`_itemBuilder`][list-builder], [`AnimatedRemovedItemBuilder`][list-typedef]). The removed item is rebuilt from whatever the closure captured. There is no move or reorder animation.

### `Hero`

A `HeroController` (a `NavigatorObserver`) pairs heroes with equal `tag` in the outgoing and incoming routes. Unless a pop gesture can use already-laid-out geometry, it puts the incoming route `offstage` for a frame and starts the flight from a **post-frame callback**: _"Once this frame completes, we'll know where the heroes in the `to` route are going to end up"_ ([`_maybeStartHeroTransition`][hero-defer]). `_HeroFlightManifest` measures each hero's `RenderBox` with `getTransformTo` into its route's coordinate space ([source][hero-bbox]). `_HeroFlight.start` builds a `RectTween(fromHeroLocation, toHeroLocation)`, swaps both heroes for size-preserving placeholders, and inserts an `OverlayEntry` that positions the shuttle with `Positioned` from `heroRectTween.evaluate(_proxyAnimation)` each frame ([`start`][hero-start], [`_buildOverlay`][hero-overlay]). Each tick re-reads the destination's position and retargets the tween's `end` if it moved ([`onTick`][hero-ontick]); a push or pop mid-flight calls `divert`, which starts the new tween at `heroRectTween.evaluate(_proxyAnimation)` ([source][hero-divert]). The docs set the limits: _"If the [Hero] isn't axis aligned, this is going to fail in a rather ugly fashion. Don't rotate your heroes!"_ ([source][hero-doc]).

### Layout-driven animation: `RenderAnimatedSize`

`AnimatedSize` is implemented in the render tree. `RenderAnimatedSize.performLayout` lays out its child, then a four-state machine (`start`, `stable`, `changed`, `unstable`) decides whether to animate: a child size change while `stable` sets `_sizeTween.begin = size` (its own current size) and `end = child.size` and restarts; a child that changes size two frames running is tracked tightly instead of chased ([states][size-states], [`performLayout`][size-layout], [`_layoutStable`][size-stable]). The controller's listener calls `markNeedsLayout()` ([source][size-ctor]).

### `timeDilation`, `TickerMode` and reduced motion

`timeDilation` is a global that divides elapsed raw time in `_adjustForEpoch`; setting it calls `resetEpoch` so time stays monotonic ([`timeDilation`][sb-timedilation], [`_adjustForEpoch`][sb-epoch]). `TickerMode(enabled: false)` mutes every widget-aware ticker below it: _"Animations driven by such tickers are not paused, they just don't call their callbacks. Time still elapses"_ ([source][tickermode]). Each `OverlayEntry` wraps its content in `TickerMode(enabled: widget.tickerEnabled)`, and `OverlayState.build` passes `tickerEnabled: false` to every entry below the topmost opaque one that `maintainState`s, which is how routes covered by an opaque route stop animating ([`_OverlayEntryWidget`][overlay-tickermode], [`OverlayState.build`][overlay-build]).

Reduced motion is read from the engine, not from the widget tree. `AnimationBehavior.normal` consults `SemanticsBinding.instance.disableAnimations` ([source][ac-behavior]), and when it is set `_animateToInternal` runs the curve at 5 % of its duration: _"the common pattern of an eternally repeating animation might cause an endless loop if it weren't delayed for at least one frame. Instead, it's run at 5% of the normal duration"_ ([source][ac-animateto]); `fling` multiplies velocity by 200 instead ([source][ac-fling]). `MediaQueryData.disableAnimations` mirrors the flag but _"cannot be overridden using [MediaQuery]"_ for framework animations, and _"On iOS, reduced motion is exposed separately via [dart:ui.AccessibilityFeatures.reduceMotion] and does not set this flag"_ ([`media_query.dart`][mq-disable]).

### Testing: `FakeAsync` and `pump(duration)`

`AutomatedTestWidgetsFlutterBinding` runs each test inside a `FakeAsync` zone ([source][tb-fakeasync]). `tester.pump(duration)` calls `_currentFakeAsync!.elapse(duration)` and then, if a frame is scheduled, exactly one `handleBeginFrame(clock.now())` and `handleDrawFrame()` ([`pump`][tb-pump]). One `pump(const Duration(milliseconds: 150))` therefore samples every animation at t = 150 ms with no intermediate frames. `pumpAndSettle` pumps in 100 ms steps `while (binding.hasScheduledFrame)` and throws on timeout ([source][wt-settle]); `hasRunningAnimations` is `transientCallbackCount > 0` ([source][wt-running]). After a test, a pending fake timer is an assertion failure ([`_verifyInvariants`][tb-verify]).

---

## Analysis

### Where animation state lives

In ordinary objects owned by retained nodes: `AnimationController` fields of a `State` (reached through the element tree, [the reactive-programming deep-dive][rp-flutter]), or of a `RenderObject` (`RenderAnimatedSize`). Identity is therefore element identity: a keyed or same-type rebuild keeps the controller, and a type or key change disposes it. Values downstream of the controller (`CurvedAnimation`, `Tween`) are stateless views. There is no central animation store and no model/presentation split at the framework level: a widget's field holds the target and the controller holds the presentation value, and app code wires one to the other.

### Declaring an animation

Both styles exist and the explicit one is primary. **Explicit**: the app creates a controller with `vsync: this`, calls `forward`/`animateTo`/`animateWith`, and feeds `controller.drive(tween)` into an `AnimatedWidget` (`FadeTransition`, `SlideTransition`) or `AnimatedBuilder`. **Implicit**: `AnimatedContainer(duration:, curve:, ...)` and `TweenAnimationBuilder(tween:, ...)` animate when a rebuild passes a different target; the declaration is the target plus a duration and curve, with no velocity or spring option ([`ImplicitlyAnimatedWidget`][implicit-doc]). Implicit widgets are a thin, fixed policy over the explicit API, not a separate engine.

### Time and the clock

The `SchedulerBinding` owns the clock. The engine supplies a vsync timestamp, `_adjustForEpoch` applies `timeDilation`, and that one `currentFrameTimeStamp` is handed to every transient callback in a frame ([`handleBeginFrame`][sb-begin]). Tickers convert it to elapsed-since-start; controllers evaluate a `Simulation` at that elapsed time, so the motion is a **closed-form function of frame time**, not a stepped integration. Frames are frame ticks only: there is no document or scroll timeline (scroll-linked effects read `ScrollPosition.pixels` in build or paint). Muted time keeps elapsing ([`TickerMode`][tickermode]), so a resumed ticker jumps forward rather than pausing.

### Interruption and retargeting

There is one rule, applied by every start method: `stop()` the current simulation and start a new one **from the current value** ([`_animateToInternal`][ac-animateto], [`animateWith`][ac-animatewith]). Value is continuous; **velocity is not carried** by `animateTo` or by implicit widgets. `_InterpolationSimulation` has no initial-velocity term, and `ImplicitlyAnimatedWidgetState` restarts with `forward(from: 0.0)` over the **full** duration from the new `begin` ([`didUpdateWidget`][implicit-update]), so a rapid sequence of retargets never finishes and shows a velocity kink at each change. Preserving momentum is opt-in: read `controller.velocity` and pass it to a `SpringSimulation` via `animateWith`, as scrolling and `fling` do. There is no additive composition; two controllers writing one property must be combined by app code (`AnimationMean`, `AnimationMax` combine `Animation`s, not targets, [`animations.dart`][curved]). `Hero.divert` is the most complete retarget in the framework: it restarts from the evaluated in-flight rect toward the new destination ([source][hero-divert]).

### Curves and springs

Duration-plus-curve is the default everywhere (`Curves.*`, `Cubic`, `Interval`). Springs are `Simulation`s parametrised physically (`mass`, `stiffness`, `damping`), by ratio (`withDampingRatio`), or perceptually (`withDurationAndBounce`, matching SwiftUI) ([source][spring-desc]). A spring is only reachable through the explicit API (`animateWith`, `fling`); no implicit widget takes one. A spring's end is decided by `tolerance` (distance and velocity), not a duration ([`isDone`][spring-sim]), and `fling` asserts that its spring is not underdamped ([source][ac-fling]).

### Layout animation

Flutter has no general layout-transition mechanism; each widget picks a phase.

| Mechanism                                 | Runs in                                                                  | Needs previous geometry?                                                                  | Source                                               |
| ----------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| `AnimatedContainer`, `AnimatedPadding`, … | **build**: `setState` per tick, then normal layout                       | no; interpolates the widget's own previous _parameters_ (`begin` = current)               | [`AnimatedWidgetBaseState`][implicit-base]           |
| `AnimatedSize` (`RenderAnimatedSize`)     | **layout**: `performLayout` measures the child, then animates own size   | yes, its own last laid-out `size` becomes `begin`                                         | [`_layoutStable`][size-stable]                       |
| `FadeTransition`, `AnimatedOpacity`       | **compositing**: `markNeedsCompositedLayerUpdate`, no rebuild or repaint | no                                                                                        | [`_updateOpacity`][fade-update], [doc][layer-update] |
| `Hero`                                    | **build** in an `Overlay` per tick, from rects measured after layout     | yes, both: source rect from the current route, destination after an offstage layout frame | [`_maybeStartHeroTransition`][hero-defer]            |

So the geometry-animating mechanisms that need two layouts get the second one either by owning a render object that remembers its last size (`RenderAnimatedSize`), or by delaying the start by a frame and reading `RenderBox` positions from a post-frame callback (`Hero`). Nothing animates position changes of ordinary children (no FLIP for reorders); `AnimatedList` has no move ([`removeItem`][list-remove]). Paint- and compositor-only animation is available when the value is pushed straight into a render object (`RenderAnimatedOpacity` listens to its `Animation` directly), which skips build and layout.

### Enter and exit

Exit is done by **keeping the old widget description alive in a `State`**, not by snapshotting pixels. `AnimatedSwitcher` keeps outgoing `_ChildEntry`s, each with its old `widgetChild` and controller, and builds them every frame until their reverse animation is dismissed ([source][switcher-entry]). `AnimatedList` keeps an outgoing `_ActiveItem` with the app's removed-item builder until its controller completes ([source][list-remove]). `Hero` replaces the source hero with a placeholder and flies a shuttle widget in an `OverlayEntry`, removed in `_performAnimationUpdate` when the animation stops ([source][hero-overlay]). In every case the departing content is still a live subtree, rebuilt, laid out and painted, and it must be described by data the app no longer holds (`AnimatedList`'s builder closure captures it). Enter has no dedicated API: an implicit widget does not animate on first build ([`ImplicitlyAnimatedWidget`][implicit-doc]), so enter is spelled either with `TweenAnimationBuilder` (whose first build runs `begin → end`, [source][tab-state]) or with an explicit controller started in `initState`.

### Scheduling, reduced motion and testing

Frames are requested only while something is ticking: `Ticker.scheduleTick` calls `scheduleFrame` and re-registers only while active and unmuted ([source][ticker-schedule]), and a completed simulation stops its ticker ([`_tick`][ac-tick]). `TickerMode` and route offstaging cut work for invisible subtrees. Reduced motion is global and automatic but blunt: Android's "Remove animations" (`AccessibilityFeatures.disableAnimations`) shrinks every `AnimationBehavior.normal` controller to 5 % of its duration, cannot be overridden per subtree, and iOS's separate `reduceMotion` is not honoured unless app code reads it ([`media_query.dart`][mq-disable]). Tests get a fully virtual clock: `FakeAsync` plus `pump(duration)` produce one frame at an exact time, so animation states are assertable at arbitrary instants and tests run in microseconds ([`pump`][tb-pump]).

### Lessons for sparkles:ui

- **A dedicated animation phase before build is the right shape for a pure build.** Flutter samples every animation once, at one timestamp, before any `build` runs. A sparkles host that advances store-held animation phases at `FrameStart` and lets components read the committed values matches this exactly, with no ticker objects in components ([baseline][baseline]).
- **Closed-form simulations make time a parameter.** Because `Simulation.x(t)` is a function of elapsed time, Flutter's controllers need no per-frame state beyond the start time, which is what makes `pump(duration)` and `timeDilation` trivial. A store entry of `(start time, from, to, velocity, spec)` evaluated at the frame time is `@nogc` plain data with the same property.
- **Retarget-from-current-value without velocity is the failure case to avoid.** `ImplicitlyAnimatedWidget` restarts the full duration from the current value and drops velocity; Compose and SwiftUI carry it ([Compose][compose]). A store that keeps `velocity` alongside the value can retarget springs continuously at no extra cost.
- **For UI-Q9, Flutter puts geometry animation where the previous geometry already is.** `RenderAnimatedSize` animates in layout because it holds last frame's size; `Hero` waits a frame and reads `RenderBox` rects post-layout. A sparkles component should not need to read last frame's rect to animate a resize: the host can interpolate between the committed rect and this frame's laid-out rect after layout, as `RenderAnimatedSize` does inside layout. See UI-Q9 ([PR #775][pr775]).
- **For UI-Q10, Flutter's exits retain descriptions, not pixels, and that pushes the burden onto the app.** `AnimatedList.removeItem` makes the app supply a builder for an item it has already deleted. A store-driven closing state that repaints the element's last committed subtree removes that burden; a retained draw list (Compose's lazy-list approach, [Compose][compose]) is the cheaper variant when the subtree need not stay live. See UI-Q10 ([PR #775][pr775]).
- **Reduced motion belongs to the animation layer, but per subtree.** Flutter's 5 % rule is automatic and sound for loops, yet the flag cannot be scoped or overridden; sparkles can apply the same substitution in the host while still letting a component ask for "essential motion" (`AnimationBehavior.preserve`).

---

## Strengths

- One clock, one phase: every animation in a frame sees the same timestamp, and build/layout/paint see ticked values ([`drawFrame`][wb-drawframe-doc]).
- `Simulation` is a small, general, closed-form interface; tweens, springs, friction and scroll physics all fit it.
- A fully virtual test clock with exact-time sampling (`FakeAsync`, `pump(duration)`), plus a dev-time `timeDilation`.
- Cheap paths exist below build: `FadeTransition`/`RenderAnimatedOpacity` update a composited layer without rebuilding or repainting children.
- `TickerMode` silences offstage subtrees without the animations' cooperation.

## Weaknesses

- Controllers are manual resources: `vsync`, `initState`, `dispose`, and a debug assertion if a ticker outlives its `State` ([source][tpm-dispose]).
- Implicit animations restart the full duration and drop velocity on every retarget ([source][implicit-update]); springs are unavailable to them.
- No general layout animation: no reorder/FLIP, `Hero` only across routes and only for axis-aligned rects, `AnimatedSize` only for its own box.
- Exit animations require keeping or reconstructing the departing widget (`AnimatedList`'s removed-item builder, `AnimatedSwitcher`'s retained child).
- Reduced motion cannot be scoped or overridden per subtree, and iOS's flag is separate.

---

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                | Trade-off                                                                    |
| --------------------------------------------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| Animation runs in a transient-callback phase before build       | one timestamp per frame; build/layout/paint see consistent ticked values | an animation cannot react to this frame's layout until the next frame        |
| `AnimationController` is an explicit object owned by a `State`  | full control: start, stop, reverse, fling, status, futures               | lifecycle boilerplate (`vsync`, `dispose`); state hidden in widget internals |
| Motion is a `Simulation` evaluated at elapsed time              | closed form, seekable, trivially testable and dilatable                  | velocity continuity across restarts is not automatic                         |
| `Animation` values are pulled through `Tween`/`CurvedAnimation` | composition without intermediate state                                   | every read recomputes; listeners must be wired per consumer                  |
| Implicit widgets restart from the current value, full duration  | simple, no velocity bookkeeping                                          | visible kinks and never-finishing motion under rapid retargeting             |
| Exit keeps the old widget alive in an owning `State`            | the departing subtree stays interactive-capable and re-layoutable        | the app must preserve or rebuild data for content it has already removed     |
| `Hero` waits one frame and flies in an `Overlay`                | both routes' geometry known; shuttle escapes route clipping              | one-frame start latency; axis-aligned rects only                             |
| Reduced motion scales controllers to 5 %, read from the engine  | automatic, safe for repeating animations                                 | not overridable or scoped; iOS reduce-motion separate                        |

---

## Sources

- Flutter source at tag commit `9584c67` (3.47.4): [`animation_controller.dart`][ac-ctor], [`tween.dart`][tween-class], [`curves.dart`][curves-cubic], [`animations.dart`][curved], [`scheduler/binding.dart`][sb-begin], [`ticker.dart`][ticker-class], [`physics/simulation.dart`][sim-doc], [`spring_simulation.dart`][spring-sim], [`implicit_animations.dart`][implicit-doc], [`tween_animation_builder.dart`][tab-doc], [`animated_switcher.dart`][switcher-update], [`animated_scroll_view.dart`][list-remove], [`heroes.dart`][hero-doc], [`ticker_provider.dart`][tickermode], [`overlay.dart`][overlay-tickermode], [`rendering/animated_size.dart`][size-layout], [`transitions.dart`][fade-widget], [`media_query.dart`][mq-disable], [`widgets/binding.dart`][wb-drawframe-doc], [`scroll_activity.dart`][ballistic].
- `flutter_test` at the same commit: [`binding.dart`][tb-pump], [`widget_tester.dart`][wt-settle].
- Flutter history: [`TweenAnimationBuilder` (#38317, merged 2019-08-23)][pr-38317]; [`AnimatedChildSwitcher` renamed `AnimatedSwitcher` (#16551, 2018-04-16)][pr-16551]; [`AnimationStyle` introduced (#137945, 2023-11-16)][pr-137945].
- Official docs: [Introduction to animations][d-animations], [Implicit animations][d-implicit], [Hero animations][d-hero].
- In this survey: [Concepts][concepts], [Sparkles baseline][baseline], [Jetpack Compose][compose], [SwiftUI][swiftui]; elsewhere: [Flutter widgets, elements and render objects][rp-flutter], [Flutter layout][layout-flutter], [UI authoring decisions][ui-authoring].

<!-- References -->

[license]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/LICENSE
[repo]: https://github.com/flutter/flutter
[src-animation]: https://github.com/flutter/flutter/tree/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation
[src-scheduler]: https://github.com/flutter/flutter/tree/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler
[src-physics]: https://github.com/flutter/flutter/tree/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/physics
[src-widgets]: https://github.com/flutter/flutter/tree/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets
[src-flutter-test]: https://github.com/flutter/flutter/tree/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter_test
[d-animations]: https://docs.flutter.dev/ui/animations
[d-implicit]: https://docs.flutter.dev/ui/animations/implicit-animations
[d-hero]: https://docs.flutter.dev/ui/animations/hero-animations
[wb-drawframe-doc]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/binding.dart#L1479-L1484
[ac-behavior]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/animation_controller.dart#L47-L78
[ac-ctor]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/animation_controller.dart#L230-L270
[ac-velocity]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/animation_controller.dart#L404-L415
[ac-animateto]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/animation_controller.dart#L642-L688
[ac-fling]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/animation_controller.dart#L773-L800
[ac-animatewith]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/animation_controller.dart#L820-L830
[ac-startsim]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/animation_controller.dart#L856-L867
[ac-stop]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/animation_controller.dart#L869-L895
[ac-tick]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/animation_controller.dart#L934-L948
[tween-animatable]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/tween.dart#L57-L90
[tween-class]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/tween.dart#L267-L300
[curves-cubic]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/curves.dart#L365-L380
[curved]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/animation/animations.dart#L387-L460
[sb-timedilation]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/binding.dart#L36-L54
[sb-phase]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/binding.dart#L160-L199
[sb-schedulefc]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/binding.dart#L608-L622
[sb-epoch]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/binding.dart#L1085-L1125
[sb-begin]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/binding.dart#L1226-L1274
[ticker-provider]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/ticker.dart#L43-L53
[ticker-class]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/ticker.dart#L55-L78
[ticker-muted]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/ticker.dart#L102-L129
[ticker-start]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/ticker.dart#L185-L208
[ticker-tick]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/ticker.dart#L270-L286
[ticker-schedule]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/scheduler/ticker.dart#L287-L305
[sim-doc]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/physics/simulation.dart#L11-L50
[spring-desc]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/physics/spring_simulation.dart#L23-L80
[spring-sim]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/physics/spring_simulation.dart#L204-L262
[ballistic]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/scroll_activity.dart#L584-L606
[implicit-tweens]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/implicit_animations.dart#L40-L224
[implicit-doc]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/implicit_animations.dart#L226-L252
[implicit-update]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/implicit_animations.dart#L358-L441
[implicit-base]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/implicit_animations.dart#L543-L567
[animated-opacity]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/implicit_animations.dart#L1886-L1909
[tab-doc]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/tween_animation_builder.dart#L122-L132
[tab-state]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/tween_animation_builder.dart#L180-L213
[switcher-update]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/animated_switcher.dart#L276-L334
[switcher-entry]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/animated_switcher.dart#L336-L365
[switcher-build]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/animated_switcher.dart#L393-L404
[switcher-layout]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/animated_switcher.dart#L228-L236
[list-typedef]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/animated_scroll_view.dart#L925-L938
[list-builder]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/animated_scroll_view.dart#L1347-L1356
[list-remove]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/animated_scroll_view.dart#L1419-L1455
[hero-doc]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/heroes.dart#L126-L150
[hero-bbox]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/heroes.dart#L499-L520
[hero-overlay]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/heroes.dart#L572-L612
[hero-ontick]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/heroes.dart#L666-L695
[hero-start]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/heroes.dart#L697-L738
[hero-divert]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/heroes.dart#L741-L800
[hero-defer]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/heroes.dart#L955-L975
[tickermode]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/ticker_provider.dart#L19-L44
[tpm-dispose]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/ticker_provider.dart#L358-L380
[overlay-tickermode]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/overlay.dart#L418-L428
[overlay-build]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/overlay.dart#L888-L910
[size-states]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/animated_size.dart#L15-L51
[size-ctor]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/animated_size.dart#L87-L95
[size-layout]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/animated_size.dart#L245-L278
[size-stable]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/animated_size.dart#L322-L340
[fade-widget]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/transitions.dart#L589-L620
[fade-update]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/proxy_box.dart#L1052-L1067
[layer-update]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/rendering/object.dart#L3381-L3398
[mq-disable]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter/lib/src/widgets/media_query.dart#L663-L693
[tb-pump]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter_test/lib/src/binding.dart#L2248-L2266
[tb-fakeasync]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter_test/lib/src/binding.dart#L2478-L2492
[tb-verify]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter_test/lib/src/binding.dart#L2523-L2545
[wt-settle]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter_test/lib/src/widget_tester.dart#L692-L722
[wt-running]: https://github.com/flutter/flutter/blob/9584c6713b324636289d067944a46fd6b49df14b/packages/flutter_test/lib/src/widget_tester.dart#L848-L854
[pr-38317]: https://github.com/flutter/flutter/pull/38317
[pr-16551]: https://github.com/flutter/flutter/pull/16551
[pr-137945]: https://github.com/flutter/flutter/pull/137945
[pr775]: https://github.com/PetarKirov/sparkles/pull/775
[concepts]: ./concepts.md
[baseline]: ./sparkles-baseline.md
[compose]: ./jetpack-compose.md
[swiftui]: ./swiftui.md
[rp-flutter]: ../reactive-programming/flutter.md
[layout-flutter]: ../ui-layout/flutter.md
[ui-authoring]: ../ui-authoring/index.md
