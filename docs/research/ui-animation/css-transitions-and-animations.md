# CSS Transitions and Animations (Web platform)

The Web's declarative animation layer: a CSS Transition animates a property from its value in the previous style change to its new value whenever the computed value changes, a CSS Animation plays a named `@keyframes` sequence while `animation-name` lists it, easing functions (`cubic-bezier()`, `steps()`, and `linear()` sampled curves) shape progress, and `prefers-reduced-motion` tells authors the user wants less of it all.

| Field                    | Value                                                                                                                                                                                                                                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | CSS (with a CSSOM/IDL surface: `TransitionEvent`, `AnimationEvent`, `CSSTransition`, `CSSAnimation`, `CSSStartingStyleRule`)                                                                                                                                                                |
| License                  | W3C Software and Document License ([`LICENSE.md`][license])                                                                                                                                                                                                                                 |
| Repository               | [w3c/csswg-drafts][repo]: [`css-transitions-1`][t1-src], [`css-transitions-2`][t2-src], [`css-animations-1`][a1-src], [`css-animations-2`][a2-src], [`css-easing-2`][e2-src], [`mediaqueries-5`][mq5-src]                                                                                   |
| Documentation            | [CSS Transitions 1][t1-ed] ([TR][t1-tr]) · [CSS Transitions 2][t2-ed] · [CSS Animations 1][a1-ed] ([TR][a1-tr]) · [CSS Animations 2][a2-ed] · [CSS Easing 2][e2-ed] ([Level 1][e1-ed]) · [Media Queries 5][mq5-ed] · MDN only as secondary ([`@starting-style`][mdn-starting-style])        |
| Category                 | declarative, style-driven animation: implicit (a computed-value change starts a transition) and explicit (a keyframe sequence named in style), both defined on top of the [Web Animations][wa-page] model                                                                                   |
| Versions surveyed        | Editor's drafts at `w3c/csswg-drafts` commit `9c7ee53` (2026-11-25): Transitions 1 (WD dated 2026-01-08 in its metadata), Transitions 2 (ED), Animations 1 (ED; last TR WD 2023-03-02), Animations 2 (ED), Easing 1/2 (ED; Easing 2 FPWD 2024-08-28), Media Queries 5 (WD dated 2026-02-19) |
| Animation state lives in | the user agent: one `CSSTransition` per (element, property) and one `CSSAnimation` per `animation-name` entry, owned by the element ("owning element"); the author's style holds only the _parameters_ (`transition-*`, `animation-*`), never the phase                                     |

> [!NOTE]
> This page covers the CSS surface. The timing model underneath it (timelines, start and hold times, the effect stack, `getAnimations()`) is on [Web Animations][wa-page]; timelines that are driven by scroll position instead of time, and the snapshot-based [View Transitions][vt-page], are on [Scroll-driven Animations and View Transitions][vt-page]. Every quote below was read from the spec source at commit `9c7ee53` and is linked to its line range there and to the rendered section.

---

## Overview

### What it solves

Before transitions, a property change was rendered instantly. The Transitions spec opens with the problem: _"Normally when the value of a CSS property changes, the rendered result is instantly updated, with the affected elements immediately changing from the old property value to the new property value. This section describes a way to specify gradual transitions using new CSS properties"_ ([§ Transitions][t1-transitions-src]). The defining move is that the animation is _implicit_: the author never says "animate now", only "when `opacity` changes, take 2 s", and any later change — a `:hover` match, a class toggle from script — animates.

CSS Animations solve the complementary case, a motion that is not a change between two styles: _"Keyframes are used to specify the values for the animating properties at various points during the animation. The keyframes specify the behavior of one cycle of the animation; the animation may iterate zero or more times"_ ([§ Declaring Keyframes][a1-keyframes-src]).

Both feed the CSS cascade rather than painting directly. _"Transitions are a presentational effect. The computed value of a property transitions over time from the old value to the new value. Therefore if a script queries the computed value of a property (or other data depending on it) as it is transitioning, it will see an intermediate value that represents the current animated value of the property"_ ([§ Transitions][t1-transitions-src]).

### Design philosophy

1. **Animation is a function of style change, not of a call.** A transition is started by the style engine comparing two snapshots of computed style; there is no imperative entry point at Level 1.
2. **The cascade is the arbiter.** Animations _"override all normal rules, but are overridden by !important rules"_ ([CSS Animations 1 § Model][a1-model-src]); CSS Transitions sit in their own, lower cascade origin ([Transitions 2 § Animation cascade level][t2-cascade-src]).
3. **Declarative so the UA can intervene.** The accessibility section argues for declarativeness as a mitigation hook: _"Providing a declarative mechanism has multiple effects: it makes such animations easier to make and thus likely to be more common, but it also makes it easier for user agents to modify those animations if such modifications are needed to meet a user's accessibility needs"_ ([§ Motion][t1-motion-src]).
4. **Easing is pure.** _"An easing function must be a pure function meaning that for a given set of inputs, it always produces the same output progress value"_ ([Easing 2 § Easing functions][e2-easing-src]).
5. **Level 2 re-expresses Level 1 as Web Animations objects.** Each running transition is a `CSSTransition : Animation`, each animation a `CSSAnimation : Animation`, so script can inspect, seek and pause them ([`CSSTransition`][t2-csstransition-src], [`CSSAnimation`][a2-cssanimation-src]).

---

## How it works

### Style change events, before-change and after-change style

The unit of time in Transitions is the _style change event_: _"This processing of a set of simultaneous style changes is called a style change event. (Implementations typically have a style change event to correspond with their desired screen refresh rate, and when up-to-date computed style or layout information is needed for a script API that depends on it.)"_ ([§ Starting of transitions][t1-sce-src]). The spec deliberately leaves _when_ one happens unspecified, and warns that changing a transition property shortly after a change _"can result in behavior that varies between implementations"_ ([same][t1-sce-src]).

At each style change event the UA compares two computed styles per element ([§ Starting of transitions][t1-before-after-src]):

> _"define the **before-change style** as the computed values of all properties on the element as of the previous style change event, except with any styles derived from declarative animations such as CSS Transitions, CSS Animations ([CSS3-ANIMATIONS]), and SMIL Animations ([SMIL-ANIMATION], [SVG11]) updated to the current time. Likewise, define the **after-change style** as the computed values of all properties on the element based on the information known at the start of that style change event, but using the computed values of the 'animation-\*' properties from the before-change style, excluding any styles from CSS Transitions in the computation, and inheriting from the after-change style of the parent."_

So the _from_ value is last frame's committed (and already animated) style, and the _to_ value is this frame's style minus transitions. An element that was not in the document at the previous style change event has no before-change style, and no transition starts: _"If an element is not in the document during that style change event or was not in the document during the previous style change event, then transitions are not started for that element"_ ([same][t1-before-after-src]).

```css
/* css-transitions-1: each transition-* list is matched by index */
div {
  transition-property: opacity, left;
  transition-duration: 2s, 4s;
}
```

### Interrupting a running transition: the reversing shortening factor

When the after-change value differs from the end value of a running transition on the same property, the running transition is cancelled and replaced ([§ Starting of transitions, the running-transition rules][t1-retarget-src]). Three cases:

- the current animated value already equals the new target, or the values are not transitionable → cancel, no new transition;
- the new target equals the old transition's **reversing-adjusted start value** (the user went back) → start a _shortened_ reverse transition;
- otherwise → start a fresh transition from the **current value** with the full `transition-duration` and the full timing function.

The reversal case is the only interruption rule that looks at how far the old transition got. Its new duration is scaled by the _reversing shortening factor_:

> _"reversing shortening factor is the absolute value, clamped to the range [0, 1], of the sum of: the output of the timing function of the old transition at the time of the style change event, times the reversing shortening factor of the old transition; 1 minus the reversing shortening factor of the old transition."_ — with the note _"This represents the portion of the space between the reversing-adjusted start value and the end value that the old transition has traversed (in amounts of the value, not time)"_ ([§ Starting of transitions][t1-retarget-src])

and the new end time is _"the start time plus the product of the matching transition duration and the new transition's reversing shortening factor"_. The non-normative "Faster reversing" section says why: a hover-out that takes the full duration to travel a shortened distance is _"distractingly asymmetric […] Instead, this specification makes second transition shorter"_, and records two limits — _"these rules do not fully address the problem for transition patterns that involve more than two states"_ and _"these rules lead to the entire timing function of the new transition being used, rather than jumping into the middle of a timing function"_ ([§ Faster reversing][t1-reversing-src]). Level 2 pins the factor to the transition itself, not its effect, so it survives a script replacing the effect ([Transitions 2 § Faster reversing][t2-reversing-src]).

Nothing in either rule carries velocity: the new transition starts at the old one's current _value_ and restarts its easing curve from progress 0.

### `transition-behavior: allow-discrete` and `@starting-style` (Level 2)

Level 1 transitions only interpolable values and only elements with a before-change style. Level 2 removes both limits.

`transition-behavior` (`normal | allow-discrete`): _"When normal is specified, transitions will not be started for discrete properties, only for interpolable properties. When allow-discrete is specified, transitions will be started for discrete properties as well as interpolable properties"_ ([Transitions 2 § transition-behavior][t2-behavior-src]). The property this unlocks is `display`, whose interpolation is special-cased: _"during interpolation between none and any other 'display' value, p values between 0 and 1 map to the non-none value"_ ([CSS Display 4 § Animating display][display-anim-src]) — so an element transitioning to `display: none` stays rendered for the whole duration and flips at the end.

`@starting-style` supplies a before-change style where there is none: _"The style rules inside it are used to establish styles to transition from, if the previous style change event did not establish a before-change style for the element whose styles are being computed"_; _"Define starting style for an element as the after-change style with @starting-style rules applied in addition"_ ([Transitions 2 § @starting-style][t2-starting-src]). The spec's own enter/exit example:

```css
/* css-transitions-2 @starting-style example: fade in on insertion or display:none → block, fade out before display:none */
#target {
  transition-property: opacity, display;
  transition-duration: 0.5s;
  display: block;
  opacity: 1;
  @starting-style {
    opacity: 0;
  }
}
#target.hidden {
  display: none;
  opacity: 0;
}
```

with the explanation _"The display is transitioning to allow for an opacity transition before flipping from display:block to display:none"_ ([same][t2-starting-src]). (Real use also needs `transition-behavior: allow-discrete`, or `display` is not transitioned.)

Level 2 also states what happens to a transition whose element goes away: _"implementations must also cancel any running transitions on elements that are no longer being rendered and remove transitions on them from the set of completed transitions"_, on top of cancelling those no longer connected ([Transitions 2 § Starting of transitions][t2-owning-src]).

### CSS Animations: `@keyframes` and `animation-*`

```css
/* css-animations-2, the animation-composition example (abridged) */
@keyframes heartbeat {
  from {
    scale: 1;
    animation-timing-function: ease-out;
  }
  30% {
    scale: 1.3;
  }
}
.heartbeat {
  animation: heartbeat 0.3s 2s infinite;
}
```

An animation runs while its name is listed: _"Once an animation has started it continues until it ends or the 'animation-name' is removed"_; its start time is _"the time at which the style applying the animation and the corresponding @keyframes rule are both resolved"_ ([CSS Animations 1 § Model][a1-model-src]). The longhands are `animation-name`, `-duration`, `-timing-function`, `-iteration-count`, `-direction`, `-play-state`, `-delay`, `-fill-mode`; Level 2 adds `animation-composition`, `animation-timeline` (filled in by [Scroll-driven Animations][vt-page]) and splits the delay into `animation-delay-start`/`-end` ([Animations 2 headings][a2-src]).

`animation-composition` (`replace | add | accumulate`) exposes the Web Animations composite operation per animation, or per keyframe: _"When specified in a keyframe, 'animation-composition' defines the composite operation to use for each property specified in that keyframe until the next keyframe specifying each property"_ ([Animations 2 § animation-composition][a2-composition-src]). With `add`, a `throb` animation on `scale` stacks on top of `heartbeat` instead of replacing it.

Events: transitions fire `transitionrun`, `transitionstart`, `transitionend`, `transitioncancel` ([Transitions 1 § Transition Events][t1-events]); animations fire `animationstart`, `animationiteration`, `animationend`, `animationcancel`, dispatched at the owning element by comparing the effect's phase across frames ([Animations 2 § Event dispatch][a2-events-src]).

Script wins over style once it touches a `CSSAnimation`: _"After a successful call to setKeyframes() […] any subsequent change to matching @keyframes rules […] will not be reflected in that animation"_, and after `play()`/`pause()` _"any subsequent change to the 'animation-play-state' will no longer cause the CSSAnimation to be played or paused"_ ([Animations 2 § Animations][a2-override-src]).

### Ordering: composite order and cascade level

Transitions composite below animations: _"CSS Transitions have an earlier composite order that CSS Animations and animations without a specific animation class"_ ([Transitions 2 § Animation composite order][t2-composite-src]); within transitions the order is owning-element tree order, then _transition generation_ (a counter _"incremented on each style change event"_, [§ current transition generation][t2-generation-src]), then property name. CSS Animations order by tree order and then by position in `animation-name` ([Animations 2 § Animation composite order][a2-composite-src]). A transition with an owning element applies at the cascade's Transitions level; once script disassociates it, at the Animations level ([Transitions 2 § Animation cascade level][t2-cascade-src]).

### Easing functions

An easing function maps an _input progress value_ to an _output progress value_, both in [−∞, ∞] because they chain (an effect's easing feeds a keyframe's) ([Easing 2 § Easing functions][e2-easing-src]). Level 1 defines `linear`, `cubic-bezier()` (and `ease`, `ease-in`, `ease-out`, `ease-in-out`) and `steps()` ([Easing 1][e1-ed]). Level 2 adds `linear()`, a piecewise-linear function over _control points_: _"A linear easing function is an easing function that interpolates linearly between its control points. Each control point is a pair of numbers, associating an input progress value to an output progress value"_ ([§ Linear easing functions][e2-linear-src]). Its stated purpose is sampled curves: _"A typical use of linear() is to provide many points to create the illusion of a curve"_, with a bounce as the example ([§ Linear easing function examples][e2-bounce-src]):

```css
/* css-easing-2 linear() example: a reusable bounce as sampled points */
:root {
  --bounce: linear(
    0,
    0.063,
    0.25,
    0.563,
    1 36.4%,
    0.812,
    0.75,
    0.813,
    1 72.7%,
    0.953,
    0.938,
    0.953,
    1 90.9%,
    0.984,
    1 100% 100%
  );
}
.example {
  animation-timing-function: var(--bounce);
}
```

A spring in CSS is the same trick: an author (or a generator) samples a damped-spring solution offline and emits it as `linear()` points plus a duration. The spec has no `spring()` function — the word does not occur in either Easing level ([Easing 2 source][e2-src]).

### `prefers-reduced-motion`

_"The 'prefers-reduced-motion' media feature is used to detect if the user has requested the system minimize the amount of non-essential motion it uses"_; `reduce` _"Indicates that user has notified the system that they prefer an interface that removes or replaces the types of motion-based animation that either trigger discomfort for those with vestibular motion sensitivity, or distraction for those with attention deficits"_ ([Media Queries 5 § prefers-reduced-motion][mq5-prm-src]). It is a query, not a switch: the author writes `@media (prefers-reduced-motion: reduce) { … }`. Transitions 1 separately permits UAs to disable or slow animations, and asks them to keep firing events if they do: _"implementations of such mitigations may wish to fire transition events even if the transitions were not run as continuous animations"_ ([§ Motion][t1-motion-src]).

---

## Analysis

### Where animation state lives

In the user agent, keyed by (owning element, property) for transitions and (owning element, `animation-name` index) for animations. The author's style holds parameters only; the phase, start time and reversing data live in a `CSSTransition`/`CSSAnimation` object ([Transitions 2 § Starting of transitions][t2-owning-src]). The comparison that starts a transition needs one piece of retained per-element state — the **before-change style**, i.e. last style change event's computed values ([§ Starting of transitions][t1-before-after-src]). That is precisely "last frame's committed values, read by the engine, not written by the author", which is the [`sparkles:ui`][ui-authoring] element store's contract.

### Declaring an animation

Transitions are **implicit and declarative**: a value change animates; there is no call. CSS Animations are **explicit and declarative**: listing a name in `animation-name` starts the keyframe sequence, removing it stops it. Neither has a controller at the CSS level; Level 2 exposes both as Web Animations objects for imperative control ([Animations 2 § Animations][a2-override-src]).

### Time and the clock

The UA owns the clock. A transition's start time is _"the time of the style change event plus the matching transition delay"_ ([§ Starting of transitions][t1-retarget-src]); the frame on which style changes is UA-chosen (_"this specification does not define when a style change event occurs"_, [§ Starting of transitions][t1-sce-src]). Underneath, both run on the document's default timeline ([Web Animations][wa-page]); `animation-timeline` can swap that for a scroll or view timeline ([Animations 2][a2-timeline-src], [Scroll-driven Animations][vt-page]).

### Interruption and retargeting

Retargeting is defined, velocity is not preserved. A change mid-flight cancels the running transition and starts a new one from the **current value** with the full duration and a fresh easing curve, unless the new target is the old start, in which case the duration is shortened by the reversing shortening factor ([§ Starting of transitions][t1-retarget-src], [§ Faster reversing][t1-reversing-src]). The spec admits the scheme is a two-state heuristic. Additive behaviour is available only for animations, through `animation-composition: add | accumulate` ([Animations 2][a2-composition-src]); transitions always `replace`.

### Curves and springs

Duration plus easing. Springs are not a primitive: `linear()` lets a sampled spring (or bounce) curve be expressed, but the duration is still fixed by `transition-duration`/`animation-duration`, the curve is a pure function of progress ([Easing 2 § Easing functions][e2-easing-src]), and there is no input for initial velocity — so an interrupted "spring" restarts from rest.

### Layout animation

Transitions and animations interpolate **computed values**; geometry animates only if the animated property is geometric (`width`, `top`, `margin`, …) and then layout re-runs every frame with the interpolated input. No previous-frame _layout_ geometry is involved — only last style change's computed style — and values that are not transitionable (Level 1 treats `auto` that way) cancel instead ([§ Starting of transitions][t1-retarget-src]). Phase: **style**, then layout and paint as normal, on the main thread; for `transform` and `opacity` implementations may run the sampled animation on a compositor thread, which the spec allows but does not mandate (CSS Animations make the UA treat animated properties as in `will-change`, [Animations 1 § Model][a1-model-src]; the "separate thread" optimisation is named in the Web Animations use cases, see [Web Animations][wa-page]). A change of position caused by layout elsewhere (a sibling removed) is not a computed-value change and does not transition: that gap is what [FLIP][wa-page] and [View Transitions][vt-page] fill.

### Enter and exit

Enter: `@starting-style` provides the from-state for an element with no before-change style ([Transitions 2 § @starting-style][t2-starting-src]). Exit: there is no exit for a removed node — a transition on an element no longer connected or no longer rendered is cancelled ([Transitions 2 § Starting of transitions][t2-owning-src]). The exit idiom is a **closing state that keeps the element in the tree**: the author switches it to `display: none` (or a `.hidden` class) with `transition-behavior: allow-discrete`, the `display` value holds at the non-`none` value for p in (0, 1) ([CSS Display 4 § Animating display][display-anim-src]), the element keeps painting and laying out, and it is removed from the DOM only after `transitionend`. That is "the store drives a closing state" (UI-Q10), not a retained snapshot.

### Scheduling, reduced motion and testing

Scheduling is the UA's: transitions start in style change events, which implementations align with the refresh rate ([§ Starting of transitions][t1-sce-src]); while nothing animates, no frames are needed. Reduced motion is an author-side media query ([Media Queries 5][mq5-prm-src]), plus permission for UAs to suppress or slow animation while still firing events ([§ Motion][t1-motion-src]) — and the cascade lets a user style sheet set `transition: none` ([§ Cascade][t1-motion-src]). CSS itself has no virtual clock; deterministic tests go through the Level 2 objects (`getAnimations()`, `pause()`, setting `currentTime`) described on [Web Animations][wa-page].

### Lessons for sparkles:ui

- The before-change/after-change pair is a direct model for implicit animation in a per-frame rebuild: the store keeps last frame's committed style value per (identity, property); when this frame's built value differs, the host starts an interpolation. Components stay pure — they only emit the target and the `transition` parameters.
- "No before-change style ⇒ no transition" falls out of identity set difference: a new identity has no store entry. `@starting-style` is the explicit escape — a per-element "from" value used only on the first frame an identity appears.
- CSS's exit story requires the element to stay built. For `sparkles:ui` that means a closing phase in the store keyed by the removed identity, which the host — not the component — keeps building (or painting) until the transition ends; CSS shows the cost: the element still takes layout space unless it is also taken out of flow.
- The reversing shortening factor is a cheap, stateless-enough improvement over naive restart, but it neither preserves velocity nor handles three-way changes; a spring integrator in the store that carries velocity solves both.
- `linear()` is a useful _serialisation_ for curves computed elsewhere: a spring can be sampled once into points and evaluated as a pure function of progress, which keeps the per-frame path `@nogc` and deterministic.

---

## Strengths

- Zero-code implicit animation: any computed-value change, from any source, animates.
- Precise, testable start rule (before-change vs after-change style) and a defined interruption rule, including shortened reversal.
- Level 2 closes the enter/exit gap for in-tree elements (`@starting-style`, `allow-discrete`, `display` interpolation).
- Everything is a Web Animations object underneath, so it is inspectable and seekable from script.
- Declarative form lets UAs and users mitigate motion through the cascade and `prefers-reduced-motion`.

## Weaknesses

- No velocity continuity on retarget; easing restarts from zero progress.
- No physical springs; `linear()` approximations have a fixed duration.
- Layout-induced movement (siblings reflowing) does not transition at all.
- No exit for removed nodes; the author must defer removal until `transitionend`.
- The timing of style change events is unspecified, so "change then change again" behaves differently between engines.

---

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                        | Trade-off                                                                                       |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Transitions start from a before-change/after-change style diff     | Any style change animates with no API; one rule covers hover, classes and script | Needs retained per-element style; elements without one (new, `display: none`) cannot transition |
| Interruption restarts from the current value, full duration        | Simple and stateless apart from the current value                                | Velocity discontinuity; asymmetric timings                                                      |
| Reversing shortening factor for return-to-start                    | Fixes the commonest two-state case (hover in/out)                                | Heuristic; does not cover multi-state changes; still restarts easing                            |
| `@starting-style` instead of "transition from initial value"       | Authors pick the entry state explicitly, cascade-integrated                      | A separate rule set that applies only on the first style of an element                          |
| `display` stays non-`none` during interpolation (`allow-discrete`) | Exit animations without script while the element remains in the DOM              | Element keeps occupying layout during exit; removal still script-driven                         |
| Easing as pure function of progress; `linear()` for sampled curves | Frame-rate independent, compositor-friendly, constant-time seek                  | Springs only as fixed-duration approximations, no velocity input                                |
| Reduced motion as a media query                                    | Authors choose what to replace; cascade remains the user's lever                 | No default behaviour: sites that ignore the query keep full motion                              |

---

## Sources

- CSS Transitions Module Level 1, editor's draft, [rendered][t1-ed], [TR][t1-tr], [source][t1-src] (`css-transitions-1/Overview.bs` at `9c7ee53`).
- CSS Transitions Module Level 2, [rendered][t2-ed], [source][t2-src].
- CSS Animations Level 1, [rendered][a1-ed], [TR][a1-tr], [source][a1-src]; Level 2, [rendered][a2-ed], [source][a2-src].
- CSS Easing Functions Level 1 [rendered][e1-ed]; Level 2 [rendered][e2-ed], [source][e2-src].
- Media Queries Level 5, [rendered §prefers-reduced-motion][mq5-ed], [source][mq5-prm-src].
- CSS Display Level 4, [Animating and interpolating `display`][display-anim-ed] ([source][display-anim-src]).
- MDN, [`@starting-style`][mdn-starting-style] (secondary).

<!-- References -->

[repo]: https://github.com/w3c/csswg-drafts/tree/9c7ee53130057fa90efcc01c80e03478e87a9b9f
[license]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/LICENSE.md
[t1-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-1/Overview.bs
[t1-transitions-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-1/Overview.bs#L149-L168
[t1-sce-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-1/Overview.bs#L640-L673
[t1-before-after-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-1/Overview.bs#L675-L704
[t1-retarget-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-1/Overview.bs#L868-L998
[t1-reversing-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-1/Overview.bs#L1106-L1145
[t1-motion-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-1/Overview.bs#L1516-L1552
[t1-ed]: https://drafts.csswg.org/css-transitions-1/#starting
[t1-tr]: https://www.w3.org/TR/css-transitions-1/
[t1-events]: https://drafts.csswg.org/css-transitions-1/#transition-events
[t2-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs
[t2-behavior-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs#L124-L148
[t2-owning-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs#L159-L184
[t2-reversing-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs#L186-L194
[t2-generation-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs#L196-L203
[t2-starting-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs#L205-L311
[t2-composite-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs#L326-L384
[t2-cascade-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs#L386-L395
[t2-csstransition-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-transitions-2/Overview.bs#L611-L621
[t2-ed]: https://drafts.csswg.org/css-transitions-2/#defining-before-change-style
[a1-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-1/Overview.bs
[a1-model-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-1/Overview.bs#L84-L130
[a1-keyframes-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-1/Overview.bs#L196-L216
[a1-ed]: https://drafts.csswg.org/css-animations-1/#animations
[a1-tr]: https://www.w3.org/TR/css-animations-1/
[a2-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-2/Overview.bs
[a2-override-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-2/Overview.bs#L94-L162
[a2-composite-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-2/Overview.bs#L220-L260
[a2-composition-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-2/Overview.bs#L613-L660
[a2-timeline-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-2/Overview.bs#L703-L730
[a2-events-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-2/Overview.bs#L800-L830
[a2-cssanimation-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-2/Overview.bs#L984-L997
[a2-ed]: https://drafts.csswg.org/css-animations-2/#animation-composition
[e1-ed]: https://drafts.csswg.org/css-easing-1/#easing-functions
[e2-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-easing-2/Overview.bs
[e2-easing-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-easing-2/Overview.bs#L131-L165
[e2-linear-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-easing-2/Overview.bs#L205-L240
[e2-bounce-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-easing-2/Overview.bs#L515-L540
[e2-ed]: https://drafts.csswg.org/css-easing-2/#the-linear-easing-function
[mq5-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/mediaqueries-5/Overview.bs
[mq5-prm-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/mediaqueries-5/Overview.bs#L2898-L2926
[mq5-ed]: https://drafts.csswg.org/mediaqueries-5/#prefers-reduced-motion
[display-anim-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-display-4/Overview.bs#L1228-L1243
[display-anim-ed]: https://drafts.csswg.org/css-display-4/#display-animation
[mdn-starting-style]: https://developer.mozilla.org/en-US/docs/Web/CSS/@starting-style
[wa-page]: ./web-animations.md
[vt-page]: ./scroll-and-view-transitions.md
[ui-authoring]: ../ui-authoring/index.md
