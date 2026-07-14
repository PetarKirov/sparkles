# Penrose (declarative diagramming)

The survey's purest **declarative, constraint-optimization** system: you write
_what_ a diagram means in three small languages and a numerical optimizer places
every shape — the inverse of Manim's imperative [Mobject / scene-graph][mobject]
model, and the one design here a Sparkles layout layer could borrow wholesale.

| Field          | Value                                                                                                                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Language       | **TypeScript** (`@penrose/core`, a pure JS/npm package; runs in the browser and Node); original prototype in **Haskell**                   |
| License        | [MIT][license]                                                                                                                             |
| Repository     | [`penrose/penrose`][repo] (~8,000 stars)                                                                                                   |
| Documentation  | [penrose.cs.cmu.edu/docs][docs]                                                                                                            |
| Category       | Declarative constraint-optimization diagramming system (static vector diagrams, **not** a video/animation engine)                          |
| First release  | SIGGRAPH 2020 paper ([ACM TOG 39(4), Article 144, Jul 2020][paper-doi]); Haskell prototype on [Hackage][hackage] `0.1.1.1` (2019)          |
| Latest release | [`v3.3.0`][release] (Sep 28, 2025)                                                                                                         |
| Paradigm       | A **trio** — [Domain][domain] + [Substance][substance] + [Style][style] — compiled to [constrained numerical optimization][constraint-opt] |
| Layout engine  | **L-BFGS** energy minimization over **reverse-mode autodiff** (energy + gradient compiled to JS at runtime)                                |
| Output format  | **SVG** (editor also exports PNG, PDF, and SVG-for-LaTeX)                                                                                  |

> [!NOTE]
> This page is grounded in the SIGGRAPH 2020 paper ([PDF][paper], [ACM
> DOI][paper-doi]), the official docs at [penrose.cs.cmu.edu][docs], and the
> [`penrose/penrose`][repo] source + wiki. Penrose renders **in TypeScript to an
> SVG DOM**, so no `ci`-compiled D probe reproduces its output; the catalog's
> dependency-free probes ([`bezier-eval.d`][bezier-eval],
> [`affine-transform.d`][affine-transform]) reimplement the shared vector math
> (piecewise-Bézier paths, affine composition) that Penrose's SVG output also
> rests on. Penrose is the survey's **outlier**: every other subject is an
> imperative or reactive _animation_ engine, and Penrose is a _static-diagram_
> layout system — several axes below are therefore findings of **absence**.

---

## Overview

### What it solves

Penrose attacks a problem upstream of animation entirely: **placing** the shapes
of a technical diagram so they faithfully encode a mathematical statement. The
tagline is _"Create beautiful diagrams just by typing notation in plain text"_
([README][readme]). Where Manim's author writes `Circle().shift(LEFT)` and owns
every coordinate, a Penrose author writes only that a `Set` _is a subset of_
another and lets the system decide _where_ the two circles go — the abstract
content and its visual realization are kept in separate files. Figure 1 of the
paper states the separation directly ([paper][paper]):

> _"Penrose is a framework for specifying how mathematical statements should be
> interpreted as visual diagrams. A clean separation between abstract
> mathematical objects and their visual representation provides new capabilities
> beyond existing code- or GUI-based tools."_

Because the mapping from meaning to picture is user-defined rather than
hard-coded, _"the same set of statements … is given three different visual
interpretations … via Euclidean, spherical, and hyperbolic geometry"_
([paper][paper], Fig. 1) — one Substance program, many diagrams.

### Design philosophy

The abstract is the clearest statement of the design bet, and doubles as this
page's cited primary quote ([paper][paper], [ACM TOG 39(4):144][paper-doi]):

> _"We introduce a system called Penrose for creating mathematical diagrams. Its
> basic functionality is to translate abstract statements written in familiar
> math-like notation into one or more possible visual representations. Rather
> than rely on a fixed library of visualization tools, the visual representation
> is user-defined in a constraint-based specification language; diagrams are then
> generated automatically via constrained numerical optimization. The system is
> user-extensible to many domains of mathematics, and is fast enough for
> iterative design exploration. In contrast to tools that specify diagrams via
> direct manipulation or low-level graphics programming, Penrose enables rapid
> creation and exploration of diagrams that faithfully preserve the underlying
> mathematical meaning."_

Three commitments fall out of that paragraph. First, **declarative over
imperative**: you state relations and requirements, never coordinates — the
[constraint-and-optimization-based layout][constraint-opt] paradigm the survey
names, with Penrose as its exemplar. Second, **user-extensible domains**: the
visualization vocabulary is not a fixed toolbox but a `.domain`/`.style` pair the
author can write for any field. Third, **a diagram is a _family_, not a point**:
"one or more possible visual representations" means the optimizer's non-unique
solutions are a feature — resampling explores the family (see
[determinism](#determinism-caching--performance)). The ACM subject classification
files it accordingly under _"Software and its engineering → Domain specific
languages"_ ([paper][paper], CCS Concepts).

---

## How it works

A Penrose diagram is a **trio** of three plain-text programs plus the engine that
combines them ([docs][docs]):

- A **[Domain][domain] (`.domain`) program** — _"describes for a given domain the
  types of objects, predicates, and functions that comprise diagrams in this
  domain."_ It is the schema: what _kinds_ of things exist and what can be said
  about them.
- A **[Substance][substance] (`.substance`) program** — _"defines the objects and
  relationships in the diagram."_ It is the content: _which_ things exist and how
  they relate, written in math-like notation with no visual detail.
- A **[Style][style] (`.style`) program** — _"tells Penrose how to display the
  objects and relationships."_ It maps Substance declarations to shapes and
  states the layout requirements.

The canonical Venn-diagram example ([README][readme]) shows all three. **Domain**
declares the vocabulary — a `type` and three relational `predicate`s:

```text
-- setTheory.domain
type Set

predicate Disjoint(Set s1, Set s2)
predicate Intersecting(Set s1, Set s2)
predicate Subset(Set s1, Set s2)
```

**Substance** declares the objects and asserts relations over them — no geometry:

```text
-- tree.substance
Set A, B, C, D, E, F, G

Subset(B, A)
Subset(C, A)
Subset(D, B)
Disjoint(E, D)
Disjoint(B, C)

AutoLabel All
```

**Style** is where geometry and the optimization problem appear. Each `forall`
rule matches a pattern of Substance objects and, for each match, creates shapes
and states requirements with **`ensure`** (a hard constraint) and **`encourage`**
(a soft objective):

```text
-- venn.style
canvas {
  width = 800
  height = 700
}

forall Set x {
  shape x.icon = Circle { }
  shape x.text = Equation {
    string : x.label
    fontSize : "32px"
  }
  ensure contains(x.icon, x.text)
  encourage norm(x.text.center - x.icon.center) == 0
  layer x.text above x.icon
}

forall Set x; Set y
where Subset(x, y) {
  ensure disjoint(y.text, x.icon, 10)
  ensure contains(y.icon, x.icon, 5)
  layer x.icon above y.icon
}

forall Set x; Set y
where Disjoint(x, y) {
  ensure disjoint(x.icon, y.icon)
}
```

Read the last two rules as the whole idea: _"for every `Subset(x, y)`, keep `x`'s
circle **inside** `y`'s"_ and _"for every `Disjoint(x, y)`, keep the two circles
**apart**"_ — the picture is never drawn, only _constrained_. The
[Style shape library][shapes] supplies the primitives a rule can instantiate:
`Circle`, `Ellipse`, `Rectangle`, `Line`, `Path`, `Polygon`, `Polyline`, `Text`,
`Equation`, `Image`, and `Group`. Undefined shape parameters (here the circle's
radius and center) _"have default values which may or may not be adjusted upon
optimization"_ — every unpinned number becomes a **varying** degree of freedom
the optimizer is free to move.

### The numerical optimizer

The [Style compiler][style-compiler] turns the `ensure`/`encourage` statements
into one scalar **energy** and minimizes it. Its final phase _"Find[s] all the
objective and constraint functions in the translation [then] Generate[s] the
objective function"_; when that function runs on the current values, _"each of
the resulting energies is weighted … and summed to yield the overall energy"_ —
constraints enter as large-penalty terms, objectives as ordinary terms. The
gradient comes from [reverse-mode autodiff][autodiff-guide] over a computational
graph: _"given a computational graph of the energy function, it returns a
computational graph of the gradient,"_ and the compiler notes _"autodiff is
automatically taken with respect to the intermediate expressions/computations."_
The descent step is quasi-Newton — the guide _"currently appl[ies] **L-BFGS** to
get the actual descent direction."_ Both the energy and its gradient are
**compiled to JavaScript at runtime and JIT-optimized** before the loop runs, so
each iteration is cheap. After each step _"the varying state is updated … the
translation is evaluated and the list of shapes is updated for the front-end to
render."_ The pipeline, end to end:

```text
Domain + Substance + Style  ──parse──▶  matched selectors  ──▶  varying state x
       energy E(x) = Σ wᵢ · (ensure|encourage)ᵢ(x)         ──autodiff──▶  ∇E(x)
       minimize E via L-BFGS  ──▶  converged x*  ──toSVG──▶  SVG diagram
```

---

## Object & scene model

Penrose has **no [retained][retained] mutable scene graph** in the
[Mobject][mobject] sense — nothing you build once and then mutate frame by frame. Its object model is a
**bipartite** one: _Substance_ holds the abstract objects (a flat set of typed
declarations and relations, e.g. `Set A` and `Subset(B, A)`), and _Style_
produces the visual objects (shape instances such as `x.icon = Circle { }`) by
**pattern-matching** Substance with `forall` selectors. The shapes are not a tree
the author navigates; they are the _output_ of matching, keyed by the Substance
object they belong to (`x.icon`, `x.text`). Grouping exists — the `Group` shape
composes children — but there is no parent-pointer/dirty-flag machinery because
there is no per-frame mutation to invalidate: the "scene" is recomputed from the
trio each time the optimizer runs. This is the survey's declarative counterpart to
the imperative Mobject: instead of a node you translate and rotate, you have a
_relation_ (`Subset`) whose geometric meaning (`contains(...)`) the optimizer
enforces. In the survey's [relational-layout][relational] terms, the diagram _is_
its relations; coordinates are derived, never authored.

## Animation & timing model

**Absent by design — Penrose is a static-diagram system.** There is no timeline,
no frame index, no easing/[rate function][rate-functions], no play-loop, and no
[execution model][execution-models] in the sense every other subject in this
survey has one. A Penrose program specifies a _picture_, not a _motion_. The only
notions of "progression" are internal and produce still images:

- **The optimizer's iteration count.** The [API][api] exposes `step`/`stepTimes`
  to advance the L-BFGS loop N iterations at a time, and `isOptimized` to test
  convergence — so the _solve_ has a trajectory, but it is a means to a single
  static layout, not an authored animation curve. (One could film the descent,
  but nothing in the language expresses time.)
- **Staged layout.** [Layout stages][staged-layout] let the author _"divide the
  layout optimization problem into multiple stages"_ (e.g. `layout = [shape,
label, overall]`, positioning shapes before labels). This orders the _solve_,
  not the _display_ — it exists because _"if constraints and objectives differ on
  what they consider 'good' states, then they will effectively compete"_, and
  sequencing them improves reliability and solve time.
- **Resampling.** Producing another member of the diagram family (below) is a new
  static layout, not a tween between two.

Any actual animation of a Penrose diagram is a downstream concern (interpolating
between two converged states, or embedding the SVG in a video tool) and is out of
scope for the engine itself.

## Rendering backend & rasterization

Penrose's core renderer emits **vector SVG, and does not rasterize**. The
[`toSVG`][api] function _"renders a `PenroseState` as an `SVGSVGElement`"_ — a DOM
tree of `<circle>`, `<path>`, `<text>`, etc. — and rasterization to pixels is
delegated entirely to whatever consumes that SVG: the browser's own SVG renderer
in the editor, or a PNG/PDF exporter. There is no CPU-vs-GPU
[rasterizer][rasterization] question inside Penrose the way there is for Cairo vs
OpenGL in the Manim forks, because Penrose stops at the resolution-independent
vector description. Two consequences follow. First, output is **crisp at any
scale** and diff-friendly as text (the SVG _is_ the artifact). Second,
[anti-aliasing, color compositing, and gamma][color-gamma] are the _renderer's_
job, not Penrose's — an SVG `fill` is handed to the viewer untouched. The shape
geometry the SVG carries is exactly the survey's vector primitives: circles,
polygons, and piecewise-Bézier `Path`s (the [`bezier-eval.d`][bezier-eval] math),
positioned by the affine placement the optimizer solves for (the
[`affine-transform.d`][affine-transform] math).

## Typesetting & text

Math labels are Penrose's most animation-relevant text feature, and it reaches
them through a **self-contained JS math engine, not a system TeX install**. The
`Equation` shape typesets its `string` as **math-mode TeX rendered by
[MathJax][labels] to SVG**; the [Labels wiki][labels] states the mechanism plainly:

> _"all labels are converted to SVG strings by MathJax the first time the scene is
> rendered."_

The `Text` shape covers plain (non-math) strings. Because MathJax emits SVG
`<path>` geometry, an equation's glyphs arrive as real vector outlines — the
survey's [glyph-outline extraction][glyph-outline] reached, like Motion Canvas's
`Latex`, through an **in-process compiler** rather than Manim's system
LaTeX + `dvisvgm` [pipeline][latex-svg]. Two notes on where this sits versus the
survey's [text-shaping][text-shaping] axis: MathJax owns both shaping and outline
production for math, so Penrose never touches HarfBuzz/Pango directly; and the
label's rendered box feeds back into the optimizer — a label is a shape with a
measured size that `ensure contains(x.icon, x.text)` can constrain, which is why
[staged layout][staged-layout] often places shapes first and labels second.

## Output & encoding

**No video codec, muxing, or frame encoding — another finding of absence.** The
survey's [codec/muxing/pixel-format][latex-svg] axis simply does not apply: a
Penrose run produces a **single diagram**, so there is no frame stream to encode.
The core output is one SVG element ([`toSVG`][api]); the editor adds
["four export formats: PNG, SVG, SVG for LaTeX, and PDF"][using]. The
LaTeX-oriented export _"exports `Equation` as raw texts, and you can customize the
styling in LaTeX by importing the SVG using the `svg` TeX package"_, and — a neat
round-trip — _"SVGs exported by the editor contain necessary metadata (e.g. source
trio programs) for the editor to re-load them into the workspace."_ For batch use,
the `roger` CLI _"can process these trios to generate SVGs, accepting them either
as individual files or consolidated in a `.trio.json` configuration file"_
([using][using]). Where Manim's terminal artifact is an `.mp4`, Penrose's is a
`.svg` (or a directory of them, one per variation).

## Interactivity, preview & authoring

This is a genuine strength. Penrose ships a **browser-based IDE** with _"separate
tabs for editing the three core components: `.substance`, `.style`, and
`.domain`"_ ([using][using]); you edit the trio and compile to see the diagram
panel update. The signature interactive act is **resampling to explore the
diagram family**: _"To view another layout of the diagram, click 'resample.'"_
Each result is reproducible via a variation string (see
[determinism](#determinism-caching--performance)), and the editor's **Diagram
Variations** panel shows several alternate layouts side by side for comparison.
The authoring loop is fast on purpose — the paper's own criterion is being _"fast
enough for iterative design exploration"_ ([paper][paper]) — because the energy
and gradient are compiled to JIT-friendly JavaScript and the optimizer converges
in a fraction of a second for typical trios.

## Extensibility & API surface

Extensibility is layered from the DSL up to the JS API:

- **User-defined domains.** The headline extensibility axis is the language
  itself: a new `.domain` + `.style` pair teaches Penrose an entirely new field
  of mathematics or engineering — the _"user-extensible to many domains"_
  property of the abstract. Nothing about set theory, geometry, or graph drawing
  is baked into the engine; it is all trio content.
- **Constraint / objective library.** `ensure`/`encourage` draw from a library of
  differentiable functions (`contains`, `disjoint`, `overlapping`, `norm`, …);
  because everything is [autodiff][autodiff-guide]-traced, an author composes them
  freely and the gradient follows automatically.
- **`@penrose/core` JS API.** The engine is a plain npm package with a small,
  composable surface ([API docs][api]) — `compile` (trio → `PenroseState`),
  `optimize`/`step`/`stepTimes` (run the solver), `toSVG` (render), plus a
  `diagram` convenience that chains all three. The documented pattern:

  ```javascript
  import { compile, optimize, toSVG, showError } from '@penrose/core';

  const compiled = await compile(trio);
  if (compiled.isErr()) throw new Error(showError(compiled.error));
  const converged = optimize(compiled.value);
  const rendered = await toSVG(converged.value, async () => undefined);
  document.getElementById('diagram').appendChild(rendered);
  ```

- **Embeddable + scriptable.** Because it is pure JS/TS returning an
  `SVGSVGElement`, Penrose embeds in any web page or Node script, and `roger`
  drives it headlessly from the command line.

## Determinism, caching & performance

Penrose's reproducibility primitive is the **variation string**. The docs
([using][using]):

> _"each diagram layout is uniquely identified by a single variation string.
> Changing this string generates another layout alternative (similar to clicking
> 'resample')."_

The variation string seeds the optimizer's randomness (initial sample of the
varying state), so a **fixed variation deterministically reproduces the same
diagram** — the static-diagram analogue of the survey's
[deterministic frame sampling][deterministic], and what makes a Penrose diagram
shareable and regression-testable. Note the subtlety versus a video engine: the
optimizer is a numerical process, so bit-identical SVG across machines depends on
floating-point and L-BFGS stability, not on a fixed frame formula.

On **caching**, Penrose has **no Manim-style content-hash / partial-file layer**
(there are no frames to cache); its performance story is instead (a) compiling the
energy and gradient to **JIT-optimized JavaScript** so each L-BFGS iteration is
fast, (b) **[staged layout][staged-layout]** to cut solve time and avoid
constraint/objective thrash, and (c) the small problem sizes typical of diagrams.
The design target — _"fast enough for iterative design exploration"_
([paper][paper]) — is met by making the _solve_ cheap rather than by caching its
result.

---

## Strengths

- **Fully declarative layout.** You state relations and requirements; the
  optimizer finds coordinates. This is the cleanest separation of _meaning_ from
  _appearance_ in the survey and the whole point of borrowing the model.
- **User-extensible to any domain.** A `.domain` + `.style` pair, not a fixed
  toolbox, defines the visual vocabulary — the same engine draws Venn diagrams,
  Euclidean constructions, or graph layouts.
- **A diagram is a family.** Non-unique optima are a feature: resampling +
  variation strings explore alternative layouts of the _same_ statement, each
  reproducible.
- **Resolution-independent SVG output** that is crisp at any scale and diffable as
  text; math labels are real vector outlines via in-process [MathJax][labels] (no
  system TeX).
- **Genuinely good authoring loop** — a browser IDE with live compile, resample,
  and a Diagram Variations panel, fast enough for iteration.
- **Small, embeddable JS API** (`compile`/`optimize`/`toSVG`) plus a `roger` CLI;
  MIT-licensed.

## Weaknesses

- **Not an animation engine.** No timeline, frames, easing, or play-loop — the
  survey's timing and encoding axes are outright absent. Any motion is a
  downstream bolt-on.
- **Layout is a numerical optimization**, so it can fail to converge, land in a
  poor local minimum, or need [staged layout][staged-layout] and hand-tuning of
  constraint weights to behave — less predictable than placing coordinates
  directly.
- **Reproducibility is per-variation-string, not bit-identical across machines**:
  the optimizer's floating-point path can differ, so SVGs are not guaranteed
  byte-equal on different hardware.
- **Learning curve of a three-language, constraint-based model** — thinking in
  `ensure`/`encourage` and `forall` selectors is a paradigm shift from imperative
  drawing.
- **Rasterization/anti-aliasing/gamma are out of Penrose's hands** — it emits SVG
  and defers pixels to the viewer, so pixel-exact output depends on the external
  renderer.
- **No cross-run render caching** (though there are no frames to cache, iteration
  relies on a cheap solve rather than a cache).

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                              | Trade-off                                                                             |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| **Trio of DSLs** (Domain / Substance / Style)                     | Cleanly separates abstract meaning from visual mapping; each reusable independently    | Three languages to learn; indirection between "what exists" and "what it looks like"  |
| **Constraint-based layout via `ensure`/`encourage`**              | Author states requirements, not coordinates; layout composes from relations            | Must express intent as differentiable penalties; competing terms can fight            |
| **Constrained numerical optimization (L-BFGS + reverse-mode AD)** | One general engine lays out any domain; gradients are automatic                        | Can miss/local-minimum; needs staged layout and weight tuning; not always predictable |
| **Energy + gradient compiled to JIT'd JavaScript**                | Fast enough for iterative design exploration                                           | Adds a runtime codegen step; performance tied to the JS engine                        |
| **A diagram is a _family_ (resample + variation string)**         | "One or more possible visual representations"; explore alternatives, reproduce any one | No single canonical output; determinism is per-string, not cross-machine bit-exact    |
| **SVG (vector) output; rasterization deferred**                   | Resolution-independent, diffable, embeddable; no rasterizer to maintain                | Anti-aliasing/gamma/pixels controlled by the external viewer, not Penrose             |
| **In-process MathJax for `Equation` labels**                      | Math typesetting with no system TeX/`dvisvgm`; labels are real vector outlines         | Ships a large JS math engine; MathJax coverage, not full LaTeX                        |
| **Static diagrams, no timing model**                              | Focus the system on the hard part — faithful _placement_ — not motion                  | Not a video engine; animation is entirely out of scope                                |
| **Haskell prototype → TypeScript rewrite (`@penrose/core`)**      | A pure JS/npm engine embeds in browsers and Node, powering the live editor             | A full reimplementation; SIGGRAPH-'20 examples predate the current languages          |

---

## Sources

Primary sources — the SIGGRAPH 2020 paper, the official docs, and the
`penrose/penrose` source + wiki:

- [Penrose: From Mathematical Notation to Beautiful Diagrams][paper] — Ye, Ni,
  Krieger, Ma'ayan, Wise, Aldrich, Sunshine, Crane; [ACM TOG 39(4), Article 144,
  Jul 2020][paper-doi]. The abstract (constraint-based specification →
  constrained numerical optimization), Fig. 1 (meaning/representation separation,
  three geometries), and the design criteria quoted above.
- [Documentation reference][docs] — the Domain/Substance/Style definitions
  quoted verbatim; the [Style shape library][shapes] (shape list, defaults,
  `ensureOnCanvas`); [using Penrose][using] (editor, resample, variation string,
  export formats, `roger`); [`@penrose/core` API][api] (`compile`/`optimize`/
  `step`/`toSVG`, the render pattern).
- [How the Style compiler works][style-compiler] (wiki) — objective-function
  generation, weighted-and-summed energies, autodiff over `varyingState`.
- [Autodiff guide][autodiff-guide] (wiki) — reverse-mode symbolic autodiff
  (`gradAllSymbolic`), the energy/gradient computational graph, L-BFGS descent,
  runtime JS compilation.
- [Diagram Layout in Stages][staged-layout] (blog) — staged layout, the
  constraint-vs-objective competition it resolves.
- [Labels in Penrose][labels] (wiki) — MathJax converting labels/`Equation`
  strings to SVG; math-mode TeX.
- [README][readme] / [homepage][homepage] — the tagline and the Venn-diagram trio
  example (Domain/Substance/Style) quoted above.
- [Hackage `penrose` 0.1.1.1][hackage] — the original Haskell reference
  implementation (2019), synopsis _"Create beautiful diagrams just by typing
  mathematical notation in plain text."_
- [`LICENSE`][license] — MIT. [`v3.3.0` release][release] — current version.

<!-- References -->

<!-- External: Penrose paper, docs (live), and source -->

[repo]: https://github.com/penrose/penrose
[readme]: https://github.com/penrose/penrose/blob/c9f4bc612f85f20904154403ba55a1cdf080c5f2/README.md
[license]: https://github.com/penrose/penrose/blob/c9f4bc612f85f20904154403ba55a1cdf080c5f2/LICENSE
[release]: https://github.com/penrose/penrose/releases/tag/v3.3.0
[homepage]: https://penrose.cs.cmu.edu/
[docs]: https://penrose.cs.cmu.edu/docs/ref
[domain]: https://penrose.cs.cmu.edu/docs/ref/domain/overview
[substance]: https://penrose.cs.cmu.edu/docs/ref/substance/overview
[style]: https://penrose.cs.cmu.edu/docs/ref/style/overview
[shapes]: https://penrose.cs.cmu.edu/docs/ref/style/shapes-overview
[using]: https://penrose.cs.cmu.edu/docs/ref/using
[api]: https://penrose.cs.cmu.edu/docs/ref/api
[staged-layout]: https://penrose.cs.cmu.edu/blog/staged-layout
[style-compiler]: https://github.com/penrose/penrose/wiki/How-the-Style-compiler-works
[autodiff-guide]: https://github.com/penrose/penrose/wiki/Autodiff-guide
[labels]: https://github.com/penrose/penrose/wiki/Labels-in-Penrose
[hackage]: https://hackage.haskell.org/package/penrose
[paper]: https://www.cs.cmu.edu/~kmcrane/Projects/Penrose/Penrose_SIGGRAPH.pdf
[paper-doi]: https://dl.acm.org/doi/10.1145/3386569.3392375

<!-- Cross-links into the shared concepts glossary -->

[constraint-opt]: ./concepts.md#constraint-and-optimization-based-layout
[relational]: ./concepts.md#relational-layout
[mobject]: ./concepts.md#mobject-and-the-scene-graph
[execution-models]: ./concepts.md#execution-models
[retained]: ./concepts.md#retained-vs-immediate-mode
[rasterization]: ./concepts.md#rasterization
[glyph-outline]: ./concepts.md#glyph-outline-extraction
[latex-svg]: ./concepts.md#latex-to-svg
[text-shaping]: ./concepts.md#text-shaping
[color-gamma]: ./concepts.md#color-model-and-gamma
[deterministic]: ./concepts.md#deterministic-frame-sampling

<!-- Runnable probes (checked via the ignoreDeadLinks /\.d$/ rule) -->

[bezier-eval]: ./examples/bezier-eval.d
[affine-transform]: ./examples/affine-transform.d
[rate-functions]: ./examples/rate-functions.d
[frame-capture]: ./examples/frame-capture.d
