# Sources — local artifacts & pinned references

> Not published research. Do not link to it from the survey pages.

The source map for the `docs/research/manim/` catalog. `$REPOS = /home/petar/code/repos`.

Two grounding modes are used, and each deep-dive states which:

- **✓ local** — the two Manim forks are cloned locally and cited by
  `file:line` at a pinned commit.
- **🌐 web** — every other system is grounded against its official docs and
  pinned GitHub source (and, where relevant, a paper), cited by URL in the
  page's own `Sources` section. This pass did **not** stage papers under
  `$REPOS/papers/manim/`; the paper URLs live in the deep-dives.

## Local source repos (pinned to the reviewed HEAD)

| Repo                  | Path                            | Pinned commit              | As of      |
| --------------------- | ------------------------------- | -------------------------- | ---------- |
| ManimGL (3Blue1Brown) | `$REPOS/python/manim`           | `e61ad5c3` (manimgl 1.7.2) | 2026-07-11 |
| Manim Community       | `$REPOS/python/manim-community` | `4d25c031` (v0.20.1)       | 2026-07-11 |

## Web-grounded systems (pinned version / commit as cited)

| System           | Repo / docs                           | Version or commit                    | License                               |
| ---------------- | ------------------------------------- | ------------------------------------ | ------------------------------------- |
| Motion Canvas    | `motion-canvas/motion-canvas`         | v3.17.2 (2024-12-14)                 | MIT                                   |
| Remotion         | `remotion-dev/remotion`               | v4.0.488 (2026-07-11)                | source-available (company license)    |
| Theatre.js       | `theatre-js/theatre`                  | v0.7.2 (2024-05-19)                  | Apache-2.0 (core) / AGPL-3.0 (studio) |
| Javis.jl         | `JuliaAnimators/Javis.jl`             | v0.9.0 (2022-05-26, dormant)         | MIT                                   |
| Luxor.jl         | `JuliaGraphics/Luxor.jl`              | v4.5.0 (2026-04-09)                  | MIT                                   |
| Makie.jl         | `MakieOrg/Makie.jl`                   | v0.24.13 (2026-07-07)                | MIT                                   |
| nannou           | `nannou-org/nannou`                   | 0.20.0 (2026-06, Bevy rewrite)       | MIT/Apache-2.0                        |
| MathAnimation    | `ambrosiogabe/MathAnimation`          | `4b2bace5` (2024-02-03)              | custom no-redistribution EULA         |
| Penrose          | `penrose/penrose`                     | v3.3.0 (2025-09-28); SIGGRAPH 2020   | MIT                                   |
| Bluefish         | `bluefishjs/bluefish`                 | v0.0.39; UIST '24 / arXiv 2307.00146 | MIT                                   |
| TikZ / PGF       | `pgf-tikz/pgf`                        | 3.1.11a (2025-08-29)                 | GPL / LPPL                            |
| Asymptote        | `vectorgraphics/asymptote`            | 3.13-36 / 3.09                       | LGPLv3 (GPLv3 win binary)             |
| CeTZ             | `cetz-package/cetz`                   | v0.5.2 (2026-05-06)                  | LGPL-3.0-or-later                     |
| Typst            | `typst/typst`                         | v0.15.0 (2026-06-15)                 | Apache-2.0                            |
| MetaPost         | TeX Live `mplibdir/mp.w`; Hobby mpman | 3.00                                 | LGPL                                  |
| Cairo            | cairographics.org                     | 1.18.4 (2025-03-08)                  | LGPL-2.1 / MPL-1.1                    |
| Blend2D          | `blend2d/blend2d`                     | untagged (pin commit)                | Zlib                                  |
| resvg            | `RazrFalcon/resvg`                    | 0.47.0 (2026-02-10)                  | Apache-2.0 OR MIT (was MPL ≤0.44)     |
| Vello            | `linebender/vello`                    | 0.9.0 (alpha)                        | Apache-2.0 OR MIT                     |
| Lyon             | `nical/lyon`                          | 1.0.19                               | MIT OR Apache-2.0                     |
| NanoVG           | `memononen/nanovg`                    | untagged (pin commit)                | Zlib                                  |
| raylib           | `raysan5/raylib`                      | 6.0 (2026-04-23)                     | zlib/libpng                           |
| Skia             | `google/skia`                         | rolling                              | BSD-3-Clause                          |
| skia-pathops     | `fonttools/skia-pathops`              | 0.9.2 (2026-02-16)                   | BSD-3-Clause                          |
| dvisvgm          | dvisvgm.de                            | 3.6 (2025-12-08)                     | GPL-3.0+                              |
| MathJax          | `mathjax/MathJax-src`                 | v4.1.3 (2026-07-03)                  | Apache-2.0                            |
| KaTeX            | `KaTeX/KaTeX`                         | v0.17.0 (2026-05-22)                 | MIT                                   |
| MicroTeX         | `NanoMichael/MicroTeX`                | untagged (2024-08 master)            | MIT                                   |
| HarfBuzz         | `harfbuzz/harfbuzz`                   | 14.2.1 (2026-06-02)                  | "Old MIT"                             |
| ffmpeg / libav\* | ffmpeg.org                            | n8.1                                 | LGPL-2.1+ (GPL with GPL codecs)       |
| PyAV             | `PyAV-Org/PyAV`                       | v18.0.0                              | BSD-3-Clause                          |
| GStreamer        | gstreamer.freedesktop.org             | 1.26.11 (2026-03)                    | LGPL                                  |
| SVT-AV1          | gitlab AOMedia SVT-AV1                | v4.1.0                               | BSD-3-Clause-Clear                    |

## Experiment environment (the runnable probes)

The four `examples/*.d` probes are dependency-free and were compiled/run with
LDC 1.41 on Linux 6.18.26 (x86_64), and pass under `ci --example-files` (4/4).
They ground the geometry/timing claims independently of any surveyed engine.

## Open / not locally verifiable (see `index.md` register)

- Penrose SIGGRAPH 2020 abstract — ACM DOI returns 403; grounded via the CMU
  PDF text-extract + `penrose.cs.cmu.edu/siggraph20` HTML (R25).
- Bluefish "compound graph" quote — arXiv HTML returned a paraphrase-equivalent
  sentence; wording not confirmed verbatim (R26).
