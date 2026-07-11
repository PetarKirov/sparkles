# MetaPost (equation-solved vector graphics)

John Hobby's METAFONT-descended graphics language where you write **linear
equations relating points** and a built-in solver finds their coordinates — the
historical origin of solved-constraint drawing and of the **Hobby splines** that
choose good cubic-Bézier control points for a smooth curve through a sequence of
points.

| Field          | Value                                                                                                                                             |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | MetaPost — a declarative graphics language descended from Knuth's [METAFONT][mf], compiled by `mpost` (a thin wrapper over the `mplib` C library) |
| License        | [LGPL][ctan-json] — GNU Lesser General Public License (CTAN metadata `"license": "lgpl"`)                                                         |
| Repository     | TeX Live `texk/web2c/mplibdir` ([canonical SVN][ctan], [GitLab mirror][repo]); `#define metapost_version "3.00"` in [`mp.w`][mpw]                 |
| Documentation  | [_A User's Manual for MetaPost_][manual] (Hobby, AT&T tech. report); [_Drawing Graphs with MetaPost_][mpgraph]                                    |
| Category       | Equation-solved / constraint-style **vector-graphics language** — makes single **static** EPS/SVG figures, not animation                          |
| First release  | 1994 ([Wikipedia][wiki]); the language is derived from Knuth's METAFONT (1980s)                                                                   |
| Author         | John D. Hobby (AT&T Bell Laboratories); now maintained by the MetaPost dev team (Taco Hoekwater, Luigi Scarso)                                    |
| Solver         | Built-in **linear-equation solver** — incremental elimination of linear dependencies among unknowns, inherited from METAFONT                      |
| Output formats | PostScript / **EPS** (default), **SVG** (`outputformat:="svg"`), **PNG** (rasterized); vector Bézier geometry throughout                          |

> [!NOTE]
> This page is grounded in **John D. Hobby's original AT&T manual**
> ([_A User's Manual for MetaPost_][manual], extracted from the PDF's text
> streams — letters verbatim, inter-word spacing reconstructed), the CTAN
> [package record][ctan] / [JSON metadata][ctan-json], the current source
> ([`mp.w`][mpw], `metapost_version "3.00"`), the [`mpost` manual page][mpost-man],
> and Paul Murrell's [`mplib` report][mplib-report]. MetaPost emits EPS/SVG on a
> batch compiler, so no `ci`-compiled D probe reproduces its output; the catalog's
> [`bezier-eval.d`][bezier-eval] probe reimplements the cubic-Bézier evaluation
> ([de Casteljau][de-casteljau]) its `..` paths rest on, and
> [`affine-transform.d`][affine-transform] the
> `transformed` math its `transform` type provides.

---

## Overview

### What it solves

MetaPost solves the problem of drawing a **precise technical figure** without
hand-computing every coordinate. The classical alternative — a low-level device
language (PostScript) or a drawing GUI — forces the author to know each point's
position up front; MetaPost lets the author instead state the _relationships_
that pin the points down (this is the midpoint of those two, that one is on the
line through these, these two are reflections) and have the interpreter deduce
the actual numbers. It is the ancestor this survey traces the modern
[equation-solved / constraint school][constraint-layout] back to: TikZ's `calc`
library, Asymptote, and Penrose all inherit the idea that a diagram is specified
by _constraints on_ points rather than coordinates _of_ points. The manual frames
the tool as a METAFONT for print graphics:

> _"The MetaPost system implements a picture-drawing language very much like
> Knuth's METAFONT except that it outputs PostScript commands instead of
> run-length-encoded bitmaps. MetaPost is a powerful language for producing
> figures for documents to be printed on PostScript printers."_ ([manual][manual],
> Abstract)

### Design philosophy

The load-bearing design decision — the one everything else on this page descends
from — is that **equation solving is a language primitive**, borrowed wholesale
from METAFONT so that programs read declaratively rather than procedurally:

> _"Another feature borrowed from METAFONT is the ability to solve linear
> equations that are given implicitly, thus allowing many programs to be written
> in a largely declarative style. By building complex operations from simpler
> ones, MetaPost achieves both power and flexibility."_ ([manual][manual], §1)

The `=` operator does not assign; it **contributes an equation** to a global
system the interpreter keeps solving as it reads. The manual's minimal example
makes the distinction concrete:

> _"An important feature taken from METAFONT is the ability to solve linear
> equations so that programs can be written in a partially declarative fashion.
> For example, the MetaPost interpreter can read `a+b=3; 2*a=b+3;` and deduce
> that `a=2` and `b=1`."_ ([manual][manual], §4)

MetaPost is deliberately a _small_ language sitting on a _large_ set of built-in
value types — the shared vocabulary this survey calls out as the raw material of
a graphics engine: _"These include numbers, coordinate pairs, cubic splines,
affine transformations, text strings, and boolean quantities"_
([manual][manual], §1). Its philosophy is to make each of those first-class and
let the equation solver glue them together.

---

## How it works

### Points as coordinate-pair unknowns

A figure is written between `beginfig(n)` and `endfig`. Points are the pair
variables `z1`, `z2`, … — and `z`_k_ is not special syntax so much as a
convenient spelling: _"the `z⟨number⟩` … is an abbreviation for
`(x⟨number⟩,y⟨number⟩)`. This makes it possible to give values to `z` variables
by giving equations involving their coordinates"_ ([manual][manual], §4.1). So
you can constrain a whole point at once or constrain its coordinates
independently, and the solver reconciles them:

```metapost
beginfig(1);
  z1 = (0,0);                 % an equation, not an assignment
  z2 = z1 + (3cm,0);          % z2 solved relative to z1
  z3 = 0.5[z1,z2];            % z3 is the midpoint of z1 and z2
  x4 = x1;  y4 = y2;          % constrain coordinates separately
  draw z1--z2;  draw z3--z4;
endfig;
```

The `0.5[z1,z2]` is MetaPost's **mediation** operator — the linear-interpolation
primitive the survey elsewhere calls [lerp][hobby-eq]: _"This mediation
construction `z4=1/3[z3,z6]` means that `z4` is 1/3 of the way from `z3` to `z6`;
i.e., `z4 = z3 + 1/3(z6-z3)`"_ ([manual][manual], §4.1). Because every side of an
equation must be a linear combination of knowns and unknowns, the solver only
ever faces **linear** systems and can eliminate dependencies incrementally as
equations arrive.

### `whatever` — the anonymous unknown for intersections

To say "these two lines cross _somewhere_" without naming the parameter, MetaPost
provides `whatever`, a fresh anonymous unknown. It is what makes line-intersection
constraints declarative:

```metapost
z20 = whatever[z1,z3] = whatever[z2,z4];   % z20 = intersection of lines 1-3 and 2-4
```

Each `whatever` is a distinct unknown the solver discharges, subject to the
linearity rule: _"`z20=whatever[z1,z3]` is legal only when a known value has
previously been specified for the difference `z3-z1`, because the equation is
equivalent to `z20 = z1 + whatever*(z3-z1)` and the linearity requirement
disallows multiplying unknown components … by the anonymous unknown result of
`whatever`"_ ([manual][manual], §4.2).

### Hobby splines — smooth curves through points (`..`)

The second half of MetaPost's originality is **how it draws through the points it
just solved for.** The `--` connector makes straight segments; the `..` connector
makes a smooth curve:

> _"MetaPost is perfectly happy to draw curved lines as well as straight ones. A
> `draw` statement with the points separated by `..` draws a smooth curve through
> the points."_ ([manual][manual], §3)

Under the hood that smooth curve is a chain of **cubic Béziers** whose control
points MetaPost _chooses for you_ so the joins are visually fair — the
[Hobby-spline algorithm][hobby-eq], the same one this survey notes makes MetaPost
curves [cubic Béziers][bezier-basis] rather than the quadratics some engines
store. The manual states the piecewise-cubic model and its continuity target
outright:

> _"… a curve with continuous slope and approximately continuous curvature. …
> a path specification such as `z0..z1..z2..z3..z4..z5` results in a curve that
> can be defined parametrically as `(X(t),Y(t))` for `0≤t≤5`, where `X(t)` and
> `Y(t)` are piecewise cubic functions."_ ([manual][manual], §3.1)

and defers the control-point selection to Hobby's own paper — the primary
citation for the algorithm this whole survey axis rests on:

> _"The precise rules for choosing the Bézier control points are described in [2]
> and in The METAFONTbook."_ ([manual][manual], §3.1)

where reference **[2]** is _"J. D. Hobby. Smooth, easy to compute interpolating
splines. Discrete and Computational Geometry, 1(2), 1986"_ ([manual][manual],
References; [DOI][hobby-paper]). Where the default curve misbehaves, three
optional specifiers steer it — **direction**, **tension**, and **curl**:

```metapost
draw z0{up}..tension 1.5..{right}z1;   % leave z0 upward, taut, arrive at z1 rightward
draw z0{curl 2}..z1..z2;               % looser curl at the open end
```

> _"Another way to control a misbehaving path is to increase the ‘tension’
> parameter. Using `..` in a path specification sets the tension parameter to the
> default value 1. If this makes some part of a path a little too wild, we can
> selectively increase the tension."_ ([manual][manual], §3.2)

> _"MetaPost paths also have a parameter called ‘curl’ that affects the ends of a
> path. In the absence of any direction specifications, the first and last
> segments of a non-cyclic path are approximately circular arcs …"_
> ([manual][manual], §3.2)

### Pens, `draw`, `fill`, `label`

Drawing statements accumulate into an implicit picture. Strokes use a **pen**
(_"The main function of pens in MetaPost is to determine line thickness, but they
can also be used to achieve calligraphic effects"_, [manual][manual], §1); the
idiom to set line width is the famous `pickup pencircle scaled 4pt`
([manual][manual], §2). `fill` shades a closed path; `label` places text:

```metapost
pickup pencircle scaled 4pt;
draw (2u,2u)--(0,0)--(0,3u)--(3u,0)--(0,0);   % stroke a polyline (Manual Fig. 2)
fill fullcircle scaled 2u withcolor 0.8white;  % fill a cyclic path
label.top(btex $x^2$ etex, z3);                % typeset a TeX label at z3
```

`fill` requires a cyclic path: _"the `fill` statement requires a `⟨path
expression⟩` … the argument should be a cyclic path, i.e., a path that describes
a closed curve via the `..cycle` or `--cycle` notation"_ ([manual][manual], §5),
and `withcolor` tints it (_"`fill ⟨path expression⟩ withcolor ⟨color
expression⟩` specifies a shade of gray or … some rainbow color"_,
[manual][manual], §5).

### `btex … etex` — TeX labels

Labels that need mathematics are handed to TeX:

> _"If you say `btex ⟨typesetting commands⟩ etex` in a MetaPost input file, the
> `⟨typesetting commands⟩` get processed by TeX and translated into a picture
> expression … that can be used in a `label` or `dotlabel` statement."_
> ([manual][manual], §6)

This is the direct ancestor of the [LaTeX-to-vector pipeline][latex-svg] the
Manim forks still use — text becomes a picture of filled glyph outlines,
composited into the figure like any other geometry.

---

## Object & scene model

MetaPost has **no retained mutable scene graph** in the [Mobject sense][scenegraph] — no
tree of persistent, individually-animatable nodes with parent/child identity.
Its "objects" are **values** of a fixed set of types, and its "scene" is the
`picture` a figure accumulates. The manual enumerates the value algebra:
_"numbers, coordinate pairs, cubic splines, affine transformations, text strings,
and boolean quantities"_ ([manual][manual], §1), plus `pen`, `color`, and
`picture`. Drawing mutates one implicit picture:

> _"Anything that can be drawn in MetaPost can be stored in a picture variable.
> In fact, the `draw` statement actually stores its results in a special picture
> variable called `currentpicture`. Pictures can be added to other pictures and
> operated on by transforms."_ ([manual][manual], §1)

So the composition unit is not a node tree but **the equation system plus the
`currentpicture`**: you solve for the points, stamp geometry into the picture,
and `endfig` freezes it. The [affine-transform][affine] machinery this survey
treats as universal is a first-class MetaPost type — _"an arbitrary affine
transformation … any combination of rotating, scaling, slanting, and shifting.
If `p=(px,py)` is a pair and `T` is a transform, `p transformed T` is a pair of
the form `(tx + txx·px + txy·py, ty + tyx·px + tyy·py)`"_ ([manual][manual], §2)
— exactly the six-number `2×3` matrix the [`affine-transform.d`][affine-transform]
probe composes. Objects can even be _solved for as transforms_, since a
`transform` unknown is six numeric unknowns the same solver handles.

## Animation & timing model

**Not applicable — finding of absence.** MetaPost is a **static-figure**
compiler: it has no timeline, no play-head, no interpolation/easing engine, and
none of the five [execution models][execution-models] this survey catalogs
(imperative play-loop, generator, pure frame function, reactive, keyframe
timeline). The one thing that _looks_ like tweening is the mediation operator
`t[a,b]` — genuine [lerp][hobby-eq], but a spatial construct, not a temporal one:
it interpolates _positions_ at author time, not _frames_ over playback time.
The only route to motion is external: because each `beginfig(n)` writes a
separate numbered output file (`⟨job⟩.n` / `⟨job⟩-n.svg`), a MetaPost program
_can_ emit a numbered sequence of stills that an **outside** tool assembles into
frames — but frame sampling, rate functions, and animation composition are simply
not language concepts. Any "animated MetaPost" (e.g. GIF loops) is a shell around
mpost, not a feature of it.

## Rendering backend & rasterization

MetaPost does **not [rasterize][rasterization]** in its primary path. `mpost`
emits **vector** output — stroked and filled cubic-Bézier paths as PostScript or
SVG drawing operators — and leaves pixels to a downstream device:

> _"MetaPost interprets the MetaPost language and produces PostScript (EPS) or
> Scalable Vector Graphics (SVG) pictures."_ ([`mpost` man page][mpost-man])

Rasterization to **PNG** is a bolt-on: historically the EPS was run through
Ghostscript; modern `mplib` carries a PNG backend (Cairo-based) so a figure can
go straight to pixels. Colour is authored as a `color` value and written to the
output as gray, RGB, or (for print) CMYK — the [colour model][color-gamma] is the
output device's, not MetaPost's; there is no linear-vs-sRGB compositing question
because MetaPost does not composite pixels, it hands the device analytic paths.
In this survey's [CPU-vs-GPU][rasterization] framing MetaPost is the extreme
CPU-vector end: fully deterministic, resolution-independent vector geometry, with
rasterization entirely delegated.

## Typesetting & text

Text is MetaPost's oldest tie to TeX and the model the Manim forks still echo.
Two routes exist. The classic one is [`btex … etex`][latex-svg]: the enclosed
material is compiled by TeX into a `picture` (a bundle of filled
[glyph outlines][glyph-outline]) and placed with `label`/`dotlabel`
([manual][manual], §6). The `label` statement is the placement primitive —
_"`label⟨labelsuffix⟩(⟨string or picture expression⟩, ⟨pair expression⟩)`; the
`⟨string or picture expression⟩` gives the label and the `⟨pair expression⟩`
says where to put it"_ ([manual][manual], §6) — with suffixes (`.top`, `.lft`, …)
choosing the offset direction. Because a TeX-set label arrives as vector glyph
outlines, it scales and transforms like any other geometry, and the whole figure
stays resolution-independent. The lightweight route is `infont`, which sets a
plain string in a named font without invoking TeX. Either way, MetaPost is where
the "route math text through TeX, keep the result as vector paths" pattern this
survey attributes to Manim's [LaTeX→SVG pipeline][latex-svg] originates.

## Output & encoding

The output axis is where MetaPost's static nature shows. Each figure is one
file; the format is chosen by internal variables rather than a codec stack:

| Setting                         | Effect                                                         |
| ------------------------------- | -------------------------------------------------------------- |
| default                         | Encapsulated PostScript (`⟨job⟩.⟨fig⟩`), embeddable in TeX/DVI |
| `outputformat := "svg"`         | Scalable Vector Graphics per figure                            |
| `outputformat := "png"`         | Rasterized PNG (via the `mplib` image backend)                 |
| `outputtemplate := "%j-%c.svg"` | Names files from job (`%j`) + figure number (`%c`)             |

CTAN summarizes the vector-first stance verbatim: _"Its output is scalable
PostScript or SVG, rather than the bitmaps Metafont creates"_ ([CTAN][ctan]).
There is **no video/codec/muxing layer at all** — no `yuv420p` conversion, no
`libx264`, no container — because the unit of output is a single still. The
survey's [output-and-encoding concerns][execution-models] (pixel-format
conversion, encoder pinning, partial-movie concatenation) have no MetaPost
analogue; a figure sequence is stitched, if ever, by an external pipeline.

## Interactivity, preview & authoring

Authoring is **batch, code-first**: write a `.mp` file, run `mpost file`, get
figures. MetaPost also has a genuine REPL — an interactive `*` prompt that reads
statements and can display results — but there is **no scrubbable timeline or
live canvas** of the Motion-Canvas/Theatre.js kind, because there is no timeline
to scrub. The important modern authoring story is **embedding**: MetaPost was
refactored into `mplib`, a reusable C library, so the engine can run _inside_
another program instead of as a subprocess. Paul Murrell's report states the
architecture plainly — _"The MetaPost compiler is built on a MetaPost compiler
library called mplib"_ and _"There is a Lua binding for the mplib library that
allows MetaPost code to be embedded directly within a LuaTeX document"_
([mplib-report][mplib-report]). That binding is [`luamplib`][luamplib]: it runs
MetaPost figures at TeX compile time with no external `mpost` process, which is
the closest thing MetaPost has to live preview — edit the source, recompile the
document, see the figure.

## Extensibility & API surface

Two extension surfaces. **In-language**, MetaPost is macro-extensible via `def`
and `vardef`, and a large body of that macro programming ships as packages —
`plain.mp` (the base macros: `draw`, `fill`, `pickup`, `fullcircle`, …), `boxes`,
`graph` (the graph-drawing package of [_Drawing Graphs with MetaPost_][mpgraph]),
and community `mfun`/`metafun` layers. New drawing verbs are ordinary macros over
the built-in `addto … contour/doublepath` primitives, not plugins. **At the C
level**, `mplib` is the API: the engine "as a reusable component"
([mplib paper][mplib-paper]) exposes functions to feed MetaPost source, run it,
and read back the resulting figures — _"The mplib library provides C functions
that allow us to define MetaPost paths, and solve them, in C code"_
([mplib-report][mplib-report]). That C surface is why MetaPost shows up embedded
in LuaTeX, in R (the CRAN `metapost` interface), and in bespoke tools, rather
than only as a command-line compiler.

## Determinism, caching & performance

MetaPost is **fully deterministic and reproducible**: the same source yields the
same vector output on any platform, because the geometry is computed analytically
(linear solving plus closed-form Bézier control-point selection) and the output
is device-independent PostScript/SVG — the ideal [deterministic-oracle][determinism]
end of the CPU-vector spectrum. Units are fixed, not device-relative: _"pixels
per inch is irrelevant since MetaPost uses fixed units of PostScript points"_
([manual][manual], Appendix). The equation solver is the performance-relevant
core; it processes **linear** systems only, eliminating dependencies
incrementally as equations arrive, so solving is cheap and predictable rather
than an iterative optimizer's convergence (contrast the
[constraint/optimization school][constraint-layout], which minimises a nonlinear
energy and is seed/iteration-sensitive). There is **no frame cache** — there are
no frames — and no partial-render memoization; a figure is recomputed from source
each run, which is fast because a figure is small. (Current `mplib` adds
selectable numeric back-ends — `scaled` fixed-point, IEEE `double`, and
arbitrary-precision `decimal`/`binary` — trading reproducibility granularity for
range, but the default behaviour remains deterministic per number system.)

## Strengths

- **Equation-solved points are the original declarative-graphics idea** — state
  relations (`z3=0.5[z1,z2]`, `whatever` intersections), let the solver find
  coordinates. Everything the modern [constraint school][constraint-layout]
  inherits starts here.
- **Hobby splines give good curves for free** — `..` picks fair cubic-Bézier
  control points ([Hobby's 1986 algorithm][hobby-paper]) with `tension`/`curl`/
  direction knobs, so a smooth curve through points needs no handle-fiddling.
- **Vector-native and device-independent** — analytic paths out to EPS/SVG,
  resolution-independent and bit-reproducible; the deterministic-oracle extreme.
- **First-class affine transforms and TeX text** — `transform` is a solvable
  type; `btex…etex` embeds real mathematics as vector glyph outlines (the
  ancestor of Manim's [LaTeX pipeline][latex-svg]).
- **Embeddable as `mplib`** — a reusable C library, live inside LuaTeX via
  [`luamplib`][luamplib], not just a CLI.
- **Mature, tiny, LGPL** — decades stable, small surface, part of every TeX
  distribution.

## Weaknesses

- **No animation whatsoever** — static figures only; no timeline, easing,
  play-head, or frame model ([axis 2](#animation--timing-model)). Motion is an
  external shell around numbered stills.
- **No output/encoding pipeline** — one file per figure; no video/codec/muxing
  ([axis 5](#output--encoding)).
- **Linear-only solver** — the declarative power stops at _linear_ equations;
  nonlinear relations (true `whatever`-through-a-curve, general geometric
  constraints) must be worked around or precomputed.
- **Idiosyncratic, terse syntax** — `pickup pencircle scaled 4pt`, suffix labels,
  `=` as equation-not-assignment: a steep, dated learning curve.
- **Text needs a TeX install** — `btex…etex` requires a working TeX toolchain,
  the same heavyweight dependency the Manim forks carry.
- **Batch, not interactive** — no live canvas; the fastest feedback loop is
  recompiling a LuaTeX document.

## Key design decisions and trade-offs

| Decision                                             | Rationale                                                                  | Trade-off                                                                          |
| ---------------------------------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `=` contributes a **linear equation**, not an assign | Declarative figures: state relations, solver deduces coordinates           | Only linear systems; `:=` needed for genuine reassignment; surprising to newcomers |
| **Incremental linear-dependency elimination** solver | Cheap, deterministic, predictable — no iteration or seed                   | Cannot express nonlinear/global geometric constraints                              |
| `..` = **Hobby-spline** smooth curve through points  | Good default cubic-Bézier control points with tension/curl/direction knobs | The chosen curve is an algorithmic default; exact control still means handles      |
| **Cubic-Bézier** curve model                         | Matches PostScript/SVG's native curve; smooth, transformable geometry      | Heavier than quadratics for a GPU tessellator (a non-issue for a vector emitter)   |
| **Vector output** (EPS/SVG), rasterize only for PNG  | Resolution-independent, reproducible, embeddable in TeX                    | Delegates all pixel/AA/gamma questions; no in-engine raster control                |
| **Static single figures**, no timeline               | Focus entirely on precise still diagrams                                   | Zero animation model; frame sequences are an external concern                      |
| **`btex…etex` → TeX** for text                       | Real typeset mathematics as vector glyph outlines                          | Requires a TeX toolchain; the classic heavyweight-text-dependency trade            |
| Refactor engine into **`mplib`** C library           | Reuse the compiler in-process (LuaTeX, R, tools)                           | A C-API surface to maintain; the CLI `mpost` becomes a thin wrapper                |

---

## Sources

- [_A User's Manual for MetaPost_][manual] — John D. Hobby, AT&T Bell
  Laboratories (maintained by the MetaPost dev team). The primary source for the
  equation-solving model (§1, §4), the `z`/coordinate-pair and mediation syntax
  (§4.1), `whatever` (§4.2), the `..` smooth-curve / Hobby-spline model and
  `tension`/`curl` (§3–§3.2), pens/`draw`/`fill`/`label` (§1, §2, §5), and
  `btex…etex` (§6). Reference **[2]** therein is Hobby's spline paper.
- [J. D. Hobby, _Smooth, easy to compute interpolating splines_][hobby-paper],
  Discrete & Computational Geometry **1(2)**, 1986 — the algorithm behind `..`.
- [_Drawing Graphs with MetaPost_][mpgraph] — Hobby; the `graph` package.
- [CTAN: `metapost`][ctan] and its [JSON metadata][ctan-json] — description
  (_"scalable PostScript or SVG"_), `"license": "lgpl"`, author record
  (_"The METAPOST Team; John Hobby (inactive)"_), home/repository URLs.
- [`mp.w`][mpw] (TeX Live source) — `#define metapost_version "3.00"` (current).
- [`mpost` manual page][mpost-man] — _"produces PostScript (EPS) or Scalable
  Vector Graphics (SVG) pictures."_
- [Paul Murrell, _Building an mplib Shared Library_][mplib-report] and
  [T. Hoekwater, _MPlib: MetaPost as a reusable component_ (TUGboat)][mplib-paper]
  — the `mplib` C library and its LuaTeX embedding.
- [`luamplib`][luamplib] — the Lua binding running MetaPost inside LuaTeX.
- [MetaPost — Wikipedia][wiki] — first-release year (1994), current maintainers.

<!-- References -->

[manual]: https://www.tug.org/docs/metapost/mpman.pdf
[mpgraph]: https://www.tug.org/docs/metapost/mpgraph.pdf
[hobby-paper]: https://doi.org/10.1007/BF02187687
[ctan]: https://ctan.org/pkg/metapost
[ctan-json]: https://ctan.org/json/2.0/pkg/metapost
[mpw]: https://gitlab.lisn.upsaclay.fr/texlive/metapost/-/raw/main/source/texk/web2c/mplibdir/mp.w
[repo]: https://gitlab.lisn.upsaclay.fr/texlive/metapost
[mpost-man]: https://manpages.ubuntu.com/manpages/focal/man1/mpost.1.html
[mplib-report]: https://www.stat.auckland.ac.nz/~paul/Reports/MetaPost/mplib-library/mplib-library.html
[mplib-paper]: https://www.tug.org/TUGboat/tb28-3/tb90hoekwater-mplib.pdf
[luamplib]: https://github.com/lualatex/luamplib
[wiki]: https://en.wikipedia.org/wiki/MetaPost
[mf]: https://en.wikipedia.org/wiki/METAFONT
[scenegraph]: ./concepts.md#mobject-and-the-scene-graph
[hobby-eq]: ./concepts.md#hobby-splines-and-equation-solved-points
[bezier-basis]: ./concepts.md#bezier-basis-quadratic-vs-cubic
[de-casteljau]: ./concepts.md#de-casteljau-evaluation
[affine]: ./concepts.md#affine-transform-and-coordinate-space
[constraint-layout]: ./concepts.md#constraint-and-optimization-based-layout
[latex-svg]: ./concepts.md#latex-to-svg
[glyph-outline]: ./concepts.md#glyph-outline-extraction
[rasterization]: ./concepts.md#rasterization
[color-gamma]: ./concepts.md#color-model-and-gamma
[execution-models]: ./concepts.md#execution-models
[determinism]: ./concepts.md#deterministic-frame-sampling
[bezier-eval]: ./examples/bezier-eval.d
[affine-transform]: ./examples/affine-transform.d
