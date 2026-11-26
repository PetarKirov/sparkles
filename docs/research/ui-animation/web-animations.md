# Web Animations (Web platform)

The Web platform's animation model and its script API: a stateless timing function from a timeline's time value to an iteration progress, a hierarchy (timeline → `Animation` → `KeyframeEffect`) that shifts, scales and repeats that time, per-property effect stacks that composite `replace`/`add`/`accumulate` results into the CSS cascade, and the objects (`CSSTransition`, `CSSAnimation`) that CSS markup is defined to produce — plus FLIP, the user-code technique that turns a layout change into a compositor-only transform animation on top of it.

| Field                    | Value                                                                                                                                                                                                                 |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | WebIDL / JavaScript API (`Element.animate()`, `Animation`, `KeyframeEffect`, `DocumentTimeline`), consumed by CSS                                                                                                     |
| License                  | W3C Software and Document License ([`LICENSE.md`][license])                                                                                                                                                           |
| Repository               | [w3c/csswg-drafts][repo]: [`web-animations-1`][wa1-src], [`web-animations-2`][wa2-src]                                                                                                                                |
| Documentation            | [Web Animations Level 1][wa1-ed] ([TR][wa1-tr]) · [Level 2][wa2-ed] ([TR][wa2-tr]) · Paul Lewis, [_FLIP Your Animations_][flip] (aerotwist.com, 2015-02-11) · MDN only as secondary ([Web Animations API][mdn-waapi]) |
| Category                 | retained, UA-owned animation objects over a stateless timing model; imperative API with declarative CSS front ends                                                                                                    |
| Versions surveyed        | `w3c/csswg-drafts` commit `9c7ee53` (2026-11-25): Level 1 editor's draft (earliest TR listed: WD 2013-06-25; latest 2023-06-05), Level 2 WD dated 2025-11-20 (a delta spec over Level 1)                              |
| Animation state lives in | the user agent's `Animation` objects (start time, hold time, playback rate, pending tasks, replace state) on the _global animation list_; the effect value is recomputed from time each frame and is not state        |

> [!NOTE]
> The CSS front ends are on [CSS Transitions and Animations][css-page]; scroll and view timelines, and View Transitions (which are themselves CSS Animations on pseudo-elements), are on [Scroll-driven Animations and View Transitions][vt-page]. Spec quotes are verbatim from the Bikeshed source at commit `9c7ee53`, linked to line ranges, with the rendered section alongside.

---

## Overview

### What it solves

Before it, the platform had three animation systems with separate models — CSS Transitions, CSS Animations and SVG/SMIL — and script animation was `requestAnimationFrame` writing styles. The introduction positions the spec as the common substrate: _"This specification defines a model (the Web Animations model) for supporting animation and synchronization on the Web platform. It is intended that other specifications will build on this model and expose its features through declarative means"_ ([§ Introduction][wa1-intro-src]). The use-case list says what script animation lacked:

> _"While it is possible to use ECMAScript to perform animation using requestAnimationFrame [HTML], such animations behave differently to declarative animation in terms of how they are represented in the CSS cascade and the performance optimizations that are possible, such as performing the animation on a separate thread. Using the Web Animations API, it is possible to create animations from script that have the same behavior and performance characteristics as declarative animations."_ ([§ Use cases][wa1-usecases-src])

### Design philosophy

The timing model has two named characteristics ([§ Stateless][wa1-stateless-src]):

> _"The Web Animations timing model operates by taking an input time value and producing an output iteration progress. Since the output is based solely on the input time and is independent of previous inputs, the model can be described as stateless."_

which buys _"Frame-rate independent"_, _"Direction-agnostic"_ and _"Constant-time seeking"_ — with the honest caveat that play control and finishing are _"stative"_, so _"the model can only truly be described as stateless in the absence of dynamic changes to its timing properties"_ ([same][wa1-stateless-src]). And:

> _"The other characteristic feature of the timing model is that time is inherited. Time begins at a timeline and cascades down a number of steps to each animation effect. At each step, time can be shifted backwards or forwards, scaled, reversed, paused, and repeated."_ ([§ Hierarchical][wa1-hier-src])

Level 2 deepens the hierarchy with group effects so that _"complex animation arrangements can be reversed, scheduled, accelerated and so on as a whole unit since the manipulations applied to the parent, cascade down to its descendants"_ ([Level 2 § Hierarchical][wa2-hier-src]).

---

## How it works

### Timelines and the document timeline

_"A timeline is a timing node that provides a source of time values. At any given moment, a timeline has a single current time value known simply as the timeline's current time. Changes in a timeline's current time are ultimately what drive animations"_ ([§ Timelines][wa1-timelines-src]). A _document timeline_'s time is _"a fixed offset from the now timestamp provided each time the update animations and send events procedure is run"_; every document has a _default document timeline_ with origin time zero ([§ Document timelines][wa1-doctimeline-src]). Its relationship to the wall clock is explicitly frame-quantised:

> _"`document.timeline.currentTime` will roughly correspond to Performance.now() [HR-TIME] with the exception that `document.timeline.currentTime` does not change in between calls to the update animations and send events procedure."_ ([§ Relationship to wall-clock time][wa1-wallclock-src])

Time values are deliberately abstract: _"real numbers that nominally represent a number of milliseconds from some moment"_, with the note that _"In the future there could be timelines that are based on scroll position or UI gestures"_ ([§ Time values][wa1-timevalue-src]) — the hook that [Scroll-driven Animations][vt-page] fills.

### The animation frame

Once per rendering update, HTML calls _update animations and send events_ for each document with a timestamp `now` ([§ Animation Frames][wa1-frame-src]):

1. update every associated timeline's current time (which updates each animation's current time, runs _update an animation's finished state_, and queues animation events);
2. _remove replaced animations_;
3. perform a microtask checkpoint (so `finished`/`ready` promise callbacks run before events);
4. sort the pending animation events by scheduled event time, then composite order, and dispatch them.

_"It is often convenient to describe each time this procedure is invoked as establishing a new animation frame"_; API calls only _"update the current animation frame"_ ([same][wa1-frame-src]). And API calls do not, in general, restyle: _"invoking the methods or constructors, or getting or setting the members of interfaces defined in the Web Animations API does not produce a style change event"_ ([§ Model liveness][wa1-liveness-src]).

### `Animation`: start time, hold time, playback rate

An animation _"binds an animation effect child, called its associated effect, to a timeline parent so that it runs"_ — _"analogous to that of a DVD player and a DVD"_. It carries a **start time** (the timeline time at which the effect begins) and a **hold time** (_"used to freeze the animation's current time output in circumstances such as pausing"_), and is appended to a **global animation list** in creation order ([§ Animations][wa1-animations-src]). Current time is a pure formula ([§ Calculating the current time][wa1-currenttime-src]):

```text
if hold time is resolved:      current time = hold time
elif no/inactive timeline or start time unresolved: current time = unresolved
else:                          current time = (timeline time − start time) × playback rate
```

Starting playback is asynchronous by rule. `play()` queues a _pending play task_ that resolves the start time once the animation is **ready** — _"the user agent has completed any setup required to begin the playback of the animation's associated effect, including rendering the first frame of any keyframe effect"_ ([§ The current ready promise][wa1-ready-src]) — and the UA _"must not perform the task synchronously"_ ([§ Playing an animation][wa1-pendingplay-src]). The `ready` promise reports that moment. This is where a compositor-thread implementation synchronises: the start time is chosen when the first frame is actually produced, not when script asked. Playback-rate changes have the same problem and a dedicated API: _"For an in-flight animation that is running on another process or thread, the procedure to set the playback rate can cause the animation to jump"_, hence `updatePlaybackRate()` and a _pending playback rate_ ([§ Seamlessly updating the playback rate][wa1-playbackrate-src]).

### Effects: local, active and iteration time

An effect's **local time** is its animation's current time ([§ Local time][wa1-localtime-src]). The effect then maps it through three time spaces ([§ Time spaces][wa1-timespaces-src]): _local_ (relative to the animation's start time), _active_ (relative to the start of the active interval, after `delay`), and _iteration_ (relative to the start of the current iteration). The pipeline in [§ Calculating progress, overview][wa1-calc-src] is: local time → active time (start delay) → overall progress (÷ iteration duration, + iteration start) → simple iteration progress (fold into one iteration) → directed progress (`direction`) → transformed progress (easing). The output, the _iteration progress_, is what a keyframe effect samples.

Fill modes extend the effect outside its active interval; the spec discourages using them to hold an end state: _"Authors are discouraged from using fill modes to produce animations whose effect is applied indefinitely […] they produce situations where animation state would be accumulated indefinitely, necessitating the automatic removal of animations"_ ([§ Fill behavior][wa1-fill-src]).

### `KeyframeEffect`, implicit keyframes and the effect stack

A `KeyframeEffect` holds a target element, a keyframe list and timing (`duration`, `delay`, `iterations`, `direction`, `easing`, `fill`, `composite`). If a property has no keyframe at offset 0 or 1, the UA synthesises one whose value is the **underlying value** with `replace` composite and linear easing ([§ The effect value of a keyframe effect][wa1-implicit-src]) — so `el.animate({ transform: 'translateX(100px)' }, 300)` animates from whatever lower animations and the base style currently produce.

Per property, every in-effect keyframe effect sits in an **effect stack** ordered by animation class (transitions < CSS animations < script), class-specific order, then global animation list position ([§ The effect stack][wa1-stack-src]). Evaluation folds the stack from the base computed value: _"For each keyframe effect in the stack, the appropriate effect value from the keyframe effect is combined with the underlying value to produce a new value. This resulting value becomes the underlying value for combining the next keyframe effect in the stack"_ ([§ Calculating the result of an effect stack][wa1-stackresult-src]). The combine step is the **composite operation** ([§ Effect composition][wa1-composite-src]):

- `replace` — _"The result of compositing the effect value with the underlying value is simply the effect value."_
- `add` — _"The effect value is added to the underlying value"_, as `underlying + effect` when not commutative (for `transform` lists, append).
- `accumulate` — _"The effect value is accumulated onto the underlying value"_ (for `transform`, component-wise sum of matching functions).

The composited value is inserted into the cascade at the level of the topmost effect's class: _"By default, the specified value is added to the Animation Origin of the cascade"_; a transition on top goes to the Transition origin ([§ Applying the composited result][wa1-apply-src]).

### Replaceable animations, `persist()`, `commitStyles()`

Fire-and-forget `animate(…, { fill: 'forwards' })` would otherwise grow the stack forever — the spec's own example is a `mousemove` handler that creates _"hundreds, even thousands of forwards-filling animations"_ ([§ Replacing animations][wa1-replace-src]). So an animation is **replaceable** when it is not owned by CSS markup, is _finished_, is on a monotonically increasing timeline, and has an in-effect effect with a target; during each animation frame, a replaceable animation all of whose target properties are covered by a higher-composite-order replaceable animation gets `replaceState = 'removed'` and a `remove` event ([§ Removing replaced animations][wa1-removal-src]). `persist()` opts out; `commitStyles()` writes the current effect values into the target's inline style, using endpoint-inclusive timing so a just-finished, non-filling animation still commits its end value, and _"calling this method does trigger a style change event"_ ([`commitStyles()`][wa1-commit-src]). The recommended end-state idiom:

```js
// web-animations-1, Fill behavior: set the final state in style, not with fill
elem.animate({ transform: 'translateY(100px)' }, 200).finished.then(() => {
  elem.commitStyles();
});
```

`finished` resolves when the animation reaches its end; the spec notes the callback runs _"BEFORE style is updated, and hence will NOT flicker"_ ([same][wa1-fill-src]).

### `getAnimations()`

`Element.getAnimations({ subtree })` returns the relevant animations for a target (or its subtree), sorted by composite order, and _"Calling this method triggers a style change event for the target element. As a result, the returned list reflects the state after applying any pending style changes"_ ([`getAnimations()`][wa1-getanim-src]). `document.getAnimations()` returns all of them — the use-case list pauses every animation on a page with one loop ([§ Use cases][wa1-usecases-src]).

### CSS Transitions and Animations as Web Animations

`interface CSSTransition : Animation { readonly attribute CSSOMString transitionProperty; }` and `interface CSSAnimation : Animation { readonly attribute CSSOMString animationName; }` ([Transitions 2][t2-csstransition-src], [Animations 2][a2-cssanimation-src]). They are ordinary `Animation`s with an _owning element_; markup-owned ones are never replaceable ([§ Removing replaced animations][wa1-removal-src]); a transition is not on the global animation list until script disassociates it and plays it ([Transitions 2, composite order][t2-composite-src]). Script edits pin parameters: after `effect.updateTiming({ duration })`, later `animation-duration` changes are ignored ([Animations 2][a2-override-src]). See [CSS Transitions and Animations][css-page].

### Level 2: progress-based timelines, group effects, custom effects

Level 2 is _"a delta specification, meaning that it currently contains only the differences from Web Animations Level 1"_ ([Level 2 § Delta specification][wa2-delta-src]). Its changes: _"group effects and sequence effects, an animation effect-specific playback rate, Support for non-monotonic (scroll) timelines"_ ([Changes][wa2-changes-src]). A timeline gains a **duration**; a non-monotonic one is a _progress-based timeline_ whose duration is 100% ([Level 2 § Timelines][wa2-timelines-src]), and `AnimationTimeline.currentTime` becomes a `CSSNumberish` — _"expressed as a percentage for a progress-based timeline, or as a double in milliseconds otherwise"_ ([`AnimationTimeline`][wa2-timeline-idl-src]). `Animation.overallProgress` is `min(max(current time / associated effect end, 0), 1)` ([§ Calculating the overall progress][wa2-progress-src]). Custom effects — an `EffectCallback(progress, currentTarget, animation)` called on each sample — are flagged exploratory: _"there are some concerns about the design of this feature and it may be replaced"_ ([Level 2 § EffectCallback][wa2-custom-src], [changes][wa2-changes-src]).

### FLIP on top of WAAPI

Paul Lewis's _FLIP Your Animations_ (aerotwist.com, 2015-02-11) names the technique: _"FLIP stands for First, Last, Invert, Play"_ — First is _"the initial state of the element(s) involved in the transition"_, Last _"the final state of the element(s)"_, Invert _"You figure out from the first and last how the element has changed"_, and Play _"switch on transitions for any of the properties you changed, and then remove the inversion changes"_ ([FLIP][flip]). Its budget argument: _"There is a window of 100ms after someone interacts with your site where you're able to do work without them noticing"_, which is spent on _"all that getBoundingClientRect work"_; its constraint: _"Animations that can be remapped to transform and opacity changes are the perfect fit"_ ([same][flip]). With WAAPI the Invert and Play steps are one keyframe effect:

```js
// FLIP with the Web Animations API
const first = el.getBoundingClientRect(); // F: geometry from the last layout
applyStateChange(); // DOM/class change that moves el
const last = el.getBoundingClientRect(); // L: forces a synchronous layout
const dx = first.left - last.left,
  dy = first.top - last.top;
const sx = first.width / last.width,
  sy = first.height / last.height;
el.animate(
  // I + P: start inverted, play to identity
  [
    {
      transformOrigin: 'top left',
      transform: `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})`,
    },
    { transformOrigin: 'top left', transform: 'none' },
  ],
  { duration: 300, easing: 'ease-out' },
);
```

Three properties of this are load-bearing. **First** is read in user code from the _last committed layout_ (`getBoundingClientRect` before the DOM change, which returns the geometry already laid out). **Last** is read in user code after the change, and the read _forces_ a synchronous style and layout pass. **Play** animates only `transform` (and optionally `opacity`), so the per-frame work needs no layout or paint and can be sampled on the compositor; the element's layout box is already at its final position from the first frame. Interrupting a FLIP means reading the _current visual_ rect (which includes the running transform) as the new First, cancelling, and inverting again — continuity of position, not of velocity.

---

## Analysis

### Where animation state lives

In UA-owned `Animation` objects: start time, hold time, playback rate (and pending rate), pending play/pause tasks, replace state, the `ready`/`finished` promises ([§ Animations][wa1-animations-src], [§ Replace state][wa1-replace-src]). The _effect value_ is not state: it is recomputed each animation frame from the timeline's time through a stateless pipeline ([§ Stateless][wa1-stateless-src]). Ordering state is the global animation list. Script holds references, not ownership; CSS-owned animations belong to their owning element.

### Declaring an animation

Explicit and imperative: `el.animate(keyframes, options)` or `new Animation(new KeyframeEffect(…), timeline)`, then `play`/`pause`/`reverse`/`finish`/`cancel`, `currentTime`/`startTime` seeking and `playbackRate`. The declarative front ends (CSS Transitions, implicit; CSS Animations, explicit) are defined as producers of the same objects. Implicit `from` keyframes make "animate to X from wherever it is" one call ([§ The effect value of a keyframe effect][wa1-implicit-src]).

### Time and the clock

A hierarchy of time: timeline → animation (offset by start time, scaled by playback rate, frozen by hold time) → effect (delay, iterations, direction, easing). The UA owns the document timeline and ticks it once per rendering update with the frame's `now`; the timeline does not advance between ticks ([§ Relationship to wall-clock time][wa1-wallclock-src]). Timelines are pluggable: Level 2 adds progress-based (scroll, view) timelines with no time at all, only percentages ([Level 2][wa2-timelines-src]).

### Interruption and retargeting

No built-in retarget: a new `animate()` call adds a new animation on top of the stack. Position continuity comes from the implicit offset-0 keyframe, which takes the **underlying value** — the composited output of the animations below, including the still-running old one ([§ The effect value of a keyframe effect][wa1-implicit-src]); the old one is auto-removed only once finished and covered ([§ Removing replaced animations][wa1-removal-src]). Velocity is not preserved by `replace`. `composite: 'add'` enables Core Animation-style **additive retargeting**: animate the _delta_ (old target − new target → 0) additively over a base already set to the new target, and overlapping additive animations sum, which smooths the velocity change ([§ Effect composition][wa1-composite-src]).

### Curves and springs

Duration plus easing, on the effect and per keyframe; easing functions are pure functions of progress ([CSS Easing][css-page]). No spring primitive, no velocity input, no physics integration in the model; a spring is a sampled `linear()` easing over a fixed duration. The stateless design is what precludes it: an integrator's output depends on its previous state, which the timing model refuses by construction ([§ Stateless][wa1-stateless-src]).

### Layout animation

The model animates computed values in the cascade, so `width`/`top` animations re-run layout each frame on the main thread. Animating layout _results_ needs FLIP, which is user code end to end: **First** and **Last** are geometry reads in script — First from the last committed layout, Last after a forced synchronous layout — and the **Play** phase is a transform animation that the UA can sample on the **compositor** without layout or paint ([FLIP][flip]; the separate-thread optimisation is a use case, [§ Use cases][wa1-usecases-src], and its synchronisation is why `ready` and the pending play task are asynchronous, [§ Playing an animation][wa1-pendingplay-src]). So FLIP needs the previous frame's geometry, reads it in user code, and plays on the compositor. View Transitions move the same First/Last capture into the UA ([Scroll-driven Animations and View Transitions][vt-page]).

### Enter and exit

Not applicable at the model level, because an effect's target is an element and the model says nothing about elements leaving the DOM; an animation on a removed element simply has nothing rendered. Exit is user code: animate, `await animation.finished`, then remove the node — the element stays in the tree (and in layout) through the exit. FLIP-style exits additionally take the element out of flow first (`position: absolute` at its First rect) so siblings can FLIP into the gap.

### Scheduling, reduced motion and testing

Animations are sampled once per animation frame of the HTML event loop ([§ Animation Frames][wa1-frame-src]); a document with no running animations needs no animation frames, and compositor-sampled ones need no main-thread frames. The model has no reduced-motion hook; authors query `matchMedia('(prefers-reduced-motion: reduce)')` ([Media Queries 5][mq5-prm]) and shorten or skip. Testing is where statelessness pays: pause an animation and set `currentTime` (or `startTime`), and the effect value is defined exactly at that time, independent of how many frames ran (_"Constant-time seeking"_, [§ Stateless][wa1-stateless-src]). The document timeline itself cannot be driven by script; virtual time is a test-harness feature, not a spec one.

### Lessons for sparkles:ui

- The timing model is the right shape for a `pure` per-frame build: effect value = f(frame time − start time, parameters). Storing only (start time, hold time, rate, parameters) per (identity, property) in the element store makes every frame reproducible and every test a seek.
- Statelessness and springs are in tension: a velocity-preserving spring needs integrator state. Either keep springs analytic (closed-form damped oscillator from (t, x0, v0), re-seeded at each retarget — still a pure function of time between retargets) or accept per-frame state in the store.
- Asynchronous `play()`/`ready` exists only because sampling may happen on another thread. If `sparkles:ui` samples everything on the frame thread, start times can be the frame's timestamp and the asynchrony disappears; if a GPU-side sampler is ever added, the same "start time resolves when the first frame is produced" rule is the precedent.
- FLIP maps directly onto UI-Q9: First is last frame's committed rect from the store; Last is this frame's layout result; the host — not the component — computes the inverse transform after layout and animates it at paint/compositing. No forced synchronous layout is needed, because the host already has both rects.
- Effect stacks with `add` are a clean way to let a retarget overlap the old motion instead of cancelling it; the store would keep a small list of active animations per (identity, property) and fold them at sample time, with WAAPI's auto-removal rule bounding the list.

---

## Strengths

- One model under every Web animation feature; CSS objects are inspectable and controllable from script.
- Stateless timing: frame-rate independent, direction-agnostic, constant-time seek, deterministic tests by seeking.
- Explicit composite order and composite operations, including additive animation.
- Pluggable timelines (document, scroll, view) without changing effects.
- Built-in leak control (replaceable animations) with explicit escapes (`persist`, `commitStyles`).

## Weaknesses

- No velocity-preserving retarget and no springs; continuity relies on implicit keyframes or hand-built additive deltas.
- Layout animation is left to user code (FLIP), which forces synchronous layout and is limited to transform/opacity to stay smooth.
- Fill modes and `commitStyles()` are a two-step dance to persist end states; computed values committed lose live dependencies (`em`, variables).
- Asynchronous `play()`/`ready` semantics complicate otherwise simple code, to accommodate threaded implementations.
- Level 2 group effects and custom effects remain unshipped or exploratory.

---

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                       | Trade-off                                                                     |
| ----------------------------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Stateless timing function from time to progress       | Frame-rate independence, seeking, reversal for free             | Excludes physics/integrator animations and velocity carry-over                |
| Hierarchical time (timeline → animation → effect)     | Pause, rate, offset and repeat compose; one timeline syncs many | Level 1 hierarchy is shallow; groups are a Level 2 delta                      |
| Effect stacks composited into a cascade origin        | Animations interoperate with style and with each other          | Composite order rules are intricate (class, owner, generation, list position) |
| Implicit keyframes from the underlying value          | "Animate to X" from the current visual value in one call        | Position continuity only; the stack grows until auto-removal                  |
| Asynchronous pending play task and `ready`            | Lets a compositor choose the real start time                    | Start time is unresolved right after `play()`; code must await `ready`        |
| Auto-removal of replaced, finished, script animations | Bounds memory for fire-and-forget `fill: forwards`              | Effects vanish unless `persist()`ed or `commitStyles()`ed                     |
| FLIP left to user code                                | No new primitive; works with any layout change                  | Synchronous layout reads; transform-only; interruption by re-measurement      |

---

## Sources

- Web Animations Level 1, editor's draft, [rendered][wa1-ed], [TR][wa1-tr], [source][wa1-src] (`web-animations-1/Overview.bs` at `9c7ee53`).
- Web Animations Level 2, [rendered][wa2-ed], [TR][wa2-tr], [source][wa2-src].
- CSS Transitions 2 [`CSSTransition`][t2-csstransition-src] and CSS Animations 2 [`CSSAnimation`][a2-cssanimation-src] interfaces.
- Paul Lewis, [_FLIP Your Animations_][flip], aerotwist.com, 2015-02-11.
- MDN, [Web Animations API][mdn-waapi] (secondary).

<!-- References -->

[repo]: https://github.com/w3c/csswg-drafts/tree/9c7ee53130057fa90efcc01c80e03478e87a9b9f
[license]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/LICENSE.md
[wa1-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs
[wa1-intro-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L224-L240
[wa1-usecases-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L242-L392
[wa1-stateless-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L546-L616
[wa1-hier-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L618-L641
[wa1-timevalue-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L643-L662
[wa1-timelines-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L664-L697
[wa1-doctimeline-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L699-L739
[wa1-wallclock-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L741-L760
[wa1-frame-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L762-L837
[wa1-animations-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L839-L905
[wa1-currenttime-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L907-L937
[wa1-ready-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L1179-L1229
[wa1-pendingplay-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L1400-L1438
[wa1-playbackrate-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L2112-L2130
[wa1-localtime-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L2566-L2585
[wa1-timespaces-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L2587-L2640
[wa1-fill-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L3024-L3068
[wa1-calc-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L3314-L3370
[wa1-implicit-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L4049-L4085
[wa1-stack-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L4315-L4346
[wa1-stackresult-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L4348-L4367
[wa1-composite-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L4369-L4405
[wa1-apply-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L4407-L4451
[wa1-replace-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L4453-L4504
[wa1-removal-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L4506-L4571
[wa1-commit-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L5030-L5112
[wa1-getanim-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L7004-L7031
[wa1-liveness-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-1/Overview.bs#L7225-L7243
[wa1-ed]: https://drafts.csswg.org/web-animations-1/#timing-model
[wa1-tr]: https://www.w3.org/TR/web-animations-1/
[wa2-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-2/Overview.bs
[wa2-delta-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-2/Overview.bs#L160-L165
[wa2-hier-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-2/Overview.bs#L178-L199
[wa2-timelines-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-2/Overview.bs#L203-L233
[wa2-progress-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-2/Overview.bs#L987-L1025
[wa2-timeline-idl-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-2/Overview.bs#L2364-L2390
[wa2-custom-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-2/Overview.bs#L3243-L3292
[wa2-changes-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-2/Overview.bs#L3449-L3464
[wa2-ed]: https://drafts.csswg.org/web-animations-2/#timelines
[wa2-tr]: https://www.w3.org/TR/web-animations-2/
[t2-csstransition-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs#L611-L621
[t2-composite-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs#L326-L384
[a2-cssanimation-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-2/Overview.bs#L984-L997
[a2-override-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-2/Overview.bs#L94-L162
[mq5-prm]: https://drafts.csswg.org/mediaqueries-5/#prefers-reduced-motion
[flip]: https://aerotwist.com/blog/flip-your-animations/
[mdn-waapi]: https://developer.mozilla.org/en-US/docs/Web/API/Web_Animations_API
[css-page]: ./css-transitions-and-animations.md
[vt-page]: ./scroll-and-view-transitions.md
