# Rendering Backends (2D vector rasterizers)

The 2D vector rasterizers a native/web animation engine could bind to turn
[VMobject][fill] geometry into pixels — the highest-weight building-block cluster
for a **hybrid** target (native video _and_ web/wasm preview).

**Last reviewed:** July 11, 2026

These are **building blocks**, not engines. Together they answer the survey's
analysis-spine **axis 3** (rendering backend & [rasterization][raster]) in full —
[CPU-vector vs GPU-vector][cpugpu], [fill rule & triangulation][fill],
[anti-aliasing][aa], [colour & gamma][color], [Bézier basis][basis] — and they
touch **axis 5** (output) at the [frame-capture & readback][capture] seam where a
rendered buffer becomes an encoder's input. What every one of them _deliberately
lacks_ is a scene graph, a timeline, and a typesetting model. That absence is the
point: a renderer fills, strokes, clips, and hands back a pixel buffer, and
nothing more — so an animation engine is precisely the thing that supplies the
[object model][fill], the [timing][decast], and the text pipeline _around_ one of
these backends. Picking a backend does not pick an architecture; it picks the
pixel-production primitive the architecture calls down into, once per frame.

The cluster splits three ways: CPU rasterizers on
[`./cpu-vector.md`](./cpu-vector.md), GPU rasterizers on
[`./gpu-vector.md`](./gpu-vector.md), and the geometry-conditioning stage
(boolean ops, flattening, tessellation) that feeds the triangle-based GPU path on
[`./path-ops.md`](./path-ops.md).

---

## Master catalog

| Backend                     | Language         | License                | CPU/GPU           | Fill model                         | Curve basis input           | Boolean ops           | Bindable from D via                        | Notes                                                               |
| --------------------------- | ---------------- | ---------------------- | ----------------- | ---------------------------------- | --------------------------- | --------------------- | ------------------------------------------ | ------------------------------------------------------------------- |
| [Cairo][s-cairo]            | C                | `LGPL-2.1` / `MPL-1.1` | CPU               | winding / even-odd rule            | cubic                       | no (fills overlaps)   | ImportC + `pkg-config cairo` (easy)        | Manim Community default; the deterministic **oracle**               |
| [Blend2D][s-b2d]            | C++ (C API)      | `Zlib`                 | CPU               | winding / even-odd rule            | cubic + quadratic           | no                    | ImportC over C API (easy)                  | JIT rasterizer; faster CPU substitute for Cairo; no tagged releases |
| [resvg][s-resvg]            | Rust             | `Apache-2.0` / `MIT`   | CPU               | SVG `fill-rule`                    | cubic (via SVG)             | no                    | ImportC over C API (SVG-scoped)            | Renders whole static-SVG docs, not paths; via `tiny-skia`           |
| [Vello][s-vello]            | Rust             | `Apache-2.0` / `MIT`   | GPU (compute)     | compute rasterization              | cubic                       | no                    | **no C API** — Rust `cdylib` wrapper       | `piet-gpu` successor; `wgpu`; the web/wasm bet; alpha               |
| [Lyon][s-lyon]              | Rust             | `MIT` / `Apache-2.0`   | GPU (tessellator) | triangulation (mesh out)           | cubic + quadratic           | no                    | no C API — Rust wrapper (mesh crosses FFI) | A _tessellator_, not a renderer — emits triangles you draw          |
| [NanoVG][s-nanovg]          | C                | `Zlib`                 | GPU (OpenGL)      | stencil-and-cover (winding)        | cubic                       | no                    | ImportC (you supply the GL context)        | Immediate-mode, HTML5-canvas-shaped; small                          |
| [raylib / OpenGL][s-raylib] | C (OpenGL)       | `zlib/libpng`          | GPU (OpenGL)      | _you_ tessellate (quads/triangles) | cubic (stroke splines only) | no                    | already bound (`raylib-d`); also ImportC   | Game framework, **not** a vector rasterizer; already in this repo   |
| [Skia][s-skia]              | C++              | `BSD-3-Clause`         | CPU + GPU         | winding + stencil/analytic         | line / quad / conic / cubic | **yes** (`SkPathOps`) | C++ → `extern "C"` wrapper (heaviest)      | Chrome/Android/Flutter engine; Ganesh + Graphite GPU backends       |
| [skia-pathops][s-pathops]   | Cython over Skia | `BSD-3-Clause`         | n/a (preprocess)  | boolean preprocessing              | line / quad / cubic         | **yes**               | no C API — Skia `extern "C"` wrapper       | The boolean-ops wheel Manim Community depends on                    |

Every backend is grounded on its page with a verbatim primary-source quote,
license, current version, and a D-binding assessment.

---

## Per-backend summaries

- **[Cairo][s-cairo]** — the C reference 2D library, "a 2D graphics library with
  support for multiple output devices"; an in-memory image surface, cubic
  `cairo_curve_to`, winding/even-odd fill, grayscale coverage AA, premultiplied
  ARGB32, and a raw-buffer `cairo_image_surface_get_data` readback. Deterministic
  and bit-reproducible — Manim Community's default and this survey's video oracle.
  Cleanest D binding of all: [ImportC][importc] + `pkg-config`.

- **[Blend2D][s-b2d]** — "a high performance 2D vector graphics engine" whose
  built-in JIT compiler generates optimized rasterizer pipelines at runtime; a
  faster CPU substitute for Cairo with the same winding-fill model and an equally
  clean C-API [ImportC][importc] path. Ships no versioned releases — pin a commit.

- **[resvg][s-resvg]** — "an SVG rendering library" for _static_ SVG documents,
  built on `usvg` + the pure-Rust `tiny-skia` rasterizer. Not a path API: you feed
  it SVG and get a bitmap, which fits the text/TeX-to-SVG pipeline but not the
  per-frame drawing loop. C API → ImportC.

- **[Vello][s-vello]** — "a GPU compute-centric 2D renderer", the `piet-gpu`
  successor, rasterizing entirely in compute shaders on `wgpu` (Vulkan / Metal /
  DX12 / **WebGPU**). The modern GPU-vector research line and the natural web/wasm
  path — but alpha, and with **no C API**, so the costliest to reach from D short
  of a Rust `cdylib` shim.

- **[Lyon][s-lyon]** — explicitly "_not_ an SVG renderer": a path _tessellator_
  that emits triangle meshes for "GPU APIs such as gfx-rs, glium, OpenGL, D3D".
  One concrete answer to [fill triangulation][fill]; Rust-only, but its output is
  a flat vertex/index buffer that crosses an FFI seam easily.

- **[NanoVG][s-nanovg]** — a small C "antialiased 2D vector drawing library on
  top of OpenGL", HTML5-canvas-shaped, using classic two-pass stencil-and-cover
  fill. C → [ImportC][importc]-friendly, but you must supply the OpenGL context.

- **[raylib / OpenGL][s-raylib]** — already a dependency of this repo's
  `apps/terminal` (`raylib-d ~>6.0.1`). A "simple and easy-to-use" game framework
  over OpenGL: immediate-mode quads/triangles, font-atlas text, `TakeScreenshot`
  and `RenderTexture2D` readback. Honestly **not** a vector rasterizer — you
  flatten and tessellate outlines yourself — but the lowest-friction way to get a
  window, a GL context, and readback.

- **[Skia][s-skia]** — "a complete 2D graphic library", the Chrome/Android/Flutter
  engine, with a CPU raster backend _and_ the Ganesh/Graphite GPU backends behind
  one `SkCanvas`. The richest path model (line/quad/conic/cubic) and in-tree
  boolean ops (`SkPathOps`). Also the heaviest integration: C++ with no stable
  public C ABI, so a D consumer needs an `extern "C"` wrapper.

- **[skia-pathops][s-pathops]** — Skia's boolean-ops module as a Python wheel
  ("boolean operations on paths (intersection, union, difference, xor)"), the
  dependency Manim Community uses to make self-intersecting outlines fillable.
  Covered with curve flattening and tessellation on [`./path-ops.md`](./path-ops.md).

---

### Recommendation for a hybrid D engine

A hybrid (native video + web/wasm) target does not choose _one_ backend — it
chooses a small set that share a geometry model and split the work by axis:

- **Cairo as the deterministic reference oracle.** For the video master, a CPU
  winding-fill rasterizer gives bit-reproducible frames a [content-hash
  cache][decast] can trust, with no driver variance. Cairo is the proven choice
  (Manim Community's default), it needs no boolean/tessellation preprocessing, and
  its pure-C API is the cleanest [ImportC][importc] binding in the cluster. This is
  the baseline every other backend is perceptually diffed against.

- **Blend2D as the faster CPU alternative.** Same winding-fill model and the same
  clean C-API ImportC path, but a JIT rasterizer that is materially faster —
  worth adopting where Cairo's CPU cost dominates, while keeping it
  interchangeable with the oracle.

- **raylib / OpenGL for real-time preview.** It is _already wired into this repo_,
  gives a window + GL context + input + readback for free, and this codebase
  already drives it in immediate mode. It is not a vector rasterizer, so pair it
  with a fill strategy: either tessellate (Lyon / earcut) or drop **NanoVG** into
  the same GL context for stencil-and-cover fills.

- **Vello (wgpu) + Canvas2D for the web path.** For web/wasm, `wgpu` compiles to
  WebGPU, making Vello the forward-looking GPU-vector engine — accepting its alpha
  status and the Rust `cdylib` binding cost. The pragmatic near-term web fallback
  is the browser's own **Canvas2D**, whose cubic/winding/even-odd model matches
  Cairo's closely enough to share one geometry layer.

The through-line: keep **one** cubic-Bézier geometry model (Cairo/Canvas2D/Skia
are all cubic-native), treat GPU backends as the interactive path reconciled
against the CPU oracle by a perceptual-diff tolerance, and reach for the
[path-ops preprocessing chain](./path-ops.md) only on the triangle-based GPU
routes that need it.

<!-- References -->

[raster]: ../concepts.md#rasterization
[cpugpu]: ../concepts.md#cpu-vector-vs-gpu-vector-rendering
[aa]: ../concepts.md#anti-aliasing
[color]: ../concepts.md#color-model-and-gamma
[fill]: ../concepts.md#fill-triangulation-and-winding
[basis]: ../concepts.md#bezier-basis-quadratic-vs-cubic
[decast]: ../concepts.md#de-casteljau-evaluation
[capture]: ../concepts.md#frame-capture-and-readback
[importc]: https://dlang.org/spec/importc.html
[s-cairo]: ./cpu-vector.md#cairo
[s-b2d]: ./cpu-vector.md#blend2d
[s-resvg]: ./cpu-vector.md#resvg
[s-vello]: ./gpu-vector.md#vello
[s-lyon]: ./gpu-vector.md#lyon
[s-nanovg]: ./gpu-vector.md#nanovg
[s-raylib]: ./gpu-vector.md#raylib-opengl
[s-skia]: ./gpu-vector.md#skia
[s-pathops]: ./path-ops.md#skia-pathops-boolean-path-operations
