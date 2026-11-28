# Core Animation (Apple platforms, Objective-C/Swift)

Apple's layer compositor animates by never animating app state: setting a layer property changes the model layer at once, an action object found through `action(forKey:)` turns the change into a `CAAnimation` committed with the `CATransaction`, and the render server — a separate process — interpolates the presentation tree on its own clock, so the app, its hit testing and its next layout see the target value from the first frame.

| Field                    | Value                                                                                                                                                                                                                                                                                             |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | Objective-C API, Swift overlay (`QuartzCore` framework); UIKit's view-animation and `UIViewPropertyAnimator` APIs on top                                                                                                                                                                          |
| License                  | Proprietary (Apple SDK); closed source                                                                                                                                                                                                                                                            |
| Repository               | None public; ships in the Apple platform SDKs                                                                                                                                                                                                                                                     |
| Documentation            | [Core Animation reference][doc-quartzcore] · [Core Animation Programming Guide][guide-basics] (archive; last revised 2015-03-09) · [UIViewPropertyAnimator][doc-uivpa] · Tech Talk [Explore UI animation hitches and the render loop][tt-10855] · WWDC18 [Designing Fluid Interfaces][wwdc18-803] |
| Category                 | retained layer tree with out-of-process compositing; implicit animations from property changes, explicit `CAAnimation` objects, hierarchical media timing                                                                                                                                         |
| Versions surveyed        | Apple's QuartzCore and UIKit documentation as served on 2026-11-26; `CALayer` since macOS 10.5 / iOS 2.0, `CASpringAnimation` iOS 9 / macOS 10.11, `UIViewPropertyAnimator` iOS 10, `CASpringAnimation(perceptualDuration:bounce:)` iOS 17 / macOS 14, `UIView.animate(_:changes:)` iOS 18        |
| Animation state lives in | the `CAAnimation` objects attached to each layer (copied into the render tree on commit) and the presentation tree they produce; the model layer holds only the target                                                                                                                            |

> [!NOTE]
> Core Animation has no public source; every claim is cited to Apple's reference documentation, the archived Programming Guide, or a session transcript, quoted verbatim. SwiftUI's animation system, which on iOS 18 can drive UIKit views through this layer tree, is covered in [SwiftUI][swiftui]. Terms such as _model value_ and _additive animation_ are defined in [Concepts][concepts].

---

## Overview

### What it solves

Smooth motion without per-frame work in the app. The framework overview states the division of labour ([Core Animation][doc-quartzcore]):

> _"Core Animation provides high frame rates and smooth animations without burdening the CPU or slowing down your app. Core Animation does most of the work of drawing each frame of an animation for you. You're responsible for configuring the animation parameters, such as the start and end points, and Core Animation does the rest."_

The app describes an animation once; it is shipped, with the layer tree, to a compositor that produces every frame. The app's own state is never in an intermediate condition.

### Design philosophy

1. **Data is decoupled from what is on screen.** _"The data and state information of a layer object is decoupled from the visual presentation of that layer's content onscreen. This decoupling gives Core Animation a way to interpose itself and animate the change from the old state values to new state values"_ ([Programming Guide, Core Animation Basics][guide-basics]).
2. **Three trees, three roles.** _"Objects in the model layer tree (or simply "layer tree") are the ones your app interacts with the most. The objects in this tree are the model objects that store the target values for any animations."_ _"Objects in the presentation tree contain the in-flight values for any running animations."_ _"Objects in the render tree perform the actual animations and are private to Core Animation"_ ([Basics][guide-basics]).
3. **Changing a property is the animation request.** _"With Core Animation, initiating an animation is often as simple as just changing the property"_ ([Programming Guide, Animating Layer Content][guide-animating]).
4. **Updates are atomic.** `CATransaction` is _"the Core Animation mechanism for batching multiple layer-tree operations into atomic updates to the render tree. Every modification to a layer tree must be part of a transaction"_ ([`CATransaction`][doc-catransaction]).
5. **Interfaces must be redirectable.** Apple's fluid-interface guidance: _"we want to allow for constant redirection and interruption"_ ([WWDC18 803][wwdc18-803]) — the motivation behind additive animation and `UIViewPropertyAnimator`.

---

## How it works

### Model, presentation and render trees

For every model layer there is a presentation and a render object ([Basics][guide-basics]). The model layer _"always reflects the last value set by your code and is equivalent to the final state of the animation"_; the presentation tree _"contains the layer values as they appear onscreen at that instant"_. [`presentation()`][doc-presentation] _"Returns a copy of the presentation layer object that represents the state of the layer as it currently appears onscreen"_ — a _"close approximation"_, a copy, not a live view — and its read-only methods query the presentation tree: _"the `hitTest(_:)` method of the returned object queries the layer objects in the presentation tree."_ [`model()`][doc-model] goes the other way. The presentation tree is read-only: _"You should never modify the objects in this tree. Instead, you use these objects to read current animation values, perhaps to create a new animation starting at those values."_

### The render loop and the render server

The [render-loop Tech Talk][tt-10855] gives the process boundary:

> _"The first stage is in your app, where events are handled and changes are made to the UI. … The next stage happens in a separate process called the render server. This is where your UI is actually rendered."_

Its five phases are **event** (the app handles input and mutates layers), **commit** (_"your app updates its UI and submits that to the render server"_: coalesced layout parent-to-child, then `setNeedsDisplay` drawing, then _"the entire altered layer tree is collected and sent to the render server"_), **render prepare**, **render execute** (GPU) and display. _"If there are no commits sent to the render server, no new frame is submitted."_ A running `CAAnimation` needs no commit per frame: the render server samples it.

### Implicit animations: `action(forKey:)` and `CAAction`

Setting an animatable property on a standalone layer is an implicit animation: _"the visual appearance of the layer objects does not change immediately. What happens instead is that Core Animation uses your changes as a trigger to create and schedule one or more implicit animations for execution"_ ([Animating Layer Content][guide-animating]). The trigger is an action lookup. [`action(forKey:)`][doc-actionforkey] searches, in order: the delegate's `action(for:forKey:)`; the layer's `actions` dictionary; the `style` dictionary; the class's [`defaultAction(forKey:)`][doc-defaultaction]. The Guide adds the stop rule: the delegate may _"Return the `NSNull` object, in which case the search ends immediately"_ ([Changing a Layer's Default Behavior][guide-actions]). The found [`CAAction`][doc-caaction] is sent `run(forKey:object:arguments:)`; for a property key it is typically a `CABasicAnimation` added to the layer under that key.

UIKit uses the first step to switch implicit animation off: _"The UIView class disables layer animations by default but reenables them inside animation blocks. So any changes you make outside of an animation block are not animated"_ ([Animating Layer Content][guide-animating]). AppKit likewise _"disables implicit animations for its layer-backed views by default"_.

### `CATransaction`

Transactions are implicit (_"created automatically when the layer tree is modified by a thread without an active transaction and are committed automatically when the thread's runloop next iterates"_) or explicit (`begin()`/`commit()`, nestable). A transaction overrides the defaults its implicit animations get — duration, timing function, [`setDisableActions(_:)`][doc-setdisableactions] (suppress actions entirely) — and carries a completion block that runs _"when all animations from the transaction group are completed"_ ([`CATransaction`][doc-catransaction]). [`flush()`][doc-flush] is called _"automatically at the end of the current runloop"_; calling it by hand is discouraged so that _"atomic screen updates will be preserved"_.

```swift
CATransaction.begin()
CATransaction.setAnimationDuration(2)
CATransaction.setCompletionBlock { transitioningLayer.removeFromSuperlayer() }
transitioningLayer.opacity = 0                            // implicit, 2 s
CATransaction.begin()
CATransaction.setAnimationDuration(1)
transitioningLayer.transform = CATransform3DMakeScale(3, 3, 3)  // implicit, 1 s
CATransaction.commit()
CATransaction.commit()
```

(the reference's own example, [`CATransaction`][doc-catransaction]).

### Explicit animations: `CABasicAnimation`, `CAKeyframeAnimation`, `CASpringAnimation`

An explicit animation is an object added with [`add(_:forKey:)`][doc-addforkey] (_"Add the specified animation object to the layer's render tree"_), keyed by a key path such as `"position"` or `"transform.scale.x"`. It does **not** change the model:

> _"Unlike an implicit animation, which updates the layer object's data value, an explicit animation does not modify the data in the layer tree. Explicit animations only produce the animations. … If you want the changes from an explicit animation to be permanent, you must also update the layer's property"_ ([Animating Layer Content][guide-animating]).

```swift
let fade = CABasicAnimation(keyPath: "opacity")
fade.fromValue = 1.0
fade.toValue = 0.0
fade.duration = 1.0
layer.add(fade, forKey: "opacity")
layer.opacity = 0.0          // the model jumps to the target now
```

- [`CABasicAnimation`][doc-cabasic] interpolates between any two of `fromValue`/`byValue`/`toValue`; with one or none set it reads the **presentation** layer: `toValue` alone _"Interpolates between the current value of `keyPath` in the target layer's presentation layer and `toValue`"_.
- [`CAKeyframeAnimation`][doc-cakeyframe] takes `values` + `keyTimes`, or a `path` for a point property, with `calculationMode` (e.g. `kCAAnimationPaced`, _"timing values are calculated implicitly to provide the animation with a constant velocity"_, [Animating Layer Content][guide-animating]).
- [`CASpringAnimation`][doc-caspring] (iOS 9) _"applies a spring-like force to a layer's properties"_ with `mass`, `stiffness`, `damping`, [`initialVelocity`][doc-caspring-velocity] and a derived [`settlingDuration`][doc-caspring-settling]; iOS 17 adds [`init(perceptualDuration:bounce:)`][doc-caspring-perceptual], the same parametrisation as SwiftUI's `Spring` ([WWDC23 10158][wwdc23-10158]).
- `CAAnimationGroup` shares one timing over several animations; [`CATransition`][doc-catransition] animates _"between a layer's states"_ (cross fade, push, …) as an action for the `contents` change or added explicitly.
- When the active duration ends, [`isRemovedOnCompletion`][doc-removedoncompletion] (default `true`) removes the animation and the layer renders its model value; [`fillMode`][doc-fillmode] `.forwards` instead keeps the final presentation.

### `additive` animations

[`isAdditive`][doc-isadditive]: _"If `true`, the value specified by the animation will be added to the current render tree value of the property to produce the new render tree value. The addition function is type-dependent, e.g. for affine transforms the two matrices are concatenated."_ An additive animation from `old − new` to `0`, laid over a model already at `new`, moves the layer from where it was without removing any other animation on the key path; several such animations sum. ([`isCumulative`][doc-iscumulative] is the unrelated per-repeat accumulation.)

### `CAMediaTiming`: hierarchical time

Layers and animations both adopt [`CAMediaTiming`][doc-camediatiming], _"Methods that model a hierarchical timing system, allowing objects to map time between their parent and local time"_. _"Absolute time is defined as mach time converted to seconds"_ ([`CACurrentMediaTime()`][doc-cacurrentmediatime]). Parent→local conversion has two stages: to _"active local time"_ (where the object sits on the parent's timeline and _"how fast it plays relative to the parent"_), then to _"basic local time"_ (repeat and autoreverse).

| Property                                              | Meaning                                                                  |
| ----------------------------------------------------- | ------------------------------------------------------------------------ |
| [`beginTime`][doc-begintime]                          | _"the begin time of the receiver in relation to its parent object"_      |
| [`timeOffset`][doc-timeoffset]                        | _"an additional time offset in active local time"_                       |
| [`speed`][doc-speed]                                  | _"if `speed` is 2.0 local time progresses twice as fast as parent time"_ |
| `duration`, `repeatCount`, `autoreverses`, `fillMode` | the basic-time shape of one animation                                    |

Because a layer's timing composes into its sublayers', _"changing the layer's speed property causes the duration of animations on that layer (and its sublayers) to change proportionally"_; [`convertTime(_:from:)`][doc-converttime] maps between layer time spaces ([Programming Guide, Advanced Animation Tricks][guide-advanced]). The Guide's pause idiom freezes a whole subtree:

```swift
func pause(_ layer: CALayer) {
    let paused = layer.convertTime(CACurrentMediaTime(), from: nil)
    layer.speed = 0
    layer.timeOffset = paused
}
```

This is the same parent-time/local-time tree that [SMIL and Web Animations][concepts-timeline] use.

### `UIViewPropertyAnimator`: an interruptible controller

[`UIViewPropertyAnimator`][doc-uivpa] (iOS 10) wraps a block of view-property changes in a controller object that lets you _"run your animations from start to finish normally or you can turn them into interactive animations and control the timing yourself"_. It can:

- start, pause, resume and stop (`UIViewAnimating`); [`stopAnimation(_:)`][doc-stopanimation] _"sets the values of any animatable properties to their current values"_;
- scrub a paused animation through [`fractionComplete`][doc-fractioncomplete] (_"You can update the value of this property only while the animator is paused"_), linearly unless [`scrubsLinearly`][doc-scrubslinearly] is `false`;
- reverse with [`isReversed`][doc-isreversed] (_"view properties animate back to their original values"_), and stay active after finishing with [`pausesOnCompletion`][doc-pausesoncompletion] so it can still be reversed;
- re-time the remainder with [`continueAnimation(withTimingParameters:durationFactor:)`][doc-continueanimation], e.g. a `UISpringTimingParameters(dampingRatio:initialVelocity:)` carrying the gesture's velocity;
- take more blocks while running ([`addAnimations(_:)`][doc-addanimations]), combined additively: _"For many properties, the changes from each animator are added together to yield a new intermediate value. If a property can't be modified in this additive manner, the new animations take over as if the `beginFromCurrentState` option had been specified."_

The older block API keeps a narrower interruption rule: [`beginFromCurrentState`][doc-beginfromcurrentstate] — _"Start the animation from the current setting associated with an already in-flight animation"_.

### `CADisplayLink`: the app-side frame clock

When the app must compute frames itself it uses [`CADisplayLink`][doc-cadisplaylink], _"A timer object that allows your app to synchronize its drawing to the refresh rate of the display"_. The callback reads `timestamp` (_"the time the system displayed the previous frame"_) and `targetTimestamp` (the next one); `preferredFrameRateRange` requests a rate that the system may lower for _"Low Power Mode, critical thermal state, and accessibility settings"_ ([`preferredFrameRateRange`][doc-preferredframerate]). `isPaused` stops callbacks.

---

## Analysis

### Where animation state lives

Outside the app's model entirely. The **model layer** holds the target (`layer.position` is the new value the moment it is set). The **animation objects** attached to the layer under keys (`animationKeys()`, `animation(forKey:)`) hold the from/to/by values, timing and spring parameters; on commit they are copied into the **render tree** in the render server process, which owns their evaluation (_"This object is copied by the render tree, not referenced. Therefore, subsequent modifications to the object are not propagated into the render tree"_, [`add(_:forKey:)`][doc-addforkey]). The **presentation tree** is a periodically refreshed, read-only copy of what that evaluation produced. This is the clearest instance of the [model/presentation split][concepts-model-presentation]: the presentation value exists, is readable (`presentation()`), but belongs to another process. `UIViewPropertyAnimator` adds a fourth, app-side holder: its `state`, `fractionComplete` and `isReversed`.

### Declaring an animation

Both forms, and both are value-change driven. **Implicit**: set a property; the action lookup produces a default animation (0.25 s unless the transaction overrides it — [`add(_:forKey:)`][doc-addforkey] substitutes _"the default value of `0.25` seconds"_ for a non-positive duration). In UIKit this is scoped to an animation block — the block is the "transaction with an animation" and everything set inside it animates. **Explicit**: construct a `CAAnimation`, add it, and separately set the model. Neither is a declarative target in the reactive sense: the description is an imperative command (set, add) that produces a retained animation object. **Imperative controllers** exist at two levels: `CAAnimation` objects can be removed by key and timed via `CAMediaTiming`; `UIViewPropertyAnimator` is a full controller (pause, scrub, reverse, re-time).

### Time and the clock

The **render server owns the clock** for committed animations; the app does not tick them. Time is continuous, in mach-time seconds (`CACurrentMediaTime()`), and **hierarchical**: every layer and animation maps parent time to local time through `beginTime`, `timeOffset`, `speed`, repeat and autoreverse ([`CAMediaTiming`][doc-camediatiming]). A subtree can be slowed, paused or scrubbed by editing one layer's timing — the same model as SMIL/Web Animations' timing tree. Frames are sampled at display refresh (VSYNC-timed render loop, [Tech Talk 10855][tt-10855]). When the app needs a clock of its own — custom physics, a game loop — `CADisplayLink` gives it `timestamp`/`targetTimestamp`, i.e. the presentation time of the frame being prepared; animating against `targetTimestamp` rather than "now" is what makes app-driven motion match compositor-driven motion ([baseline: who owns the clock][baseline-clock]). There are no scroll or view timelines in Core Animation itself; scroll-linked motion is app code in `scrollViewDidScroll` setting model values.

### Interruption and retargeting

Because the model already holds the target, a new change mid-flight must decide where the motion starts. Core Animation offers three answers:

- **Replace** (same key): [`add(_:forKey:)`][doc-addforkey] keeps _"Only one animation per unique key"_, so a new animation under the key of a running one replaces it. A `CABasicAnimation` with only `toValue` starts from the **presentation** value, so position is continuous but velocity is not (the new curve starts from rest). Removing without care jumps: _"When you remove an animation from a layer, Core Animation responds by redrawing the layer using its current values. Because the current values are usually the end values of the animation, this can cause the appearance of the layer to jump suddenly"_; the Guide's fix is to copy presentation values into the model first ([Animating Layer Content][guide-animating]).
- **Additive** (`isAdditive`): leave the old animation running and add a new relative one; the render server sums them, so both position and velocity stay continuous at the hand-off. UIKit's property animators combine this way by default ([`addAnimations(_:)`][doc-addanimations]).
- **Controller hand-off** (`UIViewPropertyAnimator`): pause, read `fractionComplete`, scrub, then `continueAnimation` with spring timing whose `initialVelocity` is the gesture's velocity — velocity is preserved only if the app computes and passes it. [WWDC24 10145][wwdc24-10145] shows the cost: _"we compute the initial velocity of the spring based on the current velocity of the bead, and we have to convert to a unit velocity by dividing by the distance the bead will travel"_, and offers SwiftUI animations on UIKit views ([`UIView.animate(_:changes:completion:)`][doc-uiview-animate-swiftui], iOS 18) as the alternative because they merge and keep velocity automatically.

### Curves and springs

Both. Timing curves are `CAMediaTimingFunction` cubic Béziers plus `duration`; keyframes add per-segment timing functions and paced/cubic calculation modes. Springs are `CASpringAnimation` (physical `mass`/`stiffness`/`damping`/`initialVelocity`, with `duration` independent of the derived `settlingDuration`: _"With a damping coefficient of `5`, the settling duration is approximately 2.85 seconds"_ for a 2-second `duration`, [`settlingDuration`][doc-caspring-settling]), UIKit's `usingSpringWithDamping:initialSpringVelocity:` and `UISpringTimingParameters(dampingRatio:initialVelocity:)` (damping ratio + response, as taught in [Designing Fluid Interfaces][wwdc18-803]: _"damping ratio and frequency response"_), and since iOS 17 `CASpringAnimation(perceptualDuration:bounce:)` and `UIView.animate(duration:bounce:)`, sharing SwiftUI's conversion ([WWDC23 10158][wwdc23-10158]). A `CASpringAnimation`'s `initialVelocity` is in units of the animated distance per second (positive _"moving towards the spring attachment point"_), which is why gesture hand-off must normalise.

### Layout animation

**Layout runs in the app, once, at the target; the compositor interpolates.** The idiom is to change constraints or frames and call [`layoutIfNeeded()`][doc-layoutifneeded] inside an animation block. Layout (commit phase, _"from parent to child"_, [Tech Talk 10855][tt-10855]) writes the new `bounds`/`position` into the model layers immediately; because UIKit re-enables actions inside the block, each changed geometry property gets an animation whose from-value is the old value (or the current presentation value) and whose to-value is the new model value. The render server then interpolates `position` and `bounds` per frame.

- **Previous geometry needed?** Yes — the action captures the old value at the moment the property is set (a `CABasicAnimation` with only `toValue` reads it from the presentation layer). Core Animation keeps it; the app never stores it.
- **Phase:** user code and layout run **once** in the app process (event → commit); the per-frame geometry interpolation runs **on the compositor** (render server). Nothing in the app runs per frame, which is why the animation survives a busy main thread.
- **Consequence:** during the animation every app-side query — layout, `frame`, hit testing on the model — sees the target geometry. Hit testing against where things _appear_ requires `presentation()?.hitTest(_:)`; UIKit additionally disables interaction on animating views by default (_"During an animation, user interactions are temporarily disabled for the views being animated"_ unless `allowUserInteraction`, [`animate(withDuration:delay:options:…)`][doc-uiview-animate]).
- Content whose layout itself must change per frame (text reflow, a path) cannot be expressed this way; it needs `CADisplayLink` and per-frame layout in the app.

### Enter and exit

There is **no exit mechanism**; removal is immediate. A layer removed with `removeFromSuperlayer()` leaves the model tree and the render tree in the same commit. An exit animation is therefore choreographed by the app: animate the departing property (opacity, transform) and remove the layer in the completion — exactly the reference's `CATransaction` example, whose completion block calls `transitioningLayer.removeFromSuperlayer()` ([`CATransaction`][doc-catransaction]); UIKit's `animate(withDuration:…completion:)` and `UIViewPropertyAnimator.addCompletion` are the same pattern. Until then the layer is a full member of the model tree — hit-testable, laid out, visible to the app — so the app must itself mark it "closing" and ignore it. `CATransition` covers the in-place case (a layer's contents swapped with a fade or push), and `fillMode = .forwards` with `isRemovedOnCompletion = false` can hold a final presentation state, at the price of a model that disagrees with the screen. Entry is the mirror image: insert the layer with its "before" values inside a disabled-actions transaction, then set the "after" values animated.

### Scheduling, reduced motion and testing

- **Frames only while animating, and not in the app.** A committed animation costs the app nothing per frame; the render server composites until `isRemovedOnCompletion` takes it off. App-driven motion uses a `CADisplayLink` that the app must pause or invalidate when idle (_"Your app can disable notifications by setting `isPaused` to `true`"_).
- **Reduced motion** is a flag the app reads: [`UIAccessibility.isReduceMotionEnabled`][doc-isreducemotion] (_"Whether the Reduce Motion setting is in an enabled state"_), with [`reduceMotionStatusDidChangeNotification`][doc-reducemotion-notification]. Core Animation does not alter app animations when it is set; the system may lower display-link frame rates for _"accessibility settings"_. [HIG: Motion][hig-motion] asks apps to _"Make motion optional."_
- **Testing.** There is no virtual clock, but the timing tree is one: `speed = 0` plus `timeOffset` samples any subtree at an exact local time (the Guide's pause idiom), and a large `speed` on a window's layer compresses animations. [`UIView.setAnimationsEnabled(_:)`][doc-setanimationsenabled] makes blocks apply immediately: _"code inside subsequent animation blocks is still executed but no animations actually occur"_. The model-jumps-immediately rule also helps: a test can assert on model values right after the change without waiting.

### Lessons for sparkles:ui

- **Core Animation is the element store with the clock moved out of process.** The model layer is the committed target; the presentation tree is the per-frame value. For sparkles, the analogous split is: components build against target values, and the host — not the component — samples presentation values at `FrameStart.target` for paint. App code (components, handlers, layout) then never sees an intermediate state, which keeps the build pure.
- **For UI-Q9, the cheapest layout animation needs one old rect per identity and runs at paint.** Layout once at the target; for every identity whose committed rect changed, start an interpolation from last frame's _presentation_ rect (not its model rect) to the new one; paint applies it as a translate/scale. This is exactly Core Animation's `bounds`/`position` actions and needs only the store's last committed geometry. The trade-off Core Animation documents also transfers: hit testing and handlers see the target geometry unless the host offers a presentation-space hit test. See UI-Q9 ([PR #775][pr775]).
- **For UI-Q10, Core Animation is the counter-example.** Removal is immediate, so every app reimplements "animate out, then remove" by keeping the element in its model. A store that keeps a closing entry painting after the element stops being built — and lets the component ignore it — is the feature Core Animation lacks.
- **Hierarchical timing is cheap and buys pause, scrub and tests.** `beginTime`/`timeOffset`/`speed` composed down the tree is three numbers per node; sampling an animation at a computed local time makes a recorder's virtual clock (see [baseline][baseline-clock]) a matter of passing a time, not mocking a clock.
- **Additive animation is the low-state way to retarget.** Representing an in-flight animation as an offset that decays to zero, layered over the target, means retargeting adds an entry rather than recomputing one — and keeps velocity continuous without a spring solver. It suits a `@nogc` store holding small per-identity arrays of offsets.
- **Velocity hand-off should not be the app's arithmetic.** `UIViewPropertyAnimator` makes callers normalise gesture velocity by distance; Apple's own later answer (SwiftUI animations on UIKit views) merges springs internally. A sparkles spring should accept velocity in property units and keep it across retargets itself.

---

## Strengths

- The app pays nothing per frame for committed animations; motion survives a blocked main thread.
- The model always holds the truth: layout, hit testing and app logic see a settled state.
- Implicit animations make "set a property" the whole API for common cases; `CATransaction` scopes and batches them atomically.
- A full hierarchical timing model (`CAMediaTiming`) gives pause, scrub, slow-motion and delay on any subtree.
- Additive animations and `UIViewPropertyAnimator` give two distinct, documented retargeting strategies.

## Weaknesses

- In-flight values are readable only as an approximate, copied presentation tree; they cannot be written.
- Model and screen disagree during every animation; hit testing on the model targets where things will be, not where they are.
- No exit animation: removal is immediate, and the app keeps departing elements alive by hand.
- Velocity preservation for non-additive replacement is the caller's job (normalised `initialVelocity`).
- Per-frame layout (reflow, paths) is not expressible; it falls back to `CADisplayLink` in the app.
- Several overlapping layers of API (implicit actions, `CAAnimation`, UIKit blocks, property animators, SwiftUI bridging) with different defaults.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                                 | Trade-off                                                                       |
| ------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Model jumps to the target immediately             | App state is never intermediate; layout and logic stay simple             | Screen and model disagree in flight; hit tests and queries see the target       |
| Render server evaluates animations out of process | No per-frame app work; smooth under main-thread load                      | App cannot observe or adjust frames; presentation values are copies             |
| Implicit actions via `action(forKey:)` lookup     | "Change a property" animates; delegates/dictionaries can override per key | UIKit has to disable it outside blocks; behaviour depends on a four-step lookup |
| Explicit `CAAnimation` does not touch the model   | Decorative or temporary motion without state changes                      | Forgetting to set the model snaps back at the end                               |
| Hierarchical `CAMediaTiming`                      | Pause, scrub, delay and speed compose through the tree                    | Time-space conversions (`convertTime`) are easy to get wrong                    |
| `isAdditive` relative animations                  | Continuous position and velocity when retargeting; animations stack       | Opt-in for raw layers; reasoning about summed offsets is harder                 |
| `UIViewPropertyAnimator` as a controller          | Interactive, scrubbable, reversible transitions                           | App computes and normalises hand-off velocity                                   |
| No removal phase                                  | Layer tree membership is always exact                                     | Every exit animation is app choreography with a completion callback             |

---

## Sources

- Apple, Core Animation reference: [framework overview][doc-quartzcore], [`CALayer`][doc-calayer], [`presentation()`][doc-presentation], [`model()`][doc-model], [`action(forKey:)`][doc-actionforkey], [`CAAction`][doc-caaction], [`CATransaction`][doc-catransaction], [`CABasicAnimation`][doc-cabasic], [`CAKeyframeAnimation`][doc-cakeyframe], [`CASpringAnimation`][doc-caspring], [`isAdditive`][doc-isadditive], [`CAMediaTiming`][doc-camediatiming], [`CADisplayLink`][doc-cadisplaylink] — read 2026-11-26.
- Apple, [Core Animation Programming Guide][guide-basics] (archive, revised 2015-03-09): [Core Animation Basics][guide-basics], [Animating Layer Content][guide-animating], [Advanced Animation Tricks][guide-advanced], [Changing a Layer's Default Behavior][guide-actions].
- Apple, UIKit reference: [`UIViewPropertyAnimator`][doc-uivpa], [`fractionComplete`][doc-fractioncomplete], [`isReversed`][doc-isreversed], [`addAnimations(_:)`][doc-addanimations], [`beginFromCurrentState`][doc-beginfromcurrentstate], [`isReduceMotionEnabled`][doc-isreducemotion], [`setAnimationsEnabled(_:)`][doc-setanimationsenabled].
- Sessions: Tech Talk [Explore UI animation hitches and the render loop][tt-10855]; [WWDC18 803 Designing Fluid Interfaces][wwdc18-803]; [WWDC23 10158 Animate with springs][wwdc23-10158]; [WWDC24 10145 Enhance your UI animations and transitions][wwdc24-10145].
- Apple, [Human Interface Guidelines: Motion][hig-motion].
- In this survey: [Concepts][concepts], [Sparkles baseline][baseline], [SwiftUI][swiftui]; [UI authoring decisions][ui-authoring].

<!-- References -->

[doc-quartzcore]: https://developer.apple.com/documentation/quartzcore
[doc-calayer]: https://developer.apple.com/documentation/quartzcore/calayer
[doc-presentation]: https://developer.apple.com/documentation/quartzcore/calayer/presentation()
[doc-model]: https://developer.apple.com/documentation/quartzcore/calayer/model()
[doc-actionforkey]: https://developer.apple.com/documentation/quartzcore/calayer/action(forkey:)
[doc-defaultaction]: https://developer.apple.com/documentation/quartzcore/calayer/defaultaction(forkey:)
[doc-caaction]: https://developer.apple.com/documentation/quartzcore/caaction
[doc-catransaction]: https://developer.apple.com/documentation/quartzcore/catransaction
[doc-setdisableactions]: https://developer.apple.com/documentation/quartzcore/catransaction/setdisableactions(_:)
[doc-flush]: https://developer.apple.com/documentation/quartzcore/catransaction/flush()
[doc-addforkey]: https://developer.apple.com/documentation/quartzcore/calayer/add(_:forkey:)
[doc-cabasic]: https://developer.apple.com/documentation/quartzcore/cabasicanimation
[doc-cakeyframe]: https://developer.apple.com/documentation/quartzcore/cakeyframeanimation
[doc-caspring]: https://developer.apple.com/documentation/quartzcore/caspringanimation
[doc-caspring-velocity]: https://developer.apple.com/documentation/quartzcore/caspringanimation/initialvelocity
[doc-caspring-settling]: https://developer.apple.com/documentation/quartzcore/caspringanimation/settlingduration
[doc-caspring-perceptual]: https://developer.apple.com/documentation/quartzcore/caspringanimation/init(perceptualduration:bounce:)
[doc-catransition]: https://developer.apple.com/documentation/quartzcore/catransition
[doc-removedoncompletion]: https://developer.apple.com/documentation/quartzcore/caanimation/isremovedoncompletion
[doc-fillmode]: https://developer.apple.com/documentation/quartzcore/camediatiming/fillmode
[doc-isadditive]: https://developer.apple.com/documentation/quartzcore/capropertyanimation/isadditive
[doc-iscumulative]: https://developer.apple.com/documentation/quartzcore/capropertyanimation/iscumulative
[doc-camediatiming]: https://developer.apple.com/documentation/quartzcore/camediatiming
[doc-cacurrentmediatime]: https://developer.apple.com/documentation/quartzcore/cacurrentmediatime()
[doc-begintime]: https://developer.apple.com/documentation/quartzcore/camediatiming/begintime
[doc-timeoffset]: https://developer.apple.com/documentation/quartzcore/camediatiming/timeoffset
[doc-speed]: https://developer.apple.com/documentation/quartzcore/camediatiming/speed
[doc-converttime]: https://developer.apple.com/documentation/quartzcore/calayer/converttime(_:from:)
[doc-cadisplaylink]: https://developer.apple.com/documentation/quartzcore/cadisplaylink
[doc-preferredframerate]: https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange
[doc-uivpa]: https://developer.apple.com/documentation/uikit/uiviewpropertyanimator
[doc-stopanimation]: https://developer.apple.com/documentation/uikit/uiviewanimating/stopanimation(_:)
[doc-fractioncomplete]: https://developer.apple.com/documentation/uikit/uiviewanimating/fractioncomplete
[doc-scrubslinearly]: https://developer.apple.com/documentation/uikit/uiviewpropertyanimator/scrubslinearly
[doc-isreversed]: https://developer.apple.com/documentation/uikit/uiviewanimating/isreversed
[doc-pausesoncompletion]: https://developer.apple.com/documentation/uikit/uiviewpropertyanimator/pausesoncompletion
[doc-continueanimation]: https://developer.apple.com/documentation/uikit/uiviewimplicitlyanimating/continueanimation(withtimingparameters:durationfactor:)
[doc-addanimations]: https://developer.apple.com/documentation/uikit/uiviewpropertyanimator/addanimations(_:)
[doc-beginfromcurrentstate]: https://developer.apple.com/documentation/uikit/uiview/animationoptions/beginfromcurrentstate
[doc-uiview-animate]: https://developer.apple.com/documentation/uikit/uiview/animate(withduration:delay:options:animations:completion:)
[doc-uiview-animate-swiftui]: https://developer.apple.com/documentation/uikit/uiview/animate(_:changes:completion:)
[doc-layoutifneeded]: https://developer.apple.com/documentation/uikit/uiview/layoutifneeded()
[doc-isreducemotion]: https://developer.apple.com/documentation/uikit/uiaccessibility/isreducemotionenabled
[doc-reducemotion-notification]: https://developer.apple.com/documentation/uikit/uiaccessibility/reducemotionstatusdidchangenotification
[doc-setanimationsenabled]: https://developer.apple.com/documentation/uikit/uiview/setanimationsenabled(_:)
[hig-motion]: https://developer.apple.com/design/human-interface-guidelines/motion
[guide-basics]: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html
[guide-animating]: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CreatingBasicAnimations/CreatingBasicAnimations.html
[guide-advanced]: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/AdvancedAnimationTricks/AdvancedAnimationTricks.html
[guide-actions]: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/ReactingtoLayerChanges/ReactingtoLayerChanges.html
[tt-10855]: https://developer.apple.com/videos/play/tech-talks/10855/
[wwdc18-803]: https://developer.apple.com/videos/play/wwdc2018/803/
[wwdc23-10158]: https://developer.apple.com/videos/play/wwdc2023/10158/
[wwdc24-10145]: https://developer.apple.com/videos/play/wwdc2024/10145/
[pr775]: https://github.com/PetarKirov/sparkles/pull/775
[concepts]: ./concepts.md
[concepts-model-presentation]: ./concepts.md#model-value-and-presentation-value
[concepts-timeline]: ./concepts.md#timeline
[baseline]: ./sparkles-baseline.md
[baseline-clock]: ./sparkles-baseline.md#who-owns-the-clock
[swiftui]: ./swiftui.md
[ui-authoring]: ../ui-authoring/index.md
