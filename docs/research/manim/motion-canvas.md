# Motion Canvas (TypeScript)

A TypeScript library plus a real-time editor that programs 2D vector animations
as **generator functions** driven against a moving play-head, rendering through
the browser's HTML5 Canvas2D context and reacting to change through **signals**.

| Field             | Value                                                                                                                           |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript (runs in the browser; tooling on Node.js ≥ 16)                                                                       |
| License           | [MIT][license] (`Copyright (c) 2022 motion-canvas`)                                                                             |
| Repository        | [`motion-canvas/motion-canvas`][repo] (Lerna monorepo, ~18.8k stars)                                                            |
| Documentation     | [motioncanvas.io/docs][docs]                                                                                                    |
| Category          | Code-driven 2D vector motion-graphics engine (web / retained node tree)                                                         |
| First release     | `@motion-canvas/core` `v2.0.0` (Feb 4 2023); repo public since Aug 2022                                                         |
| Latest release    | `v3.17.2` (Dec 14 2024); `v3.18.0-alpha.0` in progress; repo last pushed Jul 2026                                               |
| Rendering surface | **HTML5 Canvas2D** (`CanvasRenderingContext2D`) per node; a shared **WebGL2** context for shader passes only                    |
| Timing model      | [Generator / play-head][execution-models]: scenes are `function*`, animations are generators consumed with `yield*`             |
| Editor            | A **Vite plugin** (`@motion-canvas/vite-plugin` + `@motion-canvas/ui`) serving a live-preview editor with a scrubbable timeline |

> [!NOTE]
> This page is grounded in the official docs ([motioncanvas.io/docs][docs]) and
> the source tree pinned at tag [`v3.17.2`][repo-tag]. Prose behaviour is quoted
> from the `packages/docs` MDX; runtime mechanics are quoted from `packages/core`
> and `packages/2d`. Motion Canvas renders **in a browser**, so no `ci`-compiled
> D probe reproduces its output; the catalog's dependency-free probes
> ([`rate-functions.d`][rate-functions], [`bezier-eval.d`][bezier-eval],
> [`affine-transform.d`][affine-transform], [`frame-capture.d`][frame-capture])
> reimplement the shared math (easing, Bézier bases, affine composition,
> readback checksum) that this engine also relies on.

---

## Overview

### What it solves

Motion Canvas targets **informative, voice-over-synchronised vector
animations** — the explainer-video niche — authored entirely in code but
previewed and fine-tuned in a live editor. It is deliberately **not** a general
video editor. The [introduction][intro-src] states its scope plainly:

> _"It's a specialized tool designed to create informative vector animations and
> synchronize them with voice-overs. It's not meant to be a replacement for
> traditional video editing software."_

Two problems drive its design. First, **expressing time in code** without the
imperative `self.play(...)` ceremony of Manim or the frame-indexed purity of
Remotion: Motion Canvas borrows JavaScript **generators** so an animation reads
top-to-bottom as a script, pausing at each `yield`. Second, **audio sync**: the
single hardest part of an explainer is landing a beat on a spoken cue, which the
editor solves with draggable [time events](#interactivity-preview--authoring)
rather than hard-coded frame counts.

### Design philosophy

The project describes itself as [two things][intro-src]:

> _"Motion Canvas consists of two main components:_
> _- A TypeScript library that uses generators to program animations._
> _- An editor providing a real-time preview of said animations."_

The library and editor are co-designed: the same generator that _is_ the
animation is also what the editor steps, scrubs, and instruments. The value
layer underneath is **reactive** — every node property is a
[signal](#animation--timing-model), so a change to one value lazily propagates
to everything derived from it, and a tween is just a signal being driven over
time. The node tree is **retained** (a DOM-like hierarchy the engine re-renders
each frame; see [retained vs immediate mode][retained]) but authored with a
**custom JSX runtime that is not React** — JSX tags map straight to `Node`
instances with no virtual DOM ([hierarchy][hierarchy-src]):

> _"Note that Motion Canvas does **not** use React itself, only JSX. There's no
> virtual DOM or reconciliation and the JSX tags are mapped directly to Node
> instances."_

---

## How it works

A **project** (`makeProject`) is an ordered list of **scenes**; each scene is a
generator produced by `makeScene2D(function* (view) { … })`. The `view` argument
is the root [`Node`][node-src] of a retained tree. You build the tree with JSX,
grab handles with `createRef`, then `yield*` animation generators against the
scene's play-head. The canonical [quickstart][docs] scene:

```tsx
import { makeScene2D, Circle } from '@motion-canvas/2d';
import { all, createRef } from '@motion-canvas/core';

export default makeScene2D(function* (view) {
  const myCircle = createRef<Circle>();
  view.add(
    <Circle ref={myCircle} x={-300} width={140} height={140} fill="#e13238" />,
  );

  yield* all(
    myCircle().position.x(300, 1).to(-300, 1), // animate x over 1s, then back
    myCircle().fill('#e6a700', 1).to('#e13238', 1),
  );
});
```

Three call shapes on a single property signal — `myCircle().fill()` reads,
`myCircle().fill('#e6a700')` sets, `myCircle().fill('#e6a700', 1)` returns a
**tween generator** — are the whole surface. `yield*` delegates the scene
generator to that tween until it completes; `.to(value, dur)` chains a second
tween onto the first; [`all(...)`](#animation--timing-model) merges generators so
they advance together. The editor watches the source via Vite and hot-reloads
the preview on save.

The frame the reader sees is produced by the [`Stage`][stage-src], which owns
three `HTMLCanvasElement` buffers and their 2D contexts; every `Node` draws
itself into that context (see [rendering](#rendering-backend--rasterization)).

---

## Object & scene model

Motion Canvas uses a **retained tree** of nodes rooted at the scene `view`,
explicitly likened to the DOM ([hierarchy][hierarchy]): _"They're organized in a
tree hierarchy, with the scene view at its root. This concept is similar to the
Document Object Model."_ This is the survey's [Mobject / scene-graph][mobject]
role, filled by a class hierarchy rather than one `Mobject` type:

| Class                                                                 | Role                                                                          |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| [`Node`][node-src]                                                    | Base: transform, opacity, parent/children, `render`, caching, querying        |
| `Layout`                                                              | A `Node` with `size`/`offset` and **Flexbox** participation                   |
| `Shape`                                                               | A `Layout` with `fill`/`stroke`/`lineWidth` — base of the drawable primitives |
| `Rect`, `Circle`                                                      | Filled/stroked primitives (Flexbox-aware)                                     |
| `Txt` / `TxtLeaf`                                                     | Text runs (Canvas text; see [typesetting](#typesetting--text))                |
| `Line`, `Path`, `Ray`, `Spline`, `Bezier`, `Curve`, `Polygon`, `Knot` | Vector-path geometry (piecewise Bézier; the [VMobject][vmobject] analogue)    |
| `Img`, `Video`, `SVG`, `Latex`, `Code`                                | Raster/vector/text-derived content nodes                                      |
| `Camera`, `Grid`, `Icon`                                              | Framing and helpers                                                           |

JSX is sugar over constructors — the two are documented as equivalent
([hierarchy][hierarchy-src]):

```tsx
// JSX form …                              // … equals the imperative form
view.add(
  <Layout>
    <Rect />
    <Txt>Hi</Txt>
  </Layout>,
);
view.add(new Layout({ children: [new Rect({}), new Txt({ text: 'Hi' })] }));
```

The tree is mutable at any time (`add`, `insert`, `remove`, `reparent`,
`moveTo`/`moveUp`/`moveToTop`, …) and **queryable**: `view.findAll(is(Txt))`
takes a predicate and walks descendants; `is(T)` builds an `instanceof`
predicate. Positioning is a **Cartesian** system with the origin at the scene
centre, x right, y **down** ([positioning][positioning]); each node exposes local
`position`/`scale`/`rotation`, world-space `absolutePosition`/`absoluteRotation`,
and the underlying [affine][affine-transform] matrices (`localToWorld`,
`worldToParent`, …) for mapping between spaces — the composition-order and
non-commutativity facts the [`affine-transform.d`][affine-transform] probe
verifies.

## Animation & timing model

This is Motion Canvas's defining axis. Time is a **generator / play-head**
([execution models][execution-models]): a scene is a `function*`, and `yield`
means "this frame is ready." The [flow][flow-src] page names it the core idea:

> _"This is the fundamental idea of Motion Canvas. `yield` means: 'The current
> frame is ready, display it on the screen and come back to me later.'"_

A bare `yield` emits one frame; `yield*` **delegates** to a sub-generator until
it finishes. An animation — a tween, a flow combinator, a hand-written
`function*` — is _just a generator_, so composition is ordinary generator
delegation. This contrasts sharply with the other engines in this survey:
Manim's imperative `self.play()` steps an external scene loop; Remotion makes a
frame a **pure function of its index**; Motion Canvas instead **suspends a
coroutine** at each frame boundary. (The catalog's [execution-models
glossary][execution-models] lays the three side by side.)

**Tweens** are the leaf animations ([tweening][tweening]): `tween(dur, t => …)`
calls the callback each frame with `t ∈ [0,1]`, or the property-signal shorthand
`node.prop(target, dur, timingFn?, interpolationFn?)` tweens from the current
value to `target`. Timing (easing) functions map `[0,1] → [0,1]`; the library
ships the standard [easings.net](https://easings.net/) set (`easeInOutCubic` is
the property-tween default) and any JS function qualifies — the reshaping the
[`rate-functions.d`][rate-functions] probe tabulates for the [rate-function
axis][rate-func]. Interpolation of non-scalars goes through a static `lerp` on
each complex type (`Color.lerp`, `Vector2.lerp`, `Vector2.arcLerp` for a curved
path) — the [lerp][interpolation] the survey defines. A separate `spring(desc,
from, to, settleTolerance?)` integrates a physical spring:

> _"The `spring` function allows us to interpolate between two values using
> Hooke's law."_ — [tweening][tweening]

**Flow generators** ([flow][flow]) are the [composition combinators][composition]
over the `[0,1]` timeline:

| Combinator           | Meaning                                                    |
| -------------------- | ---------------------------------------------------------- |
| `all(...gens)`       | run all in parallel; finishes with the **longest**         |
| `any(...gens)`       | run in parallel; finishes with the **shortest**            |
| `chain(...gens)`     | run sequentially, one after another                        |
| `sequence(delay, …)` | stagger starts by a fixed delay (the `lag_ratio` analogue) |
| `loop(n, i => gen)`  | repeat a generator                                         |
| `delay(time, gen)`   | wait, then run                                             |
| `waitFor(seconds)`   | advance the play-head by a fixed duration                  |
| `waitUntil('event')` | pause until a **named, editor-editable** time event        |

Because properties are **signals**, animation is reactive rather than
imperative bookkeeping. A signal is a value that may change over time
([signals][signals]):

> _"Signals represent a value that may change over time. They can be used to
> define dependencies between the state of the animation. This way, when a value
> changes, all other values that depend on it get automatically updated."_

`createSignal(0)` makes a scalar signal; passing a function makes a **computed**
signal that tracks its dependencies, recomputes **lazily**, and **caches** the
result:

```ts
const radius = createSignal(1);
const area = createSignal(() => Math.PI * radius() * radius());
area(); // computes: 3.14159…
radius(2);
area(); // recomputes once, lazily: 12.566…
```

Every node property _is_ a signal, so a scene can be made data-driven — animate
`radius` and everything derived from it follows, no per-frame updater needed.
This subsumes the imperative engines' [updater/ValueTracker][updaters]
machinery: where Manim adds an `add_updater(fn)` callback and wraps a scalar in a
`ValueTracker`, Motion Canvas gets the same reactivity for free from the signal
graph. Signals also carry a `DEFAULT` sentinel to reset (or tween back) to their
initial/inherited value, and node `save()`/`restore()` snapshot state onto a
stack.

## Rendering backend & rasterization

The rendering surface is the browser's **HTML5 Canvas2D**. Every node's
`render` method takes a `CanvasRenderingContext2D` ([`Node.ts`][node-render]):

```ts
public render(context: CanvasRenderingContext2D) { … }   // Node.ts:1649
protected draw(context: CanvasRenderingContext2D) { … }  // Node.ts:1690
```

The single 2D-context factory confirms the surface ([`getContext.ts`][getcontext-src]):

> _"`const context = canvas.getContext('2d', options);`"_

`render` saves the context, applies the node's `localToParent` matrix via
`context.transform(a,b,c,d,e,f)` (a `DOMMatrix`), draws itself or its cache, then
recurses into `drawChildren` — an ordinary [CPU-vector][cpu-gpu] retained
[rasterisation][rasterization] pass. The [`Stage`][stage-src] owns the output as
plain `HTMLCanvasElement` buffers (`finalBuffer`, plus `current`/`previous` for
scene transitions), and its context is created `willReadFrequently` because
frames are read back for export. Color space is a first-class knob —
`private colorSpace: CanvasColorSpace = 'srgb'` by default, with **DCI-P3**
wide-gamut selectable ([rendering][rendering]) — the browser's canvas handles the
[gamma/linear][color-gamma] compositing.

> [!NOTE]
> **WebGL is a secondary, opt-in path — not the base renderer.** A single
> [`SharedWebGLContext`][webgl-src] (a `WebGL2RenderingContext` borrowed by one
> owner at a time) exists **only** to run fragment-shader effects: when a node
> declares a `ShaderConfig`, `render` routes its cached canvas through
> `shaderCanvas(...)` before compositing back into the 2D context. The geometry,
> fills, strokes, text, and the frame you export are all Canvas2D. There is no
> GPU-vector [stencil-and-cover][cpu-gpu] path — Motion Canvas leans on the
> browser's own path rasteriser, so [anti-aliasing][anti-aliasing] is whatever
> the Canvas2D implementation provides.

Expensive subtrees are cached: `requiresCache()` (opacity groups, filters,
shaders, compositing) diverts a node to an offscreen `cachedCanvas()` that is
re-blitted with `drawImage` until invalidated — a node-level cache, distinct from
the frame-level [content-hash caching](#determinism-caching--performance)
question below.

## Typesetting & text

Two distinct paths, and neither matches Manim's LaTeX-to-`dvisvgm` pipeline:

- **Plain text** (`Txt` / `TxtLeaf`) is drawn **directly by the Canvas2D text
  engine**. `TxtLeaf.draw` sets `context.font`, `context.letterSpacing`, and
  measures with `context.measureText(...)`, then paints with `context.fillText`
  / `context.strokeText` ([`TxtLeaf.ts`][txtleaf-src]). Consequently **shaping is
  delegated to the browser** (HarfBuzz inside Chromium) rather than an in-process
  [HarfBuzz/Pango][text-shaping] stack, and there is **no [glyph-outline
  extraction][glyph-outline]** for ordinary text — glyphs are rasterised by the
  canvas, not converted to [VMobject][vmobject] paths. The trade-off is that
  plain `Txt` cannot be morphed at the contour level the way an outline-extracted
  glyph can.
- **Math** (`Latex`) compiles TeX to SVG **in-process with MathJax** — no TeX
  installation, no `dvisvgm`. `Latex.ts` imports `mathjax-full` and configures a
  `new SVG(...)` output jax ([`Latex.ts`][latex-src]):

  ```ts
  import { TeX } from 'mathjax-full/js/input/tex';
  import { SVG } from 'mathjax-full/js/output/svg'; // Latex.ts:14,17
  ```

  The emitted SVG is parsed into an `SVG` node whose paths **are** vector
  geometry, so an equation _can_ be tweened contour-to-contour — and a
  doubled-brace group syntax in the `tex` string lets you diff two formulas for a
  morph. This is the survey's
  [glyph-outline / LaTeX-to-SVG][glyph-outline] concept reached through a
  self-contained JS compiler instead of a system TeX + `dvisvgm` toolchain.
  `Code` (via a companion highlighter) covers animated source-code typesetting.

## Output & encoding

Rendering is driven from the editor's **Video Settings** tab: pick a frame
`Range`, `Resolution`, `Frame rate`, `Scale`, and color space, press `RENDER`,
and Motion Canvas "plays through the animation" writing frames to `/output`
([rendering][rendering]). The render loop seeks the playback to each integer
frame and reads the `Stage` back — an [export via **frame capture /
readback**][readback].

The **default, built-in exporter is an image sequence**, and readback is the
browser's own `toDataURL` ([`ImageExporter.ts`][imgexporter-src]):

```ts
data: canvas.toDataURL(this.fileType, this.quality),   // ImageExporter.ts:113
```

`fileType` is `image/png` (lossless), `image/jpeg`, or `image/webp` (browser-gated —
"may not work on Safari"), quality `0–100` ([image sequence][render-imgseq]).
The PNG frames drop into a video editor for muxing.

Direct video is a **separate, optional package**, `@motion-canvas/ffmpeg`, which
plugs into `vite.config.ts` and shells out to **FFmpeg** to mux the frame stream
([video (FFmpeg)][render-video]) — the [codec / muxing / pixel-format][codec-muxing]
step. Because the renderer lives in the browser but FFmpeg cannot, the exporter
runs FFmpeg on the **Node side** of the Vite dev server and streams frames to it;
"You do **not** need to install FFmpeg yourself. It will be installed
automatically." Still frames can be grabbed one at a time to `/output/still`.

> [!NOTE]
> There is no first-party in-process libav integration à la Manim community's
> PyAV: the split is deliberately **browser (render) → Node (mux)**. Reproducible
> encodes therefore hinge on pinning the bundled FFmpeg build.

## Interactivity, preview & authoring

The editor is the differentiator. It is a **Vite plugin**
(`@motion-canvas/vite-plugin`) mounting the `@motion-canvas/ui` app; `npm start`
serves it at `http://localhost:9000/`, and any source edit hot-reloads the
preview (the `?scene` import transform enables per-scene refresh). It provides a
**scrubbable timeline** with a play-head, a playback-range selector, live
inspection (node overlays via `drawOverlay`), and separate preview-vs-render
`Scale`/`Frame rate` so the preview can run cheap while the export runs at full
quality ([rendering][rendering]).

The signature authoring feature is **time events** for audio sync
([time events][time-events]). Instead of guessing a duration, you write a named
pause:

```ts
yield * animationOne();
yield * waitUntil('event'); // no hard-coded seconds
yield * animationTwo();
```

The named event then appears in the editor as a draggable pill; its timing is
edited **by hand in the UI**, not in code, and adjusting one event shifts all
later events (hold <kbd>SHIFT</kbd> to pin). `useDuration('event')` reads an
event's editor-set length back into the animation
(`circle().scale(2, useDuration('event'))`). A `player` package ships a custom
element to embed finished animations in any web page, and a **presentation mode**
turns a project into a slide deck.

## Extensibility & API surface

Extensibility is layered:

- **Custom components** — subclass `Node`, `Shape`, or `Layout` and implement
  `draw(context)`; the `@decorator`-based `@signal`/`@computed`/`@initial`
  property system (used throughout `packages/2d`) makes new animatable props
  first-class signals.
- **Renderer-agnostic core** — `@motion-canvas/core` holds all timing, signals,
  flow, and playback logic with **no 2D assumptions**; the README calls
  `@motion-canvas/2d` _"The default renderer for 2D motion graphics,"_ implying
  core can back alternative renderers.
- **Custom exporters** — implement the `Exporter` interface (`create`,
  `start`, `handleFrame`, `stop`); the FFmpeg exporter is exactly this, plugged
  in as a Vite plugin. Exporter choice is a project-config field.
- **Shaders** — a `ShaderConfig` attaches a GLSL fragment shader to any node,
  compiled through the [`SharedWebGLContext`][webgl-src].
- **Interpolation / easing** — any `(t) => number` is a valid timing function and
  any `(a, b, t) => T` a valid interpolation function; complex types expose a
  static `lerp` you can extend.
- **Vite ecosystem** — the whole toolchain is Vite plugins, so bundling,
  TypeScript, and asset handling come from the standard web build stack.

## Determinism, caching & performance

Frame output is **deterministic as a function of the frame index**: the renderer
reloads scenes and `seek`s the playback to an integer frame, then reads the
`Stage` — the same code yields the same frame sequence, satisfying the survey's
[deterministic-sampling][deterministic] prerequisite for reproducible export.

> [!WARNING]
> **Determinism is per-machine, not bit-identical across machines.** The pixels
> come from the browser's Canvas2D rasteriser (and, for shader nodes, its WebGL
> driver), so anti-aliasing and blending can differ across browsers, OSes, and
> GPUs — the same [CPU-vector-vs-GPU][cpu-gpu] reproducibility caveat the survey
> raises. Motion Canvas has no CPU "oracle" backend to fall back on; the Canvas2D
> output _is_ the render.

> [!NOTE]
> **No Manim-style frame/content-hash caching — an absence worth stating.**
> Manim community hashes each `play()` call and reuses a cached **partial movie
> file** ([content-hash caching][content-hash]); Motion Canvas has **no such
> layer** — it re-plays and re-renders the whole selected range on every export.
> Its caching is confined to the **node level**: `requiresCache()` diverts
> expensive subtrees (opacity groups, filters, shaders) to an offscreen
> `cachedCanvas()` that is invalidated through the signal graph and otherwise
> re-blitted. The iteration-speed win comes instead from the **live editor**
> (instant scrubbing, hot-reload) rather than from cross-run render caching.

The signal layer doubles as a **compute cache within a frame**: computed signals
memoise until a dependency changes, and the docs note the engine "uses signals
internally to cache things such as matrices" ([signals][signals]). Performance is
otherwise bounded by single-threaded Canvas2D in the browser, mitigated by
lower-resolution/frame-rate previews.

---

## Strengths

- **Generators make time read like a script.** `yield* anim()` sequences,
  `all/any/chain/loop` compose, and the whole animation is one linear function —
  no external play-loop, no frame-index arithmetic.
- **Signals give reactivity for free.** Every property is a lazy, cached,
  dependency-tracked signal, so data-driven scenes need no manual updaters or
  `ValueTracker` equivalents.
- **A genuinely good editor.** Live preview, timeline scrubbing, and
  **draggable, code-referenced time events** solve audio sync — the actual pain
  point of explainer videos — better than any code-only engine here.
- **Self-contained math typesetting.** `Latex` via MathJax needs no TeX install
  or `dvisvgm`, and emits animatable SVG paths.
- **Web-native and hackable.** TypeScript, JSX, Flexbox layout, the Vite plugin
  ecosystem, embeddable `player` element, MIT-licensed.
- **Flexbox layout** for structured diagrams — a real constraint-ish layout
  system most animation engines lack.

## Weaknesses

- **Browser-bound rendering.** Output is Canvas2D in a browser; there is no
  headless CPU oracle, so frames are **not bit-reproducible across machines**,
  and heavy scenes are single-threaded.
- **No cross-run render caching.** Unlike Manim's partial-movie-file cache, every
  export re-renders the whole range; fast iteration relies on the editor, not the
  batch renderer.
- **Plain text is not vector geometry.** `Txt` is rasterised by the canvas (no
  [glyph-outline extraction][glyph-outline]), so ordinary text cannot be morphed
  at the contour level; only the `Latex`/`SVG` path yields tweenable outlines.
- **Video export is a bolt-on.** FFmpeg muxing is a separate package running on
  the Node side; the built-in exporter only emits an image sequence.
- **Narrow by design.** Explicitly _"not meant to be a replacement for
  traditional video editing software"_ — 2D only, explainer-shaped.
- **Generators have a learning curve.** `yield` vs `yield*`, and "no `*` here"
  footguns in `for`-loops, trip newcomers (the [flow][flow] page spends real ink
  on it).

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                                    | Trade-off                                                                             |
| --------------------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Generators as the timing model                | Animation reads as a linear script; `yield*` composes without a play-loop    | Generator semantics (`yield` vs `yield*`) are a learning curve                        |
| Signals for every property                    | Lazy, cached, dependency-tracked reactivity; data-driven scenes for free     | A whole reactive graph to reason about; debugging propagation is subtler than setters |
| Custom JSX runtime, **not** React             | Familiar markup, direct `Node` instances, no virtual-DOM/reconciliation cost | Bespoke runtime to maintain; not a drop-in for the React ecosystem                    |
| HTML5 Canvas2D as the render surface          | Ubiquitous, simple retained 2D drawing; live browser preview                 | Not bit-reproducible across machines; single-threaded; no GPU-vector fast path        |
| WebGL only for shader effects                 | GPU where it pays (post-effects) without a full GPU renderer                 | Effects layer bolted onto a CPU compositor; extra context to manage                   |
| Editor-editable **time events** (`waitUntil`) | Solves voice-over sync without hard-coded durations                          | Timing now lives partly outside source control, in editor metadata                    |
| MathJax (in-process) for LaTeX                | No TeX/`dvisvgm` dependency; portable, animatable SVG output                 | Ships a large JS math engine; MathJax coverage, not full LaTeX                        |
| Image-sequence default, FFmpeg as a plugin    | Zero-dependency built-in export; muxing opt-in                               | Direct video needs an extra package and a Node-side FFmpeg process                    |
| Node-level cache, no frame-hash cache         | Reactive invalidation is simpler than hashing `play()` calls                 | Every export re-renders the full range; no Manim-style partial-movie reuse            |

---

## Sources

Primary sources (docs pinned to the live site; source pinned to tag
[`v3.17.2`][repo-tag]):

- [Introduction][docs] / [`intro.md`][intro-src] — the "two components,"
  vector-animation-plus-voice-over scope, and the "not a video editor" framing.
- [Animation flow][flow] / [`flow.mdx`][flow-src] — generators, `yield`/`yield*`,
  and the `all`/`any`/`chain`/`sequence`/`loop`/`delay`/`waitFor`/`waitUntil`
  combinators.
- [Signals][signals] — `createSignal`, computed signals, laziness, caching,
  dependency tracking, `DEFAULT`.
- [Tweening][tweening] — `tween`, property tweens, timing/interpolation functions,
  `Color.lerp`/`Vector2.arcLerp`, `spring` (Hooke's law), `save`/`restore`.
- [Scene hierarchy][hierarchy] — DOM-like retained tree, JSX-not-React,
  `add`/`insert`/`reparent`, `findAll(is(T))`.
- [Layouts][layouts] — Flexbox participation, layout roots, cardinal directions.
- [Positioning][positioning] — Cartesian space, world-space helpers, matrices.
- [Time events][time-events] — `waitUntil`, editor-draggable events, `useDuration`.
- [Rendering][rendering] · [Image sequence][render-imgseq] · [Video (FFmpeg)][render-video]
  — Video Settings, color space, exporters.
- [`Node.ts`][node-render] · [`getContext.ts`][getcontext-src] · [`Stage.ts`][stage-src]
  — Canvas2D `render(context)`, the `getContext('2d')` factory, the `Stage` buffers.
- [`SharedWebGLContext.ts`][webgl-src] — the WebGL2 shader-only context.
- [`ImageExporter.ts`][imgexporter-src] — `canvas.toDataURL` frame readback.
- [`Latex.ts`][latex-src] · [`TxtLeaf.ts`][txtleaf-src] — MathJax→SVG math;
  Canvas `fillText` plain text.
- [`README.md`][readme] — monorepo package list; "default renderer for 2D."
- [`LICENSE`][license] — MIT.

<!-- References -->

<!-- External: Motion Canvas docs (live) + source pinned to v3.17.2 -->

[repo]: https://github.com/motion-canvas/motion-canvas
[repo-tag]: https://github.com/motion-canvas/motion-canvas/tree/e735a995aa738ca682feb4204a39ee7db7b5d279
[readme]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/README.md
[license]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/LICENSE
[docs]: https://motioncanvas.io/docs/
[flow]: https://motioncanvas.io/docs/flow
[signals]: https://motioncanvas.io/docs/signals
[tweening]: https://motioncanvas.io/docs/tweening
[hierarchy]: https://motioncanvas.io/docs/hierarchy
[layouts]: https://motioncanvas.io/docs/layouts
[positioning]: https://motioncanvas.io/docs/positioning
[time-events]: https://motioncanvas.io/docs/time-events
[rendering]: https://motioncanvas.io/docs/rendering
[render-video]: https://motioncanvas.io/docs/rendering/video
[render-imgseq]: https://motioncanvas.io/docs/rendering/image-sequence
[intro-src]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/docs/docs/intro.md
[flow-src]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/docs/docs/getting-started/flow.mdx
[hierarchy-src]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/docs/docs/getting-started/hierarchy.mdx
[node-src]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/2d/src/lib/components/Node.ts
[node-render]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/2d/src/lib/components/Node.ts#L1649
[stage-src]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/core/src/app/Stage.ts
[getcontext-src]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/core/src/utils/getContext.ts#L5
[webgl-src]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/core/src/app/SharedWebGLContext.ts
[imgexporter-src]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/core/src/app/ImageExporter.ts#L113
[latex-src]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/2d/src/lib/components/Latex.ts#L14
[txtleaf-src]: https://github.com/motion-canvas/motion-canvas/blob/e735a995aa738ca682feb4204a39ee7db7b5d279/packages/2d/src/lib/components/TxtLeaf.ts#L115

<!-- Cross-links into the shared concepts glossary -->

[mobject]: ./concepts.md#mobject-and-the-scene-graph
[vmobject]: ./concepts.md#vmobject-and-vector-geometry
[interpolation]: ./concepts.md#interpolation-and-lerp
[rate-func]: ./concepts.md#rate-function-and-easing
[composition]: ./concepts.md#animation-composition
[execution-models]: ./concepts.md#execution-models
[retained]: ./concepts.md#retained-vs-immediate-mode
[updaters]: ./concepts.md#updaters-and-valuetracker
[rasterization]: ./concepts.md#rasterization
[cpu-gpu]: ./concepts.md#cpu-vector-vs-gpu-vector-rendering
[anti-aliasing]: ./concepts.md#anti-aliasing
[color-gamma]: ./concepts.md#color-model-and-gamma
[glyph-outline]: ./concepts.md#glyph-outline-extraction
[text-shaping]: ./concepts.md#text-shaping
[readback]: ./concepts.md#frame-capture-and-readback
[codec-muxing]: ./concepts.md#codec-muxing-and-pixel-format
[deterministic]: ./concepts.md#deterministic-frame-sampling
[content-hash]: ./concepts.md#content-hash-caching

<!-- Runnable probes (checked via the ignoreDeadLinks /\.d$/ rule) -->

[bezier-eval]: ./examples/bezier-eval.d
[rate-functions]: ./examples/rate-functions.d
[affine-transform]: ./examples/affine-transform.d
[frame-capture]: ./examples/frame-capture.d
