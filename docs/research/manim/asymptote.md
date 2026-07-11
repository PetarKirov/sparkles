# Asymptote (descriptive vector graphics)

A C++-like vector-graphics **programming language** with its own compiler and
stack-based bytecode virtual machine — the MetaPost lineage turned into a full
language — that emits 2D and true 3D vector output and typesets every label
through LaTeX.

| Field          | Value                                                                                                                                                      |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | Asymptote (its own C++-like DSL); engine written in C++ (`camp`/`asy`)                                                                                     |
| License        | [GNU **LGPL** v3-or-later][license-lesser] (source); the bundled MSWindows binary is [**GPL** v3][license-gpl] (ships GSL/Readline)                        |
| Repository     | [`vectorgraphics/asymptote`][repo] — _"2D & 3D TeX-Aware Vector Graphics Language"_                                                                        |
| Documentation  | [asymptote.sourceforge.io][site] · [reference manual][manual]                                                                                              |
| Category       | Descriptive vector-graphics programming language (2D + native 3D), figure-oriented                                                                         |
| First release  | 2004 (Copyright 2004–2026 Andy Hammerlindl, John Bowman, Tom Prince)                                                                                       |
| Compiler/VM    | `camp` lexer/parser ([`camp.l`][src-campl]/[`camp.y`][src-campy]) → bytecode ([`inst.h`][src-inst]) → stack VM ([`stack.cc`][src-stack], [`vm.h`][src-vm]) |
| Output formats | EPS, PDF, SVG (via `dvisvgm`), PNG + any ImageMagick format (2D); PRC, V3D, WebGL, OpenGL (3D); GIF/MPEG (`animation` module)                              |
| 3D support     | **Native** — `import three`; `triple`/`path3`/`surface`; interactive PRC-in-PDF and WebGL-in-HTML; OpenGL preview + PBR shading                            |

> [!NOTE]
> This page is grounded in the official [reference manual][manual] (online
> snapshot **version 3.13-36**, Copyright © 2004–2026) and the source repo
> ([`vectorgraphics/asymptote`][repo], `master`); the current stable release is
> **3.09** (per the [manual PDF][site] title page). Asymptote is a
> _descriptive_ vector language, not a timeline animation engine — it renders a
> _figure_. Its animation facility ([axis 2](#animation--timing-model)) batches
> independently-rendered figures and muxes them with external tools, so no
> `ci`-compiled D probe reproduces an Asymptote render; the catalog's
> [`bezier-eval.d`][bezier-eval] and [`affine-transform.d`][affine-transform]
> probes reimplement the cubic-Bézier and coordinate-transform math its path
> and picture model share.

---

## Overview

### What it solves

Asymptote targets **technical and mathematical drawing** where two things must
both be true: the figure is described by _computation_ (loops, functions,
coordinate algebra, 3D geometry) and its text is typeset to publication quality.
The predecessor it names, MetaPost, solved the second half — `dvips`-quality
labels and equation-solved points — but through a weak, untyped macro language.
Asymptote keeps MetaPost's [solved-point / Hobby-spline][hobby] drawing model and
replaces the macro language with a **real, statically-typed, C++-like programming
language** compiled to bytecode. The manual states the positioning directly:

> _"A major advantage of Asymptote over other graphics packages is that it is a
> high-level programming language, as opposed to just a graphics application."_
> ([Description][description])

This places it at a distinct point in the survey's design space: not TeX macros
driving a drawing package ([TikZ][determinism]-style), and not an imperative
render loop over a retained animatable scene ([Manim][execution-models]-style),
but a **descriptive language whose programs are figures** — with native 3D that
neither macro nor most imperative-2D engines offer.

### Design philosophy

The one-line thesis is byte-identical across the repository [`README`][repo] and
the manual [Description][description] — the load-bearing quote for this page:

> _"Asymptote is a powerful descriptive vector graphics language for technical
> drawing, inspired by MetaPost but with an improved C++-like syntax. Asymptote
> provides for figures the same high-quality level of typesetting that LaTeX
> does for scientific text."_ ([`README`][repo])

Two commitments follow. First, **describe, don't paint**: the manual frames it as
_"a powerful descriptive vector graphics language that provides a mathematical
coordinate-based framework for technical drawing"_ ([Description][description]) —
you write coordinate expressions and constraints, and the language resolves them.
Second, **typographic consistency by delegation**: _"Labels and equations are
typeset with LaTeX, for overall document consistency"_ ([Description][description]),
so text is never Asymptote's own font problem — it is a TeX run
([axis 4](#typesetting--text)).

---

## How it works

**The language.** Asymptote is compiled, not string-substituted. Its C++-like
front end — a lexer ([`camp.l`][src-campl]) and Bison grammar
([`camp.y`][src-campy]) — feeds a code generator ([`coder.cc`][src-coder]) that
emits bytecode instructions ([`inst.h`][src-inst]) for a **stack-based virtual
machine** ([`stack.cc`][src-stack], [`vm.h`][src-vm]) driven by the `asy` binary.
The language is statically typed with function overloading, default and rest
arguments, operator overloading, `struct`s, and a module system — _"Users may
also define their own data types as structures, along with user-defined
operators, much as in C++."_ ([Structures][structures]). A `struct` implicitly
gets a constructor from its `operator init`:

```asy
struct Person {
  string firstname, lastname;
  void operator init(string first, string last) {
    firstname=first; lastname=last;
  }
}
Person joe=Person("Joe", "Jones");   // constructor auto-generated
```

**The path / guide / pen model.** Geometry is built from `path`s — piecewise
**cubic Bézier** curves (evaluated and subdivided by [de
Casteljau][de-casteljau]) — connected by MetaPost-style _guide connectors_. `--`
is a straight segment; `..` is a curvature-minimising [Hobby spline][hobby] whose
control points Asymptote computes _"using the algorithms described in Donald
Knuth's monograph, The MetaFontbook, Chapter 14"_ ([Bézier curves][bezier]); the
`..controls..and..` form supplies explicit [cubic control
points][bezier-basis]; and `..tension..` / `{dir}` / `curl` tune the spline
(_"the higher the tension, the straighter the curve"_; `curl` _"0 means straight;
the default value of 1 means approximately circular"_ — [Bézier curves][bezier]):

```asy
size(6cm);
draw((0,0)--(1,0)--(1,1)--cycle);                    // straight segments (--)
draw((0,0)..(1,1)..(2,0), red);                       // Hobby-smooth spline (..)
draw((0,0)..controls (0.5,1) and (1.5,1)..(2,0));     // explicit cubic controls
draw((0,0){up}..tension 1.5..(2,0){down});            // direction + tension
label("$e^{i\pi}=-1$", (1,0.5));                      // LaTeX-typeset label
```

A **`guide`** is a `path` whose spline is _not yet solved_: _"a guide is similar
to a path except that the computation of the cubic spline is deferred until
drawing time"_, _"an unresolved cubic spline (list of cubic-spline nodes and
control points)"_ ([Paths and guides][paths]) — so two open guides can be joined
and the [equation-solved endpoint conditions][hobby] recomputed globally. A
`pen` carries the paint state: _"color, line type, line width, line cap, line
join, fill rule, text alignment, font, font size, pattern, overwrite mode, and
calligraphic transforms on the pen nib"_ ([Pens][pens]).

**Deferred drawing.** `draw`/`fill`/`label` do not paint immediately — they push
closures onto a `picture`. The manual: _"All of Asymptote's graphical
capabilities are based on four primitive commands. The three PostScript drawing
commands `draw`, `fill`, and `clip` add objects to a picture in the order in
which they are executed, with the most recently drawn object appearing on top."_
([Drawing commands][drawing]). Resolution is deferred because _"the translation
between user coordinate and PostScript coordinate is not determined until shipout
time"_ — so _"a deferred drawing routine is an object of type `drawer`, which is a
function with signature `void(frame f, transform t)`"_ ([Deferred
drawing][deferred]). The final [affine `transform`][affine] is chosen at
`shipout` by a **linear program** ([axis 8](#determinism-caching--performance)).

**2D and native 3D.** `import three` lifts the same syntax into 3D: _"Guides in
three dimensions are specified with the same syntax as in two dimensions except
that triples `(x,y,z)` are used"_ ([three][three]), with `path3`, `surface`
(Bézier surfaces), `material`/`light` for PBR shading, and output as interactive
vector PRC/V3D/WebGL or rasterized via `settings.render`.

---

## Object & scene model

The retained unit is the **`picture`** — an ordered display list of deferred
`drawer` closures plus a coordinate bookkeeping structure — not a tree of
individually-animatable objects (there is no `Mobject`/`ValueTracker` analog).
Pictures nest: a sub-`picture` is `fit` into a `frame` and placed inside a parent,
which is how figures compose. The drawable primitives are `path`/`guide`
(cubic-Bézier geometry, [axis "how it works"](#how-it-works)), `label`
(LaTeX text), `pen` (paint), and `frame` (a resolved, fixed-size canvas). User
_types_ are built with [`struct`][structures], so an "object model" beyond the
built-ins is something the author programs rather than a fixed class hierarchy.

Coordinate composition is ordinary [affine `transform`][affine] stacking —
`transform` values (`shift`, `rotate`, `scale`, `slant`, and their 3D
`transform3` counterparts) multiply right-to-left and are applied to points and
sub-pictures; the [`affine-transform.d`][affine-transform] probe reimplements
exactly that compose-once-apply math and its non-commutativity. The distinctive
twist is that a `picture`'s coordinates are **not purely user-space**: each point
carries a _user_ part and a _true-size_ (device-fixed) part, reconciled only at
output ([axis 8](#determinism-caching--performance)).

## Animation & timing model

**Figure-oriented, not a timeline engine — the key survey finding.** Asymptote
has no play-head, no interpolation/easing engine, no rate functions, and no
`Scene`-style [execution model][execution-models]. It renders a _figure_. The
`animation` module ([source][src-animation], _"Produce GIF, inline PDF, or other
animations"_) builds a movie the imperative way: the author writes a loop that
renders **one independent `picture` per frame** and appends it, then muxes:

```asy
import animation;
animation a;
for (int i=0; i < 20; ++i) {
  picture pic;
  draw(pic, rotate(360*i/20)*((-1,0)--(1,0)));  // author computes each frame
  a.add(pic);                                    // a separately-rendered figure
}
a.movie(delay=50);   // frames merged into a GIF via ImageMagick `convert`
```

`animation.add(picture)`, `animation.movie(...)` and `animation.merge(...)`
([source][src-animation]) drive the mux; the manual says the module _"allows one
to generate animations using the ImageMagick `magick` program to create GIF or
MPEG movies from multiple images"_ ([animation][animation]) — an **external**
`convert`/`magick` (which itself shells out to `ffmpeg` for MPEG), never an
in-process encoder ([axis 5](#output--encoding)). The sibling `animate` module
_"loads the TeX `animate` package before importing the `animation` module to
generate portable clickable PDF movies with optional controls"_ ([animate][animate]),
and `glmovie` captures OpenGL-rendered 3D frames. There is nothing to interpolate
_between_ frames — no `lerp`, no [rate function][rate-functions] — so the
[`rate-functions.d`][rate-functions] probe tabulates precisely the easing
machinery Asymptote does **not** provide. In the survey's [execution-model
taxonomy][execution-models] this is closest to a _pure frame function_, but
**eager and imperative**: the program emits every frame, rather than the engine
sampling `frame(N)` on demand.

## Rendering backend & rasterization

For 2D vector formats Asymptote **does not rasterize** — its C++ engine emits
analytic vector output (PostScript path operators; PDF/SVG derived from it), so
it is a pure [CPU-vector][cpu-vs-gpu] _producer_. The [fill rule][rasterization]
is a `pen` attribute: `zerowinding` (default nonzero) or `evenodd` (_"`z` is
considered to be outside the region if the total number of such intersections is
even"_, [Pens][pens]). Turning that vector output into pixels is delegated —
PNG via Ghostscript/ImageMagick, [SVG via `dvisvgm`][latex-to-svg] — so
[anti-aliasing and coverage][rasterization] are the downstream rasteriser's
concern, not Asymptote's.

The one place Asymptote runs its own rasteriser is **3D**: `import three` ships
an OpenGL renderer for interactive preview (`asy -V`, mouse-rotatable) and for
`settings.render=n` (n pixels per `bp`) rasterized output, with `material`/`light`
[PBR shading][three]. That is the survey's [CPU-vs-GPU split][cpu-vs-gpu] in one
tool: a deterministic CPU-vector path for 2D/print, a GPU-OpenGL path for 3D
preview and shaded rasterization. Colour lives in the `pen`: `gray`, `rgb`/`RGB`,
`cmyk`, and `hsv` models ([Pens][pens]); compositing/[gamma][color-gamma] is
whatever the PostScript/PDF interpreter applies, not something the language
re-encodes at a linear paint edge.

## Typesetting & text

Every label is a **real LaTeX run**. `label("$...$", position)` hands its string
to LaTeX so a figure's math matches the surrounding document — _"the same
high-quality level of typesetting that LaTeX does for scientific text"_
([`README`][repo]). For SVG output the typeset glyphs are converted through
[`dvisvgm`][latex-to-svg] (DVI → SVG path outlines), the same
[glyph-outline][glyph-outline] route Manim's math pipeline uses; for EPS/PDF the
LaTeX-produced graphics are embedded directly. Consequently Asymptote does **no**
in-process [text shaping][text-shaping] (no HarfBuzz/Pango) and **no** in-process
[glyph-outline extraction][glyph-outline] (no FreeType) — that entire concern is
delegated to the TeX stack, a deliberate finding-of-delegation rather than a gap.
The `asymptote.sty` LaTeX package closes the loop in the other direction:
`\usepackage{asymptote}` plus a `\begin{asy}...\end{asy}` environment embeds
figures in a document, and the `inline` option makes the document's own LaTeX
macros/symbols visible inside the figure ([LaTeX usage][latexusage]).

## Output & encoding

Asymptote's output is **vector-first**. The default 2D format tracks the TeX
engine — _"EPS for the (default) `latex` and `tex` tex engine and PDF for the
`pdflatex`, `xelatex`, `context`, `luatex`, and `lualatex` tex engines"_
([Options][options]) — and `-f format` selects EPS/PDF/SVG/PNG _"or any output
format supported by the ImageMagick `magick` program"_ ([Options][options]);
`-render n` sets the raster resolution in pixels per `bp`. **3D** adds four
targets: legacy **PRC** (embedded interactive in PDF), modern compressed **V3D**
(`settings.outformat="v3d"`), **WebGL** (interactive in HTML), and OpenGL preview
([three][three]).

Video/animation is **external muxing** ([axis 2](#animation--timing-model)): the
`animation` module exports per-frame images and merges them into GIF/MPEG via the
ImageMagick `convert`/`magick` program ([animation][animation],
[source][src-animation]); `animate` produces clickable PDF movies via the TeX
`animate` package. There is no in-process [libav/codec/muxer][codec] — the
[pixel-format → codec → container][codec] pipeline is handled by the external
tools, so reproducible encodes require pinning those toolchains, not an Asymptote
setting. The [`frame-capture.d`][frame-capture] probe models the framebuffer
readback → hash step that Asymptote's vector-first model largely _sidesteps_ for
2D (there is no pixel buffer until a downstream rasteriser runs).

## Interactivity, preview & authoring

Authoring is **code-first `.asy` files**, run either in batch (`asy figure.asy`)
or in an **interactive REPL** (`asy` with GNU Readline line editing —
[Interactive mode][manual]). The strongest interactive surface is the built-in
**OpenGL viewer** (`asy -V`): a 3D figure opens in a window you rotate, pan, and
zoom with the mouse before committing to a static render. Beyond the CLI there is
a Tk GUI (`xasy`) for point-and-click editing and an editor-facing **Language
Server** ([LSP][manual]). Crucially, interactivity also lives in the _output_:
PRC-in-PDF and WebGL-in-HTML figures stay rotatable/zoomable in the reader's
PDF/browser viewer — the 3D scene is shipped as vectors, not baked to pixels.
Document authoring integrates via `asymptote.sty` + `latexmk`, which _"will then
call Asymptote automatically, recompiling only the figures that have changed"_
([LaTeX usage][latexusage]).

## Extensibility & API surface

The API surface _is a programming language_, which is the whole design bet.
Extensibility comes from ordinary language features — `struct`s with implicit
constructors ([Structures][structures]), function/operator overloading, default
and rest arguments, and a module system (`import`, `access`, `unravel`) — rather
than a plugin protocol. `import Person unravel` is auto-generated so a struct's
constructor is usable unqualified ([Structures][structures]). On top of that sits
a large **standard module library** (manual chapters _User modules_ and
_Specialty modules_): `graph`/`graph3` (plotting), `three`/`solids`/`tube`
(3D geometry), `geometry`, `contour`/`smoothcontour3`, `palette`/`colormap`,
`patterns`, `flowchart`, `feynman`, `ode`/`lmfit`, and — notably for this page —
`simplex`/`simplex2` (the LP solver the sizing engine itself uses). Users extend
Asymptote by writing more such modules, exactly as they write figures.

## Determinism, caching & performance

Vector output is deterministic and reproducible (PostScript path emission has no
driver-dependent rasterisation), which is why the LaTeX integration can cache
aggressively — `latexmk` recompiles _"only the figures that have changed"_
([LaTeX usage][latexusage]). The distinctive mechanism is the **deferred-sizing
linear program**. Because a `picture` mixes user coordinates with fixed
true-size coordinates ([axis 1](#object--scene-model)) — a coordinate in _"flex
space … a linear combination of user and true-size"_ ([`plain_scaling.asy`][src-scaling])
— the final [scaling transform][affine] is not knowable until `shipout`. Asymptote
resolves it by optimization: `calculateScaling` _"Solve[s] the two-variable
linear programming problem using the simplex method"_ ([`plain_scaling.asy`][src-scaling]),
maximizing the drawing's scale subject to the requested `size()` bounds, reporting
`OPTIMAL`/`UNBOUNDED` from the [`simplex2`][src-simplex2] `problem` solver. That is
a genuine [constraint-and-optimization layout step][constraint-layout] hiding
inside every sized figure — the same lineage as MetaPost's
[equation-solved points][hobby], applied to page fitting rather than curve
control. There is **no content-hash frame cache** (frames are not first-class,
[axis 2](#animation--timing-model)); caching is per-figure at the document layer.
Determinism holds for the vector path but, as everywhere, [the GPU/OpenGL 3D
path][cpu-vs-gpu] is not bit-identical across drivers — see the survey's general
[deterministic-frame-sampling][determinism] note.

## Strengths

- **A real programming language for figures** — static typing, `struct`s,
  overloading, modules, and a stack-VM compiler mean loops, functions, and
  coordinate algebra are first-class, not macro-expanded (the stated advantage
  over "just a graphics application", [Description][description]).
- **Native, interactive 3D** — `triple`/`path3`/`surface` with PBR shading, and
  output as _viewer-interactive_ PRC-in-PDF and WebGL-in-HTML, a capability most
  2D vector engines lack entirely.
- **MetaPost-quality curves** — [Hobby splines][hobby] via `..`, explicit cubic
  controls, tension/direction/curl, and `guide`s that solve endpoint conditions
  globally at draw time.
- **Publication-grade text for free** — labels are typeset by LaTeX, matching the
  host document; SVG glyphs route through [`dvisvgm`][latex-to-svg].
- **Constraint-based sizing** — the [simplex sizing LP][src-scaling] lets figures
  be specified in scale-free user units and fit to an exact output size.
- **Vector-first, reproducible output** — deterministic EPS/PDF/SVG suitable for
  print, with document-level figure caching.

## Weaknesses

- **Not an animation engine** — no timeline, interpolation, easing, or play-head;
  animation is a manual frame loop muxed by external ImageMagick/`ffmpeg`
  ([axis 2](#animation--timing-model)).
- **Heavy external toolchain** — a full LaTeX distribution is required for _any_
  label; SVG needs `dvisvgm`, PNG/GIF/MPEG need Ghostscript/ImageMagick/`ffmpeg`.
- **Idiosyncratic language** — a bespoke C++-like DSL with its own semantics
  (implicit scaling, `unravel`, deferred drawing) and a smaller ecosystem than
  general-purpose languages; the learning curve is real.
- **No in-process text stack** — [shaping][text-shaping] and
  [glyph extraction][glyph-outline] are delegated to TeX, so non-TeX text
  workflows are awkward.
- **3D preview isn't reproducible** — the OpenGL/[GPU path][cpu-vs-gpu] varies by
  driver; only the vector path is bit-stable.
- **Legacy 3D friction** — PRC is a legacy format whose PDF embedding depends on
  reader support (`media9`/Adobe), with V3D/WebGL the modern replacements.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                                    | Trade-off                                                                                       |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| A **full C++-like language** compiled to a **bytecode VM** | Figures are programs — loops, types, functions, modules — not macro expansions               | A bespoke language + toolchain to learn; smaller ecosystem than a host language                 |
| **Descriptive** MetaPost model (`path`/`guide`/`pen`)      | Cubic-Bézier + [Hobby][hobby] curves and equation-solved points, typographic pen             | You describe a figure, not an animatable scene; no object-level timeline                        |
| **Deferred drawing** resolved at `shipout`                 | Mix user + true-size coordinates; place fixed-size marks correctly at any scale              | Nothing is painted until output; coordinates are two-part `flex space`                          |
| **Simplex LP** for `size()` fitting                        | Scale-free authoring that fits an exact output size ([constraint layout][constraint-layout]) | Sizing is an optimization with `UNBOUNDED` edge cases; hidden cost per figure                   |
| **LaTeX** for all text                                     | Document-consistent, publication-grade math typesetting                                      | Hard dependency on a TeX install; no in-process [shaping][text-shaping]/[glyphs][glyph-outline] |
| **Vector-first** 2D output (delegate rasterization)        | Deterministic, print-quality EPS/PDF/SVG; small, portable engine                             | Needs Ghostscript/ImageMagick/`dvisvgm` for pixels; [AA][rasterization] is downstream's job     |
| **Native 3D** with its own OpenGL renderer + PRC/V3D/WebGL | True 3D vector graphics, interactive in PDF/HTML — rare among vector tools                   | GPU preview not bit-reproducible; PRC is legacy and viewer-dependent                            |
| **Animation = batched figures + external mux**             | Reuses the whole 2D/3D pipeline per frame with zero new engine code                          | No interpolation/easing/caching; depends on ImageMagick/`ffmpeg` ([axis 5](#output--encoding))  |

---

## Sources

- [Asymptote reference manual][manual] — Copyright © 2004–2026 Andy Hammerlindl,
  John Bowman, Tom Prince; online snapshot **3.13-36**. Chapters cited:
  [Description][description] (positioning, output formats), [Bézier curves][bezier]
  (cubic formula, MetaFontbook/Hobby control-point algorithm, tension/curl),
  [Paths and guides][paths] (guide = deferred cubic spline), [Drawing
  commands][drawing] (four primitives, deferred ordering), [Deferred
  drawing][deferred] (`drawer` signature, shipout-time coordinate resolution),
  [Pens][pens] (attribute list, colour models, fill rules, opacity),
  [Structures][structures] (`struct`/`operator init`), [three][three] (native 3D,
  PRC/V3D/WebGL/OpenGL), [animation][animation] / [animate][animate] (GIF/MPEG via
  ImageMagick, clickable PDF movies), [LaTeX usage][latexusage] (`asymptote.sty`,
  `latexmk` caching), [Options][options] (formats, `-f`, `-render`).
- [`vectorgraphics/asymptote`][repo] — source repo (`master`). `README`
  (positioning quote), [`LICENSE.LESSER`][license-lesser] (LGPL v3),
  [`LICENSE`][license-gpl] (GPL v3 for the Windows binary). Engine internals:
  [`camp.l`][src-campl]/[`camp.y`][src-campy] (lexer/parser),
  [`coder.cc`][src-coder]/[`inst.h`][src-inst] (bytecode),
  [`stack.cc`][src-stack]/[`vm.h`][src-vm] (stack VM). Base modules:
  [`plain_scaling.asy`][src-scaling] (the simplex sizing LP + "flex space"),
  [`animation.asy`][src-animation] (`add`/`movie`/`merge`/`glmovie`),
  [`simplex2.asy`][src-simplex2] (the LP `problem` solver).
- [asymptote.sourceforge.io][site] — project site, binaries, and the manual PDF
  (current stable release **3.09**).

<!-- References -->

[repo]: https://github.com/vectorgraphics/asymptote
[license-lesser]: https://github.com/vectorgraphics/asymptote/blob/master/LICENSE.LESSER
[license-gpl]: https://github.com/vectorgraphics/asymptote/blob/master/LICENSE
[site]: https://asymptote.sourceforge.io
[manual]: https://asymptote.sourceforge.io/doc/index.html
[description]: https://asymptote.sourceforge.io/doc/Description.html
[bezier]: https://asymptote.sourceforge.io/doc/Bezier-curves.html
[paths]: https://asymptote.sourceforge.io/doc/Paths-and-guides.html
[drawing]: https://asymptote.sourceforge.io/doc/Drawing-commands.html
[deferred]: https://asymptote.sourceforge.io/doc/Deferred-drawing.html
[pens]: https://asymptote.sourceforge.io/doc/Pens.html
[structures]: https://asymptote.sourceforge.io/doc/Structures.html
[three]: https://asymptote.sourceforge.io/doc/three.html
[animation]: https://asymptote.sourceforge.io/doc/animation.html
[animate]: https://asymptote.sourceforge.io/doc/animate.html
[latexusage]: https://asymptote.sourceforge.io/doc/LaTeX-usage.html
[options]: https://asymptote.sourceforge.io/doc/Options.html
[src-campl]: https://github.com/vectorgraphics/asymptote/blob/master/camp.l
[src-campy]: https://github.com/vectorgraphics/asymptote/blob/master/camp.y
[src-coder]: https://github.com/vectorgraphics/asymptote/blob/master/coder.cc
[src-inst]: https://github.com/vectorgraphics/asymptote/blob/master/inst.h
[src-stack]: https://github.com/vectorgraphics/asymptote/blob/master/stack.cc
[src-vm]: https://github.com/vectorgraphics/asymptote/blob/master/vm.h
[src-scaling]: https://github.com/vectorgraphics/asymptote/blob/master/base/plain_scaling.asy
[src-animation]: https://github.com/vectorgraphics/asymptote/blob/master/base/animation.asy
[src-simplex2]: https://github.com/vectorgraphics/asymptote/blob/master/base/simplex2.asy
[bezier-basis]: ./concepts.md#bezier-basis-quadratic-vs-cubic
[de-casteljau]: ./concepts.md#de-casteljau-evaluation
[hobby]: ./concepts.md#hobby-splines-and-equation-solved-points
[affine]: ./concepts.md#affine-transform-and-coordinate-space
[constraint-layout]: ./concepts.md#constraint-and-optimization-based-layout
[latex-to-svg]: ./concepts.md#latex-to-svg
[glyph-outline]: ./concepts.md#glyph-outline-extraction
[text-shaping]: ./concepts.md#text-shaping
[rasterization]: ./concepts.md#rasterization
[cpu-vs-gpu]: ./concepts.md#cpu-vector-vs-gpu-vector-rendering
[color-gamma]: ./concepts.md#color-model-and-gamma
[execution-models]: ./concepts.md#execution-models
[codec]: ./concepts.md#codec-muxing-and-pixel-format
[determinism]: ./concepts.md#deterministic-frame-sampling
[bezier-eval]: ./examples/bezier-eval.d
[affine-transform]: ./examples/affine-transform.d
[frame-capture]: ./examples/frame-capture.d
[rate-functions]: ./examples/rate-functions.d
