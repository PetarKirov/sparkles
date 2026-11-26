# Scroll-driven Animations and View Transitions (Web platform)

Two extensions of the Web Animations model that replace its inputs: Scroll-driven Animations swap the time source for a scroll position (`ScrollTimeline`, `ViewTimeline`, `animation-timeline`, `animation-range`), so progress is a percentage and no clock is involved; View Transitions swap the _targets_ for UA-generated pseudo-elements that paint a raster snapshot of the old DOM and a live capture of the new one, so the DOM can change instantly while the visual change animates — including elements that no longer exist.

| Field                    | Value                                                                                                                                                                                                                                                                                                                                          |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | CSS (`animation-timeline`, `scroll()`, `view()`, `animation-range`, `view-transition-name`, `view-transition-class`, `@view-transition`, `::view-transition-*`) and WebIDL (`ScrollTimeline`, `ViewTimeline`, `document.startViewTransition`, `ViewTransition`)                                                                                |
| License                  | W3C Software and Document License ([`LICENSE.md`][license])                                                                                                                                                                                                                                                                                    |
| Repository               | [w3c/csswg-drafts][repo]: [`scroll-animations-1`][sa-src], [`css-view-transitions-1`][vt1-src], [`css-view-transitions-2`][vt2-src]                                                                                                                                                                                                            |
| Documentation            | [Scroll-driven Animations][sa-ed] ([TR][sa-tr]) · [CSS View Transitions 1][vt1-ed] ([TR][vt1-tr]) · [CSS View Transitions 2][vt2-ed] ([TR][vt2-tr]) · MDN only as secondary ([View Transition API][mdn-vt], [scroll-driven animations][mdn-sda])                                                                                               |
| Category                 | Scroll-driven: progress-based timelines feeding ordinary keyframe effects. View Transitions: UA-captured snapshots of the previous frame, animated by CSS Animations on a pseudo-element tree above the page                                                                                                                                   |
| Versions surveyed        | `w3c/csswg-drafts` commit `9c7ee53` (2026-11-25): Scroll-driven Animations ED (last TR WD 2023-04-28), View Transitions 1 ED (FPWD 2022-10-25; last CRD 2024-03-28), View Transitions 2 ED (last TR WD 2024-05-16)                                                                                                                             |
| Animation state lives in | Scroll-driven: the scroll offset of a scroll container (the timeline _is_ the scroll position); the `Animation` objects are ordinary. View Transitions: the UA's `ViewTransition` object — its _named elements_ map of captured elements (old image, old geometry, new element), the pseudo-element tree, and the CSS Animations running on it |

> [!NOTE]
> The underlying timing model, effect stacks and FLIP are on [Web Animations][wa-page]; the CSS animation front ends that drive both features here are on [CSS Transitions and Animations][css-page]. Quotes are verbatim from the Bikeshed sources at commit `9c7ee53`, linked to line ranges, with the rendered section alongside.

---

## Overview

### What it solves

**Scroll-driven Animations** let a scroll position drive animation progress without script on every scroll event: _"These scroll-driven animations use a timeline based on scroll position, rather than one based on clock time. This module provides both an imperative API building on the Web Animations API as well as a declarative API building on CSS Animations"_ ([§ Introduction][sa-intro-src]). It is explicitly about progress, not triggering: _"Scroll-driven animations, whose progress is linked to the scroll position, are distinct from scroll-triggered animations, which are triggered by a scroll position, but whose progress is driven by time"_ ([same][sa-intro-src]).

**View Transitions** solve the problem that animating between two DOM states used to require both states to be in the DOM at once ([§ Separating Visual Transitions from DOM Updates][vt1-separating-src]):

> _"Traditionally, creating a visual transition between two document states required a period where both states were present in the DOM at the same time. […] This extra in-between state often resulted in UX and accessibility issues, as the structure of the DOM was compromised for a purely-visual effect. View Transitions avoid this troublesome in-between state by allowing the DOM to switch between states instantaneously, then performing a customizable visual transition between the two states in another layer, using a static visual capture of the old state, and a live capture of the new state."_

### Design philosophy

1. **Replace the input, keep the model.** Scroll-driven Animations _"extend the Web Animations model by defining scroll-driven timelines"_ ([§ Relationship to other specifications][sa-otherspecs-src]); View Transitions animate pseudo-elements with ordinary CSS Animations and Web Animations ([§ View Transition Customization][vt1-customizing-src]).
2. **Compatible with off-main-thread scrolling.** _"this specification allows expressing scroll-driven effects in a way that does not require script to run each time the effect is sampled. User agents that support asynchronous scrolling are allowed (but not required) to sample such effects asynchronously as well"_ ([§ Relationship to asynchronous scrolling][sa-async-src]).
3. **A transition is an enhancement, never a gate.** _"an animated transition is a visual enhancement to an underlying document state change. That means a failure to create a visual transition […] will not prevent the developer's ViewTransitionUpdateCallback being called"_ ([§ Transitions as an enhancement][vt1-enhancement-src]).
4. **Visual identity is a name, not a node.** Two elements with the same `view-transition-name` in the old and new states _"are treated as representing different visual state of the same element […] it is a useful model to consider them to be visual states of the same conceptual page entity"_ ([`view-transition-name`][vt1-name-src]).

---

## How it works: Scroll-driven Animations

### Scroll progress timelines

_"Scroll progress timelines are timelines linked to progress in the scroll position of a scroll container along a scrollable axis. The startmost scroll position represents 0% progress and the endmost scroll position represents 100% progress"_ ([§ Scroll Progress Timelines][sa-scroll-src]). Progress is a ratio, not a time: _"scroll offset ÷ (scrollable overflow size − scroll container size)"_, and a zero denominator makes the timeline inactive ([§ Calculating Progress][sa-scroll-src]). In script it is `new ScrollTimeline({ source, axis })` with `axis` one of `block`, `inline`, `x`, `y` ([`ScrollTimeline`][sa-scrolltimeline-src]); in CSS it is anonymous `scroll()` or a named `scroll-timeline`. Web Animations Level 2 supplies the model change: a non-monotonic timeline is a _progress-based timeline_ whose duration is 100%, and `currentTime` is _"expressed as a percentage for a progress-based timeline"_ ([Web Animations 2 § Timelines][wa2-timelines-src], [`AnimationTimeline`][wa2-timeline-idl-src]).

### View progress timelines

_"View progress timelines are segments of a scroll progress timeline that are scoped to the scroll positions in which any part of the subject element's principal box intersects its nearest ancestor scrollport"_ ([§ View Progress Timelines][sa-view-src]). They define named ranges — `cover`, `contain`, `entry`, `exit`, `entry-crossing`, `exit-crossing` ([§ View Progress Timeline Ranges][sa-ranges-src]) — and in script are `new ViewTimeline({ subject, axis, inset })` ([`ViewTimeline`][sa-viewtimeline-src]).

### Attaching animations: `animation-timeline`, `animation-range`

`animation-timeline` (from CSS Animations 2) takes `auto`, `none`, a timeline name, `scroll()` or `view()` ([`animation-timeline`][a2-timeline-src]). `animation-range` clips the animation's active interval to part of the timeline: _"animation-range: entry 10% exit 90%"_ expands to `animation-range-start: entry 10%; animation-range-end: exit 90%` ([`animation-range`][sa-range-src]). The spec's reveal example ([examples][sa-range-examples-src]):

```css
/* scroll-animations-1: each child fades in as it enters the scrollport */
@keyframes reveal {
  from {
    opacity: 0;
  }
}
.scroller > * {
  animation: reveal linear both;
  animation-timeline: view();
  animation-range: entry;
}
```

Durations become proportions of a finite range: _"Unlike time-driven timelines, scroll-driven timelines are finite, thus scroll-driven animations are always attached to a finite attachment range […] If the specified duration is auto, then the remaining range is divided by its iteration count"_ ([§ Finite Timeline Calculations][sa-finite-src]).

### When a scroll timeline is sampled

Scroll-driven effects can move layout, and layout can move scroll, so the spec pins the sample point ([§ HTML Processing Model: Event loop][sa-frames-src]):

> _"To avoid such layout cycles, animations with a scroll progress timeline update their current time once during step 7.10 of the HTML Processing Model event loop, as step 1 of update animations and send events."_

Timelines created during style and layout are _stale_ and get one extra style/layout round in the same frame, to avoid _"an undesirable initial "flash""_. The compositor may run ahead: _"If a user agent normally composites frames where scrolling has occurred but the consequences of scrolling have not been fully propagated in layout or script […] the user agent may likewise choose not to sample scroll-driven animations for that composited frame"_ ([same][sa-frames-src]).

---

## How it works: View Transitions

### The lifecycle

`document.startViewTransition(updateCallback)` returns a `ViewTransition` and runs ([§ View Transition Lifecycle][vt1-lifecycle-src]):

1. _"Current state captured as the "old" state."_
2. _"Rendering paused."_
3. the update callback runs and changes the DOM; `updateCallbackDone` fulfils;
4. _"Current state captured as the "new" state."_
5. _"Transition pseudo-elements created."_
6. _"Rendering unpaused, revealing the transition pseudo-elements."_; `ready` fulfils;
7. _"Pseudo-elements animate until finished."_; they are removed; `finished` fulfils.

Normatively, _setup view transition_ flushes pending update callbacks, captures the old state, sets the document's _rendering suppression for view transitions_ flag, schedules the update callback, and on its completion clears the flag and captures the new state ([§ Setup view transition][vt1-setup-src]). A second `startViewTransition` while one is active skips the first with an `AbortError` — there is no retargeting between view transitions ([`startViewTransition()` steps][vt1-start-src]).

### Capturing the old state: a raster snapshot

_Capture the old state_ walks every connected element in paint order, collects those with a `view-transition-name` (failing the whole transition on a duplicate name), and for each records ([§ Capture the old state][vt1-capture-old-src]):

- its **old image** — _"the result of capturing the image of element"_;
- its **old width/height** (border box) and **old transform** — _"a transform-function that would map element's border box from the snapshot containing block origin to its current visual position"_;
- a few computed values (`writing-mode`, `direction`, `text-orientation`, `mix-blend-mode`, `backdrop-filter`, `color-scheme`).

_Capture the image_ renders the element and its descendants onto a transparent canvas and returns the ink-overflow area as an image whose natural size is the border box ([§ Capture the image][vt1-capture-image-src]). The `::view-transition-old()` pseudo-element is _"an empty named view transition pseudo-element that represents a visual snapshot of the "old" state as a replaced element"_ ([§ ::view-transition-old()][vt1-old-src]), styled with `object-*` like an `img`. The old element may be gone from the DOM by the time it paints — the snapshot is a bitmap plus a recorded rect, not a reference to the node.

### Capturing the new state: a live capture

_Capture the new state_ records only the **new element** reference for each name ([§ Capture the new state][vt1-capture-new-src]). Its image is re-captured every frame: _update pseudo-element styles_ sets the `::view-transition-new()` replaced content _"to the result of capturing the image of capturedElement's new element"_ and copies its current geometry into the group's styles ([§ Update pseudo-element styles][vt1-update-styles-src]). So "old" is frozen and "new" is live. The original elements do not paint in place while the transition animates: _"the boxes generated by any element in that Document with captured in a view transition […] are not painted (as if they had opacity: 0) and do not respond to hit-testing"_ ([§ View Transition Painting Order][vt1-painting-src]).

### The pseudo-element tree

```text
::view-transition
├─ ::view-transition-group(name)
│  └─ ::view-transition-image-pair(name)
│     ├─ ::view-transition-old(name)
│     └─ ::view-transition-new(name)
└─ …other groups…
```

([§ View Transition Pseudo-elements][vt1-pseudos-src]). The root has the name `root` via the UA style sheet. Either image is absent when there is no old or new state — that absence is how entry-only and exit-only names are expressed. The tree paints in a new _view transition layer_ _"after all other content of the document (including any content rendered in the top layer)"_ ([§ View Transition Painting Order][vt1-painting-src]).

### The default animation is generated CSS

_Setup transition pseudo-elements_ writes rules into a per-document _dynamic view transition style sheet_ ([§ Setup transition pseudo-elements][vt1-setup-pseudos-src]):

- old only (exit): `::view-transition-old(name) { animation-name: -ua-view-transition-fade-out; }`;
- new only (entry): `::view-transition-new(name) { animation-name: -ua-view-transition-fade-in; }`;
- both: a group keyframes rule with **only a `from`** frame —

```css
/* css-view-transitions-1, setup transition pseudo-elements (variables substituted at runtime) */
@keyframes -ua-view-transition-group-anim-NAME {
  from {
    transform: OLD-TRANSFORM;
    width: OLD-WIDTH;
    height: OLD-HEIGHT;
    backdrop-filter: OLD-BACKDROP-FILTER;
  }
}
```

— so the implicit `to` frame is the group's current style, which _update pseudo-element styles_ keeps equal to the new element's live geometry; plus a cross-fade of old and new with `mix-blend-mode: plus-lighter`. The UA sheet sets `animation-duration: 0.25s` on groups and inherits timing down the tree ([§ User Agent Stylesheet][vt1-ua-src]). If the new element moves mid-transition a new keyframe is generated, and the spec accepts the jump: _"a change in incoming element's size or position will cause a new keyframe to be generated. This can cause a visual jump. We could retarget smoothly but don't have a use-case to justify the complexity"_ ([§ Handle transition frame][vt1-frame-src]). The transition ends when no animation on the pseudo-tree is running or paused ([same][vt1-frame-src]).

### Level 2: cross-document, classes, types, scoped

Level 2 adds _"Cross-document view transitions, including the @view-transition rule"_, selective transitions by type, `view-transition-class`, nested groups and scoped (element-rooted) transitions ([Level 2 updates][vt2-l2-src]).

- **Cross-document**: a same-origin, user-initiated navigation transitions when both documents opt in with `@view-transition { navigation: auto; }` ([`@view-transition`][vt2-rule-src]); the old document's last frame stays up while the new one is render-blocked — _"overusing the render-blocking mechanism could make it so that the old state remains frozen for a long time"_ ([§ Waiting for the new state to stabilize][vt2-crossdoc-src]).
- **`view-transition-class`**: shared styling for many names, `::view-transition-group(*.any-box)`; it _"doesn't mark an element for capturing"_ ([`view-transition-class`][vt2-class-src]).
- **Types**: `startViewTransition({ update, types })`, a mutable `ViewTransitionTypeSet`, and `:active-view-transition-type(…)` on the root to select per-type styles ([API][vt2-start-src], [types][vt2-typeset-src], [pseudo-class][vt2-typepseudo-src]).
- **Scoped**: _"individual elements can host their own scoped view transitions. This enables multiple view transitions to run on a page at the same time"_, under automatic layout containment ([§ Scoped View Transitions][vt2-scoped-src]).
- **`view-transition-name: auto`** generates names (from `id` when present) ([§ Determining view-transition-name automatically][vt2-auto-src]).

```js
// same-document view transition with a type
const vt = document.startViewTransition({
  update: () => list.removeChild(item), // DOM changes at once
  types: ['delete'],
});
await vt.finished;
```

```css
li {
  view-transition-name: auto;
  view-transition-class: row;
}
:root:active-view-transition-type(delete)::view-transition-old(
    *.row
  ):only-child {
  animation: 200ms ease-in both shrink-out; /* the removed row's snapshot */
}
```

---

## Analysis

### Where animation state lives

Scroll-driven: in the scroll offset; the timeline holds no state of its own beyond its source, axis and computed ranges, and the attached `Animation` is ordinary ([§ Scroll Progress Timelines][sa-scroll-src]). View Transitions: in the `ViewTransition` — the _named elements_ map, keyed by `view-transition-name`, of captured elements holding the old image, old geometry and the new element ([§ Capture the old state][vt1-capture-old-src]), plus the pseudo-element tree and the CSS Animations on it. The map is keyed by **name**, a stable identity chosen by the author, not by DOM node.

### Declaring an animation

Scroll-driven: declarative and explicit (an `@keyframes` plus `animation-timeline: view()`), or imperative via `new ScrollTimeline` in `animate()`. View Transitions: an imperative trigger (`startViewTransition(update)`) or a declarative one for navigations (`@view-transition`), with a default animation that is _implicit_ — every named element's geometry change and cross-fade animates without being described ([§ Setup transition pseudo-elements][vt1-setup-pseudos-src]) — and customised declaratively via `::view-transition-*` selectors.

### Time and the clock

Scroll-driven: no time. The timeline is a progress-based timeline whose value is a percentage of the scroll range; durations are proportions; the scroll position — the user, or the compositor's async scroll — is the clock ([Web Animations 2][wa2-timelines-src], [§ Finite Timeline Calculations][sa-finite-src]). The UA samples once per frame at a defined step and may skip sampling on compositor-only frames ([§ HTML Processing Model: Event loop][sa-frames-src]). View Transitions: the pseudo-elements' animations run on the document timeline, with a UA default of 0.25 s ([§ User Agent Stylesheet][vt1-ua-src]); between old capture and new capture, rendering is suppressed, so the page's own clock-driven painting pauses.

### Interruption and retargeting

Scroll-driven: no interruption — reversing the scroll reverses progress, a direct consequence of the stateless timing model. View Transitions: none. A new `startViewTransition` skips the active one ([steps][vt1-start-src]); a moving new element regenerates keyframes and may jump, and the spec declines smooth retargeting for lack of a use case ([§ Handle transition frame][vt1-frame-src]). Velocity is never carried.

### Curves and springs

Both reuse CSS easing. For scroll-driven animations easing applies to scroll progress (`linear` is the usual choice so the effect tracks the finger). View Transitions use `animation-timing-function` on the pseudo-elements; springs only as sampled `linear()` ([CSS Easing][css-page]).

### Layout animation

View Transitions are UA-implemented FLIP. First is captured from the **previous rendered frame** — the old image and the old border-box geometry and transform of every named element ([§ Capture the old state][vt1-capture-old-src]); Last is the new element's live geometry after the DOM update and layout, refreshed every frame ([§ Update pseudo-element styles][vt1-update-styles-src]); the animation interpolates the group's `transform`, `width` and `height` from the old values to the new ones ([§ Setup transition pseudo-elements][vt1-setup-pseudos-src]). Phase: capture happens in the rendering update (paint output for the image, layout output for the rect); the group's `width`/`height` animation re-lays-out the pseudo-elements each frame, while the image transforms and cross-fade are compositable. So it **needs the previous frame's geometry and pixels**, but it obtains them in the UA, not in user code — unlike [FLIP][wa-page]. Scroll-driven animations animate whatever the keyframes say, like CSS Animations; their timeline needs the current layout's scroll range and view ranges, recomputed in the frame's style/layout step ([§ HTML Processing Model: Event loop][sa-frames-src]).

### Enter and exit

View Transitions are the platform's answer to exit animation of removed content. An element with a `view-transition-name` in the old state and none in the new produces a group with only `::view-transition-old()`, which keeps painting the **raster snapshot** — with the element's recorded geometry — while the live DOM has already changed, and fades out by default ([§ Setup transition pseudo-elements][vt1-setup-pseudos-src], [§ ::view-transition-old()][vt1-old-src]). The element itself can be gone: the snapshot is a replaced-element bitmap, so it neither lays out in the page nor receives events (the view transition tree _"is not exposed to the accessibility tree"_, [§ View Transition Pseudo-elements][vt1-pseudos-src]). Entry is the symmetric case, a `::view-transition-new()` alone, fading in. The cost is that the old content is frozen pixels: it cannot reflow, animate internally or respond while it exits. Scroll-driven animations have no enter/exit concept beyond the `entry`/`exit` view ranges, which describe scroll geometry, not tree membership.

### Scheduling, reduced motion and testing

Scroll-driven: samples only when the scroll position or ranges change, and are designed to need no script per sample ([§ Relationship to asynchronous scrolling][sa-async-src]). View Transitions: frames run only while a pseudo-element animation runs; the transition is torn down when none remain ([§ Handle transition frame][vt1-frame-src]); `skipTransition()` skips the animation but still runs the update. Neither spec mentions `prefers-reduced-motion` — a search of both sources finds no reference — so reduced motion is the author's `@media (prefers-reduced-motion: reduce)` rule, e.g. disabling the `::view-transition-*` animations, which still leaves the instant DOM change because a transition is an enhancement ([§ Transitions as an enhancement][vt1-enhancement-src]). Testing: scroll-driven state is a function of scroll offset, so a test scrolls to a position and reads styles; view transitions are tested through their promises (`updateCallbackDone`, `ready`, `finished`) and, since the pseudo-element animations are Web Animations, by `document.getAnimations()` and seeking.

### Lessons for sparkles:ui

- **UI-Q10 answer, platform version**: keep painting a removed element from a _retained snapshot_ keyed by a stable identity, captured before the frame that removes it. In `sparkles:ui`, the host can do this without a bitmap: last frame's display list (or retained draw ops) for the removed identity's subtree, plus its last committed rect from the store, is the "old image". It costs no rebuild of the removed component and keeps components pure.
- The snapshot's limits are inherent: frozen content, no hit testing, no internal animation. A "closing state" in the store (the CSS `allow-discrete` model) is the alternative when the exiting element must stay interactive or keep animating internally.
- **UI-Q9 answer, platform version**: layout animation via old-rect → new-rect needs last frame's committed geometry, read by the host after layout, not by components. View Transitions show the UA can own FLIP entirely; `sparkles:ui`'s host is in the same position, having both rects without a forced layout.
- Pairing by name, not node, maps onto keyed identity: an element moved between parents in the tree keeps its key, so the host can pair old and new by identity as View Transitions pair by `view-transition-name`.
- Scroll timelines show that progress-based timelines plug into a stateless timing model for free; in `sparkles:ui` the store's scroll offset (already presentation state) can be such a timeline, sampled after layout so the range is current — the one-sample-per-frame rule avoids the layout cycle the spec describes.

---

## Strengths

- Scroll-driven: scroll-linked effects with no per-scroll script, compatible with compositor scrolling; reversible by construction.
- View Transitions: exit and shared-element animations without keeping old DOM alive; the DOM changes atomically and accessibly.
- View Transitions reuse CSS Animations and Web Animations entirely; the default is generated CSS that authors override.
- Name-based pairing works across containers and, in Level 2, across documents.

## Weaknesses

- View Transitions' old state is frozen pixels; text reflow and internal animation of exiting content are impossible.
- No retargeting: a new view transition aborts the running one; moving targets jump.
- Global view transitions suppress rendering while the update callback runs; slow updates freeze the page.
- Duplicate names abort the transition; every participant needs a unique name (Level 2's `auto` mitigates).
- Neither spec handles reduced motion; it is entirely author responsibility.
- Scroll-driven sampling can lag async scroll on compositor-only frames.

---

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                          | Trade-off                                                                     |
| --------------------------------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| Scroll position as a progress-based timeline (percent, no time) | Reuses keyframe effects; stateless; compositor-sampleable          | Durations become proportions; delays and iterations need reinterpretation     |
| Sample scroll timelines once per frame at a fixed step          | Breaks the scroll ↔ layout cycle                                   | A stale timeline needs an extra style/layout pass; async scroll may outrun it |
| Old state as a raster snapshot, new state as a live capture     | DOM switches instantly; old content needs no DOM to exit           | Old content is frozen; memory for snapshots; size limits fail the transition  |
| Pairing by `view-transition-name`                               | Shared-element transitions across containers and documents         | Names must be unique per frame or the whole transition aborts                 |
| Default animation is generated `from`-only keyframes            | `to` tracks the live new geometry; authors override with plain CSS | Changing new geometry regenerates keyframes and can jump                      |
| Transition as enhancement; update always runs                   | Failure never blocks state change                                  | No coordination of concurrent updates; left to frameworks                     |
| Pseudo-tree in a top layer above all content (global VTs)       | Avoids clipping by old/new containers                              | Ignores page clipping/z-order; Level 2 scoped VTs needed for in-flow effects  |

---

## Sources

- Scroll-driven Animations, editor's draft, [rendered][sa-ed], [TR][sa-tr], [source][sa-src] (`scroll-animations-1/Overview.bs` at `9c7ee53`).
- CSS View Transitions Module Level 1, [rendered][vt1-ed], [TR][vt1-tr], [source][vt1-src].
- CSS View Transitions Module Level 2, [rendered][vt2-ed], [TR][vt2-tr], [source][vt2-src].
- Web Animations Level 2, [progress-based timelines][wa2-timelines-src] and [`AnimationTimeline`][wa2-timeline-idl-src].
- CSS Animations Level 2, [`animation-timeline`][a2-timeline-src].
- MDN, [View Transition API][mdn-vt] and [CSS scroll-driven animations][mdn-sda] (secondary).

<!-- References -->

[repo]: https://github.com/w3c/csswg-drafts/tree/9c7ee53130057fa90efcc01c80e03478e87a9b9f
[license]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/LICENSE.md
[sa-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs
[sa-intro-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L86-L109
[sa-otherspecs-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L111-L135
[sa-async-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L137-L146
[sa-scroll-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L164-L194
[sa-scrolltimeline-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L359-L380
[sa-view-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L607-L636
[sa-ranges-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L638-L700
[sa-viewtimeline-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L816-L840
[sa-finite-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L1081-L1119
[sa-frames-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L1226-L1290
[sa-range-examples-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L1442-L1468
[sa-range-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/scroll-animations-1/Overview.bs#L1553-L1580
[sa-ed]: https://drafts.csswg.org/scroll-animations-1/#scroll-timelines
[sa-tr]: https://www.w3.org/TR/scroll-animations-1/
[vt1-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs
[vt1-separating-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L133-L154
[vt1-customizing-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L156-L168
[vt1-lifecycle-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L170-L201
[vt1-enhancement-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L233-L260
[vt1-name-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L509-L560
[vt1-pseudos-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L604-L648
[vt1-old-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L740-L759
[vt1-painting-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L816-L847
[vt1-ua-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L849-L937
[vt1-start-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L968-L999
[vt1-setup-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L1254-L1330
[vt1-capture-old-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L1332-L1425
[vt1-capture-new-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L1427-L1465
[vt1-setup-pseudos-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L1467-L1611
[vt1-capture-image-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L1734-L1791
[vt1-frame-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L1823-L1864
[vt1-update-styles-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-1/Overview.bs#L1866-L1956
[vt1-ed]: https://drafts.csswg.org/css-view-transitions-1/#lifecycle
[vt1-tr]: https://www.w3.org/TR/css-view-transitions-1/
[vt2-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-2/Overview.bs
[vt2-l2-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-2/Overview.bs#L123-L136
[vt2-start-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-2/Overview.bs#L526-L572
[vt2-typeset-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-2/Overview.bs#L839-L850
[vt2-scoped-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-2/Overview.bs#L1160-L1179
[vt2-crossdoc-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-2/Overview.bs#L1624-L1685
[vt2-rule-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-2/Overview.bs#L1888-L1941
[vt2-typepseudo-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-2/Overview.bs#L2026-L2039
[vt2-class-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-2/Overview.bs#L2119-L2153
[vt2-auto-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-view-transitions-2/Overview.bs#L2197-L2207
[vt2-ed]: https://drafts.csswg.org/css-view-transitions-2/#cross-document-view-transitions
[vt2-tr]: https://www.w3.org/TR/css-view-transitions-2/
[wa2-timelines-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-2/Overview.bs#L203-L233
[wa2-timeline-idl-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/web-animations-2/Overview.bs#L2364-L2390
[a2-timeline-src]: https://github.com/w3c/csswg-drafts/blob/9c7ee53130057fa90efcc01c80e03478e87a9b9f/css-animations-2/Overview.bs#L703-L730
[mdn-vt]: https://developer.mozilla.org/en-US/docs/Web/API/View_Transition_API
[mdn-sda]: https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_scroll-driven_animations
[wa-page]: ./web-animations.md
[css-page]: ./css-transitions-and-animations.md
