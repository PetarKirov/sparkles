# Svelte transitions, `animate:` and motion (Svelte)

Svelte's template directives for animation: `transition:`/`in:`/`out:` attach a function that returns a `css(t, u)` or `tick(t, u)` program, which the runtime samples into Web Animations keyframes when a block enters or leaves; a leaving block is _paused_ rather than destroyed, so its DOM stays until every outro finishes; `animate:` runs FLIP on keyed `{#each}` reorders, measuring each item immediately before reconciliation and again in a microtask after it; `svelte/motion` supplies rune-backed `Tween` and `Spring` values.

| Field                    | Value                                                                                                                                                                                                                                                                              |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                 | Svelte components compiled to JavaScript; runtime in JavaScript with JSDoc types                                                                                                                                                                                                   |
| License                  | MIT ([`LICENSE.md`][license])                                                                                                                                                                                                                                                      |
| Repository               | [sveltejs/svelte][repo]: [`src/transition`][src-transition], [`src/animate`][src-animate], [`src/motion`][src-motion], runtime [`dom/elements/transitions.js`][rt-transitions], [`dom/blocks/each.js`][rt-each]                                                                    |
| Documentation            | [svelte.dev/docs][docs]: [`transition:`][doc-transition], [`in:` and `out:`][doc-inout], [`animate:`][doc-animate], [`svelte/motion`][doc-motion] (sources under `documentation/docs` in the repository)                                                                           |
| Category                 | compiler-attached, runtime-managed directive animations over the DOM; WAAPI playback of sampled keyframes; signal-backed tween/spring values                                                                                                                                       |
| Versions surveyed        | Svelte **5.59.2** (`packages/svelte/package.json`) at commit `f076077` (2026-11-25)                                                                                                                                                                                                |
| Animation state lives in | per-block _transition managers_ (`effect.nodes.t`) and per-item _animation managers_ (`effect.nodes.a`) attached to the runtime's effect tree, holding the running WAAPI `Animation`; the leaving block's effect itself (flagged `INERT`/`PAUSED`); `Tween`/`Spring` state signals |

> [!NOTE]
> Read for [`sparkles:ui`][ui-authoring]'s two open questions: where FLIP takes its _before_ and _after_ geometry (UI-Q9, [PR #775][pr775]) and how a block removed from the description keeps painting through its exit (UI-Q10). The Web Animations objects Svelte creates are described on [Web Animations][web-animations]; the React libraries that solve the same problems from a virtual DOM are on [Motion and React Spring][react-motion]. Svelte 5's signals ("runes") are close kin to [Solid's][solid-signals]; vocabulary is on [Concepts][concepts]. Every source link is pinned to `f076077`; paths below are relative to `packages/svelte/src` unless stated.

---

## Overview

### What it solves

A compiled UI framework that updates the DOM in place has no virtual-DOM diff in which to keep a removed node, and no hook for "where was this element before the update". Svelte puts both into the runtime's block machinery: an `{#if}` or `{#each}` block that is about to remove a branch asks that branch's transitions to play first, and a keyed `{#each}` that is about to move items asks each item to measure itself first. The docs state the user-facing contract: _"A transition is triggered by an element entering or leaving the DOM as a result of a state change. When a block (such as an `{#if ...}` block) is transitioning out, all elements inside it, including those that do not have their own transitions, are kept in the DOM until every transition in the block has been completed"_ ([`14-transition.md`][doc-transition-src]).

### Design philosophy

- **A transition is a pure function of progress.** A transition function returns `{ delay, duration, easing, css, tick }`; _"The `t` argument passed to `css` is a value between `0` and `1` after the `easing` function has been applied. In transitions run from `0` to `1`, out transitions run from `1` to `0` — in other words, `1` is the element's natural state"_, and _"The function is called repeatedly before the transition begins, with different `t` and `u` arguments"_ ([`14-transition.md`][doc-css-src]).
- **Prefer declarative output the browser can run off-thread.** _"If it's possible to use `css` instead of `tick`, do so — web animations can run off the main thread, preventing jank on slower devices"_ ([source][doc-tick-src]).
- **Transitions are local by default.** _"Local transitions only play when the block they belong to is created or destroyed, not when parent blocks are created or destroyed"_; `|global` opts in ([source][doc-local-src]).
- **Leaving is pausing.** The runtime comment: _"When a block effect is removed, we don't immediately destroy it or yank it out of the DOM, because it might have transitions. Instead, we 'pause' it. It stays around (in memory, and in the DOM) until outro transitions have completed, and if the state change is reversed then we resume it"_ ([`pause_effect`][rt-pause]).

---

## How it works

### Compilation: directives become runtime calls

The compiler turns `transition:fade={params}` into `$.transition(flags, node, () => fade, () => params)`, where `flags` packs `TRANSITION_IN`, `TRANSITION_OUT` (both for `transition:`, one for `in:`/`out:`) and `TRANSITION_GLOBAL` for `|global`; the call is emitted into the element's `after_update` list, _"to ensure it always happens after bind:this"_ ([`TransitionDirective.js`][c-transition]). `animate:flip` becomes `$.animation(node, () => flip, params)` ([`AnimateDirective.js`][c-animate]) and sets `EACH_IS_ANIMATED` on the enclosing each block ([`EachBlock.js`][c-each]). Nothing about the animation itself is compiled: the transition function runs at runtime, against the live element.

```svelte
<script>
    import { fade, fly } from 'svelte/transition';
    import { flip } from 'svelte/animate';
    let visible = $state(true);
    let items = $state([1, 2, 3]);
</script>

{#if visible}
    <div in:fly={{ y: 200 }} out:fade>flies in, fades out</div>
{/if}

{#each items as item (item)}
    <li animate:flip transition:fade>{item}</li>
{/each}
```

### Transition managers on the effect tree

Svelte 5's runtime is a tree of _effects_: block effects (`{#if}`, `{#each}`, `{#key}`) own branch effects, which own the DOM nodes and template effects of one branch. `$.transition(...)` creates a `TransitionManager` — `{ is_global, in(), out(fn), stop() }` — and pushes it onto the current effect's `nodes.t` list ([`transition`][rt-transition]). An intro runs on creation only if the transition is `|global` or the parent block effect has already run once (`REACTION_RAN`), which is how "local" is decided: a block created as part of its parent's first render does not intro ([source][rt-local]).

When a block decides a branch must go, it calls `pause_effect(branch, callback)` instead of destroying it ([`pause_effect`][rt-pause]). `pause_children` walks the subtree, flips each effect to `INERT` (an inert effect no longer updates), and collects transition managers — every manager of the branch's own elements, but in nested blocks only `|global` ones, since `local` is carried down only through _transparent_ effects ([`pause_children`][rt-pause-children]). Each collected manager's `out(check)` runs; when the last calls `check`, the branch is destroyed and the callback fires. If the state flips back before that, `resume_effect` clears `INERT`, schedules any effect whose dependencies changed while paused, and calls `in()` on the managers ([`resume_children`][rt-resume]). A manager's `out` also sets `element.inert = true`, so an outroing element cannot be focused or clicked ([source][rt-out]).

### `animate()`: sampling `css` into Web Animations keyframes

Both intros and outros end in the internal `animate(element, options, counterpart, t2, …)` ([source][rt-animate]). It takes the target `t2` (1 for intro, 0 for outro) and the start `t1` from the opposite-direction animation still running, if any (`counterpart?.t()`), so a `transition:` reversed mid-flight continues from its current progress and lasts `duration * |t2 − t1|`. With a `css` function it **samples** the program into one keyframe per 60 Hz frame and hands them to `element.animate` ([source][rt-sample]):

```js
// packages/svelte/src/internal/client/dom/elements/transitions.js — animate()
if (css) {
  var n = Math.ceil(d / (1000 / 60)); // `n` must be an integer, or we risk missing the `t2` value
  for (var i = 0; i <= n; i += 1) {
    var t = t1 + delta * easing(i / n);
    var styles = css_to_keyframe(css(t, 1 - t));
    keyframes.push(styles);
  }
}
// …
animation = element.animate(keyframes, { duration: d, fill: 'forwards' });
```

Easing is baked into the keyframe values, and the WAAPI animation is linear in time. Progress is read back from `animation.currentTime` (`get_t`), which is what a reversing counterpart uses. A `tick` function is driven from Svelte's own `requestAnimationFrame` task loop, reading the same `get_t` ([`loop.js`][rt-loop]). The docs state the platform consequence: _"Transitions are driven by the Web Animations API rather than by CSS. A global `@media (prefers-reduced-motion: reduce)` rule that zeroes `transition-duration` and `animation-duration` therefore has no effect on them"_ ([source][doc-a11y-src]). Svelte 4 sampled the same `css` function into a CSS `@keyframes` rule inserted into a generated stylesheet and set `node.style.animation` to it (`create_rule` in [`style_manager.js`][v4-style-manager], tag `svelte@4.2.19`); Svelte 5 plays the frames through `element.animate`, and since `5.0.0-next.240` also times `tick`-only transitions with WAAPI ([`CHANGELOG.md`][changelog-waapi]).

Any `delay` is a dummy WAAPI animation of that length that holds the intro's first keyframe (`fill: 'forwards'`), created in a microtask _"so that transitions created in the same batch (e.g. on nested elements) all measure the DOM first … this still happens before the next paint"_ ([source][rt-delay]). A transition function may instead return a **function**, called in the next microtask — after the DOM update — which is how deferred transitions coordinate ([source][rt-deferred]).

### Built-in transitions and `crossfade`

`svelte/transition` provides `fade`, `blur`, `fly`, `slide`, `scale`, `draw` (SVG stroke) and `crossfade`; each reads the element's computed style once and returns a `css` template (e.g. `fade` reads the element's opacity `o` and returns a `css` that writes `opacity: t * o`, [`transition/index.js`][src-transition-file]). `crossfade({ fallback })` returns a `[send, receive]` pair sharing two maps keyed by a user `key`. Each side registers its node and returns a deferred transition; in the microtask, if the counterpart map has the key, it measures **both** nodes with `getBoundingClientRect` and returns a `css` that translates and scales the incoming node from the outgoing node's rect, otherwise it uses `fallback` ([`crossfade`][src-crossfade]). This is a shared-element transition between two elements that exist simultaneously in the DOM — the outgoing one kept by its outro.

### `animate:` and FLIP in keyed each blocks

`$.animation(...)` attaches an _animation manager_ `{ element, measure, apply, fix, unfix }` to the item's effect as `nodes.a` ([`animation`][rt-animation]). Keyed `{#each}` reconciliation drives it in four places ([`reconcile`][rt-reconcile]):

| Step                                              | Code                                                                         | Effect                                                                                                                                                                                                                                                 |
| ------------------------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1. start of `reconcile`, before any DOM move      | `effect.nodes?.a?.measure()` for every surviving item ([source][rt-measure]) | `from = element.getBoundingClientRect()` — the **old** geometry, read from the live DOM (items coming in for the first time are skipped)                                                                                                               |
| 2. items being removed, after their own `measure` | `a.fix()` ([source][rt-fix])                                                 | an outroing item is switched to `position: absolute` with its computed width/height and translated back to `from`, so it leaves the flow (survivors close the gap and animate) while it keeps painting where it was                                    |
| 3. DOM moves                                      | the reconciliation itself                                                    | items are inserted/moved; removed items are `pause_effects`-ed                                                                                                                                                                                         |
| 4. microtask after `reconcile`, before paint      | `queue_micro_task(() => … a.apply())` ([source][rt-apply])                   | `to = element.getBoundingClientRect()` — the **new** geometry (forced layout); if any edge differs, call the user's animation function with `{ from, to }` and play its `css` through the same `animate()`, aborting any previous move animation first |

The built-in `flip` computes the translate and scale that map `to` back onto `from` (correcting for `transform-origin`, parent transforms and CSS `zoom`) and returns `css: (t, u) => transform: … translate(u*dx, u*dy) scale(…)` with a distance-dependent default duration `Math.sqrt(d) * 120` ([`animate/index.js`][src-flip]). The docs: _"Animations do not run when an element is added or removed, only when the index of an existing data item within the each block changes"_, and `to` is _"the DOMRect of the element in its final position after the list has been reordered and the DOM updated"_ ([`16-animate.md`][doc-animate-src]).

The whole sequence runs inside Svelte's effect flush: a state change schedules the each block's effect; when the batch flushes (a microtask after the change, or synchronously under `flushSync`), `reconcile` measures, moves, and queues `apply` in a microtask — all before the browser's next rendering opportunity.

### `svelte/motion`: `Tween`, `Spring`, `prefersReducedMotion`

`Tween` and `Spring` (since 5.8.0) are classes whose `current` and `target` are rune state signals; reading `.current` in a template subscribes to it. `tween.target = v` / `tween.set(v, opts)` starts a task on Svelte's `requestAnimationFrame` loop that interpolates from the current value and writes `current` each frame ([`Tween.set`][src-tween-set]); `Tween.of(() => expr)` creates one and retargets it from a `render_effect` whenever `expr` changes ([`Tween.of`][src-tween-of]). `Spring` integrates a semi-implicit step per frame from the last two values ([`tick_spring`][src-tick-spring]):

```js
// packages/svelte/src/motion/spring.js — tick_spring
const delta = target_value - current_value;
const velocity = (current_value - last_value) / (ctx.dt || 1 / 60); // guard div by 0
const spring = ctx.opts.stiffness * delta;
const damper = ctx.opts.damping * velocity;
const acceleration = (spring - damper) * ctx.inv_mass;
const d = (velocity + acceleration) * ctx.dt;
```

`stiffness` and `damping` are clamped to `[0, 1]` (defaults 0.15 and 0.8) and `precision` (0.01) is the settle threshold; `dt` is in 60 Hz frame units with elapsed time clamped to 1/30 s, _"so that longer pauses (blocked thread or inactive tab) don't cause the spring to go haywire"_ ([`Spring.#update`][src-spring-update]). `set(v, { instant: true })` jumps; `set(v, { preserveMomentum: ms })` zeroes the inverse mass and lets it recover over `ms`, so the spring coasts on its current trajectory — for flings ([`Spring.set`][src-spring-set]). The Svelte 4 stores `tweened` and `spring` remain, marked `@deprecated` in favour of the classes. `prefersReducedMotion` is a `MediaQuery` on `(prefers-reduced-motion: reduce)` whose `.current` is reactive ([`motion/index.js`][src-motion-index]).

---

## Analysis

### Where animation state lives

On the runtime's effect tree, not in components. A block's elements carry `TransitionManager`s in `effect.nodes.t`, each holding the running intro/outro `Animation` handles and the cached `current_options` (kept while a transition is in flight _"so that reversible transitions reverse smoothly"_, [source][rt-options]); a keyed item carries one animation manager in `effect.nodes.a` holding `from`, `to` and the running move animation. The visual progress of a CSS transition lives in the browser's `Animation` object (`currentTime`), and Svelte reads it back on reversal. The fact that a branch is leaving is the branch effect's `PAUSED`/`INERT` flags. Value animations (`Tween`, `Spring`) are plain objects holding state signals plus a task handle; their identity is whatever the component holds.

### Declaring an animation

Transitions and `animate:` are **declarative and explicit, attached to presence**: the directive names a function, and the runtime decides when to run it — on block creation (intro), removal (outro) or reorder (animate). Nothing animates implicitly when an attribute or style changes; a changing value is animated only by routing it through `Tween`/`Spring`, which is implicit in the sense that setting `target` (or a `Tween.of` dependency changing) animates. The animation program itself is a pure function `t → css string`, sampled ahead of time; `tick` is the imperative escape hatch.

### Time and the clock

Two clocks. CSS transitions and `animate:` moves play on the **document timeline** as WAAPI animations: duration is fixed when the keyframes are sampled and the browser advances them, off the main thread when the properties allow. `tick` callbacks, `Tween` and `Spring` run on Svelte's own task loop, a single `requestAnimationFrame` callback that calls each task with `raf.now()` (`performance.now()` in the browser) — deliberately not the rAF timestamp argument ([`loop.js`][rt-loop], [`timing.js`][rt-timing]). `raf` is an internal mutable object (`tick`, `now`, `tasks`), which is how tests replace it.

### Interruption and retargeting

**Transitions** reverse, they do not retarget: a bidirectional `transition:` interrupted mid-outro starts its intro from the outro's current `t` and runs for the remaining fraction of the duration, using the same cached options; velocity is not considered (the progress curve simply turns around). `in:`/`out:` are not reversible — _"an `in` transition will continue to 'play' alongside the `out` transition, rather than reversing … If an out transition is aborted, transitions will restart from scratch"_ ([`15-in-and-out.md`][doc-inout-src]). **`animate:`** aborts the running move and starts a fresh one from the freshly measured `from` — which includes the old animation's current transform, since `getBoundingClientRect` reports the visual box — again without velocity. **`Tween.set`** restarts interpolation from `current` with the full duration, no velocity. **`Spring`** keeps velocity implicitly: velocity is `(current − last) / dt`, and a new target changes only `delta`, so the motion continues smoothly. Nothing is additive.

### Curves and springs

Transitions and `animate:` are duration + easing (`svelte/easing` supplies the Penner set plus `linear`); easing is applied while sampling, so arbitrary JS easing functions work on WAAPI. Durations may be functions of distance (`flip`'s `Math.sqrt(d) * 120`, `crossfade`'s `Math.sqrt(d) * 30`). `Spring` is the only physics: unitless `stiffness`/`damping` in `[0, 1]` and a `precision` threshold, integrated per frame (frame-rate-normalised to 60 Hz units), plus `preserveMomentum`. There is no spring-driven transition or `animate:`.

### Layout animation

`animate:` is FLIP on keyed each items only. _First_ is read from the **live DOM** with `getBoundingClientRect` at the **start of `reconcile`**, in the each block's effect, before items are moved; _Last_ is read in a **microtask after reconcile**, after the DOM mutation and before paint, forcing layout; _Invert/Play_ is a WAAPI transform animation sampled from the user's `css` and run by the browser — on the compositor when only `transform`/`opacity` change ([table above](#animate-and-flip-in-keyed-each-blocks)). It needs the previous geometry and obtains it by measuring before mutating, not from retained layout state. Items that leave are taken out of flow (`fix`: `position: absolute` + a compensating translate) so their outro keeps them visible at their old place while survivors FLIP into the gap. Elements outside a keyed each, or size changes that are not reorders, have no layout animation; `crossfade` provides element-to-element transitions by measuring both elements in the deferred-transition microtask.

### Enter and exit

Exit keeps the **real DOM subtree and its effects** alive: `pause_effect` marks the branch `INERT` (no further updates — the content is frozen as of the removal), plays every local transition's outro and destroys the branch when the last completes; elements without transitions in that block stay too. An outroing element is `inert`. A reversal before completion resumes the same effect and DOM. For keyed each items, a leaving item is additionally `fix`ed out of flow. Enter runs `in()` on creation, skipped for local transitions whose parent block is itself being created (and on hydration/initial mount unless `intro: true` is passed to `mount`). Elements report `introstart`/`introend`/`outrostart`/`outroend` events.

### Scheduling, reduced motion and testing

WAAPI animations need no frames from Svelte; the task loop books `requestAnimationFrame` only while `raf.tasks` is non-empty and stops when every task returns false ([`loop.js`][rt-loop]); `Spring` drops its task once settled. **Reduced motion is the author's job**: Svelte does not consult the preference, and because transitions are WAAPI, a CSS `prefers-reduced-motion` reset does not affect them — the docs direct authors to `prefersReducedMotion.current` to shrink or skip the transition ([source][doc-a11y-src]). **Testing**: Svelte's own suite swaps `raf.tick` and `raf.now` for a manual clock and replaces `Element.prototype.animate` with a fake `Animation` advanced by `raf.tick(time)`, which calls `flushSync()` first ([`tests/animation-helpers.js`][t-helpers]) — a deterministic clock for both the task loop and WAAPI; `flushSync` itself is public.

### Lessons for sparkles:ui

- **Svelte's FLIP shape matches a frame pipeline cleanly:** measure before mutation, measure after, animate a transform. In `sparkles:ui` neither measurement needs a DOM read: _First_ is last frame's committed rect in the element store, _Last_ is this frame's layout result, and the inversion is applied after layout, before paint (UI-Q9). Svelte's two forced layouts per reorder are the cost sparkles avoids by construction.
- **"Pause, don't destroy" is the UI-Q10 answer in a retained runtime:** the exiting branch stays in the tree, frozen (`INERT`), with its transitions playing, and is resurrected on reversal. In an immediate-mode builder the equivalent is a store entry for an identity absent from this frame's set that keeps a _retained snapshot_ of its last subtree (Svelte's choice: content frozen at removal) — distinct from React Spring's re-build-with-`leave`-phase alternative on [Motion and React Spring][react-motion].
- **`fix()` is a necessary detail:** a leaving item must be taken out of layout yet painted at its old rect, or survivors cannot animate into the gap. In sparkles that means the store can paint a closing element at its last rect without it participating in this frame's layout.
- **A transition as `t → style` is purity-friendly and precomputable.** Svelte samples it into keyframes once; sparkles can evaluate the same pure function per frame from the store's phase, with no allocation and no callback into components.
- **Reversal versus velocity.** Svelte's reversible transitions keep progress but not velocity; only `Spring`, whose velocity is the difference of its last two values, retargets smoothly — the minimal state an element-store spring needs is `(current, previous, target)`.

---

## Strengths

- Exit animations are a property of the block machinery: any removed subtree, including untransitioned children, stays until its outros finish, and reversal resumes the same DOM.
- Transition programs are small pure functions; `css` output plays as WAAPI, often off the main thread; arbitrary easing still works because it is sampled.
- `animate:flip` gives keyed-list FLIP with one directive, including leaving-item out-of-flow handling and `crossfade` shared elements.
- Local-by-default transitions avoid cascades of animations when an ancestor block appears or disappears.
- `Spring`/`Tween` are rune-native and need no subscription plumbing; `preserveMomentum` supports flings.

## Weaknesses

- Layout animation is limited to reorders in keyed each blocks; resizes and moves caused by other changes do not animate.
- FLIP and `crossfade` force synchronous layout (`getBoundingClientRect`) before and after each reconcile.
- Transitions and moves are duration-based; interruption keeps progress but drops velocity; `animate:` restarts on every reorder.
- Keyframes are sampled at 60 Hz from the start state; a `css` function that reads changing state during playback cannot be expressed, and `tick` is main-thread.
- Reduced motion is entirely opt-in per transition, and the WAAPI choice defeats the common CSS-reset approach.

---

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                               | Trade-off                                                                         |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Transitions are functions `t → css` sampled into WAAPI keyframes       | declarative output the browser can play off-thread; any JS easing works | fixed at start; 60 Hz sampling; bypasses CSS `prefers-reduced-motion` resets      |
| Leaving blocks are paused (`INERT`) until every outro finishes         | the DOM and effects survive the exit and can be resumed on reversal     | the leaving content is frozen at removal; outro bookkeeping on the effect tree    |
| Transitions are local by default, `\|global` opt-in                    | prevents a whole subtree animating when an ancestor block toggles       | authors must know which block owns a transition                                   |
| `animate:` measures at the start of reconcile and in a microtask after | the DOM is the geometry store; both reads land before paint             | two forced layouts per reorder; only keyed each items animate                     |
| Leaving each items are `fix`ed out of flow                             | survivors can FLIP into the gap while the leaver outros in place        | inline style rewriting (`position`, size, transform) restored by `unfix`          |
| Bidirectional transitions reverse from current `t`                     | smooth reversal without velocity bookkeeping                            | no momentum; `in:`/`out:` cannot reverse at all                                   |
| `Tween`/`Spring` are rune-backed classes on a rAF task loop            | composes with the reactivity system; reads subscribe                    | main-thread, per-frame signal writes; a separate clock from the WAAPI transitions |

---

## Sources

- Svelte source at [`f076077`][repo]: [`internal/client/dom/elements/transitions.js`][rt-transitions], [`internal/client/dom/blocks/each.js`][rt-each], [`internal/client/reactivity/effects.js`][rt-pause], [`internal/client/loop.js`][rt-loop], [`transition/index.js`][src-transition-file], [`animate/index.js`][src-flip], [`motion/spring.js`][src-tick-spring], [`motion/tweened.js`][src-tween-set], compiler visitors [`TransitionDirective.js`][c-transition] and [`AnimateDirective.js`][c-animate], [`tests/animation-helpers.js`][t-helpers].
- Svelte documentation: [`transition:`][doc-transition], [`in:` and `out:`][doc-inout], [`animate:`][doc-animate], [`svelte/motion`][doc-motion], [`svelte/transition`][doc-transition-ref]; [_Svelte 5 is alive_][blog-svelte5] (2024-10-22).
- Paul Lewis, [_FLIP Your Animations_][flip] (2015).
- Related pages: [Motion and React Spring][react-motion], [Web Animations][web-animations], [CSS Transitions and Animations][css-anim], [Solid signals][solid-signals], [Concepts][concepts].

<!-- References -->

[pr775]: https://github.com/PetarKirov/sparkles/pull/775
[ui-authoring]: ../ui-authoring/index.md
[solid-signals]: ../reactive-programming/solid-signals.md
[react-motion]: ./react-motion-and-spring.md
[web-animations]: ./web-animations.md
[css-anim]: ./css-transitions-and-animations.md
[concepts]: ./concepts.md
[flip]: https://aerotwist.com/blog/flip-your-animations/
[blog-svelte5]: https://svelte.dev/blog/svelte-5-is-alive
[docs]: https://svelte.dev/docs/svelte
[doc-transition]: https://svelte.dev/docs/svelte/transition
[doc-inout]: https://svelte.dev/docs/svelte/in-and-out
[doc-animate]: https://svelte.dev/docs/svelte/animate
[doc-motion]: https://svelte.dev/docs/svelte/svelte-motion
[doc-transition-ref]: https://svelte.dev/docs/svelte/svelte-transition
[repo]: https://github.com/sveltejs/svelte/tree/f076077c6a07496a431e799a51dc361eda6562ab
[license]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/LICENSE.md
[doc-transition-src]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/documentation/docs/03-template-syntax/14-transition.md#L6-L8
[doc-local-src]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/documentation/docs/03-template-syntax/14-transition.md#L26-L38
[doc-a11y-src]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/documentation/docs/03-template-syntax/14-transition.md#L56-L60
[doc-css-src]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/documentation/docs/03-template-syntax/14-transition.md#L76-L80
[doc-tick-src]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/documentation/docs/03-template-syntax/14-transition.md#L111-L113
[doc-inout-src]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/documentation/docs/03-template-syntax/15-in-and-out.md
[doc-animate-src]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/documentation/docs/03-template-syntax/16-animate.md
[src-transition]: https://github.com/sveltejs/svelte/tree/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/transition
[src-animate]: https://github.com/sveltejs/svelte/tree/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/animate
[src-motion]: https://github.com/sveltejs/svelte/tree/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/motion
[src-transition-file]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/transition/index.js#L67-L81
[src-crossfade]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/transition/index.js#L244-L311
[src-flip]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/animate/index.js#L4-L58
[src-tick-spring]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/motion/spring.js#L22-L40
[src-spring-update]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/motion/spring.js#L236-L285
[src-spring-set]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/motion/spring.js#L287-L322
[src-tween-set]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/motion/tweened.js#L230-L292
[src-tween-of]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/motion/tweened.js#L220-L228
[src-motion-index]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/motion/index.js#L6-L32
[rt-transitions]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js
[rt-animation]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js#L76-L180
[rt-fix]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js#L131-L172
[rt-transition]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js#L182-L299
[rt-options]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js#L220-L229
[rt-out]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js#L268-L290
[rt-local]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js#L301-L325
[rt-animate]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js#L328-L515
[rt-deferred]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js#L342-L366
[rt-sample]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js#L383-L450
[rt-delay]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/elements/transitions.js#L452-L489
[rt-each]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/blocks/each.js
[rt-reconcile]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/blocks/each.js#L548-L784
[rt-measure]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/blocks/each.js#L592-L605
[rt-apply]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/dom/blocks/each.js#L758-L784
[rt-pause]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/reactivity/effects.js#L617-L668
[rt-pause-children]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/reactivity/effects.js#L670-L711
[rt-resume]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/reactivity/effects.js#L713-L768
[rt-loop]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/loop.js#L9-L48
[rt-timing]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/internal/client/timing.js#L6-L16
[c-transition]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/compiler/phases/3-transform/client/visitors/TransitionDirective.js#L12-L41
[c-animate]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/compiler/phases/3-transform/client/visitors/AnimateDirective.js#L11-L36
[c-each]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/src/compiler/phases/3-transform/client/visitors/EachBlock.js#L95-L98
[v4-style-manager]: https://github.com/sveltejs/svelte/blob/d8b31333ec4afeab7dd178aedc7c187bfb971531/packages/svelte/src/runtime/internal/style_manager.js#L45-L66
[changelog-waapi]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/CHANGELOG.md#L4188-L4192
[t-helpers]: https://github.com/sveltejs/svelte/blob/f076077c6a07496a431e799a51dc361eda6562ab/packages/svelte/tests/animation-helpers.js#L1-L37
