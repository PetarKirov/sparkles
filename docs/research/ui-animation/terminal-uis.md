# Terminal UIs (Bubble Tea + harmonica, Textual, tachyonfx)

How terminal UI frameworks animate on a grid of character cells: Bubble Tea keeps every animated value in the application's model and advances it with timer messages, harmonica's spring being a pure function the model calls; Textual runs a retained, CSS-styled widget tree with a 60 fps `Animator` that writes attributes directly; tachyonfx post-processes Ratatui's cell buffer after the widgets have drawn into it.

| Field                    | Value                                                                                                                                                                                                                                                                                                 |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | Go (Bubble Tea, Bubbles, harmonica) · Python (Textual) · Rust (tachyonfx)                                                                                                                                                                                                                             |
| License                  | MIT (all five repositories: [harmonica][hm-repo], [bubbletea][bt-repo], [bubbles][bb-repo], [textual][tx-repo], [tachyonfx][tfx-repo])                                                                                                                                                                |
| Repository               | [charmbracelet/harmonica][hm-repo] · [charmbracelet/bubbletea][bt-repo] · [charmbracelet/bubbles][bb-repo] · [Textualize/textual][tx-repo] · [ratatui/tachyonfx][tfx-repo] (formerly `junkdog/tachyonfx`)                                                                                             |
| Documentation            | harmonica [`README.md`][hm-readme] and doc comments · Bubble Tea [`commands.go`][bt-tick] doc comments · Textual [Animation guide][tx-guide] (`docs/guide/animation.md`) · tachyonfx [`README.md`][tfx-readme]                                                                                        |
| Category                 | Bubble Tea: Elm-architecture model/update/view, animation by self-rescheduling messages · Textual: retained DOM with CSS, attribute tweening by a central animator · tachyonfx: post-render cell-buffer shaders                                                                                       |
| Versions surveyed        | harmonica at `0ff76e4` (2026-08-13; Bubbles pins `v0.2.0`) · Bubble Tea **v2** at `bb45cb6` (2026-11-26) · Bubbles **v2** at `0c1a491` (2026-11-20) · Textual **8.2.8** at `5e5b7ef` (2026-10-09) · tachyonfx **0.25.2** at `dac4d28` (2026-10-24)                                                    |
| Animation state lives in | Bubble Tea: fields of the application's model (`progress.Model.percentShown`, `velocity`, `tag`) · Textual: the animated attribute itself on the widget or `Styles`, plus `Animator._animations` keyed by `(id(obj), attribute)` · tachyonfx: `Effect` values in an `EffectManager`, optionally keyed |

> [!NOTE]
> The framework pages already cover the basics this page builds on: [Bubble Tea][tui-bubbletea] (the Elm loop, `tea.Tick`, the 60 fps renderer, the Bubbles catalogue) and [Textual][tui-textual] (the DOM, CSS, the compositor). This page covers only how they animate. The immediate-mode GUI analogues (egui, Dear ImGui, Clay, Gio) are on the sibling page [Immediate-mode GUIs][imm]; terms such as _retarget_ and _stepped integration_ are defined in [Concepts][concepts]. Ratatui itself has no animation support; tachyonfx is the notable effects crate for it. Every claim was read at the pinned revision.

---

## Overview

### What it solves

A terminal frame is a grid of cells re-emitted as escape sequences, so animation is coarse in space (whole cells) and bounded in time by how fast the terminal accepts output. The three subjects take three positions on where the animation runs:

- **In the model (Bubble Tea).** The framework provides only a timer command. An animated widget stores its current value, its velocity and a generation tag in its model, schedules its own next frame, and renders whatever the model says. harmonica supplies the physics as a pure step function.
- **In the framework, on attributes (Textual).** Any numeric or blendable attribute of any object, and any animatable CSS property, can be tweened by the app-wide `Animator`; CSS `transition:` makes style changes animate implicitly.
- **After rendering, on cells (tachyonfx).** Widgets render normally into Ratatui's `Buffer`; effects then rewrite colours, symbols and positions of the cells in an area, with no knowledge of widgets.

### Design philosophy

harmonica describes itself as framework-agnostic ([`README.md`][hm-readme]):

> _"Harmonica is framework-agnostic and works well in 2D and 3D contexts. Simply call [`NewSpring`][newspring] with your settings to initialize and [`Update`][update] on each frame to animate."_

Bubble Tea's timer is deliberately a one-shot ([`commands.go`][bt-tick]):

> _"Beginners' note: Tick sends a single message and won't automatically dispatch messages at an interval. To do that, you'll want to return another Tick command after receiving your tick message."_

Textual's guide describes its animator as a fixed-increment tweener ([`docs/guide/animation.md`][tx-guide]):

> _"Textual's animator can change an attribute from one value to another in fixed increments over a period of time. You can apply animations to styles such as `offset` to move widgets around the screen, and `opacity` to create fading effects."_

tachyonfx positions itself as composable post-processing ([`README.md`][tfx-readme]):

> _"An effects and animation library for [Ratatui][ratatui] applications. Build complex animations by composing and layering simple effects, bringing smooth transitions and visual polish to the terminal."_

---

## How it works

### harmonica: a spring as a pure step function

harmonica ports Ryan Juckett's closed-form damped harmonic oscillator ([`spring.go`][hm-header]). `NewSpring(deltaTime, angularFrequency, dampingRatio)` precomputes four coefficients for one fixed time step, choosing the over-damped, under-damped or critically damped solution from `dampingRatio` ([source][hm-newspring]); `Update` applies them ([source][hm-update]):

```go
// spring.go
func (s Spring) Update(pos, vel float64, equilibriumPos float64) (newPos, newVel float64) {
    oldPos := pos - equilibriumPos // update in equilibrium relative space
    oldVel := vel

    newPos = oldPos*s.posPosCoef + oldVel*s.posVelCoef + equilibriumPos
    newVel = oldPos*s.velPosCoef + oldVel*s.velVelCoef

    return newPos, newVel
}
```

`Spring` is a value holding only coefficients; position and velocity belong to the caller, and one `Spring` can step any number of values (_"cache the result, then call Update to update position and velocity values for each spring that needs updating"_, [source][hm-spring-type]). The time step is fixed at construction: `FPS(n)` returns `1/n` seconds, with the advice _"game engines often provide the time delta as well, which you should use instead of this function, if possible"_ ([source][hm-fps]). The parameters are physical: angular frequency (speed) and damping ratio, with the three regimes documented on `NewSpring` (_"An under-damped spring will reach equilibrium the fastest, but also overshoots it and continues to oscillate as its amplitude decays over time"_, [source][hm-newspring-doc]).

`Projectile` is the other primitive: a pointer type holding position, velocity, acceleration and `deltaTime`, whose `Update()` performs one explicit Euler step in place and returns the new position ([`projectile.go`][hm-projectile], [`Update`][hm-projectile-update]). Unlike `Spring`, it owns its state.

### Bubble Tea and Bubbles: self-rescheduling frame messages

Bubble Tea gives two timers. `Tick(d, fn)` fires once, `d` after the command runs; `Every(d, fn)` fires once at the next wall-clock multiple of `d` (_"ticks in sync with the system clock"_, [source][bt-every], [source][bt-tick]). An animation is a loop the model closes itself: `Update` handles the frame message, steps the value, and returns the next `Tick`. Rendering is decoupled: the renderer redraws on its own ticker at `WithFPS` frames per second (default 60, capped at 120, [`renderer.go`][bt-fps-const], [`options.go`][bt-withfps]), and parks the ticker after _"about half a second of frames with nothing to draw"_, resuming on the next change aligned to the old frame grid ([`tea.go`][bt-renderer]).

The `progress` bubble is the canonical spring user ([`progress/progress.go`][bb-progress-model]):

```go
// progress/progress.go (abridged)
const fps, defaultFrequency, defaultDamping = 60, 18.0, 1.0

type FrameMsg struct{ id, tag int }

func (m *Model) SetPercent(p float64) tea.Cmd {
    m.targetPercent = clampPercent(p)
    m.tag++
    return m.nextFrame()
}

func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
    switch msg := msg.(type) {
    case FrameMsg:
        if msg.id != m.id || msg.tag != m.tag {
            return m, nil
        }
        if !m.IsAnimating() {
            return m, nil
        }
        m.percentShown, m.velocity = m.spring.Update(m.percentShown, m.velocity, m.targetPercent)
        return m, m.nextFrame()
    }
    return m, nil
}

func (m *Model) nextFrame() tea.Cmd {
    done := FrameMsg{id: m.id, tag: m.tag}
    return tea.Tick(time.Second/time.Duration(fps), func(time.Time) tea.Msg { return done })
}
```

The pieces and their sources: the constants (critically damped, `ω = 18`, [source][bb-progress-consts]); `FrameMsg` and the `id`/`tag` fields (_"An identifier to keep us from receiving frame messages too quickly"_, [source][bb-progress-model]); `Update` ([source][bb-progress-update]); `SetPercent` bumps `tag`, which orphans the frame chain already in flight so only one chain runs ([source][bb-progress-setpercent]); `nextFrame` captures the tag by value to avoid a data race ([source][bb-progress-nextframe]); `IsAnimating` stops the chain once `|shown − target| < 0.001` and velocity `< 0.01` ([source][bb-progress-isanimating]). `View()` renders `percentShown`; `ViewAs(p)` renders a given percentage statically and bypasses the spring ([source][bb-progress-view]). The spring's `dt` is fixed at `FPS(60)` regardless of when the tick actually arrives ([source][bb-progress-springopts]).

The `spinner` bubble is a frame counter: each `Spinner` is a list of strings and an `FPS` duration (`Line` is 10 frames per second); `Update` on a matching `TickMsg` increments `frame` modulo the list length and schedules the next tick with a new tag (_"This prevents the spinner from receiving too many messages and thus spinning too fast"_) ([`spinner/spinner.go`][bb-spinner-type], [update][bb-spinner-update], [tick][bb-spinner-tick]).

### Textual: the `Animator`

The app owns one `Animator`, a `Timer` at `1 / frames_per_second` (60) that starts paused ([`_animator.py`][tx-animator-init]). `Widget.animate`, `App.animate` and `Styles.animate` all bind it to an object and call ([`widget.py`][tx-widget-animate]):

```python
widget.animate("attribute", value, duration=…, speed=…, delay=0.0,
               easing="in_out_cubic", on_complete=None, level="full")
```

`_animate` asserts exactly one of `duration` and `speed` (speed divides the distance, default 50 units/s), keys the animation by `(id(obj), attribute)`, reads the current attribute as the start value, and builds either a `SimpleAnimation` (numbers, or any object with a `blend(destination, factor)` method — the `Animatable` protocol that `Color` satisfies) or, via the object's `__textual_animation__` hook, a `ScalarAnimation` for CSS scalars ([source][tx-animate-impl], [`Animatable`][tx-animatable]). Storing it in `_animations` replaces any running animation for the same key (whose `on_complete` is still called) and resumes the timer ([source][tx-animate-replace]).

Each timer tick evaluates every animation at `_get_time()` (monotonic wall clock) and the app's animation level, writes the attribute with `setattr`, and removes finished ones; with nothing left the timer pauses ([`__call__`][tx-animator-call], [`_get_time`][tx-animator-time]). `SimpleAnimation.__call__` is closed form — `factor = min(1, (time − start_time) / duration)`, eased, blended or lerped — and jumps straight to `final_value` when `duration == 0` or the level forbids it ([source][tx-simple-call]).

Writing the attribute is the whole mechanism: animating `scroll_y` sets the reactive scroll offset; animating a style sets a CSS property whose descriptor triggers a refresh. `width`, `height` and `offset` descriptors call `refresh(layout=True)` ([`_style_properties.py`][tx-offset-prop]); `ScalarAnimation` resolves start and destination against the widget's outer size and the app size once, at creation, then sets the style each tick ([`scalar_animation.py`][tx-scalar-init], [step][tx-scalar-call]). The animatable style set is fixed: `offset`, `padding`, `margin`, `width`, `height`, the min/max sizes, colours, `opacity`, `text_opacity`, `tint`, scrollbar colours, link colours and a few more ([`styles.py`][tx-animatable-set]).

### Textual: CSS `transition:`

Textual CSS parses `transition: <property> <duration> <easing> <delay>` (comma-separated groups) into a `dict[str, Transition]` on the styles ([`_styles_builder.py`][tx-transition-parse], [`transition.py`][tx-transition], test: `transition: offset-x 1 in_out_cubic;`, [`test_parse.py`][tx-transition-test]). When a class or pseudo-class changes (_"For example, when you hover over a button, the :hover pseudo class will be added"_, [`app.py`][tx-update-styles]), `Stylesheet.replace_rules(node, rules, animate=True)` diffs old and new render rules; for each animatable key that changed (or is still being animated) and has a transition, it calls `animator.animate(base, key, new_value, duration, delay, easing)` instead of assigning ([`stylesheet.py`][tx-replace-rules]). Focus changes also restyle with `animate=True` ([`screen.py`][tx-focus-animate]).

### Textual: animation levels

`AnimationLevel = Literal["none", "basic", "full"]` ([`_types.py`][tx-level-type]). `App.animation_level` defaults to `constants.TEXTUAL_ANIMATIONS`, read from the `TEXTUAL_ANIMATIONS` environment variable (default `"full"`, invalid values fall back to `"full"`) ([`app.py`][tx-app-level], [`constants.py`][tx-env-level]). Each animation carries a minimum `level`; at `"none"` everything jumps to its final value, at `"basic"` only animations declared `level="basic"` run. Scrolling defaults to `level="basic"` ([`widget.py`][tx-scroll-level]), as do the `Switch` slider and the `Tabs` underline ([`_switch.py`][tx-switch]); generic `animate` calls default to `"full"`. Both arrived in Textual 0.52.0 (2024-02-19, [`CHANGELOG.md`][tx-changelog-level]).

### tachyonfx: shaders over the cell buffer

tachyonfx runs after the widgets have drawn ([`README.md`][tfx-quickstart]):

```rust
// README.md — quick start (abridged)
let mut effects: EffectManager<()> = EffectManager::default();
effects.add_effect(fx::fade_to(Color::Cyan, Color::Gray, (1_000, Interpolation::SineIn)));
let mut last_frame = Instant::now();
loop {
    let elapsed = last_frame.elapsed();
    last_frame = Instant::now();
    terminal.draw(|frame| {
        frame.render_widget(Paragraph::new("Hello, TachyonFX!"), frame.area());
        effects.process_effects(elapsed.into(), frame.buffer_mut(), frame.area());
    })?;
}
```

An effect is a `Shader`: `process(duration, buf, area)` advances its `EffectTimer` by the caller's `duration` and calls `execute` to rewrite cells, returning overflow time once done ([`shader.rs`][tfx-shader]). `EffectTimer` is `{ remaining, total, interpolation, reverse }` ([`effect_timer.rs`][tfx-timer]); `Interpolation` is the easing enum ([`interpolation.rs`][tfx-interp]). `EffectManager::process_effects` runs every effect and drops finished ones ([source][tfx-process]). `unique(key, fx)` / `add_unique_effect` make an effect cancel any running effect with the same key — _"When a new unique effect is created with a key that matches an existing effect, the existing effect will be marked as complete on the next processing cycle"_ ([`effect_manager.rs`][tfx-unique]). Effects compose (`sequence`, `parallel`, `delay`, `ping_pong`, `never_complete`), and include colour fades, `dissolve`/`coalesce`, `sweep_in`, `slide_in`, `translate` and `translate_buf`, which moves _"pre-rendered content without re-rendering it on every frame"_ from an auxiliary buffer ([`fx/mod.rs`][tfx-translate-buf]). `RefRect` is a shared mutable `Rect` so an effect can follow an area that layout moves (_"useful for effects that need to operate on the same dynamically changing area"_, [`ref_rect.rs`][tfx-refrect]).

---

## Analysis

### Where animation state lives

- **Bubble Tea:** in the application's model, as plain fields of the bubble's value type (`percentShown`, `targetPercent`, `velocity`, `tag`, [source][bb-progress-model]). harmonica holds none of it. The model is replaced by `Update`'s return value, so the state is immutable data threaded through the loop.
- **Textual:** the animated value _is_ the attribute on the widget or its `Styles`; the in-flight animation records sit in `Animator._animations: dict[(id(obj), attribute), Animation]` ([source][tx-animator-init]). The key is Python object identity, not a stable application key.
- **tachyonfx:** effects are owned values in the caller's `EffectManager` (optionally keyed by any `K: Ord`); the animated output exists only in the cell buffer for one frame.

### Declaring an animation

Bubble Tea is **explicit and imperative**: the widget changes its target and returns the first frame command (`SetPercent` returns a `tea.Cmd`, [source][bb-progress-setpercent]); there is no framework notion of "this value animates". Textual offers both: **explicit** `animate(attr, value, …)` and **implicit** CSS `transition:` on style changes driven by classes and pseudo-classes ([source][tx-replace-rules]). tachyonfx is **explicit**: an effect is constructed and added, and runs on whatever the buffer holds.

### Time and the clock

- **Bubble Tea:** the wall clock schedules frames (`time.NewTimer` inside `Tick`), but the progress spring integrates a fixed `dt = 1/60` per message regardless of the actual interval, so the animation is frame-count-based and slows under load ([source][bb-progress-springopts], [source][bt-tick]). Render cadence is a separate ticker (≤ 120 fps) owned by the program.
- **Textual:** the animator owns a 60 fps timer and evaluates animations closed-form against the monotonic clock (`time.monotonic`, `perf_counter` on Windows, [`_time.py`][tx-time]), so a dropped tick does not slow the animation.
- **tachyonfx:** the caller passes `elapsed` to `process_effects` every frame; the library never reads a clock.

### Interruption and retargeting

- **Bubble Tea + harmonica retargets with velocity preserved.** `SetPercent` changes only `targetPercent` and the tag; the next frame calls `spring.Update(percentShown, velocity, targetPercent)` with the velocity carried in the model, so the bar bends smoothly towards the new target ([source][bb-progress-update]). This follows directly from the pure-function design: the spring has no notion of "an animation", only `(pos, vel, target) → (pos, vel)`. The tag guarantees a single frame chain survives a retarget.
- **Textual restarts from the current value with zero velocity.** A new `animate` for the same `(obj, attribute)` reads the current (mid-flight) value as `start_value`, starts a fresh duration and easing, and replaces the old record ([source][tx-animate-impl], [source][tx-animate-replace]). With the default `in_out_cubic` the motion visibly slows to zero and accelerates again at the interruption point.
- **tachyonfx cancels**: a unique effect with the same key marks the old one complete; there is no blending between effects ([source][tfx-unique]).

### Curves and springs

harmonica is the only spring here: critically/under/over-damped by `dampingRatio`, speed by `angularFrequency`, exact for the fixed `dt` it was built with ([source][hm-newspring]). Its `Projectile` adds gravity-style ballistic motion with explicit Euler. Textual uses duration (or speed) plus a named easing (`DEFAULT_EASING = "in_out_cubic"`, `DEFAULT_SCROLL_EASING = "out_cubic"`, [`_easing.py`][tx-easing-default]) and CSS-style easing names. tachyonfx uses `EffectTimer` duration plus an `Interpolation` curve. Bubbles' spinner has no curve at all: it steps through a list of glyphs at a fixed rate.

### Layout animation

- **Bubble Tea:** not applicable as a framework feature, because Bubble Tea has no layout engine — `View` returns a string. A bubble that animates its size (the progress bar's filled width) does so in user code, inside `View`, from the model value.
- **Textual animates in the layout phase, re-run every frame.** Animating `width`, `height`, `margin`, `padding` or `offset` writes the style on each tick, and the style descriptors request `refresh(layout=True)`, so the compositor re-lays out the screen at the next refresh ([source][tx-offset-prop], [source][tx-scalar-call]). The start and end are resolved once against the widget's size when the animation is created ([source][tx-scalar-init]); there is no FLIP-style "animate from the previous layout position" — a widget moved by layout (a sibling removed) jumps.
- **tachyonfx animates in the paint phase, after layout.** Effects rewrite cells in an area of a buffer that layout and widgets have already filled; `translate`/`slide_in` move cell content, `translate_buf` moves a pre-rendered auxiliary buffer ([source][tfx-translate-buf]). Layout never sees the animated geometry; `RefRect` lets an effect track the area layout assigned this frame ([source][tfx-refrect]). This is the closest terminal analogue to compositor-side animation, and it needs no previous-frame geometry.

### Enter and exit

None of the three keeps a removed element painting on its own:

- **Bubble Tea:** an element exists only while `View` emits it; an exit animation means keeping it in the model (with a "closing" phase) until the animation ends — the store-driven closing-state pattern, done by hand.
- **Textual:** there is no exit hook — `Toast`, for one, calls `remove()` the moment its timer expires ([`_toast.py`][tx-toast]); an exit is `animate("opacity", 0.0, on_complete=…)` followed by removal in the callback, i.e. a closing state the application drives ([guide § Completion callbacks][tx-guide-complete]). Enter is the reverse: mount with a start style, then animate.
- **tachyonfx:** effects such as `dissolve` and `fade_to` act on whatever is in the buffer, so the widget must still be rendered underneath for the effect to have content to dissolve; `translate_buf` works from a retained auxiliary buffer, which is a snapshot-based exit if the caller renders the departing content into it ([source][tfx-translate-buf]).

### Scheduling, reduced motion and testing

**Frame requests.** Bubble Tea animations schedule exactly as long as they run: `IsAnimating()` false means no further `Tick` ([source][bb-progress-update]), and the renderer parks after half a second with nothing to draw ([source][bt-renderer]). Textual's animator timer pauses when `_animations` is empty and resumes on the next `animate` ([source][tx-animator-call]). tachyonfx relies on the caller's loop (the README polls every 16 ms, [source][tfx-quickstart]).

**Reduced motion.** Textual is the only one with a policy: `TEXTUAL_ANIMATIONS=none|basic|full` and `App.animation_level`, with per-animation minimum levels separating functional motion (scrolling, toggles: `"basic"`) from decorative motion (`"full"`) ([source][tx-env-level], [source][tx-scroll-level]). Bubble Tea and tachyonfx have none.

**Testing.**

- **Bubble Tea:** the model is a value and frames are messages, so a test drives the animation by calling `Update(FrameMsg{…})` in a loop with no clock at all — `TestNaNAnimationRecovery` steps up to 600 frames and asserts the chain stops and settles within `0.001` ([`progress_test.go`][bb-progress-test]).
- **Textual:** tests freeze time by replacing `animator._get_time` and call the animator directly to "move to the next frame" ([`test_disabling_animations.py`][tx-test-disable]); `Pilot.wait_for_animation()` and `wait_for_scheduled_animations()` await the animator's idle and complete events ([`pilot.py`][tx-pilot-wait]); snapshot tests set `app.animation_level = "none"` ([`test_snapshots.py`][tx-snapshot-none]).
- **tachyonfx:** `fx::freeze_at(alpha, …)` pins an effect at a fixed progress, and `with_rng(SimpleRng::new(42))` makes randomised effects reproducible ([`fx/mod.rs`][tfx-freeze-at], [dissolve][tfx-dissolve]); time is the caller's `Duration` argument.

### Lessons for sparkles:ui

- **harmonica is the shape a `pure nothrow @nogc` spring should have.** `(pos, vel, target, coeffs) → (pos, vel)` holds no state, allocates nothing, and retargets with velocity for free. In sparkles the `(pos, vel, target)` triple would live in the element store keyed by identity, and the host would step it after commit. The cost is that velocity must be stored per animated value.
- **Fix the clock dependency harmonica leaves open.** Coefficients are computed for one `dt`; a frame-paced host with variable frame times either recomputes coefficients per frame (cheap: a few `exp`/`sin`/`cos`) or sub-steps at a fixed rate. Bubbles' fixed `FPS(60)` dt with wall-clock ticks drifts under load.
- **Bubble Tea's `tag` is generation-based cancellation** — the same problem sparkles' lifecycle-by-set-difference solves: a frame message (or an animation record) carries the generation it was issued for, and stale ones are ignored.
- **Textual's levels are a ready taxonomy for reduced motion**: per-animation minimum level, functional (`basic`) vs decorative (`full`), one global switch, and "jump to final value" as the reduced behaviour. A test mode is then just `level = none`.
- **For UI-Q9, Textual and tachyonfx bracket the choice.** Textual feeds animated geometry back into layout every frame (siblings reflow, layout re-runs); tachyonfx animates after layout on the painted output (siblings do not move, layout is not re-run). Neither reads previous-frame geometry; a sparkles FLIP-style move would need the store's last committed rect, which neither offers.
- **For UI-Q10, all three leave exit to the application** (keep it in the model, animate-then-remove, or render it under the effect). tachyonfx's `translate_buf` is the only snapshot form, and it is caller-managed.

---

## Strengths

- harmonica's spring is exact, stateless and allocation-free, and gives velocity-preserving retargeting with no extra machinery.
- Bubble Tea animations are fully deterministic in tests: no clock, just messages.
- Textual animates any attribute with one call, makes CSS style changes animate implicitly, and has the only reduced-motion policy among terminal frameworks surveyed.
- tachyonfx adds rich effects to any Ratatui app without touching its widgets, and its time input is entirely the caller's.

## Weaknesses

- Bubble Tea has no animation abstraction: each bubble reimplements the frame loop, tag and stop condition; springs integrate a fixed `dt` against wall-clock ticks.
- harmonica's `Spring` is bound to the `dt` it was built for; variable frame times need new coefficients.
- Textual restarts interrupted animations from zero velocity; geometry animation re-runs layout every frame; start and end scalars are resolved once and go stale if the container resizes mid-animation.
- Textual has no exit animation for removed widgets.
- tachyonfx cannot see widgets or layout: an effect is bound to an area, not to an element, and exit effects need the content still rendered.

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                  | Trade-off                                                                                |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Spring as a pure `(pos, vel, target) → (pos, vel)` function (harmonica) | framework-agnostic; caller owns state; velocity survives retargets         | caller stores velocity; coefficients fixed to one `dt`                                   |
| Animation as a self-rescheduling message chain (Bubble Tea)             | fits the Elm loop with no new concepts; testable by feeding messages       | per-widget boilerplate; needs a generation `tag` to avoid duplicate chains               |
| Separate render ticker that parks when idle (Bubble Tea)                | coalesces model updates into ≤ 120 fps output; no CPU when nothing changes | animation cadence and render cadence are independent clocks                              |
| Central animator tweening attributes by `setattr` (Textual)             | any attribute or style animates with one call; one timer for the app       | keyed by Python object identity; restart-from-current with zero velocity                 |
| CSS `transition:` on rule diffs (Textual)                               | hover/focus/class changes animate implicitly, as on the web                | only properties in the fixed `ANIMATABLE` set; layout properties re-run layout per frame |
| Animation levels with per-animation minimums (Textual)                  | one switch for reduced motion and for tests; functional motion can stay    | authors must classify each animation                                                     |
| Post-render buffer shaders (tachyonfx)                                  | works on any widget; no layout cost; compositor-like                       | blind to widgets and layout; exit needs the content still drawn or a pre-rendered buffer |

## Sources

- harmonica `0ff76e4`: [`spring.go`][hm-header], [`projectile.go`][hm-projectile], [`README.md`][hm-readme]
- Bubble Tea `bb45cb6`: [`commands.go`][bt-tick], [`tea.go`][bt-renderer], [`renderer.go`][bt-fps-const], [`options.go`][bt-withfps]
- Bubbles `0c1a491`: [`progress/progress.go`][bb-progress-model], [`progress/progress_test.go`][bb-progress-test], [`spinner/spinner.go`][bb-spinner-update]
- Textual `5e5b7ef`: [`_animator.py`][tx-animator-init], [`css/scalar_animation.py`][tx-scalar-call], [`css/styles.py`][tx-animatable-set], [`css/stylesheet.py`][tx-replace-rules], [`css/_styles_builder.py`][tx-transition-parse], [`css/transition.py`][tx-transition], [`widget.py`][tx-widget-animate], [`app.py`][tx-app-level], [`constants.py`][tx-env-level], [`pilot.py`][tx-pilot-wait], [`docs/guide/animation.md`][tx-guide], [`CHANGELOG.md`][tx-changelog-level], [`tests/animations/test_disabling_animations.py`][tx-test-disable]
- tachyonfx `dac4d28`: [`README.md`][tfx-readme], [`src/shader.rs`][tfx-shader], [`src/effect_manager.rs`][tfx-unique], [`src/effect_timer.rs`][tfx-timer], [`src/fx/mod.rs`][tfx-translate-buf], [`src/ref_rect.rs`][tfx-refrect]
- Related pages: [Bubble Tea][tui-bubbletea], [Textual][tui-textual], [Ratatui][tui-ratatui], [Immediate-mode GUIs][imm], [Concepts][concepts]

<!-- References -->

[hm-repo]: https://github.com/charmbracelet/harmonica/tree/0ff76e405449b47bd60f1df4820d880081692d3c
[hm-readme]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/README.md#L22-L27
[newspring]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/spring.go#L132
[update]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/spring.go#L216
[hm-header]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/spring.go#L1-L21
[hm-fps]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/spring.go#L58-L69
[hm-spring-type]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/spring.go#L84-L107
[hm-newspring-doc]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/spring.go#L109-L131
[hm-newspring]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/spring.go#L132-L212
[hm-update]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/spring.go#L214-L224
[hm-projectile]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/projectile.go#L23-L30
[hm-projectile-update]: https://github.com/charmbracelet/harmonica/blob/0ff76e405449b47bd60f1df4820d880081692d3c/projectile.go#L75-L86
[bt-repo]: https://github.com/charmbracelet/bubbletea/tree/bb45cb61b7642babc469c8e21950d2a0ec1e11a2
[bt-every]: https://github.com/charmbracelet/bubbletea/blob/bb45cb61b7642babc469c8e21950d2a0ec1e11a2/commands.go#L55-L114
[bt-tick]: https://github.com/charmbracelet/bubbletea/blob/bb45cb61b7642babc469c8e21950d2a0ec1e11a2/commands.go#L116-L165
[bt-fps-const]: https://github.com/charmbracelet/bubbletea/blob/bb45cb61b7642babc469c8e21950d2a0ec1e11a2/renderer.go#L13-L14
[bt-withfps]: https://github.com/charmbracelet/bubbletea/blob/bb45cb61b7642babc469c8e21950d2a0ec1e11a2/options.go#L146-L153
[bt-renderer]: https://github.com/charmbracelet/bubbletea/blob/bb45cb61b7642babc469c8e21950d2a0ec1e11a2/tea.go#L1608-L1670
[bb-repo]: https://github.com/charmbracelet/bubbles/tree/0c1a4915f40343be6d6a3bb3f998db8f069d8b03
[bb-progress-consts]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/progress/progress.go#L48-L51
[bb-progress-model]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/progress/progress.go#L180-L231
[bb-progress-update]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/progress/progress.go#L260-L282
[bb-progress-springopts]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/progress/progress.go#L284-L290
[bb-progress-setpercent]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/progress/progress.go#L300-L309
[bb-progress-view]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/progress/progress.go#L329-L340
[bb-progress-nextframe]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/progress/progress.go#L354-L359
[bb-progress-isanimating]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/progress/progress.go#L444-L449
[bb-progress-test]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/progress/progress_test.go#L39-L65
[bb-spinner-type]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/spinner/spinner.go#L20-L31
[bb-spinner-update]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/spinner/spinner.go#L123-L157
[bb-spinner-tick]: https://github.com/charmbracelet/bubbles/blob/0c1a4915f40343be6d6a3bb3f998db8f069d8b03/spinner/spinner.go#L168-L192
[tx-repo]: https://github.com/Textualize/textual/tree/5e5b7ef58b8c5572c13a3ff9027d756623661495
[tx-guide]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/docs/guide/animation.md#L1-L11
[tx-guide-complete]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/docs/guide/animation.md#completion-callbacks
[tx-changelog-level]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/CHANGELOG.md#L1759-L1769
[tx-animatable]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/_animator.py#L38-L49
[tx-simple-call]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/_animator.py#L104-L146
[tx-animator-init]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/_animator.py#L223-L245
[tx-animate-impl]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/_animator.py#L353-L457
[tx-animate-replace]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/_animator.py#L459-L466
[tx-animator-call]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/_animator.py#L556-L572
[tx-animator-time]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/_animator.py#L574-L582
[tx-time]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/_time.py#L9-L46
[tx-easing-default]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/_easing.py#L130-L131
[tx-level-type]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/_types.py#L56-L57
[tx-env-level]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/constants.py#L95-L108
[tx-app-level]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/app.py#L838-L842
[tx-update-styles]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/app.py#L2504-L2523
[tx-widget-animate]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/widget.py#L2515-L2554
[tx-scroll-level]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/widget.py#L2723-L2729
[tx-switch]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/widgets/_switch.py#L170-L180
[tx-focus-animate]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/screen.py#L1082-L1095
[tx-animatable-set]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/css/styles.py#L226-L258
[tx-replace-rules]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/css/stylesheet.py#L636-L693
[tx-transition-parse]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/css/_styles_builder.py#L865-L926
[tx-transition]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/css/transition.py#L4-L16
[tx-transition-test]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/tests/css/test_parse.py#L1109
[tx-offset-prop]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/css/_style_properties.py#L734-L779
[tx-scalar-init]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/css/scalar_animation.py#L40-L51
[tx-scalar-call]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/css/scalar_animation.py#L53-L76
[tx-toast]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/widgets/_toast.py#L130-L143
[tx-pilot-wait]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/src/textual/pilot.py#L549-L560
[tx-test-disable]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/tests/animations/test_disabling_animations.py#L23-L42
[tx-snapshot-none]: https://github.com/Textualize/textual/blob/5e5b7ef58b8c5572c13a3ff9027d756623661495/tests/snapshot_tests/test_snapshots.py#L1856
[tfx-repo]: https://github.com/ratatui/tachyonfx/tree/dac4d287f4593174c9b2d13f18d582c03cbb9e8b
[tfx-readme]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/README.md#L10-L11
[tfx-quickstart]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/README.md#L37-L78
[tfx-shader]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/src/shader.rs#L18-L91
[tfx-timer]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/src/effect_timer.rs#L26-L31
[tfx-interp]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/src/interpolation.rs#L238
[tfx-unique]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/src/effect_manager.rs#L13-L53
[tfx-process]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/src/effect_manager.rs#L117-L137
[tfx-freeze-at]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/src/fx/mod.rs#L552-L581
[tfx-dissolve]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/src/fx/mod.rs#L1466-L1478
[tfx-translate-buf]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/src/fx/mod.rs#L1244-L1269
[tfx-refrect]: https://github.com/ratatui/tachyonfx/blob/dac4d287f4593174c9b2d13f18d582c03cbb9e8b/src/ref_rect.rs#L1-L23
[ratatui]: https://github.com/ratatui/ratatui
[tui-bubbletea]: ../tui-libraries/bubbletea.md
[tui-textual]: ../tui-libraries/textual.md
[tui-ratatui]: ../tui-libraries/ratatui.md
[imm]: ./immediate-mode.md
[concepts]: ./concepts.md
