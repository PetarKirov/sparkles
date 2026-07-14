# Grounding: Rendering Backends (2D vector rasterizers)

> Not published research. Do not link to it from the survey pages.

Status legend: ✓ verified against a local artifact · ≈ paraphrase-verified · 🌐 web-verified (primary source fetched) · ◯ open
Claim types: quote · fact · figure · behavior · exposition

Covers the four cluster pages: [`index.md`](../rendering-backends/index.md),
[`cpu-vector.md`](../rendering-backends/cpu-vector.md),
[`gpu-vector.md`](../rendering-backends/gpu-vector.md), and
[`path-ops.md`](../rendering-backends/path-ops.md) — nine backends.
Per-backend license + version + D-binding verdict are transcribed as `fact` rows;
the primary-source quotes each page carries are `quote` rows. Internal QA,
excluded from the built site (`srcExclude`) and the link checker.

**Corrections recorded by the pages (flagged):** resvg is `Apache-2.0 OR MIT`,
**not** MPL-2.0 — changed at 0.45.0 (C-resvg-3); Skia is `BSD-3-Clause`
(C-skia-1); Blend2D and NanoVG ship **no tagged releases** — pin a commit
(C-b2d-2, C-nanovg-2).

## Cairo (CPU)

| #         | Claim (short)                                                                                                                                                                                                            | Type  | Source (locator)                                                                                                            | Status |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- | --------------------------------------------------------------------------------------------------------------------------- | ------ |
| Q-cairo-1 | "Cairo is a 2D graphics library with support for multiple output devices."                                                                                                                                               | quote | https://www.cairographics.org/                                                                                              | 🌐     |
| Q-cairo-2 | Dual license: "under the terms of either the GNU Lesser General Public License (LGPL) version 2.1 or the Mozilla Public License (MPL) version 1.1 at your option."                                                       | quote | https://www.cairographics.org/                                                                                              | 🌐     |
| Q-cairo-3 | `cairo_curve_to` "Adds a cubic Bézier spline to the path from the current point to position (x3, y3) in user-space coordinates, using (x1, y1) and (x2, y2) as the control points."                                      | quote | https://www.cairographics.org/manual/cairo-Paths.html                                                                       | 🌐     |
| Q-cairo-4 | `CAIRO_FORMAT_ARGB32`: "each pixel is a 32-bit quantity, with alpha in the upper 8 bits, then red, then green, then blue. … Pre-multiplied alpha is used. (That is, 50% transparent red is 0x80800000, not 0x80ff0000.)" | quote | https://www.cairographics.org/manual/cairo-Image-Surfaces.html                                                              | 🌐     |
| C-cairo-1 | License `LGPL-2.1` OR `MPL-1.1`; version `cairo-1.18.4` (2025-03-08)                                                                                                                                                     | fact  | https://www.cairographics.org/ · https://gitlab.freedesktop.org/cairo/cairo                                                 | 🌐     |
| C-cairo-2 | D-binding: ImportC + `pkg-config cairo` — cleanest of the cluster, zero wrapper (same recipe as libghostty-vt); cubic-only fill, winding/even-odd, no triangulation                                                      | fact  | https://dlang.org/spec/importc.html                                                                                         | 🌐     |
| C-cairo-3 | Manim Community's default renderer; the deterministic reproducible oracle                                                                                                                                                | fact  | https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/mobject/geometry/boolean_ops.py | 🌐     |

## Blend2D (CPU)

| #       | Claim (short)                                                                                                                                                                                               | Type  | Source (locator)                         | Status |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ---------------------------------------- | ------ |
| Q-b2d-1 | "Blend2D is a high performance 2D vector graphics engine written in C++ and released under the Zlib license."                                                                                               | quote | https://blend2d.com/                     | 🌐     |
| Q-b2d-2 | Tagline: "2D Vector Graphics Powered by a JIT Compiler"                                                                                                                                                     | quote | https://github.com/blend2d/blend2d       | 🌐     |
| Q-b2d-3 | "The engine utilizes a built-in JIT compiler to generate optimized pipelines at runtime that take the advantage of host CPU features."                                                                      | quote | https://blend2d.com/                     | 🌐     |
| Q-b2d-4 | "Blend2D C++ API is in fact build on top of the C API and all C++ functions are inlines that call C API without any overhead."                                                                              | quote | https://blend2d.com/doc/index.html       | 🌐     |
| C-b2d-1 | License `Zlib`; `BLPath` stores cubic (`cubicTo`, "Matches SVG 'C'") and quadratic (`quadTo`, "Matches SVG 'Q'"); fill `BL_FILL_RULE_NON_ZERO`/`_EVEN_ODD`; default pixfmt premultiplied `BL_FORMAT_PRGB32` | fact  | https://blend2d.com/doc/classBLPath.html | 🌐     |
| C-b2d-2 | **No versioned releases** — GitHub shows "No releases published"; pin a commit                                                                                                                              | fact  | https://github.com/blend2d/blend2d       | 🌐     |
| C-b2d-3 | D-binding: ImportC over the `blend2d.h` C API (no `extern "C"` shim needed) — recommended faster-CPU substitute for Cairo                                                                                   | fact  | https://dlang.org/spec/importc.html      | 🌐     |
| C-b2d-4 | JIT backed by AsmJit; non-JIT reference pipeline as fallback; render context can run multi-threaded                                                                                                         | fact  | https://blend2d.com/performance.html     | ◯      |

## resvg (CPU)

| #         | Claim (short)                                                                                                                                                              | Type  | Source (locator)                    | Status |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ----------------------------------- | ------ |
| Q-resvg-1 | "resvg is an SVG rendering library." / "It can be used as a Rust library, as a C library, and as a CLI application to render static SVG files."                            | quote | https://github.com/RazrFalcon/resvg | 🌐     |
| Q-resvg-2 | "aims to only support the static SVG subset; i.e. no `a`, `script`, `view` or `cursor` elements, no events and no animations."                                             | quote | https://github.com/RazrFalcon/resvg | 🌐     |
| Q-resvg-3 | **Correction (0.45.0, 2025-02-26):** "Please note that the license of this project changed from `MPL-2.0` to `Apache-2.0 OR MIT`."                                         | quote | https://github.com/RazrFalcon/resvg | 🌐     |
| C-resvg-1 | License `Apache-2.0 OR MIT` (was `MPL-2.0` through 0.44.x — older survey notes citing MPL predate this); version `0.47.0` (2026-02-10)                                     | fact  | https://github.com/RazrFalcon/resvg | 🌐     |
| C-resvg-2 | Internals: `usvg` ("an SVG preprocessor/simplifier") + `tiny-skia` ("a Skia subset ported to Rust") CPU rasterizer; cubic (via SVG), winding/even-odd, coverage AA         | fact  | https://github.com/RazrFalcon/resvg | 🌐     |
| C-resvg-3 | D-binding: C API (`resvg.h` from the `c-api` crate) → ImportC; SVG-scoped (feed SVG string, get bitmap) — right for the text/TeX-to-SVG path, wrong for the per-frame loop | fact  | https://dlang.org/spec/importc.html | 🌐     |

## Vello (GPU compute)

| #         | Claim (short)                                                                                                                                                                                          | Type  | Source (locator)                    | Status |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- | ----------------------------------- | ------ |
| Q-vello-1 | "Vello is a 2D graphics rendering engine written in Rust, with a focus on GPU compute." / "Vello was previously known as `piet-gpu`."                                                                  | quote | https://github.com/linebender/vello | 🌐     |
| Q-vello-2 | "Vello avoids this by using prefix-sum algorithms to parallelize work that usually needs to happen in sequence, so that work can be offloaded to the GPU with minimal use of temporary buffers."       | quote | https://github.com/linebender/vello | 🌐     |
| Q-vello-3 | "This means that Vello needs a GPU with support for compute shaders to run."                                                                                                                           | quote | https://github.com/linebender/vello | 🌐     |
| Q-vello-4 | **Alpha:** "Vello can currently be considered in an alpha state." (blur/filters, conflation, GPU memory, glyph caching called out as open)                                                             | quote | https://github.com/linebender/vello | 🌐     |
| C-vello-1 | License `Apache-2.0 OR MIT`; version `0.9.0` (alpha); `wgpu` → Vulkan/Metal/DX12/WebGPU; cubic (`kurbo`) flattened on-GPU; compute rasterization (no triangulation/stencil); linear-then-encode colour | fact  | https://github.com/linebender/vello | 🌐     |
| C-vello-2 | D-binding: **no C API**, no stable ABI — needs a Rust `cdylib` shim re-exporting `extern "C"` and threading a wgpu device/queue across FFI; hardest in the cluster; the web/wasm strategic bet         | fact  | https://dlang.org/spec/importc.html | 🌐     |

## Lyon (GPU tessellator)

| #        | Claim (short)                                                                                                                                                                                                                        | Type  | Source (locator)                    | Status |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- | ----------------------------------- | ------ |
| Q-lyon-1 | "A path tessellation library written in rust for GPU-based 2D graphics rendering."                                                                                                                                                   | quote | https://github.com/nical/lyon       | 🌐     |
| Q-lyon-2 | "Lyon is _not_ an SVG renderer. For now lyon mainly provides primitives to tessellate complex path fills and strokes in a way that is convenient to use with GPU APIs such as gfx-rs, glium, OpenGL, D3D, etc."                      | quote | https://github.com/nical/lyon       | 🌐     |
| C-lyon-1 | License `MIT OR Apache-2.0`; version `1.0.19`; `FillTessellator`/`StrokeTessellator` emit indexed triangle mesh (nonzero/even-odd); cubic+quadratic input flattened via adaptive subdivision; no AA/colour/readback (consumer's job) | fact  | https://github.com/nical/lyon       | 🌐     |
| C-lyon-2 | D-binding: no C API — Rust-only, but the FFI surface is small/data-shaped (path in → vertex/index arrays out); lighter than Vello (no GPU context to marshal)                                                                        | fact  | https://dlang.org/spec/importc.html | 🌐     |

## NanoVG (GPU stencil-and-cover / OpenGL)

| #          | Claim (short)                                                                                                                                                                         | Type  | Source (locator)                    | Status |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ----------------------------------- | ------ |
| Q-nanovg-1 | "Antialiased 2D vector drawing library on top of OpenGL for UI and visualizations."                                                                                                   | quote | https://github.com/memononen/nanovg | 🌐     |
| Q-nanovg-2 | "The NanoVG API is modeled loosely on HTML5 canvas API." / "The library is licensed under zlib license."                                                                              | quote | https://github.com/memononen/nanovg | 🌐     |
| Q-nanovg-3 | `glnvg__fill` source: `INCR_WRAP`/`DECR_WRAP` on front/back faces accumulate the winding number in the stencil, then a `GL_NOTEQUAL` cover pass paints the inside (`src/nanovg_gl.h`) | quote | https://github.com/memononen/nanovg | 🌐     |
| C-nanovg-1 | License `Zlib`; **no tagged releases** — pin by commit; cubic (`nvgBezierTo`, flattened before stencil); stencil-and-cover winding fill; `NVG_ANTIALIAS` fringe-geometry AA           | fact  | https://github.com/memononen/nanovg | 🌐     |
| C-nanovg-2 | D-binding: ImportC over `nanovg.h` + `nanovg_gl.h`; friction is upstream — you must supply a live OpenGL 3.3 context and loader (raylib or bespoke GL init)                           | fact  | https://dlang.org/spec/importc.html | 🌐     |

## raylib / OpenGL (game framework, not a rasterizer)

| #          | Claim (short)                                                                                                                                                                                                                         | Type  | Source (locator)                                           | Status |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ---------------------------------------------------------- | ------ |
| Q-raylib-1 | "A simple and easy-to-use library to enjoy videogames programming." / "Hardware accelerated with OpenGL: 1.1, 2.1, 3.3, 4.3, ES 2.0, ES 3.0"                                                                                          | quote | https://github.com/raysan5/raylib                          | 🌐     |
| Q-raylib-2 | "raylib is licensed under an unmodified zlib/libpng license, which is an OSI-certified, BSD-like license that allows static linking with closed source software."                                                                     | quote | https://github.com/raysan5/raylib                          | 🌐     |
| Q-raylib-3 | `TakeScreenshot` "Takes a screenshot of current screen (filename extension defines format)"; `DrawSplineBezierCubic` flattens a cubic to a thick polyline (does not fill a region)                                                    | quote | https://github.com/raysan5/raylib (raylib.h)               | 🌐     |
| C-raylib-1 | License `zlib/libpng`; version `6.0` (2026-04-23); repo pins `raylib-d ~>6.0.1`; MSAA (`FLAG_MSAA_4X_HINT`), 8-bit sRGB `Color`; you supply the fill (triangulate outlines yourself)                                                  | fact  | https://github.com/raysan5/raylib                          | 🌐     |
| C-raylib-2 | D-binding: already bound via `raylib-d`, built/linked by this repo's Nix (`pkgs.raylib`); `apps/terminal` drives it in immediate mode (`BeginDrawing`→`DrawRectangle`→`DrawTextEx`→`EndDrawing`) — lowest-friction window+GL+readback | fact  | local repo (`apps/terminal`, `dub.sdl` `raylib-d ~>6.0.1`) | ✓      |

## Skia (CPU + GPU: Ganesh/Graphite)

| #        | Claim (short)                                                                                                                                                                                                                       | Type  | Source (locator)                                  | Status |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ------------------------------------------------- | ------ |
| Q-skia-1 | "Skia is an open source 2D graphics library which provides common APIs that work across a variety of hardware and software platforms"                                                                                               | quote | https://skia.org/                                 | 🌐     |
| Q-skia-2 | "Skia is a complete 2D graphic library for drawing Text, Geometries, and Images" (states the `BSD-3-Clause` license); "It serves as the graphics engine for Google Chrome and ChromeOS, Android, Flutter, and many other products." | quote | https://github.com/google/skia                    | 🌐     |
| Q-skia-3 | Raster backend "draws to a block of memory. This memory can be managed by Skia or by the client." — its own CPU oracle; Ganesh GPU surfaces need a `GrContext` matched one-to-one with GL/Vulkan                                    | quote | https://skia.org/docs/user/api/skcanvas_creation/ | 🌐     |
| Q-skia-4 | `SkPath` richest basis: `conicTo` "Adds conic from last point towards (x1, y1), to (x2, y2), weighted by w" (rational quadratic — exact circles/arcs); also `quadTo`, `cubicTo`                                                     | quote | https://api.skia.org/classSkPath.html             | 🌐     |
| C-skia-1 | **License `BSD-3-Clause`** (correction); version rolling (milestone/`chrome/*` branches, no SemVer); curve basis line/quad/conic/cubic; `SkColorSpace` colour-managed (linear-light compositing); `SkPathOps` in-tree booleans      | fact  | https://github.com/google/skia                    | 🌐     |
| C-skia-2 | Graphite is the newer GPU backend; `skgpu::ganesh` and `skgpu::graphite` live side by side in the `skgpu` namespace                                                                                                                 | fact  | https://api.skia.org/namespaceskgpu.html          | 🌐     |
| C-skia-3 | D-binding: **costliest** — C++ with no stable public C ABI; needs an `extern "C"` wrapper (as Flutter/`skia4delphi`/CanvasKit do) or a third-party C wrapper                                                                        | fact  | https://dlang.org/spec/importc.html               | 🌐     |

## skia-pathops + path preprocessing (boolean ops / flatten / tessellate)

| #           | Claim (short)                                                                                                                                                                                                   | Type       | Source (locator)                                                                                                            | Status |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------- | ------ |
| Q-pathops-1 | "Python bindings for the Google Skia library's Path Ops module, performing boolean operations on paths (intersection, union, difference, xor)."                                                                 | quote      | https://github.com/fonttools/skia-pathops                                                                                   | 🌐     |
| Q-pathops-2 | `Op()`: "The resulting path will be constructed from non-overlapping contours. The curve order is reduced where possible so that cubics may be turned into quadratics, and quadratics maybe turned into lines." | quote      | https://github.com/google/skia/blob/88954ef8f36d064fda7d81c3353edd06f99e7e4b/include/pathops/SkPathOps.h                    | 🌐     |
| Q-pathops-3 | `Simplify()`: "Return a path with a set of non-overlapping contours that describe the same area as the original path."                                                                                          | quote      | https://github.com/google/skia/blob/88954ef8f36d064fda7d81c3353edd06f99e7e4b/include/pathops/SkPathOps.h                    | 🌐     |
| C-pathops-1 | License `BSD-3-Clause`; version `0.9.2` (2026-02-16); Cython over Skia C++ (`pathops` module); five booleans `kDifference`/`kIntersect`/`kUnion`/`kXOR`/`kReverseDifference_SkPathOp`                           | fact       | https://github.com/fonttools/skia-pathops                                                                                   | 🌐     |
| C-pathops-2 | Manim Community declares it a dependency; `boolean_ops.py` wraps it as `Union`/`Intersection`/`Difference`/`Exclusion` mobjects                                                                                 | fact       | https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/mobject/geometry/boolean_ops.py | 🌐     |
| C-pathops-3 | D-binding: no clean C ABI (reached via Cython, not a C header) — link Skia + `extern "C"` shim over `Op()`/`Simplify()`, or sidestep via a winding-fill CPU rasterizer that fills overlapping contours directly | fact       | https://dlang.org/spec/importc.html                                                                                         | 🌐     |
| C-ppn-1     | Manim's OpenGL fill path uses `mapbox-earcut` (`earclip_triangulation` → `mapbox_earcut.triangulate_float32`), which requires a **simple** polygon — hence the `skia-pathops` booleans + flattening first       | fact       | https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/mobject/geometry/boolean_ops.py | ◯      |
| C-ppn-2     | ManimGL dropped its earcut path in favour of GPU winding (stencil-and-cover) fill, which is robust to self-intersection without boolean preprocessing                                                           | fact       | survey exposition (ManimGL renderer) — no single locator on the page                                                        | ◯      |
| C-ppn-3     | Preprocessing matrix: CPU winding fill needs none; GPU triangulation needs booleans→flatten→tessellate; GPU stencil-and-cover needs flatten only; GPU compute (Vello) flattens on-GPU                           | exposition | survey synthesis of the above rows                                                                                          | ◯      |

## Cluster-level

| #           | Claim (short)                                                                                                                                                                                                         | Type       | Source (locator)  | Status |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ----------------- | ------ |
| C-cluster-1 | These are building blocks, not engines: each fills/strokes/clips and hands back a pixel buffer — no scene graph, timeline, or typesetting model                                                                       | exposition | cluster synthesis | ◯      |
| C-cluster-2 | Hybrid recommendation: Cairo as deterministic oracle, Blend2D as faster CPU alternative, raylib+NanoVG/Lyon for real-time preview, Vello(wgpu)+Canvas2D for the web path — one cubic-Bézier geometry model throughout | exposition | cluster synthesis | ◯      |
