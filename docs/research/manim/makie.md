# Makie.jl (Julia)

GPU-first plotting for Julia built on a reactive [`Observable`][obs-docs] model
and three interchangeable backends (`CairoMakie`, `GLMakie`, `WGLMakie`) that
render the same `Figure` — the survey's cleanest exemplar of the
[reactive/observable execution model](./concepts.md#execution-models), where a
`record` loop animates by _mutating observables_, not by morphing objects.

| Field                 | Value                                                                                                                                  |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Julia                                                                                                                                  |
| License               | MIT — _"The MIT License (MIT)"_, `Copyright (c) 2018-2021: Simon Danisch, Julius Krumbiegel` ([`LICENSE.md`][license])                 |
| Repository            | [`MakieOrg/Makie.jl`][repo]                                                                                                            |
| Documentation         | [`docs.makie.org`][docs]                                                                                                               |
| Category              | Reactive/observable **plotting & data-visualization ecosystem** — _not_ a morph-animation engine                                       |
| First release         | 2018 (MIT copyright `2018-2021`); JOSS paper Sept 2021; current `v0.24.13` (Jul 7 2026); reviewed Jul 11 2026                          |
| Backends              | `CairoMakie` (CPU vector), `GLMakie` (OpenGL), `WGLMakie` (WebGL), `RPRMakie` (raytrace, experimental)                                 |
| Timing/reactive model | `Observable`s (via [`Observables.jl`][observables-pkg]) + a `record` frame loop — the [reactive model](./concepts.md#execution-models) |
| Video output          | `record` / `VideoStream` piping to [`FFMPEG_jll`][ffmpeg-jll] (`.mp4`, `.webm`, `.mkv`, `.gif`)                                        |

> [!NOTE]
> **Makie is a plotting framework, not a Manim-class morph engine.** It has no
> `Transform`-between-shapes primitive, no [rate-function/easing](./concepts.md#rate-function-and-easing)
> library, and no [point-count alignment](./concepts.md#mobject-and-the-scene-graph)
> — those axis-2 concerns are **N/A** and marked so below. It earns its place in
> the survey as the reference implementation of the _other_ animation paradigm:
> the [reactive/observable model](./concepts.md#execution-models), where the
> author changes data and the scene recomputes, and "animation" is that change
> captured frame by frame.

---

## Overview

### What it solves

Makie is a general-purpose scientific plotting stack for Julia — scatter, line,
surface, heatmap, mesh, volume, and 3D plots — with a single frontend package
(`Makie`) and swappable rendering backends. The README's positioning line:

> _"Makie is an interactive data visualization and plotting ecosystem for the
> Julia programming language, available on Windows, Linux and Mac."_ —
> [`README.md`][repo]

The problem it uniquely solves for _this_ survey is **interactive, data-driven
recomputation**: because every plottable value is an [`Observable`][obs-docs],
changing an input immediately updates the view, and the same mechanism that
drives a live GUI also drives an exported animation. Manim expresses time with an
[imperative play-loop](./concepts.md#execution-models) over a
[retained scene graph](./concepts.md#retained-vs-immediate-mode) of morphing
objects; Makie expresses it as a dataflow graph of observables that a `record`
loop advances.

### Design philosophy

The documentation homepage states the philosophy in one line:

> _"Makie is a data visualization ecosystem for the Julia programming language,
> with high performance and extensibility."_ — [`docs.makie.org`][docs]

Two commitments follow. First, **one frontend, many backends**: the `Makie`
package defines the plot objects, attributes, and layout; the backend packages
render them. The README:

> _"The backend packages GLMakie, WGLMakie, CairoMakie and RPRMakie add different
> functionalities: You can use Makie to interactively explore your data … export
> high-quality vector graphics or even raytrace with physically accurate
> lighting."_ — [`README.md`][repo]

`Makie` itself is never installed directly — _"There's no need to install
`Makie.jl` separately, it is re-exported by each backend package"_ ([docs][docs]).
Second, **reactive attributes**: plot attributes are observables, so
"interaction and animations … can be handled using [`Observables.jl`][observables-pkg]"
([observables docs][obs-docs]). This is the design bet that makes Makie the
survey's [reactive-model](./concepts.md#execution-models) exemplar.

---

## How it works

An `Observable` is the atom. [`Observables.jl`][observables-pkg] (re-exported by
Makie) gives a container whose value is read with empty-bracket `x[]`, written
with `x[] = v`, and — crucially — **notifies listeners on write**:

```julia
# Observable basics: read x[], write x[] = v, react with on()
x = Observable(0.0)
on(x) do val
    println("New value of x is $val")   # runs synchronously on every write
end
x[] = 3.34                              # prints; listeners fire in registration order
```

> _"An `Observable` is a container object whose stored value you can update
> interactively."_ — [observables docs][obs-docs]

Derived observables are built with `lift` (and its `@lift` macro sugar), which
re-evaluate whenever any input changes:

```julia
# Derived observables: y tracks f(x); @lift lifts every $-marked observable
y = lift(a -> a^2, x)     # whenever x changes, y[] == x[]^2
z = @lift($x .+ $y)       # $ marks each observable dependency
```

> _"Now, whenever `x` changes, the derived `Observable` `y` will immediately hold
> the value `f(x)`."_ — [observables docs][obs-docs]

Plotting builds a scene from these atoms. A `Figure` holds a top-level `Scene`
and a `GridLayout`; an `Axis` is placed at a grid cell; a mutating plot call
(`scatter!`, `lines!`, `mesh!`) adds a plot object whose arguments become
observables:

```julia
# Figure → Axis at grid cell → mutating plot call returns a plot object
fig = Figure()
ax  = Axis(fig[1, 1])
sc  = scatter!(ax, xs, ys)   # `!` mutates the axis; sc is the Plot object
```

Animation is then just _mutation over an iterator_, captured by `record`:

```julia
# Animation = advance an iterator, mutate observables, capture each frame
record(fig, "color_animation.mp4", hue_iterator; framerate = framerate) do hue
    plot.color[] = to_colormap(:viridis)[hue]   # mutate → scene recomputes → frame
end
```

> _"Animations work by making changes to data or plot attribute Observables and
> recording the changing figure frame by frame."_ — [animation docs][anim-docs]

The rest of this page walks the survey's [eight axes](./concepts.md) against this
machinery.

---

## Object & scene model

Makie is [retained-mode](./concepts.md#retained-vs-immediate-mode): you build a
persistent object tree once and mutate it, and the backend re-renders it each
frame. But its retained unit is not a Manim
[`Mobject`](./concepts.md#mobject-and-the-scene-graph) — there is no
piecewise-Bézier `VMobject`, no submobject "family", and no morph alignment.
Makie's tree is a **`Scene` graph of `Plot` objects**.

- **`Scene`** — _"A Scene is like a container for `Plot`s and other `Scene`s"_,
  and _"Scenes have `Plot`s and `Subscenes` associated with them"_
  ([scenes docs][scene-docs]). Scenes nest: `Scene(parentscene)` makes a
  subscene, and _"A subscene is no different than a normal Scene, except that it
  is linked to a 'parent' Scene."_ Each carries an
  [affine transform](./concepts.md#mobject-and-the-scene-graph) — _"Every Scene
  also has a transformation, made up of \_scale_, _translation_, and _rotation_"\_
  — plus a camera (`camera(scene)`). This is the survey's scene-graph node.
- **`Figure`** — the user-facing container. _"The `Figure` object contains a
  top-level `Scene` and a `GridLayout`, as well as a list of blocks that have
  been placed into it, like `Axis`, `Colorbar`, `Slider`, `Legend`, etc."_
  ([figure docs][fig-docs]). Blocks are placed by grid indexing:
  `ax = fig[1, 1] = Axis(fig)`.
- **`Plot` objects** — `scatter!`, `lines!`, `mesh!`, `heatmap!`, `surface!`,
  `volume!`. The bang forms add into an existing axis: _"You can plot into an
  existing axis with plotting functions that end with a `!`"_
  ([getting-started][getting-started], e.g. `scatter!(ax, seconds, measurements)`).
  A plot's positional arguments and keyword **attributes are all observables**,
  which is what makes the reactive update loop possible.

> [!NOTE]
> The `Scene` is now largely internal: _"Before the introduction of the `Figure`
> workflow, `Scene`s used to be the main container object … Now, scenes are
> mostly an implementation detail for many users."_ ([scenes docs][scene-docs]).
> Most authoring is against `Figure`/`Axis`, with the scene tree underneath.

---

## Animation & timing model

This is Makie's defining axis and the reason it is in the survey. Its
[execution model](./concepts.md#execution-models) is **reactive/observable**:
values are observables, the view recomputes when they change, and a `record`
loop advances them. The concepts page names Makie as this model's exemplar, and
contrasts it with the imperative engines' emulation via a
[`ValueTracker`](./concepts.md#updaters-and-valuetracker) — Makie's `Observable`
_is_ the primitive that a `ValueTracker` reimplements inside a play-loop engine.

The loop is the whole model. `record` takes a figure, a path, and an iterable,
and calls a user function per element (documented signatures:
`record(func, figurelike, path; …)` and `record(func, figurelike, path, iter; …)`,
[`recording.jl`][recording]). The body mutates observables; each iteration a
frame is captured. Manually, the equivalent is a loop that calls `recordframe!(io)`
after mutating the figure ([`recording.jl`][recording]).

What Makie **does not** provide — the Manim axis-2 machinery — is instructive by
its absence:

| Manim axis-2 concept                                                           | Makie                                                                                                                                                           |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Interpolation / lerp](./concepts.md#interpolation-and-lerp)                   | **N/A in core.** The author writes the tween (iterate a `LinRange`, set `obs[] = a + (b-a)*t`); no built-in point/color lerp.                                   |
| [Rate function / easing](./concepts.md#rate-function-and-easing)               | **N/A in core.** No `smooth`/`rush_into` library; ease by transforming the loop parameter yourself (companion `Animations.jl` exists but is not part of Makie). |
| [Transform + point-count alignment](./concepts.md#mobject-and-the-scene-graph) | **N/A.** No shape-to-shape morph; there is no Bézier path store to align.                                                                                       |
| [Updaters / `ValueTracker`](./concepts.md#updaters-and-valuetracker)           | **Native, inverted.** `lift`/`@lift` and `on` _are_ the reactive graph the imperative engines emulate.                                                          |

So Makie's "animation" is a dataflow re-computation, not a timeline of eased
morphs. The [`rate-functions.d`](./examples/rate-functions.d) probe's easing
tables describe what a Manim-class engine bakes in and what a Makie author must
supply by hand around the `record` loop.

---

## Rendering backend & rasterization

One `Figure`, several rasterizers — the axis where Makie's "one frontend, many
backends" design meets the survey's
[CPU-vector vs GPU-vector](./concepts.md#cpu-vector-vs-gpu-vector-rendering)
distinction. A backend is chosen by `using CairoMakie` + `CairoMakie.activate!()`
(or `GLMakie`, `WGLMakie`); the same plotting code then
[rasterizes](./concepts.md#rasterization) differently.

| Backend      | Engine / target                                                                                                                   | Character                                         |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `CairoMakie` | _"`Cairo.jl` based, non-interactive 2D (and some 3D) backend for publication-quality vector graphics"_ ([backends][backend-docs]) | **CPU vector**, deterministic, SVG/PDF/PNG        |
| `GLMakie`    | _"GPU-powered, interactive 2D and 3D plotting in standalone `GLFW.jl` windows"_ ([backends][backend-docs])                        | **OpenGL GPU**, interactive native window, bitmap |
| `WGLMakie`   | _"WebGL-based interactive 2D and 3D plotting that runs within browsers"_ ([backends][backend-docs])                               | **WebGL GPU**, browser/notebook interactive       |
| `RPRMakie`   | _"An experimental ray tracing backend"_ ([backends][backend-docs])                                                                | RadeonProRender, physically-based (experimental)  |

The CPU-vs-GPU trade-off is stated plainly for `CairoMakie`:

> _"You should use it if you want to achieve the highest-quality plots for
> publications, as the rendering process of the GL backends works via bitmaps and
> is geared more towards speed than pixel-perfection."_ —
> [CairoMakie docs][cairo-docs]

That is exactly the survey's resolution: the **CPU vector backend is the
reproducible oracle** (Cairo draws analytic vector paths to SVG/PDF), the **GPU
backends are the fast/interactive path** (bitmap rasterization, not
bit-identical across drivers). `CairoMakie` exposes resolution knobs
`px_per_unit` (raster density) and `pt_per_unit` (vector point scale)
([CairoMakie docs][cairo-docs]).

[Anti-aliasing](./concepts.md#anti-aliasing) and
[color model / gamma](./concepts.md#color-model-and-gamma) therefore differ by
backend: `CairoMakie` gets Cairo's analytic-coverage AA on vector edges, while
the GL backends multisample. The one text-specific rasterization fact Makie
documents — GL glyphs are signed-distance fields — is covered under
[Typesetting & text](#typesetting--text). The
[`frame-capture.d`](./examples/frame-capture.d) probe stands in for the CPU
coverage-AA + readback path a `CairoMakie` render performs.

---

## Typesetting & text

Makie loads fonts through FreeType and does its own glyph layout, rather than
routing text through a LaTeX install the way both Manim forks do.

- **Font loading** — _"Makie uses the [`FreeType.jl`][freetype] package for font
  support, therefore, most fonts that this package can load should be supported
  by Makie as well."_ ([fonts docs][fonts-docs]). Layout goes through
  [`FreeTypeAbstraction`][fta] (`glyph_index`, `layout_text`) building a
  `GlyphCollection` of positioned glyphs — the survey's
  [text-shaping](./concepts.md#text-shaping) step (decide _which_ glyph goes
  _where_) followed by [glyph-outline extraction](./concepts.md#glyph-outline-extraction).
- **GL backends use SDF glyphs** — the GL/WGL path rasterizes each glyph from a
  **signed distance field**: the fonts docs note this _"can only be used to
  render monochrome glyphs, but not arbitrary bitmaps"_ ([fonts docs][fonts-docs]),
  which is why emoji/color fonts do not render on those backends. `CairoMakie`,
  by contrast, draws the glyph outlines directly through Cairo.
- **Math via a native engine, not a TeX toolchain** — `LaTeXString`s are laid
  out by [`MathTeXEngine.jl`][mathtex], a pure-Julia math typesetter. This is the
  sharpest contrast with Manim's [LaTeX→`dvisvgm`→SVG](./concepts.md#glyph-outline-extraction)
  pipeline: Makie needs **no TeX distribution** on the system to typeset an
  equation, trading TeX's completeness for a self-contained, faster path.

---

## Output & encoding

Video output is a `record`/`VideoStream` pipeline to an FFmpeg subprocess — the
survey's [frame-capture-and-readback](./concepts.md#frame-capture-and-readback)
followed by [codec/muxing/pixel-format](./concepts.md#codec-muxing-and-pixel-format).

**Readback.** Each frame is captured by reading the backend's pixels: `record`
(and manual `recordframe!(io)`) calls `colorbuffer(screen)` to pull the rendered
image out of the backend into a buffer ([`recording.jl`][recording]) — the exact
"render → framebuffer readback" step the
[`frame-capture.d`](./examples/frame-capture.d) probe models.

**Encoding.** The buffer is written to an FFmpeg process. From
[`ffmpeg-util.jl`][ffmpeg]:

- The `VideoStream` holds `io::Base.PipeEndpoint`, `process::Base.Process`, a
  `buffer::Matrix{RGB{N0f8}}`, and a `VideoStreamOptions` (fields `format`,
  `framerate`, `compression`, `profile`, `pixel_format`, `loop`, …).
- Frames pipe to an `open(pipeline(...), "w")` writing to an FFmpeg process
  spawned via `FFMPEG_jll.ffmpeg()` — the encoder is [`FFMPEG_jll`][ffmpeg-jll],
  as the animation docs confirm: _"Video files are created with `FFMPEG_jll.jl`."_
  ([animation docs][anim-docs]).
- **Pixel format**: input is `rgb24`; `.mp4` output defaults to `yuv420p`
  (`yuv444p` under a `high444` profile). **Codec**: `.mp4` → `libx264`,
  `.webm` → `libvpx-vp9`. **Containers**: `"mkv"`, `"mp4"`, `"webm"`, `"gif"`.
  **Default framerate**: 24.

**Image export.** Still frames go through `save`: _"CairoMakie uses `Cairo.jl` to
draw vector graphics to SVG and PDF"_ ([CairoMakie docs][cairo-docs]), e.g.
`save("figure.pdf", fig, pdf_version="1.4")` or `save("plot.svg", fig)`; the GL
backends save bitmap PNG. Backend output type is selectable —
`CairoMakie.activate!(type = "svg")` vs `type = "png"`.

---

## Interactivity, preview & authoring

The same observable graph that animates also drives **live interaction** — the
axis where Makie's reactive model pays off twice. Because attributes are
observables and `on(observable)` registers a synchronous callback, a native
`GLMakie` window or a browser `WGLMakie` view recomputes in place as the user
drags, zooms, or moves a `Slider` block; the [figure][fig-docs] holds those
interactive blocks (`Slider`, `Button`, `Menu`) alongside the axes.

Authoring therefore has two modes off one code path:

- **Interactive preview** — `GLMakie` opens a real OpenGL window
  (_"interactive 2D and 3D plotting in standalone `GLFW.jl` windows"_,
  [backends][backend-docs]); `WGLMakie` embeds the same figure in a browser,
  notebook, or IDE. Events (mouse, keyboard, `events(scene)`) feed observables.
- **Deterministic export** — the _same_ figure and the _same_ observable
  mutations, driven by a `record` iterator instead of a human, produce a video or
  image via `CairoMakie` (for reproducible vector output) or a GL backend.

This is the practical realization of the survey's
[CPU-oracle / GPU-preview](./concepts.md#cpu-vector-vs-gpu-vector-rendering)
split: interact on the GPU, export the archival copy on the CPU vector backend,
from one script.

---

## Extensibility & API surface

The frontend `Makie` package is the API surface; backends re-export it, so user
code and third-party recipes are backend-agnostic. Extensibility is explicit in
the design philosophy quote (_"high performance and extensibility"_,
[docs][docs]) and rests on three seams:

- **`@recipe` / `convert_arguments`** — a plot type is defined once as a recipe
  (a function that emits other plots plus an attribute schema) and works on every
  backend; `convert_arguments` teaches Makie how to turn a user type into
  plottable primitives. This is how domain packages add first-class plots without
  touching a backend.
- **Attributes as observables** — every plot exposes a keyword attribute set
  (`color`, `markersize`, `linewidth`, `colormap`, …) that are observables;
  themes (`set_theme!`, `with_theme`) override defaults globally.
- **`ComputeGraph`** — the 0.24 attribute-processing layer. The observables docs:
  _"Makie 0.24 introduced the `ComputeGraph` for processing updates within plots.
  With that `Makie.update!(plot, attribute1 = new_value1, …)` was added, which can
  be used instead of updating Observables."_ ([observables docs][obs-docs]). It
  batches and incrementally propagates attribute updates through a plot.

The plot vocabulary itself is broad and 2D/3D: `scatter`, `lines`, `linesegments`,
`heatmap`, `image`, `surface`, `mesh`, `volume`, `contour`, `band`, `poly`, plus
`Axis`/`Axis3`/`LScene` and the block ecosystem (`Colorbar`, `Legend`, `Slider`).

---

## Determinism, caching & performance

Determinism is a per-backend property, and Makie has **no cross-run frame cache**
of the kind Manim relies on.

- **[Deterministic sampling](./concepts.md#deterministic-frame-sampling)** —
  `CairoMakie`'s analytic vector rasterization is the reproducible path (SVG/PDF
  are backend-stable; PNG is bit-stable for a fixed Cairo build). The GL backends
  are explicitly _not_ pixel-perfect — _"the rendering process of the GL backends
  works via bitmaps and is geared more towards speed than pixel-perfection"_
  ([CairoMakie docs][cairo-docs]) — so they vary with driver/MSAA, exactly the
  [CPU-vs-GPU](./concepts.md#cpu-vector-vs-gpu-vector-rendering) reproducibility
  gap. The [`frame-capture.d`](./examples/frame-capture.d) probe's FNV-1a checksum
  illustrates the determinism a Cairo render would give.
- **[Content-hash caching](./concepts.md#content-hash-caching)** — **N/A.** Makie
  does not hash `play()`-equivalent units and reuse partial movie files; there is
  no per-call render cache. Each `record` iteration re-renders the figure. This is
  a genuine finding: the caching that makes Manim's iterate-render loop fast has
  no analog here, because Makie's iteration granularity is a full frame, not a
  cacheable animation segment.
- **Incremental recompute (the reactive substitute)** — what Makie has instead is
  _intra-frame_ incrementalism: the observable graph (and the `ComputeGraph`) only
  re-runs the `lift`s downstream of a changed input, so mutating one attribute does
  not recompute the whole scene. That is a different lever from content-hash
  caching — dataflow minimality within a frame, not cross-run reuse across frames.
- **Performance** — the GL backends are GPU-accelerated for large scatter/line/mesh
  data and real-time interaction; the JOSS positioning is _"high performance"_
  ([docs][docs]). First-plot latency (Julia's "time-to-first-plot" compilation
  cost) is the well-known counterweight.

---

## Strengths

- **The reactive model, done natively.** `Observable` + `lift`/`@lift` + `on`
  make data-driven scenes and live interaction fall out of one primitive; this is
  the [reactive execution model](./concepts.md#execution-models) other engines
  emulate with a [`ValueTracker`](./concepts.md#updaters-and-valuetracker).
- **One figure, three backends.** The same code exports publication vector
  graphics (`CairoMakie`), drives a native interactive window (`GLMakie`), or runs
  in a browser (`WGLMakie`) — a clean CPU-oracle / GPU-preview split.
- **Deterministic vector export.** `CairoMakie` → SVG/PDF is a reproducible
  archival path independent of GPU drivers.
- **No LaTeX install for math.** [`MathTeXEngine.jl`][mathtex] typesets equations
  in-process; no TeX toolchain, unlike Manim.
- **Extensible via `@recipe`** — custom plot types are backend-agnostic and
  first-class.
- **Broad 2D/3D scientific vocabulary** with GPU acceleration for large data.

## Weaknesses

- **Not a morph-animation engine.** No shape-to-shape `Transform`, no
  [alignment](./concepts.md#mobject-and-the-scene-graph), no built-in
  [interpolation](./concepts.md#interpolation-and-lerp) or
  [easing](./concepts.md#rate-function-and-easing) — the author hand-codes tweens
  around the `record` loop.
- **No render cache.** No [content-hash](./concepts.md#content-hash-caching)
  partial-movie reuse; every frame re-renders.
- **GPU output is not reproducible.** GL backends are bitmap and driver-dependent;
  only `CairoMakie` is the deterministic oracle.
- **SDF glyphs are monochrome on GL** — no emoji/color fonts on `GLMakie`/`WGLMakie`
  ([fonts docs][fonts-docs]).
- **Time-to-first-plot latency** — Julia compilation cost on the first render.
- **`RPRMakie` is experimental** — the raytracing backend is not production-stable.

---

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                             | Trade-off                                                                   |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Attributes are `Observable`s; animation = mutate + `record` | One primitive powers interaction _and_ export; data-driven scenes fall out free       | No timeline/easing/morph layer — author supplies interpolation by hand      |
| One frontend (`Makie`), swappable backends                  | Same figure → vector, native GL, or browser; CPU-oracle + GPU-preview from one script | Backend feature/precision skew (SDF glyphs, bitmap AA) the author must know |
| `CairoMakie` = CPU vector reproducible; GL = fast bitmap    | Publication-quality SVG/PDF vs real-time interaction, each where it's best            | GL output not bit-identical; determinism only on the Cairo path             |
| Native `MathTeXEngine.jl` for math, not a LaTeX toolchain   | Self-contained, no TeX install, faster equation typesetting                           | Less complete than a full LaTeX distribution for exotic macros              |
| No per-frame content-hash cache                             | Reactive graph already minimizes intra-frame recompute via `lift` dependencies        | No cross-run reuse — every `record` frame re-renders (slower iterate loop)  |
| GL glyphs via signed distance fields                        | Cheap, scalable, sharp monochrome text on the GPU                                     | Cannot render color/emoji fonts on `GLMakie`/`WGLMakie`                     |
| `@recipe` + `convert_arguments` extensibility seam          | Third-party/domain plot types are backend-agnostic and first-class                    | Recipe authors work against Makie's attribute/`ComputeGraph` model          |

---

## Sources

- [`MakieOrg/Makie.jl`][repo] `README.md` — positioning (_"interactive data
  visualization and plotting ecosystem"_), backend roster, MIT badge.
- [`LICENSE.md`][license] — _"The MIT License (MIT)"_, `Copyright (c) 2018-2021:
Simon Danisch, Julius Krumbiegel`.
- [`docs.makie.org`][docs] — homepage philosophy (_"high performance and
  extensibility"_), _"re-exported by each backend package"_.
- [Observables explanation][obs-docs] — `Observable` container, `x[]` read/write,
  `on`, `lift`/`@lift`, the `ComputeGraph`/`Makie.update!` (0.24).
- [`Observables.jl`][observables-pkg] — the upstream reactive-value package Makie
  re-exports.
- [Animations explanation][anim-docs] — `record(fig, path, iter) do i … end`,
  _"Animations work by making changes to … Observables and recording the changing
  figure frame by frame"_, _"Video files are created with `FFMPEG_jll.jl`"_.
- [Backends explanation][backend-docs] — verbatim one-liners for `CairoMakie`,
  `GLMakie`, `WGLMakie`, `RPRMakie`.
- [CairoMakie explanation][cairo-docs] — SVG/PDF vector output, publication-quality
  vs GL-bitmap statement, `px_per_unit`/`pt_per_unit`, `save`/`activate!(type=…)`.
- [Scenes explanation][scene-docs] — `Scene` container/tree, `scale`/`translation`/
  `rotation` transform, subscenes, "implementation detail for many users".
- [Figure explanation][fig-docs] — `Figure` = top-level `Scene` + `GridLayout` +
  blocks; grid placement `fig[1,1] = Axis(fig)`.
- [Fonts explanation][fonts-docs] — `FreeType.jl` loading; GL glyphs are signed
  distance fields, _"can only be used to render monochrome glyphs"_.
- [Getting started][getting-started] — mutating `scatter!`/`lines!` into an axis.
- [`Makie/src/ffmpeg-util.jl`][ffmpeg] — `VideoStream`/`VideoStreamOptions`,
  `FFMPEG_jll.ffmpeg()` pipe, `rgb24`→`yuv420p`, `libx264`/`libvpx-vp9`,
  mp4/webm/mkv/gif, framerate 24.
- [`Makie/src/recording.jl`][recording] — `record`/`recordframe!` signatures,
  `colorbuffer(screen)` readback, `save(path, io)`.
- [JOSS 10.21105/joss.03349][joss] — Danisch & Krumbiegel, "Makie.jl: Flexible
  high-performance data visualization for Julia" (published Sept 1 2021).
- [`FreeTypeAbstraction.jl`][fta] · [`MathTeXEngine.jl`][mathtex] ·
  [`FFMPEG_jll`][ffmpeg-jll] — the font-layout, math-typesetting, and encoder
  dependencies referenced above.

<!-- References -->

[repo]: https://github.com/MakieOrg/Makie.jl
[license]: https://github.com/MakieOrg/Makie.jl/blob/f34d62d4fbe49ed9604e7571f22ae78f31cd7083/LICENSE.md
[docs]: https://docs.makie.org/stable/
[obs-docs]: https://docs.makie.org/stable/explanations/observables
[anim-docs]: https://docs.makie.org/stable/explanations/animation
[backend-docs]: https://docs.makie.org/stable/explanations/backends/backends
[cairo-docs]: https://docs.makie.org/stable/explanations/backends/cairomakie
[scene-docs]: https://docs.makie.org/stable/explanations/scenes
[fig-docs]: https://docs.makie.org/stable/explanations/figure
[fonts-docs]: https://docs.makie.org/stable/explanations/fonts
[getting-started]: https://docs.makie.org/stable/tutorials/getting-started
[ffmpeg]: https://github.com/MakieOrg/Makie.jl/blob/f34d62d4fbe49ed9604e7571f22ae78f31cd7083/Makie/src/ffmpeg-util.jl
[recording]: https://github.com/MakieOrg/Makie.jl/blob/f34d62d4fbe49ed9604e7571f22ae78f31cd7083/Makie/src/recording.jl
[observables-pkg]: https://github.com/JuliaGizmos/Observables.jl
[freetype]: https://github.com/JuliaGraphics/FreeType.jl
[fta]: https://github.com/JuliaGraphics/FreeTypeAbstraction.jl
[mathtex]: https://github.com/Kolaru/MathTeXEngine.jl
[ffmpeg-jll]: https://github.com/JuliaBinaryWrappers/FFMPEG_jll.jl
[joss]: https://joss.theoj.org/papers/10.21105/joss.03349
