# SwiftUI animation (Swift)

Apple's declarative UI framework animates by splitting every animatable attribute into a model value, which `body` sets once per state change, and a presentation value, which an `Animation` copied out of the update's `Transaction` interpolates over a delta vector on a framework-owned clock. Springs merge with a running animation and keep its velocity, timing curves add to it, and a removed view keeps rendering through its `Transition` until the framework drops it.

| Field                    | Value                                                                                                                                                                                                                                                                                               |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | Swift                                                                                                                                                                                                                                                                                               |
| License                  | Proprietary (Apple SDK); closed source                                                                                                                                                                                                                                                              |
| Repository               | None public; the framework ships in the Apple platform SDKs                                                                                                                                                                                                                                         |
| Documentation            | [SwiftUI reference][doc-swiftui] · WWDC23 [Explore SwiftUI animation][wwdc23-10156], [Animate with springs][wwdc23-10158], [Wind your way through advanced animations][wwdc23-10157] · WWDC21 [Demystify SwiftUI][wwdc21-10022] · WWDC24 [Enhance your UI animations and transitions][wwdc24-10145] |
| Category                 | declarative, transaction-scoped implicit animation over a retained attribute graph; per-attribute model/presentation split                                                                                                                                                                          |
| Versions surveyed        | Apple's SwiftUI documentation as served on 2026-11-26 (the 26.0 SDK generation: [`AnimatableValues`][doc-animatablevalues] is marked iOS 26.0); the animation APIs date from iOS 13 (2019), iOS 14, iOS 15 and iOS 17 (2023), as each section notes                                                 |
| Animation state lives in | the framework's attribute graph, one presentation value and running-animation list per animatable attribute, keyed by view identity; invisible to app code                                                                                                                                          |

> [!NOTE]
> SwiftUI has no public source, so every mechanism here is cited to Apple's reference documentation or a WWDC session transcript, quoted verbatim. Layout itself (propose-and-respond, `Layout`) is covered in [SwiftUI layout][layout-swiftui]; the system underneath that SwiftUI bridges to on UIKit/AppKit is [Core Animation][ca]. Terms such as _model value_, _presentation value_ and _retargeting_ are defined in [Concepts][concepts].

---

## Overview

### What it solves

SwiftUI wants a change of state to animate without the author naming a start value, an animation object, or the views affected. The author changes state inside `withAnimation`, or marks a subtree with `.animation(_:value:)`; the framework works out which rendered attributes changed and animates each one from where it is on screen to where the new `body` puts it. The `Animation` overview describes the contract ([`Animation`][doc-animation]):

> _"An `Animation` provides a visual transition of a view when a state value changes from one value to another."_

and `Animatable` describes the mechanism ([`Animatable`][doc-animatable]):

> _"When an animatable value changes inside a `withAnimation(_:_:)` block (or is affected by an `animation(_:value:)` modifier), SwiftUI reads the old and new `animatableData` values, then interpolates between them over successive frames using `VectorArithmetic` operations."_

### Design philosophy

1. **What animates and how it animates are orthogonal.** _"Animatable attributes, like scaleEffect, determine the data being animated, while the Animation determines how that data changes over time"_ ([WWDC23 10156][wwdc23-10156]).
2. **Every animatable attribute has two values.** _"animatable attributes conceptually have both model and presentation values"_; on a change with an animation _"the attribute makes a local copy of the animation to calculate the current presentation value"_ ([WWDC23 10156][wwdc23-10156]).
3. **Context flows with the update, then evaporates.** `Transaction` is _"a dictionary SwiftUI uses to implicitly propagate all the context for the current update, most notably the animation"_, and it _"is unique among SwiftUI's implicit data-flow constructs because it's discarded at the end of every update"_ ([WWDC23 10156][wwdc23-10156]).
4. **Springs by default, because they keep velocity.** _"We highly recommend using spring animations because they give your UI an organic feel by preserving velocity and naturally coming to rest. In fact, we feel so strongly about the benefits of spring animations that we made a smooth spring the new default when you use a bare withAnimation in iOS 17 and aligned releases"_ ([WWDC23 10156][wwdc23-10156]).
5. **Identity decides what is "the same view" across a change.** _"connecting views across different states is important, because that's how SwiftUI understands how to transition between them"_ ([WWDC21 10022][wwdc21-10022]); a different identity is an insertion and a removal, which transitions animate.

---

## How it works

### An animated update, step by step

[WWDC23 10156][wwdc23-10156] traces one update through the attribute graph, the long-lived dependency graph whose nodes ("attributes") _"map to a fine-grained piece of the UI"_:

1. An event opens an update transaction. `withAnimation` _"sets the given `Animation` as the `animation` property of the thread's current `Transaction`"_ ([`withAnimation(_:_:)`][doc-withanimation]).
2. State changes; dependent attributes are invalidated; `body` runs once and produces new attribute values; the view value is then discarded.
3. The transaction propagates across the graph. _"When it reaches an animatable attribute, the attribute checks if an animation is set. And if so, it makes a copy to drive its presentation value."_
4. Each frame after that, _"SwiftUI knows when the attribute graph contains running animations and will call into the appropriate animatable attributes to produce the next frame. For built-in animatable attributes like scaleEffect, SwiftUI is very efficient. It's able to do this work off the main thread and without calling into any of your view code."_

The model value is the one step 2 wrote; app code never sees the presentation value.

### Declaring: `withAnimation`, `.animation(_:value:)`, scoped modifiers

```swift
// explicit: the animation rides the transaction of this state change
Button("+") { withAnimation(.bouncy) { scale += 0.1 } }

// implicit: animate this subtree whenever `selected` changes
Image(pet.type)
    .scaleEffect(selected ? 1.5 : 1.0)
    .animation(.bouncy, value: selected)

// iOS 17: scope the animation to the modifiers inside the closure only
content.animation(.smooth) { $0.shadow(radius: selected ? 12 : 8) }
```

- [`animation(_:value:)`][doc-animation-value] (iOS 13) _"Applies the given animation to this view when the specified value changes"_; it _"will only write the animation into the transaction if the value has changed"_ ([WWDC23 10156][wwdc23-10156]). The value-less [`animation(_:)`][doc-animation-deprecated] is deprecated since iOS 15 (_"Use withAnimation or animation(_:value:) instead."_).
- [`animation(_:body:)`][doc-animation-body] (iOS 17) _"Applies the given animation to all animatable values within the `body` closure"_. The transaction is copied, _"propagated downstream, but only to the scoped animatable attributes. Once it's done its job, the copy is discarded"_, so arbitrary child content is not accidentally animated ([WWDC23 10156][wwdc23-10156]).
- A `Binding` can carry an animation too: `$isTrailing.animation(.linear)` ([`Animation`][doc-animation]).

### `Transaction` and `withTransaction`

[`Transaction`][doc-transaction] is _"The context of the current state-processing update"_; _"The root transaction for a state change comes from the binding that changed, plus any global values set by calling `withTransaction(_:_:)` or `withAnimation(_:_:)`."_ _"withAnimation is just a thin wrapper around withTransaction"_ ([WWDC23 10156][wwdc23-10156]). Its fields include:

| Field                                          | Meaning (verbatim from the reference)                                                                                                                                                                                       |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `animation`                                    | the `Animation` an animatable attribute copies                                                                                                                                                                              |
| [`disablesAnimations`][doc-disablesanimations] | _"`true` during the initial phase of a two-part transition update, to prevent `animation(_:)` from inserting new animations into the transaction"_                                                                          |
| [`isContinuous`][doc-iscontinuous]             | _"whether the transaction originated from an action that produces a sequence of values"_ (a slider drag, a held stepper)                                                                                                    |
| [`tracksVelocity`][doc-tracksvelocity]         | (iOS 17) track velocity during an interaction _"so that when the interaction ends, an animation can use the accumulated velocities"_; _"Gesture onChanged and updating callbacks automatically set this property to true."_ |
| custom `TransactionKey`s                       | (iOS 17) app-defined, per-update data; every value _"reverts to just being the default value for its key"_ after the update ([WWDC23 10156][wwdc23-10156])                                                                  |

The [`transaction(_:)`][doc-transaction-mod] modifier rewrites the transaction for a subtree on every update, which the reference warns about: _"calling `transaction(_:)` on a container view can lead to unbounded scope of execution"_. iOS 17 adds the scoped [`transaction(value:_:)`][doc-transaction-value] and a `body:` variant, mirroring the animation modifiers.

### `Animatable`, `animatableData` and `VectorArithmetic`

A type conforms to [`Animatable`][doc-animatable] by exposing `animatableData`, a read-write [`VectorArithmetic`][doc-vectorarithmetic] value (_"`AdditiveArithmetic` with scalar multiplication and a way to query the vector magnitude"_). `CGFloat` is one-dimensional, `CGPoint` two, `CGRect` four; [`AnimatablePair`][doc-animatablepair] (_"A pair of animatable values, which is itself animatable"_) fuses vectors, and `scaleEffect`'s data is _"a CGSize for the width and height scale, paired with a UnitPoint for the relative anchor"_ ([WWDC23 10156][wwdc23-10156]). The 26.0 SDK adds variadic [`AnimatableValues`][doc-animatablevalues] and an `@Animatable` macro that synthesises the property.

Conforming a whole view to `Animatable` makes `body` the animated attribute: _"for every frame of the animation, body is going to be called by SwiftUI with a new offset angle, and the layout will be rerun"_. The session's example animates avatars along an arc rather than the straight line that interpolating each laid-out `CGPoint` would give, at a cost: _"a custom Animatable conformance can be much more expensive to animate than a built-in effect because it'll run body for every frame of the animation"_ ([WWDC23 10156][wwdc23-10156]).

### `CustomAnimation`: the low-level protocol

Since iOS 17 every built-in animation is expressible through [`CustomAnimation`][doc-customanimation] (_"the same low-level generic entry points we use to implement all the animations that come built into SwiftUI"_, [WWDC23 10156][wwdc23-10156]):

```swift
struct MyLinearAnimation: CustomAnimation {
    var duration: TimeInterval
    func animate<V: VectorArithmetic>(value: V, time: TimeInterval,
                                      context: inout AnimationContext<V>) -> V? {
        if time <= duration { value.scaled(by: time / duration) } else { nil }
    }
    func velocity<V: VectorArithmetic>(value: V, time: TimeInterval,
                                       context: AnimationContext<V>) -> V? {
        value.scaled(by: 1.0 / duration)
    }
}
```

- [`animate(value:time:context:)`][doc-ca-animate] returns _"The current value of the animation, or `nil` if the animation has finished"_. `value` is the **delta**: _"the animation running in the scaleEffect animatable attribute isn't interpolating from 1 to 1.5, but from 0 to 0.5"_ ([WWDC23 10156][wwdc23-10156]). `time` is elapsed time since the animation began.
- [`AnimationContext`][doc-animationcontext] carries per-animation `state` (typed by `AnimationStateKey`) and the creating view's `environment`; the reference's `PausableAnimation` example pauses by remapping `time` from an environment flag.
- [`shouldMerge(previous:value:time:context:)`][doc-ca-shouldmerge] and [`velocity(value:time:context:)`][doc-ca-velocity] govern interruption ([below](#interruption-and-retargeting)).

### Springs, curves and the `Spring` model

`Animation`'s presets are grouped as timing curves (`linear`, `easeIn`, `easeOut`, `easeInOut`, [`timingCurve(_:_:_:_:duration:)`][doc-timingcurve] from cubic Bézier control points), springs (`spring(duration:bounce:blendDuration:)`, `spring(response:dampingFraction:blendDuration:)`, `interpolatingSpring(…)`, `interactiveSpring`, and the iOS 17 presets [`smooth`][doc-smooth], [`snappy`][doc-snappy], [`bouncy`][doc-bouncy]) and higher-order modifiers (`delay(_:)`, `speed(_:)`, `repeatCount(_:autoreverses:)`, `repeatForever(autoreverses:)`). [`Animation.default`][doc-default] is _"`spring(response:dampingFraction:blendDuration:)` with … `response` equal to `0.55` … `dampingFraction` equal to `1.0`"_, and _"Prior to iOS 17, macOS 14, tvOS 17, and watchOS 10, the `default` animation is `easeInOut`."_

[`Spring`][doc-spring] (iOS 17) is the standalone model: it converts parametrisations (`Spring(duration: 0.5, bounce: 0.3)` gives mass 1.0, stiffness 157.9, damping 17.6) and evaluates `value(target:initialVelocity:time:)`, `velocity(…)`, `settlingDuration(…)` and a stepped `update(value:velocity:target:deltaTime:)`. [UnitCurve][wwdc23-10156] is the matching model for timing curves.

### Multi-step animation: `PhaseAnimator`, `KeyframeAnimator`, `TimelineView`

- [`PhaseAnimator`][doc-phaseanimator] (iOS 17) _"animates its content by automatically cycling through a collection of phases"_; with a `trigger`, each change of the trigger value runs through the phases once ([`phaseAnimator(_:trigger:content:animation:)`][doc-phaseanimator-trigger]). Each phase transition is an ordinary `Animation`, chosen per phase.
- [`KeyframeAnimator`][doc-keyframeanimator] (iOS 17) drives a value type through `KeyframeTrack`s of `LinearKeyframe`, `SpringKeyframe`, `CubicKeyframe` (a sequence _"is equivalent to a Catmull-Rom spline"_) and `MoveKeyframe`; _"SwiftUI maintains velocity between keyframes"_ ([WWDC23 10157][wwdc23-10157]). Its `content` closure _"updates every frame while animating"_. [`KeyframeTimeline`][doc-keyframetimeline] is the same curve as a pure value: _"you can scrub and evaluate them for any time within the duration"_ via [`value(time:)`][doc-keyframetimeline-value].
- [`TimelineView`][doc-timelineview] (iOS 15) _"redraws the content it contains at scheduled points in time"_, passing a `Context` with the `date`. The [`.animation`][doc-timeline-animation] schedule is _"A pausable schedule of dates updating at a frequency no more quickly than the provided interval"_ — a per-frame clock for code that computes its own motion.

### Transitions

A view inserted or removed under an animated transaction runs its transition. The iOS 17 [`Transition`][doc-transition] protocol is a function of a [`TransitionPhase`][doc-transitionphase]:

```swift
struct RotatingFadeTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1.0 : 0.0)
            .rotationEffect(phase == .willAppear ? .degrees(30)
                          : phase == .didDisappear ? .degrees(-30) : .zero)
    }
}
```

Built-ins include `.opacity`, `.scale`, `.slide`, `.move(edge:)`, `.offset`, `.push(from:)`, `.blurReplace`; the older type-erased [`AnyTransition`][doc-anytransition] adds [`asymmetric(insertion:removal:)`][doc-asymmetric] and `modifier(active:identity:)`. [`contentTransition(_:)`][doc-contenttransition] (iOS 16) animates a change _within_ one view (`.interpolate` morphs text paths; `.opacity` cross-fades).

### `matchedGeometryEffect` and `geometryGroup`

[`matchedGeometryEffect(id:in:properties:anchor:isSource:)`][doc-matchedgeometry] (iOS 14) _"Defines a group of views with synchronized geometry using an identifier and namespace that you provide"_. The [`Namespace`][doc-namespace] is _"defined by the persistent identity of the object containing the property"_. The non-source views take the source's geometry, and:

> _"If inserting a view in the same transaction that another view with the same key is removed, the system will interpolate their frame rectangles in window space to make it appear that there is a single view moving from its old position to its new position. The usual transition mechanisms define how each of the two views is rendered during the transition (e.g. fade in/out, scale, etc), the `matchedGeometryEffect()` modifier only arranges for the geometry of the views to be linked, not their rendering."_

[`geometryGroup()`][doc-geometrygroup] (iOS 17) exposes how frame animation is applied by default: _"SwiftUI views push position and size changes down through the view hierarchy, so that only views that draw something (known as leaf views) apply the current animation to their frame rectangle"_; a group _"forces the position and size values to be resolved and animated by the parent, before being passed down to each subview"_.

### Completion

[`withAnimation(_:completionCriteria:_:completion:)`][doc-withanimation-completion] (iOS 17): _"The completion callback will always be fired exactly one time. If no animations are created by the changes in `body`, then the callback will be called immediately after `body`."_ [`AnimationCompletionCriteria`][doc-completioncriteria] has two values: [`logicallyComplete`][doc-logicallycomplete] (_"The animation has logically completed, but may still be in its long tail"_; later animations on the same property are ignored) and [`removed`][doc-removed] (_"The entire animation is finished and will now be removed"_; fires only when all created animations are complete). A spring's logical completion uses _"a perceptual duration instead of a settling duration"_ ([WWDC23 10158][wwdc23-10158]); [`logicallyComplete(after:)`][doc-logicallycomplete-after] overrides it.

---

## Analysis

### Where animation state lives

In the framework, never in app state. Each animatable attribute of the attribute graph holds its model value (what `body` produced), its presentation value, and the copied `Animation`s driving it, plus each animation's `AnimationContext.state` ([WWDC23 10156][wwdc23-10156]; [`AnimationContext`][doc-animationcontext]). Attributes are owned by view identity — structural or explicit (`.id`, `ForEach` data) — and live as long as the identity does ([WWDC21 10022][wwdc21-10022]). App code has no read path to a presentation value; the closest are `KeyframeAnimator`/`PhaseAnimator` content closures, which receive the interpolated _input_ value every frame, and `TimelineView`, which hands out a date. This is the [model/presentation split][concepts-model-presentation] with the presentation half sealed.

### Declaring an animation

Declarative and implicit at the point of use: the author declares a new target (by changing state) and names an `Animation`, either for one state change (`withAnimation`, explicit in the transaction) or for a subtree whenever a value changes (`.animation(_:value:)`, implicit — a value change animates). Neither names a start value, an object, or a property; the transaction finds every animatable attribute the change reached. Imperative controllers do not exist: there is no handle to pause, scrub or reverse an in-flight animation. The only "controller" shapes are a `CustomAnimation` that reads `context.environment` (the reference's `PausableAnimation`) and `KeyframeTimeline.value(time:)` evaluated against a clock the app supplies.

### Time and the clock

The framework owns the clock. `CustomAnimation.animate` receives `time`, _"the amount of time that has elapsed since the animation began"_ ([WWDC23 10156][wwdc23-10156]), so an animation is a pure function of (delta, elapsed time, context). Higher-order animations remap that time (`delay`, `speed`, `repeatCount`). The per-frame tick is internal — SwiftUI _"knows when the attribute graph contains running animations"_ and produces the next frame, off the main thread for built-in effects. App-visible time exists only as `TimelineView`'s `context.date` (wall-clock `Date` values on a schedule, with a `cadence` the system may lower, e.g. on a lowered watch wrist) and keyframe-time evaluation. There is no document or view timeline driving `Animation`s; the scroll-position analogue is [`scrollTransition(_:axis:transition:)`][doc-scrolltransition] (iOS 17), which _"Applies the given transition, animating between the phases of the transition as this view appears and disappears within the visible region of the containing scroll view"_.

### Interruption and retargeting

SwiftUI's answer is per-animation and explicit in the protocol. When a new animation lands on an attribute that is already animating, the system calls `shouldMerge` on the new one ([`shouldMerge`][doc-ca-shouldmerge]):

> _"If `shouldMerge(previous:value:time:context:)` returns `true`, the system merges the new animation instance with the previous animation. The system provides to the new instance the state and elapsed time from the previous one. Then it removes the previous animation. If this method returns `false`, the system doesn't merge the animation with the previous one. Instead, both animations run together and the system combines their results."_

- **Timing curves do not merge** (the default `false`): the old and new delta animations run concurrently and their results add — [additive composition][concepts-composite], which is _"another reason why SwiftUI animations deal in terms of delta vectors"_ ([WWDC23 10156][wwdc23-10156]). Position stays continuous; velocity is the sum of two curves.
- **Springs merge and keep velocity.** [`spring(duration:bounce:blendDuration:)`][doc-spring-anim] is _"A persistent spring animation. When mixed with other `spring()` or `interactiveSpring()` animations on the same property, each animation will be replaced by their successor, preserving velocity from one animation to the next."_ [`velocity(value:time:context:)`][doc-ca-velocity] is the hook: _"Should subsequent animations merge with the animation, the system preserves continuity of the velocity between animations."_ _"a spring animation uses the velocity it had when it was retargeted as the initial velocity towards its new destination"_ ([WWDC23 10158][wwdc23-10158]).
- **`interpolatingSpring` is additive**: it _"Preserves velocity across overlapping animations by adding the effects of each animation"_ ([`interpolatingSpring(duration:bounce:initialVelocity:)`][doc-interpolatingspring]).
- **Gestures hand velocity to animations** without the author computing it: every drag event's `.interactiveSpring` retargets the last, and _"when the gesture ends, a final non-interactive spring animation is created. This spring uses the velocity from the interactiveSprings"_ ([WWDC24 10145][wwdc24-10145]); without an animation, `Transaction.tracksVelocity` accumulates it.
- **Keyframes do not retarget**: _"keyframe animations can't gracefully retarget the way that springs can, so it's generally best to avoid changing keyframes mid-animation"_ ([WWDC23 10157][wwdc23-10157]).

### Curves and springs

Both, unified by `CustomAnimation`. Timing curves are cubic Béziers plus a duration. Springs are parametrised perceptually: _"You just specify the perceived duration of the animation and how bouncy you want the spring to be"_ ([WWDC23 10156][wwdc23-10156]); `bounce` is 0 for critically damped, negative for over-damped, up to 1 (_"exactly the behavior of a cosine wave"_). The conversion is published ([WWDC23 10158][wwdc23-10158]):

```text
mass = 1
stiffness = (2π ÷ duration)^2
damping = 1 - 4π × bounce ÷ duration, bounce ≥ 0
          4π ÷ (duration + 4π × bounce), bounce < 0
```

The older `response`/`dampingFraction` form (from [Designing Fluid Interfaces][wwdc18-803], _"damping ratio and frequency response"_) and `mass`/`stiffness`/`damping` remain. `duration` is a perceptual constant, distinct from the spring's _settling duration_, which _"depends on many different factors, so can be a bit unpredictable"_ ([WWDC23 10158][wwdc23-10158]). The `Spring` type evaluates closed-form `value`/`velocity` at a time and also offers a stepped `update(value:velocity:target:deltaTime:)`.

### Layout animation

Layout runs **once**, at the new state; geometry is then animated **after layout, inside the framework's render pass**, as ordinary animatable attributes:

- **Mechanism.** A view's position and size are animatable attributes. When an animated transaction changes them, the attribute holds the old value as its presentation value and interpolates to the new one; by default only leaf views apply it to their frame ([`geometryGroup()`][doc-geometrygroup]). The interpolation is cartesian: in the session's radial example the laid-out `CGPoint`s move _"along a straight line"_ ([WWDC23 10156][wwdc23-10156]).
- **Previous geometry.** Required, and kept by the framework: the from-value is the attribute's last presentation value (so an interrupted move starts where the view is on screen). `matchedGeometryEffect` needs more — the removed view's last window-space frame, which it interpolates to the inserted view's ([`matchedGeometryEffect`][doc-matchedgeometry]).
- **Phase.** For built-in geometry, _"off the main thread and without calling into any of your view code"_ — after layout, before rendering, never in user code or layout. A custom `Animatable` view moves the animation **into user code and layout**: `body` and the layout are re-run every frame with the interpolated `animatableData` ([WWDC23 10156][wwdc23-10156]). That is the escape hatch for non-cartesian layout motion, priced per frame.
- iOS 18's `navigationTransition(.zoom(sourceID:in:))` with [`matchedTransitionSource(id:in:)`][doc-matchedtransitionsource] applies the same identity-matched idea to navigation pushes.

### Enter and exit

A removed view **keeps rendering under framework ownership** until its removal transition finishes. [`TransitionPhase`][doc-transitionphase] is the contract:

> _"When a view is appearing with a transition, the transition will first be shown with the `willAppear` phase, then will be immediately moved to the `identity` phase. When a view is being removed, its transition is changed from the `identity` phase to the `didDisappear` phase. If a view is removed while it is still transitioning in, then its phase will change to `didDisappear`. If a view is re-added while it is transitioning out, its phase will change back to `identity`."_

So a transition is just a pair of modifier states animated by the transaction's `Animation`: _"If no animatable change is applied, then the transition will be a no-op."_ An insertion is the two-part update `disablesAnimations` refers to (render at `willAppear` without animation, then animate to `identity`). The disappearing view's lifetime has ended from the app's point of view — _"Once the identity of the view changes or the view is removed, its lifetime ends"_ ([WWDC21 10022][wwdc21-10022]) — yet its attributes stay in the graph, driven to `didDisappear`, and **re-insertion under the same identity revives it mid-flight**, reversing the transition rather than starting a new view. The `Transition` docs forbid identity changes inside a transition (_"Transitions should not use any identity-affecting changes like `.id`, `if`, and `switch` on the `content`"_), because the identity is what the framework is tracking. Completion is observable only through `withAnimation(…, completion:)` with `.removed` criteria; there is no per-view "did finish disappearing" callback.

### Scheduling, reduced motion and testing

- **Frames only while animating.** The graph knows whether it has running animations and asks for frames only then; an animation ends when `animate` returns `nil` (or, for springs, after the settling duration). `TimelineView(.animation)` is the explicit per-frame opt-in, `paused:` turns it off.
- **Reduced motion is the app's job.** [`accessibilityReduceMotion`][doc-reducemotion] is an environment value: _"If this property's value is true, UI should avoid large animations, especially those that simulate the third dimension."_ SwiftUI does not rewrite app animations when it is set; the Human Interface Guidelines ask apps to _"Make motion optional"_ ([HIG: Motion][hig-motion]). An app swaps its `Animation` (or a `Transition`, e.g. `.opacity` for `.move`) on the flag.
- **Testing.** No public virtual clock drives `withAnimation`. What is testable is the math: `Spring.value(target:time:)`, `UnitCurve.value(at:)`, `KeyframeTimeline.value(time:)` and a `CustomAnimation.animate` are pure functions of time, and `Transaction.disablesAnimations` (or a `transaction(value:)` that clears `animation`) collapses a change to its end state.

### Lessons for sparkles:ui

- **The element store is SwiftUI's attribute graph with the seal removed.** SwiftUI already keys presentation state by identity and lets the framework, not `body`, advance it. A store that components may _read_ (last frame's committed presentation values) is strictly more capable than SwiftUI's write-only model, and maps directly onto `animatableData`: store one vector per animated property per identity.
- **Delta vectors and `shouldMerge` are a compact retargeting design.** Storing each running animation as "delta to target + elapsed + per-animation state" makes both policies one line: concurrent deltas add (timing curves), or the newcomer inherits state and velocity (springs). Both are `@nogc` value data; neither needs a callback into the component.
- **For UI-Q9, geometry animation needs only last frame's committed rect, and it can run after layout.** SwiftUI lays out once at the target and interpolates frames in the render pass; the component never sees in-flight geometry. A component that must _decide what to build_ from geometry (the radial-path case) is the exception SwiftUI prices as "run `body` and layout every frame". Sparkles can mirror that split: host-side interpolation by default, a per-frame rebuild only when the component asks for animated input values. See UI-Q9 ([PR #775][pr775]).
- **For UI-Q10, SwiftUI's answer is a store-driven closing state, not a snapshot.** The removed view's attributes stay live, are driven to `didDisappear`, and revive to `identity` if re-added with the same identity. A sparkles store entry marked "closing", painted from its last committed subtree with transition modifiers interpolated by the host, and swept by `ElementStore.retain` only when its animation reports `removed`, reproduces this — and the re-add case falls out of identity reuse ([baseline][baseline]).
- **Transaction-scoped animation is a fit for pure components.** An animation attached to "this frame's change" rather than to a component is plain data passed down the build and discarded after it, which a `@safe pure` build can carry as a parameter. The accidental-animation problem SwiftUI documents (an unscoped `.transaction` leaking into child content) argues for the scoped form by default.
- **Reduced motion should be in the vocabulary, not left to every app.** SwiftUI exposes the flag and does nothing with it; a host that can substitute (spring → instant, move → fade) at the animation layer gives the preference teeth.

---

## Strengths

- One generic mechanism (`VectorArithmetic` delta + `CustomAnimation`) animates every property of every dimension, built-in or custom.
- Implicit animation needs no start value, no handle and no target property: change state, name an animation.
- Velocity preservation on retarget is built into springs and gesture hand-off, with a published parametrisation (`duration`, `bounce`) and its conversion.
- Built-in effects animate off the main thread without re-running app code.
- Transitions are identity-tracked: an exiting view re-added mid-flight reverses instead of duplicating.
- `Spring`, `UnitCurve` and `KeyframeTimeline` are usable as pure models outside views.

## Weaknesses

- Presentation values are invisible to app code; there is no way to read "where is this view now".
- No imperative controller: an in-flight animation cannot be paused, scrubbed, reversed or cancelled by handle.
- Transaction propagation makes it easy to animate things accidentally; the scoped APIs arrived only in iOS 17.
- Non-cartesian geometry animation (paths, custom layout) costs a `body` and layout per frame.
- No virtual clock for tests; reduced motion is left to each app.
- Closed source: behaviour beyond the reference and WWDC sessions (exact frame scheduling, removal timing) is not inspectable.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                         | Trade-off                                                                           |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Model/presentation split per animatable attribute           | `body` stays a function of state; motion is framework business                    | App code cannot read in-flight values or hit-test against them                      |
| Animation carried in a per-update `Transaction`             | One state change animates every affected attribute without naming them            | Unscoped transactions cause accidental animation; needed scoped modifiers (iOS 17)  |
| Animate the delta vector, not from→to                       | Concurrent animations add trivially; `animate` is simpler to write                | Additive timing curves can overshoot the visual expectations of "replace"           |
| `shouldMerge` + `velocity` as the retarget protocol         | Each animation type chooses replace-with-velocity (springs) or add (curves)       | Custom animations must implement both to retarget well; default is additive         |
| Springs as the default (iOS 17), `duration` + `bounce`      | Continuous velocity at start, on retarget and from gestures; intuitive parameters | Settling duration is unpredictable; completion needs a separate "logical" criterion |
| Layout once, interpolate frames after layout                | Cheap, off-main-thread animation of built-in geometry                             | Interpolation is cartesian; anything else re-runs `body` and layout every frame     |
| Removed views kept alive by identity through a `Transition` | Exit animations need no app bookkeeping; re-add reverses                          | The disappearing view is unaddressable; no per-view completion callback             |
| Keyframes as pre-planned clips                              | Full timing control, scrubbable via `KeyframeTimeline`                            | Cannot retarget gracefully                                                          |

---

## Sources

- Apple, SwiftUI reference: [`withAnimation(_:_:)`][doc-withanimation], [`withAnimation(_:completionCriteria:_:completion:)`][doc-withanimation-completion], [`animation(_:value:)`][doc-animation-value], [`animation(_:body:)`][doc-animation-body], [`Animation`][doc-animation], [`Animation.default`][doc-default], [`Transaction`][doc-transaction], [`transaction(_:)`][doc-transaction-mod], [`transaction(value:_:)`][doc-transaction-value], [`Animatable`][doc-animatable], [`VectorArithmetic`][doc-vectorarithmetic], [`CustomAnimation`][doc-customanimation], [`AnimationContext`][doc-animationcontext], [`Spring`][doc-spring], [`PhaseAnimator`][doc-phaseanimator], [`KeyframeAnimator`][doc-keyframeanimator], [`KeyframeTimeline`][doc-keyframetimeline], [`TimelineView`][doc-timelineview], [`Transition`][doc-transition], [`TransitionPhase`][doc-transitionphase], [`matchedGeometryEffect`][doc-matchedgeometry], [`geometryGroup()`][doc-geometrygroup], [`AnimationCompletionCriteria`][doc-completioncriteria], [`accessibilityReduceMotion`][doc-reducemotion] — all read 2026-11-26.
- WWDC sessions (transcripts): [WWDC23 10156 Explore SwiftUI animation][wwdc23-10156]; [WWDC23 10158 Animate with springs][wwdc23-10158]; [WWDC23 10157 Wind your way through advanced animations in SwiftUI][wwdc23-10157]; [WWDC21 10022 Demystify SwiftUI][wwdc21-10022]; [WWDC20 10041 What's new in SwiftUI][wwdc20-10041] (`matchedGeometryEffect`); [WWDC24 10145 Enhance your UI animations and transitions][wwdc24-10145]; [WWDC18 803 Designing Fluid Interfaces][wwdc18-803].
- Apple, [Human Interface Guidelines: Motion][hig-motion].
- In this survey: [Concepts][concepts], [Sparkles baseline][baseline], [Core Animation][ca]; [SwiftUI layout][layout-swiftui]; [UI authoring decisions][ui-authoring].

<!-- References -->

[doc-swiftui]: https://developer.apple.com/documentation/swiftui
[doc-withanimation]: https://developer.apple.com/documentation/swiftui/withanimation(_:_:)
[doc-withanimation-completion]: https://developer.apple.com/documentation/swiftui/withanimation(_:completioncriteria:_:completion:)
[doc-animation-value]: https://developer.apple.com/documentation/swiftui/view/animation(_:value:)
[doc-animation-body]: https://developer.apple.com/documentation/swiftui/view/animation(_:body:)
[doc-animation-deprecated]: https://developer.apple.com/documentation/swiftui/view/animation(_:)-1hc0p
[doc-animation]: https://developer.apple.com/documentation/swiftui/animation
[doc-default]: https://developer.apple.com/documentation/swiftui/animation/default
[doc-smooth]: https://developer.apple.com/documentation/swiftui/animation/smooth
[doc-snappy]: https://developer.apple.com/documentation/swiftui/animation/snappy
[doc-bouncy]: https://developer.apple.com/documentation/swiftui/animation/bouncy
[doc-spring-anim]: https://developer.apple.com/documentation/swiftui/animation/spring(duration:bounce:blendduration:)
[doc-interpolatingspring]: https://developer.apple.com/documentation/swiftui/animation/interpolatingspring(duration:bounce:initialvelocity:)
[doc-timingcurve]: https://developer.apple.com/documentation/swiftui/animation/timingcurve(_:_:_:_:duration:)
[doc-transaction]: https://developer.apple.com/documentation/swiftui/transaction
[doc-disablesanimations]: https://developer.apple.com/documentation/swiftui/transaction/disablesanimations
[doc-iscontinuous]: https://developer.apple.com/documentation/swiftui/transaction/iscontinuous
[doc-tracksvelocity]: https://developer.apple.com/documentation/swiftui/transaction/tracksvelocity
[doc-transaction-mod]: https://developer.apple.com/documentation/swiftui/view/transaction(_:)
[doc-transaction-value]: https://developer.apple.com/documentation/swiftui/view/transaction(value:_:)
[doc-animatable]: https://developer.apple.com/documentation/swiftui/animatable
[doc-animatablepair]: https://developer.apple.com/documentation/swiftui/animatablepair
[doc-animatablevalues]: https://developer.apple.com/documentation/swiftui/animatablevalues
[doc-vectorarithmetic]: https://developer.apple.com/documentation/swiftui/vectorarithmetic
[doc-customanimation]: https://developer.apple.com/documentation/swiftui/customanimation
[doc-ca-animate]: https://developer.apple.com/documentation/swiftui/customanimation/animate(value:time:context:)
[doc-ca-shouldmerge]: https://developer.apple.com/documentation/swiftui/customanimation/shouldmerge(previous:value:time:context:)
[doc-ca-velocity]: https://developer.apple.com/documentation/swiftui/customanimation/velocity(value:time:context:)
[doc-animationcontext]: https://developer.apple.com/documentation/swiftui/animationcontext
[doc-spring]: https://developer.apple.com/documentation/swiftui/spring
[doc-phaseanimator]: https://developer.apple.com/documentation/swiftui/phaseanimator
[doc-phaseanimator-trigger]: https://developer.apple.com/documentation/swiftui/view/phaseanimator(_:trigger:content:animation:)
[doc-keyframeanimator]: https://developer.apple.com/documentation/swiftui/keyframeanimator
[doc-keyframetimeline]: https://developer.apple.com/documentation/swiftui/keyframetimeline
[doc-keyframetimeline-value]: https://developer.apple.com/documentation/swiftui/keyframetimeline/value(time:)
[doc-timelineview]: https://developer.apple.com/documentation/swiftui/timelineview
[doc-timeline-animation]: https://developer.apple.com/documentation/swiftui/timelineschedule/animation
[doc-transition]: https://developer.apple.com/documentation/swiftui/transition
[doc-transitionphase]: https://developer.apple.com/documentation/swiftui/transitionphase
[doc-anytransition]: https://developer.apple.com/documentation/swiftui/anytransition
[doc-asymmetric]: https://developer.apple.com/documentation/swiftui/anytransition/asymmetric(insertion:removal:)
[doc-contenttransition]: https://developer.apple.com/documentation/swiftui/view/contenttransition(_:)
[doc-matchedgeometry]: https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:)
[doc-namespace]: https://developer.apple.com/documentation/swiftui/namespace
[doc-geometrygroup]: https://developer.apple.com/documentation/swiftui/view/geometrygroup()
[doc-matchedtransitionsource]: https://developer.apple.com/documentation/swiftui/view/matchedtransitionsource(id:in:)
[doc-completioncriteria]: https://developer.apple.com/documentation/swiftui/animationcompletioncriteria
[doc-logicallycomplete]: https://developer.apple.com/documentation/swiftui/animationcompletioncriteria/logicallycomplete
[doc-removed]: https://developer.apple.com/documentation/swiftui/animationcompletioncriteria/removed
[doc-logicallycomplete-after]: https://developer.apple.com/documentation/swiftui/animation/logicallycomplete(after:)
[doc-reducemotion]: https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
[doc-scrolltransition]: https://developer.apple.com/documentation/swiftui/view/scrolltransition(_:axis:transition:)
[hig-motion]: https://developer.apple.com/design/human-interface-guidelines/motion
[wwdc23-10156]: https://developer.apple.com/videos/play/wwdc2023/10156/
[wwdc23-10158]: https://developer.apple.com/videos/play/wwdc2023/10158/
[wwdc23-10157]: https://developer.apple.com/videos/play/wwdc2023/10157/
[wwdc21-10022]: https://developer.apple.com/videos/play/wwdc2021/10022/
[wwdc20-10041]: https://developer.apple.com/videos/play/wwdc2020/10041/
[wwdc24-10145]: https://developer.apple.com/videos/play/wwdc2024/10145/
[wwdc18-803]: https://developer.apple.com/videos/play/wwdc2018/803/
[pr775]: https://github.com/PetarKirov/sparkles/pull/775
[concepts]: ./concepts.md
[concepts-model-presentation]: ./concepts.md#model-value-and-presentation-value
[concepts-composite]: ./concepts.md#composite-operation
[baseline]: ./sparkles-baseline.md
[ca]: ./core-animation.md
[layout-swiftui]: ../ui-layout/swiftui.md
[ui-authoring]: ../ui-authoring/index.md
