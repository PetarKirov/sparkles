# Jetpack Compose animation (Kotlin)

Compose animates with snapshot-state value holders that suspend on a frame clock: `animate*AsState` and `Transition` turn a changed target in composition into a coroutine that calls `withFrameNanos` each frame and evaluates a stateless `AnimationSpec` at the elapsed play time, carrying value _and_ velocity across retargets. Layout animation is a second, built-in measure pass: inside a `LookaheadScope` every layout is first measured and placed at its destination, then an _approach_ pass lets `ApproachLayoutModifierNode`s (`animateBounds`, shared elements) animate from the bounds they showed last frame toward it.

| Field                    | Value                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | Kotlin (Multiplatform: `commonMain` sources; Android, JVM desktop, iOS and web hosts)                                                                                                                                                                                                                                                                       |
| License                  | Apache-2.0 ([`LICENSE.txt`][license])                                                                                                                                                                                                                                                                                                                       |
| Repository               | [androidx/androidx][repo]: [`compose/animation/animation-core`][src-core], [`compose/animation/animation`][src-anim]; lookahead in [`compose/ui/ui/.../layout`][src-layout]; lazy items in [`compose/foundation/.../lazy/layout`][src-lazy]                                                                                                                 |
| Documentation            | [Animations in Compose][d-intro] · [Shared element transitions][d-shared] · [Compose phases][d-phases] · [Test animations][d-testing] · KDoc in the sources cited below                                                                                                                                                                                     |
| Category                 | declarative target values with implicit retargeting (`animate*AsState`, `Transition`) over imperative suspend-function holders (`Animatable`); spec objects are stateless functions of play time; lookahead/approach two-pass layout animation                                                                                                              |
| Versions surveyed        | Compose **1.14.0-alpha02** (`COMPOSE` in [`libraryversions.toml`][versions], an atomic version for runtime, ui, foundation and animation), `androidx-main` commit `296313a488a0`, 2026-11-21; the same pin as the [reactive-programming deep-dive][rp-compose]                                                                                              |
| Animation state lives in | `remember`ed holders in the composition slot table (`Animatable`, `Transition` and its `TransitionAnimationState`s), whose value and velocity are snapshot `MutableState`; layout animations keep theirs in `Modifier.Node` instances (`SizeAnimationModifierNode`, `BoundsAnimationModifierNode`) and lazy items in a key-indexed `LazyLayoutItemAnimator` |

> [!NOTE]
> This page covers animation. The snapshot system, the `Recomposer`'s frame loop, `MonotonicFrameClock` dispatch and `MainTestClock` are described in [Jetpack Compose Runtime][rp-compose] ([time and scheduling][rp-compose-time], [testing][rp-compose-test]) and [Testing FRP and UI loops][rp-testing-compose], and are only summarised here; layout itself is in [Compose layout][layout-compose]. Vocabulary follows the catalog's [concepts][concepts].

---

## Overview

### What it solves

Composable functions re-run from state, so a value that should move between two states needs a holder that outlives one composition and advances between them. Compose's holders are snapshot state: an animation writes its current value into a `MutableState` once per frame, and only the scopes that **read** it are invalidated, in whichever phase read it. The phases doc states the consequence: _"State reads during drawing code affect the drawing phase. […] When the state's value changes, Compose UI runs only the draw phase"_ ([Compose phases][d-phases]). The same value read inside `Modifier.graphicsLayer { }` _"will only cause the layer properties update without triggering recomposition and relayout"_ ([`GraphicsLayerModifier.kt`][graphicslayer]). A single animation API therefore serves composition-, layout- and draw-phase animation; the caller picks the phase by where it reads.

### Design philosophy

1. **Specs are stateless; holders are stateful.** _"[VectorizedAnimationSpec]s are stateless vector based animation specifications. […] Its stateless nature allows the same [VectorizedAnimationSpec] to be reused by a few different running animations with different starting and ending values. More importantly, it allows the system to reuse the same animation spec when the animation target changes in-flight"_ ([`VectorizedAnimationSpec.kt`][vspec-doc]). An `Animation` _"does not track the lifecycle of an animation. It merely reacts to play time change and returns the new value/velocity"_ ([`Animation.kt`][animation-doc]).
2. **Continuity is the default.** `Animatable.animateTo` mid-flight starts _"from its current value (i.e. value at the point of interruption) to the new [targetValue]. This ensures that the value change is **always** continuous […] If a [spring] animation (e.g. default animation) is used with [animateTo], the velocity change will guarantee to be continuous as well"_ ([`Animatable.kt`][animatable-doc]). `spring()` is the default spec of `animate*AsState`, `Animatable`, `animateContentSize`, `animateItem` and `animateBounds`.
3. **Mutual exclusion through structured concurrency.** _"[Animatable] ensures *mutual exclusiveness* on its animations […] any ongoing animation will be canceled via a [CancellationException]"_ ([`Animatable.kt`][animatable-doc]); the cancellation is a `MutatorMutex`, the same primitive scroll and gestures use.
4. **Layout animation is a layout pass, not an effect.** _"[LookaheadScope] creates a scope in which all layouts will first determine their destination layout through a lookahead pass, followed by an *approach* pass to run the measurement and placement approach defined in [approachLayout] or [ApproachLayoutModifierNode], in order to gradually reach the destination"_ ([`LookaheadScope.kt`][lookahead-doc]).

---

## How it works

### `MonotonicFrameClock`, `withFrameNanos` and duration scale

Every Compose animation ends in a loop over `withFrameNanos`, which _"Suspends until a new frame is requested, immediately invokes [onFrame] with the frame time in nanoseconds […] `frameTimeNanos` should be used when calculating animation time deltas from frame to frame as it may be normalized to the target time for the frame"_ ([`MonotonicFrameClock.kt`][frameclock]). The internal `AnimationState.animate` creates the scope on the first frame (start time = that frame's time), then loops `while (isRunning)` calling `doAnimationFrameWithScale`, which computes `playTimeNanos = (frameTimeNanos - startTimeNanos) / durationScale` and sets `value = anim.getValueFromNanos(playTimeNanos)` and `velocityVector = anim.getVelocityVectorFromNanos(playTimeNanos)` ([`SuspendAnimation.kt`][suspend-animate], [`doAnimationFrame`][suspend-frame]). `durationScale` is the `MotionDurationScale` element of the coroutine context (default 1); a scale of 0 makes `playTimeNanos = durationNanos`, so _"the motion will end in the next frame callback"_ ([`SuspendAnimation.kt`][suspend-scale], [`MotionDurationScale.kt`][mds]). On Android the `Recomposer`'s context carries a `MotionDurationScaleImpl` that observes `Settings.Global.ANIMATOR_DURATION_SCALE` ([`WindowRecomposer.android.kt`][wr-scale], [`MotionDurationScaleImpl`][wr-impl]). How the `Recomposer` dispatches frames is in [Compose runtime § Time and scheduling][rp-compose-time].

### `Animatable`

`Animatable(initialValue, typeConverter)` holds `value`, `velocityVector`, `targetValue`, `isRunning` and optional bounds; `TwoWayConverter` maps `T` to an `AnimationVector1D…4D` so every dimension animates independently ([`Animatable.kt`][animatable-class]). `animateTo(target, spec, initialVelocity = velocity)` builds a `TargetBasedAnimation(spec, value, target, initialVelocity)` and runs it under `mutatorMutex.mutate { … }` ([`animateTo`][animatable-animateto], [`runAnimation`][animatable-run]); `animateDecay(initialVelocity, decaySpec)` builds a `DecayAnimation` instead. `snapTo` and `stop` take the same mutex, so they cancel any running animation with a `CancellationException` before setting the value ([`snapTo`, `stop`][animatable-snap]). When an animation ends, velocity resets to zero; the end state is returned in `AnimationResult` for chaining a fling into a spring ([`endAnimation`][animatable-end]).

### `animate*AsState`

`animateValueAsState(targetValue, converter, spec)` remembers an `AnimateAsState` holding an `Animatable` and a composition `CoroutineScope`, and in a `SideEffect` (after the composition commits) calls `update` ([source][aas-fun]). `update` restarts when `target != animatable.targetValue`: it cancels the previous job and launches, `CoroutineStart.UNDISPATCHED` _"to allow for continuous progress when target changes every frame"_, `animatable.animateTo(newTarget, specToUse)` ([source][aas-update]). The KDoc: _"If there is already an animation in-flight when [targetValue] changes, the on-going animation will adjust course to animate towards the new target value"_, and _"[animateFloatAsState] cannot be canceled/stopped without removing this composable function from the tree"_ ([`AnimateAsState.kt`][aas-doc]).

```kotlin
// compose/animation/animation-core/.../AnimateAsState.kt — AnimateAsState.restartAnimation
job = coroutineScope.launch(
    // undispatched to allow for continuous progress when target changes every frame
    start = CoroutineStart.UNDISPATCHED
) {
    animatable.animateTo(newTarget, specToUse)
    finishedListener?.invoke(animatable.value)
}
```

### `Transition`: `updateTransition`, `rememberTransition`, `SeekableTransitionState`

A `Transition<S>` animates many values toward targets derived from one state. `updateTransition(targetState)` remembers a `Transition` and calls `animateTo(targetState)` every composition ([source][tr-update]); `rememberTransition(transitionState)` takes a `MutableTransitionState` (an initial state different from the target, so it animates on entry) or a `SeekableTransitionState`. Child values come from `transition.animateFloat { state -> … }` / `animateValue`, each a `TransitionAnimationState` that keeps its own `animation`, `value` and `velocityVector`. The frame loop exists only while needed: a `derivedStateOf { targetState != currentState || isRunning || updateChildrenNeeded }` gates a `DisposableEffect` that launches `while (isActive) withFrameNanos { onFrame(it, durationScale) }`, and `onFrame` pulses `playTimeNanos` to every child ([`animateTo`][tr-loop], [`onFrame`][tr-onframe]). `SeekableTransitionState` replaces the clock with a fraction: _"A [TransitionState] that can manipulate the progress of the [Transition] by seeking with [seekTo] or animating with [animateTo]"_ ([source][tr-seekable]); `seekTo(fraction, targetState)` drives predictive-back and other gesture-scrubbed transitions ([source][tr-seekto]).

### `AnimationSpec`

| Spec                                                     | Parametrisation                                                                                   | Source                                                               |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `tween(durationMillis = 300, delay, easing)`             | duration + `Easing` (`FastOutSlowInEasing`, `CubicBezierEasing`, `PathEasing`)                    | [`tween`][spec-tween]                                                |
| `spring(dampingRatio, stiffness, threshold)`             | `Spring.DampingRatioNoBouncy` (1) and `Spring.StiffnessMedium` (1500) by default; mass fixed at 1 | [`spring`][spec-spring], [`Spring`][spring-consts]                   |
| `keyframes { durationMillis; v at t using e }`           | timestamped values, per-segment easing; `keyframesWithSpline` for monotone splines                | [`keyframes`][spec-keyframes]                                        |
| `repeatable`, `infiniteRepeatable`, `snap`               | wrap a duration-based spec; `snap` jumps                                                          | [`AnimationSpec.kt`][spec-file]                                      |
| `DecayAnimationSpec`                                     | `exponentialDecay(friction)`, `splineBasedDecay(density)` (Android fling curve); has no target    | [`DecayAnimationSpec.kt`][decay], [`splineBasedDecay`][spline-decay] |
| `InterruptionAwareAnimationSpec(spec, interruptionSpec)` | `spec` from rest, `interruptionSpec` when a target changes mid-flight                             | [source][spec-interrupt]                                             |

The spring is solved analytically from the start value and velocity at the play time: `FloatSpringSpec.getValueFromNanos` calls `spring.updateValuesSeconds(initialValue, initialVelocity, deltaTSeconds)` on a `SpringSimulation` whose natural frequency is `sqrt(stiffness)` ([`FloatAnimationSpec.kt`][float-spring], [`SpringSimulation.kt`][spring-sim]).

### `AnimatedVisibility`, `AnimatedContent`, `Crossfade`: exit by staying composed

`AnimatedVisibility(visible)` is a `Transition<Boolean>` mapped by `createChildTransition` to `EnterExitState` (`PreEnter`, `Visible`, `PostExit`). `AnimatedEnterExitImpl` keeps composing `content` while _either_ the transition's target or current state is visible, and drops it only when `currentState == PostExit && targetState == PostExit` ([source][av-impl]). The KDoc: _"[content] will only be removed after all the (built-in and custom) exit animations have finished"_ ([source][av-doc]). The caller keeps calling `AnimatedVisibility(visible = false) { … }` in its own composition, so the exiting content is **live, recomposed code** reading current state. Inside a lookahead pass `AnimatedVisibilityImpl` reports `IntSize.Zero` for content whose target is invisible, so the lookahead layout already has the content gone ([source][av-lookahead]).

`AnimatedContent(targetState)` keeps `currentlyVisible`, a list of **state values** `S` (not of nodes or pixels), appends each new target, and composes `key(contentKey(s)) { content(s) }` for every entry inside its own `AnimatedEnterExitImpl`; a `DisposableEffect` removes `s` from the list when its exit completes ([`AnimatedContentImpl`][ac-list], [content loop][ac-loop]). The old content is re-invoked with its old state value, so a stale `S` must still render. `SizeTransform` animates the container between the content sizes ([source][ac-size]). `Crossfade` is the same list with an `animateFloat` alpha per entry applied in `graphicsLayer` ([source][crossfade]).

### `Modifier.animateContentSize`

`SizeAnimationModifierNode` is a `LayoutModifierNode`. In `measure` it measures the child, then reports `animateTo(measuredSize)` instead of the child's size; `animateTo` relaunches `anim.animateTo(targetSize, spec)` when the target changes, starting from `anim.value` ([source][acs-node]). Inside a lookahead scope it records the lookahead size and animates toward it in the main pass. Reading `anim.value` in `measure` makes the node re-measure each frame; the child is laid out once at its final size and clipped or aligned inside the animated box ([`animateContentSize`][acs-doc]).

### Lazy lists: `Modifier.animateItem`

`animateItem(fadeInSpec, placementSpec, fadeOutSpec)` _"animates the item appearance (fade in), disappearance (fade out) and placement changes (such as an item reordering)"_ and needs a stable `key` ([`LazyItemScope.kt`][animateitem-doc]). `LazyLayoutItemAnimator.onMeasured` runs after each list measure: it compares each item's index with `previousKeyToIndexMap`, and for an item whose offset changed computes `delta = newTarget - currentTarget` and calls `animatePlacementDelta(delta)`, which animates an offset back to zero (FLIP) ([`onMeasured`][lia-onmeasured], [`startPlacementAnimationsIfNeeded`][lia-placement]). Placement adds `animation.placementDelta` to the item's target offset and places it `placeWithLayer` ([`LazyListMeasuredItem.kt`][lazy-place]). A **removed** item (`newIndex == -1`) is not recomposed: its last `GraphicsLayer` is put in `disappearingItems` and drawn by the list in `onDrawDisappearingItems` at its last placement offset until the fade finishes ([removal][lia-remove], [draw][lia-draw]).

### Lookahead: `LookaheadScope`, `approachLayout`, `animateBounds`

Inside a `LookaheadScope`, each invalidated node is measured twice per frame. `DepthSortedSetsForDifferentPasses.popEach` drains, in order, _"lookaheadAndAncestorMeasureSet, lookaheadAndAncestorPlaceSet, approachSet"_ ([`DepthSortedSet.kt`][dss-popeach]); `remeasureAndRelayoutIfNeeded` runs `doLookaheadRemeasure` and `lookaheadReplace` for lookahead entries and `doRemeasure`/`replace` for approach entries ([`MeasureAndLayoutDelegate.kt`][mld-remeasure]). During the lookahead pass a modifier's ordinary `measure` runs (`isLookingAhead == true`) and produces the destination; during the approach pass an `ApproachLayoutModifierNode`'s `approachMeasure` runs with `lookaheadSize` available, and `isPlacementApproachInProgress(lookaheadCoordinates)` sees the destination position ([`ApproachLayoutModifierNode.kt`][approach-doc]). `LayoutModifierNodeCoordinator.measure` asks `isMeasurementApproachInProgress(lookaheadSize)` first and, once both predicates are false, forces the child to the lookahead constraints and snaps the result to the lookahead size ([source][lmnc-measure]):

```kotlin
// compose/ui/ui/.../node/LayoutModifierNodeCoordinator.kt — measure (approach pass)
scope.approachMeasureRequired =
    isMeasurementApproachInProgress(scope.lookaheadSize) ||
        constraints != lookaheadConstraints
if (!scope.approachMeasureRequired) {
    wrappedNonNull.forceMeasureWithLookaheadConstraints = true
}
val result = scope.approachMeasure(wrappedNonNull, constraints)
```

`Modifier.animateBounds(lookaheadScope, boundsTransform)` is the general client. `BoundsAnimationModifierNode.isMeasurementApproachInProgress` records the lookahead size as target; `isPlacementApproachInProgress` records the lookahead position (`localLookaheadPositionOf`) and, if the target changed, launches `Animatable<Rect>.animateTo(target, boundsTransform(currentBounds, target))`; `approachMeasure` measures and places the child at the animated rect ([node][ab-node], [`BoundsTransformDeferredAnimation`][ab-deferred], [`animate`][ab-animate]). The **start** of every bounds animation is `currentBounds`, the rect the node itself produced in the previous approach pass; the **target** is this frame's lookahead result. Positions under a `LayoutCoordinates.introducesMotionFrameOfReference` parent (scroll) are excluded by default ([`animateBounds`][ab-doc]).

### Shared elements: `SharedTransitionLayout`, `sharedElement`, `sharedBounds`

`SharedTransitionScope { }` is a `LookaheadScope` plus a root modifier that records both the lookahead root and the approach root coordinates and draws an overlay ([source][st-scope], [root node][st-root]). `Modifier.sharedElement(state, animatedVisibilityScope)` and `sharedBounds(…)` tag layouts with a key; an entry in an exiting `AnimatedVisibility`/`AnimatedContent` and one in an entering one match, and _"The bounds will be animated from the initial bounds defined by the exiting shared element to the target bounds calculated based on the incoming shared element"_ ([`sharedElement`][st-element]). Both are still composed and laid out, because both sit inside an `AnimatedVisibilityScope` that keeps them composed through the transition. While the bounds transform runs, _"it will be rendered into the overlay of the [SharedTransitionScope] in order to avoid being faded in/out along with its parents or clipped by its parent"_: `SharedContentNode.draw` records its content into a `GraphicsLayer` instead of drawing in place, and the root's `drawInOverlay` draws every recorded layer at the animated bounds ([`SharedContentNode.kt`][st-draw], [`SharedTransitionScope.kt`][st-root]). `sharedElement` remeasures the child to the animated size; `sharedBounds` defaults to `scaleToBounds`, which _"avoids frame-by-frame remeasurement"_ ([`sharedBounds`][st-bounds]).

### Testing: `mainClock.autoAdvance = false`

`MainTestClock` _"is ultimately responsible for driving all recompositions, all subscribers to [withFrameNanos] (all compose animations) and all coroutines launched with [LaunchedEffect]"_ ([`MainTestClock.kt`][mtc-doc]). With `autoAdvance = false`, `advanceTimeByFrame()`, `advanceTimeBy(ms)` and `advanceTimeUntil { }` step it; the KDoc documents the one-frame start latency: _"Because animations receive their [frame time] *before* recomposition, an animation will not get its start time in the first frame after kicking it off by toggling a state variable"_ ([source][mtc-doc]). `MotionDurationScale` is injectable through the test rule's `effectContext` ([`MotionDurationScale.kt`][mds]). Details and a worked example are in [Compose runtime § Testing][rp-compose-test] and [Testing FRP and UI loops][rp-testing-compose].

---

## Analysis

### Where animation state lives

In remembered objects in the composition slot table, keyed by call-site position (and `key()`), with snapshot `MutableState` for the observable parts: `Animatable.value`, `TransitionAnimationState.value`, `velocityVector`. Layout animations put theirs in `Modifier.Node`s attached to the layout node (`SizeAnimationModifierNode.animData`, `BoundsAnimationModifierNode.boundsAnimation`), so they live exactly as long as the node. Lazy lists key it by item key in `LazyLayoutItemAnimator.keyToItemInfoMap` ([source][lia-class]). There is no global store; the snapshot system is what lets any phase observe these values without a store.

### Declaring an animation

**Implicit and declarative** is the default surface: `animateDpAsState(if (expanded) 200.dp else 80.dp)`, `updateTransition(state).animateColor { … }`, `AnimatedVisibility(visible)`, `AnimatedContent(target)`, `Modifier.animateContentSize()`, `animateItem()`, `animateBounds(scope)`. A target computed in composition is the whole declaration; the holder animates when it differs. **Explicit and imperative** is `Animatable`: suspend calls (`animateTo`, `animateDecay`, `snapTo`, `stop`) in a `LaunchedEffect` or gesture coroutine, needed for gesture-driven motion and sequencing. `SeekableTransitionState` is a third mode, a declarative transition whose progress the app supplies.

### Time and the clock

The host owns the clock; animations only ask for it. The frame time arrives through the `MonotonicFrameClock` in the `Recomposer`'s coroutine context (Choreographer on Android), is normalised to the frame's target time, and is converted to play time relative to the animation's first frame ([`MonotonicFrameClock.kt`][frameclock], [`SuspendAnimation.kt`][suspend-animate]). Specs are evaluated in closed form at that play time, so a dropped frame does not change where the animation is. `MotionDurationScale` divides elapsed time globally per context. There is no document or scroll timeline; scroll-linked motion reads scroll state, and `SeekableTransitionState.seekTo(fraction)` is the only "timeline" whose position is not time ([source][tr-seekto]). Within a frame the order is fixed: frame-clock subscribers first, then recomposition, then measure/layout (lookahead then approach), then draw ([`MainTestClock.kt`][mtc-doc], [`DepthSortedSet.kt`][dss-popeach]).

### Interruption and retargeting

Retargeting is continuous in value and, for springs, in velocity. `Animatable.animateTo` defaults `initialVelocity = velocity`, so the new `TargetBasedAnimation` starts from the in-flight value and velocity ([source][animatable-animateto]); `runAnimation` reuses the interrupted animation's `lastFrameTimeNanos` as the new start so no frame is lost ([source][animatable-run]). `Transition` goes further for non-spring specs: on interruption _"use the default spring, unless the spec is also a spring or specifies its own interruption spec"_, so a `tween` interrupted mid-flight becomes a velocity-preserving spring to the new target ([`TransitionAnimationState.updateAnimation`][tr-interrupt]); `InterruptionAwareAnimationSpec` lets an author choose the interruption spec for `Transition`, `animate*AsState` and `Animatable` alike ([source][spec-interrupt]). A `tween` driven through `Animatable` ignores the carried velocity (duration specs have no velocity input), so only springs and the `Transition` fallback are velocity-continuous. Composition is exclusive, not additive: a new `animateTo` cancels the old one through the `MutatorMutex` ([source][animatable-run]). `AnimatedContent` is interruptible by design: `currentlyVisible` can hold several states at once, each with its own enter/exit progress ([source][ac-list]).

### Curves and springs

Both are first-class, and springs are the default. `spring(dampingRatio, stiffness)` with named constants (`DampingRatioNoBouncy`/`LowBouncy`/`MediumBouncy`/`HighBouncy`, `StiffnessHigh`…`VeryLow`) and an implicit unit mass ([`Spring`][spring-consts], [`SpringSimulation.kt`][spring-sim]); the duration is estimated from the parameters, not given. Duration-based motion is `tween` with an `Easing` and `keyframes`. Decay (`exponentialDecay`, `splineBasedDecay`) handles flings with no target ([source][decay]). Enter/exit and item animations default to `StiffnessMediumLow` springs ([`animateItem`][animateitem-doc], [`DefaultBoundsTransform`][ab-animate]).

### Layout animation

Compose has three layout-animation mechanisms, all of which run **in the layout phase** and none in user code:

| Mechanism                        | Phase                                                                                                     | Start geometry (previous)                                  | Target geometry                      | Source                                              |
| -------------------------------- | --------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------ | --------------------------------------------------- |
| `animateContentSize`             | **measure** of a `LayoutModifierNode`                                                                     | the node's own `Animatable` value (last reported size)     | the child's size measured this pass  | [`SizeAnimationModifierNode`][acs-node]             |
| `animateItem` (placement)        | lazy-list **measure** (`onMeasured`) computes deltas; **placement** applies them through `placeWithLayer` | the item's previous target offset, by key                  | this measure's offset                | [`startPlacementAnimationsIfNeeded`][lia-placement] |
| `animateBounds`, shared elements | **lookahead** pre-pass computes destination; **approach** measure/placement animates toward it            | the node's `currentBounds` from the previous approach pass | this frame's lookahead size/position | [`BoundsAnimationModifierNode`][ab-node]            |

All three need the previous frame's geometry, and all three keep it **themselves**, inside the node or the item animator; none reads a shared "last frame" store. Lookahead removes the classic FLIP problem of measuring the destination: the pre-pass lays out the whole scope at its final state (with exiting `AnimatedVisibility` content already reporting zero size, [source][av-lookahead]) in the same frame, so the approach pass can animate from last frame's displayed bounds toward a destination computed this frame. The approach result for a parent is the animated size, so ancestors outside the animating node see in-flight sizes; `sharedBounds`' `scaleToBounds` and `animateBounds`' `modifier` parameter exist to choose between re-measuring children at each animated size and scaling a stable layout. Draw-only animation (alpha, translation, scale via `graphicsLayer { }`) skips layout entirely ([`graphicsLayer`][graphicslayer]); the compositor is not involved beyond replaying layers.

### Enter and exit

Compose uses **two different mechanisms** for keeping removed content on screen:

- **Keep composing it** (`AnimatedVisibility`, `AnimatedContent`, `Crossfade`, shared elements). The removal is expressed as a target state; the container keeps calling the content lambda, with the old state value for `AnimatedContent`, until the exit transition reaches `PostExit`, then drops it from composition ([`AnimatedEnterExitImpl`][av-impl], [`AnimatedContentImpl`][ac-loop]). The exiting subtree stays live: it recomposes, lays out, and can participate in shared-element matching.
- **Keep drawing its last layer** (lazy `animateItem`). A removed item is not composed or measured again; its last recorded `GraphicsLayer` (a display list) is drawn by the list at its last offset, faded through the layer's `alpha`, and released when the animation finishes ([removal][lia-remove], [draw][lia-draw]).

Enter is symmetric: `EnterTransition` (`fadeIn`, `slideIn`, `expandIn`, `scaleIn`) from `PreEnter`, `MutableTransitionState(false)` with target `true` to animate on first composition, and `fadeInSpec` for new lazy items when the item was absent from the previous key map ([source][lia-onmeasured]).

### Scheduling, reduced motion and testing

Frames are requested only by suspended `withFrameNanos` callers: an idle `Animatable` has no coroutine, and `Transition`'s frame loop is composed only while `targetState != currentState || isRunning` ([source][tr-loop]). `withInfiniteAnimationFrameNanos` marks infinite animations so tests and policies can treat them separately ([`callWithFrameNanos`][suspend-scale]). Reduced motion is the system animator duration scale: Android's "Remove animations" sets it to 0, every animation in that `Recomposer` finishes on its next frame, and there is no separate reduce-motion flag in the framework ([`WindowRecomposer.android.kt`][wr-scale]). That is all-or-nothing and per window, with no notion of essential motion. Tests own a virtual frame clock (`mainClock.autoAdvance = false`) and can inject `MotionDurationScale`; Android draw is not driven by the test clock ([`MainTestClock.kt`][mtc-doc]).

### Lessons for sparkles:ui

- **Stateless specs plus `(start, from, velocity)` in the store is the right split.** Compose's `VectorizedAnimationSpec` takes start value, start velocity, target and play time and holds nothing else; that is exactly a `@safe pure nothrow @nogc` function a sparkles host can evaluate at `FrameStart.target` over store-held numbers ([baseline][baseline]).
- **The interruption policy is small and copyable.** Retarget from the current value with the current velocity; if the spec cannot take velocity (a tween), fall back to a spring, as `Transition` does ([source][tr-interrupt]). That gives continuity without additive bookkeeping.
- **For UI-Q9, lookahead answers "which geometry does a layout animation need": last frame's _displayed_ bounds as start, this frame's layout as target, both owned by the animating element.** Compose computes the target in a pre-pass and animates in the approach pass, never in user code. A sparkles host can do the same after its single layout: target = this frame's laid-out rect, start = the store's committed rect for that identity, interpolated at paint, with no component reading geometry. Only the lookahead property that _ancestors see the animated size_ needs a second layout pass; scaling a stable layout (`scaleToBounds`) does not. See UI-Q9 ([PR #775][pr775]).
- **For UI-Q10, Compose ships both answers.** `AnimatedVisibility` keeps the subtree composed (a closing state, driven by a transition the container owns); lazy lists replay the item's last display list. The first needs the old _input_ retained (`AnimatedContent` keeps old `S` values); the second needs only a retained draw range. For a sparkles store whose components cannot be re-run without their data, a retained op range from the last committed frame is the cheap default and a closing state the opt-in. See UI-Q10 ([PR #775][pr775]).
- **Phase-scoped reads are the performance model, and sparkles gets it for free.** Compose works hard (snapshot read tracking per phase) so that an animated value read in draw skips composition and layout. A host that interpolates store values at paint never re-runs components for paint-only animation at all.
- **Reduced motion as a duration scale is too coarse.** A single scale-to-zero cannot distinguish essential motion (progress, scroll) from decoration; the sparkles vocabulary can carry the distinction.

---

## Strengths

- Value- and velocity-continuous retargeting by default, including the tween-to-spring fallback in `Transition`.
- Stateless specs evaluated in closed form at play time: seekable (`SeekableTransitionState`), scalable (`MotionDurationScale`) and frame-drop-proof.
- One animation API serves composition, layout and draw; the read site picks the phase.
- Lookahead gives layout animation a correct destination in the same frame, generalised to `animateBounds` and shared elements.
- Lazy-list item animations (appear, move, disappear) with a cheap retained-layer exit.
- A fully virtual test clock with documented frame ordering.

## Weaknesses

- Many overlapping APIs (`animate*AsState`, `Animatable`, `Transition`, `AnimatedVisibility`, `AnimatedContent`, `Crossfade`, `animateContentSize`, `animateBounds`, `sharedElement`/`sharedBounds`) with different interruption and lifecycle rules.
- `animate*AsState` cannot be stopped without leaving composition ([source][aas-doc]); a tween through `Animatable` drops velocity.
- Lookahead doubles measure work for every invalidated node in scope, and approach code must agree with lookahead when settled or the snap is visible ([`ApproachLayoutModifierNode.kt`][approach-doc]).
- Exiting `AnimatedContent` content is re-run with a stale state value, which every content lambda must tolerate.
- Reduced motion is only the global animator duration scale.
- One-frame start latency: an animation kicked off by a state change gets its start time a frame later ([`MainTestClock.kt`][mtc-doc]).

---

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                              | Trade-off                                                                  |
| ------------------------------------------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Animated values are snapshot state                      | any phase can read them; only readers are invalidated                  | correctness and cost depend on where app code reads                        |
| Specs stateless, holders stateful                       | one spec reused across retargets and instances; closed-form evaluation | holders are `remember`ed objects tied to composition position              |
| Springs by default, velocity carried                    | continuous motion under rapid retargeting                              | durations are emergent, harder to coordinate                               |
| `MutatorMutex` exclusion per `Animatable`               | structured cancellation shared with gestures and scroll                | no additive animation; cancelled coroutines need `try`/`catch` for cleanup |
| Exit by keeping content composed (`AnimatedVisibility`) | exiting content stays live, laid out and shareable                     | containers must retain old state values; content recomposes while leaving  |
| Exit by retained `GraphicsLayer` (lazy lists)           | no composition or measure for removed items                            | frozen content; only layer properties (alpha, offset) can animate          |
| Lookahead pre-pass + approach pass                      | destination known in the same frame; ancestors can see animated sizes  | double measure in scope; approach/lookahead must converge exactly          |
| Shared elements drawn in a root overlay                 | escape parent clip and fade                                            | clipping and fading must be re-specified explicitly on the element         |
| Reduced motion = `MotionDurationScale` 0                | one switch, honoured by every animation automatically                  | no essential-motion distinction; per-window, not per-subtree               |

---

## Sources

- AndroidX at `296313a488a0` (Compose 1.14.0-alpha02), `compose/animation/animation-core`: [`Animatable.kt`][animatable-class], [`AnimateAsState.kt`][aas-fun], [`Transition.kt`][tr-update], [`AnimationSpec.kt`][spec-file], [`VectorizedAnimationSpec.kt`][vspec-doc], [`FloatAnimationSpec.kt`][float-spring], [`SpringSimulation.kt`][spring-sim], [`DecayAnimationSpec.kt`][decay], [`Animation.kt`][animation-doc], [`SuspendAnimation.kt`][suspend-animate].
- `compose/animation/animation`: [`AnimatedVisibility.kt`][av-impl], [`AnimatedContent.kt`][ac-list], [`Crossfade.kt`][crossfade], [`AnimationModifier.kt`][acs-node], [`AnimateBoundsModifier.kt`][ab-node], [`SharedTransitionScope.kt`][st-scope], [`SharedContentNode.kt`][st-draw], [`SplineBasedDecay.kt`][spline-decay].
- `compose/ui`: [`LookaheadScope.kt`][lookahead-doc], [`ApproachLayoutModifierNode.kt`][approach-doc], [`LayoutModifierNodeCoordinator.kt`][lmnc-measure], [`MeasureAndLayoutDelegate.kt`][mld-remeasure], [`DepthSortedSet.kt`][dss-popeach], [`MotionDurationScale.kt`][mds], [`WindowRecomposer.android.kt`][wr-scale], [`GraphicsLayerModifier.kt`][graphicslayer]; `compose/runtime`: [`MonotonicFrameClock.kt`][frameclock]; `compose/ui/ui-test`: [`MainTestClock.kt`][mtc-doc].
- `compose/foundation`: [`LazyItemScope.kt`][animateitem-doc], [`LazyLayoutItemAnimator.kt`][lia-onmeasured], [`LazyListMeasuredItem.kt`][lazy-place].
- File-header years as introduction dates: `Animatable.kt` and `SpringSimulation.kt` 2019; `Transition.kt`, `AnimatedVisibility.kt`, `AnimationModifier.kt` 2020; `AnimatedContent.kt` 2021; `LookaheadScope.kt` 2022; `ApproachLayoutModifierNode.kt`, `AnimateBoundsModifier.kt`, `SharedTransitionScope.kt`, `LazyLayoutItemAnimator.kt` 2024.
- Official docs: [Animations in Compose][d-intro], [Shared element transitions][d-shared], [Compose phases][d-phases], [Test animations][d-testing].
- In this survey: [Concepts][concepts], [Sparkles baseline][baseline], [Flutter][flutter], [SwiftUI][swiftui]; elsewhere: [Jetpack Compose Runtime][rp-compose], [Testing FRP and UI loops][rp-testing-compose], [Compose layout][layout-compose], [UI authoring decisions][ui-authoring].

<!-- References -->

[license]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/LICENSE.txt
[repo]: https://github.com/androidx/androidx
[versions]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/libraryversions.toml#L28
[src-core]: https://github.com/androidx/androidx/tree/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core
[src-anim]: https://github.com/androidx/androidx/tree/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation
[src-layout]: https://github.com/androidx/androidx/tree/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/layout
[src-lazy]: https://github.com/androidx/androidx/tree/296313a488a01c84ddcb0801d4efee640a14070c/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/lazy/layout
[d-intro]: https://developer.android.com/develop/ui/compose/animation/introduction
[d-shared]: https://developer.android.com/develop/ui/compose/animation/shared-elements
[d-phases]: https://developer.android.com/develop/ui/compose/phases
[d-testing]: https://developer.android.com/develop/ui/compose/animation/testing
[graphicslayer]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/graphics/GraphicsLayerModifier.kt#L59-L61
[vspec-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/VectorizedAnimationSpec.kt#L29-L45
[animation-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Animation.kt#L31-L34
[animatable-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Animatable.kt#L28-L48
[animatable-class]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Animatable.kt#L50-L121
[animatable-animateto]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Animatable.kt#L194-L248
[animatable-run]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Animatable.kt#L296-L336
[animatable-end]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Animatable.kt#L359-L366
[animatable-snap]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Animatable.kt#L368-L410
[aas-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/AnimateAsState.kt#L44-L55
[aas-fun]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/AnimateAsState.kt#L407-L441
[aas-update]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/AnimateAsState.kt#L466-L531
[tr-update]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Transition.kt#L67-L98
[tr-seekable]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Transition.kt#L316-L332
[tr-seekto]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Transition.kt#L613-L640
[tr-onframe]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Transition.kt#L1231-L1262
[tr-loop]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Transition.kt#L1404-L1440
[tr-interrupt]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/Transition.kt#L1650-L1700
[spec-file]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/AnimationSpec.kt
[spec-interrupt]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/AnimationSpec.kt#L132-L170
[spec-tween]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/AnimationSpec.kt#L860-L866
[spec-spring]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/AnimationSpec.kt#L876-L880
[spec-keyframes]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/AnimationSpec.kt#L882-L905
[spring-consts]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/VectorizedAnimationSpec.kt#L845-L896
[float-spring]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/FloatAnimationSpec.kt#L133-L160
[spring-sim]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/SpringSimulation.kt#L55-L92
[decay]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/DecayAnimationSpec.kt#L36-L110
[spline-decay]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/SplineBasedDecay.kt#L124
[suspend-animate]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/SuspendAnimation.kt#L220-L294
[suspend-scale]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/SuspendAnimation.kt#L295-L341
[suspend-frame]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation-core/src/commonMain/kotlin/androidx/compose/animation/core/SuspendAnimation.kt#L342-L362
[frameclock]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/MonotonicFrameClock.kt#L23-L42
[mds]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/MotionDurationScale.kt#L22-L50
[wr-scale]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/platform/WindowRecomposer.android.kt#L95-L135
[wr-impl]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/platform/WindowRecomposer.android.kt#L432-L458
[av-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimatedVisibility.kt#L60-L86
[av-lookahead]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimatedVisibility.kt#L752-L781
[av-impl]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimatedVisibility.kt#L789-L870
[ac-size]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimatedContent.kt#L229-L278
[ac-list]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimatedContent.kt#L1085-L1162
[ac-loop]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimatedContent.kt#L1264-L1312
[crossfade]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/Crossfade.kt#L93-L130
[acs-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimationModifier.kt#L48-L68
[acs-node]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimationModifier.kt#L158-L258
[ab-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimateBoundsModifier.kt#L70-L98
[ab-node]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimateBoundsModifier.kt#L218-L322
[ab-deferred]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimateBoundsModifier.kt#L394-L424
[ab-animate]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/AnimateBoundsModifier.kt#L528-L568
[st-scope]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/SharedTransitionScope.kt#L101-L153
[st-root]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/SharedTransitionScope.kt#L172-L241
[st-element]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/SharedTransitionScope.kt#L538-L562
[st-bounds]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/SharedTransitionScope.kt#L640-L716
[st-draw]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/SharedContentNode.kt#L591-L635
[lookahead-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/layout/LookaheadScope.kt#L35-L50
[approach-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/layout/ApproachLayoutModifierNode.kt#L38-L71
[lmnc-measure]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/node/LayoutModifierNodeCoordinator.kt#L147-L194
[mld-remeasure]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/node/MeasureAndLayoutDelegate.kt#L579-L625
[dss-popeach]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/node/DepthSortedSet.kt#L578-L592
[animateitem-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/lazy/LazyItemScope.kt#L87-L111
[lia-class]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/lazy/layout/LazyLayoutItemAnimator.kt#L35-L65
[lia-onmeasured]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/lazy/layout/LazyLayoutItemAnimator.kt#L67-L213
[lia-remove]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/lazy/layout/LazyLayoutItemAnimator.kt#L242-L282
[lia-placement]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/lazy/layout/LazyLayoutItemAnimator.kt#L451-L473
[lia-draw]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/lazy/layout/LazyLayoutItemAnimator.kt#L604-L620
[lazy-place]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/lazy/LazyListMeasuredItem.kt#L236-L286
[mtc-doc]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test/src/commonMain/kotlin/androidx/compose/ui/test/MainTestClock.kt#L25-L60
[pr775]: https://github.com/PetarKirov/sparkles/pull/775
[concepts]: ./concepts.md
[baseline]: ./sparkles-baseline.md
[flutter]: ./flutter.md
[swiftui]: ./swiftui.md
[rp-compose]: ../reactive-programming/jetpack-compose.md
[rp-compose-time]: ../reactive-programming/jetpack-compose.md#time-and-scheduling
[rp-compose-test]: ../reactive-programming/jetpack-compose.md#testing
[rp-testing-compose]: ../reactive-programming/testing-frp-and-snapshots.md#jetpack-compose-maintestclock-and-semantics-assertions
[layout-compose]: ../ui-layout/jetpack-compose.md
[ui-authoring]: ../ui-authoring/index.md
