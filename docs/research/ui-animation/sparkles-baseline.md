# Sparkles baseline — what animates in `sparkles:ui` today

The system this survey informs: [`sparkles:ui`](../../libs/ui/index.md) and its
host, `sparkles:ui-app`. This page states what already moves, where its state
lives, who supplies the time, and how a frame is asked for — the facts the
[comparison](./comparison.md) measures the surveyed systems against.

**Last reviewed:** November 26, 2026

|                          |                                                                                                                                                                                           |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Toolkit**              | [`sparkles:ui`](../../libs/ui/index.md): components as pure per-frame functions over `const` state ([UI-Q1][ui-decisions])                                                                |
| **Animation primitives** | none general; three hand-written integrators (`ScrollMotion`, `ScrollbarAnim`, the dock's pane bars) and a frame-counted spinner                                                          |
| **State lives in**       | the application's or the component's own struct, stepped in place; `ElementStore` holds scroll state                                                                                      |
| **Time source**          | a `dt` in seconds the caller passes to `step`/`animate`; `0` on a target with no frame clock                                                                                              |
| **Frame requests**       | `HostState.requestFrame` (one more frame, re-asked every frame) and `wakeIn` (a deadline)                                                                                                 |
| **Reduced motion**       | `TargetCapabilities.reducedMotion` (`ACC5`); honoured by `ScrollMotion.instant` only where a consumer sets it                                                                             |
| **Specs**                | [`SCV12`, `SCV13`][containers] (scroll motion, overlay bar), [`LYR10`][popup] (a closing overlay paints without hits), [`WGT5`][widgets] (animation phase lives in the per-element store) |

## What moves today

| Motion                                | Type                                               | State                                                               | Integrator                                                                                     | Ends                                 |
| ------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------ |
| Smooth scroll, wheel or key           | [`ScrollMotion`][scroll-motion] (`SCV12`)          | `pos`, `target`, `velocity`, `mode`                                 | critically damped spring, **solved exactly over the step** ([`step`][scroll-motion-step])      | `abs(x) < 0.01` → `settle()`         |
| Fling                                 | `ScrollMotion`                                     | same                                                                | exponential decay, `velocity *= exp(-flingFriction * dt)`                                      | below `minFlingSpeed`, or at an edge |
| Scrollbar hover-expand and touch fade | [`ScrollbarAnim`][scrollbar-anim] (`SCV13`)        | `percent`, `visible`                                                | forward-Euler ease, `percent += (target - percent) * 15 * dt`, then clamped                    | clamp at 0 or 100                    |
| Scroll body (motion plus fade)        | [`ScrollBody.animate`][scroll-body-animate]        | owns a `ScrollMotion` and an `OverlayBar`                           | composes the two; returns `true` _"while the motion or the fade needs the next"_ frame         | both idle                            |
| Dock pane bars and capture autoscroll | [`Dock.tickScroll`][dock-tick]                     | the dock's own arrays                                               | per-pane `dt` step                                                                             | no capture                           |
| Spinner                               | [`spinnerFrame`][spinner] (`progress.d`)           | a caller-held `size_t frame`                                        | a glyph per frame, cycling every 10                                                            | never (the caller stops asking)      |
| Overlay exit                          | [`OverlaySpec.closing`][overlay-closing] (`LYR10`) | a `bool` the **component** sets while it keeps building the overlay | none in the toolkit: the application runs the fade and stops building the overlay when it ends | the application stops building it    |

`ScrollMotion`'s header states the design:

> _"The easing is a critically damped spring, the shape Neovide scrolls with: it
> reaches its target in about `springSeconds` without overshooting, and a new
> notch moves the target without throwing the velocity away, so notches in quick
> succession add up to one smooth glide."_ ([`scroll_motion.d`][scroll-motion])

That one sentence already holds three of the survey's findings: a spring rather
than a duration, retargeting that keeps velocity (what [SwiftUI](./swiftui.md),
[Compose](./jetpack-compose.md) and [Motion](./react-motion-and-spring.md) do by
default), and the exact closed-form step (_"solved exactly over the step, so a
long frame cannot overshoot"_), which makes the result independent of the frame
rate. `ScrollbarAnim` has none of these: its Euler step changes with `dt`, and a
frame longer than 1/15 s overshoots and is caught only by the clamp.

## Where the state lives

There is no single answer yet, which is the gap this survey addresses:

- **In the component's own struct, stepped in place.** `ScrollBody`, `ScrollView`
  and `DocViewPane` hold their motion as fields and mutate it in `animate(dt)`. The
  application owns the struct and calls `animate` before the frame's view.
- **In an [`ElementStore`][element-store]**, for scroll state keyed by element
  identity (`WGT5`): _"scroll offsets, focus and animation phase survive a view
  rebuild because **identity** — not equality — decides which element is "the
  same one" across frames."_ Today a view _"steps the state it `require`s"_ through
  a `ref`, so the view writes the store. The component-authoring decisions
  ([UI-Q5][ui-decisions]) move this to a store the component reads and the host
  commits after layout, which forbids that write.
- **[`ElementStore.retain`][element-store-retain]** sweeps every entry whose
  element is not in the new tree. An element's presentation state therefore dies
  in the frame the element is first not built — exactly when an exit animation
  would need it ([UI-Q10][pr775]).

## Who owns the clock

The toolkit never reads a clock. Every integrator takes `dt` from its caller;
`easeVertical` in the gallery documents the convention: _"`dtSeconds` of zero
means the target has no frame clock — a terminal wakes on input"_
([`scrollbars.d`][gallery-scrollbars]). The host has two time facts it could hand
the view but does not yet:

- **[`FrameStart.target`][frame-start]**, the predicted presentation time of the
  frame being built (`OPL13`–`OPL17`). Sampling an animation at the frame's
  presentation time rather than at its start is what Compose's frame clock
  (_"normalized to the target time for the frame"_) and Core Animation's display
  link do ([Compose](./jetpack-compose.md#time-and-the-clock),
  [Core Animation](./core-animation.md#time-and-the-clock)).
- **The recorder** ([`record.d`][record]) drives an application from a script
  with no window (`TST1`–`TST3`) and records each `requestFrame`. It is the
  natural home for a virtual clock, which it does not have yet.

## How a frame is asked for

[`HostState.requestFrame`][request-frame] is the only animation hook the host has,
and its contract is the one the survey recommends:

> _"It is a **request for one frame**, not a mode: a continuing animation asks
> again each time, so a finished one stops costing anything without having to
> remember to turn itself off."_

Every integrator above returns a `bool` "still moving" for its caller to turn
into that request, the shape egui's `animate_bool` gives automatically
([immediate mode](./immediate-mode.md#scheduling-reduced-motion-and-testing)). The
terminal arm blocks on input and wakes on a request or on
[`wakeIn`][wake-in], so an idle terminal costs nothing.

## Gaps the survey measures

| Capability                                  | Status today                                                                                   |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| A general value animation (tween or spring) | ✗ — each motion is hand-written                                                                |
| Animation as data, sampled at a time        | ✗ — every integrator mutates state by `dt`                                                     |
| Frame-rate independence                     | ✓ `ScrollMotion` (exact step); ✗ `ScrollbarAnim` (Euler)                                       |
| Retargeting keeps velocity                  | ✓ `ScrollMotion.nudge`; n/a elsewhere                                                          |
| Presentation state keyed by identity        | ✓ `ElementStore` (`WGT5`), but written by the view                                             |
| Exit animation                              | partial — `LYR10` paints a closing overlay; the application drives the fade and the unbuild    |
| Layout (geometry) animation                 | ✗                                                                                              |
| Reduced motion                              | partial — `reducedMotion` is a capability; only `ScrollMotion.instant` honours it, set by hand |
| Deterministic time in tests                 | partial — `dt` is an argument, so a unit test passes one; no virtual clock in the recorder     |
| Frames only while animating                 | ✓ `requestFrame` is one-shot by contract                                                       |

## Sources

- [`libs/ui/src/sparkles/ui/scroll_motion.d`][scroll-motion] — `ScrollMotion`, `MotionMode`, `step`, `nudge`, `fling`
- [`libs/ui/src/sparkles/ui/components/scroll_view.d`][scrollbar-anim] — `ScrollbarAnim`, `stepFade`, `fading`
- [`libs/ui/src/sparkles/ui/components/scroll_body.d`][scroll-body-animate] — `ScrollBody.animate`
- [`libs/ui/src/sparkles/ui/components/dock.d`][dock-tick] — `tickScroll`
- [`libs/ui/src/sparkles/ui/components/progress.d`][spinner] — `spinnerFrame`
- [`libs/ui/src/sparkles/ui/state.d`][element-store] — `ElementStore`, `require`, `retain`
- [`libs/ui/src/sparkles/ui/overlay/arena.d`][overlay-closing] — `OverlaySpec.closing`
- [`libs/ui/src/sparkles/ui/tokens.d`][tokens] — `TargetCapabilities.reducedMotion`
- [`libs/ui-app/src/sparkles/ui_app/host.d`][request-frame] — `requestFrame`, `wakeIn`
- [`libs/ui-app/src/sparkles/ui_app/frame_schedule.d`][frame-start] — `FrameStart`
- [`libs/ui-app/src/sparkles/ui_app/record.d`][record] — the recording host
- [`apps/ui-gallery/src/scrollbars.d`][gallery-scrollbars] — `easeVertical`
- Specs: [containers][containers] (`SCV12`, `SCV13`), [popup][popup] (`LYR10`), [widgets][widgets] (`WGT5`); decisions [UI-Q1–UI-Q7][ui-decisions]; open questions UI-Q9 and UI-Q10 in [PR #775][pr775]

<!-- References -->

[scroll-motion]: ../../../libs/ui/src/sparkles/ui/scroll_motion.d
[scroll-motion-step]: ../../../libs/ui/src/sparkles/ui/scroll_motion.d
[scrollbar-anim]: ../../../libs/ui/src/sparkles/ui/components/scroll_view.d
[scroll-body-animate]: ../../../libs/ui/src/sparkles/ui/components/scroll_body.d
[dock-tick]: ../../../libs/ui/src/sparkles/ui/components/dock.d
[spinner]: ../../../libs/ui/src/sparkles/ui/components/progress.d
[element-store]: ../../../libs/ui/src/sparkles/ui/state.d
[element-store-retain]: ../../../libs/ui/src/sparkles/ui/state.d
[overlay-closing]: ../../../libs/ui/src/sparkles/ui/overlay/arena.d
[tokens]: ../../../libs/ui/src/sparkles/ui/tokens.d
[request-frame]: ../../../libs/ui-app/src/sparkles/ui_app/host.d
[wake-in]: ../../../libs/ui-app/src/sparkles/ui_app/host.d
[frame-start]: ../../../libs/ui-app/src/sparkles/ui_app/frame_schedule.d
[record]: ../../../libs/ui-app/src/sparkles/ui_app/record.d
[gallery-scrollbars]: ../../../apps/ui-gallery/src/scrollbars.d
[containers]: ../../specs/ui/containers.md
[popup]: ../../specs/ui/popup.md
[widgets]: ../../specs/ui/widgets.md
[ui-decisions]: ../ui-authoring/index.md#decisions
[pr775]: https://github.com/PetarKirov/sparkles/pull/775
