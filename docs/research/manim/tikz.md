# TikZ / PGF (TeX)

The TeX-native vector-graphics language: **TikZ** is the human-facing frontend
syntax over the **PGF** (Portable Graphics Format) basic-layer engine, and it
runs _inside_ the TeX document compiler — the same engine that typesets the
prose emits the figure — producing **static** PDF / PostScript / SVG vector
graphics rather than a video stream.

| Field             | Value                                                                                                                                                                                                   |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TeX macro language (expanded by `pdfTeX` / `LuaTeX` / `XeTeX`); the frontend is authored in TeX, not a general-purpose language                                                                         |
| License           | **Dual, per component**: code under **GNU GPL v2** _or_ **LPPL 1.3c**; documentation under **GNU FDL 1.2** _or_ **LPPL 1.3c** — _"you can decide which license you wish to use"_ ([`LICENSE`][license]) |
| Repository        | [`pgf-tikz/pgf`][repo]                                                                                                                                                                                  |
| Documentation     | The [`pgfmanual`][manual-home] (~1300 pp.; HTML edition at [`tikz.dev`][manual-home], PDF on [CTAN][ctan] / `texdoc pgfmanual`)                                                                         |
| Category          | **TeX-native declarative vector-graphics language** — a document-embedded, compile-time figure engine, _not_ a morph-animation or video engine                                                          |
| First release     | Grew from Till Tantau's PhD-thesis graphics; under development since **2005** (Tantau to 2018, then Henri Menke); current **3.1.11a** (2025-08-29, [CTAN][ctan]); reviewed Jul 11 2026                  |
| Layers            | **TikZ frontend** (`\draw`/`\node`/`\path`) → **PGF basic layer** (`\pgf…` commands) → **system/driver layer** (`\pgfsys@…`) ([base-design][base-design], [pgfsys][pgfsys])                             |
| Rendered by       | The **TeX engine at document-compile time**; the chosen **driver** (`pdftex`, `dvips`, `dvisvgm`, …) writes vector operators into the output ([drivers][drivers])                                       |
| Output format     | **Vector graphics embedded in a document**: PDF, PostScript, or SVG — never raster frames; rasterization is deferred to the viewer/RIP                                                                  |
| Animation support | **Limited & SVG-only.** The `animations` library emits SMIL-annotated SVG ([tikz-animations][tikz-animations]); `beamer` overlays give slide-step reveals; otherwise fundamentally static               |

> [!NOTE]
> **TikZ is a static, document-oriented vector language, not a video engine.**
> It has no frame loop, no [rate-function/easing](./concepts.md#rate-function-and-easing)
> library, no shape-to-shape [morph](./concepts.md#transform-and-point-count-alignment),
> no [pixel readback](./concepts.md#frame-capture-and-readback), and no
> [codec/muxing](./concepts.md#codec-muxing-and-pixel-format) — several of the
> survey's axis-2 and axis-5 concerns are therefore **N/A** and marked so below.
> It earns its place in the catalog for the opposite reason: it is the mature,
> production-hard declarative vector language whose **TeX-native typesetting** a
> Manim-class engine can only envy — labels are set by the very compiler that
> builds the document, with no external [LaTeX→SVG shell-out](./concepts.md#latex-to-svg).

> [!WARNING]
> **Verification note.** Quotes below are drawn from the official `pgfmanual`
> via its HTML edition at [`tikz.dev`][manual-home] (a verbatim rendering of the
> manual shipped in [`pgf-tikz/pgf`][repo]), plus the [CTAN package page][ctan]
> and the in-repo [`LICENSE`][license]. Version and license facts are pinned to
> **3.1.11a** (2025-08-29). No runnable CI probe ships with this page — see the
> [note under Sources](#sources).

---

## Overview

### What it solves

PGF/TikZ solves **portable, programmatic, publication-quality figures embedded
directly in a TeX document**. The [CTAN description][ctan] states the scope:

> _"PGF is a macro package for creating graphics. It is platform- and
> format-independent and works together with the most important TeX backend
> drivers, including pdfTeX and dvips."_ — [CTAN `pgf`][ctan]

The problem it uniquely solves for _this_ survey is **figures whose text is
first-class TeX**. In a Manim-class engine, math and labels are an external
subsystem — Manim shells out to a LaTeX distribution and `dvisvgm` to turn an
equation into a [VMobject](./concepts.md#vmobject-and-vector-geometry) (the
[LaTeX→SVG pipeline](./concepts.md#latex-to-svg)). In TikZ there _is_ no
shell-out: the picture is expanded by the same TeX run that is typesetting the
surrounding document, so a node's contents — `$\int_0^1 x^2\,dx$`, a full
`align` environment, a `\ref` — are typeset by the document compiler itself,
kerned and hinted identically to the body text. The cost of that power is the
mirror image: TikZ is bound to the **document-compile model**, so it produces a
_page_, not a _movie_.

### Design philosophy

TikZ's name is a self-deprecating recursive acronym, in the GNU tradition:

> _"TikZ ist **kein** Zeichenprogramm"_ (TikZ is **not** a drawing program) —
> [Design Principles][tikz-design]

The point of the joke is the design bet. TikZ deliberately refuses a WYSIWYG
canvas; a figure is _described_ in a terse, key-value path language, not
mouse-drawn. The manual states the goal plainly:

> _"TikZ's job is to make your life easier by providing an easy-to-learn and
> easy-to-use syntax for describing graphics."_ — [Design Principles][tikz-design]

Its syntax is a magpie synthesis of prior art, which the manual credits
explicitly:

> _"The basic command names and the notion of path operations is taken from
> metafont, the option mechanism comes from pstricks, the notion of styles is
> reminiscent of svg, the graph syntax is taken from graphviz."_ —
> [Design Principles][tikz-design]

The MetaPost/`metafont` lineage is load-bearing for this survey: it is the
origin of [equation-solved, Hobby-spline drawing](./concepts.md#hobby-splines-and-equation-solved-points)
that TikZ inherits (see [Object & scene model](#object--scene-model)). The
second philosophical commitment is the **layered architecture** — a portable
basic layer with a thin, driver-specific bottom — covered next.

---

## How it works

A TikZ picture is a `tikzpicture` environment whose body is a sequence of **path
commands**. The atom is a path built from **coordinates** and **path
operations**, then acted upon (drawn, filled, clipped):

```latex
\begin{tikzpicture}
  \draw (0,0) -- (2,0) -- (2,1) -- cycle;      % a filled-outline triangle path
  \node[draw,circle] (a) at (0,0) {$x$};        % a node: TeX-typeset text in a shape
  \fill[blue!20] (a.east) circle (2pt);         % reference the node's `east` anchor
\end{tikzpicture}
```

Three verbs cover almost everything:

- **`\path`** is the primitive — it _constructs_ a path but takes no action by
  itself. `\draw`, `\fill`, `\filldraw`, `\clip`, and `\shade` are all
  `\path[draw]`, `\path[fill]`, … in disguise.
- **`\node`** places TeX-typeset content (a shape with a border and a label) at
  a coordinate; nodes are the addressable, anchored objects.
- **`\draw`/`\fill`** are the common actions.

**Coordinates and path operations.** Coordinates are Cartesian `(x,y)`, polar
`(30:1cm)`, named (`(a.north)`), or relative (`+(1,0)` / `++(1,0)`). Path
operations join them: `--` (line-to), `|-`/`-|` (right-angle), `rectangle`,
`circle`, `arc`, `grid`, `parabola`, `plot`, and the **curve-to** operator
`.. controls … ..` (a [cubic Bézier](./concepts.md#bezier-basis-quadratic-vs-cubic),
detailed below).

**The three-layer architecture** is the core mechanism. A TikZ command does not
speak to the output driver; it descends through three layers
([base-design][base-design], [pgfsys][pgfsys]):

| Layer                   | Command prefix             | Role                                                                     |
| ----------------------- | -------------------------- | ------------------------------------------------------------------------ |
| **TikZ frontend**       | `\draw`, `\node`, `\path`  | Human syntax; parses coordinates/options and calls the basic layer       |
| **PGF basic layer**     | `\pgfpath…`, `\pgfusepath` | Portable, driver-independent path/scope/node primitives                  |
| **System/driver layer** | `\pgfsys@…`                | The thin, driver-specific bottom that writes actual PDF/PS/SVG operators |

> _"The basic layer does not provide a convenient syntax for describing
> graphics, which is left to frontends like TikZ."_ — [Design Principles of the
> basic layer][base-design]

The frontend is _swappable_: TikZ and `pgfpict2e` are both frontends over the
same basic layer, and packages such as `beamer` skip the frontend entirely —
_"the beamer package uses the basic layer extensively, but does not need a
convenient input syntax"_ ([base-design][base-design]). The system layer, in
turn, hides every backend difference behind `\pgfsys@…` calls: _"This interface
provides a complete abstraction of the internals of the underlying drivers"_
([pgfsys][pgfsys]). This layering is what makes one `.tex` source render to PDF
under `pdftex` and to SVG under `dvisvgm` unchanged.

**Runs inside TeX.** There is no separate "engine" process. The `tikzpicture`
is macro-expanded during the TeX run; coordinate arithmetic is TeX register
math; the "renderer" is whichever driver `\pgfsysdriver` selects. The document
compiler _is_ the engine — a defining structural fact for every axis below.

**`\foreach`.** Repetition is the `pgffor` loop, usable inside or outside a
picture — _"execute the ⟨commands⟩ repeatedly, once for every element of the
⟨list⟩"_ ([pgffor][pgffor]), with `...` range expansion:

```latex
\foreach \x in {1,2,...,6} {\x, }   % expands to: 1, 2, 3, 4, 5, 6,
```

**Decorations** transform a constructed path into a richer one — _"Decorations
are a general concept to make (sub)paths 'more interesting'"_
([tikz-decorations][tikz-decorations]) — in three flavours: **path morphing**
(a straight line becomes a `zigzag`/`snake`/`coil`), **path replacing**, and
**path removing**. The rest of this page walks the survey's
[eight axes](./concepts.md) against this machinery.

---

## Object & scene model

TikZ has _objects_ but no **retained, mutable, animatable scene graph** in the
[Mobject](./concepts.md#mobject-and-the-scene-graph) sense. There are two kinds
of thing:

- **Paths** — constructed then immediately consumed by an action. A `\draw …;`
  emits its stroke operators and is _gone_; there is no persistent path object
  you can later grab and morph. This is closest to
  [immediate-mode](./concepts.md#retained-vs-immediate-mode) emission (each
  command paints as it expands), not a retained tree the engine re-renders.
- **Nodes** — the _addressable_ objects. A node is placed at a coordinate,
  carries TeX-typeset content, and has a shape: _"A node is typically a
  rectangle or circle or another simple shape with some text on it"_
  ([tikz-shapes][tikz-shapes]). Nodes are named (`(a)`) and referenced later,
  which gives a picture a lightweight object graph — but a _static_ one, fixed
  once the picture is compiled.

**Anchors** are the placement primitive: every shape exposes named points —
_"pgf defines numerous anchor positions in the shape. For example the upper
right corner is called … the `north east` anchor … The center of the shape has
an anchor called `center`"_ ([tikz-shapes][tikz-shapes]). Edges connect anchors
(`\draw (a.east) -- (b.west);`), and the `positioning` library places nodes
_relative_ to each other (`below=1cm of a`, `right=of b`).

**Coordinate space and transforms.** Every scope carries an
[affine transform](./concepts.md#affine-transform-and-coordinate-space) —
`\begin{scope}[shift={(1,1)},rotate=30,scale=2]` composes translate∘rotate∘scale
exactly as the [`affine-transform.d`](./examples/affine-transform.d) probe
verifies for the general case, and the `calc` library does coordinate
arithmetic (`($(a)!0.5!(b)$)` is the midpoint). TikZ distinguishes the
**canvas** transform (applied by the driver, cheap, distorts line widths) from
the **coordinate** transform (applied by PGF to points, preserves stroke width)
— a subtlety without a Manim analog because Manim transforms model points, never
the device.

> [!NOTE]
> **Layout is placement, not constraint-solving.** Node positions come from
> explicit anchors, the relative `positioning` library, or the algorithmic
> graph-drawing (`gd`) subsystem — _not_ from a numerical optimizer.
> [Constraint/optimization-based layout](./concepts.md#constraint-and-optimization-based-layout)
> (Penrose-style energy minimization) is **N/A**; the nearest TikZ has is
> graph-drawing algorithms and the MetaPost-inherited
> [equation-solved](./concepts.md#hobby-splines-and-equation-solved-points)
> `calc`/`intersections` machinery.

---

## Animation & timing model

This is the axis where TikZ is **fundamentally limited**, and honestly so. There
is **no timeline, no play-loop, no interpolation engine, no rate functions, no
lag/stagger** — none of the [execution models](./concepts.md#execution-models)
in the concepts glossary (imperative play-loop, generator, pure-frame, reactive,
keyframe) applies, because there is no _time_ axis in a compiled figure. What
exists are two narrow, deliberately-scoped mechanisms plus one companion
package.

**The `animations` library (SVG/SMIL only).** Loaded with
`\usetikzlibrary{animations}`, it attaches an `:attribute` timeline to a node or
scope. Crucially, it does **not** rasterize frames — it writes a declarative
_annotation_ into the SVG output and lets the viewer play it:

> _"TikZ animations currently work only with svg output (and use the smil
> 'flavor' of describing animations)."_ — [Animations][tikz-animations]

> _"a TikZ animation is just an 'annotation' in the output that a certain
> attribute of a certain object should change over time in some specific way
> when the object is displayed. It is the job of the document viewer application
> to actually compute and display the animation."_ — [Animations][tikz-animations]

The syntax is a `:`-namespaced key that maps timestamps to attribute values
(e.g. `myself:fill = {0s = "red", 2s = "blue"}`), and the engine is the SMIL
runtime in the browser/SVG viewer — so animations _"neither increase output
file sizes noticeably nor slow down TeX"_. The honesty is in the PDF caveat:

> _"It is very unlikely that pdf will ever support animations in a useful way."_
> — [Animations][tikz-animations]

For PDF (or a printed handout), the only recourse is **snapshots** — _"it is …
possible to create 'snapshots' of an animation and insert these into pdf files …
also useful for creating 'printed versions'"_ ([tikz-animations][tikz-animations])
— i.e. render selected instants as static figures, which is _exactly_ the
opposite of a [frame-sampled video](./concepts.md#deterministic-frame-sampling).

**`beamer` overlays (slide-step "animation").** For presentations, the
step-through illusion comes from `beamer`, not TikZ: overlay specifications in
pointed brackets gate content per slide. `\pause`, `\only<2->{…}`,
`\onslide<3>{…}`, and `\visible<2->{…}` reveal or hide material across
"overlays" of one frame ([beamer overlays][beamer-overlays]). TikZ integrates
via per-slide styles (`\draw[visible on=<2->] …`), so a diagram builds up
step-by-step. But this is **discrete slide stepping**, not continuous
interpolation — there is no tween between states, only presence/absence.

| Manim axis-2 concept                                                                   | TikZ                                                                                                                    |
| -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| [Interpolation / lerp](./concepts.md#interpolation-and-lerp)                           | **Deferred to the viewer.** SMIL interpolates attribute keyframes in the SVG player; TeX computes nothing over time.    |
| [Rate function / easing](./concepts.md#rate-function-and-easing)                       | **Minimal.** SMIL `calcMode`/`keySplines` easing is available in the SVG output; no `smooth`/`rush_into` morph library. |
| [Transform + point-count alignment](./concepts.md#transform-and-point-count-alignment) | **N/A.** No shape-to-shape morph; paths are not retained, so there is nothing to align point-for-point.                 |
| [lag_ratio / stagger](./concepts.md#lag-ratio-and-staggering)                          | **N/A** as a timeline primitive; per-object `begin` offsets exist only inside the SMIL annotation.                      |
| [Execution model](./concepts.md#execution-models)                                      | **None of the five.** A figure is macro-expanded once at compile time; `beamer` adds discrete slide stepping on top.    |

The [`rate-functions.d`](./examples/rate-functions.d) probe describes the easing
and stagger machinery a Manim-class engine bakes in — precisely the layer TikZ
_delegates_ (to the SMIL viewer) or _omits_.

---

## Rendering backend & rasterization

**TikZ has no rasterizer.** This is the sharpest structural difference from
every other engine in the survey. TikZ/PGF emits **vector operators** — path
fill/stroke/clip commands in the output language — and the actual
[rasterization](./concepts.md#rasterization) (turning vectors into pixels)
happens _downstream_, in the PDF viewer, the print RIP, or the browser's SVG
renderer. There is no [CPU-vector vs GPU-vector](./concepts.md#cpu-vector-vs-gpu-vector-rendering)
choice inside TikZ, no [anti-aliasing](./concepts.md#anti-aliasing) knob, no
MSAA, no coverage buffer — those are the viewer's job.

What TikZ _does_ choose is the **output vector language**, via the system/driver
layer. The supported drivers are ([drivers][drivers]): `luatex`, `pdftex`,
`dvips`, `dvipdfm`, `dvipdfmx`, `dvisvgm`, and `tex4ht`. Each is a
`pgfsys-⟨driver⟩.def` file implementing the `\pgfsys@…` primitives:

| Driver file           | Pipeline                       | Output operators         |
| --------------------- | ------------------------------ | ------------------------ |
| `pgfsys-pdftex.def`   | `pdftex` (direct PDF)          | PDF content stream       |
| `pgfsys-luatex.def`   | `luatex` (direct PDF)          | PDF content stream       |
| `pgfsys-dvips.def`    | `(la)tex` → `dvips`            | PostScript               |
| `pgfsys-dvipdfmx.def` | `xetex`/`(la)tex` → `dvipdfmx` | PDF                      |
| `pgfsys-dvisvgm.def`  | `(la)tex` → `dvisvgm`          | **raw SVG** (with fonts) |

> _"This driver converts dvi files to svg file, including text and fonts, and
> when you select this driver, pgf will output the required raw svg code for the
> pictures it produces."_ — [Supported Formats][drivers]

Because the pixels are produced by the viewer, TikZ output is
**resolution-independent by construction** — a PDF figure is razor-sharp at any
zoom and at print resolution, with no render-time DPI decision. The trade-off is
that TikZ cannot _observe_ its own pixels: there is no framebuffer to read back
(see [Output & encoding](#output--encoding)).

---

## Typesetting & text

This is TikZ's signature strength and the reason it belongs in a
mathematical-animation survey at all. **Text is native TeX.** A node's contents
are typeset by the _same_ TeX engine compiling the document — not a bolt-on math
subsystem — so any TeX/LaTeX construct works verbatim:

```latex
\node at (0,0) {$\displaystyle \int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}$};
\node at (0,-1) {\begin{tabular}{c}multi-line\\ \LaTeX\ content\end{tabular}};
```

Contrast the concepts glossary's [LaTeX→SVG](./concepts.md#latex-to-svg)
pipeline, which both Manim forks run to bring math in: compile LaTeX to `dvi`,
run [`dvisvgm`](./concepts.md#latex-to-svg), parse the SVG, and rebuild a
[VMobject](./concepts.md#vmobject-and-vector-geometry). TikZ collapses that
entire round-trip — the equation is _already_ in the TeX stream, laid out by the
compiler's math engine, kerned and hinted like the body text. There is **no
external shell-out** for a label, no version-skew between the figure's fonts and
the document's, and no per-label caching problem.

The corollary is that the [glyph-outline-extraction](./concepts.md#glyph-outline-extraction)
and [text-shaping](./concepts.md#text-shaping) axes look different than for a
morph engine:

- **Shaping** is TeX's own line/math-mode layout (`\hbox`/`\vbox`, math atoms),
  not [HarfBuzz/Pango](./concepts.md#text-shaping). (Under `LuaTeX` +
  `luaotfload`, HarfBuzz _is_ reachable, but that is TeX's font machinery, not
  TikZ's.)
- **Glyph outlines are usually NOT extracted.** TikZ places a _typeset glyph_ —
  a reference into an embedded font in the PDF/SVG — rather than decomposing the
  letter into contour Béziers as a [VMobject](./concepts.md#vmobject-and-vector-geometry)
  would. Text stays text (selectable, searchable) instead of becoming path. The
  exception is opt-in: the `dvisvgm` driver can flatten fonts to SVG paths, and
  helper packages (`tikz` + `\path[…] … node …` decorations, or external outline
  tools) can turn a glyph into a decoratable path — but that is not the default,
  and morphing letters is not a native operation.

---

## Output & encoding

TikZ's output is a **figure inside a document**, not a media file — so the
survey's axis-5 machinery is largely **N/A** and its absence is the finding.

- **[Frame capture / readback](./concepts.md#frame-capture-and-readback) —
  N/A.** There is no RGBA framebuffer to read. PGF emits vector operators; there
  is no rendered pixel buffer anywhere in the pipeline (it lives, transiently, in
  the viewer). The [`frame-capture.d`](./examples/frame-capture.d) probe's
  render→buffer step has no TikZ counterpart.
- **[Codec / muxing / pixel format](./concepts.md#codec-muxing-and-pixel-format)
  — N/A.** No `yuv420p` conversion, no `libx264`, no `.mp4` muxing. The "encode"
  step is the driver writing PDF/PS/SVG _vector_ operators, and the "container"
  is the surrounding `.pdf`/`.svg` document.
- **What it _does_ produce:** a page (or a standalone figure via the
  `standalone` document class or `\usepackage{tikz}` + crop), or — via
  `dvisvgm` — a self-contained SVG. For a "video", the workflow is external:
  compile one figure per instant (e.g. `\foreach` a parameter across N files),
  then feed the resulting PDFs/PNGs to an outside tool (`ffmpeg`, `convert`).
  That pipeline is _bolted on_, not part of TikZ.

The one genuinely animated output is the SVG/SMIL path of the
[`animations` library](#animation--timing-model): the "encoding" of motion is a
set of `<animate>` elements in the SVG, played by the viewer — declarative
motion, zero rendered frames.

---

## Interactivity, preview & authoring

**Authoring is the edit-compile-view loop of TeX.** You write TikZ source in an
editor and compile the document; the figure appears when the page renders. There
is no live canvas, no interactive scrubber, no REPL — authoring is inherently
_offline_ and batch, the antithesis of a [reactive](./concepts.md#execution-models)
or GUI-timeline tool.

- **Preview.** Iteration speed comes from the surrounding TeX ecosystem, not
  TikZ: `standalone` + `preview` to compile a single figure fast, editor
  live-preview (LaTeX Workshop, `latexmk -pvc`), or `externalization` (below) to
  avoid recompiling unchanged figures. The feedback loop is a document rebuild,
  typically sub-second for one figure but not interactive in the drag-a-handle
  sense.
- **Interactivity in the _output_.** The only interactivity TikZ can bake in is
  what the _viewer_ supports: PDF hyperlinks/`hyperref` targets, and — in SVG
  output — the SMIL [animations](#animation--timing-model) and JavaScript-driven
  behaviour a browser can run. A native window that recomputes on drag (Makie's
  `GLMakie`, nannou) has no TikZ analog.
- **`beamer` as the authoring target for "playback".** For talks, the
  [overlay](#animation--timing-model) system is the authoring surface: you write
  one frame and annotate which parts appear on which slide, and the PDF viewer's
  next-slide key is the "play" button.

---

## Extensibility & API surface

TikZ is extended the way TeX is extended — with macros, key-value styles, and
loadable **libraries** — and the surface is enormous.

- **Styles and the `pgfkeys` system.** Graphic parameters are keys
  (`draw`, `fill=blue!20`, `line width=2pt`, `rounded corners`), grouped into
  reusable **styles** (`\tikzset{my style/.style={...}}`) — the `svg`-inspired
  styling the [design principles][tikz-design] credit. `pgfkeys` is a
  general-purpose key-value/handler engine used well beyond graphics.
- **Libraries** (`\usetikzlibrary{…}`) add vocabulary without touching the core.
  The survey-relevant ones:

  | Library         | Adds                                                                                                       |
  | --------------- | ---------------------------------------------------------------------------------------------------------- |
  | `calc`          | Coordinate arithmetic — midpoints, projections, `($(a)!t!(b)$)`                                            |
  | `positioning`   | Relative node placement (`below=of`, `right=1cm of`)                                                       |
  | `arrows.meta`   | Parameterized, composable arrow-tip system                                                                 |
  | `decorations.*` | Path morphing / replacing / removing — `zigzag`, `snake`, `coil`, braces ([decorations][tikz-decorations]) |
  | `intersections` | Named path intersections solved at compile time                                                            |
  | `animations`    | The [SVG/SMIL animation](#animation--timing-model) annotations                                             |
  | `graphdrawing`  | Algorithmic layout (LuaTeX-only; layered/force/tree layouts)                                               |

- **The frontend seam.** Because the [basic layer](#how-it-works) is a stable,
  documented API, whole packages build on PGF _without_ TikZ: `pgfplots`
  (function/data plots), `tikz-cd` (commutative diagrams), `circuitikz`, and
  `beamer` all target the basic layer or extend the TikZ frontend. Adding a new
  frontend (à la `pgfpict2e`) is a supported extension point
  ([base-design][base-design]).
- **Smooth curves and the MetaPost inheritance.** `plot[smooth]` draws a
  tension-spline through points; for true MetaPost curves, the contributed
  `hobby` library (`\usetikzlibrary{hobby}`) implements
  [Hobby's algorithm](./concepts.md#hobby-splines-and-equation-solved-points) —
  _"The algorithm was devised as part of the MetaPost program"_
  ([hobby package][hobby]) — the curvature-minimizing spline through a point
  sequence, the same equation-solved drawing the concepts page attributes to the
  MetaPost lineage.

---

## Determinism, caching & performance

- **[Deterministic output](./concepts.md#deterministic-frame-sampling) — yes,
  by construction.** A TikZ figure is a pure function of its source: recompiling
  the same `.tex` with the same TeX/driver build yields byte-identical vector
  operators. There is no RNG, no floating-point GPU variance, no driver-dependent
  rasterization (the vectors are exact; only the viewer's pixels vary). This is
  strictly _stronger_ determinism than the [CPU-oracle](./concepts.md#cpu-vector-vs-gpu-vector-rendering)
  compromise a raster engine settles for — TikZ never commits to pixels at all.
- **[Content caching](./concepts.md#content-hash-caching) — via
  externalization.** PGF's `external` library is the direct analog of Manim's
  [partial-movie-file cache](./concepts.md#content-hash-caching): each
  `tikzpicture` is compiled once to a standalone PDF/PNG and _reused_ on
  subsequent document builds unless its source changed, so an unchanged figure is
  not re-rendered. The granularity is the whole picture (Manim's is a `play()`
  call), and correctness rests on the same property — the render is
  deterministic, so a cached artifact is valid until the input changes.
- **Performance.** The cost is TeX macro expansion, which is _slow_ for
  heavy figures: coordinate math runs in TeX's fixed-point registers, thousands
  of path segments or a dense `\foreach` can take seconds, and there is no GPU
  acceleration. Externalization exists precisely because complex pictures
  dominate compile time. The counterweight is that this cost is paid _once_, at
  build time, for a resolution-independent artifact — not per-frame, per-second
  of video.

---

## Strengths

- **TeX-native typesetting.** Labels and math are set by the document compiler
  itself — no [LaTeX→SVG shell-out](./concepts.md#latex-to-svg), no font skew,
  perfect consistency with body text. The single capability a Manim-class engine
  most envies.
- **Resolution independence.** Vector output (PDF/PS/SVG) is sharp at any zoom
  and at print DPI; TikZ makes no rasterization decision — the viewer does.
- **Deterministic and reproducible.** Same source → identical vector output; no
  RNG, no GPU variance. Externalization gives content-hash-style figure caching.
- **Mature, vast, and stable.** ~1300-page manual, two decades of development,
  huge library/package ecosystem (`pgfplots`, `tikz-cd`, `circuitikz`, `beamer`),
  and a clean [three-layer](#how-it-works) frontend/basic/system architecture.
- **Portable.** One source renders under `pdftex`, `xetex`+`dvipdfmx`, or
  `dvisvgm` unchanged — the [system layer abstracts every driver][pgfsys].
- **Declarative, composable syntax.** Key-value styles, `\foreach`, decorations,
  and `calc`/`intersections` make complex diagrams concise and parameterizable.

## Weaknesses

- **Not a video/animation engine.** No timeline, no
  [interpolation](./concepts.md#interpolation-and-lerp)/[easing](./concepts.md#rate-function-and-easing)
  library, no [shape morph](./concepts.md#transform-and-point-count-alignment).
  Animation is SVG/SMIL-only (_"very unlikely that pdf will ever support
  animations"_ [tikz-animations][tikz-animations]) or discrete `beamer` slide
  steps.
- **No rasterizer / no pixel access.** Cannot [read back frames](./concepts.md#frame-capture-and-readback);
  producing a raster or video is an external, bolted-on pipeline
  (`ffmpeg`/`convert` over per-instant PDFs).
- **No retained, mutable scene graph.** Paths are emit-and-forget; nodes are
  static once compiled — no [Mobject](./concepts.md#mobject-and-the-scene-graph)
  to grab and animate.
- **Slow for heavy figures.** TeX-register coordinate math, no GPU; complex
  pictures dominate compile time (mitigated only by externalization).
- **Offline authoring.** Edit-compile-view loop; no live canvas, scrubber, or
  interactive preview in the tool itself.
- **No linear-light compositing.** Colors come from `xcolor` and are passed as
  device colors to the driver; there is no
  [gamma-correct linear-space blend](./concepts.md#color-model-and-gamma) model
  because there is no per-pixel compositing stage.

---

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                           | Trade-off                                                                                           |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Run inside TeX; text is native TeX ("TikZ ist kein Zeichenprogramm") | Labels/math typeset by the document compiler — perfect consistency, no external LaTeX→SVG shell-out | Bound to the document-compile model; produces a page, never a movie; slow macro-expansion math      |
| Three layers: TikZ frontend → PGF basic layer → `\pgfsys@` driver    | Portable core; one source → PDF/PS/SVG; frontends (TikZ, `pgfpict2e`) and packages (`beamer`) swap  | Every backend needs a `pgfsys-⟨driver⟩.def`; feature parity across drivers is uneven                |
| Emit vector operators; no built-in rasterizer                        | Resolution independence; deterministic, viewer-agnostic output                                      | Cannot read back pixels or produce raster/video without an external pipeline                        |
| Cubic-Bézier `.. controls ..` path model (MetaPost lineage)          | Standard, expressive curves; `hobby` library adds equation-solved MetaPost splines                  | Curve _morphing_ is not a primitive; no point-count alignment for shape-to-shape tweens             |
| Animation = SVG/SMIL annotation, computed by the viewer              | No file-size/compile-time cost; declarative motion "for free" in a browser                          | SVG-only; PDF unsupported; no continuous morph timeline — snapshots or `beamer` steps for print/PDF |
| Static figure, no timeline/execution model                           | Matches the document-figure purpose; deterministic and cacheable                                    | None of the survey's five execution models applies; "animation" is out of scope by design           |
| Externalization for figure caching                                   | Skip re-rendering unchanged pictures — the `play()`-cache analog at picture granularity             | Coarse (whole-picture) granularity; adds build plumbing (`\tikzexternalize`)                        |
| Extensibility via `pgfkeys` styles + loadable libraries              | Vast, composable vocabulary without core changes; whole packages build on the basic layer           | TeX-macro API surface; debugging expansion/keys is arcane; no type safety                           |

---

## Sources

- [`pgf-tikz/pgf`][repo] — the PGF/TikZ source repository (Till Tantau, Henri
  Menke, Christian Feuersänger, the PGF/TikZ Team); README positioning
  (_"a TeX macro package for generating graphics … a user-friendly syntax layer
  called TikZ"_).
- [`doc/generic/pgf/licenses/LICENSE`][license] — dual licensing: code under
  **GNU GPL v2** _or_ **LPPL 1.3c**; documentation under **GNU FDL 1.2** _or_
  **LPPL 1.3c**; _"you can decide which license you wish to use when using the
  pgf package."_
- [CTAN: `pgf`][ctan] — package metadata: **Version 3.1.11a, 2025-08-29**;
  licenses (GPL v2 / LPPL 1.3c / GNU FDL); _"PGF is a macro package for creating
  graphics … works together with the most important TeX backend drivers,
  including pdfTeX and dvips."_
- [Design Principles][tikz-design] (`pgfmanual`) — _"TikZ ist kein
  Zeichenprogramm"_; TikZ's job (_"easy-to-learn and easy-to-use syntax for
  describing graphics"_); the `metafont`/`pstricks`/`svg`/`graphviz` influences.
- [Design Principles of the basic layer][base-design] — the three-layer
  architecture; _"The basic layer does not provide a convenient syntax … left to
  frontends like TikZ"_; `beamer` uses the basic layer directly; TikZ vs
  `pgfpict2e` as frontends.
- [The System Layer][pgfsys] — _"This interface provides a complete abstraction
  of the internals of the underlying drivers"_; the `\pgfsys@…` command family.
- [Supported Formats][drivers] — backend drivers `luatex`/`pdftex`/`dvips`/
  `dvipdfm`/`dvipdfmx`/`dvisvgm`/`tex4ht`; the `dvisvgm` driver emits _"raw svg
  code … including text and fonts."_
- [The Curve-To Operation][tikz-paths] (`pgfmanual` §14.3) — _"The curve is a
  cubic Bézier curve"_; two control points `c`, `d`; the tangent construction.
- [Nodes and Edges][tikz-shapes] — _"A node is typically a rectangle or circle
  or another simple shape with some text on it"_; the `north east`/`center`
  anchor model.
- [Repeating Things: `\foreach`][pgffor] — _"execute the ⟨commands⟩ repeatedly,
  once for every element of the ⟨list⟩"_; `{1,2,...,6}` range expansion.
- [Decorated Paths][tikz-decorations] — _"Decorations are a general concept to
  make (sub)paths 'more interesting'"_; path morphing / replacing / removing.
- [Animations][tikz-animations] — SVG/SMIL-only; the "annotation … the viewer
  computes and displays"; _"very unlikely that pdf will ever support
  animations"_; snapshots for PDF.
- [Introduction / manual home][manual-home] — history: _"What began as a small
  LaTeX style for creating the graphics in Till Tantau's PhD thesis … has now
  grown to become a full-blown graphics language with a manual of over a thousand
  pages."_
- [Creating Overlays][beamer-overlays] (beamer manual) — `\pause`, `\only`,
  `\onslide`, `\visible` overlay specifications for slide-step reveals.
- [`hobby` package][hobby] (Andrew Stacey) — _"The algorithm was devised as part
  of the MetaPost program"_; `\usetikzlibrary{hobby}` for equation-solved
  MetaPost splines.

> [!NOTE]
> **No runnable CI probe ships with this page.** The catalog's convention is a
> CI-compiled D probe per deep-dive, but TikZ is a TeX macro package with no D
> API to exercise; its behaviour is a document-compile artifact, not a callable
> library. The shared geometry probes still apply by contrast — the cubic-Bézier
> curve-to operator is the [`bezier-eval.d`](./examples/bezier-eval.d) cubic
> case, and TikZ scope transforms are the general
> [`affine-transform.d`](./examples/affine-transform.d) composition — but no
> new TeX-driving probe was added, as none would compile-and-run under the
> `ci --example-files` D toolchain.

<!-- References -->

[repo]: https://github.com/pgf-tikz/pgf
[license]: https://github.com/pgf-tikz/pgf/blob/dc56af18b72255bede59800928f9a2bab1fe35e0/doc/generic/pgf/licenses/LICENSE
[ctan]: https://ctan.org/pkg/pgf
[manual-home]: https://tikz.dev/
[tikz-design]: https://tikz.dev/tikz-design
[base-design]: https://tikz.dev/base-design
[pgfsys]: https://tikz.dev/pgfsys
[drivers]: https://tikz.dev/drivers
[tikz-paths]: https://tikz.dev/tikz-paths
[tikz-shapes]: https://tikz.dev/tikz-shapes
[tikz-decorations]: https://tikz.dev/tikz-decorations
[tikz-animations]: https://tikz.dev/tikz-animations
[pgffor]: https://tikz.dev/pgffor
[beamer-overlays]: https://www.beamer.plus/Creating-Overlays.html
[hobby]: https://ctan.org/pkg/hobby
