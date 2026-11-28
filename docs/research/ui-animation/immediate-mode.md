# Immediate-mode GUIs (Dear ImGui, egui, Clay, Nuklear, microui, Gio)

How a GUI that rebuilds its whole description every frame animates without retained widgets: each system keeps a small amount of presentation state in a store keyed by widget identity, advances it with a delta time the host supplies, and either lets the calling code read the animated value back (egui, Dear ImGui, Gio) or interpolates layout output itself between two layout passes (Clay). Nuklear and microui keep almost no animation state at all.

| Field                    | Value                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | C++ (Dear ImGui) · Rust (egui) · C99 (Clay, Nuklear) · ANSI C (microui) · Go (Gio)                                                                                                                                                                                                                                                                                                                          |
| License                  | MIT ([Dear ImGui][imgui-repo]) · MIT OR Apache-2.0 ([egui][egui-repo]) · zlib ([Clay][clay-repo]) · MIT or public domain ([Nuklear][nk-repo]) · MIT ([microui][mu-repo]) · Unlicense OR MIT ([Gio][gio-repo])                                                                                                                                                                                               |
| Repository               | [ocornut/imgui][imgui-repo] · [emilk/egui][egui-repo] · [nicbarker/clay][clay-repo] · [Immediate-Mode-UI/Nuklear][nk-repo] · [rxi/microui][mu-repo] · [gioui/gio][gio-repo] (mirror of `git.sr.ht/~eliasnaur/gio`)                                                                                                                                                                                          |
| Documentation            | Dear ImGui [`docs/FAQ.md`][imgui-faq-diff] · egui [`README.md`][egui-readme-idle] and the doc comments in [`context.rs`][egui-ctx-anim] · Clay [`README.md` § Transitions][clay-readme-transitions] · Nuklear and microui: header comments only · Gio: doc comments ([`op.InvalidateCmd`][gio-invalidate])                                                                                                  |
| Category                 | immediate mode: the application calls widget functions every frame; per-identity state survives in a library-owned store                                                                                                                                                                                                                                                                                    |
| Versions surveyed        | Dear ImGui **1.93.1 WIP** at `bd4e3b0` (2026-11-23) · egui **0.37.0** at `90431d9` (2026-11-24) · Clay at `e6cc369` (2026-05-20) · Nuklear **4.13.4** at `c8bfb4d` (2026-11-26) · microui at `0850aba` (2024-08-13) · Gio at `9816a10` (2026-11-23)                                                                                                                                                         |
| Animation state lives in | egui: `AnimationManager` maps keyed by `Id`, plus widget state in `Memory::data` (`IdTypeMap`) · Dear ImGui: fields of the global `ImGuiContext` and of each `ImGuiWindow`/`ImGuiTabBar`, plus `ImGuiStorage` · Clay: `Clay__TransitionDataInternal` records keyed by element id · Gio: the widget struct the caller owns (`widget.Clickable` press history) · Nuklear/microui: nothing beyond hover timers |

> [!NOTE]
> This page covers animation only. How these systems measure and place elements is in the layout catalog ([Dear ImGui][layout-imgui], [egui][layout-egui], [Clay][layout-clay]); how they handle long lists, including egui's `CollapsingHeader` height cache, is in [Immediate-mode large views][virt-imm]. The terminal analogues (Bubble Tea, Textual, tachyonfx) are on the sibling page [Terminal UIs][tui]. Terms such as _retarget_, _stepped integration_ and _presence_ are defined in [Concepts][concepts]. Every claim was read at the pinned revision.

---

## Overview

### What it solves

An immediate-mode GUI has no widget objects to hang an animation on. A button exists only while the frame's code is calling `ui.button(...)`; the next frame's call is a different call that happens to produce the same identity. Animation therefore needs three things the paradigm does not give for free: a place to keep a value between frames (keyed by identity), a clock (the frame's delta time, from the host), and a way to keep the frame loop running while something moves (otherwise a reactive host sleeps). The systems surveyed solve these in different proportions. egui solves all three in the library; Dear ImGui solves the first two for a fixed set of built-in effects; Clay solves the first two for layout output and leaves the third to the host; Gio puts the clock in the context and the state in the caller's widget struct; Nuklear and microui solve almost none of them.

### Design philosophy

Dear ImGui's FAQ states the trade the paradigm makes ([`docs/FAQ.md`][imgui-faq-diff]):

> _"UI library stores minimal amounts of data. At one point in time, it typically doesn't know or remember which other widgets are displayed and which widgets are coming next."_

egui's README names animation as one of the two reasons the frame loop runs at all ([`README.md`][egui-readme-idle]):

> _"`egui` only repaints when there is interaction (e.g. mouse movement) or an animation, so if your app is idle, no CPU is wasted."_

Clay's README makes the identity requirement explicit ([`README.md`][clay-readme-transitions]):

> _"Note: for transitions to work, elements need a stable ID from one frame to the next - using loop indexes or CLAY_AUTO_ID will not work."_

Gio puts the clock into the per-frame value the caller threads through every widget ([`app/app.go`][gio-frameevent]):

> _"Now is the current animation. Use Now instead of time.Now to synchronize animation and to avoid the time.Now call overhead."_

---

## How it works

### Dear ImGui

Dear ImGui has no animation API. It animates a handful of its own effects, each with a dedicated field advanced by `io.DeltaTime`, which the host must set every frame (`float DeltaTime; // = 1.0f/60.0f`, [`imgui.h`][imgui-io-dt]); `NewFrame` asserts it is positive ([`imgui.cpp`][imgui-dt-assert]).

| Effect                                              | State                                                                                                          | Update rule                                                                                                         |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Modal / Ctrl+Tab background dim                     | `g.DimBgRatio` ([`imgui_internal.h`][imgui-ctx-navwin])                                                        | `+= DeltaTime * 6` towards 1 while a modal is open, `-= DeltaTime * 10` towards 0 otherwise ([source][imgui-dimbg]) |
| Ctrl+Tab window highlight                           | `g.NavWindowingHighlightAlpha`, `g.NavWindowingTimer`, `g.NavWindowingTargetAnim`                              | fades out at `DeltaTime * 10` once the target is cleared ([source][imgui-navwin-fade])                              |
| Flash of an item activated by a shortcut            | `g.NavHighlightActivatedTimer` = `NAV_ACTIVATE_HIGHLIGHT_TIMER` (0.10 s, [source][imgui-navhl-const])          | counted down by `DeltaTime` ([source][imgui-navhl])                                                                 |
| Tab-bar scrolling                                   | `ImGuiTabBar::ScrollingAnim`, `ScrollingTarget`, `ScrollingSpeed` ([`imgui_internal.h`][imgui-tabbar])         | `ImLinearSweep` at a speed chosen to arrive within 0.3 s; teleports if far off ([source][imgui-tab-scroll])         |
| Hover delays (separator highlight, menus, tooltips) | `g.HoveredIdTimer`, `g.HoverItemDelayTimer`, `g.MouseStationaryTimer` ([`imgui_internal.h`][imgui-ctx-timers]) | accumulate `DeltaTime` while the same id stays hovered, reset otherwise ([source][imgui-newframe-timers])           |
| Text cursor blink                                   | `ImGuiInputTextState::CursorAnim`                                                                              | `+= DeltaTime`; visible while `fmod(CursorAnim, 1.20) <= 0.80` ([source][imgui-cursor])                             |

The comment on `LastActiveIdTimer` names the intended consumer: _"Store the last non-zero ActiveId timer since the beginning of activation, useful for animation."_ ([`imgui_internal.h`][imgui-ctx-timers]). Custom widgets animate by reading these id-keyed timers or by keeping their own value in `ImGuiStorage`, the sorted `ImGuiID → int/float/void*` map each window carries ([`imgui.h`][imgui-storage]):

> _"We use it to e.g. store collapse state for a tree (Int 0/1) […] You can use it as custom user storage for temporary values."_

Window scrolling does not animate: `SetScrollY`/`ScrollToItem` store `ScrollTarget`, and the next `Begin` resolves it in one step in `CalcNextScrollFromScrollTargetAndClamp` ([source][imgui-scroll-target]). Tree nodes, popups and tooltips open and close in one frame.

### egui

egui exposes animation as functions on `Context` that take an `Id` and a target and return the current value ([`context.rs`][egui-ctx-anim]):

```rust
// crates/egui/src/context.rs
pub fn animate_bool(&self, id: Id, value: bool) -> f32;                      // Style::animation_time, linear
pub fn animate_bool_responsive(&self, id: Id, value: bool) -> f32;           // cubic_out
pub fn animate_bool_with_time_and_easing(&self, id: Id, target_value: bool,
                                         animation_time: f32, easing: fn(f32) -> f32) -> f32;
pub fn animate_value_with_time(&self, id: Id, target_value: f32, animation_time: f32) -> f32;
```

The state behind them is `AnimationManager`, two `IdMap`s inside the context ([`animation_manager.rs`][egui-am-struct]):

```rust
pub(crate) struct AnimationManager {
    bools: IdMap<BoolAnim>,   // BoolAnim  { last_value: f32, last_tick: f64 }
    values: IdMap<ValueAnim>, // ValueAnim { from_value: f32, to_value: f32, toggle_time: f64 }
}
```

The two kinds are integrated differently:

- **`animate_bool` is stepped.** Each call adds `(end - start) * elapsed / animation_time` to `last_value`, with `elapsed` clamped to `input.stable_dt`, and clamps to `[0, 1]` ([source][egui-am-bool]). The first call returns the target immediately (no enter animation for a widget seen for the first time). Easing is applied to the output, flipped for the closing direction: `easing(v)` when the target is `true`, `1 - easing(1 - v)` when it is `false` ([source][egui-ctx-bool-easing]).
- **`animate_value_with_time` is closed form.** It remaps `time - toggle_time` (plus half a `predicted_dt`, _"On the frame we toggle we don't want to return the old value, so we extrapolate forwards by half a frame"_) linearly from `from_value` to `to_value`. When the target changes it sets `from_value` to the value it would have returned and restarts the clock ([source][egui-am-value]).

Both wrappers call `request_repaint()` only while the value is strictly between its endpoints (`0.0 < animated_value && animated_value < 1.0`, or `animated_value != target_value`), so a settled animation costs nothing ([source][egui-ctx-bool-easing], [source][egui-ctx-value]). The manager never evicts an entry; `clear_animations` drops all of them ([source][egui-ctx-clear]).

Time comes from `InputState`. `RawInput::time` is optional: _"If `None` is provided, egui will assume a time delta of `predicted_dt` (default 1/60 seconds)"_ ([`raw_input.rs`][egui-raw-time]). `stable_dt` exists because egui sleeps when idle ([`input_state/mod.rs`][egui-stable-dt]):

> _"If `egui` requested a repaint the previous frame, then `egui` will use `stable_dt = unstable_dt;`, but if `egui` did not not request a repaint last frame, then `egui` will assume `unstable_dt` is too large, and will use `stable_dt = predicted_dt;`."_

The global duration is `Style::animation_time` (_"How many seconds a typical animation should last"_, default `0.2`, [`style.rs`][egui-style-time]). Easing curves live in `emath::easing` (_"Contains most easing functions from https://easings.net/"_, [`easing.rs`][egui-easing]), plus `emath::ease_in_ease_out` (smoothstep) and `emath::interpolation_factor`, which turns a `(start, end)` time span and the frame's `dt` into the fraction of the _remaining_ distance to cover this frame, so a lerp from the current position stays on the eased curve ([`emath/src/lib.rs`][egui-interp-factor]).

Built-in widgets that animate:

- **`CollapsingHeader` / `CollapsingState`.** `openness()` is `animate_bool_responsive(id, open)`; while `0 < openness < 1` the body is built every frame inside a child `Ui` whose clip rect is cut to `openness × open_height`, and the parent is told the child took only that much space (`force_set_min_rect`). `open_height` is the body's height from the last fully open frame, stored in `Memory::data` as `InnerState { open, open_height }`; with no stored height the first animated frame uses `fallback_height_guess = 10.0` ([`collapsing_header.rs`][egui-collapse-state], [body][egui-collapse-body]).
- **`Window` fade-out.** `Window::show` computes `opacity = animate_bool_with_easing(area.id.with("fade-out"), is_open, cubic_out)` and returns `None` only once `opacity <= 0.0`; until then the window is built normally and `multiply_opacity(opacity)` is applied ([`window.rs`][egui-window-fade], [apply][egui-window-opacity]). Fade-in is `Area`'s: `AreaState::last_became_visible_at` is set on the first frame the layer was not visible last frame, and the content `Ui` gets `quadratic_out(age / animation_time)` opacity ([`area.rs`][egui-area-state], [set][egui-area-visible], [apply][egui-area-fade]).
- **`ScrollArea` programmatic scrolls.** `scroll_to_*` records `ScrollingToTarget { animation_time_span, target_offset }`; each frame moves `offset` by `interpolation_factor(span, time, dt, ease_in_ease_out)` towards the target. Duration is distance over `ScrollAnimation::points_per_second` (1000) clamped to `0.1..=0.3` s ([`scroll_area.rs`][egui-scroll-target], [step][egui-scroll-step], [start][egui-scroll-start], [`style.rs`][egui-scroll-anim]).

Other widget state that the animations read sits in `Memory::data`, an `IdTypeMap` (`id XOR typeid` keys, temporary or persisted values) documented as _"superficial state for all widgets with custom [`Id`]s"_ ([`memory/mod.rs`][egui-memory-data], [`id_type_map.rs`][egui-idtypemap]).

### Clay

Clay is a layout engine that returns a flat array of render commands; since the surveyed revision it also has a **transition** API that interpolates its own layout output ([`README.md`][clay-readme-transitions]: _"Both layout-affecting properties such as `width` and `height`, as well as non-layout properties such as `backgroundColor` are supported."_). An element opts in by declaring a handler:

```c
// README.md — Transitions
CLAY(CLAY_IDI("box", colors[index].id), {
    .backgroundColor = boxColor,
    .transition = {
        .handler = Clay_EaseOut,
        .duration = 0.5f,
        .properties = CLAY_TRANSITION_PROPERTY_WIDTH | CLAY_TRANSITION_PROPERTY_POSITION
                    | CLAY_TRANSITION_PROPERTY_OVERLAY_COLOR | CLAY_TRANSITION_PROPERTY_BACKGROUND_COLOR,
        .enter = { .setInitialState = EnterExitSlideUp },
        .exit  = { .setFinalState  = EnterExitSlideUp },
    }
}) { /* children */ }
```

The configuration types are in [`clay.h`][clay-types]: `Clay_TransitionData` (bounding box, background, overlay and border colour, border width), the state enum `IDLE / ENTERING / TRANSITIONING / EXITING`, the property bit set, enter and exit triggers relative to the parent, the exiting element's sibling ordering, and whether pointer interaction is disabled while position transitions. The handler is a plain function `bool (*handler)(Clay_TransitionCallbackArguments)` receiving `initial`, a pointer to `current`, `target`, `elapsedTime`, `duration` and the active property set, and returning `true` when done; `Clay_EaseOut` is the built-in cubic ease-out lerp ([source][clay-easeout]). Time is the argument to `Clay_EndLayout(float deltaTime)` ([`clay.h`][clay-endlayout-decl]; the README loop passes `deltaTime` _"the time since the last frame, and is used for transitions"_, [`README.md`][clay-readme-loop]).

`Clay_EndLayout` runs the engine as follows ([source][clay-endlayout]):

1. **Track.** Opening an element that has a handler finds or creates its `Clay__TransitionDataInternal` (keyed by `elementId`, also recording `parentId`, `siblingIndex`, and `reparented` if the parent id changed). Re-declaring an element that is mid-exit resets it to `IDLE` ([source][clay-open-transition]).
2. **Prune.** Records whose element was not declared this frame and that have no exit state are dropped ([source][clay-prune]).
3. **Resurrect exiting elements.** A record with `transitionOut` whose element was not declared this frame starts exiting: on the first frame its last frame's size is frozen into `CLAY_SIZING_FIXED`, it is reattached to the root as floating at its last bounding box if the parent is also gone, and `setFinalState` computes the exit target. On every exiting frame the element's retained subtree — the `Clay_LayoutElement`s copied out of the previous frame by `Clay__CloneElementsWithExitTransition` — is cloned back into this frame's tree and reinserted under its old parent at the configured sibling position ([source][clay-exit-start], [clone][clay-exit-clone], [reattach][clay-reattach], [`Clay__CloneElementsWithExitTransition`][clay-clone-exit]). `Clay_LayoutElement::exiting` marks these _"synthetic"_ elements whose _"data was retained from previous frames"_ ([source][clay-exiting-flag]).
4. **Layout pass 1** without render commands, to get every element's target bounding box: `Clay__CalculateFinalLayout(deltaTime, false, false)` ([source][clay-two-pass]).
5. **Diff and step.** For each record the target is this pass's bounding box and colours. An element that appeared this frame enters from `setInitialState(target)` (unless the parent also just appeared and the trigger is `SKIP_ON_FIRST_PARENT_FRAME`). Otherwise each enabled property whose target differs from last frame's target starts a transition from `currentState` with `elapsedTime = 0`; a position change counts only if the parent-relative position changed (a moving parent does not animate its children separately) and never on the frame after a root resize ([enter][clay-enter], [diff][clay-retarget]). The handler is called, its output written back into the element (`width`/`height` become `CLAY_SIZING_FIXED` of the animated size, so children re-lay out inside it), and `elapsedTime += deltaTime` ([source][clay-handler], [`Clay_ApplyTransitionedPropertiesToElement`][clay-apply]).
6. **Layout pass 2** with render commands, using the stored animated bounding boxes in place of computed ones for transitioning elements ([source][clay-final-pass], [stored boxes][clay-stored-boxes]), then the exiting subtrees are copied aside for the next frame.

Scroll containers have momentum: `Clay_UpdateScrollContainers(enableDragScrolling, scrollDelta, deltaTime)` adds `scrollMomentum` to the position and multiplies it by `0.95` per call ([`clay.h`][clay-scroll-decl], [momentum][clay-momentum]). Clay reports nothing to the host about whether a transition is running; the raylib example redraws every frame (`while (!WindowShouldClose())`, `Clay_EndLayout(GetFrameTime())`, [`main.c`][clay-example-loop]).

### Nuklear and microui

Neither has animation. Nuklear's context carries `float delta_time_seconds`, set by the platform glue ([`nuklear.h`][nk-dt]); it feeds two kinds of timer: the hover-with-delay queries (`nk_input_is_mouse_hovering_delay_rect` and its `_still_` variants accumulate into a caller-supplied `float* timer`, [source][nk-hover-delay]; tooltips use them for their delay, [source][nk-tooltip-delay]) and auto-hiding scrollbars, which simply stop drawing once `scrollbar_hiding_timer` passes `NK_SCROLLBAR_HIDING_TIMEOUT` (4 s) — no fade ([source][nk-scroll-hide], [timeout][nk-scroll-timeout], [default][nk-scroll-default]). Per-id state is `nk_table`, pages of `nk_hash → nk_uint` pairs owned by a window (used for tree-node open state, [source][nk-table], [`nk_find_value`][nk-find-value]); windows not touched in a frame are garbage-collected in `nk_clear` by comparing `seq` ([source][nk-gc]).

microui has no time input at all: the context has an integer `frame` counter and two retained pools, `container_pool` and `treenode_pool`, of `mu_PoolItem { mu_Id id; int last_update; }`, recycled least-recently-updated first ([`microui.h`][mu-ctx], [`mu_PoolItem`][mu-poolitem], [`mu_pool_init`][mu-pool]). Its README sells the constraint: _"Works within a fixed-sized memory region: no additional memory is allocated"_ ([`README.md`][mu-readme]).

### Gio

Gio's per-frame value `layout.Context` carries `Now time.Time` (_"Now is the animation time"_, [`layout/context.go`][gio-context]), copied from `app.FrameEvent.Now` ([`app/app.go`][gio-frameevent]). A widget that wants another frame executes `op.InvalidateCmd{At: t}` (_"requests a redraw at the given time. Use the zero value to request an immediate redraw"_, [`op/op.go`][gio-invalidate]); the router keeps the earliest requested time ([`io/input/router.go`][gio-router-invalidate], [`WakeupTime`][gio-wakeup]) and the window either animates continuously or arms a timer for it ([`app/window.go`][gio-window-anim]). `widget.Editor` uses the `At` form for caret blink ([source][gio-editor-blink]); `material.Loader` derives its rotation from `gtx.Now` modulo one second and invalidates every frame ([source][gio-loader]).

State lives in the widget struct the application keeps. `widget.Clickable` holds `history []Press`, each `Press { Position, Start, End time.Time, Cancelled bool }`; presses are appended on `KindPress`, stamped with `End` on click or cancel, and pruned one second after they end ([`widget/button.go`][gio-press], [prune and record][gio-press-update]). `material`'s `drawInk` is a pure function of a `Press` and `gtx.Now`: it computes fade and expansion fractions from `now - Start` and `now - End`, fast-forwards a cancelled press, returns early when the ink is _"Too old"_, and executes `op.InvalidateCmd{}` only while the press is fading in or has ended ([`widget/material/button.go`][gio-ink]).

Fling scrolling is the one physics animation. `gesture.Scroll` samples pointer velocity with `fling.Extrapolation`, and on release starts `fling.Animation`, a closed-form exponential decay `x(t) = v0·e^(kt)/k − v0/k` with `k = −4.2` (`−2` on Darwin) that `Tick(now)` evaluates and that stops below 1 px/s ([`internal/fling/animation.go`][gio-fling], [`gesture/gesture.go`][gio-gesture-fling]). `layout.List` scrolls through `gesture.Scroll`, so it inherits fling; `List.ScrollBy`/`ScrollTo` are instantaneous ([`layout/list.go`][gio-list-scrollby]).

---

## Analysis

### Where animation state lives

Every system keys animation state by the widget's identity, never by a widget object:

| System     | Store                                                                                                        | Key                                        | Lifetime                                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| egui       | `AnimationManager` (`IdMap<BoolAnim>`, `IdMap<ValueAnim>`) + `Memory::data` (`IdTypeMap`)                    | `Id` (caller-chosen, often `id.with("…")`) | animations: never evicted; `Memory::data`: until removed, and across restarts with the `persistence` feature |
| Dear ImGui | `ImGuiContext` scalars (one hovered/active/nav item at a time), `ImGuiTabBar`, `ImGuiWindow`, `ImGuiStorage` | `ImGuiID`                                  | context lifetime; windows compacted after `ConfigMemoryCompactTimer` ([`imgui.h`][imgui-compact])            |
| Clay       | `Clay__TransitionDataInternalArray`                                                                          | element id (must be explicit)              | until the element is undeclared and its exit completes                                                       |
| Gio        | the caller's widget value (`Clickable.history`, `gesture.Scroll.flinger`)                                    | Go value identity                          | the caller's                                                                                                 |
| Nuklear    | `nk_table` pages per window; caller-owned `float*` timers                                                    | `nk_hash`                                  | window GC by `seq`                                                                                           |
| microui    | fixed `container_pool` / `treenode_pool`                                                                     | `mu_Id`                                    | LRU by frame                                                                                                 |

Dear ImGui's scalars are notable for what they rule out: `HoveredIdTimer` and `ActiveIdTimer` exist once, for the single hovered and single active item ([source][imgui-newframe-timers]), so "the button that was hovered a moment ago fades out" is not expressible with them. egui's per-`Id` maps are what make that fade cheap.

### Declaring an animation

All are **declarative targets, re-stated every frame**: egui's `animate_bool(id, open)` and Clay's `.transition` config are called with the current target each frame, and the system decides whether the target changed. The animation is implicit in the sense of [Concepts][concepts-implicit] — the caller never names a start value. egui is a _read_ API (the caller gets an `f32` and uses it however it likes, typically for opacity, a clip height, or an icon rotation); Clay is a _write_ API (the engine overwrites the element's bounding box and colours, and the caller never sees the animated values). Dear ImGui's effects are hard-coded; Gio's are computed by the caller from timestamps the widget recorded. None has an imperative controller with `play`/`reverse`.

### Time and the clock

The host owns the clock everywhere; the library never reads the wall clock:

- Dear ImGui and Nuklear take a per-frame delta (`io.DeltaTime`, `ctx->delta_time_seconds`) and integrate it. microui takes none.
- egui takes an absolute `time` (optional) plus `predicted_dt`, and derives `stable_dt` to protect stepped animations from the long gap after an idle sleep ([source][egui-stable-dt]). `animate_value_with_time` and the scroll and `Area` fades are closed-form in `time`; `animate_bool` is stepped and therefore frame-rate-sensitive only through the `stable_dt` clamp.
- Clay takes a delta in `Clay_EndLayout(deltaTime)` and accumulates `elapsedTime`; its scroll momentum decays by a per-call factor (`*= 0.95`), so its speed depends on the frame rate ([source][clay-momentum]).
- Gio takes an absolute `Now` and every surveyed animation is a closed-form function of `Now` and recorded timestamps — the most deterministic arrangement here.

### Interruption and retargeting

None of the immediate-mode systems carries velocity across a retarget:

- **egui `animate_bool`** reverses in place: the stepped `last_value` simply starts moving the other way at constant rate. Because easing is applied to the output and mirrored for the closing direction, a reversal with an asymmetric curve jumps: for `cubic_out` at `last_value = 0.5` the opening output is `easing(0.5) = 0.875` and the closing output is `1 − easing(0.5) = 0.125` (arithmetic on [source][egui-ctx-bool-easing]). `CollapsingHeader` uses `cubic_out` ([source][egui-collapse-state]).
- **egui `animate_value_with_time`** restarts from the current value with a fresh full duration (restart from current value, zero velocity) ([source][egui-am-value]). **`ScrollArea`** keeps the running time span and moves only `target_offset` when a new scroll request arrives mid-animation (_"the user is continuously calling `ui.scroll_to_cursor`, so we don't want to reset the animation, but perhaps update the target"_, [source][egui-scroll-start]).
- **Clay** restarts from `currentState` with `elapsedTime = 0` and ORs the newly changed properties into the active set ([source][clay-retarget]); re-declaring an exiting element cancels the exit ([source][clay-open-transition]).
- **Dear ImGui's** tab-bar sweep keeps `ScrollingSpeed` as a running maximum while moving, so a retarget never slows it ([source][imgui-tab-scroll]). **Gio's** fling restarts from a fresh velocity estimate on each release.

### Curves and springs

Duration plus easing throughout; no system has a spring. egui ships the easings.net set (`linear`, `quadratic_*`, `cubic_*`, `sin_*`, `circular_*`, `exponential_*`, `back_*`, `bounce_*`) as `fn(f32) -> f32` and as the `Easing` enum, plus smoothstep for scrolling ([source][egui-easing]). Clay ships one handler (cubic ease-out) and lets the caller write any `bool handler(args)`, which is general enough to host a spring if the caller keeps velocity elsewhere — the handler gets `current` but no velocity field ([source][clay-types]). Dear ImGui's effects are linear ramps. Gio's ink uses smoothstep on two phase fractions; its fling is the only physical model (exponential drag, closed form, [source][gio-fling]).

### Layout animation

Two different strategies, in two different phases:

- **egui animates in user code, inside the build pass, with last frame's geometry.** `CollapsingHeader` needs the body's full height to animate it, and the only height it has is `open_height` remembered from the last fully open frame (or a guess of `10.0`). The body is built in full every animated frame, clipped to the animated height, and the parent is told the reduced size through `force_set_min_rect` — so siblings below move, because the animated value feeds layout before they are placed ([source][egui-collapse-body]). This is UI-Q9's case ([PR #775][pr775]): the component reads a committed size from the store and that read decides what space it claims.
- **Clay animates inside the layout phase, with this frame's geometry.** It runs layout twice per frame: pass 1 computes targets, the handler interpolates from the previous `currentState`, and pass 2 lays out again with animated bounding boxes substituted, so an animated `width` reflows children inside it ([source][clay-endlayout], [stored boxes][clay-stored-boxes]). It needs the previous frame's _animated_ state (kept in the record) and the previous frame's _target_ (to detect a change), but not a measurement from user code; user code never sees the animated rect.

Dear ImGui and Nuklear do not animate geometry; Gio's ink is paint-only (an offset clip and a colour, computed during the frame's op recording), and its fling changes scroll position, which feeds the next layout of `layout.List`. None defers animation to a compositor: every system re-records its whole display list each animated frame.

### Enter and exit

Three mechanisms, all relevant to UI-Q10 ([PR #775][pr775]):

1. **Closing state driven by the store, with the caller still building (egui).** `Window` stays open-in-code while closing: the application keeps calling `Window::new(…).open(&mut open)` with `open == false`, and `show` builds the full window at decreasing opacity until `animate_bool` reaches 0 ([source][egui-window-fade]). If the application stops calling `show`, the window vanishes the same frame; the library holds no snapshot. `CollapsingHeader` is the same: the body closure keeps running while `openness > 0`.
2. **Retained snapshot driven by the engine (Clay).** An element not declared this frame but configured with `exit.setFinalState` is resurrected from a copy of its previous frame's layout subtree, frozen at its last size, re-parented (or floated at its last position if the parent is gone), and animated to the final state; nested transitions inside it are removed ([source][clay-exit-clone], [`Clay__CloneElementsWithExitTransition`][clay-clone-exit]). The clone copies `Clay_LayoutElement` values, so a text element keeps the `Clay_String` slice it was declared with (only its wrapped lines are reset and recomputed, [source][clay-exit-clone]); by inference, the caller's string memory must stay valid for the whole exit. Enter is the symmetric `setInitialState(target)` on the first declared frame, with parent-relative triggers ([source][clay-enter]).
3. **A retained pointer for one effect (Dear ImGui).** `NavWindowingTargetAnim` is a _"Record of last valid NavWindowingTarget until DimBgRatio and NavWindowingHighlightAlpha becomes 0.0f, so the fade-out can stay on it"_ ([source][imgui-ctx-navwin]) — the hand-written form of "keep painting the departed thing".

Gio's ink shows a fourth, caller-owned form: a press stays in `history` for a second after it ends, so the ink keeps painting after the gesture is over ([source][gio-press-update]). Nuklear and microui have no enter or exit.

### Scheduling, reduced motion and testing

**Frame requests.** egui requests a repaint only while an animated value is strictly in flight ([source][egui-ctx-bool-easing]); Gio requests one only while the ink or fling is live, and can request a future frame with `InvalidateCmd{At}` ([source][gio-invalidate]). Clay, Dear ImGui, Nuklear and microui never report "still animating"; their examples redraw continuously (Dear ImGui's GLFW example sleeps only while iconified, [`main.cpp`][imgui-example-loop]; Clay's raylib example, [`main.c`][clay-example-loop]).

**Reduced motion.** No surveyed system reads a reduced-motion preference. egui's equivalent is a style knob: `animation_time = 0.0` makes `animate_bool` jump (division by zero gives a non-finite step, which is replaced by `end`, [source][egui-am-bool]) and `animate_value_with_time` returns the target ([source][egui-am-value]); `ScrollAnimation::none()` disables scroll animation ([source][egui-scroll-anim]).

**Testing.** egui's `egui_kittest` harness sets exactly those knobs — _"The scroll animation is disabled"_, `style.animation_time = 0.0` — and drives frames with a fixed `step_dt` written into `predicted_dt` while `RawInput::time` stays `None`, so time advances by a constant per frame; `Harness::run` steps _"until all animations are done [and] no more repaints are requested"_ ([`egui_kittest/src/lib.rs`][kittest-defaults], [style][kittest-style], [step][kittest-step], [run][kittest-run]). Gio's closed-form design makes any frame reproducible by constructing a `layout.Context` with a chosen `Now` (the zero `Context` _"returns the zero time from Now"_, [source][gio-context]). Clay and Dear ImGui are deterministic given the delta sequence the test passes.

### Lessons for sparkles:ui

- **The element store is the right home, and identity must be explicit for anything that animates.** Clay refuses auto ids for transitions; egui derives sub-keys such as `area.id.with("fade-out")`. sparkles' positional/keyed 64-bit identity can serve, but a positional id that shifts when a sibling is inserted will retarget the wrong element's animation — the same failure Clay warns about.
- **Reading animated values is pure if the clock is an input.** egui's `animate_bool` mutates the store from inside the build call, which a `pure` component cannot do. The Gio arrangement fits sparkles better: the store holds timestamps and targets committed by the host; the component reads `(now, committed state)` and computes the value in closed form; the host decides "still animating" from the same data after commit. egui's `stable_dt` problem disappears when nothing is stepped.
- **Two layout-animation phases exist and give different answers to UI-Q9.** egui's is user-code-reads-last-frame-size (needs a committed `open_height`, wrong on the first frame); Clay's is layout-runs-twice (needs no user read, costs a second layout pass only on frames with active transitions, and keeps animated geometry out of component code). A host-side, Clay-style pass fits "components may read but not write the store".
- **For UI-Q10 the two candidates are both proven.** egui's closing state requires the component to keep building the overlay while it closes — at odds with "an overlay is open iff it is built this frame" unless "built" includes "closing". Clay's retained subtree needs no component cooperation but must copy last frame's elements (including borrowed strings) and handle a vanished parent.
- **Velocity is absent everywhere here.** If sparkles wants springs with retarget continuity, the store must hold velocity alongside value; none of these systems is a template for that (see [Bubble Tea and harmonica][tui]).
- **Avoid output-side easing flips** (egui) and per-frame decay factors (Clay momentum); both are frame-rate or reversal artefacts.

---

## Strengths

- Animation state is small, flat, and keyed by the same identity the frame already computes; no widget object or callback is needed.
- egui's API is one function call returning a number; anything (opacity, clip height, rotation) can be animated with it, and it schedules frames itself.
- Clay animates layout output generically — position, size and colour of any element, including enter and exit — without the caller ever handling animated geometry.
- Gio's closed-form timestamp style is deterministic and testable with a synthetic `Now`.
- Hosts that redraw continuously (games, tools) need nothing beyond a delta time.

## Weaknesses

- No velocity, no springs, no retarget continuity in any of the six.
- egui's exit animations need the caller to keep calling the widget; its animation map is never pruned; its eased bool jumps on reversal.
- egui's collapsing animation depends on last frame's measured height and guesses on first open.
- Clay doubles layout work while any transition is active, copies retained subtrees per exiting frame, and does not tell the host when to stop redrawing.
- Dear ImGui's timers are global singletons, not per-item; Nuklear and microui offer nothing.
- No system honours a platform reduced-motion preference.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                                 | Trade-off                                                                                        |
| ------------------------------------------------------------ | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Animation keyed by widget id in a library map (egui, Clay)   | the paradigm has no widget objects; ids are already computed every frame  | unstable ids silently retarget or restart animations; maps need eviction policy                  |
| `animate_bool(id, target) -> f32` read API (egui)            | composable with any visual property; one call                             | mutates the store from the build call; reversal discontinuity with asymmetric easing             |
| Request a repaint only while in flight (egui, Gio)           | reactive hosts sleep when idle                                            | the stepped path needs `stable_dt` to absorb the first frame after a sleep                       |
| Two layout passes with animated boxes substituted (Clay)     | layout-affecting properties animate and children reflow without user code | double layout cost during transitions; animated geometry hidden from the caller                  |
| Retained subtree resurrected for exit (Clay)                 | exit works without the caller declaring the departing element             | copies last frame's elements; borrowed strings must outlive the exit; parent loss needs floating |
| Closing state with the caller still building (egui `Window`) | no snapshot machinery; the window stays fully live while fading           | caller must keep calling `show`; stopping the call cuts the animation                            |
| Timestamps in caller state, closed-form evaluation (Gio)     | deterministic, frame-rate independent, testable with a synthetic `Now`    | each widget writes its own animation math                                                        |
| Global single-item timers (Dear ImGui)                       | minimal state; enough for hover delays and one highlight                  | cannot fade an item that is no longer hovered/active                                             |
| No time input at all (microui)                               | fixed memory, minimal API                                                 | no animation is possible inside the library                                                      |

## Sources

- Dear ImGui `bd4e3b0`: [`docs/FAQ.md`][imgui-faq-diff], [`imgui.h`][imgui-storage], [`imgui_internal.h`][imgui-ctx-timers], [`imgui.cpp`][imgui-newframe-timers], [`imgui_widgets.cpp`][imgui-tab-scroll], [`examples/example_glfw_opengl3/main.cpp`][imgui-example-loop]
- egui `90431d9`: [`animation_manager.rs`][egui-am-struct], [`context.rs`][egui-ctx-anim], [`input_state/mod.rs`][egui-stable-dt], [`raw_input.rs`][egui-raw-time], [`style.rs`][egui-style-time], [`collapsing_header.rs`][egui-collapse-body], [`window.rs`][egui-window-fade], [`area.rs`][egui-area-fade], [`scroll_area.rs`][egui-scroll-step], [`emath/src/easing.rs`][egui-easing], [`emath/src/lib.rs`][egui-interp-factor], [`memory/mod.rs`][egui-memory-data], [`id_type_map.rs`][egui-idtypemap], [`egui_kittest/src/lib.rs`][kittest-run], [`README.md`][egui-readme-idle]; `Context::animate_bool` was introduced on 2020-08-30 ([`24003b1`][egui-first-anim])
- Clay `e6cc369`: [`clay.h`][clay-types], [`README.md`][clay-readme-transitions], [`examples/raylib-transitions/main.c`][clay-example-enter]
- Nuklear `c8bfb4d`: [`nuklear.h`][nk-dt]
- microui `0850aba`: [`src/microui.h`][mu-ctx], [`src/microui.c`][mu-pool], [`README.md`][mu-readme]
- Gio `9816a10`: [`op/op.go`][gio-invalidate], [`layout/context.go`][gio-context], [`app/app.go`][gio-frameevent], [`app/window.go`][gio-window-anim], [`io/input/router.go`][gio-router-invalidate], [`widget/button.go`][gio-press], [`widget/material/button.go`][gio-ink], [`internal/fling/animation.go`][gio-fling], [`gesture/gesture.go`][gio-gesture-fling]
- Related pages: [Dear ImGui layout][layout-imgui], [egui layout][layout-egui], [Clay layout][layout-clay], [Immediate-mode large views][virt-imm], [Terminal UIs][tui], [Concepts][concepts], [UI authoring][ui-authoring]

<!-- References -->

[imgui-repo]: https://github.com/ocornut/imgui/tree/bd4e3b0abccd653490d68beeb72f0750cde6d5f6
[imgui-faq-diff]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/docs/FAQ.md#L96-L111
[imgui-io-dt]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.h#L2470
[imgui-compact]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.h#L2510
[imgui-storage]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.h#L2856-L2864
[imgui-ctx-timers]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui_internal.h#L2384-L2411
[imgui-ctx-navwin]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui_internal.h#L2526-L2537
[imgui-tabbar]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui_internal.h#L2969-L2983
[imgui-navhl-const]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.cpp#L1417
[imgui-newframe-timers]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.cpp#L5763-L5795
[imgui-dimbg]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.cpp#L5912-L5916
[imgui-dt-assert]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.cpp#L11243-L11250
[imgui-scroll-target]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.cpp#L12170-L12193
[imgui-navhl]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.cpp#L14220-L14224
[imgui-navwin-fade]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.cpp#L14931-L14936
[imgui-tab-scroll]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui_widgets.cpp#L10355-L10371
[imgui-cursor]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui_widgets.cpp#L5767-L5768
[imgui-example-loop]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/examples/example_glfw_opengl3/main.cpp#L134-L147
[egui-repo]: https://github.com/emilk/egui/tree/90431d979ab1faae2de6d9f736e9d33ca0d31956
[egui-readme-idle]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/README.md#L234
[egui-am-struct]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/animation_manager.rs#L6-L26
[egui-am-bool]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/animation_manager.rs#L30-L66
[egui-am-value]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/animation_manager.rs#L68-L112
[egui-ctx-anim]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/context.rs#L3726-L3832
[egui-ctx-bool-easing]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/context.rs#L3770-L3804
[egui-ctx-value]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/context.rs#L3806-L3826
[egui-ctx-clear]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/context.rs#L3828-L3831
[egui-stable-dt]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/input_state/mod.rs#L270-L311
[egui-raw-time]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/data/input/raw_input.rs#L47-L54
[egui-style-time]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/style.rs#L316-L318
[egui-scroll-anim]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/style.rs#L948-L980
[egui-easing]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/emath/src/easing.rs#L1-L12
[egui-interp-factor]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/emath/src/lib.rs#L442-L466
[egui-collapse-state]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/collapsing_header.rs#L10-L80
[egui-collapse-body]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/collapsing_header.rs#L175-L240
[egui-window-fade]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/window.rs#L635-L644
[egui-window-opacity]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/window.rs#L707-L712
[egui-area-state]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/area.rs#L37-L41
[egui-area-visible]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/area.rs#L540-L545
[egui-area-fade]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/area.rs#L698-L710
[egui-scroll-target]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/scroll_area.rs#L18-L23
[egui-scroll-step]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/scroll_area.rs#L1001-L1029
[egui-scroll-start]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/scroll_area.rs#L1250-L1268
[egui-memory-data]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/memory/mod.rs#L35-L48
[egui-idtypemap]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/util/id_type_map.rs#L405-L420
[kittest-defaults]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui_kittest/src/lib.rs#L133-L135
[kittest-style]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui_kittest/src/lib.rs#L244-L248
[kittest-step]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui_kittest/src/lib.rs#L401-L402
[kittest-run]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui_kittest/src/lib.rs#L458-L483
[egui-first-anim]: https://github.com/emilk/egui/commit/24003b17a320d009fee0558b256042b97ac0c64b
[clay-repo]: https://github.com/nicbarker/clay/tree/e6cc36941ab2af5d81107617039d6f527a1c660b
[clay-readme-loop]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/README.md#L109
[clay-readme-transitions]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/README.md#L488-L521
[clay-types]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L563-L640
[clay-scroll-decl]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L954-L958
[clay-endlayout-decl]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L967-L970
[clay-exiting-flag]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L1226-L1228
[clay-open-transition]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L2182-L2213
[clay-stored-boxes]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L2918-L2928
[clay-momentum]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4279-L4290
[clay-clone-exit]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4374-L4405
[clay-apply]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4410-L4440
[clay-endlayout]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4447-L4816
[clay-prune]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4459-L4470
[clay-exit-start]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4482-L4503
[clay-exit-clone]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4505-L4552
[clay-reattach]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4554-L4583
[clay-two-pass]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4613-L4614
[clay-enter]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4633-L4646
[clay-retarget]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4647-L4711
[clay-handler]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4713-L4744
[clay-final-pass]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4761-L4763
[clay-easeout]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L4977-L5030
[clay-example-enter]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/examples/raylib-transitions/main.c#L73-L82
[clay-example-loop]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/examples/raylib-transitions/main.c#L242
[nk-repo]: https://github.com/Immediate-Mode-UI/Nuklear/tree/c8bfb4df1298c89056b4b597a9209034ac5201c0
[nk-scroll-default]: https://github.com/Immediate-Mode-UI/Nuklear/blob/c8bfb4df1298c89056b4b597a9209034ac5201c0/nuklear.h#L219-L220
[nk-table]: https://github.com/Immediate-Mode-UI/Nuklear/blob/c8bfb4df1298c89056b4b597a9209034ac5201c0/nuklear.h#L5996-L6002
[nk-dt]: https://github.com/Immediate-Mode-UI/Nuklear/blob/c8bfb4df1298c89056b4b597a9209034ac5201c0/nuklear.h#L6042
[nk-hover-delay]: https://github.com/Immediate-Mode-UI/Nuklear/blob/c8bfb4df1298c89056b4b597a9209034ac5201c0/nuklear.h#L18583-L18598
[nk-tooltip-delay]: https://github.com/Immediate-Mode-UI/Nuklear/blob/c8bfb4df1298c89056b4b597a9209034ac5201c0/nuklear.h#L31556
[nk-gc]: https://github.com/Immediate-Mode-UI/Nuklear/blob/c8bfb4df1298c89056b4b597a9209034ac5201c0/nuklear.h#L19796-L19803
[nk-find-value]: https://github.com/Immediate-Mode-UI/Nuklear/blob/c8bfb4df1298c89056b4b597a9209034ac5201c0/nuklear.h#L20199-L20232
[nk-scroll-timeout]: https://github.com/Immediate-Mode-UI/Nuklear/blob/c8bfb4df1298c89056b4b597a9209034ac5201c0/nuklear.h#L20632-L20636
[nk-scroll-hide]: https://github.com/Immediate-Mode-UI/Nuklear/blob/c8bfb4df1298c89056b4b597a9209034ac5201c0/nuklear.h#L20719-L20727
[mu-repo]: https://github.com/rxi/microui/tree/0850aba860959c3e75fb3e97120ca92957f9d057
[mu-readme]: https://github.com/rxi/microui/blob/0850aba860959c3e75fb3e97120ca92957f9d057/README.md#L1-L11
[mu-poolitem]: https://github.com/rxi/microui/blob/0850aba860959c3e75fb3e97120ca92957f9d057/src/microui.h#L117
[mu-ctx]: https://github.com/rxi/microui/blob/0850aba860959c3e75fb3e97120ca92957f9d057/src/microui.h#L182-L202
[mu-pool]: https://github.com/rxi/microui/blob/0850aba860959c3e75fb3e97120ca92957f9d057/src/microui.c#L346-L373
[gio-repo]: https://github.com/gioui/gio/tree/9816a101b3010936a1a250426703aa56bb9444e6
[gio-invalidate]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/op/op.go#L98-L102
[gio-context]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/layout/context.go#L15-L24
[gio-frameevent]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/app/app.go#L45-L48
[gio-window-anim]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/app/window.go#L355-L371
[gio-router-invalidate]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/io/input/router.go#L586-L590
[gio-wakeup]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/io/input/router.go#L922-L930
[gio-editor-blink]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/widget/editor.go#L778
[gio-loader]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/widget/material/loader.go#L40-L50
[gio-press]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/widget/button.go#L34-L44
[gio-press-update]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/widget/button.go#L106-L147
[gio-ink]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/widget/material/button.go#L200-L297
[gio-fling]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/internal/fling/animation.go#L13-L95
[gio-gesture-fling]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/gesture/gesture.go#L300-L344
[gio-list-scrollby]: https://github.com/gioui/gio/blob/9816a101b3010936a1a250426703aa56bb9444e6/layout/list.go#L379-L384
[layout-imgui]: ../ui-layout/dear-imgui.md
[layout-egui]: ../ui-layout/egui.md
[layout-clay]: ../ui-layout/clay.md
[virt-imm]: ../ui-virtualization/immediate-mode-large-views.md
[ui-authoring]: ../ui-authoring/index.md
[tui]: ./terminal-uis.md
[concepts]: ./concepts.md
[concepts-implicit]: ./concepts.md#implicit-and-explicit
[pr775]: https://github.com/PetarKirov/sparkles/pull/775
