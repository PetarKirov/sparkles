# Grounding — index & discrepancy register

> Not published research. Do not link to it from the survey pages.

Internal QA evidence for `docs/research/manim/`. Every deep-dive has a companion
ledger here transcribing its load-bearing claims to a source locator; the source
map is in [`_sources.md`](./_sources.md). This directory is excluded from the
built site (`srcExclude`) and the link checker (`lychee.exclude_path`).

Status legend: ✓ verified against a local artifact · ≈ paraphrase-verified ·
🌐 web-verified (primary source fetched) · ◯ open / not locally groundable
Claim types: quote · fact · figure · behavior · exposition

## Per-page ledgers

| Page                            | Ledger                                           | Grounding        |
| ------------------------------- | ------------------------------------------------ | ---------------- |
| Concepts                        | (claims grounded inline; see the engine ledgers) | —                |
| Manim Community (+ 3 sub-pages) | [manim-community.md](./manim-community.md)       | ✓ `@4d25c031`    |
| ManimGL                         | [manimgl.md](./manimgl.md)                       | ✓ `@e61ad5c3`    |
| Motion Canvas                   | [motion-canvas.md](./motion-canvas.md)           | 🌐               |
| Remotion                        | [remotion.md](./remotion.md)                     | 🌐               |
| Makie.jl                        | [makie.md](./makie.md)                           | 🌐               |
| nannou                          | [nannou.md](./nannou.md)                         | 🌐               |
| Theatre.js                      | [theatre-js.md](./theatre-js.md)                 | 🌐               |
| Javis.jl                        | [javis.md](./javis.md)                           | 🌐               |
| MathAnimation                   | [mathanimation.md](./mathanimation.md)           | ✓/🌐 `@4b2bace5` |
| Penrose                         | [penrose.md](./penrose.md)                       | 🌐 (paper ◯)     |
| Bluefish                        | [bluefish.md](./bluefish.md)                     | 🌐 (one quote ◯) |
| TikZ / PGF                      | [tikz.md](./tikz.md)                             | 🌐               |
| Asymptote                       | [asymptote.md](./asymptote.md)                   | 🌐               |
| CeTZ                            | [cetz.md](./cetz.md)                             | 🌐               |
| MetaPost                        | [metapost.md](./metapost.md)                     | 🌐               |
| Rendering backends              | [rendering-backends.md](./rendering-backends.md) | 🌐               |
| Math typesetting                | [math-typesetting.md](./math-typesetting.md)     | 🌐               |
| Video encoding                  | [video-encoding.md](./video-encoding.md)         | 🌐/✓             |

Synthesis pages (`comparison.md`, `sparkles-baseline.md`,
`animation-engine-proposal.md`, `index.md`) restate claims already grounded in
the deep-dives and the [baseline](../sparkles-baseline.md)'s cited repo files;
they add no new primary claims.

## Master discrepancy register

Load-bearing surprises and corrections found while grounding — either against the
research brief's embedded hypotheses or against a page's own draft. Each row: the
claim as hypothesized, the correction, the source, and whether it is fixed in the
published pages.

| #   | Page               | Claim (as hypothesized)                         | Correction                                                                                                                                                | Source                                      | Fixed?               |
| --- | ------------------ | ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- | -------------------- |
| R1  | manim              | one Bézier basis                                | community-Cairo is **cubic 4-pt** (separate color arrays); ManimGL + community-GL are **quadratic 3-pt** (one structured array)                           | `vectorized_mobject.py` both trees          | ✓                    |
| R2  | manim-community    | OpenGL default                                  | default renderer is **Cairo**; GL is opt-in (`--renderer=opengl`)                                                                                         | `camera.py:15`, `default.cfg:97`            | ✓                    |
| R3  | manim              | one encode path                                 | community = **PyAV** partial-file + content-hash cache; ManimGL = **ffmpeg subprocess** raw-RGBA pipe                                                     | `scene_file_writer.py` both                 | ✓                    |
| R4  | manim-community    | LaTeX only                                      | community also compiles **Typst** in-process (no dvisvgm)                                                                                                 | `typst_file_writing.py:100`                 | ✓                    |
| R5  | manim              | Transform aligns points                         | it aligns submobject **trees AND** point counts before the lerp                                                                                           | `transform.py`, `mobject.py:3149`           | ✓                    |
| R6  | remotion           | MIT                                             | **source-available**: free ≤3 employees / non-profit; paid company license; no redistribution                                                             | `LICENSE.md`                                | ✓                    |
| R7  | motion-canvas      | WebGL                                           | rendering is **Canvas2D per node**; WebGL is shader-effects only                                                                                          | `Node.ts`, `getContext.ts`                  | ✓                    |
| R8  | concepts / probe   | default `smooth` = smootherstep `6t⁵−15t⁴+10t³` | community default `smooth` is a **logistic sigmoid** (`inflection=10`); the quintic is the separate `smootherstep`; **ManimGL**'s `smooth` IS the quintic | `rate_functions.py` both                    | ✓ (probe + concepts) |
| R9  | manimgl            | winding OR triangulation toggle                 | ManimGL fill is **GPU-winding-only**; `use_winding_fill()` is a no-op stub; `get_triangulation`/earclip is vestigial                                      | `vectorized_mobject.py:466,1110`            | ✓                    |
| R10 | manim-community    | moderngl optional                               | `moderngl`/`moderngl-window` are **required** deps (only typst/gui/jupyter are extras)                                                                    | `pyproject.toml:34`                         | ✓                    |
| R11 | manim-community    | class attribute                                 | `n_points_per_cubic_curve = 4` is an `__init__` **param default**, not a class attr                                                                       | `vectorized_mobject.py:129,157`             | ✓                    |
| R12 | manim-community    | `get_sub_alpha` clamps                          | it does **not** clamp at the call site; the `unit_interval` decorator does, one call deeper                                                               | `animation.py:384`, `rate_functions.py:124` | ✓ (probe notes it)   |
| R13 | bluefish           | a constraint solver resolves relations          | Bluefish uses **tree-based LOCAL propagation** and abandoned Cassowary — no global solver (the sharp contrast with Penrose's optimizer)                   | arXiv 2307.00146                            | ✓                    |
| R14 | bluefish           | UIST 2023 "A Relational Framework"              | **UIST '24** "Composing Diagrams with Declarative Relations" (arXiv 2023 preprint "A Relational Grammar of Graphics")                                     | dl.acm.org/10.1145/3654777.3676465          | ✓                    |
| R15 | rendering-backends | resvg is MPL                                    | relicensed to **Apache-2.0 OR MIT** at 0.45.0                                                                                                             | resvg CHANGELOG                             | ✓                    |
| R16 | rendering-backends | Skia license unstated                           | **BSD-3-Clause**                                                                                                                                          | skia.org / GitHub                           | ✓                    |
| R17 | mathanimation      | ffmpeg / mp4                                    | encodes with **SVT-AV1 linked directly**, hand-muxes **IVF**; `.mov` filename mislabels; NVENC path is a 0-byte stub                                      | `Encoder.cpp`, `ExportPanel.cpp`            | ✓                    |
| R18 | mathanimation      | OSI license                                     | **custom no-redistribution EULA** (Aseprite-derived) — ideas reusable, code not                                                                           | `EULA.txt`                                  | ✓                    |
| R19 | math-typesetting   | KaTeX → SVG                                     | KaTeX outputs **HTML/MathML only** (no whole-formula SVG) → web-overlay, not morphable outlines                                                           | katex.org/docs/options                      | ✓                    |
| R20 | math-typesetting   | MicroTeX has wasm                               | wasm is **TODO, not shipped**; MicroTeX is **C++** (needs an `extern "C"` wrapper)                                                                        | MicroTeX README                             | ✓                    |
| R21 | nannou             | steady wgpu engine                              | **0.20 (2026) is a ground-up Bevy rewrite**; ≤0.19 was direct-wgpu; sporadic cadence                                                                      | guide changelog                             | ✓                    |
| R22 | javis              | active                                          | **dormant** (v0.9.0, 2022; pins Luxor 2.12/3, can't co-install with Luxor v4)                                                                             | GitHub releases                             | ✓                    |
| R23 | cetz               | "Zeichenprogramm"                               | README says "ein Typst **Zeichenpaket**"                                                                                                                  | cetz README                                 | ✓                    |
| R24 | theatre-js         | MIT                                             | **Apache-2.0** (core) / **AGPL-3.0-only** (studio)                                                                                                        | repo + package LICENSEs                     | ✓                    |
| R25 | penrose            | paper abstract verbatim                         | ACM DOI 403 + PDF undecodable this session; grounded via CMU PDF text-extract + siggraph20 HTML                                                           | penrose.cs.cmu.edu                          | ◯ open               |
| R26 | bluefish           | "compound graph" quote verbatim                 | arXiv HTML returned a paraphrase-equivalent sentence; wording unconfirmed                                                                                 | arXiv 2307.00146                            | ◯ open               |
| R27 | manimgl            | README quote at line 14                         | actually line **15** in the pinned tree (text verbatim)                                                                                                   | `README.md:15`                              | ✓ (ledger)           |

Rows R1–R7 correspond to the brief's original hypotheses; R8–R27 are surprises
found during writing. The two ◯ rows are cite-by-name against a fetchable proxy;
neither changes a published claim.
