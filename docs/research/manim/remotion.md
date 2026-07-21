# Remotion (React)

Remotion is a React library that makes videos **programmatically**: a video is a
component tree rendered by a headless browser and muxed into a file with FFmpeg,
where every frame is a _pure function of its frame number_.

| Field             | Value                                                                                                                                                                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript / JavaScript, authored as React (`.tsx`/`.jsx`)                                                                                                                                                                                  |
| License           | **Remotion License** — _source-available, not OSI open source_. Free for individuals, for-profits with **up to 3 employees**, non-profits, and evaluation; a paid **Company License** otherwise. See the license warning immediately below. |
| Repository        | [`remotion-dev/remotion`][repo] (public since 2020-06-23)                                                                                                                                                                                   |
| Documentation     | [`remotion.dev/docs`][docs]                                                                                                                                                                                                                 |
| Category          | Programmatic video · declarative · browser-rendered (React → DOM → screenshots → FFmpeg)                                                                                                                                                    |
| First release     | `v1.0.0`, 2021-02-06 ([releases][releases])                                                                                                                                                                                                 |
| Rendering surface | Headless **Chromium** (Blink) DOM — HTML / CSS / SVG / Canvas / WebGL — screenshotted per frame, muxed by **FFmpeg**                                                                                                                        |
| Timing model      | **Pure frame function** — the tree is a pure function of `useCurrentFrame()`; frame `N` renders identically anywhere ([execution models][execution-models])                                                                                 |

> [!WARNING]
> **Remotion is _not_ MIT — it is source-available with a commercial tier.** The
> code is public on GitHub, but the [`LICENSE.md`][license-md] grants only a
> conditional right to use it: _"Depending on the type of your legal entity, you
> are granted permission to use Remotion for your project."_ You may use it for
> free only if you are _"an individual, a for-profit organization with up to 3
> employees, a non-profit or not-for-profit organization, evaluating whether
> Remotion is a good fit, and are not yet using it in a commercial way"_; anyone
> outside that set _"is required to obtain a Company License"_. Redistribution is
> forbidden: _"It is not allowed to copy or modify Remotion code for the purpose
> of selling, renting, licensing, relicensing, or sublicensing your own derivate
> of Remotion."_ ([license-md], [license-doc]) This is a load-bearing caveat for
> any Sparkles design that borrows Remotion code or ships a fork — the
> permissively-licensed alternatives in this survey do not carry it.

---

## Overview

### What it solves

Remotion answers _"how do I make a video the way I make a web page?"_ Its
one-line positioning is _"Make videos programmatically with React"_ ([repo]).
Instead of a bespoke scene DSL (Manim) or a timeline GUI, a video is an ordinary
React app: layout in HTML/CSS, graphics in SVG/Canvas/WebGL, and animation
expressed as JavaScript that reads the current frame. That buys three things a
math-animation engine normally has to build from scratch — a **full styling and
layout engine** (the browser's), a **component/package ecosystem** (npm), and
**parametrization for free** (a composition is a component that takes props, so
one program renders thousands of variant videos). The render is server-side and
scalable: a Node/SSR API, a CLI, or `@remotion/lambda` for distributed cloud
rendering, plus an in-app `` `<Player>` `` for live preview.

### Design philosophy

The whole engine follows from one premise, stated in the fundamentals:

> _"A video is a function of images over time. If you change content every frame,
> you'll end up with an animation."_ — [The fundamentals][fundamentals]

Remotion realises that premise literally: it _"gives you a frame number and a
blank canvas, to which you can render anything you want using React"_
([render-frames][render-frames] context). The frame number is the only clock —
there is no imperative play-loop and no mutable scene object. Because frame `N`
is a pure function of `N`, frames can be rendered out of order, in parallel, on
many machines, and cached without a dirty-tracking protocol. This places Remotion
at the [_pure frame function_][execution-models] point of the survey's
execution-model taxonomy — the deliberate opposite of Manim's imperative
`self.play(...)` loop and of Motion Canvas's `yield`-driven play-head.

---

## How it works

A project registers one or more **compositions**. A `` `<Composition>` `` binds a
React component to video metadata — _"This is the component to use to register a
video to make it renderable"_ ([composition]) — with `id`, `component`,
`durationInFrames`, `fps`, `width`, and `height`:

```tsx
// src/Root.tsx — register a renderable video
import { Composition } from 'remotion';
import { MyVideo } from './MyVideo';

export const Root: React.FC = () => (
  <Composition
    id="MyVideo"
    component={MyVideo}
    durationInFrames={150}
    fps={30}
    width={1920}
    height={1080}
  />
);
```

The component itself is a **pure function of the frame**. `useCurrentFrame()`
returns the frame being rendered; `useVideoConfig()` exposes `fps`,
`durationInFrames`, `width`, `height`. Animation is _computed_ from the frame via
`interpolate()` (_"Allows you to map a range of values to another"_,
[interpolate]) and `spring()` (_"A physics-based animation primitive"_,
[spring]) — never accumulated in a mutable object:

```tsx
// MyVideo.tsx — the returned tree is a pure function of useCurrentFrame()
import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';

export const MyVideo: React.FC = () => {
  const frame = useCurrentFrame(); // e.g. 30
  const { fps } = useVideoConfig();
  const opacity = interpolate(frame, [0, 20], [0, 1], {
    extrapolateRight: 'clamp', // hold at 1 past frame 20
  });
  const scale = spring({
    frame,
    fps,
    config: { damping: 10, mass: 1, stiffness: 100 },
  });
  return (
    <AbsoluteFill style={{ opacity, transform: `scale(${scale})` }}>
      <h1>Hello</h1>
    </AbsoluteFill>
  );
};
```

Sequencing is a component, not a scheduler call. `` `<Sequence>` `` **time-shifts**
its children: _"All children of a `` `<Sequence>` `` that call `useCurrentFrame()`
will receive a value that is shifted by `from`"_ ([sequence]) — the timeline is
built by nesting, so composition of animations is composition of components:

```tsx
// A Sequence rebases the frame clock for its subtree
<Sequence from={30} durationInFrames={60}>
  <Title /> {/* useCurrentFrame() here reads 0 at the global frame 30 */}
</Sequence>
```

To turn a composition into a file, the renderer runs the app in a real browser
and screenshots it: `renderFrames()` _"Renders a series of images using Puppeteer
and computes information for mixing audio"_ ([render-frames]), and
`renderMedia()` drives Chromium plus FFmpeg end-to-end. The frame stream is then
encoded — _"Backed by FFmpeg, Remotion allows you to configure a variety of
encoding settings"_ ([encoding]).

---

## Object & scene model

The retained unit is not a bespoke `Mobject` ([scene graph][scene-graph]) — it is
the **React element tree**, reconciled into a **DOM subtree** inside a Chromium
page. This is the central finding: Remotion has _no vector/geometry model of its
own_. A shape is an SVG `` `<path>` ``, a `` `<div>` `` with CSS, a `` `<canvas>` `` you
draw into, or a WebGL/Three.js scene; all coexist because the render surface is a
browser. Geometry, layout, clipping, transforms, and stacking are delegated
wholesale to the web platform (CSS `transform`, SVG, Canvas2D, WebGL), so the
concerns the survey's geometry probes make concrete — the
[Bézier basis][bezier-eval] and [affine composition][affine-transform] — are
handled by Blink and the SVG/CSS engines, not by Remotion code.

On the [retained-vs-immediate][retained] axis Remotion is a hybrid worth naming
precisely: conceptually each frame is a _fresh pure tree_ (immediate-mode
authoring — you never mutate a persistent object), but React's reconciler keeps
the actual DOM **retained** and diffs the new tree against it between frames. The
author writes as if immediate; the engine executes as if retained. `AbsoluteFill`
(a `position: absolute` full-bleed `` `<div>` ``) is the default stacking primitive,
and `` `<Composition>` `` props (`width`/`height`) define the abstract canvas that
the browser viewport is sized to.

---

## Animation & timing model

This is Remotion's defining axis. Time is a single integer — the frame — and
every animated value is derived from it:

- **`useCurrentFrame()`** is the clock. There is no elapsed-time accumulator and
  no play-head object; the hook returns the frame index the renderer asked for.
- **`interpolate(input, inputRange, outputRange, options)`** is the core
  [lerp][lerp]: it linearly maps `frame` (or any driver) from an input range onto
  an output range, with `extrapolateLeft`/`extrapolateRight` of `'clamp'`
  (_"Return the closest value inside the range"_) or `'extend'`
  (_"Interpolate nonetheless"_) ([interpolate]). Non-linear motion comes from an
  `easing` option — the [rate-function / easing][easing] concept — supplied from
  `` `Easing` `` (cubic Béziers, `Easing.bezier`, etc.).
- **`spring({frame, fps, config})`** is a physics primitive parameterised by
  `damping` (default 10), `mass` (default 1), and `stiffness` (default 100)
  ([spring]). Because it is evaluated from `frame`, the same physical curve is
  reproduced at any frame with no integration state — the easing math the
  catalog's [`rate-functions.d`][rate-functions] probe tabulates for Manim has its
  Remotion analogue here, computed the same declarative way.
- **`` `<Sequence>` ``** and its siblings (`` `<Series>` ``, `` `<Loop>` ``) are the
  [composition combinators][composition-concept]: they rebase and window the frame
  clock for a subtree (`from`, `durationInFrames`), so a timeline is assembled by
  _nesting components_ rather than by ordering imperative calls. This is the
  direct counterpart of Manim's `AnimationGroup`/`Succession`, expressed in JSX.

The contrast the survey cares about: Manim advances a scene through
`self.play(Animation(...))` and _renders as it steps_; Motion Canvas `yield`s
generators against a moving play-head; Remotion never "advances" anything — it
_samples_ `frame(N)`. See [execution models][execution-models].

---

## Rendering backend & rasterization

Remotion writes **no rasteriser**. [Rasterization][rasterization] — turning the
vector/DOM content into pixels — is done by **Chromium's Blink/Skia stack**
inside a headless browser instance the renderer launches (by default Remotion
_"will try to detect it automatically and download one if none is available"_ for
the browser executable, [render-media]). Each frame is produced by navigating the
page to that frame and taking a **screenshot**; `renderFrames()` does exactly this
"via Puppeteer" ([render-frames]).

That places Remotion firmly on the [GPU/CPU-in-browser][cpu-gpu] side rather than
the CPU-vector-oracle side: the pixels are whatever _this_ Chromium build,
`--gl` backend, and font stack produce. Remotion's answer to the resulting
reproducibility problem is not a bespoke deterministic rasteriser but
**pinning the browser** (a Remotion-managed Chromium/Chrome Headless Shell
download) so every render machine rasterises identically, and offering `` `gl` ``
options (`angle`, `swiftshader`, …) to force a software GL path when GPU drivers
would diverge. [Color and gamma][gamma] are likewise the browser's job: CSS
colors, compositing, and sRGB handling follow web semantics, so an author gets
correct blends only insofar as CSS/Canvas give them. Anti-aliasing is Blink's
(coverage AA for CSS/SVG, MSAA/analytic for WebGL) — not a Remotion setting.

---

## Typesetting & text

Text is **delegated to the browser**, which is the finding for this axis: there
is no LaTeX-to-SVG pipeline and no in-engine [glyph-outline extraction][glyph-outline].
Text is HTML/SVG text laid out and [shaped][shaping] by Chromium's HarfBuzz +
layout engine; fonts are ordinary web fonts, with `@remotion/fonts` and
`@remotion/google-fonts` to load and _wait for_ them before a frame is captured
(so a frame is never screenshotted with a fallback font mid-swap). Math and rich
typesetting are done the web way — KaTeX/MathJax rendering into the DOM, or SVG —
rather than through the `dvisvgm` route both Manim forks take. The practical
upshot: Remotion inherits the browser's world-class shaping and web-font
ecosystem for free, at the cost of depending on Chromium's text stack for
pixel-level reproducibility (hence the pinned-browser discipline above).

---

## Output & encoding

The output path is the survey's [frame-capture → readback][readback] →
[codec/mux][codec] pipeline, with the browser standing in for the rasteriser:

- **Readback** is a screenshot. Frames come out of Chromium as images —
  `imageFormat` is `'jpeg'` (default, fastest), `'png'` (for an alpha channel),
  or `'none'` for audio-only ([render-frames]). This is the exact "render →
  addressable RGBA buffer" step the catalog's [`frame-capture.d`][frame-capture]
  probe models in pure D.
- **Encoding/muxing is FFmpeg.** _"Backed by FFmpeg, Remotion allows you to
  configure a variety of encoding settings"_ and _"Remotion supports 6 video
  codecs: `h264` (default), `h265`, `vp8`, `vp9`, `av1` and `prores`"_
  ([encoding]), plus `gif` and audio-only (`mp3`/`wav`/`aac`). Transparency uses
  `png` frames with an alpha-capable codec (`vp8`/`vp9`/`prores`). The pixel-format
  conversion (RGBA → the codec's `yuv420p`) and container muxing (`.mp4`/`.webm`/
  `.mov`) are FFmpeg's, and `renderMedia()` exposes an escape hatch to _"modify
  the FFMPEG command that Remotion uses under the hood"_ ([render-media]).
- **Concurrency** at encode time is `concurrency` — _"how many render processes
  should be started in parallel … Default is half of the CPU threads available"_
  ([render-media]) — i.e. multiple browser tabs/processes screenshotting disjoint
  frame ranges, safe precisely because frames are independent.

---

## Interactivity, preview & authoring

Unlike a batch-only math engine, Remotion ships a first-class **authoring and
embedding** story — the strongest axis after timing:

- **Remotion Studio** is a browser-based editor (timeline, prop-editing, Fast
  Refresh). A `` `<Sequence name>` `` is _"a label for the sequence that appears in
  the Remotion Studio timeline"_ ([sequence]), and `` `<Composition schema>` ``
  accepts a Zod schema so props become a **visual editing** form ([composition]).
- **`` `<Player>` ``** embeds a composition live in any React app for in-page
  preview and interaction, with no server render: _"Using the Remotion Player you
  can embed Remotion videos in any React app and customize the video content at
  runtime"_ ([player]). It is the interactive counterpart of the batch renderer,
  sharing the same components.
- **Agentic/interactive authoring** is now a stated product direction — _"Make
  videos agentically"_ and _"Make videos interactively: Edit and animate using
  drag and drop"_ ([repo]).

Manim has no equivalent live-preview-in-your-app surface; this is a category
advantage of building on the browser.

---

## Extensibility & API surface

Extensibility is **the npm/React ecosystem**, not a plugin API. A composition is
a component, so any React library, CSS framework, Canvas/WebGL renderer, or data
source drops in. Remotion's own surface is a family of packages:

| Package                                                                                        | Role                                                                                                 |
| ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `remotion`                                                                                     | Core hooks/components: `useCurrentFrame`, `interpolate`, `spring`, `` `<Sequence>` ``                |
| `@remotion/player`                                                                             | The embeddable `` `<Player>` `` ([player])                                                           |
| `@remotion/renderer`                                                                           | SSR APIs: `bundle`, `selectComposition`, `renderMedia`, `renderFrames`, `renderStill`, `openBrowser` |
| `@remotion/lambda`                                                                             | Distributed cloud rendering ([lambda])                                                               |
| `@remotion/three`                                                                              | React-Three-Fiber / WebGL scenes                                                                     |
| `@remotion/skia`                                                                               | CanvasKit/Skia drawing                                                                               |
| `@remotion/shapes`, `@remotion/transitions`, `@remotion/media-utils`, `@remotion/google-fonts` | Shapes, scene transitions, audio analysis, fonts                                                     |

Parametrization is a core primitive: `defaultProps` (JSON-serialisable), a Zod
`schema` for validation and visual editing, and `calculateMetadata` to derive
`durationInFrames`/dimensions from props at render time ([composition]) — so one
program is a _template_ over data, the basis of "render millions of videos"
([repo]).

---

## Determinism, caching & performance

Determinism is **structural, by construction** — the axis Remotion arguably does
best. Because frame `N` is a pure function of `N`, [deterministic frame
sampling][determinism] is not a property the engine must engineer (seeded RNG +
stable rasteriser, as a CPU-oracle engine does); it is the _premise_. The one leak
is genuine nondeterminism from JavaScript, and Remotion closes it explicitly:
`Math.random()` is rejected because _"the random values will be different on every
instance"_ when Remotion _"spins up multiple webpage instances to render frames in
parallel"_; the fix is a seeded `random()` — _"Pass in a seed … and as long as
the seed is the same, the return value will be the same"_ so _"the random values
will be the same on all threads"_ ([randomness]). The remaining nondeterminism
(browser build, GL driver, font substitution) is handled by pinning, as covered
under the rendering axis above.

On **caching**, the survey's [content-hash caching][content-hash] concern applies
_differently_ than for Manim, and that difference is the finding. Manim hashes each
`play()` call and reuses a **partial movie file** because there _is_ a discrete,
mutable unit of work to key on. Remotion has **no such per-unit render cache**:
there is no `play()` boundary and no mutable state, so the correctness that a
content hash buys Manim is instead _free_ — any frame or frame-range can be
recomputed or skipped independently. Remotion's caching is therefore at the
**bundler** layer (webpack/esbuild build caching + Fast Refresh in Studio) and the
**asset** layer, not a render-output content hash. Performance scaling is
horizontal: split the frame range across processes (`concurrency`) or across many
Lambda functions — _"A lot of Lambda functions are created in parallel which each
render a small part of the video"_ ([lambda]) — again valid only because frames
are independent. The deterministic checksum idea the [`frame-capture.d`][frame-capture]
probe illustrates is exactly what makes such distributed splitting safe.

---

## Strengths

- **Deterministic by construction.** Frame `N` is a pure function of `N`, so
  parallel/distributed rendering and out-of-order recompute are trivially correct;
  the only nondeterminism (`Math.random()`) is fenced off with a seeded `random()`.
- **The entire web platform for free.** HTML/CSS layout, SVG/Canvas/WebGL
  graphics, HarfBuzz text shaping, and the whole npm/React ecosystem — no bespoke
  vector, layout, or text engine to build or maintain.
- **Parametrization is first-class.** A composition is a component over props
  (with Zod schemas and `calculateMetadata`), so one program renders unbounded
  data-driven variants — the "render millions of videos" use case.
- **Live preview + embedding.** `` `<Player>` `` and Remotion Studio give an
  in-browser, interactive, Fast-Refresh authoring loop no batch math engine has.
- **Horizontal scale.** `concurrency` and `@remotion/lambda` split the
  independent frame stream across processes and cloud functions.

## Weaknesses

- **Not open source.** The [Remotion License][license-md] is source-available with a
  paid **Company License** for organisations over 3 employees — a real adoption
  and forking constraint, unlike the MIT/BSD tools elsewhere in this survey.
- **Chromium is the whole backend.** Rendering, rasterisation, text, and color
  are Blink's; reproducibility across machines depends on **pinning the browser**
  and forcing a software `gl` path, and the render process carries a full headless
  browser's weight (memory, startup, screenshot I/O per frame).
- **Not built for exact mathematical vector animation.** There is no `Transform`
  with point-count alignment, no de-Casteljau morph, no LaTeX pipeline — you get
  SVG/CSS and must build math-animation semantics yourself.
- **Screenshot-based capture** is heavier than a native RGBA readback: every frame
  is a browser paint + image encode, then an FFmpeg encode.
- **JavaScript/React runtime cost** and a Node + Chromium + FFmpeg toolchain to
  provision, versus a single-process native renderer.

---

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                          | Trade-off                                                                       |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Video = pure function of the frame                        | Frame `N` reproducible anywhere → free determinism, out-of-order & parallel render | Author must derive everything from `frame`; `Math.random()`/wall-clock banned   |
| Render surface is a real headless browser (Chromium)      | Inherit CSS/SVG/Canvas/WebGL, HarfBuzz, and the npm ecosystem for free             | No native rasteriser; reproducibility hinges on a pinned browser + `gl` backend |
| No bespoke geometry/vector model                          | Delegate all geometry/layout to the web platform                                   | No `Transform`/point-alignment/LaTeX math-animation primitives out of the box   |
| Timeline built by nesting `` `<Sequence>` `` components   | Composition of animations is composition of React components                       | Timing is code structure, not a mutable scheduler; some patterns feel indirect  |
| Capture frames as browser screenshots, encode with FFmpeg | Reuse Puppeteer + FFmpeg; supports many codecs and alpha                           | Per-frame paint + image encode is heavier than a native buffer readback         |
| Source-available license with a Company tier              | Fund sustained development while free for individuals/small teams                  | Not OSI open source; commercial adoption/forking needs a paid license           |
| Scale horizontally (`concurrency`, `@remotion/lambda`)    | Independent frames map cleanly onto processes and cloud functions                  | Needs a Node/Chromium/FFmpeg (or AWS) deployment; not a single binary           |

---

## Sources

- [The fundamentals][fundamentals] — video as a function of images over time;
  `useCurrentFrame`, `useVideoConfig`, `` `<Composition>` ``, frame indexing.
- [`interpolate()`][interpolate] · [`spring()`][spring] · [`<Sequence>`][sequence]
  · [`<Composition>`][composition] — the timing/composition API surface (quoted).
- [Using randomness][randomness] — the determinism contract and seeded `random()`.
- [`renderFrames()`][render-frames] ("_a series of images using Puppeteer_") ·
  [`renderMedia()`][render-media] (browser instance + FFmpeg command) ·
  [Encoding][encoding] (FFmpeg, the 6 codecs) — the render/encode pipeline.
- [`<Player>`][player] · [`@remotion/lambda`][lambda] — preview embedding and
  distributed cloud rendering (quoted).
- [`LICENSE.md`][license-md] · [License page][license-doc] — the source-available
  terms and Company License threshold (quoted in full above).
- [`remotion-dev/remotion`][repo] · [latest release][releases] — positioning line,
  license note, version `v4.0.488` (2026-07-11); first release `v1.0.0` (2021-02-06).

<!-- References -->

<!-- concepts.md anchors -->

[scene-graph]: ./concepts.md#mobject-and-the-scene-graph
[retained]: ./concepts.md#retained-vs-immediate-mode
[execution-models]: ./concepts.md#execution-models
[lerp]: ./concepts.md#interpolation-and-lerp
[easing]: ./concepts.md#rate-function-and-easing
[composition-concept]: ./concepts.md#animation-composition
[rasterization]: ./concepts.md#rasterization
[cpu-gpu]: ./concepts.md#cpu-vector-vs-gpu-vector-rendering
[gamma]: ./concepts.md#color-model-and-gamma
[glyph-outline]: ./concepts.md#glyph-outline-extraction
[shaping]: ./concepts.md#text-shaping
[readback]: ./concepts.md#frame-capture-and-readback
[codec]: ./concepts.md#codec-muxing-and-pixel-format
[determinism]: ./concepts.md#deterministic-frame-sampling
[content-hash]: ./concepts.md#content-hash-caching

<!-- Runnable probes (checked via the ignoreDeadLinks /\.d$/ rule) -->

[frame-capture]: ./examples/frame-capture.d
[rate-functions]: ./examples/rate-functions.d
[bezier-eval]: ./examples/bezier-eval.d
[affine-transform]: ./examples/affine-transform.d

<!-- External primary sources -->

[repo]: https://github.com/remotion-dev/remotion
[releases]: https://github.com/remotion-dev/remotion/releases/latest
[license-md]: https://github.com/remotion-dev/remotion/blob/ae327ffe05aa4ca47fe20e2a6e440180ceb17ae5/LICENSE.md
[license-doc]: https://www.remotion.dev/docs/license
[docs]: https://www.remotion.dev/docs
[fundamentals]: https://www.remotion.dev/docs/the-fundamentals
[interpolate]: https://www.remotion.dev/docs/interpolate
[spring]: https://www.remotion.dev/docs/spring
[sequence]: https://www.remotion.dev/docs/sequence
[composition]: https://www.remotion.dev/docs/composition
[player]: https://www.remotion.dev/docs/player
[lambda]: https://www.remotion.dev/docs/lambda
[render-media]: https://www.remotion.dev/docs/renderer/render-media
[render-frames]: https://www.remotion.dev/docs/renderer/render-frames
[encoding]: https://www.remotion.dev/docs/encoding
[randomness]: https://www.remotion.dev/docs/using-randomness
