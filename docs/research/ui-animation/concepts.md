# Concepts — the vocabulary of UI animation

The terms the deep-dives share, each defined once and tied to the systems that
use it. The surveyed systems name the same idea differently — Flutter's
`Tween` is Compose's `TwoWayConverter` plus `tween`, Core Animation's
presentation layer is what Motion calls a `MotionValue`'s rendered value — so
the deep-dives use the words below and give each system's own name beside it.

**Last reviewed:** November 26, 2026

---

## Values and time

### Model value and presentation value

Every animated property has two values. The **model value** is what the program
set: the target, the state the interface is _in_. The **presentation value** is
what is on the screen this frame, somewhere between the old model value and the
new one. Core Animation makes the split a public API — a layer and its
`presentation()` copy ([Core Animation](./core-animation.md#where-animation-state-lives))
— and every other system has it implicitly: Flutter's `AnimationController.value`,
Compose's `Animatable.value`, the computed style a [Web Animation](./web-animations.md)
produces over the specified one. Where the presentation value lives is the first
axis of the [comparison](./comparison.md#where-animation-state-lives).

### Animation as a function of time

An animation is a function from time to a presentation value. A **tween**
(_in-between_) over duration `d` starting at `t0` from `a` to `b` is

```text
value(t) = lerp(a, b, ease(clamp((t - t0) / d, 0, 1)))
```

where `ease` is the [easing curve](#easing-curves). That is the whole of
[Fran](./frp.md#fran)'s idea — a `Behavior a` _is_ a function of time — and the
reason a tween needs no per-frame state beyond `(t0, a, b, d, ease)`. A system
that stores those five values and samples them at the frame's time keeps the
view a pure function of `(state, time)`; one that stores `value` and steps it by
`dt` (a [stepped integrator](#closed-form-and-stepped-integration)) does not.

### Frame clock and target time

The **frame clock** delivers one timestamp per frame to every animation, so all
animations of a frame sample the same instant. Systems differ on _which_ instant:
the frame's start, the vsync that triggered it, or the predicted **presentation
time** at which the frame will be shown. Compose's `MonotonicFrameClock` may be
_"normalized to the target time for the frame"_; `CADisplayLink` exposes
`targetTimestamp`; Flutter's `Ticker` receives the vsync-aligned elapsed time
([Flutter](./flutter.md#time-and-the-clock),
[Compose](./jetpack-compose.md#time-and-the-clock),
[Core Animation](./core-animation.md#time-and-the-clock)). Sampling at the target
time is what makes motion look even when frame costs vary.

### Timeline

A **timeline** is a source of time values an animation is attached to. The
[document timeline](./web-animations.md#time-and-the-clock) is wall-clock time
since the page loaded; a [scroll timeline](./scroll-and-view-transitions.md#time-and-the-clock)
maps a scroll offset to progress, so the "time" is a position and the animation
runs backward when the user scrolls back; an authored timeline (GSAP's
`Timeline`, Godot's `AnimationPlayer`, a Lottie file's frame range) is a seekable
container whose children start at offsets within it
([engines and tools](./engines-and-tools.md#time-and-the-clock)). A **hierarchical
timing model** — Web Animations, `CAMediaTiming`, GSAP — nests timelines, each
with its own start time, rate and offset, so pausing or scaling a parent scales
all its children.

### Closed form and stepped integration

A **closed-form** animation computes `value(t)` directly from its parameters; a
**stepped** one keeps `(value, velocity)` and advances them by `dt` each frame. A
tween is always closed-form. A spring can be either: its differential equation
has an exact solution, which Compose's `SpringSimulation`, Flutter's
`SpringSimulation` and `sparkles:ui`'s `ScrollMotion` evaluate
([baseline](./sparkles-baseline.md#what-moves-today)), while harmonica, egui's
smoothing and `ScrollbarAnim` take an approximate step whose result depends on
the frame rate ([terminal UIs](./terminal-uis.md#curves-and-springs),
[immediate mode](./immediate-mode.md#curves-and-springs)). Closed form is what lets
a system [seek](#timeline), test at an arbitrary instant, and skip frames without
changing the outcome.

---

## Curves and physics

### Easing curves

An **easing curve** maps normalised progress `[0, 1]` to normalised output. The
common families are cubic Béziers fixed at `(0,0)` and `(1,1)` (CSS
`cubic-bezier()`, Flutter's `Cubic`, Compose's `CubicBezierEasing`,
`CAMediaTimingFunction`), steps, and piecewise-linear functions (CSS `linear()`,
which can approximate a spring as a sampled curve —
[CSS](./css-transitions-and-animations.md#curves-and-springs)). A curve has a
fixed duration; it has no notion of the velocity the value had when the
animation began.

### Spring

A **spring** animates a value toward a target as a damped harmonic oscillator:

```text
m·x'' = −k·(x − target) − c·x'
ω₀ = √(k / m)              natural frequency
ζ  = c / (2·√(k·m))        damping ratio: < 1 bounces, = 1 critical, > 1 overdamped
```

It has no duration; it _settles_ when position and velocity fall under
thresholds. Because its state includes velocity, a spring retargeted mid-flight
continues smoothly from its current velocity. Systems parametrise it three ways:
physically (`stiffness`, `damping`, `mass` — Flutter, Compose's `stiffness`,
React Spring's `tension`/`friction`), by damping ratio and frequency (Compose's
`dampingRatio`, harmonica's `angularFrequency`/`dampingRatio`), or perceptually
by a duration and a bounce (SwiftUI's `spring(duration:bounce:)`, Motion's
`visualDuration`) — see [SwiftUI](./swiftui.md#curves-and-springs) and
[Motion](./react-motion-and-spring.md#curves-and-springs). A critically damped
spring (`ζ = 1`) has the closed form `x(t) = (x₀ + (v₀ + ω₀·x₀)·t)·e^(−ω₀·t)`
(offsets from the target), the curve `ScrollMotion` evaluates.

### Decay

A **decay** (fling) has no target: it starts with a velocity and slows under
friction, `v(t) = v₀·e^(−λt)`, ending where it comes to rest. Compose's
`DecayAnimationSpec`, Flutter's `FrictionSimulation`, Gio's fling and
`ScrollMotion`'s `flinging` mode are decays. A decay that would cross a bound is
usually handed to a spring that brings it back — the overscroll bounce.

### Keyframes

**Keyframes** give values at offsets within one animation, each segment with its
own easing: CSS `@keyframes`, `KeyframeEffect`, Compose's `keyframes { }`,
SwiftUI's `KeyframeAnimator`, Lottie's keyframed properties, Godot's animation
tracks.

---

## Declaring and interrupting

### Implicit and explicit

An animation is **implicit** when changing a value animates it with no further
code: a CSS transition, a Flutter `AnimatedContainer`, a Compose
`animateDpAsState`, a Core Animation layer property's default action, egui's
`animate_bool`. It is **explicit** when the program starts it: an
`AnimationController.forward()`, `Animatable.animateTo`, `element.animate()`,
`gsap.to`. SwiftUI's `withAnimation` is explicit about _when_ and implicit about
_what_: every value the closure changes animates.

### Declarative target and imperative controller

A **declarative target** states where the value should be this frame and lets the
system get it there — a Motion `animate` prop of `{ x: 100 }`, an `AnimatedContainer`'s
`width`, a `Transition`'s target state. An **imperative controller** is an object
the program commands — `forward`, `reverse`, `stop`, `seek`, `animateTo` — and
holds: `AnimationController`, `Animatable`, a WAAPI `Animation`,
`UIViewPropertyAnimator`, a GSAP tween. Declarative targets fit a per-frame
pure view (the view only ever states targets); controllers need somewhere to live
across frames and a lifecycle to dispose them.

### Interruption and retargeting

When the target changes mid-flight, a system can:

| Response                       | What the value does                                                                         | Examples                                                                                                                                               |
| ------------------------------ | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Cut**                        | jumps to the new animation's start                                                          | a CSS animation whose `animation-name` changes                                                                                                         |
| **Restart from current value** | a new tween starts where the value is, with zero velocity — a visible kink                  | Flutter's implicit widgets, CSS transitions (with the [reversing shortening](./css-transitions-and-animations.md#interruption-and-retargeting) factor) |
| **Retarget with velocity**     | the spring or simulation keeps its velocity toward the new target                           | Compose `Animatable`, Motion and React Spring springs, `ScrollMotion.nudge`                                                                            |
| **Additive**                   | the old animation keeps running as a relative offset decaying to zero; the new one is added | Core Animation `additive`, SwiftUI timing curves (run alongside, deltas added), WAAPI `composite: "add"`                                               |

Velocity continuity is what makes an interface feel _interruptible_; Apple's
fluid-interface guidance asks _"to allow for constant redirection and
interruption"_ ([Core Animation](./core-animation.md#design-philosophy)).

### Composite operation

When several animations target one property, the **effect stack** orders them and
a **composite operation** combines each with the result below it: `replace`,
`add` or `accumulate` in [Web Animations](./web-animations.md#interruption-and-retargeting);
`additive` on a `CAPropertyAnimation`; blend weights in Godot's `AnimationTree`
and Rive's blend states.

---

## Geometry and presence

### Layout animation

A **layout animation** moves or resizes an element because its _layout_ changed,
not because a property was animated directly. It needs two geometries — before
and after — and every mechanism in the survey is a way to get both:

| Mechanism            | Before geometry                                        | After geometry                 | Runs in                                                           |
| -------------------- | ------------------------------------------------------ | ------------------------------ | ----------------------------------------------------------------- |
| **FLIP**             | measured from the last layout, in user or library code | measured after the new layout  | user/library code measures; the transform plays on the compositor |
| **Lookahead**        | the current (animated) layout                          | a pre-pass computes the target | inside the layout phase (Compose `LookaheadScope`)                |
| **Matched geometry** | the source view's frame                                | the destination view's frame   | after layout, in the framework (SwiftUI `matchedGeometryEffect`)  |
| **Snapshot**         | a raster of the old state                              | the live new state             | the compositor (View Transitions, Flutter's `Hero` overlay)       |

**FLIP** — _First, Last, Invert, Play_ (Paul Lewis, 2015) — records the
element's first rect, applies the change, reads the last rect, sets a transform
that puts the element back at the first, then animates the transform to
identity ([Web Animations](./web-animations.md#layout-animation)). It is the
mechanism behind Motion's `layout`, Svelte's `animate:flip`, GSAP's `Flip` and
React Spring's layout recipes. Which of these need the _previous frame's_
geometry, and in which phase they run, is the centre of the
[comparison](./comparison.md#layout-animation-and-ui-q9).

### Shared element

A **shared element** (hero, matched geometry, `layoutId`, `sharedElement`,
`view-transition-name`) is one logical element that appears in two places — two
routes, two containers, a list and a detail view — and animates between them. It
needs an identity that spans the two places: a tag, a namespace and id, or a
name.

### Enter, exit and presence

An **enter** animation runs when an element first appears; an **exit** when it is
removed. Enter is easy — the element exists. Exit is hard because the program has
already removed the element, so something must keep it painting. A **presence**
mechanism defers the removal: Motion's `AnimatePresence`, Compose's
`AnimatedVisibility`, Flutter's `AnimatedSwitcher`, Svelte's outros and SwiftUI's
removal transitions keep the old subtree alive until its exit finishes; View
Transitions keeps a **snapshot** of it instead. The [comparison](./comparison.md#enter-exit-and-ui-q10)
sorts the field by which of the two it keeps.

### Reduced motion

**Reduced motion** is the user's platform preference for less movement:
`prefers-reduced-motion` on the web, `accessibilityReduceMotion` and
`UIAccessibility.isReduceMotionEnabled` on Apple platforms, the animator duration
scale (`ANIMATOR_DURATION_SCALE`) on Android, `TargetCapabilities.reducedMotion`
in `sparkles:ui`. Systems respond by skipping animations, shortening them, or
substituting a cross-fade for a movement.

<!-- References -->
