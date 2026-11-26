# Comparison — how UI systems express animation

The capstone of the [UI animation survey](./index.md): the surveyed systems
re-cut by the [analysis spine](#the-analysis-spine) every deep-dive shares, the
consensus the field has reached, the two open `sparkles:ui` questions the
survey was asked to inform — UI-Q9 (reading last frame's geometry) and UI-Q10
(exit animations), both in [PR #775][pr775] — the connection to FRP, and three
candidate designs for `sparkles:ui`.

**Last reviewed:** November 26, 2026

> [!IMPORTANT]
> The sections [Candidate designs](#candidate-designs-for-sparklesui) and
> [Recommendation](#recommendation) are **analysis, not decisions**. They turn
> the evidence into options with costs; the decision belongs to the
> `sparkles:ui` specification, which cites this page as evidence.

---

## The analysis spine

Every deep-dive answers the same nine questions in the same order, as `###`
sections under `## Analysis`. This page cuts across them:

| Spine section                          | Here                                                                       |
| -------------------------------------- | -------------------------------------------------------------------------- |
| Where animation state lives            | [Where animation state lives](#where-animation-state-lives)                |
| Declaring an animation                 | [Declaring](#declaring-implicit-explicit-target-controller)                |
| Time and the clock                     | [Time and the clock](#time-and-the-clock)                                  |
| Interruption and retargeting           | [Interruption](#interruption-and-retargeting)                              |
| Curves and springs                     | [Interruption](#interruption-and-retargeting) (springs carry the velocity) |
| Layout animation                       | [Layout animation and UI-Q9](#layout-animation-and-ui-q9)                  |
| Enter and exit                         | [Enter, exit and UI-Q10](#enter-exit-and-ui-q10)                           |
| Scheduling, reduced motion and testing | [Purity, scheduling and testing](#purity-scheduling-and-testing)           |
| Lessons for `sparkles:ui`              | [Candidate designs](#candidate-designs-for-sparklesui)                     |

---

## At a glance

| System                                               | State lives in                                                                       | Declared                                              | Time source                                                                        | Retarget keeps velocity                                  | Springs                         | Layout animation runs in                                                                                | Exit keeps                                                          |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------ | ----------------------------------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| [Flutter](./flutter.md)                              | `AnimationController` in a `State` or `RenderObject`                                 | explicit controller; implicit widgets on top          | vsync timestamp to `Ticker`s, before build                                         | no (implicit widgets restart)                            | `SpringSimulation`, explicit    | build, layout (`RenderAnimatedSize`) or overlay (`Hero`)                                                | the old widget description, rebuilt                                 |
| [Jetpack Compose](./jetpack-compose.md)              | remembered holders in the slot table; `Modifier.Node`s                               | implicit default; `Animatable` imperative             | `withFrameNanos`, the frame's target time                                          | **yes**                                                  | default                         | layout: lookahead pre-pass, approach pass; placement                                                    | composition (closing state) or last layer                           |
| [SwiftUI](./swiftui.md)                              | the attribute graph, per identity, hidden                                            | `withAnimation` / `.animation(_:value:)`              | the framework                                                                      | **yes** (springs merge)                                  | default                         | after layout, off the main thread                                                                       | the removed view, under its identity                                |
| [Core Animation](./core-animation.md)                | `CAAnimation`s in the render server; presentation tree                               | implicit actions; explicit `add(_:forKey:)`           | the render server; hierarchical `CAMediaTiming`                                    | additive only                                            | `CASpringAnimation`             | compositor, from the model's target frames                                                              | nothing (the app removes after a completion)                        |
| [CSS](./css-transitions-and-animations.md)           | the UA's `CSSTransition`/`CSSAnimation` per element                                  | transitions implicit, animations by name              | the document timeline                                                              | no (reversing shortening only)                           | no (`linear()` approximates)    | style: interpolated computed values, relayout                                                           | the element, `display` held (`allow-discrete`)                      |
| [Web Animations](./web-animations.md)                | `Animation` objects; effects are stateless functions of time                         | explicit, imperative                                  | hierarchical timelines                                                             | no (`composite: "add"`)                                  | no                              | FLIP in user code; transform on the compositor                                                          | nothing (user code awaits `finished`)                               |
| [View Transitions](./scroll-and-view-transitions.md) | the `ViewTransition`'s named-element map                                             | `startViewTransition` or `@view-transition`           | document timeline; scroll timelines are progress                                   | no (a new transition aborts)                             | no                              | UA-run FLIP: old rect and raster captured, new rect live                                                | **a raster snapshot**                                               |
| [Motion](./react-motion-and-spring.md)               | `MotionValue`s on a `VisualElement`, outside React state                             | declarative targets (`animate`, `exit`, `layout`)     | Motion's frame loop on `requestAnimationFrame`                                     | **yes**                                                  | default for physical values     | library code in React's commit; transform per frame                                                     | the removed React element (`AnimatePresence`)                       |
| [React Spring](./react-motion-and-spring.md)         | `SpringValue`/`Controller` outside React state                                       | declarative targets in hooks                          | `frameloop` (`always` or `demand`)                                                 | **yes**                                                  | the only model                  | none (user measures)                                                                                    | the removed data item, re-rendered                                  |
| [Svelte](./svelte.md)                                | transition and animation managers on the runtime's effects; `Tween`/`Spring` signals | directives (`transition:`, `in:`, `out:`, `animate:`) | WAAPI for `css` transitions; the runtime's `requestAnimationFrame` loop for `tick` | `Spring` only (transitions reverse from the current `t`) | `Spring`                        | `animate:` FLIP on keyed `each` items: measured at the start of `reconcile` and in a microtask after it | the removed block's real DOM, paused `INERT` until every outro ends |
| [Fran](./frp.md#fran)                                | nowhere: the `Behavior` is the animation                                             | expressions in `time`                                 | continuous time, sampled by the runtime                                            | by switching on a snapshot                               | integrals                       | n/a                                                                                                     | n/a (the program switches to `emptyImage`)                          |
| [Yampa](./frp.md#yampa)                              | inside the running signal function                                                   | the program                                           | `dt` from the `reactimate` driver                                                  | switch on `(pos, vel)`                                   | `integral` feedback, stepped    | n/a                                                                                                     | n/a (the collection drops it)                                       |
| [Elm](./frp.md#elm)                                  | the `Model` (elm-animation record, elm-animator `Timeline`)                          | explicit; elm-animator state targets                  | `onAnimationFrame` messages                                                        | elm-animation `retarget`: yes                            | elm-animator closed-form spring | user code, geometry one frame late (`Browser.Dom`)                                                      | the model keeps a "leaving" item                                    |
| [Dear ImGui](./immediate-mode.md#dear-imgui)         | `ImGuiContext` scalars, per-window `ImGuiStorage`                                    | hard-coded effects                                    | `io.DeltaTime`, stepped                                                            | n/a                                                      | none                            | none                                                                                                    | one retained pointer for one fade                                   |
| [egui](./immediate-mode.md#egui)                     | `AnimationManager` keyed by `Id`                                                     | implicit target restated every frame                  | host time, `stable_dt`                                                             | no                                                       | none                            | user code in the build, from last frame's height                                                        | the caller keeps building it                                        |
| [Clay](./immediate-mode.md#clay)                     | transition records keyed by element id                                               | implicit, declared per element                        | `deltaTime` to `Clay_EndLayout`                                                    | no                                                       | none (a handler)                | **layout, run twice per animated frame**                                                                | **last frame's layout subtree, cloned**                             |
| [Gio](./immediate-mode.md#gio)                       | caller-owned widget structs (timestamps)                                             | explicit, closed form from `gtx.Now`                  | `FrameEvent.Now`; `InvalidateCmd{At}`                                              | fling re-estimates                                       | none                            | paint-only ink                                                                                          | the caller (press history)                                          |
| [Bubble Tea + harmonica](./terminal-uis.md)          | the application model                                                                | explicit commands                                     | `tea.Tick`, fixed spring `dt`                                                      | **yes** (caller holds velocity)                          | damped spring                   | n/a                                                                                                     | the application model                                               |
| [Textual](./terminal-uis.md)                         | the attribute plus the `Animator`                                                    | `animate()` and CSS `transition:`                     | the animator's 60 fps timer                                                        | no                                                       | none                            | layout: a style write relayouts each tick                                                               | nothing (remove in `on_complete`)                                   |
| [Godot](./engines-and-tools.md)                      | `Tween`s in the `SceneTree`; `AnimationMixer` nodes                                  | explicit                                              | idle or physics frame deltas                                                       | no                                                       | a fixed curve only              | none built in                                                                                           | nothing (a bound tween dies with the node)                          |
| [Rive](./engines-and-tools.md)                       | the `StateMachineInstance` per artboard                                              | state-level implicit: inputs fire transitions         | the host's `advance(seconds)`                                                      | no (mix restarts)                                        | none                            | layout: from the retained last rect to the new Yoga rect                                                | authored exit states                                                |
| [GSAP](./engines-and-tools.md)                       | `Tween`/`Timeline` objects under `globalTimeline`                                    | explicit; `quickTo` setter                            | one ticker on `requestAnimationFrame`                                              | no (`InertiaPlugin` only)                                | none                            | `Flip`: user code, two forced layouts, transform                                                        | nothing (`onLeave` for hidden elements)                             |
| [`sparkles:ui` today](./sparkles-baseline.md)        | component structs; `ElementStore` for scroll                                         | hand-written integrators                              | `dt` from the caller                                                               | `ScrollMotion` yes                                       | `ScrollMotion` (critical)       | none                                                                                                    | `LYR10`: the component keeps building it                            |

---

## Where animation state lives

Four homes, and every system uses one of them for its presentation values:

| Home                                         | Systems                                                                                                                                                               | What it costs a pure per-frame view                                                                                   |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **A controller object the program holds**    | Flutter `AnimationController`, Compose `Animatable`, WAAPI `Animation`, `UIViewPropertyAnimator`, GSAP, Godot `Tween`, Gio widgets                                    | a lifetime: created, disposed, kept across frames — exactly the hook or mount callback `sparkles:ui` forbids (`AUT4`) |
| **The application's model**                  | Elm, Bubble Tea, Yampa (inside the running signal function), `sparkles:ui` today                                                                                      | pure, but every application re-implements the bookkeeping, and the model grows presentation fields                    |
| **Per-identity storage the framework keeps** | SwiftUI's attribute graph, Compose's slot table, CSS's per-element transitions, egui's `AnimationManager`, Clay's transition records, Rive, Motion's `VisualElement`s | none for the view, if the view only _reads_; egui and Compose let the build write it                                  |
| **A compositor or render server**            | Core Animation, the CSS/WAAPI compositor path, View Transitions                                                                                                       | none for the view; but the program and hit testing see the model value while the screen shows another                 |

The third is the [element store][ui-decisions] `sparkles:ui` already has
(`WGT5`, UI-Q5). The deciding detail is _who writes it_. egui's `animate_bool`
and Compose's `animate*AsState` write from inside the build — egui mutates its
`AnimationManager` during the call ([immediate mode](./immediate-mode.md#where-animation-state-lives)),
Compose's remembered holder is created by the composition. SwiftUI, Clay and
Core Animation keep the write outside the program: the program states a target,
the framework commits it. `AUT8`'s rule — components read the store, the host
commits it after layout — puts `sparkles:ui` in the second group.

---

## Declaring: implicit, explicit, target, controller

The field has converged on **declarative targets with implicit animation as the
default and an imperative controller as the escape hatch**:

- Compose (`animate*AsState`, `Transition`), SwiftUI (`.animation(_:value:)`),
  Motion (`animate`), React Spring (hook targets), egui (`animate_bool`), Clay
  (`.transition`) and CSS transitions all animate _because a target changed_. A
  per-frame view states the target every frame, which is all such a view can do.
- The controllers — Flutter's, Compose's `Animatable`, WAAPI, GSAP, Core
  Animation's explicit animations — exist for gestures (a drag sets the value,
  a release flings it), sequencing and scrubbing.
- Flutter is the outlier that started from the controller and added implicit
  widgets later; its implicit widgets drop velocity on retarget because they are
  built on a duration-based controller ([Flutter](./flutter.md#interruption-and-retargeting)).

A gesture in an immediate-mode toolkit does not need a controller object: the
drag's position is the target and the release's velocity is the initial
velocity of a [decay](./concepts.md#decay) or spring — `ScrollMotion` already
works that way ([baseline](./sparkles-baseline.md#what-moves-today)).

---

## Time and the clock

| Who owns the clock                       | Systems                                                                                                                                          | Consequence                                                                                   |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| **The framework, one timestamp a frame** | Flutter (`SchedulerBinding`), Compose (`MonotonicFrameClock`), SwiftUI, Svelte and Motion (`requestAnimationFrame`), the web's document timeline | every animation of a frame samples one instant; tests replace the clock                       |
| **A compositor or render server**        | Core Animation, compositor-threaded CSS/WAAPI, View Transitions                                                                                  | animations run while the program's thread is blocked; the program cannot observe them cheaply |
| **The host, passed as an argument**      | Yampa (`reactimate`'s `dt`), Elm (a message), egui, Clay, Dear ImGui, Gio, Rive (`advance`), harmonica, `sparkles:ui` today                      | the view is a function of time; determinism is the caller's choice                            |
| **A timer of its own**                   | Textual (60 fps), Reflex (`tickLossy` threads), GSAP's ticker                                                                                    | decoupled from presentation; drifts against vsync                                             |
| **Progress, not time**                   | scroll timelines, view timelines, a Lottie frame, a GSAP timeline's position, Compose's `SeekableTransitionState`                                | the animation is a pure function of a position; seeking is free                               |

Two properties separate the robust systems from the rest:

1. **Closed-form evaluation at an elapsed time.** Flutter's `Simulation`s,
   Compose's stateless `AnimationSpec`s (start value, start velocity, target,
   play time in; value out), Web Animations' effect model, `CAMediaTiming`,
   Gio, Lottie and SwiftUI's `Spring.value(…)` all compute `value(t)` directly.
   Stepped integrators — Yampa's `integral`, egui's bool smoothing, Clay's
   `0.95` scroll momentum, Bubbles' fixed 1/60 s spring step,
   `ScrollbarAnim`'s Euler ease — change with the frame rate
   ([concepts](./concepts.md#closed-form-and-stepped-integration)).
2. **Sampling at the presentation time.** Compose's frame time _"may be
   normalized to the target time for the frame"_; `CADisplayLink` offers
   `targetTimestamp`. `sparkles:ui-app` already computes a predicted
   presentation, [`FrameStart.target`](./sparkles-baseline.md#who-owns-the-clock).

---

## Interruption and retargeting

| On a new target mid-flight                     | Systems                                                                                                                                                                           |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Spring keeps its velocity**                  | Compose (`Animatable`; `Transition` turns an interrupted tween into a spring), SwiftUI (springs merge), Motion, React Spring, harmonica, elm-animation `retarget`, `ScrollMotion` |
| **Additive: old and new summed**               | Core Animation `isAdditive`, `UIViewPropertyAnimator`, SwiftUI timing curves, WAAPI `composite: "add"`                                                                            |
| **Restart from the current value, velocity 0** | Flutter implicit widgets, CSS transitions (shortened only when reversing), egui, Clay, Textual, GSAP `quickTo`, Godot, Rive's mix                                                 |
| **Cut**                                        | CSS animations on a name change, a new View Transition aborting the old one                                                                                                       |

The systems built for touch — Apple's and Google's, and the two React libraries
— all keep velocity, and all do it the same way: the running animation's
current `(value, velocity)` becomes the initial condition of the next. That
requires the store to hold _velocity_ beside value, or to hold the animation's
parameters so velocity can be evaluated in closed form. A duration-and-easing
tween has no velocity input, which is why the field moved its default to
springs (SwiftUI since iOS 17, Compose from the start, Motion for physical
values).

---

## Layout animation and UI-Q9

UI-Q9 asks how a component reads last frame's results — layout rects, scroll
extent, hover — and which of them may decide what it builds. For layout
animation the survey's answer is precise: **every mechanism needs the previous
frame's geometry, and every robust one keeps it out of component code.**

| Mechanism                               | Previous geometry comes from                                                         | Runs in                                                             | Systems                                                                                                                                                                                 |
| --------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **FLIP by hand**                        | user code measures the last layout (`getBoundingClientRect`), forces a second layout | user code measures; the transform plays on the compositor           | [Web Animations](./web-animations.md#layout-animation), [GSAP `Flip`](./engines-and-tools.md#layout-animation)                                                                          |
| **FLIP in a library, around a commit**  | the library measures before the DOM mutates and again after it                       | library code in the commit phase; a transform written each frame    | [Motion](./react-motion-and-spring.md#layout-animation) (`getSnapshotBeforeUpdate`, then a microtask after `componentDidUpdate`), [Svelte](./svelte.md#layout-animation) `animate:flip` |
| **Read last frame's size in the build** | the component reads a committed size, and that read decides the space it claims      | user code, during the build; wrong on the first frame               | [egui](./immediate-mode.md#layout-animation) `CollapsingHeader` (guesses `10.0`), [Elm](./frp.md#layout-animation) (one frame late)                                                     |
| **The layout node remembers itself**    | the node's own last size or bounds                                                   | layout (measure or placement)                                       | Flutter `RenderAnimatedSize`; Compose `animateContentSize`, `animateItem`; [Rive](./engines-and-tools.md#layout-animation) `LayoutComponent`                                            |
| **Lookahead**                           | a pre-pass computes the destination; the node's previous bounds are the start        | layout: the lookahead pass, then the approach pass                  | [Compose](./jetpack-compose.md#layout-animation) `LookaheadScope`, `animateBounds`, shared elements                                                                                     |
| **Two layout passes**                   | the transition record holds last frame's animated state and target                   | layout: pass 1 for targets, pass 2 with animated boxes substituted  | [Clay](./immediate-mode.md#layout-animation)                                                                                                                                            |
| **Interpolate after a single layout**   | the framework's presentation value per identity                                      | after layout: SwiftUI's render pass, Core Animation's render server | [SwiftUI](./swiftui.md#layout-animation), [Core Animation](./core-animation.md#layout-animation)                                                                                        |
| **Snapshot and live new state**         | the UA captures the old rect and a raster before the update                          | the compositor, over pseudo-elements                                | [View Transitions](./scroll-and-view-transitions.md#layout-animation); Flutter `Hero` (overlay, measured in a post-frame callback)                                                      |

What follows for UI-Q9:

1. **Animation does not need a component to read geometry.** Only egui and Elm
   hand last frame's geometry to the view, and both pay for it: egui's first
   open guesses a height, Elm sees geometry a frame late. Everyone else keeps
   the previous rect in the framework, per identity, and compares it with the
   new layout itself. `sparkles:ui`'s host already has both: last frame's
   committed layout in the store, this frame's after layout. No forced second
   layout is ever needed, unlike FLIP on the web, because the host never gave
   the layout away.
2. **Two phases are viable, and they answer different needs.** A
   **paint-time** layout animation (Core Animation, SwiftUI's built-ins, View
   Transitions, FLIP's transform) lays out once at the target and draws each
   element at an interpolated rect: siblings snap to their final positions and
   only the animated element glides — cheap, and fine for moves. A
   **layout-time** one (Clay, Compose lookahead and `animateContentSize`,
   `RenderAnimatedSize`) feeds the animated size back into layout so siblings
   reflow smoothly — needed for an expanding section, and it costs a second
   layout pass (Clay) or an approach pass (Compose) on animated frames only.
3. **The geometry a component may legitimately read is not animation's.** A
   virtual list's viewport and offset decide what it builds; an animation's
   start rect does not. UI-Q9 can therefore be answered for animation without
   widening what components read.
4. **Hit testing must pick a geometry.** Core Animation hit-tests the model
   (target) layer; View Transitions make the snapshot inert; Clay can disable
   pointer interaction while a position transitions. `AUT7` dispatches against
   the last painted frame, so the hit geometry should be the _presented_ rect
   — the one the user aimed at — which a paint-time interpolation must
   therefore record.

---

## Enter, exit and UI-Q10

UI-Q10 asks how an element removed this frame keeps painting through an exit
animation, given that lifecycle is a set difference (`AUT4`) and an overlay is
open exactly when built (`AUT47`). The field keeps one of three things:

| What is kept after the program removes it      | Who drives the exit                       | Systems                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ---------------------------------------------- | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **The description, still built**               | the framework, which re-runs the old view | SwiftUI (attributes driven to `didDisappear`; re-adding revives it), Compose `AnimatedVisibility`/`AnimatedContent` (composed with the old state value until `PostExit`), Flutter `AnimatedSwitcher`, Motion `AnimatePresence` (the removed React element, props frozen), React Spring `useTransition` (the removed data item, re-rendered in a `leave` phase), Svelte outros (the real DOM subtree, paused `INERT` and resumed on reversal) |
| **A closing state the program keeps building** | the program                               | egui (`Window` with `open == false` until its fade ends), CSS `allow-discrete` (`display` held), Elm and the FRP systems (a "leaving" item in the model), `sparkles:ui`'s `LYR10` today, Textual, GSAP, Godot, Core Animation (remove in a completion)                                                                                                                                                                                       |
| **A snapshot of the built output**             | the engine, with no program code          | [View Transitions](./scroll-and-view-transitions.md#enter-and-exit) (a raster), [Clay](./immediate-mode.md#enter-and-exit) (last frame's layout subtree, cloned back in), Compose lazy lists (the item's last `GraphicsLayer`)                                                                                                                                                                                                               |

The first row is closed to `sparkles:ui`: re-running a removed element's view
needs the closure or description that built it, and `AUT5` forbids a closure
surviving the frame. React Spring's variant — keep the removed _data item_ and
call the row function on it — is the closest the first row comes, and it is a
pure function of `(previous entries, items, keys)` ([React
Spring](./react-motion-and-spring.md#enter-and-exit)), but it needs the row's
data to outlive the application's removal of it.

That leaves two designs, both proven:

- **Closing state (egui, `LYR10`).** The component keeps building the element
  with a `closing` flag until the store says the exit has finished. Pure and
  simple; the application must remember to keep building, which contradicts
  "a component closes an overlay by not building it" (`AUT47`) unless
  "closing" counts as built. The store can carry the "exit finished" fact
  back, so the application need not time it.
- **Retained output (Clay, Compose lazy lists, View Transitions).** When the set
  difference reports an identity gone and its store entry names an exit
  transition, the host keeps last frame's records for that subtree — layout
  boxes and draw commands — paints them with the exit's opacity or transform,
  gives them no hit or key targets (`AUT45` already says so for overlays), and
  drops them when the exit ends. No component cooperates. The costs are the
  ones Clay documents: text and images the subtree borrowed must outlive their
  frame (in `sparkles:ui`, a copy out of the frame's text pool), a vanished
  parent needs a fallback position (Clay floats the subtree at its last box),
  and the frozen content cannot update — the trade View Transitions makes
  explicit by keeping a raster.

Whichever is kept, a leaving element either **keeps its place in layout**, so
the gap closes only when the exit ends, or **leaves the flow while it keeps
painting at its old rect**, so the remaining elements animate into the gap at
once. Svelte takes leaving `each` items out of flow with `fix()`, and Motion's
`AnimatePresence` offers `mode="popLayout"`; Clay keeps an exiting clone in
flow at its frozen size and floats it only when its parent is gone
([Svelte](./svelte.md#enter-and-exit),
[Motion](./react-motion-and-spring.md#enter-and-exit),
[Clay](./immediate-mode.md#enter-and-exit)). An exit design has to offer both.

---

## Purity, scheduling and testing

**Can an animated view stay a pure function of `(state, time)`?** Yes, when the
animation is stored as parameters and sampled in closed form — Fran's
`Behavior`, elm-animation's record, Compose's specs, Gio's timestamps, Web
Animations' effects. It stops being pure the moment the view steps or writes
the animation: egui's `animate_bool`, Compose's remembered holders, and
`sparkles:ui`'s own `ScrollBody.animate(dt)`.

**Frames only while animating.** egui requests a repaint only while a value is
in flight; Gio schedules with `InvalidateCmd{At}`; Rive's `advance` returns
whether it needs another frame; React Spring has `frameloop: "demand"`; a
Compose animation suspends in `withFrameNanos` only while running. The
semantic basis is Elliott's push-pull FRP: a behaviour in a constant phase
needs no sampling ([FRP](./frp.md#scheduling-reduced-motion-and-testing)).
`sparkles:ui-app`'s `requestFrame` is already one-shot by contract
([baseline](./sparkles-baseline.md#how-a-frame-is-asked-for)).

**Reduced motion** is coarse almost everywhere: Flutter runs controllers at 5 %
of their duration, Compose has only the global duration scale, the web leaves
everything to the author's media query, and no immediate-mode toolkit reads a
preference. Textual is the exception worth copying: an `animation_level` of
`none`, `basic` or `full`, with each animation tagged by the level it needs, so
scrolling feedback survives where decoration does not
([terminal UIs](./terminal-uis.md#scheduling-reduced-motion-and-testing)).

**Testing** follows the clock's owner. Systems that take time as an argument
(Yampa's `embed`, Gio's `Now`, egui's `egui_kittest` with a fixed `step_dt`
and `animation_time = 0.0`) test by passing time. Systems that own a frame
clock replace it: Compose's `mainClock.autoAdvance = false`, Flutter's
`tester.pump(duration)`. `CAMediaTiming`'s `speed = 0` plus `timeOffset` samples
any instant. The recurring trap is testing with animations disabled, which
tests a different program.

---

## FRP and animation

FRP began as animation: Elliott and Hudak's _Functional Reactive Animation_
(1997) defined `Behavior a` as a function of continuous time so that an
animation could be written as an expression and sampled at whatever rate the
display allowed ([FRP](./frp.md#fran)). The survey shows that idea surviving,
under other names, in every robust system:

| FRP idea                                       | Where it reappears                                                                                                        |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `Behavior a = Time → a`                        | Web Animations' stateless effect model, Compose's `AnimationSpec`, `CAMediaTiming`, Lottie frames, elm-animation's record |
| Resolution-independent time                    | closed-form evaluation; sampling at the frame's target time                                                               |
| `timeTransform`                                | `CAMediaTiming`'s `speed`/`timeOffset`, WAAPI `playbackRate`, Flutter's `timeDilation`, Godot's `time_scale`              |
| `until`/`switcher` on an event                 | interruption: a new target starts a new behaviour                                                                         |
| `snapshot` of value and derivative at switch   | retargeting with velocity: Yampa's ball passes `(y, vy)`, elm-animation's `retarget`, Compose's `initialVelocity`         |
| `integral`                                     | springs and decays — closed-form where the ODE allows it, stepped where it does not                                       |
| Push-pull's constant phases                    | "request a frame only while animating"                                                                                    |
| Space and time leaks of first-class behaviours | why stores hold _parameters_, not histories (elm-animator keeps only 5 s of history)                                      |

For `sparkles:reactive` the consequence is a division of labour. Animation does
not need streams: a target is a value the view already has, and its motion is a
function of time the toolkit samples. The [reactive
catalog](../reactive-programming/index.md)'s cells feed _targets_ to the view at
the edges (`AUT2`); the continuous part — Fran's half of FRP — belongs in
`sparkles:ui`'s store, sampled at the frame's time. What `sparkles:reactive`
offers animation is the discrete half: the event that changes a target, and a
virtual clock shared with its own time operators
([testing](../reactive-programming/testing.md)).

---

## Candidate designs for `sparkles:ui`

> [!NOTE]
> Analysis, not decision. Each design is stated against the decisions already
> made — pure `@safe pure nothrow @nogc` components, an identity-keyed store
> the component reads and the host commits (`AUT8`), messages through `ui.on`,
> lifecycle as a set difference (`AUT4`), no hooks.

### Design A — animations as data in the store, sampled purely

The store entry for an animated attribute of an identity holds the animation's
parameters, never its stepped value:

```d
struct Motion // one animated scalar (or a small vector) of one element
{
    float from, to;       // start and target
    float v0;             // velocity at the start (springs)
    MonoTime t0;          // when it started
    MotionSpec spec;      // tween(duration, easing) | spring(duration, bounce) | none
}
```

A component writes `ui.animated(target, spec)` (or an `animate:` attribute on a
primitive), which **reads** the committed entry and returns `value(frameTime)`
in closed form. If `target` differs from the entry's `to`, the read evaluates
the retarget rule locally — `from = value(now)`, `v0 = velocity(now)`,
`t0 = now` — so the first frame after a change already moves, with no
one-frame lag; the builder records the declared target in the frame, and the
host's commit applies the same rule, deterministically, after layout. The host
requests a frame while any entry is unsettled, and samples at
[`FrameStart.target`](./sparkles-baseline.md#who-owns-the-clock).

- **From:** Fran and elm-animation (an animation is data over time), Compose
  (stateless specs, velocity on retarget), Gio (closed form from `Now`),
  egui and Clay (implicit, keyed by identity).
- **Gains:** components stay pure and `@nogc`; retargeting keeps velocity for
  springs; frame-rate independence; any frame is reproducible from
  `(store, time)`, so tests pass a virtual time; reduced motion is a host-side
  rewrite of `spec` (`none`, or a cross-fade), not a branch in every component.
- **Costs:** the store needs per-attribute entries (a slot index under the
  identity); a positional identity that shifts on a sibling insert retargets
  the wrong element, as Clay warns, so animated elements want keys; geometry and
  exit are not covered.

### Design B — a host presentation pass for geometry and exit

Components declare _what_ may animate (`layoutTransition:`, `exit:` on an
element) and never see geometry. After layout, the host compares each opted-in
identity's new rect with its last presented rect in the store and starts a
Design-A motion on the difference; paint draws the element at the interpolated
rect (a paint-time transform). An opted-in identity that the set difference
reports gone is kept as **retained output**: last frame's records for its
subtree, painted with its exit motion, with no hit or key targets, freed when
the motion settles. The exit declares whether the retained subtree keeps
its slot at a frozen size (Clay) or floats at its last rect so its
neighbours close the gap at once (Motion's `popLayout`).

- **From:** Core Animation and SwiftUI (lay out once, interpolate presented
  geometry), View Transitions (snapshot exit), Clay (the retained subtree and
  its fallback position), Compose lazy lists (replay the last layer).
- **Gains:** answers UI-Q9 for animation without widening what components read;
  answers UI-Q10 without the component cooperating, consistent with `AUT4`,
  `AUT45` and `AUT47` as written; works for list reorders, which are the
  commonest layout animation.
- **Costs:** paint-time interpolation does not reflow siblings (an expanding
  section needs a layout-time mode: Clay's second pass or a lookahead, on
  animated frames only); retained output must copy borrowed text and keep
  images alive across frames, which is new lifetime work for the frame tables
  (`AUT14`, UI-Q12's capacities); the hit geometry must be the presented rect.

### Design C — presentation state machines in the store

A component names discrete presentation states (`closed`, `opening`, `open`,
`closing`) and transitions between them with specs; the store runs the machine
per identity and exposes the current state and its progress. Sequencing,
staggering and authored timelines are machine definitions, seekable as a
progress.

- **From:** Rive's state machines (inputs fire authored transitions, the host
  advances), Compose's `Transition`/`SeekableTransitionState`, elm-animator's
  timeline of states, `sparkles:ui`'s own [state-machine spec](../../specs/ui/state-machines.md).
- **Gains:** expresses choreography A cannot — multi-property, sequenced,
  interruptible as a whole; scrubbing for gesture-driven transitions; exit is
  just a `closing` state.
- **Costs:** the largest API; definitions must be plain data to live in the
  store; much of it can be built from Design A's entries, so it is not a
  primitive.

### Recommendation

> [!IMPORTANT]
> Analysis: one reading of the evidence, for the specification to accept,
> amend or reject.

Adopt **Design A as the primitive** and **Design B's two host mechanisms** on
top of it; defer Design C to a library over A.

- A is the only design in which the view stays a pure function of
  `(state, store, time)`, and it is what the field's robust systems converged
  on (stateless specs, velocity-preserving springs, a framework-owned clock
  sampled at the presentation time). The default spec should be a critically
  or slightly under-damped spring parametrised by duration and bounce, the
  shape `ScrollMotion` already uses; tweens remain for opacity and colour.
- B answers the two open questions in the way the evidence favours. **UI-Q9:**
  layout animation needs last frame's geometry, but the host holds it and runs
  the comparison after layout; components need not read it, so animation adds
  nothing to the set of results a component may read. **UI-Q10:** an exit is
  retained output driven by the store — the identity's last records painted
  without input until its exit motion settles — so "an overlay is open exactly
  when it is built" stays true, and `LYR10`'s `closing` flag becomes the host's
  state rather than the component's.
- Keep the layout-time mode (siblings reflow) opt-in, at a second layout pass
  on animated frames only, as Clay does.
- Give the recorder host a virtual clock, and resolve reduced motion in the
  host by spec rewriting, with Textual's levels as the model.

---

## Sources

The deep-dives carry the primary sources; this page cites them through the
section links above. The decisions it is measured against are in the
[component-authoring study][ui-decisions] and, for UI-Q9 and UI-Q10, the draft
specification in [PR #775][pr775].

<!-- References -->

[ui-decisions]: ../ui-authoring/index.md#decisions
[pr775]: https://github.com/PetarKirov/sparkles/pull/775
