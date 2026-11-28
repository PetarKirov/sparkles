# UI Animation: How Interfaces Express Motion

A breadth-first survey of **how UI systems express animation** — retained
frameworks, the web platform, Apple's and Google's toolkits, the React and
Svelte libraries, functional reactive programming, immediate-mode GUIs,
terminal UIs and animation engines. It informs two designs:
[`sparkles:ui`](../../libs/ui/index.md), whose components are pure per-frame
functions over `const` state with presentation state in an identity-keyed
element store ([decisions UI-Q1–UI-Q7][ui-decisions]), and the
`sparkles:reactive` effort surveyed in the [reactive-programming
catalog][reactive]. Animation was the problem FRP was invented for —
Elliott and Hudak's _Functional Reactive Animation_ (1997) — so the survey
connects the two in [FRP](./frp.md) and [comparison § FRP and
animation][cmp-frp].

Every deep-dive answers the same nine questions in the same order (the
[analysis spine][cmp-spine]): where animation state lives, how an animation is
declared, where time comes from, what an interruption does, curves and
springs, layout animation, enter and exit, scheduling with reduced motion and
testing, and what `sparkles:ui` can take from it.

This survey answers eight questions:

1. **Where does an animation's state live, and who writes it?** — the
   [master catalog](#master-catalog) and [comparison § Where animation state
   lives][cmp-state].
2. **Is animation declared as a target or driven by a controller, and is it
   implicit?** — [comparison § Declaring][cmp-declaring].
3. **Who owns the clock, and is the value computed in closed form?** —
   [comparison § Time and the clock][cmp-time] and [concepts § Closed form and
   stepped integration][c-closed].
4. **What happens when the target changes mid-flight?** — [comparison §
   Interruption][cmp-interrupt].
5. **How is geometry animated, which mechanisms need last frame's geometry, and
   in which phase do they run?** (UI-Q9) — [comparison § Layout animation and
   UI-Q9][cmp-q9].
6. **How does a removed element keep painting through its exit?** (UI-Q10) —
   [comparison § Enter, exit and UI-Q10][cmp-q10].
7. **Can an animated view stay a pure function of state and time, and how is it
   tested?** — [comparison § Purity, scheduling and testing][cmp-purity].
8. **What could `sparkles:ui` adopt?** — [comparison § Candidate
   designs][cmp-designs] (analysis, not decision), against the
   [baseline](./sparkles-baseline.md).

The shared vocabulary is defined once in [concepts](./concepts.md).

**Last reviewed:** November 26, 2026

> [!NOTE]
> Authored-timeline engines for video — Manim, Motion Canvas, Theatre.js,
> Remotion — are covered by the [mathematical-animation catalog][manim]. This
> survey covers animation inside interactive interfaces, and treats authored
> timelines only where a UI runtime plays them ([engines and
> tools](./engines-and-tools.md)).

---

## Master catalog

| Subject                                       | Ecosystem          | Category                         | Versions surveyed                                                                                   | Animation state lives in                                     | Link                             |
| --------------------------------------------- | ------------------ | -------------------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | -------------------------------- |
| Flutter                                       | Dart               | retained framework               | 3.47.4 @ `9584c67` (2026-09-10)                                                                     | `AnimationController` in a `State` or `RenderObject`         | [flutter]                        |
| Jetpack Compose                               | Kotlin             | retained framework (recomposing) | Compose 1.14.0-alpha02 @ `296313a4` (2026-11-21)                                                    | remembered holders in the slot table; `Modifier.Node`s       | [jetpack-compose]                |
| SwiftUI                                       | Swift              | retained framework (declarative) | Apple documentation as of 2026-11-26 (iOS 13–18 APIs)                                               | the attribute graph, per view identity                       | [swiftui]                        |
| Core Animation                                | Objective-C/Swift  | compositor (render server)       | Apple documentation as of 2026-11-26; Programming Guide (2015-03-09)                                | `CAAnimation`s in the render server; presentation tree       | [core-animation]                 |
| CSS Transitions & Animations                  | Web platform       | style-level declarative          | csswg-drafts @ `9c7ee531` (2026-11-25)                                                              | the UA's `CSSTransition`/`CSSAnimation` per element          | [css-transitions-and-animations] |
| Web Animations                                | Web platform       | timing model + imperative API    | Web Animations 1 ED, 2 WD (2025-11-20) @ `9c7ee531`                                                 | `Animation` objects; stateless effects                       | [web-animations]                 |
| Scroll-driven & View Transitions              | Web platform       | progress timelines; snapshots    | scroll-animations-1 ED, css-view-transitions-1/2 ED @ `9c7ee531`                                    | the scroll offset; the `ViewTransition`'s named-element map  | [scroll-and-view-transitions]    |
| Motion, React Spring                          | TypeScript (React) | animation libraries              | Motion 14.14.0 @ `1fa0e14`; React Spring 11.0.0-beta.3 @ `f005007` (2026-11)                        | `MotionValue`s, `SpringValue`s outside React state           | [react-motion-and-spring]        |
| Svelte                                        | Svelte 5           | compiler directives + runtime    | 5.59.2 @ `f076077` (2026-11-25)                                                                     | transition managers on the runtime's effects                 | [svelte]                         |
| Fran, Yampa, Elm, Reflex                      | Haskell, Elm       | functional reactive              | Fran 1.16; Yampa 0.15.1; `elm/browser` 1.0.2, elm-animation 2.0.0, elm-animator; Reflex @ `f443526` | the behaviour value; the signal function; the `Model`        | [frp]                            |
| Dear ImGui, egui, Clay, Nuklear, microui, Gio | C, C++, Rust, Go   | immediate mode                   | ImGui @ `bd4e3b0`; egui 0.37.0 @ `90431d9`; Clay @ `e6cc369`; Gio @ `9816a10`                       | per-id storage (egui, Clay), context scalars, caller structs | [immediate-mode]                 |
| Bubble Tea + harmonica, Textual, tachyonfx    | Go, Python, Rust   | terminal UIs                     | harmonica @ `0ff76e4`; Textual 8.2.8 @ `5e5b7ef`; tachyonfx 0.25.2 @ `dac4d28`                      | the application model; Textual's `Animator`                  | [terminal-uis]                   |
| Godot, Rive, Lottie, GSAP                     | C++, JSON, JS      | engines and motion tools         | Godot @ `8f2e46b`; rive-runtime @ `c355fea`; lottie-spec @ `4b55957`; GSAP 3.15.1                   | `Tween`s, state-machine instances, a frame number, timelines | [engines-and-tools]              |
| `sparkles:ui` today                           | D                  | the system under design          | `main`, 2026-11-26                                                                                  | component structs stepped by `dt`; `ElementStore` for scroll | [sparkles-baseline]              |

The full per-dimension table — clock, retargeting, springs, layout phase and
exit mechanism for every system — is [comparison § At a glance][cmp-glance].

---

## Taxonomy

### By where animation state lives

| Home                                     | Subjects                                                                                                                                                       |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A controller object the program holds    | [flutter], [jetpack-compose] (`Animatable`), [web-animations], [core-animation] (`UIViewPropertyAnimator`), [engines-and-tools] (GSAP, Godot)                  |
| The application's model                  | [frp] (Elm, Yampa), [terminal-uis] (Bubble Tea), [sparkles-baseline]                                                                                           |
| Per-identity storage the framework keeps | [swiftui], [jetpack-compose], [css-transitions-and-animations], [immediate-mode] (egui, Clay), [react-motion-and-spring], [svelte], [engines-and-tools] (Rive) |
| A compositor or render server            | [core-animation], [web-animations] (compositor path), [scroll-and-view-transitions]                                                                            |

### By when a layout animation runs

| Phase                                | Subjects                                                                                                                                                                                         |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| User or library code around a commit | [web-animations] (FLIP), [react-motion-and-spring] (Motion `layout`), [svelte] (`animate:`), [engines-and-tools] (GSAP `Flip`), [frp] (Elm)                                                      |
| The build, from last frame's size    | [immediate-mode] (egui `CollapsingHeader`)                                                                                                                                                       |
| Layout                               | [jetpack-compose] (lookahead, `animateContentSize`, `animateItem`), [flutter] (`RenderAnimatedSize`), [immediate-mode] (Clay's two passes), [engines-and-tools] (Rive), [terminal-uis] (Textual) |
| After layout, before or at composite | [swiftui], [core-animation], [scroll-and-view-transitions] (View Transitions), [flutter] (`Hero`)                                                                                                |
| None                                 | [css-transitions-and-animations] (a layout-induced move does not animate), Dear ImGui, Nuklear, microui, Lottie, Godot                                                                           |

### By what keeps an exiting element on screen

| Kept                                       | Subjects                                                                                                                                                                  |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The description, re-run by the framework   | [swiftui], [jetpack-compose] (`AnimatedVisibility`, `AnimatedContent`), [flutter] (`AnimatedSwitcher`), [react-motion-and-spring], [svelte]                               |
| A closing state the program keeps building | [immediate-mode] (egui), [css-transitions-and-animations] (`allow-discrete`), [frp], [terminal-uis], [engines-and-tools], [core-animation], [sparkles-baseline] (`LYR10`) |
| A snapshot of the built output             | [scroll-and-view-transitions] (a raster), [immediate-mode] (Clay's cloned layout subtree), [jetpack-compose] (a lazy item's last `GraphicsLayer`)                         |

### By what an interruption does to velocity

| On retarget                              | Subjects                                                                                                                                                                     |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kept (springs carry `(value, velocity)`) | [jetpack-compose], [swiftui], [react-motion-and-spring], [svelte] (`Spring`), [terminal-uis] (harmonica), [frp] (elm-animation, Yampa), [sparkles-baseline] (`ScrollMotion`) |
| Smoothed additively                      | [core-animation], [swiftui] (timing curves), [web-animations] (`composite: "add"`)                                                                                           |
| Lost (restart from the current value)    | [flutter] (implicit widgets), [css-transitions-and-animations], [immediate-mode], [terminal-uis] (Textual), [engines-and-tools]                                              |

---

## Milestones

| Date          | Milestone                                                                                                        | Link                             |
| ------------- | ---------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| 1997          | Elliott & Hudak, _Functional Reactive Animation_ (Fran): a behaviour is a function of continuous time            | [frp]                            |
| 2003          | _The Yampa Arcade_: games as arrowized signal functions with dynamic collections                                 | [frp]                            |
| 2007          | Core Animation ships in macOS 10.5 (iOS 2.0 in 2008): model and presentation layers                              | [core-animation]                 |
| 2009          | Elliott, _Push-Pull Functional Reactive Programming_: constant phases need no sampling                           | [frp]                            |
| 2013-06-25    | Web Animations Working Draft (the earliest TR the source lists)                                                  | [web-animations]                 |
| 2015-02-11    | Paul Lewis, "FLIP Your Animations"                                                                               | [web-animations]                 |
| 2016          | `UIViewPropertyAnimator`: interruptible, scrubbable, reversible (iOS 10)                                         | [core-animation]                 |
| 2019          | SwiftUI: `withAnimation`, `Animatable`, `Transaction` (iOS 13)                                                   | [swiftui]                        |
| 2019-08-23    | Flutter's `TweenAnimationBuilder`                                                                                | [flutter]                        |
| 2020          | SwiftUI `matchedGeometryEffect` (iOS 14); egui's `animate_bool` (2020-08-30)                                     | [swiftui], [immediate-mode]      |
| 2022-10-25    | CSS View Transitions Level 1, First Public Working Draft                                                         | [scroll-and-view-transitions]    |
| 2023          | iOS 17: springs by default, `CustomAnimation` with `shouldMerge`/`velocity`, `PhaseAnimator`, `KeyframeAnimator` | [swiftui]                        |
| 2023-04-28    | Scroll-driven Animations Working Draft                                                                           | [scroll-and-view-transitions]    |
| 2024          | Compose `ApproachLayoutModifierNode`, `animateBounds` and `SharedTransitionScope` (file-header years)            | [jetpack-compose]                |
| 2024-02-19    | Textual 0.52.0: `animation_level` and `TEXTUAL_ANIMATIONS`                                                       | [terminal-uis]                   |
| 2024-08-28    | CSS Easing Level 2 FPWD: `linear()`                                                                              | [css-transitions-and-animations] |
| 2024-09-17    | lottie-spec 1.0                                                                                                  | [engines-and-tools]              |
| 2024-10-22    | Svelte 5 (runes; transitions timed through Web Animations)                                                       | [svelte]                         |
| 2024-11-12    | Framer Motion becomes Motion, independent of Framer                                                              | [react-motion-and-spring]        |
| 2025-04-30    | GSAP 3.13.0: every plugin free after the Webflow acquisition                                                     | [engines-and-tools]              |
| by 2026-05-20 | Clay's transition API, with enter and exit (date uncertain: the clone is shallow)                                | [immediate-mode]                 |

---

## Quick navigation

- **I'm designing `sparkles:ui` animation.** [Baseline](./sparkles-baseline.md)
  → [comparison § Layout animation and UI-Q9][cmp-q9] → [§ Enter, exit and
  UI-Q10][cmp-q10] → [§ Candidate designs][cmp-designs]; then the closest
  analogues, [immediate mode](./immediate-mode.md) (egui, Clay) and
  [Compose](./jetpack-compose.md).
- **I want the FRP connection.** [FRP](./frp.md) → [comparison § FRP and
  animation][cmp-frp] → the reactive catalog's [Yampa][rp-yampa],
  [Elm][rp-elm] and [Reflex][rp-reflex] pages for their runtimes.
- **I want to understand springs and interruption.** [Concepts §
  Spring][c-spring] → [SwiftUI](./swiftui.md#interruption-and-retargeting) →
  [Compose](./jetpack-compose.md#interruption-and-retargeting) →
  [harmonica](./terminal-uis.md#curves-and-springs).
- **I want layout and shared-element animation.** [Concepts § Layout
  animation][c-layout] → [Web Animations (FLIP)](./web-animations.md#layout-animation)
  → [Motion](./react-motion-and-spring.md#layout-animation) →
  [Compose lookahead](./jetpack-compose.md#layout-animation) →
  [View Transitions](./scroll-and-view-transitions.md#layout-animation).
- **I want the web platform's model.** [CSS](./css-transitions-and-animations.md)
  → [Web Animations](./web-animations.md) →
  [Scroll-driven and View Transitions](./scroll-and-view-transitions.md).

---

## Sources

Each deep-dive's `Sources` section lists the primary sources behind it: the
specifications and source trees pinned in the master catalog, official
documentation, and the papers. The decisions this survey is measured against
are in the [component-authoring study][ui-decisions]; the open questions UI-Q9
and UI-Q10 are in the draft specification of [PR #775][pr775].

<!-- References -->

[flutter]: ./flutter.md
[jetpack-compose]: ./jetpack-compose.md
[swiftui]: ./swiftui.md
[core-animation]: ./core-animation.md
[css-transitions-and-animations]: ./css-transitions-and-animations.md
[web-animations]: ./web-animations.md
[scroll-and-view-transitions]: ./scroll-and-view-transitions.md
[react-motion-and-spring]: ./react-motion-and-spring.md
[svelte]: ./svelte.md
[frp]: ./frp.md
[immediate-mode]: ./immediate-mode.md
[terminal-uis]: ./terminal-uis.md
[engines-and-tools]: ./engines-and-tools.md
[sparkles-baseline]: ./sparkles-baseline.md
[c-closed]: ./concepts.md#closed-form-and-stepped-integration
[c-spring]: ./concepts.md#spring
[c-layout]: ./concepts.md#layout-animation
[cmp-spine]: ./comparison.md#the-analysis-spine
[cmp-glance]: ./comparison.md#at-a-glance
[cmp-state]: ./comparison.md#where-animation-state-lives
[cmp-declaring]: ./comparison.md#declaring-implicit-explicit-target-controller
[cmp-time]: ./comparison.md#time-and-the-clock
[cmp-interrupt]: ./comparison.md#interruption-and-retargeting
[cmp-q9]: ./comparison.md#layout-animation-and-ui-q9
[cmp-q10]: ./comparison.md#enter-exit-and-ui-q10
[cmp-purity]: ./comparison.md#purity-scheduling-and-testing
[cmp-frp]: ./comparison.md#frp-and-animation
[cmp-designs]: ./comparison.md#candidate-designs-for-sparklesui
[reactive]: ../reactive-programming/index.md
[rp-yampa]: ../reactive-programming/yampa.md
[rp-elm]: ../reactive-programming/elm.md
[rp-reflex]: ../reactive-programming/reflex.md
[manim]: ../manim/index.md
[ui-decisions]: ../ui-authoring/index.md#decisions
[pr775]: https://github.com/PetarKirov/sparkles/pull/775
