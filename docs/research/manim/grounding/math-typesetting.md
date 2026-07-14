# Grounding: Math Typesetting (notation → vector outlines)

> Not published research. Do not link to it from the survey pages.

Status legend: ✓ verified against a local artifact · ≈ paraphrase-verified · 🌐 web-verified (primary source fetched) · ◯ open
Claim types: quote · fact · figure · behavior · exposition

Grounds [`docs/research/manim/math-typesetting.md`](../math-typesetting.md) — six
pipelines (LaTeX→dvisvgm, MathJax, KaTeX, MicroTeX, Typst, HarfBuzz/Pango).
Per-system license + version + D-binding verdict are `fact` rows. Internal QA,
excluded from the built site (`srcExclude`) and the link checker.

**Corrections recorded by the page (flagged):** KaTeX has **no whole-formula SVG
output mode** — HTML+MathML only, inline SVG for a few stretchy constructs
(C-katex-2); MicroTeX **wasm is on the TODO list, not shipped**, and it is C++
(not C) so it needs an `extern "C"` shim (C-microtex-2).

## LaTeX → dvisvgm

| #           | Claim (short)                                                                                                                                                                                  | Type  | Source (locator)                                                                                                      | Status |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | --------------------------------------------------------------------------------------------------------------------- | ------ |
| Q-dvisvgm-1 | dvisvgm "converts DVI, EPS, and PDF files to the XML-based vector graphics format SVG"                                                                                                         | quote | https://dvisvgm.de/                                                                                                   | 🌐     |
| Q-dvisvgm-2 | `--no-fonts`: "If this option is given, dvisvgm doesn't create SVG font elements but uses paths instead." (default emits `<font>…</font>` embedding font data)                                 | quote | https://dvisvgm.de/Manpage/                                                                                           | 🌐     |
| C-dvisvgm-1 | License LPPL (TeX) · GPL-3 (dvisvgm); output SVG `<path>` outlines with `--no-fonts`; **not** in-process (2–3 subprocesses/expr); needs a TeX install (mandatory, heavy)                       | fact  | https://github.com/mgieseki/dvisvgm                                                                                   | 🌐     |
| C-dvisvgm-2 | Manim Community's `convert_to_svg` builds the `dvisvgm … --no-fonts …` command unconditionally; sibling `compile_tex` shells to `latex`/`xelatex` with `-interaction=batchmode -halt-on-error` | fact  | https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/utils/tex_file_writing.py | 🌐     |
| C-dvisvgm-3 | D-binding: trivial subprocess orchestration, no FFI (spawn latex, spawn dvisvgm, parse SVG); deterministic only when the toolchain is pinned (a Nix closure makes it a viable oracle)          | fact  | survey exposition                                                                                                     | ◯      |
| C-dvisvgm-4 | `MathAnimation` inherits this pipeline — hard-codes a MiKTeX search on PATH and runs the identical `latex` → `dvisvgm -n` two-step                                                             | fact  | survey exposition (MathAnimation) — no single locator                                                                 | ◯      |

## MathJax

| #           | Claim (short)                                                                                                                                                                                                            | Type  | Source (locator)                       | Status |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- | -------------------------------------- | ------ |
| Q-mathjax-1 | "open-source JavaScript display engine for LaTeX, MathML, and AsciiMath notation that works in all modern browsers."                                                                                                     | quote | https://github.com/mathjax/MathJax-src | 🌐     |
| C-mathjax-1 | License Apache-2.0; language JavaScript; SVG output (via `tex2svg`/`tex2svgPromise`) gives extractable paths; CHTML output (`tex-mml-chtml.js`) is DOM, not useful for outlines; MathML also emitted                     | fact  | https://www.mathjax.org/               | 🌐     |
| C-mathjax-2 | In-process only within a JS runtime; for a native (D) host = embed Node; no TeX install; deterministic given pinned version+fonts                                                                                        | fact  | https://github.com/mathjax/MathJax-src | 🌐     |
| C-mathjax-3 | D-binding: poor as a library (no C ABI) — bind by driving Node, effectively a subprocess like dvisvgm but with no TeX to provision. Users: Penrose (in-page), Javis (`mathjax-node-cli`), Motion Canvas (`mathjax-full`) | fact  | survey exposition                      | ◯      |

## KaTeX

| #         | Claim (short)                                                                                                                                                                                                                               | Type  | Source (locator)                    | Status |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ----------------------------------- | ------ |
| Q-katex-1 | "a fast, easy-to-use JavaScript library for TeX math rendering on the web"                                                                                                                                                                  | quote | https://github.com/KaTeX/KaTeX      | 🌐     |
| Q-katex-2 | Design bullets: "KaTeX renders its math synchronously and doesn't need to reflow the page"; layout "based on Donald Knuth's TeX, the gold standard"; "no dependencies and can easily be bundled"                                            | quote | https://github.com/KaTeX/KaTeX      | 🌐     |
| Q-katex-3 | `output` option: "Determines the markup language of the output. The valid choices are: `html`, `mathml`, `htmlAndMathml`."                                                                                                                  | quote | https://katex.org/docs/options.html | 🌐     |
| C-katex-1 | License MIT; JavaScript; synchronous render; no TeX; fully deterministic layout                                                                                                                                                             | fact  | https://github.com/KaTeX/KaTeX      | 🌐     |
| C-katex-2 | **Correction:** no whole-formula SVG mode — paints with HTML+CSS boxes (+ MathML), inline SVG only for a few stretchy constructs (delimiters, radicals, arrows); a poor fit for a `VMobject` outline pipeline, a good fit for HTML overlays | fact  | https://katex.org/docs/options.html | 🌐     |
| C-katex-3 | D-binding: same as MathJax — no C ABI, drive Node; best reserved for the web/DOM path                                                                                                                                                       | fact  | survey exposition                   | ◯      |

## MicroTeX

| #            | Claim (short)                                                                                                                                                                                                                                                                                                                  | Type  | Source (locator)                                                                    | Status |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- | ----------------------------------------------------------------------------------- | ------ |
| Q-microtex-1 | "a dynamic, cross-platform, and embeddable LaTeX rendering library" whose "main purpose is to display mathematical formulas written in LaTeX."                                                                                                                                                                                 | quote | https://github.com/NanoMichael/MicroTeX                                             | 🌐     |
| C-microtex-1 | License **MIT** (fonts/XML in `res/` carry own licenses); C++; in-process (no subprocess, no TeX, no Node); parses LaTeX into `TeXRender`, draws via an abstract `Graphics2D` the host implements                                                                                                                              | fact  | https://github.com/NanoMichael/MicroTeX                                             | 🌐     |
| C-microtex-2 | **Corrections:** wasm is on the project's TODO list, **not shipped**; being C++ it needs an `extern "C"` shim then D `extern(C)` — a fallback, not the primary. Original repo quiescent (last commit ~Aug 2024); `cLaTeXMath` is the same author's Cairo continuation (MIT); active forks `Xrysnow/MicroTeX`, `swift-microtex` | fact  | https://github.com/NanoMichael/MicroTeX · https://github.com/NanoMichael/cLaTeXMath | 🌐     |

## Typst

| #         | Claim (short)                                                                                                                                                                    | Type  | Source (locator)                           | Status |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ------------------------------------------ | ------ |
| Q-typst-1 | "Typst is a new markup-based typesetting system that is designed to be as powerful as LaTeX while being much easier to learn and use."                                           | quote | https://github.com/typst/typst             | 🌐     |
| Q-typst-2 | "Typst has special syntax and library functions to typeset mathematical formulas" (math is built-in, not a package)                                                              | quote | https://typst.app/docs/reference/math/     | 🌐     |
| C-typst-1 | License Apache-2.0; Rust library + CLI; in-process; no TeX; exports PDF/SVG/PNG (dedicated export sections); SVG feeds the same VMobject parser as dvisvgm                       | fact  | https://typst.app/docs/reference/          | 🌐     |
| C-typst-2 | Web/wasm: pure-Rust compiler compiles to WebAssembly; official web app + `typst.ts` ship wasm binaries that compile Typst→SVG in-browser — one engine for native FFI and web     | fact  | https://github.com/Myriad-Dreamin/typst.ts | 🌐     |
| C-typst-3 | Cost: Typst's own math markup, **not** LaTeX (`amsmath`-heavy content is a rewrite); D-binding via `#[no_mangle] extern "C"` Rust shim → D `extern(C)`, or drive the `typst` CLI | fact  | https://typst.app/docs/reference/math/     | 🌐     |

## MathML + HarfBuzz / Pango (font-level shaping)

| #      | Claim (short)                                                                                                                                                                                                                                   | Type  | Source (locator)                                                                                    | Status |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | --------------------------------------------------------------------------------------------------- | ------ |
| Q-hb-1 | "Using the HarfBuzz library allows programs to convert a sequence of Unicode input into properly formatted and positioned glyph output — for any writing system and language."                                                                  | quote | https://harfbuzz.github.io/                                                                         | 🌐     |
| Q-hb-2 | HarfBuzz "Old MIT" license: "Permission is hereby granted, without written agreement and without license or royalty fees, to use, copy, modify, and distribute this software and its documentation for any purpose…"                            | quote | https://github.com/harfbuzz/harfbuzz/blob/907579859f604633ad511f2f49fa0299d799d9b8/COPYING          | 🌐     |
| C-hb-1 | OpenType MATH table exposed via `hb-ot-math.h`: `hb_ot_math_has_data`, `hb_ot_math_get_constant`, `hb_ot_math_get_glyph_italics_correction`, `hb_ot_math_get_glyph_variants`, `hb_ot_math_get_glyph_assembly` — primitives, not a layout engine | fact  | https://github.com/harfbuzz/harfbuzz/blob/907579859f604633ad511f2f49fa0299d799d9b8/src/hb-ot-math.h | 🌐     |
| C-hb-2 | Licenses: HarfBuzz "Old MIT", Pango LGPL-2.1, FreeType dual FTL/GPL-2; all C libraries with stable C ABIs → ImportC/`extern(C)`, no C++ shim; `harfbuzzjs` wasm build for web                                                                   | fact  | https://github.com/harfbuzz/harfbuzz/blob/907579859f604633ad511f2f49fa0299d799d9b8/COPYING          | 🌐     |
| C-hb-3 | Manim uses this layer for **non-math** text via `manimpango` (drives HarfBuzz through Pango); FreeType extracts outlines — TrueType quadratic, CFF/OpenType cubic. A construction kit: you write the math layout                                | fact  | survey exposition                                                                                   | ◯      |

## Cluster-level

| #           | Claim (short)                                                                                                                                                                                                        | Type       | Source (locator) | Status |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ---------------- | ------ |
| C-cluster-1 | Recommendation: LaTeX→dvisvgm (Nix-pinned) for reproducible video math; HarfBuzz+FreeType in-process for non-math text; MicroTeX behind `extern "C"` as TeX-free fallback; Typst (native+wasm) / KaTeX (DOM) for web | exposition | page synthesis   | ◯      |
