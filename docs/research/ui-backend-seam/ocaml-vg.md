# OCaml Vg — the seam is a value, and every backend documents what it cannot do

**Category:** declarative vector graphics with a documented renderer contract.
**Last reviewed:** August 23, 2026. Pinned at [`58ab81a9`][rev].

The one subject in this survey whose capability contract is **prose someone took
seriously**: each of the four shipped renderers ends with a
`Render warnings and limitations` section naming the exact images it will refuse
to draw correctly. That artifact is what
[`canvas-seam-friction.md`][friction] §2 says `isCanvas` lacks, and Vg is the
proof it can be written by hand for a real backend set.

Vg is also the purest statement of the position [`comparison.md`][comparison]'s
**F2** circles: the thing handed to a backend is not a command list at all but an
algebraic value denoting a function from the plane to colours.

|                         |                                                                                                          |
| ----------------------- | -------------------------------------------------------------------------------------------------------- |
| **Language**            | OCaml                                                                                                    |
| **License**             | ISC ([`opam`][opam])                                                                                     |
| **Repository**          | [`dbuenzli/vg`][rev]                                                                                     |
| **Documentation**       | [`doc/index.mld`][indexmld], [`doc/tutorial.mld`][tutorial], [`doc/semantics.mld`][semantics]            |
| **Category**            | declarative vector graphics; documented renderer contract                                                |
| **Pinned revision**     | `58ab81a9c25e47627838c8d973e9cc77efb3f08d` (`master`; latest tagged release `v0.9.5`, 2024-01-23)        |
| **Companion library**   | [`dbuenzli/gg`][gg] — geometry, colour and raster types, pinned at `2c5e7437`                            |
| **Backends shipped**    | [`Vgr_svg`][svgmli], [`Vgr_pdf`][pdfmli], [`Vgr_htmlc`][htmlcmli] (HTML canvas), [`Vgr_cairo`][cairomli] |
| **Renderer-author API** | `Vg.Vgr.Private` in [`src/vg.mli`][vgmli]                                                                |
| **Target range**        | vector only — PDF/PS, SVG, HTML canvas, Cairo raster. No cell target, no GPU target.                     |

> [!NOTE]
> Vg does not span this survey's hard case: there is no terminal backend and no
> shaped-glyph GPU backend. It earns its place for two other reasons — the
> renderer contract is written down, and the seam is a value rather than a
> stream of calls.

## Overview

### What it solves

Rendering one immutable, resolution-independent image description to several
document and canvas formats, where the formats disagree about which parts of the
description they can honour — and saying so, per format, in the format's own
documentation.

### Design philosophy

Vg rejects the painter model outright. From [`doc/tutorial.mld`][tutorial]:

```text
Usual vector graphics libraries follow a painter model in which paths are
filled, stroked and blended on top of each other to produce a final image. Vg
departs from that, it has a collage model in which paths define 2D areas in
infinite images that are cut to define new infinite images to be blended on top
of each other.

[...]

Images are immutable and abstract value of type image. Conceptually, images are
seen as functions mapping points of the infinite 2D plane to colors:

    type Vg.image  ≈  Gg.p2 -> Gg.color
```

[`doc/semantics.mld`][semantics] then gives every combinator a denotation —
`I.blend`, `I.cut`, `I.move` are each defined by what colour the composite image
has at an arbitrary point `pt`. The lineage is cited in the tutorial: Conal
Elliott's _Functional Image Synthesis_ and Antony Courtney's _Haven_.

The consequence for the seam is structural. An image has **no extent, no
resolution and no units** — [`doc/tutorial.mld`][tutorial]: "It has no units,
you define what they mean to you." Everything a backend needs to allocate a
surface therefore has to arrive from somewhere else, and Vg's answer to that is
the [`renderable`](#q8--extent-query).

## How it works

### The public seam: a target, a renderable, a resumable render

A backend is a value of type `'a Vg.Vgr.target`, produced by a
conventionally-named `Vgr_bla.target` function, and consumed by `Vgr.create` /
`Vgr.render` ([`src/vg.mli`][vgmli]):

```ocaml
type renderable = size2 * box2 * image
(** The physical size on the render target in millimeters, the view rectangle
    and the image to render. *)

type dst_stored = [ `Buffer of Buffer.t | `Channel of out_channel | `Manual ]
type dst = [ dst_stored | `Other ]
type 'a target constraint 'a = [< dst ]

val create : ?limit:int -> ?warn:warn -> ([< dst] as 'dst) target -> 'dst ->
  renderer
val render : renderer -> [< `Image of renderable | `Await | `End ] ->
  [ `Ok | `Partial ]
```

Two things are worth naming. The target's type parameter **statically restricts
which destinations it accepts** — `Vgr_svg.target` returns a
`Vg.Vgr.dst_stored Vg.Vgr.target`, so it cannot be created against `` `Other ``,
while `Vgr_htmlc.target` returns ``[`Other] Vg.Vgr.target`` and cannot be
pointed at a `Buffer`. And `render` is **resumable**: it returns `` `Partial ``
when the output buffer is full or the `limit` budget is exhausted, and the
client drives it with `` `Await `` until `` `Ok ``.

### The renderer-author seam: `Vgr.Private.Data.image`

What a backend actually consumes is not the abstract `image` but its internal
representation, exposed under `Vg.Vgr.Private` with an explicit warning that it
"is subject to change even between minor versions". It is a five-constructor
recursive sum type ([`src/vg.mli`][vgmli]):

```ocaml
type tr = Move of v2 | Rot of float | Scale of v2 | Matrix of m3

type primitive =
  | Const of color
  | Axial of Color.stops * p2 * p2
  | Radial of Color.stops * p2 * p2 * float
  | Raster of box2 * raster

type glyph_run =
  { font : font; text : string option; o : p2;
    blocks : bool * (int * int) list; advances : v2 list; glyphs : glyph list; }

type image =
  | Primitive of primitive
  | Cut of P.area * path * image
  | Cut_glyphs of P.area * glyph_run * image
  | Blend of blender * float option * image * image
  | Tr of tr * image
```

Paths are a second, flatter sum — `` `Sub | `Line | `Qcurve | `Ccurve | `Earc |
`Close `` — held reversed. `tr` is deliberately _not_ normalised to a matrix:
the comment says "Not uniformely expressed as a matrix since renderers may have
shorter syntaxes for some transforms" — a semantic channel kept open purely so a
backend can emit `translate(…)` instead of `matrix(…)`.

The backend flattens the tree itself. [`src/vgr_svg.ml`][svgml] keeps a worklist
and rewrites it as it walks, which is also where the resumability lives:

```ocaml
type cmd = Set of gstate | Draw of Vgr.Private.Data.image

let rec w_image s k r =
  if s.cost > limit s then (s.cost <- 0; partial (w_image s k) r) else
  match s.todo with
  | [] -> Hashtbl.reset s.prims; … ; k r
  | Set gs :: todo -> set_gstate s gs; s.todo <- todo; b_str s "</g>"; …
  | (Draw i) :: todo ->
      s.cost <- s.cost + 1;
      match i with
      | Primitive _ as i ->        (* Uncut primitive, just cut to view. *)
          s.todo <- (Draw (Cut (`Anz, view_rect s, i))) :: todo; …
      | Blend (_, _, i, i') -> s.todo <- (Draw i') :: (Draw i) :: todo; …
```

The `limit` budget is a documented cost model: "each image combinator costs one
unit, when the limit is reached `render` returns with `` `Partial ``".

### The written contract

`Vgr.Private` opens with an enumerated list of obligations on renderer authors —
naming conventions, colour model, the cost model, the coordinate convention —
ending with the rule that makes the per-backend limitation sections mandatory
([`src/vg.mli`][vgmli]):

```text
- If the renderer doesn't support Vg's full rendering model or diverges from its
  semantics it must ignore unsupported features and warn the client via the warn
  function.
```

## Q1 — measurement units, and who answers

**Vg has no text measurement API at all**, and says so at the top of the `Font`
module ([`src/vg.mli`][vgmli]):

```text
Font handling in Vg happens in renderers and text layout and text to glyph
translations are expected to be carried out by an external library. Values of
type Vg.font just represent a font specification to be resolved by the concrete
renderer.
```

`Vg.font` is a record of `name`, `slant`, `weight`, `size` — a _specification_,
not a resolved face. `glyph` is `int`, "a glyph identifier in a backend
dependent font format". And `I.cut_glyphs` takes `?advances:v2 list` from the
**caller**: positioning is the client's output, not a service the seam offers.
`Vgr_pdf`'s documentation makes the intended pipeline explicit — resolve a font
with a mechanism independent from Vg, shape with a mechanism independent from
Vg, then pass the resulting `advances` and `glyphs` in.

This is F1 taken further than any other surveyed subject: measurement is not
merely off the painter (Slint, Qt) or pre-resolved into a value (egui), it is
**out of the library**. The unit question dissolves because `font.size` is
denominated in Vg's unitless coordinate space, which the `renderable` later
binds to millimetres.

## Q2 — is the contract stated in one place?

**Stated, in prose, per renderer — and not queryable.** There is no
`hasFeature`, no capability enum, no optional module. What exists instead is a
convention every shipped backend follows: a `Render warnings and limitations`
section listing exactly the constructor shapes it cannot honour. From
[`src/htmlc/vgr_htmlc.mli`][htmlcmli], quoted in full because it is the reason
this subject is on the list:

```text
The following render warnings are reported.
- `Unsupported_cut ((`O o), i)`, outline area cuts can be performed only on
  (possibly transformed) Vg.I.const, Vg.I.axial and Vg.I.radial primitive
  images.
- `Unsupported_glyph_cut (a, i)`, glyph cuts can be performed only on bare
  Vg.I.const primitive images and outline area glyph cuts are currently
  unsupported.
- `Textless_glyph_cut i` if no text argument is specified in a glyph cut.
- `Other _` if dashes are rendered but unsupported by the browser.

The following limitations should be taken into account.
- The even-odd area rule is supported according to the latest whatwg spec. This
  may not work in all browsers.
- In the HTML canvas gradient color interpolation is performed in (non-linear)
  sRGB space. This doesn't respect Vg's semantics.
```

Three properties of that text are transferable. It is **written in the
vocabulary of the seam** — `` `O o ``, `I.const`, `I.axial` are the actual
constructors, so a reader can decide mechanically whether their image is
affected. It separates **reported degradations** (a `warning` value arrives at
runtime) from **silent divergences** (colour interpolation, which no warning can
catch). And the same section exists, differently populated, in all four
renderers — [`Vgr_svg`][svgmli] on viewers ignoring its linear-sRGB directive,
[`Vgr_pdf`][pdfmli] on uncompressed streams and unsubsetted fonts,
[`Vgr_cairo`][cairomli] on weight limited to normal/bold — so a reader learns
which divergences are the _format's_ fault rather than the backend's.

The runtime half is a small closed sum type:

```ocaml
type warning =
  [ `Unsupported_cut of P.area * I.t
  | `Unsupported_glyph_cut of P.area * I.t
  | `Textless_glyph_cut of I.t
  | `Other of string ]

type warn = warning -> unit
```

A warning **carries the offending image back to the client**, so a caller can
identify what degraded rather than merely that something did. This is a third
position beyond the two F4 records: not Qt's queryable feature bitmask and not
Notcurses' refusable `NCVISUAL_OPTION_NODEGRADE`, but _degrade-and-report_, with
the report identifying the exact value. Note what it still cannot do: there is
no way to ask **in advance** whether an image will render faithfully, and no way
to demand failure instead of degradation. F4's "refusable degrade" half is
unmet here.

## Q3 — semantic operations or primitives?

**Primitives, and only five of them.** No widget vocabulary reaches the
backend — nothing resembling `draw_text_input`, `draw_box_shadow` or our
`scrollbar` — because Vg is not a widget toolkit. It does face the general
problem of a target that cannot honour an intent, and its answer is **not** a
semantic operation but a semantic _field on an existing primitive_: see Q6.

The finding for [friction §3][friction] is a third option the survey had not yet
named: where Slint promotes intent to an operation and egui erases
it entirely, Vg keeps the operation primitive and attaches the intent as an
optional payload field, with a named warning for the case where a backend needed
it and it was absent.

## Q4 — command shape

**A sum type — but a recursive tree, not a flat stream.** `Data.image` has five
constructors, `primitive` four, `tr` four, `segment` six polymorphic-variant
cases. Nothing anywhere in the seam is a tag plus dead fields. `Blend` carries
its two operands as children; `Tr` carries its subtree; `Cut` carries the image
it cuts. Structure that `DrawOp` would have to encode by ordering conventions is
carried by the type.

That is F2 confirmed on the encoding question and **complicated on the shape
question**. F2 says "re-encode `DrawOp` as a sum type, keeping the reified
stream". Vg reifies a _scene expression_, and the linearisation into a work
queue happens **in the backend** ([`src/vgr_svg.ml`][svgml]'s `todo : cmd list`),
which is precisely what buys the resumable `` `Partial `` continuation and the
`Set gstate` push/pop pairing: the backend can suspend mid-traversal because it
owns the stack. A flat pre-linearised op array cannot be suspended that way
without the framework owning an explicit cursor.

Vg also shows the cost. Because the value is a tree of combinators compared
structurally (`I.equal` is documented to compare "the structure of image values
not their denotational interpretation"), redundancy is invisible to the
framework and every backend re-discovers it: [`src/vgr_svg.ml`][svgml] carries
four memo tables — `fonts`, `prims`, `paths`, `clips` — to avoid re-emitting the
same geometry.

## Q5 — sub-unit placement

**Does not arise.** Coordinates are `float` throughout `Gg` — `p2`, `v2`,
`box2`, `size2` — and the plane is continuous and unitless. Line width is
`outline.width : float`; there is no "hairline" concept and no edge enumeration,
because a rule along a box's top edge is just a rectangle of the width you meant.

Vg does make explicit what the other continuous subjects leave implicit: the
mapping to physical reality is **supplied per render**, as the `size2` in
millimetres inside `renderable` — "the corners of the specified view rectangle
are mapped on a rectangular area of the given physical size on the target"
([`doc/tutorial.mld`][tutorial]). Vg's answer to "what is a device pixel" is
_the caller decides at render time, in millimetres_. A fourth confirmation of
F5's diagnosis that `RuleEdge` is a symptom of integer cell coordinates.

## Q6 — resolved appearance, semantic role, or both

**Both, deliberately, on exactly one construct — and it is documented why.**
The colour channel is fully resolved: `Const of color`, `Axial of stops * p2 *
p2` — no slot, no theme role, nothing for a backend to re-resolve.

The exception is `Cut_glyphs`, whose `glyph_run` carries `glyphs : glyph list`
and `advances : v2 list` (the resolved form) **and** `text : string option` plus
`blocks` (the semantic form). [`src/vg.mli`][vgmli] states the reason:

```text
If provided the text parameter indicates the UTF-8 text corresponding to the
sequence of glyphs. This may be used by certain renderer to allow text search in
the result or to draw the text if it lacks control over glyph rendering (in
which case an empty list of glyphs may be passed).
```

Three of the four shipped renderers take that escape hatch: `Vgr_svg`,
`Vgr_htmlc` and `Vgr_cairo` each document "The `blocks`, `advances` and `glyphs`
parameters are ignored. `text` must be provided", selecting a font by CSS or
Cairo family and letting the format shape. Only `Vgr_pdf` consumes the resolved
channel, and only when the client resolved the font to `` `Otf otf ``. A backend
that needs the semantic channel and does not get it emits
`` `Textless_glyph_cut ``.

**This complicates F3 and vindicates [friction §6][friction].** The friction log
records carrying `visual` _and_ `slot` as the seam "hedging rather than
deciding". Vg hedges in the same way, for the same reason — some backends can
consume the resolved form and some can only consume the intent — and treats it
as a design, with a named failure for the missing case. The transferable
refinement is that Vg pays the dual channel on **one constructor**, not on every
op: the redundancy is scoped to the primitive that actually has two consumers.
`DrawOp` pays it eighteen fields wide.

## Q7 — payload ownership

**Immutable persistent values under a garbage collector; nothing is borrowed.**
An `image` is a value, so it outlives any frame, can be stored, compared with
`I.equal`, printed with `I.pp`, and rendered again to a different target. The
question friction §7 asks — can a command outlive the frame that made it —
is not a question here.

The interesting part is what backends do on top. [`src/vgr_svg.ml`][svgml]
keeps `fonts`, `prims`, `paths` and `clips` hash tables **inside the renderer's
own state**, keyed by the internal data values, resetting them when the worklist
empties — Slint's `draw_cached_pixmap` bargain reached independently: the party
that knows how expensive a payload is to materialise in _this_ format owns the
cache. **F6** is confirmed by a subject with no reference counting at all, which
strengthens it: the finding is "share, do not borrow", and a GC is one way to
share.

## Q8 — extent query

**Inverted: the scene cannot be asked, so the caller must tell.** An image
denotes the infinite plane; asking its extent is not merely unimplemented but
meaningless. Vg therefore makes the answer part of the render call —
`renderable = size2 * box2 * image`, physical size and view rectangle
mandatory — and [`doc/tutorial.mld`][tutorial] states the rule: "An infinite
image alone cannot be rendered. We need a finite view rectangle and a
specification of that view's physical size on the render target."

This is the strongest available confirmation of **F7**. Extent belongs to the
surface, and Vg puts it in the _type_ of what you hand a renderer, so the
`skia-canvas-render.d` failure mode — scan every op's rect and hope — cannot
occur. `Vgr_htmlc.target`'s `?resize:bool` shows the flow direction: by default
the backend **sets the canvas CSS size from the renderable's physical size**;
pass `resize:false` and the surface's own size wins and the view is mapped onto
it. Either way the extent comes from outside the scene.

## Strengths

- **The limitation sections.** Four backends, four hand-written statements of
  what will silently differ, in the seam's own vocabulary. No other surveyed
  subject ships this artifact.
- **Warnings carry the offending value**, not just a code, so a client can
  locate what degraded.
- **The seam is a value with a denotational specification.** Equality,
  printing, storage and re-rendering all fall out; `doc/semantics.mld` makes
  "correct" a checkable claim rather than a matter of taste.
- **Type-level destination restriction.** `'a target constraint 'a = [< dst]`
  makes "this backend only writes to a byte sink" a compile error.
- **Resumability without a framework cursor**: the backend owns the traversal,
  so `` `Partial `` costs one closure and a cost counter.
- **Geometry lives in a separate library** — the split `sparkles:math` has.

## Weaknesses

- **The contract is prose, so nothing checks it.** Nothing fails if a renderer
  degrades without warning, or if a limitations section rots.
- **No advance query, no refusable degrade.** A caller cannot ask "will this
  render faithfully" and cannot demand failure — exactly what a golden test
  wants.
- **`Vgr.Private` is explicitly unstable**, "subject to change even between
  minor versions", so backend authors are second-class by design.
- **Structural redundancy is the backend's problem**, and each of the four
  independently grew memo tables to cope.
- **Text is the weak seam and is admitted to be.** `cut_glyphs` is marked
  "WARNING. The interface and specifics of glyph rendering are still subject to
  change"; its `?area` parameter, "Backend support is poor this may be removed
  in the future".
- **The internal vocabulary is richer than the public one.** `Data.blender`
  admits `` `Atop | `In | `Out | `Over | `Plus | `Copy | `Xor `` while `I.blend`
  exposes only source-over; a backend must handle cases no caller can construct.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                      | Trade-off                                                                                               |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Image = function from the plane to colours, not a command list     | Gives every combinator a denotation; composition is closed and specifiable                     | Nothing has an extent; the caller must supply a view rectangle on every render                          |
| Collage model (cut + blend) instead of fill/stroke/clip            | "image cuts and blends naturally unify the distinct concepts of clipping paths, path strokes…" | Backends must translate back into fill/stroke/clip, and most cannot do outline cuts of arbitrary images |
| Backend consumes a recursive sum tree, not a flat stream           | Structure is in the type; backend owns traversal, so suspension is cheap                       | Each backend re-implements flattening and re-derives its own memo tables                                |
| Capability contract as per-renderer prose plus a runtime `warning` | Honest about format divergence a bitmask could not express (sRGB interpolation, browser bugs)  | Unchecked, unqueryable, and not refusable                                                               |
| Fonts are specifications; shaping is the client's job              | Keeps a graphics library out of the text-layout business                                       | Text is the weakest part of the seam, and three of four backends ignore the glyph channel entirely      |
| `text` carried alongside `glyphs` on one constructor               | Lets a backend without glyph control render the intent; also enables PDF text extraction       | A redundant channel, and a named failure (`` `Textless_glyph_cut ``) when a backend needed it           |
| Geometry and colour split into `Gg`                                | Reusable outside Vg; colour model (linear sRGB) specified once                                 | A second library and a second set of docs to keep in step                                               |

## Bearing on the proposal

1. **Write the limitations section.** [Friction §2][friction] says the contract
   is unstated; Vg shows the minimum viable artifact is a per-backend prose
   section written **in the seam's own vocabulary** — naming `OpKind` members
   and `RuleEdge` values, not "some clipping is approximate". `GridCanvas`,
   `RaylibCanvas` and `SkiaCanvas` each need one, and `SkiaCanvas.measure`
   returning `cellsOf(text)` is its first entry.
2. **Separate reported degradations from silent divergences.** Vg's htmlc
   section does this and it is the part a capability enum cannot reach: gradient
   interpolation in non-linear sRGB is a divergence no `hasFeature` bit could
   have surfaced. Our equivalents — a cell backend's whole-cell `rule`, a
   terminal's palette quantisation — belong in the same list.
3. **A degradation report should carry the value that degraded.** Vg's
   `warning` cases each carry the offending `I.t`. A `sparkles:ui` equivalent
   should carry the `DrawOp`, which makes it usable from `RecordingCanvas` in a
   test. This is the half of **F4** Vg supplies; it does not supply the
   refusable half, so Notcurses' `NCVISUAL_OPTION_NODEGRADE` remains the model
   there.
4. **Scope the dual resolved/semantic channel to the ops that have two
   consumers.** [Friction §6][friction] is not wrong that carrying `visual` and
   `slot` is a hedge — Vg hedges identically on `Cut_glyphs` — but Vg pays it on
   **one constructor out of five**. Under a `SumType` re-encoding (**F2**), the
   HTML interpreter's `slot` need only ride on the variants it actually
   re-resolves.
5. **Contradicts the flat-stream assumption inside F2.** F2 concludes "sum
   type, keeping the reified stream". Vg reifies a _tree_ and gets suspension,
   push/pop pairing and structural equality from it. `sparkles:ui`'s
   `buildDisplayList` already flattens `pushClip`/`popClip` into a stream; that
   is a real cost (the pairing is a convention the type does not enforce) and
   the proposal should state the choice rather than inherit it.
6. **F7 confirmed at the type level.** Make extent an input to painting rather
   than a query on the display list: the `renderable` triple is the shape to
   copy — surface size, view rectangle, scene — and it makes
   [friction §8][friction]'s scan-every-rect workaround unconstructible.
7. **Do not copy the prose-only contract on its own.** Vg's sections are
   excellent and entirely unchecked. `RecordingCanvas` already exists as the
   reference backend; a limitations section that is _generated from_, or at
   least diffed against, a recorded op-stream conformance run is strictly better
   than one maintained by hand.
8. **The `Gg` split is prior art for `sparkles:math`.** Vg depends on a
   geometry/colour library it does not own, and so does its SVG renderer. That
   arrangement is already ours; nothing here argues for changing it.

## Sources

- [`dbuenzli/vg`][rev] at `58ab81a9c25e47627838c8d973e9cc77efb3f08d` — the
  revision was pinned with `gh api repos/dbuenzli/vg/commits/master --jq .sha`,
  and every cited file was fetched from `raw.githubusercontent.com` at that SHA.
- [`src/vg.mli`][vgmli] — `Font`, `P`, `I`, `Vgr`, and the `Vgr.Private`
  renderer-author API (`Data.image`, `Data.glyph_run`, the guideline list,
  `warning`, `renderable`, `target`, `render`).
- [`src/vgr_svg.ml`][svgml] — a complete renderer: `state`, the `todo`/`cmd`
  worklist, `w_image`, the memo tables, `target`.
- [`src/vgr_svg.mli`][svgmli], [`src/pdf/vgr_pdf.mli`][pdfmli],
  [`src/htmlc/vgr_htmlc.mli`][htmlcmli], [`src/cairo/vgr_cairo.mli`][cairomli] —
  the four `Text rendering` and `Render warnings and limitations` sections.
- [`doc/tutorial.mld`][tutorial], [`doc/semantics.mld`][semantics],
  [`doc/index.mld`][indexmld] — the collage model, the infinite-image
  denotation, the coordinate convention.
- [`dbuenzli/gg`][gg] at `2c5e74370fb5415522249ac822d89a2e4094317d` — the
  companion geometry/colour library ([`src/gg.mli`][ggmli]).
- In-tree: [`canvas-seam-friction.md`][friction], [`canvas.d`][canvas],
  [`comparison.md`][comparison], [`slint.md`][slint].

<!-- References -->

[rev]: https://github.com/dbuenzli/vg/tree/58ab81a9c25e47627838c8d973e9cc77efb3f08d
[opam]: https://github.com/dbuenzli/vg/blob/58ab81a9c25e47627838c8d973e9cc77efb3f08d/opam
[vgmli]: https://github.com/dbuenzli/vg/blob/58ab81a9c25e47627838c8d973e9cc77efb3f08d/src/vg.mli
[svgml]: https://github.com/dbuenzli/vg/blob/58ab81a9c25e47627838c8d973e9cc77efb3f08d/src/vgr_svg.ml
[svgmli]: https://github.com/dbuenzli/vg/blob/58ab81a9c25e47627838c8d973e9cc77efb3f08d/src/vgr_svg.mli
[pdfmli]: https://github.com/dbuenzli/vg/blob/58ab81a9c25e47627838c8d973e9cc77efb3f08d/src/pdf/vgr_pdf.mli
[htmlcmli]: https://github.com/dbuenzli/vg/blob/58ab81a9c25e47627838c8d973e9cc77efb3f08d/src/htmlc/vgr_htmlc.mli
[cairomli]: https://github.com/dbuenzli/vg/blob/58ab81a9c25e47627838c8d973e9cc77efb3f08d/src/cairo/vgr_cairo.mli
[tutorial]: https://github.com/dbuenzli/vg/blob/58ab81a9c25e47627838c8d973e9cc77efb3f08d/doc/tutorial.mld
[semantics]: https://github.com/dbuenzli/vg/blob/58ab81a9c25e47627838c8d973e9cc77efb3f08d/doc/semantics.mld
[indexmld]: https://github.com/dbuenzli/vg/blob/58ab81a9c25e47627838c8d973e9cc77efb3f08d/doc/index.mld
[gg]: https://github.com/dbuenzli/gg/tree/2c5e74370fb5415522249ac822d89a2e4094317d
[ggmli]: https://github.com/dbuenzli/gg/blob/2c5e74370fb5415522249ac822d89a2e4094317d/src/gg.mli
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[comparison]: ./comparison.md
[slint]: ./slint.md
