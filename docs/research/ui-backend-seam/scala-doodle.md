# Doodle — the seam is a set of type classes, and the call site declares what it needs

**Category:** tagless-final algebra as the seam. **Last reviewed:** August 23, 2026.
Pinned at [`423db025`][rev].

Doodle is a Scala vector-graphics library whose renderer seam is not one
interface but **eleven independent traits**, each naming one capability, and
whose pictures are typed by the _subset_ they use. A drawing that calls `text`
has `Text` in its type; a backend that cannot render text simply has no `Text`
in its algebra type, and the two fail to meet **at compile time, at the call
site** — before any backend has been asked to degrade anything.

| Field            | Value                                                                                                         |
| ---------------- | ------------------------------------------------------------------------------------------------------------- |
| Language         | Scala 3 (`crossScalaVersions := List(scala3)` in [`build.sbt`][build])                                        |
| License          | Apache-2.0 ([`LICENSE.txt`][license])                                                                         |
| Repository       | [`creativescala/doodle`][repo]                                                                                |
| Documentation    | [creativescala.github.io/doodle][site]                                                                        |
| Category         | tagless-final algebra as the seam                                                                             |
| Pinned revision  | `423db0255f7a3d796adbbea7aee6ea5bb40c2b72` (2026-08-05)                                                       |
| Target range     | JVM desktop (Swing/Java2D) and browser (HTML canvas, SVG DOM), plus an SVG file writer on the JVM             |
| Backends shipped | [`java2d`][java2d-pkg], [`canvas`][canvas-pkg], [`svg`][svg-base] (JS DOM + JVM writer)                       |
| Seam declaration | [`doodle.algebra.Algebra`][alg] + one trait per capability in [`algebra/shared/.../doodle/algebra/`][alg-dir] |

## Overview

### What it solves

Doodle composes pictures as values and renders them later — "the description is
a 'program' and a backend is an 'interpreter' that runs that program"
([`principles.md`][principles]). The interesting part for this survey is the
second design principle, which is stated as a goal rather than discovered as a
constraint:

> Another core goal of Doodle is to support the different capabilities of
> different backends. The alternative is to work only with the features that
> are found across all backends. In fact earlier versions of Doodle did this
> but we found it too limiting. […] The implication of this is that the core of
> Doodle is built in "tagless final" style, which means the core functionality
> is split across a number of interfaces or algebras. Backends only have to
> implement the subset of algebras that they support.
>
> — [`docs/src/pages/concepts/principles.md`][principles]

That is the whole subject in one paragraph: **the least-common-denominator seam
was tried, abandoned, and replaced with a decomposed one.** `isCanvas` is a
least-common-denominator seam with four optional primitives probed at the call
sites that want them.

### Design philosophy

A capability is a trait extending the marker [`Algebra`][alg], which contributes
nothing but an abstract effect type:

```scala
trait Algebra {
  /** The effect type that methods on this algebra produce. */
  type Drawing[_]
  implicit val drawingInstance: Monad[Drawing]
}
```

Every capability trait is written against that abstract `Drawing`, so it names
operations (`Shape` declares `rectangle`, `square`, `triangle`, `circle`,
`empty`, all returning `Drawing[Unit]`) without committing to a representation.
The shipped set is [`Layout`][layout], [`Shape`][shape], [`Path`][path],
[`Text`][text], [`Style`][style], [`Size`][size], [`Transform`][transform],
[`Debug`][debug], [`Bitmap`][bitmap], [`Blend`][blend] and [`Filter`][filter],
plus the type-parameterised [`LoadBitmap`][loadbitmap] and
[`ToPicture`][topicture]. [`Basic`][basic] is a **named intersection**, not a
super-interface:

```scala
trait Basic
    extends Algebra with Debug with Layout with Path
    with Shape with Size with Style with Text with Transform
```

Note what `Basic` omits: `Bitmap`, `Blend` and `Filter` are outside the common
language on purpose.

## How it works

### A picture is a function from an algebra

```scala
trait Picture[-Alg <: Algebra, A] { self =>
  def apply(implicit algebra: Alg): algebra.Drawing[A]
  …
}
```

`Alg` is **contravariant**: a `Picture` requiring less is usable where more is
supplied. The requirement set is not declared up front — it _accumulates_ as the
picture is built, because each syntax method widens the type it returns:

```scala
// doodle/syntax/TextSyntax.scala
def font(font: Font): Picture[Alg with Text, A]

// doodle/syntax/SizeSyntax.scala
def boundingBox: Picture[Alg with Size, BoundingBox]
def width: Picture[Alg with Size, Double]
```

So `Picture.circle(100).fillColor(red)` is a `Picture[Shape with Style, Unit]`
and calling `.font(…)` on it produces a `Picture[Shape with Style with Text, Unit]`.
The smallest requirement in the tree is one algebra:
[`ToPicture`][topicture] gives `ToPicture[OpenPath, Path]`, producing a
`Picture[Path, Unit]` — a picture that will render on any backend that can draw
a path and nothing else.

### The renderer type class closes the loop

```scala
trait Renderer[+Alg <: Algebra, Frame, Canvas] {
  def canvas(description: Frame): Resource[IO, Canvas]
  def render[A](canvas: Canvas)(picture: Picture[Alg, A]): IO[A]
}
```

`Renderer` is **covariant** in `Alg`, and [`draw`][rendersyntax] takes one as an
implicit parameter (`renderer: Renderer[Alg, Frame, Canvas]`, alongside a
`DefaultFrame[Frame]` and an `IORuntime`). A backend publishes exactly one such
instance, keyed by the intersection type it actually implements —
[`java2d`][java2d-pkg]:

```scala
type Algebra =
  doodle.algebra.Algebra with Basic with Bitmap
    with FromBufferedImage with FromPngBase64
    with FromGifBase64 with FromJpgBase64

implicit val java2dRenderer: Renderer[Algebra, Frame, Canvas] = …
```

Implicit search for `Renderer[Alg, _, _]` succeeds iff the backend's algebra
type conforms to the picture's requirement. **The capability check is implicit
resolution.** There is no `hasFeature`, no probe, and no runtime negotiation.

### Two seams, not one

The user-facing algebra is not what a backend implements. Between them sit the
`Generic*` mixins, which implement the algebra's _layout_ once and leave a much
smaller, fully-resolved API for the backend — [`GenericShape`][genericshape]:

```scala
trait ShapeApi {
  def rectangle(tx: Tx, fill: Option[Fill], stroke: Option[Stroke],
                width: Double, height: Double): G[Unit]
  def triangle(…): G[Unit]   // same resolved signature
  def circle(tx: Tx, fill: Option[Fill], stroke: Option[Stroke],
             diameter: Double): G[Unit]
  def unit: G[Unit]
}
```

`GenericShape.rectangle` computes the bounding box (widening it by
`dc.strokeWidth`) and defers only the painting to `ShapeApi`. So the **outer
seam is semantic and wide**, and the **inner seam is resolved and narrow** —
the split is the mechanism by which "one algebra, many backends" does not cost
each backend a re-implementation of layout.

### The `Drawing` representation is the backend's to choose

Because `Drawing[_]` is an abstract type member, the three shipped backends pick
three genuinely different shapes for the same seam:

| Backend  | `Drawing[A]` is …                                                                             | Shape                                              |
| -------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `java2d` | `Finalized[Reification, A]`, `Reification[A] = WriterT[Eval, List[Reified], A]`               | a reified **linear IR** ([`Reified`][reified])     |
| `canvas` | `Finalized[CanvasDrawing, A]`, `opaque type CanvasDrawing[A] = CanvasRenderingContext2D => A` | an **immediate-mode closure**                      |
| `svg`    | `Finalized[SvgResult, A]`, `type SvgResult[A] = (Tag, mutable.Set[Tag], A)`                   | a **retained DOM tree** ([`Base.scala`][svg-base]) |

Nothing in `Picture`, `Algebra` or `Renderer` fixes any of that. A reified
command stream exists in exactly one backend, as its private business.

## Q1 — measurement units, and who answers

**The strongest evidence in the survey for a backend-owned measurement type,
because Doodle's two main backends genuinely disagree.**
[`GenericText`][generictext] states the problem in a comment and then gives the
API an abstract type member for the answer:

> Text layout is complicated. Doodle's layout only cares about the bounding box
> […]. However, when we come to actually render the text we usually want
> additional information. […] This is difficult to calculate just from the
> Doodle bounding box, so we allow methods to return an additional piece of
> information that can be used to layout the text.
>
> — [`GenericText.scala`][generictext]

```scala
trait TextApi {
  type Bounds
  def text(tx: Tx, fill: Option[Fill], stroke: Option[Stroke],
           font: Font, text: String, bounds: Bounds): G[Unit]
  def textBoundingBox(text: String, font: Font): (BoundingBox, Bounds)
}
```

`textBoundingBox` returns a **pair**: a `BoundingBox` in the toolkit's own
continuous units, which layout consumes, _and_ a `Bounds` of the backend's own
type, which the toolkit never inspects and hands straight back to `text` at
paint time. The three implementations pick three unrelated types:

| Backend     | `type Bounds` | Measured by                                                                         |
| ----------- | ------------- | ----------------------------------------------------------------------------------- |
| `java2d`    | `Rectangle2D` | `FontMetrics.getStringBounds` via [`Java2D.textBounds`][java2d-util]                |
| `canvas`    | `TextMetrics` | the DOM's `measureText`, in CSS pixels ([`CanvasAlgebra`][canvas-alg])              |
| `svg` (JS)  | `Rect`        | SVG `getBBox` ([`svg/js/.../Text.scala`][svgjstext])                                |
| `svg` (JVM) | `Rectangle2D` | AWT `FontMetrics` — [`JvmAlgebra`][svgjvmalg] extends `JPanel` solely to obtain one |

Each backend then uses fields the others do not have: the canvas backend centres
the run with `actualBoundingBoxLeft`/`Right` and `actualBoundingBoxAscent`/
`Descent`, while the SVG backends use `getMinX`/`getMinY` plus
`dominantBaseline := "middle"` — "Otherwise we don't know how far the baseline
is offset from the bounding box we're given"
([`svg/js/.../Text.scala`][svgjstext]).

Three consequences bear directly on [friction §1][friction]:

1. **The shared unit is a `BoundingBox` of `Double`s, not a device unit and not
   a cell.** Layout is expressed in a neutral continuous unit; nobody converts.
2. **The backend's real measurement result is a value in the backend's own type
   that survives to paint time.** Doodle does not force the measurer to
   round-trip its answer through the framework's vocabulary and re-derive it —
   which is precisely what `SkiaCanvas.measure` returning `Size` in cells forces.
3. **The SVG-JVM backend measures with a _proxy_** — AWT metrics for text that a
   browser will eventually lay out. That is an honest approximation, made
   visible by the fact that it had to name a measurement source at all.

> [!IMPORTANT]
> `Size` is an algebra, but text metrics are **not** on it. [`Size`][size]
> answers "how big is this picture" from the layout's bounding boxes; the font
> question lives in `TextApi`, one layer below the algebra and invisible to
> users. Doodle separates _scene extent_ from _text measurement_ — two things
> `isCanvas` conflates by putting `measure` beside `fillRect`.

## Q2 — is the contract stated in one place?

**Stated, exhaustively, in the type — and this is the sharpest answer in the
survey.** The contract is not "one trait plus optional methods discovered by
probing"; it is a _set_ of traits, and a backend's supported set is a type:

| Algebra                   | `java2d` | `canvas` | `svg` |
| ------------------------- | -------- | -------- | ----- |
| `Basic` (8 algebras)      | yes      | yes      | yes   |
| `Bitmap` (`java.io.File`) | yes      | no       | no    |
| `Blend`                   | no       | yes      | yes   |
| `Filter`                  | no       | no       | yes   |

`Bitmap` takes a `java.io.File` and is unimplementable in a browser;
[`Filter`][filter] is a convolution algebra (`gaussianBlur`, `convolveMatrix`,
`dropShadow`) that only SVG's filter primitives support. The consequence is
mechanical: a picture that calls `.gaussianBlur` has `Filter` in its type, no
`Renderer[…Filter…, _, _]` exists for Java2D, and `draw()` does not compile.

Three properties follow, and they map onto [F5][comparison] almost point by point:

- **The floor is a named type.** `Basic` is the set every backend implements;
  everything above it is negotiated by implicit search rather than by
  convention. `sparkles:ui` has no such name — `isCanvas` names five methods,
  and the four optional primitives above them (`rule`, `scrollbar`, `pushClip`,
  `popClip`) are discovered by `__traits(compiles)` at each call site in
  `interp/immediate.d` ([friction §2][friction]).
- **Degradation is refusable by construction, because it does not exist.** F5's
  ladder tops out at a refusable method — a way to "ask for a hairline and be
  told no". Doodle's answer is stronger and cheaper: an unsupported capability
  is a **compile error at the call site that asked for it**, naming the
  operation, before a surface is allocated. Nobody silently paints a fallback.
- **The check is at the call site, not at backend registration.** Because `Alg`
  accumulates through the syntax, the requirement is derived from the drawing
  rather than declared by hand. There is no capability list to keep in sync
  with the code, which is the failure mode Qt's `PaintEngineFeature` has.

> [!NOTE]
> Doodle also carries a **second** capability axis for payload types:
> `LoadBitmap[Specifier, Bitmap]` is "parameterized by […] the type used to
> specify where to find a bitmap (e.g. File on JVM, String URL on JS)" and the
> resulting bitmap type ([`LoadBitmap.scala`][loadbitmap]). So "can this backend
> load an image" is answered per _source type_, not per backend, and the
> documentation says so plainly: "This support is very dependent on the backend"
> ([`pictures/bitmap.md`][bitmapdoc]).

## Q3 — semantic operations, or primitives?

**Both, in separate algebras, at different heights.** [`Shape`][shape] is
semantic (`circle`, `triangle`, `square`) and [`Path`][path] is primitive
(`ClosedPath`/`OpenPath` of `PathElement`s); a backend implements whichever it
can serve well. The SVG backend maps `rectangle` to an SVG `rect` element and
`triangle` to a `path` — the semantic op survives where the target has a
matching concept and lowers where it does not, **inside the backend** — the
first of the six places [F4][comparison] enumerates for a lowering to live.

Two operations are more semantic still: [`Debug`][debug] draws "the bounding box
and origin of the given picture on top of the picture", a developer affordance
promoted to its own algebra; and [`Filter.dropShadow`][filter] is the box-shadow
case Slint puts in the renderer, here placed in an algebra no rasterising
backend implements.

There is no widget vocabulary at all — Doodle has no scrollbars, so it cannot
falsify [friction §3][friction] directly. What it does show is the _placement_
rule the friction log is groping for: when an operation is semantic **and**
some backends cannot serve it, it becomes its own algebra rather than another
member of the common one. `scrollbar` is already an optional primitive on our
side — probed, with a stated degradation to `paintScrollbarCells` — but it is
still one of the eight kinds the display list can hold, so its fourteen fields
are part of the drawing vocabulary. Under Doodle's rule it would be a separate
capability outright, and a backend that did not implement it would refuse the
drawing rather than degrade it.

## Q4 — command shape

**There is no command shape in the seam, and the one backend that reifies uses
a sealed sum type with a documented explanation of why.** `Reified` is Java2D's
private linear IR:

```scala
sealed abstract class Reified extends Product with Serializable {
  def transform: Tx
  def render[A](gc: A, finalTransform: Tx)(implicit ctx: GraphicsContext[A]): Unit = …
}
object Reified {
  final case class FillRect(transform: Tx, fill: Fill, width: Double, height: Double) extends Reified
  final case class StrokeRect(transform: Tx, stroke: Stroke, width: Double, height: Double) extends Reified
  final case class FillCircle(transform: Tx, fill: Fill, diameter: Double) extends Reified
  …
}
```

Each variant carries only its own fields — `FillCircle` has a `diameter` and no
`points`; `Text` has a `font` and a `bounds`. That is the encoding `DrawOp`
uses, arrived at independently: a closed sum whose arms are per-kind payloads,
so `Scrollbar`'s fourteen fields ride on the scrollbar arm and `PopClip` carries
none. [F3][comparison] holds the encoding open between exactly this and
variable-stride per-op storage; Doodle is a second vote for the closed sum.

The file's header comment is the most valuable paragraph this survey has found
on the tag-versus-sum question, because it argues both sides:

> Each instruction should be atomic: there should be _no_ nesting of
> instructions inside instructions. In compiler terms, this is a "linear IR",
> not a "tree IR". […] There are two implementation approaches:
>
> - Push all these operations into the atomic instructions. This is the approach
>   currently taken, with each element containing the transform, and fill or
>   stroke as appropriate. The advantage of this approach is that each reified
>   instruction is independent of any other. The disadvantage is that this
>   doesn't scale as the amount of context grows, as each instruction needs to
>   have additional fields added.
> - Have stateful operations to add and remove some context. […] This is the
>   approach taken in the `Graphics2D` Java API. […] (However, the API lacks
>   methods to undo these operations, which makes it a bit limited.)
>
> — [`Reified.scala`][reified]

`DrawOp` takes the first approach, and takes it the way Doodle does: every
operation carries its own geometry and its own resolved
appearance, and nothing is inherited from a preceding op, so a walker can start
anywhere in the stream. That independence is what makes the op stream a parity
oracle and `RecordingCanvas` a comparable value.

The bill Doodle names — "each instruction needs to have additional fields
added" — falls on the arm rather than on the stream, but it does not vanish. A
sum is as wide as its widest alternative, so the budget
`static assert(DrawOp.sizeof <= 64)` prices every operation at what a `TextRun`
costs, `PopClip` included ([friction §4][friction]). Doodle pays the same tax in
a heavier currency: `Reified` variants are boxed case classes, so the width is a
pointer and the cost is an allocation per instruction. The trade is the same
one, priced for a language with a GC.

## Q5 — sub-unit placement

**Does not arise.** Every coordinate is a `Double`:
`rectangle(width: Double, height: Double)`, `strokeWidth(width: Double)`,
`BoundingBox(left, top, right, bottom)` of `Double`, `Transform` as an affine
matrix. Screen mapping is a single transform computed per frame
([`Java2d.transform`][java2deffect]) from the picture's bounding box, the target
size and a `Center` policy. A hairline is `strokeWidth(1)`; a two-pixel focus
ring is `strokeWidth(2)`; there is no vocabulary to extend.

This is the third independent confirmation of [F6][comparison]: `RuleEdge`
([friction §5][friction]) is a symptom of integer cell coordinates, and a
continuous seam does not have to spell one. But Doodle also supplies F6's
caveat, because it is _only_ continuous and has no cell target: it never has to
land a hairline on a grid, so it is no evidence that going continuous dissolves
the sub-unit problem for a terminal-capable toolkit rather than moving it to the
snap policy.

## Q6 — resolved or semantic styling

**Resolved, exactly once, and carried by the command — no dual channel.**
[`DrawingContext`][drawingcontext] is the style state (`strokeStyle`,
`strokeWidth: Option[Double]`, `strokeCap`, `strokeJoin`, `strokeDash`,
`fill: Option[Fill]`, `font`, `blendMode`) and is folded through the tree before
any painting — [`Finalized.leaf`][finalized] applies the accumulated
`ContextTransform` list to `DrawingContext.default` and hands each leaf the
result.

Backends receive `Option[Fill]` and `Option[Stroke]` — already resolved, already
optional-if-absent — never a semantic role. `strokeWidth` is an `Option` with a
comment saying so: "We use strokeWidth to determine if there is a stroke or
not". Nothing re-resolves downstream, including the SVG backend, which emits a
CSS `style` string from the resolved `Fill`/`Stroke` rather than a class name.

So Doodle pays for one channel, like every other surveyed subject — which is
[F9][comparison] on one more subject. Our seam pays for both:
[friction §6][friction] is the resolved appearance a primitive paints from
_plus_ a `Slot`, on six of the eight payloads. The reason it exists is a
requirement Doodle deliberately does not have — an HTML interpreter that
re-resolves the role into class names, where Doodle's SVG backend emits the
resolved `Fill`/`Stroke` as an inline style string and never looks back.

The half of the hedge our seam does not pay for is the one Doodle's
`DrawingContext` also avoids: `Visual` is not a stored field. `DrawOp.visual`
reconstructs one through `visualOf`, lossy on purpose, from whichever fields the
payload's own primitive uses — a fill reports its box chrome, a run reports its
text chrome. That is the same economy as folding the context into each leaf
before painting: keep what the primitive reads, derive the rest. It makes the
dual channel cheaper without making it a decision.

## Q7 — payload ownership

**Values are immutable and garbage-collected, so the question is trivial — but
the interesting half is where a _backend-typed_ payload lives.** `Reified.Text`
carries `text: String`, `font: Font` and `bounds: Bounds`; `Reified.Bitmap`
carries a `BufferedImage`. All are ordinary heap references outliving the frame
for free.

The transferable observation is the `Bounds` channel described under Q1: an
expensive, backend-specific measurement result is computed once during layout
and **travels inside the backend's own command type** to paint time. This is
only possible because the command type is per-backend — a shared `DrawOp` could
not carry a `TextMetrics` for one backend and a `Rectangle2D` for another. It is
a further answer alongside the reference-counting, copying and arena allocation
[F8][comparison] enumerates: **let the backend's command type be the cache**.

Ours is the arena branch of that enumeration. `TextRun.text` is a
`const(char)[]` of sixteen bytes borrowed from a frame arena, and
`CmdBuffer.textRun` copies the run in on the way past, which is what makes a
`scope` source safe to draw from. What the arena cannot do is what `Bounds`
does: it holds bytes, not a backend-typed measurement, so a shaped run's metrics
have nowhere to ride to paint time.

> [!WARNING]
> Doodle cannot answer the cross-thread half of [friction §7][friction] on our
> terms. The Java2D backend explicitly crosses a threading boundary —
> `RenderRequest` is documented as the "Event that is passed into Java2DPanel to
> request rendering of a Picture. This crosses the boundary between the Cats
> Effect and Swing threading model" ([`RenderRequest.scala`][renderrequest]) —
> but the payloads are GC references, so nothing is proven about a slice whose
> lifetime rule is _valid while the buffer that built it is alive and unreset_.
> That rule is stated on the type and the buffer is move-only, so it is
> enforceable rather than advisory; it is still a borrow, and `UI-O4` stays open
> on exactly the retain-and-transfer question Doodle answers for free.

## Q8 — extent query

**Yes, twice, and one of them is an algebra.** Layout in Doodle is a two-phase
pipeline: `Finalized[F, A]` computes a `BoundingBox` for the whole tree
_before_ any `Renderable` runs, and exposes it directly:

```scala
final case class Finalized[F[_], A](f: Transforms => Eval[(BoundingBox, Renderable[F, A])]) {
  def boundingBox: BoundingBox = { val (bb, _) = run(List.empty).value; bb }
  …
}
```

The Java2D renderer uses that value to size its surface — the first of the three
questions [F7][comparison] separates, answered from the scene rather than from
the device:

```scala
// java2d/effect/RenderRequest.scala
val drawing: Finalized[Reification, A] = picture(algebra)
val (bb, rdr) = drawing.run(List.empty).value
val (w, h) = Java2d.size(bb, frame.size)

// java2d/effect/Java2d.scala
def size(bb: BoundingBox, size: Size): (Double, Double) =
  size match {
    case Size.FitToImage(border) => (bb.width + border, bb.height + border)
    case Size.FixedSize(w, h)    => (w, h)
  }
```

`Size.FitToImage` is "size the surface to the content"; `Size.FixedSize` is
"the surface chose". Both are expressible because extent is available before
painting, and neither requires scanning the command stream — which is what
`skia-canvas-render.d` does, folding `op.rect` across every operation, because
nothing on `CmdBuffer`, the display list or the arena reports the extent of a
built stream ([friction §8][friction]).

Separately, the user-facing [`Size`][size] algebra exposes `width`, `height`,
`size` and `boundingBox` as _drawing operations returning values_
(`Drawing[Double]`, `Drawing[BoundingBox]`), implemented by
[`GenericSize`][genericsize] as a read of the already-computed box. Asking is a
capability like any other: `.width` returns a `Picture[Alg with Size, Double]`.

This is [F7][comparison]'s axis at its cleanest. Doodle's extent is
**maintained at construction**: bounding boxes are computed by the layout phase
for its own reasons, and the root one is simply not thrown away, so the scene is
self-describing at no cost. Ours is **derived by scan**, and derived from the
wrong artifact — not from the layout that computed the rects, but from the
painted commands afterwards, which works only because a `TextRun`'s `rect.width`
happens to be its advance in cells. The transferable rule is the axis, not the
answer: a pipeline whose layout already knows the box should publish it, and
only a pipeline that has no layout should be scanning ops for it.

## Strengths

- **Capability is a type, checked where the drawing is written.** No probing, no
  registration table, no runtime negotiation, and no way for the declared
  contract to drift from the implemented one.
- **A named floor (`Basic`) with a genuinely open set above it.** Adding
  `Filter` cost the other two backends nothing — no stub, no "unsupported"
  branch, no default that silently does the wrong thing.
- **The measurement result is the backend's own type and survives to paint
  time**, so the best measurer in the system never has to launder its answer
  through a framework unit.
- **The representation of a drawing is backend-chosen** — linear IR, closure, or
  DOM tree — so a backend that wants a recordable stream can have one without
  imposing it on backends that do not.
- **The `Generic*` / `*Api` split** means the wide semantic seam does not cost
  each backend a re-implementation of layout.
- **Extent is a by-product of layout, published rather than recomputed.**

## Weaknesses

- **The capability check is all-or-nothing.** There is no "render this if you
  can, otherwise degrade" anywhere in the design. For a toolkit whose whole
  problem is a terminal that _must_ approximate a GPU drawing, refusal is not an
  available answer — Notcurses' fidelity ladder and Qt's emulation both solve a
  problem Doodle declines to have.
- **The seam's expressive power rests on structural intersection types and
  implicit resolution.** In D the nearest equivalents (template constraints over
  a set of concepts) exist but there is no `Alg with Text` accumulating through
  a fluent chain without an explicit type parameter at every step.
- **Layout is intrinsic to the framework, not to the backend.** `Finalized`
  fixes the bounding-box model; a backend cannot lay out differently, which is
  the price of the `Generic*` mixins doing the work once.
- **No cell target, so continuous coordinates are untested against our hard
  case**, and the "backends genuinely differ" claim is tested only across
  measurement, filters and bitmaps — not across the unit of geometry.
- **The compile-time story is a Scala-3-only, implicit-heavy design** whose
  failure mode is an implicit-not-found error naming a large intersection type.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                                  | Trade-off                                                                                                 |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| One trait per capability, not one renderer interface                | "Backends only have to implement the subset of algebras that they support" ([`principles.md`][principles]) | The set of capabilities becomes public API; adding one is a versioning event                              |
| `Picture[-Alg, A]` contravariant, requirement accumulated by syntax | The call site declares what it needs without anyone writing a list                                         | Types grow large and error messages name intersections                                                    |
| `Drawing[_]` abstract on the algebra                                | Backend picks linear IR / closure / DOM as suits it                                                        | No cross-backend command stream, so no shared recorder or op-stream parity harness                        |
| `TextApi.Bounds` an abstract type member                            | The backend's real metrics survive layout to paint time untranslated                                       | The framework can never inspect or compare measurements; two backends may lay out differently             |
| `Generic*` mixins implement layout, `*Api` is the painter seam      | Wide semantic algebra without per-backend layout cost                                                      | Layout policy is fixed by the framework; a backend cannot override it                                     |
| Styling resolved into `DrawingContext` before the backend sees it   | One channel; no re-resolution downstream                                                                   | A backend that wants semantic roles (CSS classes) cannot have them                                        |
| No degradation, ever — unsupported means "does not compile"         | The strongest possible capability guarantee, with zero runtime cost                                        | Unusable for targets that must approximate; forces per-backend source where one drawing would do          |
| Closed `Image` DSL shipped _alongside_ open `Picture`               | Beginners get one type; experts get backend-specific power                                                 | Two APIs to document; `Image` is capped at `Basic` and "not available on `Image`" is a recurring doc line |

## Bearing on the proposal

1. **Q2 has an answer better than a declared feature bitmask: make the
   capability set a set of concepts, and let the requirement be derived from the
   drawing.** [Friction §2][friction] says `isCanvas` describes five methods
   while the real contract is eight. Doodle's structure suggests splitting
   `isCanvas` into `isCanvas` (the floor: fills, text runs, glyphs, lines,
   measurement) plus `hasClip`, `hasRule`, `hasScrollbar` — named concepts a
   backend either satisfies or does not, and which a _display-list builder_ can
   be constrained on. The probing already happens; this gives it a name and a
   single home, and it costs nothing D does not already do.
2. **A named floor is the cheap half of [F5][comparison], and Doodle confirms it
   is the half that matters.** `Basic` is one line of code and does most of the
   work of a capability system.
3. **`measure` should return a backend-chosen type, not just live elsewhere.**
   [F1][comparison] concluded measurement does not belong on the painter.
   Doodle sharpens this: the measurement _result_ should be an opaque
   backend-owned value that the toolkit stores and hands back at paint time,
   alongside a neutral extent for layout. That is a stronger design than moving
   `measure` to a font object that still answers in cells, and it is what
   `SkiaCanvas` would need in order to use shaping at all
   ([friction §1][friction]).
4. **The reified stream and the closed sum are the right pair, and Doodle's
   `Reified` comment is the argument for keeping them together.** It names the
   cost we carry ("doesn't scale as the amount of context grows, as each
   instruction needs to have additional fields added") while defending the
   property we depend on (each instruction independent of any other). That is
   why the residual complaint in [friction §4][friction] is a stride, not a
   design: a `PopClip` costs what a `TextRun` costs. [F3][comparison] keeps the
   encoding open between a closed sum and variable-stride storage, and Doodle is
   the primary source that reasoned about the trade rather than just picking a
   side.
5. **Confirms [F7][comparison], and names which artifact should answer.**
   `Finalized` publishes the scene's bounding box before painting because layout
   computed it anyway, and `Size.FitToImage` uses it to size a surface to
   content — extent maintained at construction. Our layout also computes rects;
   [friction §8][friction]'s defect is that `buildDisplayList` keeps none of
   them, so the number has to be recovered by scanning painted ops. Publishing
   one rect from layout is cheaper than either the scan or a query API bolted to
   the seam.
6. **Sharpens [F4][comparison]:** the useful axis is not only _where the
   lowering lives_ but _whether the operation belongs to the common seam at
   all_. Doodle's rule — an operation that some backends cannot serve becomes
   its own capability rather than another member of the common one — would move
   `scrollbar` and `rule` out of the eight kinds and into named optional
   concepts. That fixes [friction §3][friction] outright and takes `Scrollbar`'s
   fourteen fields out of the drawing vocabulary; it leaves
   [friction §4][friction] untouched, since `TextRun` sets the stride either
   way.
7. **Reject the all-or-nothing part.** A terminal backend must approximate, not
   refuse. Doodle's compile-time refusal works because both its targets are
   pixel targets and the differing capabilities are luxuries (filters, blends,
   file bitmaps). Ours differ on necessities. The design to copy is the
   _decomposition_; the policy to keep is Notcurses' fidelity ladder.
8. **The `Image` versus `Picture` split is a warning about the open question.**
   Doodle shipped a closed sum-type DSL ([`Image`][image], compiled to
   `Picture[Alg, Unit]` requiring `Basic`) beside the open algebra, and its own
   documentation repeatedly notes what the closed one cannot reach: "It allows
   access to platform specific features not available on `Image`"
   ([`picture-image.md`][pictureimage]); "This functionality is backend specific
   and is not available on `Image`" ([`pictures/bitmap.md`][bitmapdoc]). A
   single closed `DrawOp` union is structurally the `Image` half of that pair.
   If `sparkles:ui` keeps one seam for terminal and GPU, it should expect the
   same recurring sentence — and should decide deliberately whether the GPU
   backend is allowed capabilities the union cannot name.

## Sources

- The seam: [`Algebra`][alg], [`Picture`][picture], [`Renderer`][renderer],
  [`AbstractRendererSyntax`][rendersyntax], and the named floor [`Basic`][basic].
- Capability traits: [`Layout`][layout], [`Shape`][shape], [`Path`][path],
  [`Text`][text], [`Style`][style], [`Size`][size], [`Debug`][debug],
  [`Bitmap`][bitmap], [`Blend`][blend], [`Filter`][filter],
  [`LoadBitmap`][loadbitmap], [`ToPicture`][topicture]; requirement accumulation
  in [`TextSyntax`][textsyntax] and [`SizeSyntax`][sizesyntax].
- The inner seam and layout phase: [`GenericText`][generictext],
  [`GenericShape`][genericshape], [`GenericSize`][genericsize],
  [`DrawingContext`][drawingcontext], [`Finalized`][finalized].
- Backends: [`Java2dPackage`][java2d-pkg], [`Java2D`][java2d-util],
  [`Reified`][reified], [`ReifiedText`][reifiedtext], [`Java2d`][java2deffect],
  [`effect/Size`][java2dsize], [`RenderRequest`][renderrequest];
  [`canvas/package`][canvas-pkg], [`CanvasAlgebra`][canvas-alg],
  [`canvas/algebra/Text`][canvastext], [`TextMetrics`][canvasmetrics];
  [`svg/Base`][svg-base], [`svg/BaseAlgebra`][svgbasealg],
  [`svg/js/Text`][svgjstext], [`svg/jvm/Algebra`][svgjvmalg];
  the closed [`Image`][image] DSL.
- In-tree documentation: [`concepts/principles.md`][principles],
  [`concepts/algebras.md`][algebrasdoc],
  [`concepts/drawing-picture.md`][drawingpicture],
  [`development/backend.md`][backenddoc],
  [`pictures/picture-image.md`][pictureimage],
  [`pictures/bitmap.md`][bitmapdoc].
- Revision pinned with `git rev-parse HEAD` on a clone of
  [`creativescala/doodle`][repo], cross-checked against
  `gh api repos/creativescala/doodle/commits/main`; every cited path verified
  with `git cat-file -e` against that SHA.

<!-- References -->

[rev]: https://github.com/creativescala/doodle/tree/423db0255f7a3d796adbbea7aee6ea5bb40c2b72
[repo]: https://github.com/creativescala/doodle
[site]: https://creativescala.github.io/doodle/
[license]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/LICENSE.txt
[build]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/build.sbt
[alg]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Algebra.scala
[alg-dir]: https://github.com/creativescala/doodle/tree/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra
[picture]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Picture.scala
[layout]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Layout.scala
[shape]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Shape.scala
[path]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Path.scala
[text]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Text.scala
[style]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Style.scala
[size]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Size.scala
[debug]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Debug.scala
[bitmap]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Bitmap.scala
[blend]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Blend.scala
[filter]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Filter.scala
[transform]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/Transform.scala
[loadbitmap]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/LoadBitmap.scala
[topicture]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/ToPicture.scala
[basic]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/language/Basic.scala
[renderer]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/effect/Renderer.scala
[rendersyntax]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/syntax/AbstractRendererSyntax.scala
[textsyntax]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/syntax/TextSyntax.scala
[sizesyntax]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/syntax/SizeSyntax.scala
[generictext]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/generic/GenericText.scala
[genericshape]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/generic/GenericShape.scala
[genericsize]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/generic/GenericSize.scala
[drawingcontext]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/generic/DrawingContext.scala
[finalized]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/algebra/shared/src/main/scala/doodle/algebra/generic/Finalized.scala
[java2d-pkg]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/java2d/src/main/scala/doodle/java2d/Java2dPackage.scala
[java2d-util]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/java2d/src/main/scala/doodle/java2d/algebra/Java2D.scala
[reified]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/java2d/src/main/scala/doodle/java2d/algebra/reified/Reified.scala
[reifiedtext]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/java2d/src/main/scala/doodle/java2d/algebra/reified/ReifiedText.scala
[java2deffect]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/java2d/src/main/scala/doodle/java2d/effect/Java2d.scala
[java2dsize]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/java2d/src/main/scala/doodle/java2d/effect/Size.scala
[renderrequest]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/java2d/src/main/scala/doodle/java2d/effect/RenderRequest.scala
[canvas-pkg]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/canvas/src/main/scala/doodle/canvas/package.scala
[canvas-alg]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/canvas/src/main/scala/doodle/canvas/algebra/CanvasAlgebra.scala
[canvastext]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/canvas/src/main/scala/doodle/canvas/algebra/Text.scala
[canvasmetrics]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/canvas/src/main/scala/doodle/canvas/algebra/TextMetrics.scala
[svg-base]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/svg/shared/src/main/scala/doodle/svg/Base.scala
[svgbasealg]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/svg/shared/src/main/scala/doodle/svg/algebra/BaseAlgebra.scala
[svgjstext]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/svg/js/src/main/scala/doodle/svg/algebra/Text.scala
[svgjvmalg]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/svg/jvm/src/main/scala/doodle/svg/algebra/Algebra.scala
[image]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/image/shared/src/main/scala/doodle/image/Image.scala
[principles]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/docs/src/pages/concepts/principles.md
[algebrasdoc]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/docs/src/pages/concepts/algebras.md
[drawingpicture]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/docs/src/pages/concepts/drawing-picture.md
[backenddoc]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/docs/src/pages/development/backend.md
[pictureimage]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/docs/src/pages/pictures/picture-image.md
[bitmapdoc]: https://github.com/creativescala/doodle/blob/423db0255f7a3d796adbbea7aee6ea5bb40c2b72/docs/src/pages/pictures/bitmap.md
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[comparison]: ./comparison.md
