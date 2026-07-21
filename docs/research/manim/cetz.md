# CeTZ (Typst)

A TikZ-analog drawing package written in the [Typst][typst-repo] scripting
language and rendered by the Typst compiler — the modern, non-TeX declarative
graphics-and-typesetting stack, where a diagram is ordinary Typst code (real
functions, not macro expansion) compiled by a fast incremental Rust compiler
with native math.

| Field         | Value                                                                                                                   |
| ------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Language      | [Typst][typst-repo] — a markup + scripting language; a CeTZ drawing is a Typst closure passed to `canvas`               |
| License       | [LGPL-3.0-or-later][license] (`typst.toml`); the Typst compiler itself is [Apache-2.0][typst-repo]                      |
| Repository    | [`cetz-package/cetz`][repo] (~1.8k stars; latest `v0.5.2`, [May 6 2026][rel-latest])                                    |
| Documentation | [cetz-package.github.io/docs][docs] + an in-repo [`manual.pdf`][manual] / `manual.typ`                                  |
| Category      | Declarative **vector-drawing package** (TikZ + Processing-inspired) for Typst — static diagrams                         |
| First release | [`v0.0.1`][rel-first] — **Jul 6 2023**                                                                                  |
| Host language | Typst — the drawing lives inside a `.typ` document; package entrypoint `src/lib.typ`, imported as `@preview/cetz:0.5.2` |
| Rendered by   | the **[Typst compiler][typst-repo]** (written in Rust; incremental compilation)                                         |
| Output format | **PDF, SVG, PNG, HTML** — whatever [Typst exports][typst-docs]; a CeTZ `canvas` is a box embedded in the page           |

> [!NOTE]
> This page is grounded in the CeTZ source repo ([`cetz-package/cetz`][repo],
> `v0.5.2`, `typst.toml` `compiler = "0.14.0"`), the official
> [manual/docs][docs], and — for the host — the [Typst repo][typst-repo] and
> [docs][typst-docs]. **Provenance correction:** the brief quoted the intro as
> _"CeTZ ist ein Typst Zeichenprogramm"_. The actual README string is
> _"CeTZ, ein Typst Zeichen**paket**"_ (drawing _package_, not _program_), quoted
> verbatim [below](#design-philosophy). CeTZ produces a Typst document, not video
> or a live canvas, so no `ci`-compiled D probe reproduces its output; the
> catalog's [`bezier-eval.d`][bezier-eval] and [`affine-transform.d`][affine-transform]
> probes reimplement the cubic-Bézier and coordinate-transform math CeTZ shares
> with every subject in this survey.

---

## Overview

### What it solves

TikZ is the reference declarative-graphics language, but it is a **TeX macro
package**: every `\draw` is macro expansion inside a LaTeX run, coordinates are
parsed by TeX's mouth, and compiling a page of diagrams is slow and pulls in a
full TeX distribution. CeTZ ports that mental model — a `canvas`, coordinate
systems, named [anchors][affine-transform-anchor], relative coordinates, styling
that cascades — onto Typst, where each drawing primitive is a **real function**
in a real scripting language and the whole document is compiled by a Rust
compiler with [_"fast compile times thanks to incremental compilation"_][typst-repo].
The Typst host also removes TikZ's other hard dependency: math and text are
[native to Typst][typst-math] (no external LaTeX → `dvi` → `dvisvgm` pipeline —
see [axis 4](#typesetting--text)). The result is TikZ's expressiveness without
TeX's toolchain or latency.

### Design philosophy

The README states the identity directly — the load-bearing quote for this page,
verified against the [repository README][readme]:

> _"CeTZ (CeTZ, ein Typst Zeichenpaket) is a library for drawing with Typst with
> an API inspired by TikZ and Processing."_

The repository tagline repeats the pun (Ti*k*Z ≈ _"TeX ist kein
Zeichenprogramm"_): _"CeTZ: ein Typst Zeichenpaket — A library for drawing stuff
with Typst"_ ([repo][repo]). The docs overview names the two borrowed
abstractions and one deliberate departure from screen conventions:
CeTZ has _"relative coordinates and anchors from Ti*k*Z"_, and its canvas is
Cartesian, not screen-space — _"**up is positive!**"_ ([docs overview][docs]).
Everything below `canvas` is Typst code, so the API is scripting, not a macro DSL:
functions compose, closures capture, and the language's own `let`/`for`/`if`
drive the drawing.

---

## How it works

A CeTZ drawing is a **block of Typst code** passed to `cetz.canvas`, inside which
the `cetz.draw` namespace is imported and its functions are called in sequence
([README][readme]):

```typst
#import "@preview/cetz:0.5.2"

#cetz.canvas({
  import cetz.draw: *
  // Your drawing code goes here
})
```

Each `draw` function (`line`, `circle`, `rect`, `arc`, `bezier`, `hobby`,
`catmull`, `content`, `grid`, `polygon`, `n-star`, …; see [`shapes.typ`][shapes-doc])
returns an element the `canvas` collects, resolves, and lowers to Typst's native
vector primitives. Because it is a code block, a loop _is_ a loop:

```typst
#cetz.canvas({
  import cetz.draw: *
  set-style(stroke: (paint: blue, thickness: 1pt))
  for i in range(0, 6) {
    circle((i, 0), radius: 0.3, name: "c" + str(i))
  }
  line("c0", "c5")                 // connect first to last by anchor name
  content((rel: (0, -1), to: "c2.south"), [label])  // relative + anchor coord
})
```

**Coordinate systems.** CeTZ resolves 11 kinds of coordinate, all documented in
[coordinate-systems][coord-doc] and implemented in `src/coordinate.typ`:

| Coordinate     | Written as                            | Meaning ([docs][coord-doc])                                            |
| -------------- | ------------------------------------- | ---------------------------------------------------------------------- |
| XYZ (absolute) | `(1, 2)` / `(x: 1, y: 2, z: 3)`       | _"a point `x` units right, `y` units upward and `z` units away"_       |
| Previous       | `()`                                  | _"the position of the previous coordinate passed to a draw function"_  |
| Relative       | `(rel: (1, 0), to: …)`                | _"places the given coordinate relative to the previous coordinate"_    |
| Polar          | `(30deg, 1)`                          | _"`radius` distance away from the origin at the given angle"_          |
| Anchor         | `"circle.north"` / `(name:, anchor:)` | _"a point relative to a named element using anchors"_                  |
| Barycentric    | `(bary: (a: 0.5, b: 0.1, c: 1))`      | weighted combination of named reference vectors                        |
| Interpolation  | `("a.start", 50%, "a.end")`           | _"linearly interpolate between two coordinates"_ (+ optional rotation) |
| Perpendicular  | `(horizontal: …, vertical: …)`        | intersect a vertical-through-`p` with a horizontal-through-`q`         |
| Tangent        | `(element:, point:, solution:)`       | where a line from a point touches a shape tangentially                 |
| Projection     | `(project: p, onto: (a, b))`          | project a point onto a line                                            |
| Function       | `(v => …, "c.west")`                  | call a function on resolved coordinates                                |

**Styling** works like a Typst `set` rule: `set-style(…)` establishes defaults
for all later elements, per-call arguments override them, and dictionaries merge
field-by-field. The docs state _"you can use the `set-style` function to change
the style for all elements after it, like a Typst `set` rule"_, with the cascade
_"`function > element type > global`"_ ([styling][style-doc]).

**Contrast with TikZ.** Two differences follow from the host swap. First,
_execution model_: TikZ `\draw (0,0) -- (1,1);` is TeX macro expansion; CeTZ
`line((0,0), (1,1))` is a Typst function call — no catcode/mouth parsing, no
`\pgfmath`. Second, _speed and dependencies_: a TikZ diagram needs a LaTeX run
(and, for standalone SVG, `dvisvgm`); a CeTZ diagram is compiled by the Rust
Typst binary in one incremental pass with no TeX install. The wider ecosystem
builds on the same base — [`cetz-plot`][cetz-plot] (plots and charts),
[`cetz-venn`][cetz-venn], and [`fletcher`][fletcher] (_"drawing diagrams with
arrows, built on top of CeTZ"_) — each a Typst package pulled from the `@preview`
registry.

---

## Object & scene model

The scene is a **flat, ordered list of drawable elements** built by executing the
`canvas` code block; there is no persistent, cross-frame scene graph (the output
is a static document, not a live tree — contrast Manim's `Mobject` hierarchy or
Motion Canvas's retained nodes). Structure comes from two mechanisms instead:

- **Named elements + anchors.** Any draw call can take `name:`, after which its
  [anchors][affine-transform-anchor] (`.north`, `.center`, `.75%` along a path,
  a `%`-parameterised point, …) become addressable coordinates for later calls —
  the `src/anchor.typ` machinery. This is how a diagram references parts without
  hard-coding coordinates, the same role TikZ's `(node.anchor)` plays.
- **Groups + transforms.** `group({…})` (`src/draw/grouping.typ`) scopes a
  sub-drawing and its coordinate origin; `translate`, `rotate`, `scale`,
  `set-origin`, and `set-transform` (`src/draw/transformations.typ`) push onto a
  transformation stack realised as a 4×4 matrix in `src/matrix.typ`. Composition
  down the group tree is ordinary [affine-transform stacking][affine-transform-anchor]
  — a local point mapped through its enclosing transforms — exactly the
  compose-once-apply math the [`affine-transform.d`][affine-transform] probe
  models.

Curves are first-class objects: `bezier`/`bezier-through` (cubic and quadratic
control-point splines — [`bezier.typ`][bezier-doc]; see
[bezier basis][bezier-basis] and the [`bezier-eval.d`][bezier-eval] probe),
`catmull` (Catmull-Rom through points), and `hobby` — an implementation of John
Hobby's algorithm (`src/hobby.typ`), the same [equation-solved spline][hobby]
MetaPost and TikZ use, where control points are the solution of a linear system
rather than user input.

## Animation & timing model

**Not applicable — a finding of absence.** Typst is _document-oriented_, and CeTZ
inherits that: there is no timeline, no play-head, no interpolation/easing
engine, no `ValueTracker`, and no per-frame sampling anywhere in the package. A
`canvas` evaluates once to a static picture. The survey's
[execution-model axis][execution-models] — Manim's generator-driven `Scene.play`,
Motion Canvas's `yield*` flow, a tweened clock — has no CeTZ analogue. Motion
over time is out of scope: producing an animation means rendering many documents
(one per frame) with an _external_ driver and muxing them yourself, since Typst
has no video backend. The `interpolation` **coordinate** (`("a", 50%, "b")`) is a
static geometric lerp for _placing_ one element, not a temporal tween — the word
"interpolate" here is spatial, not animated.

## Rendering backend & rasterization

**CeTZ does not [rasterize][rasterization].** It lowers its drawables to Typst's
_native_ vector primitives — Typst `path`/`curve`/`line`/`polygon` elements with
`fill`/`stroke`/`fill-rule` (`"non-zero"` or `"even-odd"`, per [styling][style-doc])
— and hands all pixel production to the Typst compiler. Fill triangulation,
coverage-based anti-aliasing, the [color model and gamma][color-gamma] of the
final raster, and PNG/SVG emission are therefore **Typst's** responsibility, not
CeTZ's; the package's job ends at emitting correct vector geometry.

What CeTZ _does_ own is the **geometry math** to build that geometry, and here it
reaches past interpreted Typst into native code. The repo ships a Rust crate,
[`cetz-core`][cetz-core], compiled to a WebAssembly module and loaded through
Typst's [_"Loads a WebAssembly module"_][typst-plugin] `plugin()` protocol; the
`call_wasm` wrapper in [`src/wasm.typ`][wasm-typ] marshals arguments in and
results out as CBOR. The crate exports the performance-critical primitives —
`cubic_extrema_func` (cubic-Bézier extrema via derivative roots),
`aabb_func` (axis-aligned bounding boxes), `layout_tree_func` (tree layout), and
`path_bool_func` (path boolean operations, backing `src/draw/boolean.typ`)
([`cetz-core/src/lib.rs`][cetz-core]). So the rasterization pipeline is Typst's,
but the hot geometry loops are native Rust/WASM, not Typst script — a deliberate
split for speed.

> [!NOTE]
> **Two layers of WebAssembly, both survey-relevant.** (1) CeTZ's own hot path is
> a WASM plugin (`cetz-core`) — Typst's plugin protocol requires plugins be pure,
> deterministic _"32-bit shared WebAssembly libraries"_ ([plugin docs][typst-plugin]).
> (2) The Typst _compiler_ is Rust and has been compiled to `wasm32` to run
> entirely client-side (e.g. [`typst.ts`][typst-ts], _"Run Typst in
> JavaScriptWorld"_), which is why this stack is a candidate for **web math** in
> the Sparkles proposal: a browser can compile Typst — including CeTZ diagrams and
> native equations — without a server or a TeX install.

## Typesetting & text

This is CeTZ's sharpest advantage over the whole [LaTeX-based][latex-to-svg]
field. The `content((x, y), …)` function places **arbitrary Typst content** onto
the canvas, and Typst's math is _native_ — the Typst README positions the whole
system as _"designed to be as powerful as LaTeX while being much easier to learn
and use"_ ([README][typst-repo]), with [math typesetting][typst-math] built into
the compiler. So a labelled equation is just:

```typst
#cetz.canvas({
  import cetz.draw: *
  content((0, 0), $ integral_0^1 x^2 dif x = 1/3 $)   // native Typst math
  circle((3, 0), radius: 1, name: "c")
  content("c.center", [*node*])
})
```

There is **no external LaTeX → `dvi` → `dvisvgm` pipeline** — the exact
[LaTeX-to-SVG][latex-to-svg] machinery Manim/ManimGL must shell out to. Typst
does its own [glyph-outline extraction][glyph-outline] and [text shaping][text-shaping]
(font parsing/shaping inside the Rust compiler), and CeTZ measures the resulting
content box through Typst's layout engine to place and anchor it. The practical
consequences: math renders in the same fast incremental pass as the rest of the
document, no TeX distribution is required, and label typography (fonts, kerning,
math spacing) is governed by Typst's typesetter rather than a bolted-on SVG
importer. The cost is that the vocabulary is _Typst_ math, not `amsmath` LaTeX —
a large but not identical surface.

## Output & encoding

**Not applicable — a finding of absence at the CeTZ layer.** CeTZ has no encoder,
no codec, no muxer, and no [frame capture/readback][frame-capture]. Its "output"
is a Typst _box_ embedded in the page; the surrounding **Typst compiler** exports
the whole document to [PDF, SVG, PNG, or HTML][typst-docs]. Because the model is a
document, the natural artifact is a page or an image, never a video stream — the
render → framebuffer-readback → encode pipeline the [`frame-capture.d`][frame-capture]
probe models is exactly what a document target obviates. Multi-frame output (an
animated sequence) is possible only by compiling many documents and encoding them
with an external tool; nothing in the [output/encoding axis][execution-models] is
native to this stack. This is the mirror image of a native renderer like Manim,
whose entire reason for existing is that last mile.

## Interactivity, preview & authoring

Authoring is **code-first `.typ` files**. The live-preview loop is Typst's own:
`typst watch` recompiles on save, and Typst's [incremental compilation][typst-repo]
makes that loop fast even for large documents; the [typst.app][typst-docs] web
editor gives the same experience in the browser (backed by the wasm compiler),
and the `tinymist` language server provides editor tooling. What is _absent_ is a
scrubbable-timeline IDE of the Motion-Canvas/Theatre.js kind — consistent with
[axis 2](#animation--timing-model), there is no timeline to scrub. "Interactivity"
in the CeTZ sense is authoring ergonomics (named anchors, relative coordinates,
loops) rather than a runtime interactive canvas; the compiled artifact (PDF/PNG)
is static, and even the SVG/HTML output is a rendered picture, not an event-driven
scene.

## Extensibility & API surface

CeTZ is **pure Typst**, so extensibility is unusually direct: a draw function _is_
an ordinary Typst function, and a user's custom primitive is written the same way
the built-ins are (`src/draw/*.typ` are themselves just Typst modules). Groups,
closures, and the `function` coordinate let a caller compute geometry inline; the
`@preview` package registry distributes higher-level layers built entirely on the
public API — [`cetz-plot`][cetz-plot] (axes, charts), [`cetz-venn`][cetz-venn],
and the widely-used [`fletcher`][fletcher] arrow-diagram package all sit _"on top
of CeTZ"_ ([fletcher][fletcher]). The API is organised into coherent modules —
shapes ([`shapes.typ`][shapes-doc]), grouping, transformations, styling,
projection (3D), and path booleans — re-exported through `cetz.draw`. The one
escape hatch below Typst is the [`cetz-core`][cetz-core] Rust/WASM plugin: when a
computation is too hot for interpreted Typst, it moves to native code behind the
`call_wasm`/CBOR seam ([`wasm.typ`][wasm-typ]) — extension _downward_ to Rust, not
just outward in Typst.

## Determinism, caching & performance

Determinism is a **language guarantee**, not a CeTZ feature: Typst functions must
be pure — _"Typst functions must be pure (which is quite fundamental to the
language design)"_ ([plugin docs][typst-plugin]) — and the same requirement is
imposed on WASM plugins (_"no observable side effects and deterministic results"_),
so `cetz-core` cannot introduce nondeterminism. The same source therefore always
compiles to the same output, and Typst's [incremental compilation][typst-repo]
(_"All Typst language features must accommodate for incremental compilation"_)
memoises unchanged sub-computations across edits — the fast-preview substrate. CeTZ
performance is thus a function of (a) how much interpreted-Typst geometry a canvas
runs and (b) the native `cetz-core` offload for the hot primitives (Bézier
extrema, bounding boxes, tree layout, path booleans). Unlike [Penrose or
Bluefish][constraint-layout], CeTZ runs **no global constraint solver**: coordinates
are resolved procedurally in draw order, and the only equation-solved geometry is
the [Hobby spline][hobby]'s linear system for control points — a bounded, local
solve, not an iterative optimizer with seed sensitivity.

## Strengths

- **TikZ's model without TeX.** Coordinate systems, named anchors, relative
  coordinates, and cascading styles — the familiar declarative-drawing vocabulary
  — over a fast Rust compiler with no LaTeX toolchain.
- **Native math and text.** `content(…, $…$)` places _native_ Typst math and
  typography; no external [LaTeX → SVG][latex-to-svg] shell-out, no TeX install,
  and math renders in the same incremental pass as everything else.
- **Real scripting, not macros.** Draw calls are Typst functions; `for`/`if`/`let`
  and closures drive drawings directly — extension is writing a function.
- **Native hot path.** Performance-critical geometry (`cubic_extrema`, `aabb`,
  tree layout, path booleans) runs as a Rust [WASM plugin][cetz-core], not
  interpreted Typst.
- **Web-deployable stack.** The Typst compiler compiles to `wasm32`
  ([`typst.ts`][typst-ts]), so CeTZ diagrams + native equations can be compiled
  fully client-side — the property that makes this a web-math candidate.
- **Deterministic and cacheable** by language design (purity + incremental
  compilation).

## Weaknesses

- **No animation whatsoever** — no timeline, play-head, easing, or per-frame model
  ([axis 2](#animation--timing-model)); motion needs an external frame driver.
- **No output/encoding pipeline** — output is a Typst document; video is out of
  scope ([axis 5](#output--encoding)).
- **Not a renderer.** CeTZ emits vector geometry; all [rasterization][rasterization],
  anti-aliasing, and [color/gamma][color-gamma] behaviour is delegated to Typst —
  no direct pixel control.
- **Typst-math, not LaTeX-math.** A large migration surface for authors who think
  in `amsmath`; some LaTeX constructs have no one-to-one Typst form.
- **Young and pre-1.0.** `v0.5.2` on a Typst that is itself pre-1.0 (`v0.15.0`);
  the `compiler = "0.14.0"` pin means CeTZ tracks a moving host — breaking changes
  across Typst releases are routine.
- **Static only.** Every dynamic/interactive facility the survey's other subjects
  provide (scrubbing, live scenes, tweening) is absent by design.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                                    | Trade-off                                                                       |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| **Host on Typst**, not TeX                                   | Fast incremental Rust compiler; no LaTeX toolchain; real scripting           | Tracks a pre-1.0 moving host (`compiler = "0.14.0"`); Typst-math ≠ LaTeX-math   |
| Draw primitives are **Typst functions**                      | Composition, closures, loops, and extension come for free from the language  | Bound to Typst's evaluation cost/semantics; no macro-level metaprogramming      |
| **Emit vector geometry, let Typst rasterize**                | No rasterizer/AA/encoder to build or maintain; reuse the compiler's pipeline | Zero direct pixel/gamma control; output fidelity is Typst's, not CeTZ's         |
| Offload hot geometry to a **Rust/WASM plugin** (`cetz-core`) | Native speed for Bézier extrema, AABB, tree layout, path booleans            | A build dependency + CBOR marshalling seam; plugin must stay pure/deterministic |
| **Native math via `content`**, no LaTeX pipeline             | No `dvi`/`dvisvgm` shell-out; math is fast and dependency-free               | Author must learn Typst math; not a drop-in for LaTeX sources                   |
| **No animation / no encoder** (document-oriented)            | Focus on static declarative drawing; leverage Typst's document output        | Animation and video are entirely external; no play-head or frame capture        |
| **Procedural coordinate resolution**, no global solver       | Deterministic, debuggable, draw-order-local; cheap                           | Can't express global simultaneous constraints (cf. Penrose/Bluefish)            |
| 11 **coordinate systems** (absolute/rel/anchor/polar/…)      | Match TikZ ergonomics; place elements by relation, not raw numbers           | A learning surface; some (tangent/projection) are niche                         |

---

## Sources

- [`cetz-package/cetz`][repo] — the source repository (LGPL-3.0-or-later,
  [`LICENSE`][license]; `typst.toml` `compiler = "0.14.0"`, entrypoint
  `src/lib.typ`). Source of the identity quote ([`README`][readme]), the
  `draw`-function set ([`shapes.typ`][shapes-doc]), coordinate systems
  (`coordinate.typ`), styling (`styling.typ`), transforms (`transformations.typ`,
  `matrix.typ`), and Hobby/Bézier curves (`hobby.typ`, [`bezier.typ`][bezier-doc]).
- [`cetz-core/src/lib.rs`][cetz-core] — the Rust crate compiled to a WASM plugin;
  exports `cubic_extrema_func`, `aabb_func`, `layout_tree_func`, `path_bool_func`.
  Loaded via [`src/wasm.typ`][wasm-typ]'s `call_wasm` (CBOR marshalling).
- [cetz-package.github.io/docs][docs] — the manual: [coordinate-systems][coord-doc]
  (the 11 coordinate kinds), [styling][style-doc] (the `set-style` cascade), and
  [shapes][shapes-doc]; plus the in-repo [`manual.pdf`][manual].
- [`typst/typst`][typst-repo] + [typst.app/docs][typst-docs] — the host: the
  Rust, incremental-compilation compiler; [native math][typst-math]; the
  [`plugin()`][typst-plugin] WebAssembly protocol; PDF/SVG/PNG/HTML export.
- [`Myriad-Dreamin/typst.ts`][typst-ts] — the Typst compiler compiled to
  `wasm32` for client-side use (web-math relevance).
- Ecosystem: [`cetz-plot`][cetz-plot], [`cetz-venn`][cetz-venn], and
  [`fletcher`][fletcher] — Typst packages built on CeTZ.
- Concept notes: [bezier basis][bezier-basis], [affine transform &
  coordinate space][affine-transform-anchor], [Hobby splines][hobby],
  [LaTeX to SVG][latex-to-svg], [rasterization][rasterization], and
  [constraint/optimization layout][constraint-layout]. Probes:
  [`bezier-eval.d`][bezier-eval], [`affine-transform.d`][affine-transform],
  [`frame-capture.d`][frame-capture].

<!-- References -->

[repo]: https://github.com/cetz-package/cetz
[readme]: https://github.com/cetz-package/cetz/blob/22affc3f44ce309fda5d2294f133e79fe2b045b6/README.md
[license]: https://github.com/cetz-package/cetz/blob/22affc3f44ce309fda5d2294f133e79fe2b045b6/LICENSE
[manual]: https://github.com/cetz-package/cetz/blob/22affc3f44ce309fda5d2294f133e79fe2b045b6/manual.pdf
[cetz-core]: https://github.com/cetz-package/cetz/blob/22affc3f44ce309fda5d2294f133e79fe2b045b6/cetz-core/src/lib.rs
[wasm-typ]: https://github.com/cetz-package/cetz/blob/22affc3f44ce309fda5d2294f133e79fe2b045b6/src/wasm.typ
[bezier-doc]: https://github.com/cetz-package/cetz/blob/22affc3f44ce309fda5d2294f133e79fe2b045b6/src/bezier.typ
[rel-first]: https://github.com/cetz-package/cetz/releases/tag/v0.0.1
[rel-latest]: https://github.com/cetz-package/cetz/releases/tag/v0.5.2
[docs]: https://cetz-package.github.io/docs/
[coord-doc]: https://cetz-package.github.io/docs/basics/coordinate-systems
[style-doc]: https://cetz-package.github.io/docs/basics/styling
[shapes-doc]: https://cetz-package.github.io/docs/api/draw-functions/shapes
[cetz-plot]: https://github.com/cetz-package/cetz-plot
[cetz-venn]: https://github.com/cetz-package/cetz-venn
[fletcher]: https://github.com/Jollywatt/typst-fletcher
[typst-repo]: https://github.com/typst/typst
[typst-docs]: https://typst.app/docs/
[typst-math]: https://typst.app/docs/reference/math/
[typst-plugin]: https://typst.app/docs/reference/foundations/plugin/
[typst-ts]: https://github.com/Myriad-Dreamin/typst.ts
[bezier-basis]: ./concepts.md#bezier-basis-quadratic-vs-cubic
[affine-transform-anchor]: ./concepts.md#affine-transform-and-coordinate-space
[constraint-layout]: ./concepts.md#constraint-and-optimization-based-layout
[hobby]: ./concepts.md#hobby-splines-and-equation-solved-points
[latex-to-svg]: ./concepts.md#latex-to-svg
[glyph-outline]: ./concepts.md#glyph-outline-extraction
[text-shaping]: ./concepts.md#text-shaping
[rasterization]: ./concepts.md#rasterization
[color-gamma]: ./concepts.md#color-model-and-gamma
[execution-models]: ./concepts.md#execution-models
[bezier-eval]: ./examples/bezier-eval.d
[affine-transform]: ./examples/affine-transform.d
[frame-capture]: ./examples/frame-capture.d
