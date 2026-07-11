# Mathematical Animation Engines

A breadth-first survey of the open-source ecosystem for **mathematical animation
videos** — the [Manim](./manim-community/) family and the wider paradigm and
building-block space around it — mapped to inform a future `sparkles` D library
targeting both native video and interactive web output. Every claim ties to a
primary source (a cited repository path or official-doc URL, usually with a
verbatim quote), and the load-bearing geometry and timing facts are backed by
[runnable D probes](#the-runnable-probes) that CI compiles and runs.

**Last reviewed:** July 11, 2026

This survey answers eleven questions:

1. What is the reference architecture of a mathematical-animation engine — object
   model, animation system, rendering, typesetting, encoding? →
   [Manim Community][mc] (+ [scene-graph][mc-sg], [text-pipeline][mc-tx],
   [caching][mc-ch]) and [ManimGL][mgl]
2. How is _time_ expressed across engines — play-loop, generator, pure frame
   function, reactive, GUI timeline? → the [engines](#master-catalog) +
   [concepts § execution models][c-exec]
3. Why is the [Bézier basis][c-bez] (quadratic vs cubic) load-bearing, and how
   does the conversion cost fall? → [scene-graph][mc-sg], [ManimGL][mgl],
   [`bezier-eval.d`][ex-bez]
4. How do the web-native engines differ in model and rendering surface? →
   [Motion Canvas][motion], [Remotion][rem], [Theatre.js][th]
5. What does a reactive/observable plotting model contribute? → [Makie.jl][mak]
6. What does immediate-mode creative-coding look like? → [nannou][nan]; and a
   Cairo frame-function layer? → [Javis.jl][jav]
7. What does a from-scratch _native_ engine (the closest analog to a D one)
   actually do? → [MathAnimation][ma]
8. What is the declarative-diagramming alternative to the imperative Mobject
   model? → [Penrose][pen], [Bluefish][blu], [TikZ/PGF][tik], [Asymptote][asy],
   [CeTZ][cet], [MetaPost][met]
9. Which 2D rasterizers could a D engine bind, and at what cost? →
   [Rendering Backends][rb]
10. How does mathematical notation become vector outlines, and how do frames
    become video? → [Math Typesetting][mt], [Video Encoding][ve]
11. Where does Sparkles stand, and what should it build? → [Baseline][base] +
    [comparison delta][cmp-delta] → [Animation Engine Proposal][prop]

---

## The eight axes

Every deep-dive is analysed against the same spine, so the catalog is comparable;
where an axis does not apply, the page says so, because the _absence_ of a
capability is itself a finding. Defined once in [concepts][concepts]:

| #   | Axis                               | #   | Axis                                          |
| --- | ---------------------------------- | --- | --------------------------------------------- |
| 1   | [Object & scene model][c-mob]      | 5   | [Output & encoding][c-codec]                  |
| 2   | [Animation & timing][c-exec]       | 6   | Interactivity, preview & authoring            |
| 3   | [Rendering & rasterization][c-cpu] | 7   | Extensibility & API surface                   |
| 4   | [Typesetting & text][c-latex]      | 8   | [Determinism, caching & performance][c-cache] |

## Master catalog

| Subject            | What it is                                     | Category       | Paradigm     | Link                                 |
| ------------------ | ---------------------------------------------- | -------------- | ------------ | ------------------------------------ |
| Concepts           | the survey's shared vocabulary                 | —              | —            | [concepts.md][concepts]              |
| Manim Community    | the reference engine (Cairo default, cubic)    | engine         | imperative   | [manim-community/][mc]               |
| ManimGL            | 3Blue1Brown's OpenGL-only original (quadratic) | engine         | imperative   | [manimgl.md][mgl]                    |
| Motion Canvas      | TS generator/play-head + editor (Canvas2D)     | engine         | generator    | [motion-canvas.md][motion]           |
| Remotion           | React "video = pure frame function"            | engine         | pure-frame   | [remotion.md][rem]                   |
| Theatre.js         | keyframe-timeline toolkit driving any renderer | engine (seq.)  | GUI timeline | [theatre-js.md][th]                  |
| Javis.jl           | Julia frame-function on Luxor/Cairo            | engine         | imperative   | [javis.md][jav]                      |
| Makie.jl           | Julia GPU plotting, Observables reactive       | engine         | reactive     | [makie.md][mak]                      |
| nannou             | Rust immediate-mode wgpu creative-coding       | engine         | immediate    | [nannou.md][nan]                     |
| MathAnimation      | C++ from-scratch native engine + editor        | engine         | imperative   | [mathanimation.md][ma]               |
| Penrose            | diagrams by numerical constraint optimization  | diagramming    | declarative  | [penrose.md][pen]                    |
| Bluefish           | relational diagramming (local propagation)     | diagramming    | declarative  | [bluefish.md][blu]                   |
| TikZ / PGF         | the TeX-native vector language                 | diagramming    | declarative  | [tikz.md][tik]                       |
| Asymptote          | descriptive vector _language_ with 3D          | diagramming    | descriptive  | [asymptote.md][asy]                  |
| CeTZ               | TikZ-for-Typst, rendered by the Typst compiler | diagramming    | declarative  | [cetz.md][cet]                       |
| MetaPost           | Hobby's equation-solved-points origin          | diagramming    | declarative  | [metapost.md][met]                   |
| Rendering Backends | Cairo/Blend2D/Vello/Skia/… rasterizers         | building block | —            | [rendering-backends/][rb]            |
| Math Typesetting   | LaTeX→dvisvgm / MathJax / Typst / HarfBuzz     | building block | —            | [math-typesetting.md][mt]            |
| Video Encoding     | ffmpeg / libav / GStreamer / SVT-AV1           | building block | —            | [video-encoding.md][ve]              |
| Comparison         | capability matrix + consensus + delta table    | synthesis      | —            | [comparison.md][cmp]                 |
| Sparkles Baseline  | the D monorepo's greenfield starting point     | synthesis      | —            | [sparkles-baseline.md][base]         |
| Engine Proposal    | milestoned M1–M10 hybrid-engine design         | design         | —            | [animation-engine-proposal.md][prop] |

## Taxonomies

### By authoring paradigm

| Paradigm                                     | Subjects                                                                                     |
| -------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Imperative play-loop / frame-function        | [Manim CE][mc], [ManimGL][mgl], [Javis][jav], [MathAnimation][ma]                            |
| Generator / play-head                        | [Motion Canvas][motion]                                                                      |
| Pure frame function                          | [Remotion][rem]                                                                              |
| Reactive / observable                        | [Makie][mak]                                                                                 |
| GUI timeline / keyframe                      | [Theatre.js][th]                                                                             |
| Immediate mode                               | [nannou][nan]                                                                                |
| Declarative constraint / relation / equation | [Penrose][pen], [Bluefish][blu], [TikZ][tik], [Asymptote][asy], [CeTZ][cet], [MetaPost][met] |

### By rendering model

| Model                                  | Subjects                                                                                                           |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| CPU vector                             | [Manim CE][mc] (Cairo), [Javis][jav] (Luxor), [Makie][mak] (CairoMakie), [Cairo/Blend2D/resvg][rb-cpu]             |
| GPU                                    | [ManimGL][mgl], [Makie][mak] (GL/WGL), [nannou][nan], [MathAnimation][ma], [Vello/Lyon/NanoVG/raylib/Skia][rb-gpu] |
| Web canvas / DOM                       | [Motion Canvas][motion], [Remotion][rem], [Theatre.js][th]                                                         |
| Vector document (PDF/PS/SVG)           | [TikZ][tik], [Asymptote][asy], [CeTZ][cet], [MetaPost][met]                                                        |
| Optimizer-laid-out (renderer-agnostic) | [Penrose][pen], [Bluefish][blu]                                                                                    |

### By language / ecosystem

| Ecosystem          | Subjects                                                                                    |
| ------------------ | ------------------------------------------------------------------------------------------- |
| Python             | [Manim CE][mc], [ManimGL][mgl]                                                              |
| TypeScript / web   | [Motion Canvas][motion], [Remotion][rem], [Theatre.js][th], [Penrose][pen], [Bluefish][blu] |
| Julia              | [Javis][jav], [Makie][mak]                                                                  |
| Rust               | [nannou][nan]                                                                               |
| C / C++            | [MathAnimation][ma]                                                                         |
| TeX / Typst family | [TikZ][tik], [Asymptote][asy], [CeTZ][cet], [MetaPost][met]                                 |

### By output target (maps to the hybrid D goal)

| Target                  | Subjects                                                                                     |
| ----------------------- | -------------------------------------------------------------------------------------------- |
| Offline video file      | [Manim CE][mc], [ManimGL][mgl], [Javis][jav], [Remotion][rem], [MathAnimation][ma]           |
| Real-time native window | [ManimGL][mgl], [Makie][mak] (GLMakie), [nannou][nan], [MathAnimation][ma]                   |
| Interactive web         | [Motion Canvas][motion], [Remotion][rem], [Theatre.js][th], [Makie][mak] (WGLMakie)          |
| Static vector figure    | [Penrose][pen], [Bluefish][blu], [TikZ][tik], [Asymptote][asy], [CeTZ][cet], [MetaPost][met] |

## Milestones

When the field's key capabilities landed. Coarse dates are `[literature]`.

| When       | What                                                                                                                      |
| ---------- | ------------------------------------------------------------------------------------------------------------------------- |
| ~1994      | **MetaPost** (Hobby) — equation-solved points + Hobby splines `[literature]`                                              |
| ~2004–2005 | **Asymptote** and **PGF/TikZ** bring descriptive vector graphics to TeX `[literature]`                                    |
| ~2009–2014 | **MathJax** then **KaTeX** — web math rendering `[literature]`                                                            |
| ~2015–2018 | 3Blue1Brown's **manim** authored then open-sourced; **Makie.jl** and **nannou** appear `[literature]`                     |
| 2020       | **Manim Community** fork formalised; **Javis.jl**; **Penrose** (SIGGRAPH) `[literature]`                                  |
| ~2021–2023 | **Remotion** (React-as-video); **Typst** + **CeTZ**; **Vello** GPU vector; **Motion Canvas** public `[literature]`        |
| ~2024–2026 | **Bluefish** (UIST '24) relational diagramming; **nannou** 0.20 Bevy rewrite; **Typst** math + wasm mature `[literature]` |
| 2026-07-11 | This survey's `**Last reviewed:**` date                                                                                   |

## The runnable probes

Dependency-free `dub` single-file programs under [`examples/`][ex-bez]; CI
compiles and runs each (`ci --example-files`). They ground the survey's geometry
and timing claims in code.

| Probe                        | Demonstrates                                                           | Backs                                |
| ---------------------------- | ---------------------------------------------------------------------- | ------------------------------------ |
| [bezier-eval.d][ex-bez]      | quadratic vs cubic; exact quad→cubic elevation + the one-way fit cost  | [scene-graph][mc-sg], [ManimGL][mgl] |
| [rate-functions.d][ex-rate]  | smootherstep vs the community sigmoid `smooth`; `lag_ratio` stagger    | [concepts § easing][c-ease]          |
| [affine-transform.d][ex-aff] | 3×3 compose = right-to-left composition; non-commutativity             | [concepts § affine][c-aff]           |
| [frame-capture.d][ex-cap]    | software framebuffer readback → checksum (the render→encode interface) | [video-encoding][ve]                 |

## Quick navigation

### Suggested reading paths

- **"I'm designing the Sparkles animation engine"** — [concepts][concepts] →
  [Manim Community][mc] (+ [scene-graph][mc-sg], [text-pipeline][mc-tx],
  [caching][mc-ch]) → [ManimGL][mgl] (geometry contrast) →
  [Rendering Backends][rb] → [Math Typesetting][mt] → [Video Encoding][ve] →
  [Comparison][cmp] (matrix + [delta][cmp-delta]) → [Baseline][base] →
  [Proposal][prop]; add [Motion Canvas][motion]/[Remotion][rem] before the
  web/wasm target decision.
- **"I want the web/interactive (wasm) target"** — [Motion Canvas][motion] →
  [Remotion][rem] → [Theatre.js][th] → [rendering-backends § GPU][rb-gpu] →
  [Comparison][cmp].
- **"I want the native video target"** — [Manim Community][mc] →
  [MathAnimation][ma] → [nannou][nan] → [rendering-backends § CPU][rb-cpu] →
  [Video Encoding][ve] → [Comparison][cmp].
- **"Declarative / constraint-first authoring"** — [Penrose][pen] →
  [Bluefish][blu] → [MetaPost][met] → [concepts § declarative layout][c-decl].
- **"How does math text become shapes?"** — [Math Typesetting][mt] →
  [text-pipeline][mc-tx] → [concepts § glyph outlines][c-glyph].
- **Vocabulary lookup** — [concepts.md][concepts].

## Sources

Each deep-dive carries its own `Sources` section with the primary references
behind its claims (repository paths pinned by commit, official-doc URLs, and
papers). The four probes are the survey's own CI-run evidence; internal
claim-by-claim grounding ledgers are kept under `grounding/` (not published).

<!-- References -->

[concepts]: ./concepts.md
[mc]: ./manim-community/
[mc-sg]: ./manim-community/scene-graph.md
[mc-tx]: ./manim-community/text-pipeline.md
[mc-ch]: ./manim-community/caching.md
[mgl]: ./manimgl.md
[motion]: ./motion-canvas.md
[rem]: ./remotion.md
[th]: ./theatre-js.md
[jav]: ./javis.md
[mak]: ./makie.md
[nan]: ./nannou.md
[ma]: ./mathanimation.md
[pen]: ./penrose.md
[blu]: ./bluefish.md
[tik]: ./tikz.md
[asy]: ./asymptote.md
[cet]: ./cetz.md
[met]: ./metapost.md
[rb]: ./rendering-backends/
[rb-cpu]: ./rendering-backends/cpu-vector.md
[rb-gpu]: ./rendering-backends/gpu-vector.md
[mt]: ./math-typesetting.md
[ve]: ./video-encoding.md
[cmp]: ./comparison.md
[cmp-delta]: ./comparison.md#the-delta-table
[base]: ./sparkles-baseline.md
[prop]: ./animation-engine-proposal.md
[ex-bez]: ./examples/bezier-eval.d
[ex-rate]: ./examples/rate-functions.d
[ex-aff]: ./examples/affine-transform.d
[ex-cap]: ./examples/frame-capture.d
[c-mob]: ./concepts.md#mobject-and-the-scene-graph
[c-exec]: ./concepts.md#execution-models
[c-bez]: ./concepts.md#bezier-basis-quadratic-vs-cubic
[c-cpu]: ./concepts.md#cpu-vector-vs-gpu-vector-rendering
[c-latex]: ./concepts.md#latex-to-svg
[c-codec]: ./concepts.md#codec-muxing-and-pixel-format
[c-cache]: ./concepts.md#content-hash-caching
[c-ease]: ./concepts.md#rate-function-and-easing
[c-aff]: ./concepts.md#affine-transform-and-coordinate-space
[c-decl]: ./concepts.md#constraint-and-optimization-based-layout
[c-glyph]: ./concepts.md#glyph-outline-extraction
