# Animation engines and tools (Godot, Rive, Lottie, GSAP)

Four systems from outside the widget toolkits: a game engine's procedural `Tween` and its authored, blended `AnimationPlayer`/`AnimationTree`; a design tool's runtime that plays timelines from a state machine the host only feeds inputs and time; a file format in which an animation is data rendered at any frame; and the web's dominant imperative tween-and-timeline library, with a FLIP plugin that animates layout changes by measuring the DOM before and after.

| Field                    | Godot                                                                                                              | Rive                                                                                     | Lottie                                                                                                              | GSAP                                                                                                                                      |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | C++ engine, GDScript/C# API                                                                                        | C++ runtime (`rive-runtime`), wrapped per platform                                       | JSON format; players in JS, Kotlin, Swift, C++                                                                      | JavaScript                                                                                                                                |
| License                  | MIT ([`LICENSE.txt`][godot-license])                                                                               | MIT ([`LICENSE`][rive-license])                                                          | Community Specification License 1.0 ([`License.md`][lottie-license]); `lottie-web` MIT ([`LICENSE.md`][lw-license]) | proprietary _"Standard 'no charge' license"_ ([`package.json`][gsap-pkg]); not OSI, with a prohibited-use clause ([below](#gsap-license)) |
| Repository               | [godotengine/godot][godot-repo]: [`scene/animation`][godot-anim-dir], [`doc/classes`][godot-doc-dir]               | [rive-app/rive-runtime][rive-repo]: [`src/animation`][rive-anim-dir]                     | [lottie/lottie-spec][lottie-repo] (spec); [airbnb/lottie-web][lw-repo] (reference web player)                       | [greensock/GSAP][gsap-repo]: [`src/gsap-core.js`][gsap-core], [`src/Flip.js`][gsap-flip]                                                  |
| Documentation            | [class reference][godot-docs-tween] (generated from `doc/classes/*.xml`)                                           | [rive.app/docs][rive-docs-sm]                                                            | [lottie.github.io/lottie-spec][lottie-site]                                                                         | [gsap.com/docs][gsap-docs-timeline]                                                                                                       |
| Category                 | procedural tweens + authored keyframe tracks, blend trees and animation state machines                             | authored timelines selected and mixed by a designer-built state machine                  | authored timeline as data; a frame is a pure function of the frame number                                           | imperative tweens nested in seekable timelines; measured layout animation (FLIP)                                                          |
| Versions surveyed        | `master` at `8f2e46b` (2026-11-25), `version.py` 4.8.0-beta                                                        | `main` at `c355fea` (2026-11-26)                                                         | spec `main` at `4b55957` (2026-05-29); `lottie-web` `master` at `bede03d` (2024-11-19)                              | 3.15.1, `master` at `5e6c35f` (2026-11-03)                                                                                                |
| Animation state lives in | a `Tween` (`RefCounted`) held by the `SceneTree`'s tween list; an `AnimationMixer` node's playback and blend state | a `StateMachineInstance` per artboard instance: per-layer current state, from-state, mix | the player (`AnimationItem.currentRawFrame`); the file is immutable                                                 | each `Tween`/`Timeline` object, linked into `gsap.globalTimeline`; per-target `_gsap` cache                                               |

> [!NOTE]
> This page asks how these systems express animation, for the design of [`sparkles:ui`][sparkles-ui] ([decisions][ui-authoring]). Authored-timeline engines for programmatic video — Motion Canvas's generator scenes against a play-head, Theatre.js's sequence of keyframed props — are covered by the [manim catalog][manim] ([Motion Canvas][manim-mc], [Theatre.js][manim-theatre]) and are not repeated here. Every source path was read at the pinned SHA.

---

## Overview

### What it solves

Each system answers a different half of "how does a value change over time":

- **Godot** offers two tools and says when to pick which. `Tween` is for values computed at run time: _"[Tween] is more suited than [AnimationPlayer] for animations where you don't know the final values in advance. For example, interpolating a dynamically-chosen camera zoom value is best done with a [Tween]"_ ([`Tween.xml`][godot-tween-xml-desc]). `AnimationPlayer` plays editor-authored tracks; `AnimationTree` blends and sequences them with state machines and blend spaces.
- **Rive** separates what designers author (timelines) from what the application controls (inputs, or bound view-model data). The editor docs put it as _"A state machine connects your timelines with logic"_ and _"This is what makes a Rive graphic interactive"_ ([state machine docs][rive-docs-sm]).
- **Lottie** is a data interchange format: _"a JSON-based format for animated vector graphics"_ ([spec index][lottie-index]), produced by an authoring tool and rendered by any conforming player.
- **GSAP** animates arbitrary JavaScript properties from code: _"At its core, GSAP is a high-speed property manipulator, updating values over time with extreme accuracy"_ ([`README.md`][gsap-readme]). Its timelines sequence tweens; its `Flip` plugin turns a DOM change into an animation.

### Design philosophy

1. **Godot: fire-and-forget, owned by the scene tree.** _"They can be used in a "fire-and-forget" manner for some logic that normally would be done by code"_ and _"Tweens are not designed to be reused and trying to do so results in an undefined behavior. Create a new Tween for each animation and every time you replay an animation from start"_ ([`Tween.xml`][godot-tween-xml-desc]). A tween is a one-shot script of steps, not a retargetable controller.
2. **Rive: the host owns the clock, the file owns the behaviour.** The runtime exposes `bool advance(float seconds)`, commented _"Advance the state machine by the specified time. Returns true if the state machine will continue to animate after this advance"_ ([`state_machine_instance.hpp`][rive-smi-advance]). The application writes inputs and time; which animation plays, and how states mix, is decided by data the designer authored.
3. **Lottie: an animation is a function of the frame number.** Properties are either a static value or a keyframe list (_"When it's not animated, `k` will contain the value directly. When animated, `k` will be an array of keyframes"_, [`properties.md`][lottie-props]), and the playable range is `[ip, op)` in frames at rate `fr` ([`composition.md`][lottie-time]). Nothing in the format depends on history.
4. **GSAP: everything is a seekable child of a timeline.** _"A Timeline is a powerful sequencing tool that acts as a container for tweens and other timelines"_ ([Timeline docs][gsap-docs-timeline]); the root timeline is driven by one ticker, and any tween or timeline can be `seek`ed, `reverse`d or `timeScale`d.

---

## How it works

## Godot: `Tween`, `AnimationPlayer`, `AnimationTree`

### `Tween`: a sequence of `Tweener` steps processed by the `SceneTree`

`SceneTree.create_tween()` instantiates a `Tween` and pushes it onto the tree's `tweens` list ([`scene_tree.cpp`][godot-st-create]); `Node.create_tween()` does the same and then calls `tween->bind_node(this)` ([`node.cpp`][godot-node-create]). A `Tween.new()` is invalid. Steps are appended with `tween_property`, `tween_interval`, `tween_callback`, `tween_method`, `tween_subtween` and `tween_await`; they run one after another unless `parallel()` (next step joins the previous) or `set_parallel(true)` is used, and `chain()` returns to sequencing ([`Tween.xml`][godot-tween-xml-desc]):

```gdscript
# doc/classes/Tween.xml — the class description's own example
var tween = get_tree().create_tween().bind_node(self).set_trans(Tween.TRANS_ELASTIC)
tween.tween_property($Sprite, "modulate", Color.RED, 1.0)
tween.tween_property($Sprite, "scale", Vector2(), 1.0)
tween.tween_callback($Sprite.queue_free)
```

`tween_property(object, property, final_val, duration)` animates from _"the property's value at the time the tweening of the [PropertyTweener] starts"_ ([`tween_property`][godot-tween-xml-prop]): `PropertyTweener::start` reads `target_instance->get_indexed(property)` when the step begins (or after its delay), and computes `delta_val = final_val - initial_val` ([`PropertyTweener::start`][godot-ptw-start]). `from(v)` and `from_current()` override the start; `as_relative()` makes `final_val` an offset. Each frame `PropertyTweener::step` writes `tween->interpolate_variant(initial_val, delta_val, time, duration, trans_type, ease_type)` straight into the target with `set_indexed`, and on completion writes `final_val` exactly and returns the unused remainder of the frame's delta so the next step starts mid-frame ([`PropertyTweener::step`][godot-ptw-step]).

`set_trans` picks the curve family (`TRANS_LINEAR` … `TRANS_SPRING`) and `set_ease` the side it applies to (`EASE_IN`, `EASE_OUT`, `EASE_IN_OUT`, `EASE_OUT_IN`); both set defaults for tweeners appended afterwards ([`set_ease`][godot-tween-xml-ease], [`set_trans`][godot-tween-xml-trans]). `Tween.interpolate_value(initial, delta, elapsed, duration, trans, ease)` exposes the same evaluator as a static, stateless function — _"for manual interpolation of a value, when you don't want [Tween] to do animating for you"_ ([`interpolate_value`][godot-tween-xml-interp]); it is `Tween::interpolate_variant`, a lookup into the `interpolaters[trans][ease]` table ([`tween.cpp`][godot-tween-eq]).

**Processing.** `SceneTree::process_tweens(delta, physics)` walks the list after the frame's nodes have run, skips tweens whose process mode does not match the pass, steps the rest, and erases a tween whose `step` returns `false` ([`process_tweens`][godot-st-process-tweens]). It is called from both `physics_process` and `process` ([`scene_tree.cpp` L662][godot-st-phys-call], [L731][godot-st-idle-call]); `set_process_mode(TWEEN_PROCESS_IDLE | TWEEN_PROCESS_PHYSICS)` chooses which ([`TweenProcessMode`][godot-tween-xml-modes]). The docs state the order: _"The tween is processed after all of the nodes in the current frame, i.e. node's [method Node._process] method would be called before the tween"_ ([`Tween.xml`][godot-tween-xml-desc]). `custom_step(delta)` steps a tween by hand ([`custom_step`][godot-tween-xml-custom]); `set_speed_scale` and `set_ignore_time_scale` scale or bypass `Engine.time_scale`.

**Binding to a node's lifetime.** `bind_node` stores the node's `ObjectID`, not a pointer:

> _"When you bind a [Node] with the [Tween], the [Tween] will halt the animation when the object is not inside tree and the [Tween] will be automatically killed when the bound object is freed."_ ([`bind_node`][godot-tween-xml-bind])

`Tween::step` implements both clauses in its first lines: it resolves the id through `ObjectDB`; a node that exists but is outside the tree makes `step` return `true` without advancing (halted, kept); a freed node makes it return `false`, and `process_tweens` then `clear()`s and erases the tween ([`Tween::step`][godot-tween-step-bound]). Independently, each `PropertyTweener` resolves its _target_ by `ObjectID` every step and `_finish()`es if the target was freed ([`PropertyTweener::step`][godot-ptw-step]). `can_process` makes pausing follow the bound node under `TWEEN_PAUSE_BOUND` ([`can_process`][godot-tween-canprocess]). An unbound, paused tween _"will exist indefinitely until manually started or invalidated"_ ([`pause`][godot-tween-xml-pause]).

**Interruption is manual.** _"If two or more tweens animate one property at the same time, the last one created will take priority and assign the final value. If you want to interrupt and restart an animation, consider assigning the [Tween] to a variable"_ and calling `kill()` before `create_tween()` again ([`Tween.xml`][godot-tween-xml-desc]); `kill()` _"Aborts all tweening operations and invalidates the [Tween]"_ ([`kill`][godot-tween-xml-kill]).

### `AnimationMixer`, `AnimationPlayer`: authored tracks with blending and capture

`AnimationPlayer` and `AnimationTree` share the base `AnimationMixer`, which holds animation libraries and performs the blend: _"After instantiating the playback information data within the extended class, the blending is processed by the [AnimationMixer]"_ ([`AnimationMixer.xml`][godot-mixer-xml]). An `Animation` resource holds tracks (value, transform, method, audio…) keyed at times in seconds. Relevant controls:

| Control                                                   | Meaning (verbatim where quoted)                                                                                                                                                                                                                                                                                                                                                                                                 |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `callback_mode_process`                                   | `ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS`, `_IDLE` (default), or `_MANUAL`: _"Do not process animation. Use [method advance] to process the animation manually"_ ([constants][godot-mixer-xml-modes]); `process_callback` is its deprecated name on `AnimationPlayer`/`AnimationTree`                                                                                                                                           |
| `advance(delta)`                                          | _"Manually advance the animations by the specified time (in seconds)"_ ([`advance`][godot-mixer-xml-advance])                                                                                                                                                                                                                                                                                                                   |
| `play(name, custom_blend, custom_speed, from_end)`        | crossfades from the current animation over `custom_blend` seconds (default `playback_default_blend_time`, [`play`][godot-player-xml-play], [default][godot-player-xml-blend])                                                                                                                                                                                                                                                   |
| `seek(seconds, update)`                                   | _"Events between the current frame and [param seconds] are skipped"_ ([`seek`][godot-player-xml-seek])                                                                                                                                                                                                                                                                                                                          |
| `capture` / `play_with_capture` / `playback_auto_capture` | for tracks with `UPDATE_CAPTURE`, _"stores current values of the objects indicated by the track path as a cache"_ and then _"interpolate[s] with current animation blending result … for the time specified by [param duration], working like a crossfade"_ ([`capture`][godot-mixer-xml-capture], [`UPDATE_CAPTURE`][godot-anim-xml-capture]); `playback_auto_capture` defaults to `true` ([source][godot-player-xml-autocap]) |
| `RESET` animation, `deterministic`, `reset_on_save`       | with `deterministic`, _"the result is accumulated with an initial value ([code]0[/code] or a [code]"RESET"[/code] animation if present)"_; `reset_on_save` saves the scene _"with the effects of the reset animation … applied as if it had been seeked to time 0"_ ([`deterministic`][godot-mixer-xml-det], [`reset_on_save`][godot-mixer-xml-reset])                                                                          |

`UPDATE_CAPTURE` is the authored-timeline answer to "start from wherever the property is now": the first key of the track is replaced, for `duration`, by a blend from the captured live value.

### `AnimationTree`: blend trees, blend spaces and state machines

`AnimationTree` evaluates a graph of `AnimationNode`s rooted at `tree_root`; the linked `AnimationPlayer` becomes a library only (_"Playback and transitions should be handled using only the [AnimationTree]"_, [`AnimationTree.xml`][godot-tree-xml]). Nodes include `AnimationNodeBlend2/3`, `Add2/3`, `OneShot`, `TimeScale`, `TimeSeek`, `Transition`, `AnimationNodeBlendSpace1D/2D` (_"Outputs the linear blend of the three adjacent animations using a [Vector2] weight"_, [`AnimationNodeBlendSpace2D.xml`][godot-bs2d-xml]) and `AnimationNodeStateMachine`:

> _"Contains multiple [AnimationRootNode]s representing animation states, connected in a graph. State transitions can be configured to happen automatically or via code, using a shortest-path algorithm."_ ([`AnimationNodeStateMachine.xml`][godot-sm-xml])

Code drives it through the playback object (`$AnimationTree.get("parameters/playback").travel("some_state")`, [`travel`][godot-sm-travel]) or through parameters: a transition's `advance_condition` _"will become a boolean parameter on the [AnimationTree] that can be controlled from code"_, `advance_expression` evaluates an expression, `xfade_time` and `xfade_curve` shape the crossfade, and `switch_mode` is `SWITCH_MODE_IMMEDIATE`, `SWITCH_MODE_SYNC` (_"seek the new state to the playback position of the old state"_) or `SWITCH_MODE_AT_END` ([`AnimationNodeStateMachineTransition.xml`][godot-sm-trans-xml], [switch modes][godot-sm-trans-modes]).

## Rive: state machines over timelines

### Artboard, timelines, state machine

A Rive file holds artboards; each has `LinearAnimation`s (keyframed timelines in seconds) and `StateMachine`s. At run time the host instantiates an `ArtboardInstance` and a `StateMachineInstance` over it, then each frame calls `advanceAndApply(seconds)` and draws. A `LinearAnimation` is applied as a function of a time: `LinearAnimation::apply(artboard, time, mix)` ([`linear_animation.cpp`][rive-la-apply]) walks keyed objects and calls `KeyedProperty::apply(object, seconds, mix, …)` ([`keyed_property.cpp`][rive-kp-apply]), which finds the bracketing keyframes and interpolates them (cubic, elastic or scripted interpolators, [`include/rive/animation`][rive-anim-include]). Playback position, looping and direction live in `LinearAnimationInstance` (`time()`, `advance(seconds)`, [header][rive-lai]).

The state machine's vocabulary, from the editor docs ([state machine][rive-docs-sm], [transitions][rive-docs-trans]):

- **Inputs** — `SMIBool`, `SMINumber`, `SMITrigger`, fetched by name (`getBool`, `getNumber`, `getTrigger`, [`state_machine_instance.hpp`][rive-smi-advance]). The docs now mark them legacy: _"Older files use Inputs to drive state machines"_; _"Use data binding for new work."_
- **Data binding** — _"Data binding connects data stored in View Models to properties in your Rive scene. When data changes, your scene updates automatically"_ ([data binding][rive-docs-db]); the runtime side is `bindViewModelInstance` and `bind()` on the instance.
- **Layers** — _"A layer plays one state at a time"_; several layers play concurrently and apply in order.
- **States** — animation states, blend states (`BlendState1D` driven by a number input or view-model value, `BlendStateDirect`), entry, exit and any-state.
- **Transitions** — _"the connections between states, with conditions that decide when the state machine moves from one state to another"_. Each has a duration (_"how long it takes for a transition to occur"_), an optional exit time (_"how much of the state must play before transitioning"_), an interpolator, and flags.
- **Listeners** — pointer, keyboard, focus and gamepad listener groups whose actions change inputs or view-model values or fire events (`pointerDown` etc. on the instance).

The transition flags are a bit set ([`state_transition_flags.hpp`][rive-trans-flags]):

```cpp
// include/rive/animation/state_transition_flags.hpp
DurationIsPercentage = 1 << 1,  // duration is % of the state's animation, or ms
EnableExitTime       = 1 << 2,
ExitTimeIsPercentage = 1 << 3,
/// Whether the animation is held at exit or if it keeps advancing
/// during mixing.
PauseOnExit          = 1 << 4,
/// Whether the transition can exit before it is complete.
EnableEarlyExit      = 1 << 5
```

### A layer's advance: mix weight, not velocity

Each `StateMachineLayerInstance` keeps `m_currentState`, `m_stateFrom`, a `m_mix` weight in `[0, 1]`, and an optional held pose (`m_holdAnimation`, `m_holdTime`) ([`state_machine_instance.cpp`][rive-layer-fields]). `updateMix` advances the weight linearly, `m_mix += seconds / mixTime`, clamped, and fires the transition's end events when it reaches 1 ([`updateMix`][rive-update-mix]). `apply` writes the from-state at `transform(m_mixFrom)` and then the current state at `interpolator->transform(m_mix)` — a crossfade of poses, shaped by the transition's curve ([`apply`][rive-layer-apply]).

While a transition is mixing, `updateState` refuses to change state unless the transition has `EnableEarlyExit`: _"Don't allow changing state while a transition is taking place (we're mixing one state onto another) if enableEarlyExit is not true"_ ([`updateState`][rive-update-state]). When an early exit does happen, the interrupted blend is baked into a reset pose: _"An interrupted mix's blend is already in the reset values"_, and the new mix starts from 0 ([transition start][rive-trans-start]).

### Layout animation inside the runtime

Rive artboards can contain Yoga-based layout components. After `calculateLayout()`, `Artboard::syncStyleChangesWithUpdate` calls `updateLayoutBounds(/*animation*/ true)` ([`artboard.cpp`][rive-artboard-sync]). `LayoutComponent::updateLayoutBounds` compares the newly solved rect with the current target; when a layout style animates and the target changed, it sets `from = m_layout` (the rect currently displayed), `to = newLayout`, and resets elapsed time ([`updateLayoutBounds`][rive-lc-update]). Each frame `advanceComponent` → `applyInterpolation` lerps `from → to` by the style's interpolator and duration ([`advanceComponent`][rive-lc-advance], [`applyInterpolation`][rive-lc-apply]).

Retargeting mid-flight uses a second buffer: the header comment describes _"two LayoutAnimationData (the second is the smoothing buffer, used when a new target arrives mid-flight)"_ ([`layout_component.hpp`][rive-lc-hdr]). With `IsSmoothingAnimation` set, the new tween's `from` is itself recomputed each frame as the old tween's current interpolated value (`m_animation->b.from = m_animation->a.interpolate(f)`), so the start point keeps moving until the old tween would have ended — a blend of two tweens rather than a velocity hand-off ([`applyInterpolation`][rive-lc-apply]). A component newly added to a host list does _not_ animate in: it snaps to its first computed rect, with the comment _"this may be useful in adding support for animate in/out of items in an ArtboardHost"_ ([`updateLayoutBounds`][rive-lc-update]).

## Lottie: the file is the animation

### Time and keyframes

The top-level `Animation` object carries `fr` (frame rate), `ip` (in point, inclusive) and `op` (out point, exclusive); _"The total duration in frames is `op - ip`, and the duration in seconds is `(op - ip) / fr`"_ ([`composition.md`][lottie-time]). Each layer has its own `ip`/`op`: _"A layer is visible on frame `t` when `ip <= t < op`"_ ([`layers.md`][lottie-layer-vis]). Precomposition layers remap time with a stretch, `t' = t / sr - st`, or an arbitrary animatable time-remap property `tm` (_"subset, speedup/slowdown, reverse, frame-freeze"_, [`layers.md`][lottie-timestretch]).

An animated property is a keyframe list sorted by `t`; every keyframe except the last (or a hold keyframe, `h: 1`) carries easing handles `o` and `i`, which _"represent a cubic bezier, starting at `[0,0]` and ending at `[1,1]`"_, `x` being normalised time and `y` the interpolation factor ([`properties.md`][lottie-easing]):

```json
{
  "a": 1,
  "k": [
    {
      "t": 0,
      "s": [100, 100],
      "o": { "x": [0.333, 0.333], "y": [0, 0] },
      "i": { "x": [0.667, 0.667], "y": [1, 1] }
    },
    { "t": 60, "s": [50, 50] }
  ],
  "ty": "v"
}
```

Handles are per dimension, and _"Unlike `x` values, `y` values are not clamped to `[0 .. 1]`. Supernormal `y` values allow the interpolated value to overshoot"_ — overshoot is authored, not simulated. Before the first keyframe the first value holds; after the last, the last value holds ([`properties.md`][lottie-keyframes]).

### The player: a frame counter on `requestAnimationFrame`

`lottie-web`'s `AnimationManager` runs one `requestAnimationFrame` loop for all registered animations: `resume(nowTime)` passes `elapsedTime` to every `AnimationItem.advanceTime`, and re-requests a frame only `if (playingAnimationsNum && !_isFrozen)`, otherwise setting `_stopped` ([`AnimationManager.js`][lw-manager-loop]). `advanceTime` adds `value * frameModifier` (milliseconds × `fr / 1000` × speed × direction) to `currentRawFrame` and handles looping and segments ([`advanceTime`][lw-advance]); `gotoFrame` truncates to an integer frame unless `setSubframe(true)` ([`gotoFrame`][lw-gotoframe]). `goToAndStop(value, isFrame)` and `playSegments` seek directly ([`AnimationItem.js`][lw-gotoandstop]). Interactivity on top of Lottie — scrubbing a frame from scroll, swapping segments on hover — lives in the host.

## GSAP: tweens, timelines, ticker, Flip

### Tweens and timelines

`gsap.to(targets, vars)`, `gsap.from` and `gsap.fromTo` create a `Tween` and add it to `gsap.globalTimeline` (`_globalTimeline = new Timeline({… autoRemoveChildren: true, id:"root", smoothChildTiming: true})`, [`gsap-core.js`][gsap-global-tl]). Start values are read when the tween first renders (`_initTween`, [source][gsap-inittween]); `from()` tweens default to `immediateRender: true`. A `Timeline` is a tween container whose children are placed by the **position parameter**, parsed by `_parsePosition`: an absolute number, a label, `"+=1"`/`"-=1"` relative to the timeline's end, and `"<"`/`">"` for the start/end of the most recently added child ([`_parsePosition`][gsap-parse-pos]; the docs: _"think of `"<"` and `">"` as pointers to the start or end of the most recently-added animation"_, [Timeline docs][gsap-docs-timeline]).

```js
// illustrative: the position-parameter forms
const tl = gsap.timeline();
tl.to('.a', { x: 100, duration: 1 })
  .to('.b', { y: 50, duration: 1 }, '<') // same start as .a
  .to('.c', { opacity: 0, duration: 0.5 }, '-=0.25')
  .add(otherTimeline, '>'); // nested timeline after .c
```

Every animation's state is its local time. `totalTime(t)` aligns the playhead and renders at `t`; `seek(position)` is `this.totalTime(_parsePosition(this, position), …)` ([`totalTime`][gsap-totaltime], [`seek`][gsap-seek]); `progress()`, `timeScale()`, `reverse()` and `paused()` are setters over the same value ([`progress`][gsap-progress], [`timeScale`][gsap-timescale]). Because a child's time is derived from its parent's, `gsap.globalTimeline.timeScale(0.5)` slows every animation, and scrubbing a timeline (`ScrollTrigger`'s `scrub`, a slider) is a write of one number.

### The ticker

One ticker drives the root: `_ticker.add(Timeline.updateRoot)` ([`gsap-core.js`][gsap-ticker-add]). Its `_tick` reads `Date.now()`, applies lag smoothing — `(elapsed > _lagThreshold || elapsed < 0) && (_startTime += elapsed - _adjustedLag)` with defaults 500 ms and 33 ms — and dispatches to listeners only when the `fps()` gap (default `1000 / 240`) has passed; `tick()` forces a manual tick ([ticker][gsap-ticker]). The docs: when the CPU lags, GSAP _"adjusts the core timing mechanism on the next tick"_, and the time passed to listeners is _"the total time (in seconds) since the ticker started"_ ([ticker docs][gsap-docs-ticker]). `updateRoot` puts the ticker to sleep after `autoSleep` (120) frames with no active child and no other listener ([`updateRoot`][gsap-updateroot]); any new tween calls `_wake()`.

### Conflicts, retargeting, inertia

`overwrite` decides what happens to a competing tween: _"If `true`, all tweens of the same targets will be killed immediately regardless of what properties they affect. If `"auto"`, when the tween renders for the first time it hunt down any conflicts in active animations (animating the same properties of the same targets) and kill only those parts of the other tweens. Non-conflicting parts remain intact. If `false`, no overwriting strategies will be employed. Default: `false`."_ ([Tween docs][gsap-docs-tween]). In source, `"auto"` runs inside `_initTween`: `_globalTimeline.killTweensOf(target, ptLookup, tween.globalTime(time))`, with `_overwritingTween` set so the new tween is spared ([`_initTween`][gsap-autooverwrite]). The new tween reads its start from the property's current value, so position is continuous; velocity is not.

`gsap.quickTo(target, property, vars)` builds one paused tween and returns `value => tween.resetTo(property, value, …)` ([`quickTo`][gsap-quickto]); the docs pitch it for a `"mousemove"` handler, as _"an optimized function tied to one particular numeric property"_ ([quickTo docs][gsap-docs-quickto]). `resetTo` computes the current eased ratio, sets each property tween's start to the current value (`pt.s + ratio * pt.c`) and its change to `value - start`, moves the playhead back to 0 and renders ([`resetTo`][gsap-resetto], [`_updatePropTweens`][gsap-updatepts]). This is the canonical non-physical retarget: a restart from the current position with the full duration and ease. Velocity enters GSAP only through `InertiaPlugin`, which samples a `VelocityTracker` ([`InertiaPlugin.js`][gsap-inertia]).

### `Flip`: First, Last, Invert, Play

`Flip.getState(targets)` records, for each element, `getBoundingClientRect()`, its global matrix, computed `x`/`y`/`scale`/`rotation`/`opacity`, `display`, `position` and parent ([`ElementState.update`][gsap-flip-elstate]); the user mutates the DOM; `Flip.from(state, vars)` records the new state, matches elements by `data-flip-id` (auto-assigned if absent, [`_getID`][gsap-flip-id]), and tweens transforms from the old geometry to none ([`Flip` class][gsap-flip-class]):

```js
// illustrative: the getState → mutate → from bracket
const state = Flip.getState('.item');
container.classList.toggle('grid'); // any DOM/style change
Flip.from(state, {
  duration: 0.6,
  ease: 'power1.inOut',
  absolute: true,
  onLeave: els => gsap.to(els, { opacity: 0 }),
});
```

The docs: _"Flip records the current position/size/rotation of your elements, you make whatever changes you want"_, _"and then animate the removal of those offsets"_ ([Flip docs][gsap-docs-flip]). Two elements with the same `data-flip-id` but different nodes are a swap (`sd` ≠ 0), which yields shared-element transitions. An element visible before and invisible after goes into `leaving` and is handed to `onLeave`; one invisible before and visible after goes to `entering`/`onEnter` ([classification][gsap-flip-enterleave]). `absolute: true` takes elements out of flow during the flip so siblings do not reflow under it ([`_makeCompsAbsolute`][gsap-flip-absolute]).

Interruption: a new `getState` on targets with a running flip records their current, mid-flight geometry first and then forces the old flip to completion (`_killFlip(tl, 1)` → `tl.progress(1)`, [`FlipState.update`/`interrupt`][gsap-flip-interrupt], [`_killFlip`][gsap-flip-kill]); the docs: _"so that it gets forced to completion if a competing flip interrupts it"_ ([Flip docs][gsap-docs-flip]).

### `gsap.matchMedia()` and reduced motion

`gsap.matchMedia().add(conditions, fn)` runs `fn` inside a `Context` when a condition matches, listens for `change` on each `MediaQueryList`, and reverts everything the context created when the match flips ([`MatchMedia`][gsap-matchmedia]). The documented reduced-motion pattern is a condition the user writes:

```js
// adapted from the gsap.matchMedia() docs example
mm.add(
  {
    isDesktop: `(min-width: ${breakPoint}px)`,
    reduceMotion: '(prefers-reduced-motion: reduce)',
  },
  context => {
    let { isDesktop, reduceMotion } = context.conditions;
    gsap.to('.box', {
      rotation: isDesktop ? 360 : 180,
      duration: reduceMotion ? 0 : 2,
    }); // skip to the end if prefers-reduced-motion
  },
);
```

<a id="gsap-license"></a>**License.** The README states _"GSAP is now **100% FREE** including ALL of the bonus plugins"_ following Webflow's acquisition ([`README.md`][gsap-readme]), but the file headers say _"Subject to the terms at https://gsap.com/standard-license"_ ([`gsap-core.js`][gsap-core-header]) and the license grants use while listing as a prohibited use _"a solution that competes with Webflow's visual animation building capabilities"_ ([standard license][gsap-license]). It is free of charge, not open source.

---

## Analysis

### Where animation state lives

- **Godot `Tween`:** in a `RefCounted` object referenced by the `SceneTree`'s `tweens` list, outside the animated node; the node only receives property writes. The link back is an `ObjectID` (bound node, each target), resolved every step ([`Tween::step`][godot-tween-step-bound]). **`AnimationMixer`:** in the mixer node — current/next animation, playback position, blend weights, capture cache, state-machine playback.
- **Rive:** in the `StateMachineInstance` (inputs, view-model bindings, per-layer `m_currentState`/`m_stateFrom`/`m_mix`) and in the `ArtboardInstance` it writes to; layout tweens in each `LayoutComponent`'s lazily allocated `LayoutAnimation` ([`layout_component.hpp`][rive-lc-hdr]). The host holds only the instance handle.
- **Lottie:** nowhere in the document. A player holds one number per animation (`currentRawFrame`), plus play state.
- **GSAP:** in `Tween`/`Timeline` objects (start time, local time, `timeScale`, property tweens `s`/`c`), linked into the global timeline; a per-target cache (`_gsap`) holds the transform components GSAP last wrote. The DOM holds the rendered values.

The common pattern is that the _animated object_ does not own the animation: Godot, GSAP and Rive keep it in a side structure keyed by object identity (Godot's `ObjectID`, GSAP's target list and `data-flip-id`, Rive's instance pointers) — the shape of an identity-keyed element store.

### Declaring an animation

| System                | Form                                                                   | Implicit (value change animates)?                                                                                                        |
| --------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Godot `Tween`         | imperative controller, built step by step, starts immediately          | no; explicit `create_tween()`                                                                                                            |
| Godot `AnimationTree` | declarative graph authored in the editor; code sets parameters/travels | partly: setting a parameter (blend position, condition) changes what plays; transitions and blends animate the change                    |
| Rive                  | declarative state machine authored in the editor                       | yes at the state level: an input or bound value change makes a transition fire, which animates; layout styles animate any re-solved rect |
| Lottie                | declarative keyframes; no runtime declaration at all                   | not applicable — there is no target value to change                                                                                      |
| GSAP `to`/`Timeline`  | imperative, but each call is a declarative `vars` object               | no; `quickTo` makes a retargetable setter that behaves implicitly once created                                                           |
| GSAP `Flip`           | imperative bracket around a state change                               | the closest web library gets: any DOM change between `getState` and `from` animates                                                      |

Rive's model is the one that maps onto a pure component: the component (host) emits _values_ (`setBool`, a view-model number); a separately authored, data-only machine decides which animation that implies.

### Time and the clock

- **Godot:** frame deltas from the main loop, scaled by `Engine.time_scale` and `speed_scale`, in idle or physics passes; tweens run after nodes. Time accumulates by summing deltas: _"As it results from accumulating frame deltas, the time returned after the [Tween] has finished animating will be slightly greater than the actual [Tween] duration"_ ([`get_total_elapsed_time`][godot-tween-xml-elapsed]). `custom_step` and `ANIMATION_CALLBACK_MODE_PROCESS_MANUAL` + `advance` hand the clock to the caller.
- **Rive:** the host owns the clock outright. `advance(seconds)` is the only way time enters; nothing in the runtime reads a wall clock ([`state_machine_instance.hpp`][rive-smi-advance]).
- **Lottie:** time is a frame index in `[ip, op)` at `fr`; the player converts elapsed milliseconds to frames. Because evaluation depends only on the frame, any frame can be rendered in any order — the definition of a seekable timeline.
- **GSAP:** a single ticker on `requestAnimationFrame`, timed by `Date.now()` with lag smoothing (a long stall is clipped to 33 ms, so animations pause rather than jump), optional `fps` cap; every tween's time is derived from its parent timeline's, so time is hierarchical and seekable at every level.

Two notions of time coexist. _Accumulated deltas_ (Godot `Tween`, Rive state machine, Godot mixer) make the state a fold over the frame history — deterministic given the same deltas, but not seekable. _Time as a value_ (Lottie frames, GSAP `totalTime`, Godot `seek` and `interpolate_value`, Rive's `LinearAnimation::apply(time)`) makes a pose a pure function of position; scrubbing is then just choosing the position. Every system that has a seekable layer keeps its _transitions_ (Rive mixes, Godot crossfades, GSAP `overwrite`) in the accumulated layer above it.

### Interruption and retargeting

| System                   | When the target changes mid-flight                                                                                                                                            | Velocity kept?                     |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| Godot `Tween`            | nothing automatic; two tweens fight and the last created wins each frame. The documented idiom is `kill()` + new tween, whose `PropertyTweener` starts from the current value | no                                 |
| Godot mixer              | `play(other, custom_blend)` crossfades poses; `UPDATE_CAPTURE` blends from captured live values                                                                               | no                                 |
| Rive state machine       | blocked until the mix completes unless `EnableEarlyExit`; then the interrupted blend is frozen into reset values and a new mix starts at 0 ([source][rive-trans-start])       | no                                 |
| Rive layout              | new tween starts at the displayed rect; its start point is itself animated from the old tween until that one ends (smoothing buffer)                                          | no, but C⁰-continuous and softened |
| Lottie                   | not applicable: no runtime targets                                                                                                                                            | —                                  |
| GSAP `overwrite: "auto"` | the conflicting _properties_ of older tweens are killed when the new one first renders; the new one starts from the current value                                             | no                                 |
| GSAP `quickTo`/`resetTo` | same tween restarted from the current value, full duration                                                                                                                    | no                                 |
| GSAP `Flip`              | a new `getState` captures mid-flight geometry, then completes the old flip; the new flip starts at the captured rect                                                          | no                                 |

None of the four preserves velocity on retarget, and none animates additively by default. GSAP's relative values (`"+=100"`) and Godot's `as_relative()` add to the start value once, at start, not per frame. Rive's smoothing buffer is the most considered non-physical answer: it removes the corner that a plain restart leaves in the trajectory.

### Curves and springs

All four are duration + easing systems:

- **Godot:** eleven `TransitionType` families × four `EaseType`s, Penner-style equations in [`easing_equations.h`][godot-easing]. `TRANS_SPRING` is a fixed closed-form curve, `(sin(t·π·(0.2 + 2.5t³))·(1−t)^2.2 + t)·(1 + 1.2(1−t))` ([`Spring::out`][godot-spring]), not a damped oscillator with mass/stiffness/damping; `AnimationTree` crossfades take a unit `Curve` (`xfade_curve`).
- **Rive:** per-keyframe interpolators (linear, cubic bezier, elastic, scripted) and a per-transition interpolator applied to the mix weight; no physical springs.
- **Lottie:** per-keyframe, per-dimension cubic bezier handles with unclamped `y` (authored overshoot) and hold keyframes; no springs in the spec.
- **GSAP:** named eases (`power1`–`power4`, `back`, `elastic`, `bounce`, `expo`, `circ`, `sine`, `steps`), `CustomEase`/`CustomBounce`/`CustomWiggle`; physics only in `InertiaPlugin` (deceleration from a tracked velocity) and `Physics2DPlugin`/`PhysicsPropsPlugin`, not as a general spring ease.

The absence of springs follows from the time model: a closed-form ease is a function of `t / duration` and so stays seekable; a spring's state is position _and_ velocity, which only a stepped (accumulated) model carries.

### Layout animation

| System      | Mechanism                                                                                                                                                                                                                                                        | Phase                                                                                                                                                                                                    | Needs previous geometry?                                                        |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Godot       | none built in. A `Container` places children in a deferred `_sort_children`, and `fit_child_in_rect` calls `child->set_rect(r)`, `set_rotation(0)` and `set_scale(Vector2(1, 1))` ([`container.cpp`][godot-container-fit], [`queue_sort`][godot-container-sort]) | user code: a script must capture the old rect, let the container sort, then tween a visual offset (or a non-container parent); a tween on a container child's `position` is overwritten by the next sort | yes, captured by user code                                                      |
| Rive        | `LayoutComponent` tweens its own rect from the displayed `m_layout` to the newly solved Yoga rect, with a smoothing buffer for mid-flight targets                                                                                                                | **layout**: armed in `updateLayoutBounds` right after `calculateLayout`, interpolated in `advanceComponent` during artboard advance, before draw ([source][rive-artboard-sync])                          | yes, the component's own retained last rect — held by the runtime, not the user |
| Lottie      | not applicable: there is no layout engine; geometry is keyframed data                                                                                                                                                                                            | —                                                                                                                                                                                                        | —                                                                               |
| GSAP `Flip` | FLIP: measure (`getBoundingClientRect`, matrices), mutate DOM, measure again, tween inverse transforms to zero                                                                                                                                                   | **user code** brackets two forced synchronous layouts; the resulting tween writes inline `transform` per tick on the main thread, which the browser applies at paint/composite without relayout          | yes, captured explicitly by `getState` before the change                        |

Rive is the only one where layout animation is a property of the element (its layout style) rather than a procedure around a change, and the only one where the previous geometry is the runtime's own retained state. GSAP's Flip is the explicit two-snapshot version, and it is also the clearest illustration of the cost: both snapshots force layout, and the animation is a transform, so the element's _layout_ box jumps to the final rect at once while only its painted image travels.

### Enter and exit

- **Godot:** a removed node stops existing; there is no exit phase. The documented idiom sequences the exit before removal — `tween_property(...)` then `tween_callback($Sprite.queue_free)` ([`Tween.xml`][godot-tween-xml-desc]) — and `queue_free` itself defers deletion to the end of the frame (`_flush_delete_queue` after `process_tweens`, [`scene_tree.cpp`][godot-st-idle-call]). Binding defines the tween's fate when the node goes first: removed from the tree → halted; freed → killed ([`bind_node`][godot-tween-xml-bind]).
- **Rive:** elements are not created and destroyed by the host; they exist in the artboard and states animate their visibility. Exit is an authored transition (to a hidden state, or to the exit state). Items added to a component-list host snap to their first rect; the source names animate-in/out as unimplemented ([`updateLayoutBounds`][rive-lc-update]).
- **Lottie:** enter and exit are layer `ip`/`op` boundaries plus keyframed opacity/scale — authored, and a function of the frame.
- **GSAP:** GSAP does not observe DOM removal. `Flip` reports `leaving` elements only if they are still in the DOM but invisible in the final state, so the application keeps the node (`display: none`) until `onLeave`'s tween completes and then removes it itself ([classification][gsap-flip-enterleave]).

All four agree: exit is "keep it, animate it, then remove it", and the keeping is done by whoever owns the object's lifetime — the user's script (Godot, GSAP) or the authored file (Rive, Lottie). None has a retained snapshot of a removed element.

### Scheduling, reduced motion and testing

- **Frames only while animating.** lottie-web stops its `requestAnimationFrame` loop when no animation plays ([`AnimationManager.js`][lw-manager-loop]); GSAP's ticker sleeps after 120 idle frames and wakes on the next tween ([`updateRoot`][gsap-updateroot]); Rive's `advance` returns whether it _"will continue to animate after this advance"_ and `needsAdvance()` reports pending work, so the host decides whether to schedule another frame ([`state_machine_instance.hpp`][rive-smi-advance]). Godot redraws every frame by default; `OS.low_processor_usage_mode` _"only refresh[es] the screen if needed"_ ([`OS.xml`][godot-os-lowproc]).
- **Reduced motion.** Godot exposes `DisplayServer.accessibility_should_reduce_animation()` (_"implemented on Android, macOS, and Windows"_, [`DisplayServer.xml`][godot-ds-reduce]) but nothing in `Tween` or `AnimationMixer` consults it. GSAP documents a `prefers-reduced-motion` condition in `matchMedia` that sets durations to 0 ([matchMedia docs][gsap-docs-mm]); it is a pattern, not a default. The Rive runtime and the Lottie spec contain no reduced-motion handling (no match for the term in either tree); it is the host's job.
- **Deterministic clocks in tests.** Every system lets the caller drive time: Godot `custom_step(delta)`, `ANIMATION_CALLBACK_MODE_PROCESS_MANUAL` + `advance(delta)`, and the stateless `Tween.interpolate_value`; Rive `advance(seconds)`; Lottie `goToAndStop(frame, true)`; GSAP `gsap.ticker.tick()`, `lagSmoothing(0)`, and `seek`/`progress` on any timeline. The seekable ones are testable by sampling (render at `t`, compare); the accumulated ones by replaying a fixed delta sequence.

### Lessons for sparkles:ui

- **Rive is a working model of UI-Q5's presentation state machines.** The application writes plain values (inputs, view-model fields); an identity-attached machine, which components never call into, owns current state, from-state and a mix weight, and the host advances it with an explicit `dt`. For `sparkles:ui` the analogue is: a component emits target values and state names into the tree; the element store holds `{state, fromState, mix, startPose}` per identity; the host's commit step advances it. No hooks are needed because the component never sees the machine, only last frame's committed values.
- **Separate a seekable pose function from the stateful transition layer.** Lottie and GSAP show that a pose as a pure function of position is what makes scrubbing, testing and reduced motion (jump to the end) trivial; Rive and Godot show that interruption needs state above it (from-state, mix, captured start). A `@safe pure nothrow @nogc` component can evaluate the pure layer (`interpolate(from, to, ease, t)`, as Godot's `interpolate_value`) given `t` from the store; only the host advances `t`.
- **UI-Q9: layout animation needs last frame's rect, and the runtime should own it.** GSAP's Flip makes the user capture and re-measure (two forced layouts, user code); Godot leaves it to scripts and its containers overwrite position, rotation and scale; Rive retains each layout component's displayed rect and interpolates after the solve, before draw. The Rive placement — arm at layout commit using the stored previous rect, interpolate during the host's advance, paint the interpolated rect — fits an element store that already keeps last frame's measured size, and keeps the component from deciding anything based on in-flight geometry.
- **UI-Q10: every system keeps a removed element alive only because something owns its lifetime past removal.** Godot's `bind_node` semantics are the precise rule worth copying in reverse: an animation bound to an identity halts when the identity is out of the tree and dies when it is freed. For `sparkles:ui`, where lifetime is the set difference of identities, an exit animation means the store — not the component — defers the identity's removal while a closing state runs, painting from retained data. None of the four offers a retained snapshot; Flip's `onLeave` contract (element still present, marked invisible) is the closest to a "closing state the store drives".
- **Retargeting without velocity is the field's norm; Rive's smoothing buffer is the cheap upgrade.** If the store holds springs, it must hold velocity, and the pure-of-position property is lost for that element; if it holds tweens, blending the old tween's moving value into the new tween's start (Rive) removes the visible corner at no physics cost.
- **Let the host decide whether to schedule a frame.** Rive's `advance → bool` and lottie-web's "stop the loop when nothing plays" are the right interface for a backend that redraws only on change.

---

## Strengths

- **Godot:** two tools with a stated division of labour (`Tween` for run-time values, `AnimationPlayer` for authored ones); explicit, documented node-lifetime binding via `ObjectID`; capture tracks start authored animations from live values; manual stepping at every level.
- **Rive:** the host owns time and supplies only values; designers author behaviour as data; state mixing and layout interpolation are inside the runtime; `advance` reports whether more frames are needed.
- **Lottie:** an animation is pure data and a pure function of the frame; any frame renders in isolation; a written spec with MUST-level timing and easing rules; easy deterministic testing.
- **GSAP:** hierarchical, seekable time — every tween and timeline can be scrubbed, reversed and time-scaled; per-property `overwrite: "auto"`; `quickTo` for cheap retargeting; Flip turns arbitrary DOM changes into layout animations with shared-element swaps.

## Weaknesses

- **Godot:** concurrent tweens on one property silently fight; no retarget or velocity hand-off; `TRANS_SPRING` is a shape, not a spring; no layout animation, and containers reset child transforms; reduced motion is queryable but unused by the animation classes.
- **Rive:** transitions block further state changes unless early exit is enabled; interruption bakes and restarts the mix; no springs; no animate-in/out for dynamically hosted items; no reduced-motion handling in the runtime.
- **Lottie:** no runtime targets, interaction or layout; everything dynamic lives outside the format; frame-quantised playback unless subframes are enabled.
- **GSAP:** imperative and side-effecting (writes inline styles); Flip forces two synchronous layouts and animates transforms, not layout; no velocity preservation outside `InertiaPlugin`; exit handling is the user's; free of charge but proprietary, with a field-of-use restriction.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                        | Trade-off                                                                                             |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Godot: tweens live in the `SceneTree`, bound to nodes by `ObjectID`    | node can be freed at any time without dangling; a tween can animate many objects | the node does not know it is animated; lifetime rules must be documented and opted into (`bind_node`) |
| Godot: tweens are one-shot, not reusable                               | simple model: a tween is a script of steps run once                              | interruption means kill-and-recreate; no retargeting                                                  |
| Godot: `UPDATE_CAPTURE` tracks                                         | authored animations can start from live values                                   | per-track flag; capture is a crossfade, not a velocity match                                          |
| Rive: host supplies `dt` and values; runtime owns states and mixes     | one behaviour file runs identically on every platform; deterministic             | the host cannot override a mix in flight; behaviour changes need the editor                           |
| Rive: transitions block state changes unless `EnableEarlyExit`         | avoids pose pops from rapid input changes                                        | rapid inputs are dropped or delayed                                                                   |
| Rive: layout tweens retain the displayed rect and smooth retargets     | layout animation without user measurement; no corner on retarget                 | per-component memory once animated, never released; no enter/exit animation for hosted items          |
| Lottie: the file is a pure function of frame number                    | portability, seeking, deterministic rendering, trivial tests                     | no runtime interaction; interactivity is bolted on by players                                         |
| GSAP: every animation's state is a local time in a timeline tree       | scrub, reverse, nest and time-scale anything by writing one number               | transitions between independently created tweens need `overwrite` heuristics                          |
| GSAP: `overwrite: "auto"` kills conflicting properties at first render | per-property interruption without user bookkeeping                               | position-continuous only; velocity discarded; default is `false`                                      |
| GSAP: Flip measures before and after a DOM change                      | works with any layout engine (flex, grid) without knowing it                     | two forced layouts; animates transforms so the layout box jumps; the user must bracket the change     |

---

## Sources

- Godot `8f2e46b`: [`doc/classes/Tween.xml`][godot-tween-xml-desc], [`scene/animation/tween.cpp`][godot-tween-step-bound], [`scene/main/scene_tree.cpp`][godot-st-process-tweens], [`scene/main/node.cpp`][godot-node-create], [`scene/animation/easing_equations.h`][godot-easing], [`doc/classes/AnimationMixer.xml`][godot-mixer-xml], [`doc/classes/AnimationPlayer.xml`][godot-player-xml-play], [`doc/classes/AnimationNodeStateMachine.xml`][godot-sm-xml], [`doc/classes/AnimationNodeStateMachineTransition.xml`][godot-sm-trans-xml], [`scene/gui/container.cpp`][godot-container-fit], [`doc/classes/DisplayServer.xml`][godot-ds-reduce]
- Rive `c355fea`: [`state_machine_instance.hpp`][rive-smi-advance], [`state_machine_instance.cpp`][rive-layer-apply], [`state_transition_flags.hpp`][rive-trans-flags], [`layout_component.hpp`][rive-lc-hdr], [`layout_component.cpp`][rive-lc-update], [`artboard.cpp`][rive-artboard-sync]; docs: [state machine][rive-docs-sm], [transitions][rive-docs-trans], [data binding][rive-docs-db]
- Lottie spec `4b55957`: [`composition.md`][lottie-time], [`properties.md`][lottie-props], [`layers.md`][lottie-layer-vis]; lottie-web `bede03d`: [`AnimationManager.js`][lw-manager-loop], [`AnimationItem.js`][lw-advance]
- GSAP `5e6c35f` (3.15.1): [`src/gsap-core.js`][gsap-core], [`src/Flip.js`][gsap-flip], [`README.md`][gsap-readme]; docs: [Tween][gsap-docs-tween], [Timeline][gsap-docs-timeline], [ticker][gsap-docs-ticker], [quickTo][gsap-docs-quickto], [matchMedia][gsap-docs-mm], [Flip][gsap-docs-flip], [standard license][gsap-license]
- Related catalogs: [manim: Motion Canvas][manim-mc], [manim: Theatre.js][manim-theatre], [UI component authoring][ui-authoring]; UI-Q9/UI-Q10 ([PR #775][pr775])

<!-- References -->

[sparkles-ui]: ../../libs/ui/index.md
[ui-authoring]: ../ui-authoring/index.md
[manim]: ../manim/index.md
[manim-mc]: ../manim/motion-canvas.md
[manim-theatre]: ../manim/theatre-js.md
[pr775]: https://github.com/PetarKirov/sparkles/pull/775
[godot-repo]: https://github.com/godotengine/godot
[godot-license]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/LICENSE.txt
[godot-anim-dir]: https://github.com/godotengine/godot/tree/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/animation
[godot-doc-dir]: https://github.com/godotengine/godot/tree/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes
[godot-docs-tween]: https://docs.godotengine.org/en/stable/classes/class_tween.html
[godot-tween-xml-desc]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L6-L94
[godot-tween-xml-bind]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L98-L105
[godot-tween-xml-custom]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L126-L133
[godot-tween-xml-elapsed]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L140-L146
[godot-tween-xml-interp]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L153-L169
[godot-tween-xml-kill]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L182-L187
[godot-tween-xml-pause]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L210-L216
[godot-tween-xml-ease]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L223-L244
[godot-tween-xml-trans]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L304-L325
[godot-tween-xml-prop]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L541-L577
[godot-tween-xml-modes]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Tween.xml#L634-L648
[godot-tween-step-bound]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/animation/tween.cpp#L335-L432
[godot-tween-canprocess]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/animation/tween.cpp#L434-L451
[godot-tween-eq]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/animation/tween.cpp#L457-L474
[godot-ptw-start]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/animation/tween.cpp#L617-L638
[godot-ptw-step]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/animation/tween.cpp#L640-L686
[godot-st-phys-call]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/main/scene_tree.cpp#L662
[godot-st-idle-call]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/main/scene_tree.cpp#L731-L736
[godot-st-process-tweens]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/main/scene_tree.cpp#L826-L854
[godot-st-create]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/main/scene_tree.cpp#L1796-L1802
[godot-node-create]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/main/node.cpp#L2651-L2663
[godot-easing]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/animation/easing_equations.h
[godot-spring]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/animation/easing_equations.h#L417-L444
[godot-mixer-xml]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationMixer.xml#L6-L9
[godot-mixer-xml-advance]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationMixer.xml#L40-L46
[godot-mixer-xml-capture]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationMixer.xml#L47-L58
[godot-mixer-xml-det]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationMixer.xml#L308-L315
[godot-mixer-xml-reset]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationMixer.xml#L316-L319
[godot-mixer-xml-modes]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationMixer.xml#L373-L381
[godot-anim-xml-capture]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/Animation.xml#L761-L763
[godot-player-xml-play]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationPlayer.xml#L120-L132
[godot-player-xml-seek]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationPlayer.xml#L226-L236
[godot-player-xml-autocap]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationPlayer.xml#L318-L321
[godot-player-xml-blend]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationPlayer.xml#L332-L334
[godot-tree-xml]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationTree.xml#L6-L9
[godot-bs2d-xml]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationNodeBlendSpace2D.xml#L6-L9
[godot-sm-xml]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationNodeStateMachine.xml#L6-L12
[godot-sm-travel]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationNodeStateMachinePlayback.xml#L106-L115
[godot-sm-trans-xml]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationNodeStateMachineTransition.xml#L14-L49
[godot-sm-trans-modes]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/AnimationNodeStateMachineTransition.xml#L59-L67
[godot-container-fit]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/gui/container.cpp#L133-L178
[godot-container-sort]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/scene/gui/container.cpp#L180-L192
[godot-ds-reduce]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/DisplayServer.xml#L115-L121
[godot-os-lowproc]: https://github.com/godotengine/godot/blob/8f2e46bca3c1cca8f3b759a0eaf67e44082b81a4/doc/classes/OS.xml#L914-L917
[rive-repo]: https://github.com/rive-app/rive-runtime
[rive-license]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/LICENSE
[rive-anim-dir]: https://github.com/rive-app/rive-runtime/tree/c355fea551408e006cd62e2ff48eaf2b671be98f/src/animation
[rive-anim-include]: https://github.com/rive-app/rive-runtime/tree/c355fea551408e006cd62e2ff48eaf2b671be98f/include/rive/animation
[rive-smi-advance]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/include/rive/animation/state_machine_instance.hpp#L172-L196
[rive-lai]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/include/rive/animation/linear_animation_instance.hpp#L24-L110
[rive-trans-flags]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/include/rive/animation/state_transition_flags.hpp#L8-L31
[rive-la-apply]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/animation/linear_animation.cpp#L436-L439
[rive-kp-apply]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/animation/keyed_property.cpp#L115-L129
[rive-layer-fields]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/animation/state_machine_instance.cpp#L1155-L1166
[rive-update-mix]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/animation/state_machine_instance.cpp#L229-L262
[rive-update-state]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/animation/state_machine_instance.cpp#L640-L650
[rive-trans-start]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/animation/state_machine_instance.cpp#L1015-L1067
[rive-layer-apply]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/animation/state_machine_instance.cpp#L1072-L1119
[rive-lc-hdr]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/include/rive/layout_component.hpp#L154-L194
[rive-lc-update]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/layout_component.cpp#L1665-L1747
[rive-lc-advance]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/layout_component.cpp#L1785-L1797
[rive-lc-apply]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/layout_component.cpp#L2021-L2081
[rive-artboard-sync]: https://github.com/rive-app/rive-runtime/blob/c355fea551408e006cd62e2ff48eaf2b671be98f/src/artboard.cpp#L2950-L2959
[rive-docs-sm]: https://rive.app/docs/editor/state-machine/state-machine
[rive-docs-trans]: https://rive.app/docs/editor/state-machine/transitions
[rive-docs-db]: https://rive.app/docs/editor/data-binding/overview
[lottie-repo]: https://github.com/lottie/lottie-spec
[lottie-site]: https://lottie.github.io/lottie-spec/
[lottie-license]: https://github.com/lottie/lottie-spec/blob/4b55957472f8718e34e9c1298f0e8f021b6c597f/License.md
[lottie-index]: https://github.com/lottie/lottie-spec/blob/4b55957472f8718e34e9c1298f0e8f021b6c597f/docs/index.md#L1-L11
[lottie-time]: https://github.com/lottie/lottie-spec/blob/4b55957472f8718e34e9c1298f0e8f021b6c597f/docs/specs/composition.md#L9-L22
[lottie-props]: https://github.com/lottie/lottie-spec/blob/4b55957472f8718e34e9c1298f0e8f021b6c597f/docs/specs/properties.md#L1-L13
[lottie-keyframes]: https://github.com/lottie/lottie-spec/blob/4b55957472f8718e34e9c1298f0e8f021b6c597f/docs/specs/properties.md#L28-L44
[lottie-easing]: https://github.com/lottie/lottie-spec/blob/4b55957472f8718e34e9c1298f0e8f021b6c597f/docs/specs/properties.md#L46-L140
[lottie-layer-vis]: https://github.com/lottie/lottie-spec/blob/4b55957472f8718e34e9c1298f0e8f021b6c597f/docs/specs/layers.md#L17-L22
[lottie-timestretch]: https://github.com/lottie/lottie-spec/blob/4b55957472f8718e34e9c1298f0e8f021b6c597f/docs/specs/layers.md#L127-L164
[lw-repo]: https://github.com/airbnb/lottie-web
[lw-license]: https://github.com/airbnb/lottie-web/blob/bede03d25d232826e0c9dca1733d542d8a7754fb/LICENSE.md
[lw-manager-loop]: https://github.com/airbnb/lottie-web/blob/bede03d25d232826e0c9dca1733d542d8a7754fb/player/js/animation/AnimationManager.js#L99-L117
[lw-gotoframe]: https://github.com/airbnb/lottie-web/blob/bede03d25d232826e0c9dca1733d542d8a7754fb/player/js/animation/AnimationItem.js#L365-L378
[lw-gotoandstop]: https://github.com/airbnb/lottie-web/blob/bede03d25d232826e0c9dca1733d542d8a7754fb/player/js/animation/AnimationItem.js#L454-L490
[lw-advance]: https://github.com/airbnb/lottie-web/blob/bede03d25d232826e0c9dca1733d542d8a7754fb/player/js/animation/AnimationItem.js#L492-L530
[gsap-repo]: https://github.com/greensock/GSAP
[gsap-pkg]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/package.json#L66
[gsap-readme]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/README.md
[gsap-core]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js
[gsap-core-header]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L1-L8
[gsap-flip]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/Flip.js
[gsap-parse-pos]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L390-L414
[gsap-ticker]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L886-L971
[gsap-totaltime]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L1188-L1226
[gsap-progress]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L1227-L1229
[gsap-timescale]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L1247-L1262
[gsap-seek]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L1372-L1374
[gsap-updateroot]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L1986-L2000
[gsap-inittween]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L2131-L2140
[gsap-autooverwrite]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L2217-L2223
[gsap-updatepts]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L2259-L2268
[gsap-resetto]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L2569-L2590
[gsap-global-tl]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L2835
[gsap-matchmedia]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L2993-L3023
[gsap-quickto]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L3090-L3095
[gsap-ticker-add]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/gsap-core.js#L3175
[gsap-inertia]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/InertiaPlugin.js
[gsap-flip-id]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/Flip.js#L185-L189
[gsap-flip-enterleave]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/Flip.js#L403-L412
[gsap-flip-absolute]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/Flip.js#L508-L515
[gsap-flip-kill]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/Flip.js#L526-L534
[gsap-flip-interrupt]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/Flip.js#L566-L692
[gsap-flip-elstate]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/Flip.js#L734-L760
[gsap-flip-class]: https://github.com/greensock/GSAP/blob/5e6c35ff8eedea12d4f229129def635277d8b0f2/src/Flip.js#L952-L975
[gsap-docs-tween]: https://gsap.com/docs/v3/GSAP/Tween/
[gsap-docs-timeline]: https://gsap.com/docs/v3/GSAP/Timeline/
[gsap-docs-ticker]: https://gsap.com/docs/v3/GSAP/gsap.ticker/
[gsap-docs-quickto]: https://gsap.com/docs/v3/GSAP/gsap.quickTo()/
[gsap-docs-mm]: https://gsap.com/docs/v3/GSAP/gsap.matchMedia()/
[gsap-docs-flip]: https://gsap.com/docs/v3/Plugins/Flip/
[gsap-license]: https://gsap.com/standard-license
