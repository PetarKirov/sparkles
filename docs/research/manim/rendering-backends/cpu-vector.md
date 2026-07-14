# CPU vector rasterizers (Cairo, Blend2D, resvg)

The CPU backends that walk vector paths analytically into a coverage buffer in
main memory — [Cairo][cairo-site], [Blend2D][b2d-site], and [resvg][resvg-repo].
They are the deterministic, bit-reproducible half of [CPU-vector vs
GPU-vector][cpugpu]: no driver, no MSAA lottery, one code path that produces the
same pixels on every machine, which is exactly what a video **oracle** and a
content-hash cache need. This page is the axis-3 (rendering backend &
[rasterization][raster]) treatment for the three; the GPU line is on
[`./gpu-vector.md`](./gpu-vector.md) and boolean path preprocessing on
[`./path-ops.md`](./path-ops.md).

> [!NOTE]
> These are **building blocks**, not engines: each fills, strokes, clips, and
> hands back a pixel buffer, but none carries a scene graph, a timeline, or a
> typesetting model. An animation engine supplies those and calls down into one
> of these per frame. Cairo and Blend2D expose an imperative path API you drive
> directly; resvg is narrower — it renders a whole SVG document, not individual
> paths.

---

## Cairo

Cairo is [Manim Community's default renderer][mc-boolean] and the reference the
rest of this survey measures GPU output against.

| Field      | Value                                                                            |
| ---------- | -------------------------------------------------------------------------------- |
| Language   | C (with a stable C ABI)                                                          |
| License    | `LGPL-2.1` **OR** `MPL-1.1` (dual, at your option)                               |
| Repository | [`cairographics.org`][cairo-site] (source at [gitlab.freedesktop.org][cairo-gl]) |
| Latest     | `cairo-1.18.4` (2025-03-08)                                                      |
| Bindings   | Native C API → [ImportC][importc] + `pkg-config cairo`                           |

### Overview

The project's own one-liner is deliberately backend-agnostic
([cairographics.org][cairo-site], verbatim):

> "Cairo is a 2D graphics library with support for multiple output devices."

> "Currently supported output targets include the X Window System (via both Xlib
> and XCB), Quartz, Win32, image buffers, PostScript, PDF, and SVG file output."

The **image surface** (an in-memory pixel buffer) is the target that matters for
offline video; the vector drawing model is identical whichever surface is bound.
The licence is the permissive-copyleft pair, verbatim:

> "Cairo is free software and is available to be redistributed and/or modified
> under the terms of either the GNU Lesser General Public License (LGPL) version
> 2.1 or the Mozilla Public License (MPL) version 1.1 at your option."

### How it works

A caller creates a surface, wraps it in a `cairo_t` context, appends path
segments, sets a source (colour/gradient), and calls `cairo_fill` /
`cairo_stroke`. The rasterizer scan-converts the path into per-pixel coverage on
the CPU. Cairo's design goal is media-independent, consistent output
([cairographics.org][cairo-site], verbatim):

> "Cairo is designed to produce consistent output on all output media while
> taking advantage of display hardware acceleration when available (eg. through
> the X Render Extension)."

For a headless render pipeline that acceleration path is unused; the image
surface is pure software, hence its reproducibility.

### Axis-3 facts

- **Curve basis — cubic.** The path primitive is a cubic Bézier;
  `cairo_curve_to(cr, x1, y1, x2, y2, x3, y3)` is documented
  ([cairo-Paths][cairo-paths], verbatim) as: "Adds a cubic Bézier spline to the
  path from the current point to position (x3, y3) in user-space coordinates,
  using (x1, y1) and (x2, y2) as the control points." There is no quadratic
  primitive — this is the [cubic-native][basis] rasterizer an engine can keep a
  cubic store for and only lower to quadratics for the GPU.
- **Fill rule — winding and even-odd.** `cairo_set_fill_rule` selects between the
  two [winding rules][fill]. `CAIRO_FILL_RULE_WINDING` ([cairo-cairo-t][cairo-t],
  verbatim): "If the path crosses the ray from left-to-right, counts +1. If the
  path crosses the ray from right to left, counts -1." `CAIRO_FILL_RULE_EVEN_ODD`:
  "Counts the total number of intersections, without regard to the orientation of
  the contour. If the total number of intersections is odd, the point will be
  filled." Because it fills arbitrary paths by rule, Cairo needs **no**
  triangulation and no boolean preprocessing (contrast the GPU earcut path on
  [`./path-ops.md`](./path-ops.md)).
- **Anti-aliasing — coverage.** `cairo_antialias_t` defaults to grayscale
  coverage AA; `CAIRO_ANTIALIAS_GRAY` ([cairo-cairo-t][cairo-t], verbatim):
  "Perform single-color antialiasing (using shades of gray for black text on a
  white background, for example)." The scan-converter computes each boundary
  pixel's covered fraction — the [analytic-coverage AA][aa] the
  [`frame-capture.d`][ex-capture] probe models with 1px disc coverage.
- **Colour / gamma — premultiplied ARGB32, device-space compositing.** The
  workhorse format is `CAIRO_FORMAT_ARGB32` ([cairo-Image-Surfaces][cairo-img],
  verbatim): "each pixel is a 32-bit quantity, with alpha in the upper 8 bits,
  then red, then green, then blue. The 32-bit quantities are stored native-endian.
  Pre-multiplied alpha is used. (That is, 50% transparent red is 0x80800000, not
  0x80ff0000.)" Cairo composites in this stored byte space — it has no
  linear-light stage — so an engine that wants correct [linear blends][color]
  must linearize its colours around Cairo, not rely on it.
- **Readback.** `cairo_image_surface_get_data` ([cairo-Image-Surfaces][cairo-img],
  verbatim) — "Get a pointer to the data of the image surface, for direct
  inspection or modification" — hands back the raw RGBA buffer an encoder
  consumes (call `cairo_surface_flush()` first), the [frame-capture &
  readback][capture] step.

### D-binding path

The cleanest of the three: a plain C header set (`cairo.h`) with a `pkg-config`
file, so an [ImportC][importc] shim (`#include <cairo.h>`, `pkgConfigModules
"cairo"`) exposes the whole API with zero wrapper code — the same recipe this
repo already uses for `libghostty-vt`. No C++, no ABI risk.

---

## Blend2D

A drop-in-shaped, higher-performance alternative to Cairo whose distinguishing
trick is a runtime **JIT** rasterizer.

| Field      | Value                                                      |
| ---------- | ---------------------------------------------------------- |
| Language   | C++ core, with a first-class C API                         |
| License    | `Zlib`                                                     |
| Repository | [`blend2d/blend2d`][b2d-repo] ([blend2d.com][b2d-site])    |
| Latest     | No tagged releases — "No releases published"; pin a commit |
| Bindings   | Native C API → [ImportC][importc]                          |

### Overview

Blend2D's positioning, verbatim ([blend2d.com][b2d-site]):

> "Blend2D is a high performance 2D vector graphics engine written in C++ and
> released under the Zlib license."

Its GitHub tagline names the differentiator directly ([blend2d/blend2d][b2d-repo],
verbatim): "2D Vector Graphics Powered by a JIT Compiler". The library ships
**no versioned releases** — GitHub shows "No releases published" — so a consumer
pins a commit, the same discipline the source-grounded pages of this survey use.

### How it works

Instead of a fixed rasterizer, Blend2D emits machine code for the exact
fill/composite pipeline a frame needs, at runtime ([blend2d.com][b2d-site],
verbatim):

> "The engine utilizes a built-in JIT compiler to generate optimized pipelines
> at runtime that take the advantage of host CPU features."

The JIT is backed by `AsmJit`; a non-JIT reference pipeline exists as a fallback.
The rasterizer itself is an analytic, edge-based scan-converter, and the render
context can run **multi-threaded**. The project's summary of why it is fast
([blend2d.com/performance][b2d-perf], verbatim): "Blend2D offers incredible
performance compared to other libraries, because it optimizes across the whole
stack" — the stack it lists being "building edges from geometries, novel
rasterization approach, JIT optimized pipelines, and multithreading".

### Axis-3 facts

- **Curve basis — cubic and quadratic.** `BLPath` stores both. `cubicTo`
  ([classBLPath][b2d-path], verbatim) "Adds a cubic curve to `p1`, `p2`, `p3`"
  and "Matches SVG 'C' path command"; `quadTo` "Adds a quadratic curve to `p1`
  and `p2`" and "Matches SVG 'Q' path command". So it is [cubic-native like
  Cairo][basis] but also accepts quadratics directly.
- **Fill rule — winding and even-odd**, via `BL_FILL_RULE_NON_ZERO` /
  `BL_FILL_RULE_EVEN_ODD` — the same [two winding rules][fill]; no triangulation.
- **Anti-aliasing — analytic coverage**, produced by the "novel rasterization
  approach" above; comparable to Cairo's grayscale [coverage AA][aa] but faster.
- **Colour / gamma — premultiplied ARGB.** Blend2D's default pixel format is
  premultiplied 32-bit ARGB (`BL_FORMAT_PRGB32`), the same [premultiplied
  device-space model][color] as Cairo — it is a faster CPU rasterizer, not a
  colour-management upgrade.
- **Readback.** Renders into a caller-owned `BLImage`; `BLImage::getData` yields
  the pixel buffer for the [readback][capture] step.

### D-binding path

Although the core is C++, Blend2D is architected C-API-first — the C++ headers
are thin inlines over the C ABI ([blend2d.com/doc][b2d-doc], verbatim):

> "Blend2D C++ API is in fact build on top of the C API and all C++ functions
> are inlines that call C API without any overhead."

So D binds the underlying `blend2d.h` C API through [ImportC][importc] with no
`extern "C"` shim of its own — nearly as clean as Cairo, and the reason Blend2D
is the recommended faster-CPU substitute.

---

## resvg

The odd one out: not a path API but a whole-document **SVG renderer**. Relevant
here because Manim's text/TeX pipeline already produces SVG, and resvg turns that
SVG into pixels without a browser.

| Field      | Value                                                      |
| ---------- | ---------------------------------------------------------- |
| Language   | Rust                                                       |
| License    | `Apache-2.0` **OR** `MIT` (was `MPL-2.0` through 0.44.x)   |
| Repository | [`RazrFalcon/resvg`][resvg-repo]                           |
| Latest     | `0.47.0` (2026-02-10)                                      |
| Bindings   | C API (the `c-api` crate → `resvg.h`) → [ImportC][importc] |

### Overview

resvg's scope statement, verbatim ([resvg README][resvg-repo]):

> "_resvg_ is an SVG rendering library."

> "It can be used as a Rust library, as a C library, and as a CLI application to
> render static SVG files."

The **static** qualifier is load-bearing — resvg deliberately excludes the
dynamic parts of SVG (verbatim): it "aims to only support the static SVG
subset; i.e. no `a`, `script`, `view` or `cursor` elements, no events and no
animations." It renders one SVG to one raster image; it is not a canvas you
animate.

> [!WARNING]
> **Licence changed.** resvg was `MPL-2.0` for most of its life; the current
> licence is `Apache-2.0 OR MIT`. The changelog for `0.45.0` (2025-02-26) states
> verbatim: "Please note that the license of this project changed from `MPL-2.0`
> to `Apache-2.0 OR MIT`." (Older survey notes citing MPL predate this.)

### How it works

resvg splits parsing from rasterization across two crates, verbatim: `usvg`
("an SVG preprocessor/simplifier") normalizes the document into a minimal tree,
then `tiny-skia` ("a Skia subset ported to Rust") rasterizes it on the CPU. So
resvg's rendering is itself a Cairo-class CPU coverage rasterizer — a pure-Rust
[SkRaster][skia-repo] subset — wrapped behind an SVG front door.

### Axis-3 facts

- **Curve basis — cubic**, inherited from the SVG path grammar (`C`/`c` cubic
  commands) it consumes; see [Bézier basis][basis].
- **Fill rule — winding and even-odd**, per SVG's `fill-rule`; `tiny-skia` fills
  by [winding rule][fill], no triangulation.
- **Anti-aliasing — coverage**, the `tiny-skia` analytic [coverage AA][aa].
- **Colour / gamma — straight/premultiplied RGBA** per the SVG/`tiny-skia`
  model; the same [pixel-boundary re-encoding concern][color] applies.
- **Readback.** The C API renders into a caller-provided pixmap buffer
  (`resvg_render` → RGBA bytes) — a one-shot [readback][capture], not a
  per-path loop.

### D-binding path

resvg exposes a C API (`resvg.h`, generated from its `c-api` crate), so despite
being Rust it binds through [ImportC][importc] like the C libraries. The catch is
not the ABI but the **granularity**: you feed it an SVG string and get a bitmap,
so an engine using it must serialize geometry to SVG rather than issue path
calls — fine for the text/TeX-to-SVG path, wrong for the hot per-frame drawing
loop.

---

## At a glance

| Backend             | Fill model              | Curve input       | AA                     | Readback                       | D binding                       |
| ------------------- | ----------------------- | ----------------- | ---------------------- | ------------------------------ | ------------------------------- |
| [Cairo](#cairo)     | winding / even-odd rule | cubic             | grayscale coverage     | `cairo_image_surface_get_data` | ImportC + `pkg-config` (easy)   |
| [Blend2D](#blend2d) | winding / even-odd rule | cubic + quadratic | analytic coverage      | `BLImage::getData`             | ImportC over C API (easy)       |
| [resvg](#resvg)     | SVG `fill-rule`         | cubic (via SVG)   | coverage (`tiny-skia`) | render-to-pixmap               | ImportC over C API (SVG-scoped) |

All three are deterministic CPU rasterizers, so any of them can serve as the
reproducible video [oracle][cpugpu]. Cairo is the proven Manim default; Blend2D
is the faster substitute with an equally clean [ImportC][importc] path; resvg is
the SVG-document shortcut, not a general drawing surface.

<!-- References -->

[raster]: ../concepts.md#rasterization
[cpugpu]: ../concepts.md#cpu-vector-vs-gpu-vector-rendering
[aa]: ../concepts.md#anti-aliasing
[color]: ../concepts.md#color-model-and-gamma
[fill]: ../concepts.md#fill-triangulation-and-winding
[basis]: ../concepts.md#bezier-basis-quadratic-vs-cubic
[capture]: ../concepts.md#frame-capture-and-readback
[ex-capture]: ../examples/frame-capture.d
[cairo-site]: https://www.cairographics.org/
[cairo-gl]: https://gitlab.freedesktop.org/cairo/cairo
[cairo-paths]: https://www.cairographics.org/manual/cairo-Paths.html
[cairo-t]: https://www.cairographics.org/manual/cairo-cairo-t.html
[cairo-img]: https://www.cairographics.org/manual/cairo-Image-Surfaces.html
[b2d-site]: https://blend2d.com/
[b2d-repo]: https://github.com/blend2d/blend2d
[b2d-doc]: https://blend2d.com/doc/index.html
[b2d-perf]: https://blend2d.com/performance.html
[b2d-path]: https://blend2d.com/doc/classBLPath.html
[resvg-repo]: https://github.com/RazrFalcon/resvg
[skia-repo]: https://github.com/google/skia
[importc]: https://dlang.org/spec/importc.html
[mc-boolean]: https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/mobject/geometry/boolean_ops.py
