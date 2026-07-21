# Capability Comparison

The capstone synthesis: the surveyed systems laid side by side across the eight
axes, the cross-cutting patterns that emerge, the field's points of consensus and
genuine disagreement, and a **delta table** mapping each modern capability onto
where [Sparkles](./sparkles-baseline.md) stands today and which
[milestone](./animation-engine-proposal.md) would deliver it.

**Last reviewed:** July 11, 2026

## The master matrix

Programmatic engines and declarative-diagramming systems across the dimensions
that most shape a reimplementation. Building blocks
([rendering backends](./rendering-backends/),
[typesetting](./math-typesetting.md), [encoding](./video-encoding.md)) are
components an engine binds, not engines, and are compared within their cluster
pages.

| Subject                             | Lang         | Paradigm                 | Rendering             | Bézier               | Timing model           | Math typesetting      | Output           | License           |
| ----------------------------------- | ------------ | ------------------------ | --------------------- | -------------------- | ---------------------- | --------------------- | ---------------- | ----------------- |
| [Manim CE](./manim-community/)      | Python       | imperative               | Cairo (CPU) + GL      | **cubic** (GL: quad) | play-loop              | LaTeX→dvisvgm / Typst | PyAV mp4/webm    | MIT               |
| [ManimGL](./manimgl.md)             | Python       | imperative               | OpenGL only           | **quadratic**        | play-loop              | LaTeX→dvisvgm         | ffmpeg pipe      | MIT               |
| [Motion Canvas](./motion-canvas.md) | TS           | generator                | Canvas2D (web)        | cubic (Canvas)       | generator/play-head    | MathJax→SVG           | ffmpeg plugin    | MIT               |
| [Remotion](./remotion.md)           | React        | pure-frame-fn            | headless Chromium     | web platform         | pure frame(N)          | web (KaTeX/MathJax)   | ffmpeg           | source-available  |
| [Theatre.js](./theatre-js.md)       | TS           | GUI timeline             | — (delegates)         | —                    | keyframe timeline      | —                     | — (host renders) | Apache-2.0 / AGPL |
| [Javis.jl](./javis.md)              | Julia        | imperative               | Luxor/Cairo (CPU)     | cubic                | frame-function         | MathJax `tex2svg`     | ffmpeg gif/mp4   | MIT (dormant)     |
| [Makie.jl](./makie.md)              | Julia        | reactive                 | Cairo/GL/WGL          | cubic                | Observables + `record` | MathTeXEngine         | ffmpeg           | MIT               |
| [nannou](./nannou.md)               | Rust         | immediate                | wgpu (GPU)            | n/a (immediate)      | manual per-frame       | — (RustType)          | PNG seq → ffmpeg | MIT/Apache        |
| [MathAnimation](./mathanimation.md) | C++          | imperative               | plutovg→GL atlas      | cubic+quad           | GUI timeline           | MiKTeX→dvisvgm        | SVT-AV1/IVF      | custom EULA       |
| [Penrose](./penrose.md)             | TS           | declarative              | SVG (optimized)       | —                    | — (static)             | MathJax               | SVG/PNG/PDF      | MIT               |
| [Bluefish](./bluefish.md)           | TS           | declarative (relational) | SVG (DOM)             | —                    | — (static)             | (SVG/host)            | SVG              | MIT               |
| [TikZ/PGF](./tikz.md)               | TeX          | declarative              | TeX driver → PDF/SVG  | **cubic**            | SVG/SMIL only          | native TeX            | PDF/PS/SVG       | GPL/LPPL          |
| [Asymptote](./asymptote.md)         | C++-like DSL | descriptive              | own VM → PS/SVG/GL    | **cubic** (Hobby)    | batched frames         | LaTeX labels          | EPS/PDF/SVG/3D   | LGPLv3            |
| [CeTZ](./cetz.md)                   | Typst        | declarative              | Typst compiler (Rust) | cubic                | — (static)             | native Typst math     | PDF/SVG/PNG      | LGPL-3.0          |
| [MetaPost](./metapost.md)           | DSL          | declarative (equations)  | own → EPS/SVG         | **cubic** (Hobby)    | — (static)             | TeX `btex`            | EPS/SVG/PNG      | LGPL              |

## By dimension

### Object & geometry model

The retained-tree model ([`Mobject`/`VMobject`](./concepts.md#mobject-and-the-scene-graph))
is near-universal among the programmatic engines; [nannou](./nannou.md) is the
lone [immediate-mode](./concepts.md#retained-vs-immediate-mode) outlier (no
retained scene, per-frame `draw` calls). The declarative systems replace the tree
with a [constraint/relation layer](./concepts.md#constraint-and-optimization-based-layout):
[Penrose](./penrose.md) optimises a numerical energy, [Bluefish](./bluefish.md)
propagates relations _locally_ (explicitly not a global solver — the sharpest
split within the declarative camp), and the
[MetaPost](./metapost.md)/[TikZ](./tikz.md)/[Asymptote](./asymptote.md) lineage
solves linear equations over points.

The load-bearing geometry split is the
[**Bézier basis**](./concepts.md#bezier-basis-quadratic-vs-cubic): **cubic** wins
almost everywhere (Cairo, Canvas2D, SVG, all the TeX-lineage languages), and only
[ManimGL](./manimgl.md) and Manim-community's GL classes use **quadratic** — a
choice that pays off _only_ when the GPU is the sole target. A second split is
data layout: ManimGL packs one interleaved structured array (GPU-upload-friendly);
Manim-community-Cairo keeps points and colors in _parallel_ arrays (better for
the two independent `Transform` passes). The [`bezier-eval.d`](./examples/bezier-eval.d)
probe quantifies why cubic is the safer canonical form.

### Animation & timing model

Five distinct [execution models](./concepts.md#execution-models) appear, and the
choice is the deepest architectural fork:

- **Imperative play-loop** — Manim, Javis, MathAnimation: `play(Animation)` calls
  stepped by a scene loop. The richest morph/`Transform` vocabulary.
- **Generator / play-head** — [Motion Canvas](./motion-canvas.md): `yield`ed
  generators against a moving playhead.
- **Pure frame function** — [Remotion](./remotion.md): `frame(N)` is pure; the
  cleanest determinism story, but no stateful morph.
- **Reactive / observable** — [Makie](./makie.md): mutate observables, `record`
  captures frames. A plotting model, not a morph engine.
- **GUI timeline** — [Theatre.js](./theatre-js.md): keyframes on a visual
  timeline, driving a host renderer.

The declarative systems are mostly **static** — animation is a finding-of-absence
(TikZ's `animate` is SVG/SMIL-only; Penrose/Bluefish/CeTZ/MetaPost have none).
Only the retained play-loop engines implement true
[`Transform`](./concepts.md#transform-and-point-count-alignment) with
submobject-tree + point-count alignment; Javis reduces the same problem to a
Hungarian-assignment polygon match.

### Rendering & rasterization

The [CPU-vector-vs-GPU](./concepts.md#cpu-vector-vs-gpu-vector-rendering) tension
recurs everywhere. Deterministic, reproducible output lives on **CPU vector**
([Cairo](./rendering-backends/cpu-vector.md) — Manim-community default, Javis via
Luxor, Makie via CairoMakie); real-time preview lives on **GPU** (ManimGL,
Makie's GLMakie, nannou's wgpu, MathAnimation's GL atlas). Manim community's
metaclass keeps _both_ alive from one class definition. Fill strategy divides into
[winding fill](./concepts.md#fill-triangulation-and-winding) (Cairo, ManimGL's
GPU stencil) and [triangulation](./rendering-backends/path-ops.md) (earcut on the
GL paths, needing `skia-pathops` boolean pre-processing for holey shapes). The
[rendering-backends](./rendering-backends/) cluster ranks the bindable options by
D-effort: Cairo/Blend2D/NanoVG (C API, easy), Vello (no C API, hardest), Skia
(C++, no stable C ABI, heaviest).

### Typesetting & text

Two philosophies. The **shell-out** camp (both Manim forks, Asymptote,
MathAnimation) compiles [LaTeX → dvisvgm → SVG](./concepts.md#latex-to-svg) and
imports the paths — powerful but needs a TeX install and a subprocess. The
**native** camp is the modern trend: [TikZ](./tikz.md) _is_ TeX, and
[CeTZ](./cetz.md)/[Typst](./math-typesetting.md) have first-class math in a
self-contained compiler with a wasm build. The web engines lean on
[MathJax/KaTeX](./math-typesetting.md) (HTML/SVG, not morphable outlines). For a
native engine, [HarfBuzz+FreeType](./math-typesetting.md) is the best-bindable
route for non-math [glyph outlines](./concepts.md#glyph-outline-extraction).

### Output & encoding

The [encode](./concepts.md#codec-muxing-and-pixel-format) integration spans the
full spectrum: **ffmpeg subprocess** (ManimGL, Motion Canvas, Javis — zero ABI),
**libav in-process** ([Manim community's PyAV](./manim-community/caching.md)),
**headless-browser capture** (Remotion), **PNG-sequence + external tool**
(nannou, Asymptote via ImageMagick), and **direct codec linking**
(MathAnimation's [SVT-AV1→IVF](./video-encoding.md), the far end). The
[video-encoding](./video-encoding.md) cluster recommends the subprocess-first,
libav-later path for a D engine.

### Determinism, caching & performance

[Content-hash caching](./concepts.md#content-hash-caching) is Manim community's
signature optimisation (hash each `play()`, reuse the cached partial movie file) —
and, strikingly, almost nobody else implements it: Motion Canvas re-renders the
whole range, Remotion gets determinism "for free" from pure frame functions but
caches at the asset layer, ManimGL re-renders (caching only LaTeX/SVG on disk).
Correct caching _requires_ [deterministic](./concepts.md#deterministic-frame-sampling)
rendering, which is exactly why the CPU-vector oracle matters.

## Consensus

- **Vector, not raster.** Every serious engine represents shapes as
  Bézier [`VMobjects`](./concepts.md#vmobject-and-vector-geometry), because
  interpolation and morphing demand it.
- **Cubic is the interchange default** (ManimGL's quadratic is the GPU-motivated
  exception).
- **A retained scene graph** for object-level animation; immediate mode only for
  procedural per-frame work.
- **Rate functions + staggered composition** are the shared timing primitive.
- **LaTeX→SVG remains the pragmatic math path**, even as native-typesetting
  (Typst) rises.
- **CPU-vector for reproducible video, GPU for interactivity** — often both.

## Architectural trade-offs

| Decision       | One side                                          | The other side                                          |
| -------------- | ------------------------------------------------- | ------------------------------------------------------- |
| Bézier basis   | quadratic → GPU-native, one-shader fill (ManimGL) | cubic → CPU/SVG/Canvas-native, lossless (everyone else) |
| Data layout    | interleaved AoS → GPU upload (ManimGL)            | parallel SoA → independent lerp passes (CE-Cairo)       |
| Timing model   | imperative play-loop → rich morph (Manim)         | pure frame-fn → trivial determinism (Remotion)          |
| Renderer       | CPU vector → deterministic, slow (Cairo)          | GPU → fast, non-reproducible (GL)                       |
| Typesetting    | shell out to LaTeX → powerful, heavy (Manim)      | native compiler → fast, self-contained (Typst)          |
| Encoding       | subprocess → zero ABI, fork cost (ManimGL)        | linked libav → in-process, ABI surface (PyAV)           |
| Scene identity | GC/reference tree → ergonomic (Manim)             | value/arena → `@nogc` hot loop                          |

## The delta table

Each modern capability, where Sparkles stands **today** (per the
[baseline](./sparkles-baseline.md)), and the [milestone](./animation-engine-proposal.md)
that would deliver it.

| Capability                            | Best-in-class exemplar                                           | Sparkles today           | Milestone |
| ------------------------------------- | ---------------------------------------------------------------- | ------------------------ | --------- |
| Cubic Bézier geometry + alignment     | [Manim CE](./manim-community/scene-graph.md)                     | ✗ (only `Vector`)        | M1–M2     |
| Retained scene graph                  | [Manim](./manim-community/)                                      | ✗                        | M2        |
| Rate functions + `lag_ratio`          | [Manim](./manim-community/index.md)                              | ✗ (probe only)           | M1, M4    |
| `Transform` morph + alignment         | [Manim](./concepts.md#transform-and-point-count-alignment)       | ✗                        | M4        |
| Deterministic CPU-vector backend      | [Cairo](./rendering-backends/cpu-vector.md)                      | ✗ (ImportC recipe ready) | M3        |
| GPU backend + frame capture           | [ManimGL](./manimgl.md)                                          | ◐ raylib wired           | M7        |
| Video encode + content-hash cache     | [Manim CE](./manim-community/caching.md)                         | ✗                        | M5        |
| LaTeX / native math typesetting       | [Manim](./manim-community/text-pipeline.md) / [Typst](./cetz.md) | ✗                        | M6        |
| Web/interactive (wasm) preview        | [Motion Canvas](./motion-canvas.md)                              | ◐ `buildDWasmModule`     | M8        |
| Reactive `ValueTracker`/observables   | [Makie](./makie.md)                                              | ✗                        | M9        |
| Capability-gated renderer abstraction | (novel; DbI)                                                     | ◐ idiom exists           | M3, M7    |

## Open questions & gaps

- **Native + web from one codebase** is unproven at this scale — the wasm text
  constraint (no HarfBuzz/FreeType in WASI) forces a split text path.
- **Determinism across a CPU oracle and a GPU preview** needs a perceptual-diff
  tolerance nobody in the survey formalises.
- **A `@nogc` scene graph** is a road not taken by any surveyed engine (all use GC
  or refcounting); the payoff and cost are untested.
- **Declarative layout** (Penrose/Bluefish) as an optional layer over an
  imperative engine is unexplored — a possible Sparkles differentiator.

## Sources

This synthesis draws on every deep-dive and building-block page in the catalog
(linked throughout), the [concepts](./concepts.md) vocabulary, and the
[baseline](./sparkles-baseline.md) audit; each claim's primary source is in the
cited page's own `Sources` section.

<!-- References -->

[concepts]: ./concepts.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./animation-engine-proposal.md
[manim-community]: ./manim-community/
[manimgl]: ./manimgl.md
[motion-canvas]: ./motion-canvas.md
[remotion]: ./remotion.md
[theatre-js]: ./theatre-js.md
[javis]: ./javis.md
[makie]: ./makie.md
[nannou]: ./nannou.md
[mathanimation]: ./mathanimation.md
[penrose]: ./penrose.md
[bluefish]: ./bluefish.md
[tikz]: ./tikz.md
[asymptote]: ./asymptote.md
[cetz]: ./cetz.md
[metapost]: ./metapost.md
[rendering-backends]: ./rendering-backends/
[cpu-vector]: ./rendering-backends/cpu-vector.md
[path-ops]: ./rendering-backends/path-ops.md
[math-typesetting]: ./math-typesetting.md
[video-encoding]: ./video-encoding.md
