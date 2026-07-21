# Bluefish (declarative diagramming)

A SolidJS diagramming framework that builds diagrams from **relations** —
declarative, composable, reusable layout fragments over marks — instead of
absolute coordinates, resolving them to SVG through local propagation rather
than a global solver.

| Field          | Value                                                                                                                          |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Language       | TypeScript (JSX; runs in the browser)                                                                                          |
| License        | [MIT][license] (`Copyright (c) 2024 Josh Pollock`)                                                                             |
| Repository     | [`bluefishjs/bluefish`][repo] (~157 stars; monorepo, `pnpm` + Turbo; last pushed May 2026)                                     |
| Documentation  | [bluefishjs.org][site] ([learn][what-is] + [component reference][components])                                                  |
| Category       | Declarative **relational** diagramming framework (web / retained SVG)                                                          |
| First release  | arXiv preprint Jul 2023 (_"A Relational Grammar of Graphics"_); published at [**UIST '24**][paper-acm] (Oct 2024); npm pre-1.0 |
| Paradigm       | [Relational layout][relational-layout]: first-class composable `relations` over marks, not coordinates                         |
| Framework base | [SolidJS][solidjs] (JSX component tree + reactive signals)                                                                     |
| Output format  | **SVG** — marks are thin wrappers around SVG primitives; the diagram is a live DOM subtree                                     |

> [!NOTE]
> This page is grounded in the peer-reviewed paper (the [MIT Visualization
> Group copy][paper-mit] and the [arXiv HTML][paper-arxiv]), the official docs
> ([bluefishjs.org][site]), and the source repo ([`bluefishjs/bluefish`][repo],
> `bluefish-solid` `v0.0.39`). **Provenance correction:** the task brief dated
> the paper to UIST 2023 and titled it _"A Relational Framework for Graphic
> Representations"_. Neither is exact. The work first appeared as an arXiv
> preprint in July 2023 titled _"Bluefish: A Relational Grammar of Graphics"_,
> and was published as **_"Bluefish: Composing Diagrams with Declarative
> Relations"_ at [UIST '24][paper-acm]** (Oct 13–16 2024, Pittsburgh). Bluefish
> renders SVG in a browser, so no `ci`-compiled D probe reproduces its output;
> the catalog's [`affine-transform.d`][affine-transform] probe reimplements the
> coordinate-transform math its scenegraph shares.

---

## Overview

### What it solves

Bluefish targets the **diagramming dilemma**: a low-level drawing toolkit (an
SVG/Canvas API, or `matplotlib`/D3) is maximally expressive but forces the
author to hand-place every coordinate, while a high-level typology (a fixed
chart grammar or a template gallery) gives a recognizable vocabulary but only
covers the diagrams it was built for. Bluefish's answer is to borrow the
**component model** from UI frameworks and relax it: diagrams are assembled from
[relations][relational-layout] — `Align`, `Distribute`, `StackH`/`StackV`,
`Background`, `Arrow`, `Line`, `Group` — that compose the way React/Solid
components compose, but which can _share_ children and _partially_ specify
layout. The paper positions this against exactly the tools this survey covers:
_"Manim (Sanderson, 2018) is a Python library for making animated diagrams"_
([arXiv][paper-arxiv]) is cited as a neighbouring point in the design space.

### Design philosophy

The abstract states the thesis directly — the load-bearing quote for this page,
verified identically against both the [MIT copy][paper-mit] and the
[arXiv HTML][paper-arxiv]:

> _"Diagrams are essential tools for problem-solving and communication as they
> externalize conceptual structures using spatial relationships. But when
> picking a diagramming framework, users are faced with a dilemma. They can
> either use a highly expressive but low-level toolkit, whose API does not match
> their domain-specific concepts, or select a high-level typology, which offers
> a recognizable vocabulary but supports a limited range of diagrams. To address
> this gap, we introduce Bluefish: a diagramming framework inspired by
> component-based user interface (UI) libraries. Bluefish lets users create
> diagrams using relations: declarative, composable, and extensible diagram
> fragments that relax the concept of a UI component."_

The relaxation is precise. A UI component owns its children and fully lays them
out; a **relation** does neither. The docs put the primitive front and centre:
_"The main primitive of Bluefish is the `relation`. Just as components are the
building blocks of user interfaces, relations are the building blocks of
diagrams"_ ([what-is-bluefish][what-is]), and the abstract's follow-on:
_"Unlike a component, a relation does not have sole ownership over its children
nor does it need to fully specify their layout."_ The landing page markets three
pillars — _"Compose with Relations"_, _"Build Reactive Diagrams"_, _"Use
Powerful Custom Layouts"_ ([bluefishjs.org][site]).

---

## How it works

A Bluefish diagram is a **JSX component tree** whose non-leaf nodes are relations
and whose leaves are marks. It is authored in either of two published surfaces:
the [SolidJS][solidjs] JSX package `bluefish-solid` (the paper's syntax) or the
vanilla function-call package `bluefish-js`. The paper's canonical example —
four planets stacked horizontally, with a label attached to one of them — shows
the model in one screen:

```jsx
<Bluefish>
  <Background>
    <StackH spacing={50}>
      <Circle name="mercury" r={15} fill="#EBE3CF" />
      <Circle r={36} fill="#DC933C" />
      <Circle r={38} fill="#179DD7" />
      <Circle r={21} fill="#F1CF8E" />
    </StackH>
  </Background>
  <Background>
    <StackV spacing={30}>
      <Text>Mercury</Text>
      <Ref select="mercury" />
    </StackV>
  </Background>
</Bluefish>
```

The load-bearing move is `<Ref select="mercury" />`. The Mercury circle is a
child of the `StackH` (which fixes its horizontal position among the planets)
_and_ is referenced by the `StackV` label group (which stacks the label above
it) — one node, two parents, layout _"determined jointly by all parents"_
([arXiv][paper-arxiv]). A relation is **declarative** because it _"cannot
override properties that have already been set"_ ([tutorial][tutorial]), so the
`StackV` positions the label relative to Mercury without disturbing the
`StackH` spacing already established. The same diagram in the `bluefish-js`
function-call API:

```tsx
import {
  StackH,
  StackV,
  Circle,
  Text,
  Ref,
  Background,
  render,
} from 'bluefish-js';

function Diagram() {
  return [
    Background(
      { padding: 40, fill: '#859fc9' },
      StackH({ spacing: 50 }, [
        Circle({ name: 'mercury', r: 15, fill: '#EBE3CF' }),
        Circle({ r: 36, fill: '#DC933C' }),
        Circle({ r: 38, fill: '#179DD7' }),
        Circle({ r: 21, fill: '#F1CF8E' }),
      ]),
    ),
    Background(
      { rx: 10 },
      StackV({ spacing: 30 }, [Text('Mercury'), Ref({ select: 'mercury' })]),
    ),
  ];
}
render(Diagram, document.getElementById('app'));
```

**The compound-graph scenegraph.** Sharing a child breaks the tree, so Bluefish
generalises the [scenegraph][scenegraph]:

> _"Bluefish's relational scenegraph is an instance of a `compound graph`: a
> data structure that maintains the hierarchical information of traditional
> scenegraphs while also encoding adjacency relationships between nodes."_
> ([arXiv][paper-arxiv])

Every `Ref` instantiates a node in the hierarchy that links to its target as an
_adjacency_ — the tree carries containment, the adjacency edges carry the shared
references.

**Layout is local propagation, not a global solver.** This is the sharpest
contrast with the [constraint-and-optimization school][constraint-layout] and
the most important honest finding on this page: **Bluefish does not optimize and
does not run a global constraint solver.** The authors built one and removed it:

> _"we implemented an early version of Bluefish using the Cassowary linear
> programming solver … However, in doing so, we identified a series of tradeoffs
> at odds with our design goals."_ ([arXiv][paper-arxiv])

The reason is debuggability: _"A global solver increases viscosity for diagram
authors: it can be difficult to localize layout bugs because the solver reasons
about all constraints at once"_ ([arXiv][paper-arxiv]). Instead Bluefish runs
_"tree-based local propagation"_ — a single pass in which _"when a node's layout
algorithm is evaluated, it invokes the algorithms of its children by proposing a
width and height for each child"_ ([arXiv][paper-arxiv]), the same measure/place
protocol modern UI engines use. Contrast [Penrose][penrose], the survey's other
relational/constraint data point, which _does_ minimise a numerical constraint
energy: _"Bluefish's component-inspired abstraction colocates data and display
logic while Penrose, inspired by HTML and CSS, groups data and display logic
separately"_ ([arXiv][paper-arxiv]).

---

## Object & scene model

The object model is a [**retained**][retained] compound-graph scenegraph
([above](#how-it-works)). Leaves are **marks**: _"A mark is a basic visual
element. Bluefish's mark standard library comprises `Rect`, `Circle`, `Ellipse`,
`Path`, `Image`, and `Text`. Marks are thin wrappers around SVG primitives,
except for `Text`"_ ([arXiv][paper-arxiv]). Interior nodes are **relations**,
grouped by the paper against Gestalt grouping principles:

| Relation            | Gestalt principle   | Effect                                                            |
| ------------------- | ------------------- | ----------------------------------------------------------------- |
| `Align`             | alignment           | Aligns children on a shared edge/centre axis                      |
| `Distribute`        | uniform density     | Spaces children with uniform gaps                                 |
| `StackH` / `StackV` | alignment + density | Horizontal/vertical stack (align + uniform spacing in one)        |
| `Background`        | common region       | Draws an enclosing region behind its children                     |
| `Arrow` / `Line`    | connectedness       | Draws a connector between two referenced elements                 |
| `Group`             | (composition)       | Renders children without imposing layout (unset fields default 0) |
| `Ref`               | —                   | A proxy/pointer to an existing element, enabling shared children  |

Because layout flows locally, each relation sets only the fields it owns and
leaves the rest to other parents — the defining departure from a UI component.
Coordinate composition down the graph is ordinary [affine][affine-transform]
transform stacking (a mark's placed box is its local box mapped through its
ancestors' transforms); the [`affine-transform.d`][affine-transform] probe
reimplements exactly that compose-once-apply math. Layout itself, however, works
on **axis-aligned bounding boxes**, a coarser abstraction than the true mark
outline (see [Weaknesses](#weaknesses)).

## Animation & timing model

**Largely absent — finding of absence.** Bluefish is a **static-diagram**
framework: the paper describes no timeline, no interpolation/easing engine, and
no [play-head/generator execution model][execution-models] of the kind Motion
Canvas or a Manim `Scene` provides. Animation appears in the paper only as a
property of a _neighbouring_ tool (_"Manim … is a Python library for making
animated diagrams"_, [arXiv][paper-arxiv]), never as a Bluefish feature. The one
dynamic facility is **reactivity**: because Bluefish is built on [SolidJS][solidjs]
signals, a diagram can re-derive and re-layout when its backing state changes,
which is what the landing page's _"Build Reactive Diagrams"_ and _"interactive
and animated diagrams with popular reactive UI primitives"_ ([bluefishjs.org][site])
refer to. That is reactive re-rendering, not a tweened timeline — there is no
`ValueTracker`/`yield*` play-head, no per-frame sampling, and no rate functions.
Motion over time is the author's responsibility (drive a signal from
`requestAnimationFrame`), not a first-class engine concept.

## Rendering backend & rasterization

Bluefish does not [rasterize][rasterization]. It emits an **SVG DOM subtree**
and hands pixel production to the browser: marks are _"thin wrappers around SVG
primitives"_ ([arXiv][paper-arxiv]), and Solid's DOM renderer materialises them.
So the entire [CPU-vector-vs-GPU-vector][rasterization] question — fill
triangulation, coverage-based anti-aliasing, the tessellation pipeline that a
native Manim/`Cairo`/OpenGL backend must implement — is delegated wholesale to
the SVG rendering engine of the host browser. Color is authored as CSS/SVG
color strings (`fill="#EBE3CF"`), so the [color-model/gamma][color-gamma]
behaviour is likewise the browser's sRGB compositing, not something Bluefish
defines. The framework's job ends at producing correct SVG geometry.

## Typesetting & text

`Text` is the one mark that is _not_ a thin SVG wrapper (_"Marks are thin
wrappers around SVG primitives, except for `Text`"_, [arXiv][paper-arxiv]),
because layout needs a text element's measured size _before_ it can place
neighbours — the general problem that _"aligning widths and heights of elements"_
requires determining minimum sizes ahead of layout ([arXiv][paper-arxiv]). Text
is measured via the browser (SVG `getBBox`/`getComputedTextLength`), so
[glyph-outline extraction][glyph-outline] and [text shaping][text-shaping] are
the browser's font stack, not Bluefish's — there is no LaTeX pipeline, no
`freetype`/`HarfBuzz` integration, and no glyph-to-path conversion in the
framework itself. The paper flags text-baseline handling as a recurring
_"precise alignment and spacing"_ limitation ([arXiv][paper-arxiv]): the
bounding-box-only layout cannot reason about baselines and cap-heights the way a
true typesetting engine would.

## Output & encoding

**Absent — finding of absence.** Bluefish's "output" is the live **SVG element
in the DOM**; there is no [frame-capture/readback][affine-transform] path, no
codec, no muxing, and no video/image-sequence export in the framework. It has no
analogue of the native _"render → framebuffer readback → encode"_ pipeline the
[`frame-capture.d`][frame-capture] probe models — that pipeline is precisely
what a browser-SVG target obviates and deliberately does not provide. Producing a
PNG or a video is left to the surrounding page (serialize the SVG, or screenshot
the browser); the survey's [output-and-encoding axis][execution-models] simply
does not apply to a retained-SVG framework.

## Interactivity, preview & authoring

Authoring is **code-first in the browser**, with the SolidJS ecosystem as the
harness: _"Bluefish is implemented in SolidJS, a reactive UI framework. Solid
provides a JSX component abstraction, signal library, and renderer for Bluefish"_
([arXiv][paper-arxiv]). There is no bespoke visual editor or scrubbable-timeline
IDE of the Motion-Canvas/Theatre.js kind; the "preview" loop is the ordinary web
dev loop (Vite HMR, Storybook — both present in the `bluefish-solid` toolchain).
**Interactivity** rides on Solid's reactivity: because a diagram is a reactive
component tree, it can respond to signals/events and re-lay-out, which is the
substance of the marketed _"interactive … diagrams"_. The declarative-reference
model (`Ref`, `name`/`select`) is what makes such diagrams _authorable_ at scale
— a shared element is named once and pointed at, rather than duplicated.

## Extensibility & API surface

Extensibility is a stated design goal — relations are _"declarative, composable,
and extensible"_ ([abstract][paper-arxiv]) — and the mechanism is that a relation
_is just a Solid component_ that reads/writes its children's boxes through the
same measure/place protocol the built-ins use. Custom relations and custom
layouts (_"Use Powerful Custom Layouts"_, [bluefishjs.org][site]) are therefore
first-class, not plugins. The published npm surface reflects a real, if young,
library rather than a paper artifact: `bluefish-solid` (`v0.0.39`, _"A SolidJS
diagramming library"_) depends on `solid-js`, and pulls domain helpers —
`d3-scale`, `dagre` (graph layout), `paper`, `perfect-arrows`, `smiles-drawer`
(chemistry) — showing the intended reach beyond generic boxes-and-arrows. The
authors frame the repo as dual-purpose: _"Bluefish is open source, and we aim to
shape it into both a usable tool and a research platform"_ ([arXiv][paper-arxiv]).

## Determinism, caching & performance

Layout is a **deterministic single local-propagation pass** — the same
scenegraph yields the same boxes, with no solver iteration or random seed to
perturb it (a deliberate contrast with an [optimizer's][constraint-layout]
convergence-and-seed sensitivity). The paper reports it is fast and scales
predictably: _"Bluefish scales linearly with the size of the scenegraph"_ and,
across the paper's example gallery, _"all examples run in less than 175ms"_
([arXiv][paper-arxiv]). There is no content-hash frame cache (no frames), and no
persistent build cache is described; performance is a function of the SolidJS
reactive graph and the browser's SVG layout/paint. The bounding-box layout
abstraction is what keeps the pass cheap and local — and is also the source of
its geometric imprecision.

## Strengths

- **Relations compose like UI components** — a familiar mental model (`Stack`,
  `Align`, `Background`) with the crucial relaxation that children can be
  **shared** and layout **jointly** determined, so complex diagrams grow by
  composition instead of coordinate bookkeeping.
- **Local propagation is debuggable** — layout information _"only flows locally"_
  ([arXiv][paper-arxiv]), so a misplacement is traceable to one relation, unlike
  a global solver where _"the solver reasons about all constraints at once."_
- **Deterministic and fast** — one linear pass, no optimizer iteration; the
  paper's whole example set lays out in `<175ms`.
- **Rides the web platform** — SVG output plus SolidJS reactivity means zero
  rasterization/typesetting/encoding code to maintain, and diagrams are
  interactive and embeddable for free.
- **Extensible by construction** — custom relations are ordinary components using
  the same protocol as the built-ins.

## Weaknesses

- **No animation or timeline** — reactive re-layout only; no play-head,
  interpolation, easing, or per-frame model ([axis 2](#animation--timing-model)).
- **No output/encoding pipeline** — output is a DOM SVG element; PNG/video export
  is out of scope ([axis 5](#output--encoding)).
- **Bounding-box-only layout is geometrically coarse** — _"Bluefish represents
  shapes during layout using axis-aligned bounding boxes, which are too coarse
  for shapes like circles or paths"_ ([arXiv][paper-arxiv]); precise
  edge-to-curve alignment and text-baseline spacing are known limitations.
- **Research-grade maturity** — pre-1.0 (`bluefish-solid` `v0.0.39`), small
  community (~157 stars), a self-described _"research platform"_ as much as a
  product; APIs (two syntaxes coexist) are still shifting.
- **Browser-bound** — no headless/native rendering target; anything the SVG/DOM
  engine can't express, Bluefish can't either.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                    | Trade-off                                                                                |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **Relations** (relaxed UI components) as the primitive     | Familiar composition + shared children + partial layout → wide diagram range | A new mental model vs plain components; joint layout can surprise                        |
| **Compound-graph** scenegraph (tree + adjacency)           | Lets one node have multiple parents via `Ref` while keeping hierarchy        | More complex than a tree; references must resolve, name collisions matter                |
| **Tree-based local propagation**, no global solver         | Debuggable, deterministic, linear-time layout                                | Can't express truly global/cyclic constraints; abandoned Cassowary to get here           |
| Cassowary/global constraints **removed** after prototyping | Global solvers raise "viscosity"; bugs aren't localizable                    | Loses the expressive power of arbitrary simultaneous constraints                         |
| **SVG marks + SolidJS** rendering                          | No rasterizer/typesetter/encoder to build; free reactivity + interactivity   | Browser-bound; no native/headless/video path; layout can't see true glyph/curve geometry |
| **Bounding-box** layout geometry                           | Keeps the local pass cheap and simple                                        | Too coarse for circles/paths and text baselines — a stated precision limitation          |
| **Static** diagrams (reactivity, not a timeline)           | Focus on structure/composition; animation deferred to future work            | No built-in tweening/play-head; motion is the author's job via signals                   |

---

## Sources

- [Bluefish: Composing Diagrams with Declarative Relations][paper-acm] — Pollock,
  Mei, Huang, Evans, Jackson, Satyanarayan (MIT CSAIL + unaffiliated), **UIST '24**
  (Oct 13–16 2024, Pittsburgh). Read via the [MIT Visualization Group copy][paper-mit]
  and the [arXiv HTML `2307.00146v4`][paper-arxiv] (preprint first posted Jul 2023
  as _"A Relational Grammar of Graphics"_). Source of the abstract, the compound-graph
  and local-propagation model, the Cassowary/Penrose contrasts, the marks definition,
  and the performance/limitation figures.
- [`bluefishjs/bluefish`][repo] — the source monorepo (MIT, [`LICENSE`][license],
  `Copyright (c) 2024 Josh Pollock`); `bluefish-solid` `v0.0.39` ([`package.json`][pkg],
  _"A SolidJS diagramming library"_, `solid-js` peer dep).
- [bluefishjs.org][site] — official site: [_What is Bluefish?_][what-is] (the
  "relations are the building blocks of diagrams" framing), [Tutorial Part 1][tutorial]
  (the planets example + declarative-reference semantics), and the
  [component reference][components].
- [SolidJS][solidjs] — the reactive UI framework Bluefish is implemented in.
- [Penrose][penrose] — the survey's optimizer-based counterpoint; see also the
  [constraint & optimization-based layout][constraint-layout] concept note.

<!-- References -->

[paper-mit]: https://vis.csail.mit.edu/pubs/bluefish/
[paper-arxiv]: https://arxiv.org/html/2307.00146v4
[paper-acm]: https://dl.acm.org/doi/10.1145/3654777.3676465
[repo]: https://github.com/bluefishjs/bluefish
[license]: https://github.com/bluefishjs/bluefish/blob/a6d2134a0c4b6c388e9f1646f1085fb68d882a2f/LICENSE
[pkg]: https://github.com/bluefishjs/bluefish/blob/a6d2134a0c4b6c388e9f1646f1085fb68d882a2f/packages/bluefish-solid/package.json
[site]: https://bluefishjs.org/
[what-is]: https://bluefishjs.org/learn/what-is-bluefish.html
[tutorial]: https://bluefishjs.org/learn/tutorial-1-intro.html
[components]: https://web.archive.org/web/20240226044732/https://bluefishjs.org/docs/category/components
[solidjs]: https://www.solidjs.com/
[penrose]: https://penrose.cs.cmu.edu/
[relational-layout]: ./concepts.md#relational-layout
[constraint-layout]: ./concepts.md#constraint-and-optimization-based-layout
[scenegraph]: ./concepts.md#mobject-and-the-scene-graph
[retained]: ./concepts.md#retained-vs-immediate-mode
[execution-models]: ./concepts.md#execution-models
[rasterization]: ./concepts.md#rasterization
[glyph-outline]: ./concepts.md#glyph-outline-extraction
[text-shaping]: ./concepts.md#text-shaping
[color-gamma]: ./concepts.md#color-model-and-gamma
[affine-transform]: ./examples/affine-transform.d
[frame-capture]: ./examples/frame-capture.d
