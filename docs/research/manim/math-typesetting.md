# Math Typesetting (notation → vector outlines)

How mathematical notation becomes the vector outlines a `VMobject` can morph — the
pipelines a Manim-class engine chooses between, and the one trade every choice comes
down to: **reuse a real TeX stack, or reimplement it.**

This is the building-block cluster for **axis 4 — typesetting & text** of the
[survey's eight axes](./concepts.md), and it answers that axis in full: every deep-dive
in the catalog defers its "how does math become geometry" question here. It also touches
**axis 1 — object & scene model**, because the output of a math pipeline is not a picture
but a set of glyph contours that become a [`VMobject`](./concepts.md#vmobject-and-vector-geometry)
the scene graph animates. The two concepts that anchor this page —
[LaTeX to SVG](./concepts.md#latex-to-svg) and
[glyph-outline extraction](./concepts.md#glyph-outline-extraction) — are the two ends of
the design space: shell out to a document typesetter and scrape its vector output, or
pull glyph contours from a font in-process and lay them out yourself. Everything below
sits on that spectrum.

**Last reviewed:** July 11, 2026

> [!NOTE]
> **Scope.** This page surveys the _math notation → vector outline_ step only. Where a
> pipeline emits [SVG paths](./concepts.md#latex-to-svg), those paths still have to be
> parsed and rebuilt as [`VMobject`](./concepts.md#vmobject-and-vector-geometry) geometry
> (the [text-pipeline](./concepts.md#glyph-outline-extraction) step) and then
> [rasterised](./concepts.md#rasterization) — those are downstream axis-1/axis-3 concerns.
> Plain (non-math) text shaping is covered under [HarfBuzz + Pango](#mathml-with-harfbuzz-and-pango).

---

## The pipelines at a glance

Six systems, grouped by the fundamental split — **subprocess to a TeX-family typesetter**
(`dvisvgm`), **in-process JS math engine** (MathJax, KaTeX), **in-process native library
with no TeX** (MicroTeX, Typst), and **font-level shaping** (HarfBuzz + the OpenType MATH
table). Each row links to its section.

| System                                                       | Language   | License                         | Output                                | In-process?                   | Needs TeX install? | Web/wasm?                        | Used by                                             |
| ------------------------------------------------------------ | ---------- | ------------------------------- | ------------------------------------- | ----------------------------- | ------------------ | -------------------------------- | --------------------------------------------------- |
| [LaTeX → `dvisvgm`](#latex-to-svg-via-dvisvgm)               | TeX + C++  | LPPL (TeX) · GPL-3 (`dvisvgm`)  | **SVG paths** (`--no-fonts`)          | **No** — subprocess           | **Yes**            | No (native subprocess)           | Manim (both forks), `MathAnimation`, TikZ authoring |
| [MathJax](#mathjax)                                          | JavaScript | Apache-2.0                      | **SVG** or CHTML (+ MathML)           | JS runtime (Node subprocess)  | No                 | **Yes** (browser JS)             | Penrose, Motion Canvas, Javis                       |
| [KaTeX](#katex)                                              | JavaScript | MIT                             | HTML + MathML (inline SVG for a few)  | JS runtime (Node subprocess)  | No                 | **Yes** (browser JS)             | Remotion / web overlays, docs sites                 |
| [MicroTeX](#microtex)                                        | **C++**    | MIT                             | `Graphics2D` draw calls / paths       | **Yes** (embeddable library)  | No                 | wasm on the TODO list            | KLatexFormula-class apps, `swift-microtex`          |
| [Typst](#typst)                                              | Rust       | Apache-2.0                      | **PDF / SVG / PNG**                   | **Yes** (Rust library or CLI) | No                 | **Yes** (wasm; official web app) | Typst web app, modern Luxor `v4`                    |
| [MathML + HarfBuzz / Pango](#mathml-with-harfbuzz-and-pango) | C / C++    | Old MIT (HB) · LGPL-2.1 (Pango) | positioned glyphs → FreeType outlines | **Yes** (C library)           | No                 | **Yes** (`harfbuzzjs` wasm)      | Manim non-math text (`manimpango`)                  |

> [!NOTE]
> **"In-process" is per host language.** MathJax and KaTeX are _in-process_ inside a
> JavaScript runtime, but for a D (or Julia, or C++) host they are reached by launching
> Node — Javis literally shells out to a `tex2svg` CLI. The genuinely embeddable
> no-TeX options for a native engine are **MicroTeX** (C++, so a C-ABI shim) and
> **Typst** (Rust, so a C-ABI shim or its wasm build).

---

## LaTeX to SVG via `dvisvgm`

The classic, and the one both Manim forks use: compile LaTeX to a device file
(`dvi` from `latex`, `xdv` from `xelatex`, or `pdf` from `lualatex`/`pdflatex`), then
convert that file to SVG with **`dvisvgm`**, parse the SVG `<path>` data, and rebuild a
[`VMobject`](./concepts.md#vmobject-and-vector-geometry). This is exactly the
[LaTeX-to-SVG concept](./concepts.md#latex-to-svg); the point of the pipeline is that the
final artifact is _vector paths_, not a bitmap or a font reference.

`dvisvgm` is a C++ tool whose own homepage states its job plainly — it
["converts DVI, EPS, and PDF files to the XML-based vector graphics format SVG"][dvisvgm]
— and the flag that makes it a _math-outline_ tool rather than a font-embedding tool is
`--no-fonts`. Its [manual][dvisvgm-man] is explicit:

> _"If this option is given, dvisvgm doesn't create SVG font elements but uses paths
> instead."_

Without it, `dvisvgm` emits `<font>…</font>` elements (["it creates font elements
(`<font>`…`</font>`) to embed the font data into the SVG files"][dvisvgm-man]) that most
renderers — and every animation engine that wants morphable contours — cannot use. Manim
Community therefore passes it unconditionally: the [`convert_to_svg` helper][manim-tex]
builds the command

```python
command = [
    "dvisvgm",
    *(["--pdf"] if extension == ".pdf" else []),
    f"--page={page}",
    "--no-fonts",
    "--verbosity=0",
    f"--output={result.as_posix()}",
    f"{dvi_file.as_posix()}",
]
```

and the sibling [`compile_tex`][manim-tex] function shells out to `latex`/`xelatex` with
`-interaction=batchmode -halt-on-error` first. Three external binaries end up on `PATH`
(a TeX engine, `dvisvgm`, and later `ffmpeg`); the first render of any expression is slow,
which is why the result is [content-hash cached](./concepts.md#content-hash-caching) to disk.

- **Input syntax:** full LaTeX (arbitrary preamble, packages, `amsmath`, TikZ, …). The
  ceiling is "whatever the installed TeX distribution can compile" — the widest coverage
  of any system here.
- **Output:** SVG `<path>` outlines — glyph contours already flattened to Bézier data, so
  the [basis](./concepts.md#bezier-basis-quadratic-vs-cubic) is whatever the font carried,
  normalised on import.
- **In-process?** No. Two-to-three subprocesses per expression. From a D engine this is a
  process-spawn + tempfile dance, not a library call.
- **TeX dependency:** mandatory, and heavy (a full TeX Live / MiKTeX). This is the pipeline's
  defining cost.
- **Determinism:** deterministic _when the toolchain is pinned_. TeX + `dvisvgm` are
  reproducible given fixed binaries and fonts, which is why a Nix-pinned closure makes this
  a viable [deterministic-frame-sampling](./concepts.md#deterministic-frame-sampling) oracle;
  an unpinned system TeX is a reproducibility hazard.
- **D-bindability:** trivial and ugly — it is subprocess orchestration, no FFI. The
  binding surface is "spawn `latex`, spawn `dvisvgm`, parse SVG". No C ABI to wrap.

> [!WARNING]
> **The dependency is the product.** The strength (arbitrary LaTeX, exact TeX output) and
> the weakness (three external binaries, cold-start latency, a multi-hundred-MB TeX
> install, Windows path assumptions) are the same fact. `MathAnimation` inherits precisely
> this — it hard-codes a search for **MiKTeX** on `PATH` and runs the identical
> `latex` → `dvisvgm -n` two-step.

---

## MathJax

**MathJax** is the in-browser workhorse, and the most common _TeX-free-yet-LaTeX-syntax_
choice among the JS-based engines in this survey. Its repository describes it as an

> _"open-source JavaScript display engine for LaTeX, MathML, and AsciiMath notation that
> works in all modern browsers."_ — [`mathjax/MathJax-src`][mathjax-repo]

The load-bearing feature for an animation engine is that MathJax v3/v4 can produce **SVG**
output (via its `tex2svg` / `tex2svgPromise` conversion functions), not just on-screen
HTML — so its glyphs come back as real vector paths that can be scraped into a
[`VMobject`](./concepts.md#vmobject-and-vector-geometry), the same way `dvisvgm` output is.
Its alternate output, **CHTML** (CommonHTML, shipped as `tex-mml-chtml.js`), lays out with
HTML+CSS and is _not_ useful for outline extraction.

- **Input syntax:** a large subset of LaTeX math, plus MathML and AsciiMath — three input
  jacks into one layout engine.
- **Output:** SVG (extractable paths) **or** CHTML (DOM); MathML is also emitted for
  accessibility. Choose SVG for a rendering pipeline.
- **In-process?** In-process _within JavaScript_. For a browser engine that is native; for
  a native (D/Julia) host it means embedding Node — Penrose runs it in-page, Javis shells
  out to a `tex2svg` Node CLI (`mathjax-node-cli`), Motion Canvas imports `mathjax-full`.
- **TeX dependency:** none. This is the whole appeal — LaTeX _syntax_ without a TeX
  _install_.
- **Determinism:** deterministic given a pinned MathJax version and fonts (it is pure JS,
  no floating-point rasterisation at the SVG stage), but coverage is "MathJax's LaTeX",
  not "whatever TeX Live compiles".
- **D-bindability:** poor as a library — there is no C ABI; you bind it by driving Node.
  Effectively a subprocess, like `dvisvgm`, but with no TeX install to provision.

> [!NOTE]
> **Who leans on it:** Penrose converts all diagram labels to SVG with MathJax; Motion
> Canvas's `Latex` node imports `mathjax-full` in-process; Javis's `latex()` routes
> `LaTeXString`s through `mathjax-node-cli`. All three deliberately trade the
> `latex` + `dvisvgm` toolchain for "no TeX, ship a JS engine instead."

---

## KaTeX

**KaTeX** is the speed play: the fastest web math shaper, MIT-licensed, and synchronous.
Its README defines it as

> _"a fast, easy-to-use JavaScript library for TeX math rendering on the web,"_ —
> [`KaTeX/KaTeX`][katex-repo]

with three design bullets that matter here: **Fast** (_"KaTeX renders its math
synchronously and doesn't need to reflow the page"_), **Print quality** (_"KaTeX's layout
is based on Donald Knuth's TeX, the gold standard for math typesetting"_), and **Self
contained** (_"KaTeX has no dependencies and can easily be bundled"_). The synchronous
render is the differentiator against MathJax's async layout — it matters for a per-frame
web overlay.

The catch for an outline-extraction pipeline is the **output format**. KaTeX's
[`output` option][katex-opts] is documented as:

> _"Determines the markup language of the output. The valid choices are: `html`, `mathml`,
> `htmlAndMathml`."_

There is **no whole-formula SVG output mode**: KaTeX paints with HTML + CSS boxes (plus a
MathML tree for accessibility) and only emits _inline_ SVG for a handful of stretchy
constructs (extensible delimiters, square-root radicals, long arrows). That is enough to
render into a DOM, but it does **not** hand you glyph contours the way `dvisvgm` or MathJax's
`tex2svg` do — so KaTeX is a poor fit for a `VMobject` pipeline and a great fit for a web
overlay that composites HTML on top of video.

- **Input syntax:** a well-defined LaTeX-math subset (smaller than MathJax's, by design).
- **Output:** HTML + MathML; **not** extractable outlines. Web-DOM only.
- **In-process?** In-process in JS; the same Node-embedding caveat as MathJax for a native host.
- **TeX dependency:** none.
- **Determinism:** fully deterministic (pure synchronous layout), but the output is boxes,
  not vectors — determinism of _pixels_ then depends on the browser's font rasteriser, not
  on KaTeX.
- **D-bindability:** same as MathJax — no C ABI; drive Node. Best reserved for the web path.

---

## MicroTeX

**MicroTeX** is the one system here that renders LaTeX math to vector geometry **in a
native library, with no TeX install and no browser**. Its README calls it

> _"a dynamic, cross-platform, and embeddable LaTeX rendering library"_ —
> [`NanoMichael/MicroTeX`][microtex-repo]

whose "main purpose is to display mathematical formulas written in LaTeX." Crucially, it
does not shell out to TeX: it parses LaTeX directly into a paintable object (`TeXRender`)
and draws it through an abstract **`Graphics2D`** interface that the host implements — the
same abstraction FreeType-based engines use for [glyph-outline
extraction](./concepts.md#glyph-outline-extraction). That is the mechanism that lets it
target "Android, iOS, Windows, Linux GTK, Qt…" without a document typesetter anywhere in
the loop.

- **Input syntax:** a LaTeX-math subset implemented in C++ (its own parser + font metrics),
  independent of any TeX distribution.
- **Output:** calls into a `Graphics2D` context — `drawLine`, `drawChar`, `fillRect`,
  glyph paths — which the host can capture as [Bézier
  contours](./concepts.md#bezier-basis-quadratic-vs-cubic) for a `VMobject` instead of
  rasterising immediately.
- **In-process?** **Yes.** This is the distinguishing property: a single C++ library call,
  no subprocess, no TeX, no Node.
- **TeX dependency:** none — the strongest "TeX-free" story of the LaTeX-syntax systems.
- **Determinism:** deterministic in-process layout; the host controls rasterisation, so the
  determinism story is the host's, not a subprocess's.
- **D-bindability:** the caveat is the language. MicroTeX is **C++**, not C, so D cannot
  bind it directly — it needs an `extern "C"` wrapper (a thin C shim exposing "parse →
  `TeXRender` → walk the paths"), then D `extern(C)` declarations over that shim. That is
  the same shape as the repo's [`ghostty` ImportC integration](./concepts.md#glyph-outline-extraction),
  and the reason MicroTeX is a _fallback_ rather than the primary in the recommendation below.

> [!NOTE]
> **License and maintenance.** MicroTeX is **MIT** — its README states the project "is
> under the MIT license" (fonts and XML resources in `res/` carry their own licenses). The
> original `NanoMichael/MicroTeX` is quiescent (its last commit and its successor share an
> August 2024 date); the same author's [`cLaTeXMath`][clatexmath] is a Cairo-graphics
> continuation with the identical description and MIT terms, and there are active third-party
> forks (`Xrysnow/MicroTeX`, the `swift-microtex` wrapper). A consumer should pin whichever
> fork it vendors. wasm is on the project's own TODO list, not shipped.

---

## Typst

**Typst** is the newest and arguably strongest _self-contained_ candidate: a Rust
typesetting system with native math, no TeX anywhere, and a first-class **SVG** export.
Its README positions it directly against LaTeX —

> _"Typst is a new markup-based typesetting system that is designed to be as powerful as
> LaTeX while being much easier to learn and use."_ — [`typst/typst`][typst-repo]

Math is a built-in feature, not a package: the [math reference][typst-math] states that
_"Typst has special syntax and library functions to typeset mathematical formulas,"_ and
the compiler exports to **PDF, SVG, and PNG** (the [reference][typst-ref] carries dedicated
`pdf`, `svg`, and `png` export sections). SVG export is what makes it a real
[`VMobject`](./concepts.md#vmobject-and-vector-geometry) source — the same "typeset →
scrape SVG paths" shape as `dvisvgm`, but from a single self-contained binary.

- **Input syntax:** Typst's own math markup — powerful but **not** LaTeX. `$x^2/2$`,
  `$sum_(i=0)^n$`, function-call-without-`#` in math mode. Porting `amsmath`-heavy content
  is a rewrite, not a copy-paste. This is the one real ergonomic cost versus the LaTeX-syntax
  engines.
- **Output:** PDF / SVG / PNG. Choose SVG for outline extraction, PNG for a rasterised frame.
- **In-process?** **Yes** — Typst is a Rust library (and a CLI). No subprocess needed if you
  link it; a subprocess (`typst compile`) if you don't.
- **TeX dependency:** none. Self-contained down to a bundled font stack.
- **Determinism:** deterministic and fast (incremental compilation); a pinned Typst version
  is a clean reproducibility unit.
- **Web/wasm:** **yes.** The compiler is pure Rust and compiles to WebAssembly — the
  official web app runs it, and the ecosystem's [`typst.ts`][typstts] ships wasm binaries
  that compile Typst to SVG entirely in the browser. This makes Typst a single engine that
  serves _both_ the native path (Rust FFI) and the web path (wasm), which none of the other
  no-TeX options do.
- **D-bindability:** Rust with a stable-enough crate API; bind via a `#[no_mangle] extern "C"`
  Rust shim → D `extern(C)`, or drive the `typst` CLI as a subprocess. Same C-ABI-shim shape
  as MicroTeX, but with wasm as a bonus target.

---

## MathML with HarfBuzz and Pango

The last option is not a math engine at all but the **font-level shaping layer** every
other pipeline eventually sits on — and the path Manim already uses for _non-math_ text.
**MathML** is the semantic interchange format (a `<math>` tree of `<mrow>`/`<mi>`/`<mo>`
elements that MathJax, KaTeX, and browsers all speak); **HarfBuzz** is the shaper that turns
a run of characters plus a font into positioned glyphs. HarfBuzz's manual defines the job:

> _"Using the HarfBuzz library allows programs to convert a sequence of Unicode input into
> properly formatted and positioned glyph output — for any writing system and language."_ —
> [HarfBuzz manual][harfbuzz]

This is exactly the [text-shaping concept](./concepts.md#text-shaping): shaping decides
_which_ glyphs go _where_; then [glyph-outline extraction](./concepts.md#glyph-outline-extraction)
(via **FreeType**) pulls each glyph's contours — TrueType outlines being
[quadratic](./concepts.md#bezier-basis-quadratic-vs-cubic), CFF/OpenType cubic — into a
`VMobject`. Manim reaches this layer through **`manimpango`**, which drives HarfBuzz via
**Pango** for all of its plain-text (non-`Tex`) rendering.

For _math specifically_, HarfBuzz exposes the **OpenType MATH table** through its
[`hb-ot-math.h`][hb-math] API — `hb_ot_math_has_data`, `hb_ot_math_get_constant`,
`hb_ot_math_get_glyph_italics_correction`, `hb_ot_math_get_glyph_variants`,
`hb_ot_math_get_glyph_assembly`, and friends — the primitives a from-scratch math layout
engine needs (stretchy delimiters, script positioning, radical construction). HarfBuzz does
_not_ lay out a formula for you; it hands you the MATH-table data with which you could.

- **Input syntax:** MathML (semantic tree) for structure; a math font with a MATH table for
  metrics. Building a formula is _your_ layout algorithm over these primitives.
- **Output:** positioned glyph IDs (HarfBuzz) → contour outlines (FreeType). The most
  low-level, most controllable output in the survey.
- **In-process?** **Yes** — C libraries, directly linkable.
- **TeX dependency:** none.
- **Determinism:** fully deterministic; shaping and outline extraction are pure functions of
  (text, font, features).
- **D-bindability:** **best of the set.** HarfBuzz and FreeType are C libraries with stable
  C ABIs — ImportC / `extern(C)` bindings, no C++ shim. HarfBuzz even has a `harfbuzzjs`
  wasm build for the web path.

> [!WARNING]
> **This is a construction kit, not a math engine.** HarfBuzz + FreeType + a MATH-table font
> give you every primitive to _build_ a math layout engine, but you must write the layout
> (spacing rules, nesting, stretch) yourself — the multi-decade work that TeX, MathJax, and
> MicroTeX already did. Use this layer for **non-math text** (as Manim does) and let a
> higher-level system own the _math_ layout.

License note: **HarfBuzz** is under the ["Old MIT" license][hb-copying] (_"Permission is
hereby granted, without written agreement and without license or royalty fees, to use,
copy, modify, and distribute this software and its documentation for any purpose…"_);
**Pango** is LGPL-2.1; **FreeType** is dual FTL / GPL-2. All are permissive enough to
vendor.

---

## Recommendation for a hybrid D engine

No single system wins; the right answer is a **layered stack** that matches each job to the
system built for it, and keeps the reproducible path and the web path separate.

| Job                          | Primary choice                                             | Why                                                                                                          |
| ---------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| **Math, reproducible video** | [LaTeX → `dvisvgm`](#latex-to-svg-via-dvisvgm), Nix-pinned | Widest LaTeX coverage; matches Manim byte-for-byte; deterministic when the toolchain is a pinned Nix closure |
| **Non-math text**            | [HarfBuzz + FreeType](#mathml-with-harfbuzz-and-pango)     | Clean C ABI (ImportC), in-process, deterministic; the layer Manim already uses via `manimpango`              |
| **Math, TeX-free fallback**  | [MicroTeX](#microtex) behind an `extern "C"` shim          | In-process LaTeX-math with no TeX install, for environments that can't provision TeX Live                    |
| **Web / wasm path**          | [Typst](#typst) (native + wasm) or [KaTeX](#katex) (DOM)   | Typst is one engine for both native FFI and wasm; KaTeX for fast HTML overlays where outlines aren't needed  |

**The reasoning:**

1. **Primary — `LaTeX` → `dvisvgm`, Nix-pinned.** For the video path, match Manim: it is the
   only system with unbounded LaTeX coverage, its output is exactly what the reference engine
   produces, and — the usual objection, non-determinism — evaporates when the entire TeX +
   `dvisvgm` toolchain is a **pinned Nix closure**. That turns "three fragile external
   binaries" into a reproducible [frame-sampling oracle](./concepts.md#deterministic-frame-sampling),
   with `dvisvgm --no-fonts` output [content-hash cached](./concepts.md#content-hash-caching)
   to disk. The cost — a heavy TeX install and subprocess latency — is paid once and amortised.

2. **Non-math text — HarfBuzz + FreeType, in-process.** Do not route plain labels through
   LaTeX. HarfBuzz shapes and FreeType extracts outlines with the cleanest binding story in
   the survey (stable C ABI, ImportC, no C++), deterministically. This is the axis-4 half that
   should be _in_ the D engine, not shelled out.

3. **TeX-free fallback — MicroTeX behind a C-ABI wrapper.** For hosts that cannot install
   TeX, MicroTeX gives in-process LaTeX-math with no subprocess. Because it is **C++**, it
   must sit behind a thin `extern "C"` shim (parse → `TeXRender` → walk paths), then D
   `extern(C)` — the same integration shape the repo already uses for C/C++ libraries. It is
   a fallback, not the primary, precisely because of that wrapper cost and its narrower LaTeX
   coverage.

4. **Web path — Typst, with KaTeX for DOM overlays.** For a browser build, Typst is uniquely
   attractive: one Rust engine that ships both a native FFI surface and a **wasm** build, with
   first-class SVG export feeding the same [`VMobject`](./concepts.md#vmobject-and-vector-geometry)
   parser as `dvisvgm`. Its cost is a **non-LaTeX math syntax**, so it is a parallel path, not
   a drop-in. KaTeX remains the fastest option when the web overlay only needs _rendered HTML_
   (no morphable outlines).

The through-line: **reuse a real typesetter for the math you can't afford to reimplement
(LaTeX via `dvisvgm`), own the font layer you can (HarfBuzz + FreeType), and keep a TeX-free
fallback (MicroTeX) and a web engine (Typst/KaTeX) behind stable seams.** The two probes that
ground the geometry underneath all of this are [`bezier-eval.d`](./examples/bezier-eval.d)
(the quadratic-vs-cubic outline basis every path arrives in) and
[`frame-capture.d`](./examples/frame-capture.d) (the readback + content-hash a render cache
keys on).

---

## Sources

- [dvisvgm homepage][dvisvgm] · [manual][dvisvgm-man] · [`mgieseki/dvisvgm`][dvisvgm-repo] —
  "converts DVI, EPS, and PDF files to … SVG"; the `--no-fonts` "uses paths instead" quote.
- [ManimCommunity `tex_file_writing.py`][manim-tex] — the live `dvisvgm … --no-fonts …`
  command and the `latex`/`xelatex` `compile_tex` step.
- [`mathjax/MathJax-src`][mathjax-repo] · [MathJax.org][mathjax-site] — "JavaScript display
  engine for LaTeX, MathML, and AsciiMath"; SVG/CHTML output.
- [`KaTeX/KaTeX`][katex-repo] · [output options][katex-opts] — "fast … TeX math rendering on
  the web"; synchronous; `html`/`mathml`/`htmlAndMathml` output (no SVG mode).
- [`NanoMichael/MicroTeX`][microtex-repo] · [`cLaTeXMath`][clatexmath] — "embeddable LaTeX
  rendering library"; `Graphics2D` abstraction; MIT; C++ (needs an `extern "C"` shim).
- [`typst/typst`][typst-repo] · [math reference][typst-math] · [export reference][typst-ref] ·
  [`typst.ts`][typstts] — "as powerful as LaTeX"; native math syntax; PDF/SVG/PNG; wasm.
- [HarfBuzz manual][harfbuzz] · [`hb-ot-math.h`][hb-math] · [COPYING][hb-copying] —
  Unicode→positioned-glyph shaping; the OpenType MATH-table API; the "Old MIT" license.

> [!NOTE]
> **Runnable grounding.** This page's claims are about _pipelines_, not D APIs, so it has no
> dedicated probe; the geometry the pipelines feed is grounded by the catalog's shared
> probes — [`bezier-eval.d`](./examples/bezier-eval.d) for the
> [outline basis](./concepts.md#bezier-basis-quadratic-vs-cubic) and
> [`frame-capture.d`](./examples/frame-capture.d) for
> [caching](./concepts.md#content-hash-caching). Source-file citations are pinned to
> commits; external homepages may rate-limit the link checker (`SKIP=lychee` at commit time,
> per the research-docs guide).

<!-- References -->

<!-- Concept anchors (same-tree) -->

<!-- Runnable probes (checked via the ignoreDeadLinks /\.d$/ rule) -->

[dvisvgm]: https://dvisvgm.de/
[dvisvgm-man]: https://dvisvgm.de/Manpage/
[dvisvgm-repo]: https://github.com/mgieseki/dvisvgm
[manim-tex]: https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/utils/tex_file_writing.py
[mathjax-repo]: https://github.com/mathjax/MathJax-src
[mathjax-site]: https://www.mathjax.org/
[katex-repo]: https://github.com/KaTeX/KaTeX
[katex-opts]: https://katex.org/docs/options.html
[microtex-repo]: https://github.com/NanoMichael/MicroTeX
[clatexmath]: https://github.com/NanoMichael/cLaTeXMath
[typst-repo]: https://github.com/typst/typst
[typst-math]: https://typst.app/docs/reference/math/
[typst-ref]: https://typst.app/docs/reference/
[typstts]: https://github.com/Myriad-Dreamin/typst.ts
[harfbuzz]: https://harfbuzz.github.io/
[hb-math]: https://github.com/harfbuzz/harfbuzz/blob/907579859f604633ad511f2f49fa0299d799d9b8/src/hb-ot-math.h
[hb-copying]: https://github.com/harfbuzz/harfbuzz/blob/907579859f604633ad511f2f49fa0299d799d9b8/COPYING
