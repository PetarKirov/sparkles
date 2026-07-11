# GPU vector rasterizers (Vello, Lyon, NanoVG, raylib/OpenGL, Skia)

The GPU side of [CPU-vector vs GPU-vector][cpugpu]: backends that turn vector
geometry into pixels on the graphics card. They buy real-time preview and raw
throughput, at the cost of exact reproducibility — [rasterization][raster], MSAA,
and blend order vary by driver, so a GPU backend is the _interactive_ path
reconciled against the CPU [oracle][cpugpu], not the video master. This page is
the axis-3 treatment; the CPU line is on
[`./cpu-vector.md`](./cpu-vector.md) and boolean/tessellation preprocessing on
[`./path-ops.md`](./path-ops.md).

> [!NOTE]
> **Two fill families divide this page.** A GPU cannot fill an arbitrary curved
> path directly. Either it (a) **triangulates** the region into a mesh first
> (Lyon; earcut — see [fill triangulation and winding][fill]), or it (b) renders
> the raw path into a **stencil** that counts the winding number and then covers
> the pixels (NanoVG, Skia/Ganesh, ManimGL). Vello is the outlier: it does
> neither, rasterizing paths in a **compute** pipeline. raylib does _none_ of
> this — it is a game framework, not a vector rasterizer, and is included to be
> honest about what it can and cannot do.

---

## Vello

The modern research line in GPU 2D: a compute-shader rasterizer, successor to
`piet-gpu`, built on `wgpu`.

| Field      | Value                                                     |
| ---------- | --------------------------------------------------------- |
| Language   | Rust                                                      |
| License    | `Apache-2.0` **OR** `MIT`                                 |
| Repository | [`linebender/vello`][vello-repo]                          |
| Latest     | `0.9.0` (alpha)                                           |
| Bindings   | **No C API** — Rust-native; would need a `cdylib` wrapper |

### Overview

Vello's self-description, verbatim ([linebender/vello][vello-repo]):

> "Vello is a 2D graphics rendering engine written in Rust, with a focus on GPU
> compute."

> "Vello was previously known as `piet-gpu`."

Its crate blurb is tighter still: "A GPU compute-centric 2D renderer." It targets
`wgpu` for portability across Vulkan/Metal/DX12/WebGPU (verbatim): "It can draw
large 2D scenes with interactive or near-interactive performance, using `wgpu`
for GPU access."

### How it works

Vello uploads an encoded scene (paths, clips, gradients) and runs the _entire_
rasterization as a sequence of compute passes — no triangulation, no stencil, no
intermediate textures for sorting. The README states the mechanism verbatim:

> "In traditional PostScript-style renderers, some steps of the render process
> like sorting and clipping either need to be handled in the CPU or done through
> the use of intermediary textures. Vello avoids this by using prefix-sum
> algorithms to parallelize work that usually needs to happen in sequence, so
> that work can be offloaded to the GPU with minimal use of temporary buffers."

The hard requirement follows directly (verbatim): "This means that Vello needs a
GPU with support for compute shaders to run."

### Axis-3 facts

- **Fill model — compute rasterization.** Neither [triangulation nor
  stencil][fill]; a sort-middle compute pipeline evaluates coverage per pixel.
- **Curve basis — cubic.** Vello's scene encoding is path/cubic-Bézier based
  (the `kurbo` curve library), flattened on-GPU; see [Bézier basis][basis].
- **Anti-aliasing — analytic**, computed in the compute pipeline (area coverage),
  not [MSAA][aa].
- **Colour / gamma.** Operates in a linear compute pipeline with explicit
  encode at the output — the [linear-then-encode model][color] done right, in
  contrast to Cairo's device-space compositing.
- **Readback.** Renders into a `wgpu` texture; a buffer copy + map yields pixels
  for [readback][capture] (an async GPU→CPU transfer, unlike Cairo's direct
  pointer).

> [!WARNING]
> **Alpha, and moving.** The README is explicit, verbatim: "Vello can currently
> be considered in an alpha state." Blur/filter effects, conflation artifacts,
> GPU memory allocation, and glyph caching are called out as open. Pin a commit
> and expect churn.

### D-binding path

The hardest of any backend here. Vello has **no C API** and no stable ABI — it
is consumed as a Rust crate. Binding it from D means writing a Rust `cdylib`
shim that re-exports a hand-rolled `extern "C"` surface _and_ threading a `wgpu`
device/queue/surface across the FFI boundary. It is the strategic bet for the web
(`wgpu` compiles to WebGPU), but not a near-term drop-in.

---

## Lyon

Not a renderer — a **tessellator**. It converts fills and strokes into triangle
meshes you then draw with your own GPU pipeline.

| Field      | Value                                                      |
| ---------- | ---------------------------------------------------------- |
| Language   | Rust                                                       |
| License    | `MIT` **OR** `Apache-2.0`                                  |
| Repository | [`nical/lyon`][lyon-repo]                                  |
| Latest     | `1.0.19`                                                   |
| Bindings   | No C API — Rust-native (mesh output can cross an FFI seam) |

### Overview

Lyon states its own boundary plainly ([nical/lyon][lyon-repo], verbatim):

> "A path tessellation library written in rust for GPU-based 2D graphics
> rendering."

> "Lyon is _not_ an SVG renderer. For now lyon mainly provides primitives to
> tessellate complex path fills and strokes in a way that is convenient to use
> with GPU APIs such as gfx-rs, glium, OpenGL, D3D, etc."

Its crate description: "2D Graphics rendering on the GPU using tessellation."

### How it works

Lyon's `FillTessellator` runs a sweep-line over a path's edges and emits an
indexed triangle mesh (vertices + indices) obeying the [nonzero / even-odd
winding rule][fill]; `StrokeTessellator` does the same for stroked outlines. You
upload that mesh and draw it — Lyon never touches a framebuffer. It is one
concrete answer to the [fill-triangulation][fill] problem, the same role
`mapbox-earcut` plays inside Manim's OpenGL path (see
[`./path-ops.md`](./path-ops.md)).

### Axis-3 facts

- **Fill model — triangulation.** Produces triangles; the fill rule is a
  tessellator option. Curves are [flattened][decast] to a polyline within a
  tolerance before the sweep-line runs.
- **Curve basis — cubic + quadratic** on input (`lyon_path`), flattened via
  adaptive subdivision; see [Bézier basis][basis].
- **Anti-aliasing — none built in.** Output is bare geometry; AA is the
  consumer's job (MSAA on the target, or an analytic edge shader) — see
  [anti-aliasing][aa].
- **Colour / gamma — out of scope.** Vertices carry whatever attributes you
  attach; [colour handling][color] lives in your shader.
- **Readback — n/a.** Lyon produces a mesh, not pixels; [readback][capture]
  belongs to the pipeline you draw the mesh with.

### D-binding path

Rust-only, no C API. But the FFI surface is small and data-shaped: a wrapper
could expose "tessellate this path → vertex/index arrays", and only that flat
buffer crosses into D. Lighter than Vello (no GPU context to marshal), but still
a Rust build dependency and a hand-written seam.

---

## NanoVG

A tiny C library that draws anti-aliased vector graphics on OpenGL with an
HTML5-canvas-shaped, immediate-mode API.

| Field      | Value                                                        |
| ---------- | ------------------------------------------------------------ |
| Language   | C                                                            |
| License    | `Zlib`                                                       |
| Repository | [`memononen/nanovg`][nanovg-repo]                            |
| Latest     | No tagged releases — header/source, pinned by commit         |
| Bindings   | Native C API → [ImportC][importc] (you supply the GL loader) |

### Overview

NanoVG's description, verbatim ([memononen/nanovg][nanovg-repo]):

> "Antialiased 2D vector drawing library on top of OpenGL for UI and
> visualizations."

Its API shape (verbatim): "The NanoVG API is modeled loosely on HTML5 canvas
API." And the licence (verbatim): "The library is licensed under zlib license."

### How it works

NanoVG is the textbook **stencil-and-cover** fill on OpenGL. `glnvg__fill`
(`src/nanovg_gl.h`) draws the path's triangle fan into the stencil buffer with
front/back winding, then covers only the pixels the winding rule marks inside —
verbatim from the source:

```c
// Draw shapes
glEnable(GL_STENCIL_TEST);
glnvg__stencilMask(gl, 0xff);
glnvg__stencilFunc(gl, GL_ALWAYS, 0, 0xff);
glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
...
glStencilOpSeparate(GL_FRONT, GL_KEEP, GL_KEEP, GL_INCR_WRAP);
glStencilOpSeparate(GL_BACK, GL_KEEP, GL_KEEP, GL_DECR_WRAP);
...
// Draw fill
glnvg__stencilFunc(gl, GL_NOTEQUAL, 0x0, 0xff);
```

The `INCR_WRAP`/`DECR_WRAP` on front/back faces _is_ the [winding number][fill]
accumulated in the stencil; the final `GL_NOTEQUAL` cover pass paints the inside.

### Axis-3 facts

- **Fill model — stencil-and-cover** (winding), as above — no CPU triangulation
  of the region, robust to self-intersection. See [fill & winding][fill].
- **Curve basis — cubic.** `nvgBezierTo` appends a cubic; NanoVG [flattens][decast]
  it to a polyline (`tessellate` step) before stenciling. See [basis][basis].
- **Anti-aliasing — fringe geometry.** With `NVG_ANTIALIAS`, an extra
  anti-aliased edge strip ("fringe") is drawn with a coverage-carrying alpha —
  an [analytic-ish AA][aa] without MSAA (`NVG_STENCIL_STROKES` improves stroke
  quality).
- **Colour / gamma — straight RGBA in shader**; premultiplied blend on the GL
  target — the [device-space compositing caveat][color] applies.
- **Readback.** Via the enclosing GL FBO (`glReadPixels`), not a NanoVG call —
  the [readback][capture] belongs to your GL context.

### D-binding path

Plain C, so [ImportC][importc] over `nanovg.h` + `nanovg_gl.h` binds it directly.
The friction is upstream: NanoVG needs a live OpenGL context and a function
loader that _you_ provide — the same OpenGL 3.3 context [raylib](#raylib-opengl)
or a bespoke GL init supplies.

---

## raylib (OpenGL)

Already wired into this repo — `apps/terminal` depends on `raylib-d`
(`~>6.0.1`) — and the honest odd one out: raylib is a **game framework over
OpenGL**, not a vector rasterizer.

| Field      | Value                                                       |
| ---------- | ----------------------------------------------------------- |
| Language   | C (OpenGL under an abstraction layer)                       |
| License    | `zlib/libpng`                                               |
| Repository | [`raysan5/raylib`][raylib-repo] ([raylib.com][raylib-site]) |
| Latest     | `6.0` (2026-04-23); this repo pins `raylib-d ~>6.0.1`       |
| Bindings   | Already bound via [`raylib-d`][raylib-d]; also ImportC-able |

### Overview

raylib's own one-liner, verbatim ([raysan5/raylib][raylib-repo]): "A simple and
easy-to-use library to enjoy videogames programming." It is OpenGL-backed
(verbatim): "Hardware accelerated with OpenGL: 1.1, 2.1, 3.3, 4.3, ES 2.0, ES
3.0". Licence, verbatim: "raylib is licensed under an unmodified zlib/libpng
license, which is an OSI-certified, BSD-like license that allows static linking
with closed source software."

### How it works — and what it is not

raylib draws with **immediate-mode quads and triangles** batched to the GPU.
This repo's `apps/terminal` is the live example: its frame loop is
`BeginDrawing()` → `DrawRectangle(...)` for each cell background →
`DrawTextEx(...)` for glyphs (a font-atlas blit) → `EndDrawing()`. There is no
path object, no fill rule, no analytic vector coverage — you assemble geometry
from primitives yourself. raylib _does_ ship cubic-spline _stroke_ helpers, e.g.
`DrawSplineBezierCubic`, documented (verbatim from `raylib.h`):

> `// Draw spline: Cubic Bezier, minimum 4 points (2 control points): [p1, c2, c3, p4, c5, c6...]`

but these flatten a curve to a **thick polyline** — they do not _fill_ a curved
region. To render a filled `VMobject` you would flatten and triangulate the
outline yourself (Lyon/earcut, [`./path-ops.md`](./path-ops.md)) and hand raylib
the triangles.

### Axis-3 facts

- **Fill model — you supply it.** No winding/stencil fill of arbitrary paths;
  raylib fills the _triangles you give it_. The [triangulation][fill] is your job.
- **Curve basis — n/a for fills** (cubic only for stroke splines); flatten to
  lines yourself. See [flattening][decast].
- **Anti-aliasing — MSAA.** `FLAG_MSAA_4X_HINT` on the context; no analytic
  vector AA. See [anti-aliasing][aa].
- **Colour / gamma — 8-bit sRGB `Color`**, composited in device space on the GL
  target — the [gamma caveat][color] applies.
- **Readback — first-class.** `TakeScreenshot(const char *fileName)` — "Takes a
  screenshot of current screen (filename extension defines format)" — and, for
  offscreen render, `LoadRenderTexture(int width, int height)` → a
  `RenderTexture2D` (an FBO) drawn into between `BeginTextureMode`/`EndTextureMode`,
  then read back. This is the [frame-capture & readback][capture] path the
  [`frame-capture.d`][ex-capture] probe stands in for.

### D-binding path

The _easiest_ to reach from D — it is **already** a dependency (`raylib-d`), a
maintained binding, and this repo builds and links it via Nix (`pkgs.raylib`).
The cost is conceptual, not integration: raylib gives you a window, a GL context,
input, text, and readback for free, but the actual vector _rasterizer_ is
something you build on top of it (or bind alongside — NanoVG shares the same GL
context cleanly).

---

## Skia

The industrial reference: one 2D API over both a CPU raster backend and GPU
backends (**Ganesh** and **Graphite**), shipping in Chrome, Android, and Flutter.

| Field      | Value                                                          |
| ---------- | -------------------------------------------------------------- |
| Language   | C++ (no stable public C ABI)                                   |
| License    | `BSD-3-Clause`                                                 |
| Repository | [`google/skia`][skia-repo] ([skia.org][skia-site])             |
| Latest     | Rolling (milestone/`chrome/*` branches; no SemVer package)     |
| Bindings   | C++ → needs an `extern "C"` wrapper (or a third-party binding) |

### Overview

Skia's descriptions, verbatim: "Skia is an open source 2D graphics library which
provides common APIs that work across a variety of hardware and software
platforms" ([skia.org][skia-site]); "Skia is a complete 2D graphic library for
drawing Text, Geometries, and Images" ([google/skia][skia-repo], which also
states the "`BSD-3-Clause` license"). Its reach, verbatim: "It serves as the
graphics engine for Google Chrome and ChromeOS, Android, Flutter, and many other
products."

### How it works — three backends, one canvas

An `SkCanvas` records drawing commands; the _backend_ decides where they land.
The CPU **raster** backend, verbatim ([SkCanvas Creation][skia-canvas]): "The
raster backend draws to a block of memory. This memory can be managed by Skia or
by the client." — a Cairo-class deterministic software rasterizer, so Skia can be
_its own_ CPU [oracle][cpugpu]. The GPU **Ganesh** backend, verbatim: "GPU
Surfaces must have a `GrContext` object which manages the GPU context, and related
caches for textures and fonts" and "GrContexts are matched one to one with OpenGL
contexts or Vulkan devices." **Graphite** is the newer GPU backend; the two live
side by side in Skia's [`skgpu` namespace][skia-skgpu] as `skgpu::ganesh` and
`skgpu::graphite`, which "includes numerous public types that are used by all of
our gpu backends".

### Axis-3 facts

- **Fill model — winding/even-odd**, and (on GPU) stencil-and-cover plus analytic
  coverage; `SkPath` sets the [fill type][fill]. Robust boolean preprocessing is
  available in-tree via `SkPathOps` (see [`./path-ops.md`](./path-ops.md)).
- **Curve basis — lines, quadratics, conics, cubics.** `SkPath` is the richest
  here: `quadTo` "Adds quad from last point towards (x1, y1), to (x2, y2)",
  `conicTo` "Adds conic from last point towards (x1, y1), to (x2, y2), weighted
  by w" (a rational quadratic — exact circles/arcs), and `cubicTo` "Adds cubic
  from last point towards (x1, y1), then towards (x2, y2), ending at (x3, y3)"
  ([SkPath API][skia-skpath], verbatim). See [Bézier basis][basis].
- **Anti-aliasing — analytic** (per-primitive `SkPaint::setAntiAlias`), coverage
  on CPU and shader-analytic on GPU; see [anti-aliasing][aa].
- **Colour / gamma — colour-managed.** `SkColorSpace` carries an explicit
  transfer function, so Skia can composite in linear light and encode at the
  boundary — the [colour/gamma model][color] done explicitly rather than in
  device bytes.
- **Readback.** `SkImage::readPixels` / `SkSurface::readPixels` copies out an
  RGBA buffer — the [readback][capture] step, uniform across backends.

### D-binding path

The costliest ABI. Skia is C++ with **no stable public C API**; a D consumer must
either write and maintain an `extern "C"` wrapper over the C++ surface (the
approach Flutter's engine and the C `skia4delphi`/`CanvasKit` shims take) or
depend on a third-party C wrapper. Powerful and battle-tested, but the heaviest
integration in this survey.

<!-- References -->

[raster]: ../concepts.md#rasterization
[cpugpu]: ../concepts.md#cpu-vector-vs-gpu-vector-rendering
[aa]: ../concepts.md#anti-aliasing
[color]: ../concepts.md#color-model-and-gamma
[fill]: ../concepts.md#fill-triangulation-and-winding
[basis]: ../concepts.md#bezier-basis-quadratic-vs-cubic
[decast]: ../concepts.md#de-casteljau-evaluation
[capture]: ../concepts.md#frame-capture-and-readback
[ex-capture]: ../examples/frame-capture.d
[vello-repo]: https://github.com/linebender/vello
[lyon-repo]: https://github.com/nical/lyon
[nanovg-repo]: https://github.com/memononen/nanovg
[raylib-repo]: https://github.com/raysan5/raylib
[raylib-site]: https://www.raylib.com/
[raylib-d]: https://github.com/schveiguy/raylib-d
[skia-repo]: https://github.com/google/skia
[skia-site]: https://skia.org/
[skia-canvas]: https://skia.org/docs/user/api/skcanvas_creation/
[skia-skgpu]: https://api.skia.org/namespaceskgpu.html
[skia-skpath]: https://api.skia.org/classSkPath.html
[importc]: https://dlang.org/spec/importc.html
