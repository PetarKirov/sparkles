# The Sparkles Animation Engine — a design direction

A milestoned architecture direction for a Manim-class mathematical-animation
engine in idiomatic D, targeting **both** a deterministic native-video path and
an interactive web/wasm path. It synthesises the survey — the
[Manim](./manim-community/) object model, the timing models of
[Motion Canvas](./motion-canvas.md)/[Remotion](./remotion.md)/[Makie](./makie.md),
the [rendering backends](./rendering-backends/), the
[typesetting](./math-typesetting.md) and [encoding](./video-encoding.md)
pipelines — against the [Sparkles baseline](./sparkles-baseline.md).

**Last reviewed:** July 11, 2026

> [!IMPORTANT]
> This is **design direction, not a commitment**: no code is proposed for merge
> here. The milestones sketch a build order and name the prior art each step
> borrows; the concrete design lands later under `docs/specs/` or
> `docs/libs/<name>/`.

## Two framing principles

Everything below follows from two decisions the survey makes defensible:

1. **Cubic-canonical, capability-gated.** Store and interchange geometry as
   **cubic** Béziers. [Cairo](./rendering-backends/cpu-vector.md),
   [Blend2D](./rendering-backends/cpu-vector.md), and HTML Canvas2D all consume
   cubics natively, SVG import from typesetting is cubic-native, and quadratic→
   cubic elevation is _exact_ while cubic→quadratic is lossy (the
   [`bezier-eval.d`](./examples/bezier-eval.d) probe measures both: ~`4e-16` vs
   ~`0.86`). So a cubic store costs **zero** conversion on the whole
   deterministic-video path and the default web path; only the GPU backend lowers
   to quadratics/triangles — and it was going to tessellate arbitrary fills
   anyway. This is the opposite of [ManimGL](./manimgl.md)'s quadratic-canonical
   choice, which is right only when the GPU is the _sole_ target.
2. **GC for topology, value types for the hot payload.** The scene-graph _tree_
   is a reference-semantic, GC-managed `final class` (matches Manim's identity
   model, makes updater closures natural, and the baseline already runs a GC
   under wasm). The per-frame numeric _payload_ — points and colors — lives in
   allocator-conscious Structure-of-Arrays value buffers so interpolation stays
   `@nogc`.

## Core object model

A `Mobject` is a GC-managed tree node (id, parent back-ref, submobjects, a
value-type `Geometry` payload, a `Paint`, a local
[affine](./concepts.md#affine-transform-and-coordinate-space) transform,
updaters, a dirty flag, and a lazy `family()` range). A `VMobject`'s
[geometry](./concepts.md#vmobject-and-vector-geometry) is **Structure-of-Arrays**
(the [Manim-community-Cairo](./manim-community/scene-graph.md) layout, not
[ManimGL](./manimgl.md)'s interleaved structured array): cubic subpaths plus
_parallel_ per-anchor color/width arrays, so `Transform`'s two passes (equalise
point counts, then lerp points and colors) are independent and vectorisable. The
GPU backend packs the interleaved `[x,y,z,r,g,b,a,w]` vertex buffer as a _pack
step_, not the canonical store. A `MobjectId` indirection is kept as insurance:
the payload can migrate to a component arena for an ECS-style `@nogc` hot loop
without touching call sites.

`libs/math` grows from its lone [`Vector`](./sparkles-baseline.md) type:
`Matrix`/`Affine2`/`Affine3`, `Quaternion`, `CubicBezier`/`QuadraticBezier`
(`eval`/`subdivide`/`flatten`/`elevate`), curve **alignment**
(`equalizeCurveCounts`), an `ease` module
([rate functions](./concepts.md#rate-function-and-easing)), `lerp`, and a `Color`
= `Vector!(float,4,["r","g","b","a"])` with an sRGB↔linear pair
([gamma](./concepts.md#color-model-and-gamma) — interpolate in linear, encode at
the paint boundary). This layer stays C-library- and OS-free so it compiles to
`wasm32-wasip1`.

## Animation & timing model

Mirror Manim's [`Animation`](./manim-community/index.md) primitive
(`begin → interpolate(alpha) → finish`, with `run_time`, a pure `float→float`
[rate function](./concepts.md#rate-function-and-easing), and
[`lag_ratio`](./concepts.md#lag-ratio-and-staggering) staggering). Composition
(`AnimationGroup`/`Succession`/`LaggedStart`) is a small value-type combinator
algebra; laziness belongs in the _sampling_ (the play loop pulls a range of
`(frame, t)`), not the composition. `Transform` uses Manim's
[alignment](./concepts.md#transform-and-point-count-alignment) on the SoA payload.
The reactive layer — [`ValueTracker`](./concepts.md#updaters-and-valuetracker) +
`addUpdater` + `alwaysRedraw` — is where the GC-tree pays off (updaters are
naturally closures); the convention is "compute into a preallocated payload" so
per-frame updaters don't churn the GC.

## The backend abstraction — the crux

Use the repo's Design-by-Introspection idiom (`versions/traits.d`): a **required
renderer surface** plus an **optional capability vocabulary** that generic code
`static if`s over.

- **Required:** `beginFrame` / `fillPath` / `strokePath` / `endFrame` /
  `readback` (cubic subpaths in device space; transform baked into the submitted
  path).
- **Optional (DbI):** `hasNativeCubicFill`, `hasNativeClip`, `hasNativeGlyphs`,
  `hasGpuWindingFill`, `hasImageBlit`. Generic code: `static if
(hasNativeCubicFill!R)` submit cubics directly; `else static if
(hasGpuWindingFill!R)` submit the raw soup for stencil-and-cover; `else`
  flatten and CPU-[triangulate](./concepts.md#fill-triangulation-and-winding).

The four backends and how the cubic-canonical choice interacts:

| Backend                                         | Kind                                    | Bind via                   | Curve handling                         |
| ----------------------------------------------- | --------------------------------------- | -------------------------- | -------------------------------------- |
| [Cairo](./rendering-backends/cpu-vector.md)     | CPU vector, **deterministic reference** | ImportC (easy C API)       | native cubic — no lowering             |
| [Blend2D](./rendering-backends/cpu-vector.md)   | CPU vector, JIT (faster)                | ImportC (easy)             | native cubic — no lowering             |
| [raylib/GL](./rendering-backends/gpu-vector.md) | GPU + `TakeScreenshot`                  | already wired              | flatten+triangulate **or** GPU winding |
| wasm→Canvas2D/WebGL                             | web preview                             | scene in wasm, drawn in JS | Canvas2D native cubic; WebGL lowers    |

Three of four are cubic-native, so cubic-canonical means zero conversion on the
deterministic-video and default-web paths. Cairo is the reproducible **oracle**
(the [CPU-vs-GPU](./concepts.md#cpu-vector-vs-gpu-vector-rendering) determinism
gap is real; GL is the interactive path, reconciled by a perceptual-diff
tolerance). Not chosen: [Vello](./rendering-backends/gpu-vector.md) (no C API →
hardest to bind) and [Skia](./rendering-backends/gpu-vector.md) (C++, no stable C
ABI → heaviest wrapper), though both are watch-list options if the GPU path
becomes primary.

## Math typesetting strategy

Per the [typesetting survey](./math-typesetting.md): **non-math text** via
**HarfBuzz + FreeType** through ImportC (the best C-ABI fit — stable C APIs, no
C++ wrapper) → glyph
[outlines](./concepts.md#glyph-outline-extraction) → `VMobject`. **Math primary:**
[LaTeX → dvisvgm](./concepts.md#latex-to-svg) → SVG → `VMobject`, exactly like
[Manim](./manim-community/text-pipeline.md), with the TeX distribution **Nix-
pinned** (which neutralises the usual subprocess-nondeterminism objection) and
per-equation content-hash caching. **TeX-free fallback:** MicroTeX behind an
`extern "C"` wrapper (it is C++, so not pure ImportC — a bounded but real lift).
**Web math:** Typst compiled to **wasm** (it already ships one) or KaTeX for a
docs preview — noting Typst's math syntax differs from LaTeX.

## Video / encoding

Per the [encoding survey](./video-encoding.md): **ffmpeg subprocess** with a
raw-RGBA pipe first ([ManimGL](./manimgl.md)-style — zero ABI, deterministic when
Nix-pinned), moving to **libav via ImportC** in-process later (the
[Manim-community PyAV](./manim-community/caching.md) pattern) when the pipe
becomes a bottleneck. Adopt Manim community's per-`play()`
[content-hash caching](./concepts.md#content-hash-caching) + partial-file concat —
the biggest iteration-speed win, correct only because the Cairo render and the
pinned encoder are [deterministic](./concepts.md#deterministic-frame-sampling).
Skip GStreamer.

## Milestone roadmap

Design-direction only; each milestone names the prior art it borrows and a
"prove-it" artifact.

| M       | Goal                                                                                                    | Reuses / borrows from                                                          | Key risk                                       | Prove-it                                                                                 |
| ------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **M1**  | `libs/math`: matrix/affine/quaternion, cubic Bézier (eval/subdivide/flatten/align), ease, gamma `Color` | the [probes](./examples/bezier-eval.d); [MetaPost](./metapost.md) Hobby curves | keep it wasm/betterC-clean                     | `unittest`s: split reproduces the curve; sRGB↔linear round-trips; all `@safe pure @nogc` |
| **M2**  | Object model: `Mobject` GC tree + `VMobject` SoA (cubic + parallel color)                               | [Manim-community](./manim-community/scene-graph.md) cubic layout               | GC-tree vs arena; SoA churn                    | build a scene graph; dump `family()` + point counts                                      |
| **M3**  | First backend: [Cairo](./rendering-backends/cpu-vector.md) via ImportC + frame capture (the reference)  | `libs/ghostty` recipe                                                          | ImportC/Cairo header quirks; unique `c.c` stem | a static scene → byte-stable PNG                                                         |
| **M4**  | Animation + play loop + `Transform` alignment                                                           | [Manim](./manim-community/index.md) timing                                     | alignment correctness                          | `Transform(square → circle)` frame sequence                                              |
| **M5**  | Encoding: [ffmpeg subprocess](./video-encoding.md) + per-`play()` content-hash cache                    | ManimGL pipe; Manim-community cache                                            | cache-key determinism                          | one scene → cached MP4; re-run skips unchanged plays                                     |
| **M6**  | Typesetting: [HarfBuzz+FreeType](./math-typesetting.md) text + LaTeX→dvisvgm math                       | [Manim text pipeline](./manim-community/text-pipeline.md)                      | SVG-path fidelity; TeX hermeticity             | animate a rendered equation + a shaped text line                                         |
| **M7**  | Second backend: [raylib/GL](./rendering-backends/gpu-vector.md) + readback, diffed vs Cairo oracle      | `apps/terminal` raylib surface                                                 | GPU↔CPU pixel divergence                       | same scene on GL, perceptually diffed                                                    |
| **M8**  | wasm/web preview: scene/geometry/easing → `wasm32-wasip1`, drawn on Canvas2D                            | `buildDWasmModule`; [Motion Canvas](./motion-canvas.md)                        | single-module, no-C-libs (esp. text)           | a docs widget playing a scene in-browser                                                 |
| **M9**  | Reactive: [`ValueTracker`](./concepts.md#updaters-and-valuetracker) + updaters                          | [Makie](./makie.md) observables; Manim updaters                                | per-frame updater churn                        | a graph tracking a live `ValueTracker`                                                   |
| **M10** | (stretch) [Blend2D](./rendering-backends/cpu-vector.md) backend; libav-in-process; MicroTeX C-wrapper   | ImportC recipe                                                                 | Blend2D determinism vs Cairo                   | drop-in backend/encoder swap, diffed vs reference                                        |

## Open questions & risks

1. **Cubic vs quadratic lock-in** — cubic optimises three of four backends but
   makes GL lower every frame. Mitigation: `SubPath` exposes a `curves()` range,
   not a raw stride, so the basis is swappable; reconsider before making GL
   primary.
2. **GC tree vs arena** — the per-frame family walk can pressure the GC.
   Mitigation: the payload is already value-type SoA; `MobjectId` lets hot data
   move to an arena later. Reversible by construction.
3. **`@nogc` vs GC updaters** — forcing `@nogc` hurts authoring; free allocation
   risks churn. Mitigation: the preallocated-payload convention; measure with the
   repo's bench tooling.
4. **Determinism across backends** — Cairo is the byte-stable oracle; GL will not
   be bit-identical. Mitigation: perceptual-diff tolerance; Nix-pin every
   rasteriser, encoder, and TeX distribution on the reference path.
5. **wasm's no-C-libs constraint for text** — HarfBuzz/FreeType cannot run in the
   wasm module. Mitigation: precompute glyph outlines natively and ship them as
   data, or shape/draw text on the JS side (Canvas/KaTeX/Typst-wasm); keep only
   geometry/easing in wasm.
6. **GPU winding-fill vs CPU triangulation** — winding handles arbitrary paths
   but needs a stencil pass; earcut needs simple polygons (hence
   [`skia-pathops`](./rendering-backends/path-ops.md) boolean pre-processing).
   Mitigation: start with CPU flatten+triangulate for M7; add GPU winding as a
   capability later.
7. **MicroTeX is C++** — ImportC cannot bind it directly; it needs an `extern
"C"` wrapper TU. Keep Nix-pinned LaTeX→dvisvgm as primary.

## Sources

This proposal synthesises the catalog. Its architectural claims are grounded in
the surveyed deep-dives and building-block pages linked throughout, the
[concepts](./concepts.md) vocabulary, and the [baseline](./sparkles-baseline.md)
audit of the `sparkles` repository; the field-wide capability picture and the
per-capability delta are in the [comparison](./comparison.md).

<!-- References -->

[concepts]: ./concepts.md
[baseline]: ./sparkles-baseline.md
[comparison]: ./comparison.md
[manim-community]: ./manim-community/
[manimgl]: ./manimgl.md
[motion-canvas]: ./motion-canvas.md
[remotion]: ./remotion.md
[makie]: ./makie.md
[rendering-backends]: ./rendering-backends/
[cpu-vector]: ./rendering-backends/cpu-vector.md
[gpu-vector]: ./rendering-backends/gpu-vector.md
[path-ops]: ./rendering-backends/path-ops.md
[math-typesetting]: ./math-typesetting.md
[video-encoding]: ./video-encoding.md
[metapost]: ./metapost.md
