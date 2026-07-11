# Concepts

The shared vocabulary of the mathematical-animation survey. Every deep-dive is
organised around the same **eight axes** (object model, timing, rendering,
typesetting, output, interactivity, extensibility, determinism); this page
defines the terms those axes use, once, grounded in a concrete example — usually
the local Manim source or one of the catalog's [runnable probes](#the-probes).
Deep-dives link back here rather than redefining a term.

**Last reviewed:** July 11, 2026

The terms are grouped by the axis that uses them most, but they cross-cut: a
`Transform` (axis 2) rewrites the control points of a `VMobject` (axis 1) that a
backend rasterises (axis 3). Read this page once, then use it as a glossary.

---

## Axis 1 — Object & scene model

### Mobject and the scene graph

A **Mobject** ("mathematical object") is the retained unit an engine draws and
animates: a node in a tree whose children are its **submobjects**. A `Circle`, a
`Square`, an equation, or a whole figure are all Mobjects; a group is just a
Mobject whose submobjects are the members. The tree is **retained** (see
[retained vs immediate mode](#retained-vs-immediate-mode)): you build it once,
mutate it over time, and the engine re-renders it each frame — as opposed to
re-issuing draw calls from scratch. Manim stores the children as a plain list
(`self.submobjects`); operations that need the whole subtree flatten it into a
**family** (the node plus all descendants). Whether a node also keeps a
back-reference to its parent is an engine choice with cache-invalidation
consequences (ManimGL keeps `parents` and propagates a dirty flag upward;
community does not).

### VMobject and vector geometry

A **VMobject** (vectorized Mobject) is a Mobject whose geometry is
**piecewise-Bézier vector paths** rather than a pixel image or a point cloud.
Its shape is a list of Bézier curves (subpaths); its appearance is a fill and a
stroke. This is the workhorse type — text glyphs, shapes, and graphs are all
VMobjects — because vector paths scale, interpolate, and morph cleanly. The two
representational questions every engine answers are the [Bézier
basis](#bezier-basis-quadratic-vs-cubic) and whether per-vertex colour lives
interleaved with the points or in parallel arrays.

### Bezier basis: quadratic vs cubic

A **Bézier curve** is a polynomial curve defined by control points; the
**basis** is its degree. A **quadratic** Bézier has 3 control points
(`anchor, handle, anchor`); a **cubic** has 4 (`anchor, handle, handle,
anchor`). The choice is load-bearing and the two camps split on it: ManimGL and
Manim community's OpenGL classes store **quadratic** triples; community's Cairo
classes store **cubic** quads. Conversion is asymmetric — a quadratic elevates
to a cubic **exactly**, but a single quadratic cannot reproduce a general cubic
(one with an inflection). The [`bezier-eval.d`](./examples/bezier-eval.d) probe
demonstrates both directions: the elevation deviation is ~`4e-16`, while a single
quadratic fit to an inflected cubic leaves a residual of ~`0.86` scene units.
This is why an engine targeting cubic-native rasterisers (Cairo, Canvas2D) can
keep a cubic store and only _lower_ to quadratics for the GPU.

### de Casteljau evaluation

The **de Casteljau algorithm** evaluates a Bézier curve at a parameter `t` by
repeated linear interpolation of the control points — numerically stable and the
basis of curve **subdivision** (splitting a curve at `t` into two exact
sub-curves). Subdivision is how a `Transform` equalises point counts between two
paths ([point-count alignment](#transform-and-point-count-alignment)) and how a
cubic is flattened for the GPU. Both the quadratic and cubic evaluators in
[`bezier-eval.d`](./examples/bezier-eval.d) are direct de Casteljau.

### Fill triangulation and winding

A vector **fill** must become triangles (for the GPU) or a coverage mask (for a
CPU rasteriser). **Triangulation** decomposes the filled region into triangles;
Manim's OpenGL path uses ear-clipping (`mapbox-earcut`), which requires the
boundary be a simple polygon, so self-intersecting or holey paths need boolean
pre-processing (`skia-pathops`). The alternative is **winding fill**: a CPU
rasteriser like Cairo (the Manim community default) fills a path directly by a
nonzero/even-odd rule, and a GPU can render the raw path into a stencil counting
the **winding number** and cover the pixels — handling arbitrary paths without
triangulation (ManimGL's only fill path; its old triangulation code is
vestigial). The **fill rule** — **nonzero** vs **even-odd** — decides which
pixels count as inside when subpaths overlap.

### Affine transform and coordinate space

An **affine transform** is a linear map plus a translation — any composition of
translate, rotate, scale, and shear — represented as a 3×3 matrix acting on
homogeneous 2D points (4×4 in 3D). Every Mobject carries a model transform; the
camera is one too. The load-bearing fact is that **matrix multiplication is
function composition, right-to-left**: `M = T·R·S` applied once equals scaling,
then rotating, then translating each point — and the order matters (`T·S ≠
S·T`). The [`affine-transform.d`](./examples/affine-transform.d) probe verifies
the composition (deviation `0`) and the non-commutativity. **Coordinate space**
is the units the scene is authored in (abstract "scene units" centred on the
origin) versus device pixels; the camera's transform maps one to the other.

---

## Axis 2 — Animation & timing model

### Interpolation and lerp

**Interpolation** produces in-between states; **lerp** (linear interpolation)
is the base case, `a + (b−a)·t`. Animating a Mobject lerps its control points
and colours from a start to an end state as `t` runs `0→1`. Colours must be
lerped in a linear space, not gamma-encoded sRGB (see [color model and
gamma](#color-model-and-gamma)).

### Rate function and easing

A **rate function** (a.k.a. **easing**) reshapes the linear time parameter
before interpolation, so motion accelerates and decelerates instead of running
at constant speed. The two Manim forks even differ on what `smooth` _is_:
ManimGL's default `smooth` is the **smootherstep** quintic `6t⁵−15t⁴+10t³` (zero
first _and_ second derivative at both ends), whereas Manim community's default
`smooth` is a **normalized logistic sigmoid** (`inflection = 10`) and keeps the
quintic under the separate name `smootherstep`. Both are ease-in-out S-curves;
the others are `linear`, `rush_into`/`rush_from` (ease-in / ease-out only), and
`there_and_back`. The [`rate-functions.d`](./examples/rate-functions.d) probe
tabulates the family and prints the two S-curves side by side. The rate function
is applied _before_ the mobject is touched: `interpolate(rate_func(alpha))`.

### Lag ratio and staggering

**`lag_ratio`** spreads a group of sub-animations across the parent's time
window so they start in sequence rather than together. Each submobject `i` of
`n` gets a sub-window; Manim's formula is `full = (n−1)·lag + 1`,
`sub_alpha_i = clip(alpha·full − i·lag, 0, 1)`. `lag_ratio = 0` runs everything
together; `1` is strict [succession](#animation-composition); fractions overlap.
The [`rate-functions.d`](./examples/rate-functions.d) probe prints the stagger
matrix.

### Animation composition

Animations compose into larger animations. An **AnimationGroup** runs children
in parallel, each mapped onto a `(start, end)` slice of the group's window
(derived from `lag_ratio`); **Succession** is an AnimationGroup with
`lag_ratio = 1` (each child begins when the previous ends); **LaggedStart**
staggers with a fractional lag. Composition is a small combinator algebra over
the `[0,1]` timeline.

### Transform and point-count alignment

A **Transform** morphs one Mobject into another by interpolating control points.
Its hard prerequisite is **alignment**: the source and target must have matching
submobject trees _and_ equal numbers of control points per subpath, so a
point-to-point lerp is well-defined. The engine pads the shorter family and
**subdivides** curves in the sparser path (via [de
Casteljau](#de-casteljau-evaluation)) until the counts match, then lerps points
and colours along a **path function** (straight line by default; arc or spiral
optional). Getting alignment right is the single subtlest part of a
reimplementation.

### Execution models

How an engine expresses _time_ is its defining axis-2 choice:

- **Imperative play-loop** — the author writes `self.play(Animation(...))` calls;
  a scene loop steps a time progression and renders frames (Manim).
- **Generator / play-head** — animations are generator functions `yield`ed
  against a moving play-head (Motion Canvas).
- **Pure frame function** — a frame is a pure function of its index; the engine
  samples `frame(N)` (Remotion).
- **Reactive / observable** — values are observables; the view recomputes when
  they change, and a record loop advances them (Makie).
- **GUI timeline / keyframe** — properties are keyframed on a visual timeline
  (Theatre.js).

### Retained vs immediate mode

In **retained mode** the engine keeps a persistent scene graph and re-renders it
each frame (Manim, most vector engines). In **immediate mode** the program
re-issues every draw call each frame with no retained objects (nannou's `draw`
API, classic Processing). Retained mode suits object-level animation and
diffing; immediate mode suits per-frame procedural drawing.

### Updaters and ValueTracker

An **updater** is a callback attached to a Mobject that recomputes it every frame
(`add_updater(fn)`); **`always_redraw`** rebuilds a Mobject from a factory each
frame. A **`ValueTracker`** is a Mobject wrapping an animatable scalar, so a
number can be `Transform`ed and updaters can read it — the basis of reactive,
data-driven scenes (a graph that follows a moving parameter). This is the
imperative engines' answer to the [reactive execution
model](#execution-models).

---

## Axis 3 — Rendering backend & rasterization

### Rasterization

**Rasterization** turns vector geometry into pixels. A **CPU vector** rasteriser
(Cairo, Blend2D) walks paths analytically into a coverage buffer; a **GPU**
rasteriser uploads triangles or runs a stencil-and-cover pass. The renderer's
minimal job is: fill a path, stroke a path, clip, transform, and hand back the
pixels ([readback](#frame-capture-and-readback)).

### CPU-vector vs GPU-vector rendering

**CPU-vector** rendering (Cairo, the Manim community default) is deterministic
and bit-reproducible but bounded by the CPU; **GPU-vector** rendering (ManimGL,
Makie's GLMakie, nannou) is fast and enables real-time preview but is _not_
bit-identical across drivers (rasterisation, MSAA, and blend order differ). The
practical resolution is to treat a CPU backend as the reproducible **oracle**
for video and the GPU backend as the interactive path, reconciled by a
perceptual-diff tolerance.

### Anti-aliasing

**Anti-aliasing** (AA) softens the staircase on edges. **Coverage/analytic** AA
(CPU rasterisers) computes the exact fraction of each boundary pixel the shape
covers; **MSAA** (GPU) samples each pixel several times; **analytic** GPU
methods evaluate curve distance in a shader. The [`frame-capture.d`
probe](./examples/frame-capture.d) uses 1px analytic coverage on a disc edge.

### Color model and gamma

A **color model** stores channels (RGBA) and an alpha convention
(**premultiplied** vs straight). **Gamma** is the catch: display sRGB is a
non-linear encoding, so interpolating or compositing colours in sRGB is visibly
wrong — blends must happen in **linear** space and be re-encoded to sRGB only at
the pixel boundary. An engine that stores linear RGBA and converts at the paint
edge gets correct blends for free; one that lerps sRGB bytes does not. Manim's
`Vector`-style colour is naturally expressed as a 4-component value
(`["r","g","b","a"]`).

---

## Axis 4 — Typesetting & text

### Glyph-outline extraction

Rendering text as vector shapes means pulling each glyph's **outline** (its
contour Béziers) from the font and turning it into a [VMobject](#vmobject-and-vector-geometry).
TrueType outlines are quadratic; CFF/OpenType outlines are cubic — normalise to
one basis on import. This is the in-process alternative to routing text through
LaTeX.

### LaTeX to SVG

The classic math pipeline: compile LaTeX to a device file (`dvi`, or `xdv` from
`xelatex`), convert that to **SVG** with **`dvisvgm`**, parse the SVG paths, and
build a [VMobject](#vmobject-and-vector-geometry). Both Manim forks do exactly
this; it needs a LaTeX distribution plus `dvisvgm` on the system, and is
disk-cached because it is slow. Modern alternatives compute glyph layout without
a TeX install (KaTeX/MathJax on the web, MicroTeX embeddable in C++, Typst as a
self-contained compiler).

### Text shaping

**Shaping** turns a run of characters plus a font into positioned glyphs,
handling kerning, ligatures, and complex scripts — the job of **HarfBuzz** (via
**Pango** in Manim's `manimpango`). Shaping precedes [outline
extraction](#glyph-outline-extraction): first decide _which_ glyphs go _where_,
then pull their contours.

---

## Axis 5 — Output & encoding

### Frame capture and readback

**Readback** is reading the rendered pixels out of the backend: Cairo exposes
its image surface buffer, raylib offers `TakeScreenshot` / an offscreen render
texture, an OpenGL backend blits an FBO and reads it. The result is an
addressable **RGBA buffer** — the input an encoder consumes. The
[`frame-capture.d`](./examples/frame-capture.d) probe stands in for this step
with a software framebuffer.

### Codec, muxing, and pixel format

Encoding a frame stream needs a **pixel format** conversion (RGBA → the codec's
`yuv420p`), a **codec** (`libx264`, `libvpx-vp9`, `qtrle` for transparency), and
**muxing** into a container (`.mp4`, `.webm`, `.mov`). Two integration styles
dominate: pipe raw RGBA to an **ffmpeg subprocess** (ManimGL) or call the
**libav** libraries in-process (Manim community's PyAV). Reproducible encodes
require pinning the encoder build.

---

## Axis 8 — Determinism, caching & performance

### Deterministic frame sampling

**Determinism** means the same scene renders the same pixels every run — a
prerequisite for caching and for regression-testing output. It requires
seeded RNG, floating-point stability, and a rasteriser that does not vary with
the driver (hence the CPU oracle of [CPU-vs-GPU](#cpu-vector-vs-gpu-vector-rendering)).

### Content-hash caching

Rendering is expensive, so engines **hash the inputs** of each unit of work and
skip it when unchanged. Manim community hashes each `play()` call (mobject state,
animation spec, camera) and reuses a cached **partial movie file** if the hash
matches, concatenating the partials at the end — the single biggest
iteration-speed win, and correct only because the render is
[deterministic](#deterministic-frame-sampling). The
[`frame-capture.d`](./examples/frame-capture.d) checksum illustrates the hash a
cache would key on.

---

## Declarative & constraint layout

The diagramming systems in this survey replace the imperative object model with
a declarative one, so a few extra terms recur.

### Constraint and optimization-based layout

Instead of placing objects at coordinates, you state _what exists_ and _what
must hold_ (relations, alignments, non-overlap), and a solver finds positions
that satisfy — or an **optimizer** minimises a penalty over — those constraints.
Penrose is the exemplar: its diagrams are laid out by numerical optimization of a
constraint energy.

### Relational layout

A refinement where a diagram is a hierarchy of **relations** between elements
(this _above_ that, these _aligned_) rather than absolute coordinates, so layout
composes; Bluefish explores this model.

### Hobby splines and equation-solved points

The MetaPost lineage: you write **linear equations relating points** and a solver
finds them, and smooth curves through a point sequence are chosen by **Hobby's
algorithm** (curvature-minimising splines). This is the origin of
solved-constraint drawing that the modern systems inherit.

---

## The probes

The catalog's claims about geometry and timing are backed by four dependency-free
runnable D programs (compiled and run by `ci --example-files`):

| Probe                                                 | Grounds                                                                                    |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [`bezier-eval.d`](./examples/bezier-eval.d)           | [Bézier basis](#bezier-basis-quadratic-vs-cubic), [de Casteljau](#de-casteljau-evaluation) |
| [`rate-functions.d`](./examples/rate-functions.d)     | [easing](#rate-function-and-easing), [lag ratio](#lag-ratio-and-staggering)                |
| [`affine-transform.d`](./examples/affine-transform.d) | [affine transform](#affine-transform-and-coordinate-space)                                 |
| [`frame-capture.d`](./examples/frame-capture.d)       | [readback](#frame-capture-and-readback), [content-hash caching](#content-hash-caching)     |

<!-- References -->

<!-- Runnable probes (checked via the ignoreDeadLinks /\.d$/ rule) -->

[bezier-eval]: ./examples/bezier-eval.d
[rate-functions]: ./examples/rate-functions.d
[affine-transform]: ./examples/affine-transform.d
[frame-capture]: ./examples/frame-capture.d
