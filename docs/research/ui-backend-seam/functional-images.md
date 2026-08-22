# Functional images (Henderson, Pan, Elliott) — the seam removed rather than designed

**Category:** the theoretical extreme. **Last reviewed:** August 23, 2026.

Two papers, forty years apart, that answer the survey's question by refusing its
premise: a picture is a **function**, so there is no backend contract to state,
no command to shape, and no unit to argue about. Henderson's [_Functional
Geometry_][fg2] makes a picture a function of the box it is drawn into; Elliott's
[_Functional Images_][fi] makes an image a function of a point. Read together
they mark the limit the rest of the survey is measured against — and they
localise, precisely, which of Q1–Q8 are _dissolved_ and which are merely
_deferred to an unwritten renderer_.

| Field                | Value                                                                                                                                                                                                                         |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**         | Pure functional pseudocode (Henderson); Haskell as a DSEL (Elliott's `Pan`)                                                                                                                                                   |
| **License**          | Academic papers; the `Pan` compiler was distributed as a free download — no license statement found                                                                                                                           |
| **Repository**       | None. `Pan` was distributed from [the Pan home page][pan]; the chapter notes it "requires having the Microsoft C++ compiler"                                                                                                  |
| **Documentation**    | [_Functional Geometry_ (2002 revision)][fg2]; [_Functional Images_ chapter page][fip]                                                                                                                                         |
| **Pinned revision**  | Publications, not commits: Henderson 1982 ([`10.1145/800068.802148`][fg82]) and its 2002 revision ([`10.1023/A:1022986521797`][fg2doi], PDF `funcgeo2.tex; 16/10/2002; 13:53`); Elliott, _The Fun of Programming_ ch. 7, 2003 |
| **Target range**     | None — the papers name no device. Henderson mentions "a printer or a screen"; `Pan` compiled to C                                                                                                                             |
| **Backends shipped** | Henderson: "the implementation used to create the pictures in this paper", unnamed, drawing beziers. `Pan`: one compiler backend emitting C                                                                                   |

> [!NOTE]
> Everything below is cited to the two PDFs and to `conal.net`. `dl.acm.org`
> refuses the link checker (HTTP 403), so the 1982 paper is cited through a
> verified Wayback snapshot per the [research-doc guidelines][guidelines].

## Overview

### What it solves

Henderson's target is the gap between _what a picture is_ and _the sequence of
commands a device wants_ — which is the survey's gap, named in 1982:

> A picture is an example of a complex object that can be described in terms of
> its parts. Yet a picture needs to be rendered on a printer or a screen by a
> device that expects to be given a sequence of commands. Programming that
> sequence of commands directly is much harder than having an application
> generate the commands automatically from the simpler, denotational
> description. ([`funcgeo2.pdf`][fg2], §1)

Elliott's target is narrower and more radical — not a fixed set of primitives at
all.

> There have been many libraries for generating images using functional
> programming, each based on its own fixed set of geometric primitives and
> combinators. In contrast, this chapter addresses the general notion of images,
> based on a very simple model: functions over continuous 2D space. ([chapter
> abstract][fip])

### Design philosophy

Henderson: abstract away size and position, and let the renderer recover them.

> The key conceptual idea behind Functional Geometry is that we have abstracted
> completely from size and absolute location. Each picture is described in terms
> of subpictures and their relative locations. The implementation, on rendering
> the picture, must work out from this description, the exact size and the exact
> location of each part of the picture. ([`funcgeo2.pdf`][fg2], §5)

Elliott: shift the paradigm "from _doing_ to _being_" ([_Functional Image
Synthesis_ abstract][bridges]), where an image's essential nature is not
"muddled with details of how to display it on a computer".

## How it works

### Henderson: a picture is a function of its locating box

The seam's defining declaration is one sentence of prose plus five equations.

> Let us define a picture as a function which takes three arguments, each being
> two-space vectors and returns a set of graphical objects to be rendered on the
> output device. … The picture `p(a,b,c)` will be drawn in a box bounded by `b`
> and `c`, with its bottom left-hand corner at position `a`.
> ([`funcgeo2.pdf`][fg2], §5)

```text
Picture = (Vector, Vector, Vector) -> Set GraphicalObject

blank        (a, b, c) = {}
over  (p, q) (a, b, c) = p(a, b, c) ∪ q(a, b, c)
beside(p, q) (a, b, c) = p(a, b/2, c) ∪ q(a + b/2, b/2, c)
above (p, q) (a, b, c) = p(a, b, c/2) ∪ q(a + c/2, b, c/2)
rot   (p)    (a, b, c) = p(a + b, c, b)
flip  (p)    (a, b, c) = p(a + b, b, c)
```

`a` is the origin corner, `b` and `c` the two edge vectors — a **bounding
parallelogram**, not a rectangle, which is why `rot45` can shear the frame and
still be a picture. The vocabulary the paper builds on is `above`, `beside`,
`over`, `rot`, `flip` and the Escher-specific `rot45`; the composite operators
(`quartet`, `cycle`, `nonet`) are defined from those.

Two properties fall out that no other subject here has. First, the combinators
obey **laws**, and the paper treats law quality as a design metric:

```text
rot(rot(rot(rot(p))))  = p
rot(above(p, q))       = beside(rot(p), rot(q))
rot(beside(p, q))      = above(rot(q), rot(p))
flip(beside(p, q))     = beside(flip(q), flip(p))
```

> It seems there is a positive correlation between the simplicity of the rules
> and the quality of the algebra as a description tool.
> ([`funcgeo2.pdf`][fg2], §6)

Second, the paper applies that metric to its own worst operation and convicts
it — `rot45` rotates about the top-left corner and shrinks by `√2`, so
`rot45(rot45(p)) ≠ rot(p)`:

> This analysis suggests that `rot45` is not the kind of operation we would
> include in a general algebraic language for geometry. Rather, we would define
> more fundamental operations for scaling, rotation and translation and allow
> the user to define `rot45` for this specific application.
> ([`funcgeo2.pdf`][fg2], §6)

### Elliott: an image is a function of a point

```haskell
type Point   = (Float, Float)
type Image α = Point -> α          -- 'Image = Point -> Colour' specialised
type Region  = Image Bool          -- characteristic function of a point set
type ImageC  = Image Colour
type Colour  = (Frac, Frac, Frac, Frac)   -- BGRA, premultiplied
```

> `Pan`'s model of images is simply functions from infinite, continuous 2D space
> to colours with partial opacity. (Although the domain space is infinite, some
> images are transparent everywhere outside of a bounding region.)
> ([`fop-conal.pdf`][fi], §7.2)

Every operation is either **pointwise lifting** or **domain composition**:

```haskell
lift2 h f1 f2 p = h (f1 p) (f2 p)
over            = lift2 overC              -- layering
cond            = lift3 (\a b c -> if a then b else c)
crop reg im     = cond reg im empty        -- clipping is a Boolean image

type Transform = Point -> Point
type Filter α  = Image α -> Image α
translate (dx, dy) im = im . translateP (-dx, -dy)
swirl r im            = im . swirlP (-r)
```

Clipping is not a stack operation but `cond` against a `Region`; layering is not
a painter's-algorithm ordering but `overC` under `lift2`; a spatial transform is
not a matrix but **the inverse point mapping pre-composed** with the image —
"we simply construct the transforms in inverted form" ([`fop-conal.pdf`][fi],
§7.5). Sampled data enters the same way: a bitmap becomes a subscripting
function, reconstructed by bilinear interpolation into an image of infinite
extent.

```haskell
data Array2 α = Array2 Int Int ((Int, Int) -> α)

reconstruct (Array2 w h sub) =
  move (-fromInt w / 2, -fromInt h / 2)
       (crop (inBounds w h) (bilerpArray2 sub))
```

> Rather than creating and storing an actual array of colours, each represented
> as a quadruple of floating point numbers, conversion from the file
> representation … is done on-the-fly during 'subscripting'. The details depend
> on the particular format. This flexibility is exactly why we chose to use
> subscripting functions rather than a more concrete representation.
> ([`fop-conal.pdf`][fi], §7.10)

## Q1 — measurement units, and who answers

**Dissolved for geometry; unanswered for text — and the second half is the
finding.**

Henderson has no measurement because a picture has no size to measure: size is
an _argument_ (`b`, `c`) supplied at render time, and the same picture value
drawn into a different parallelogram is a different set of graphical objects.
`Pan` has no measurement because nothing has extent at all — an image is total
over infinite continuous space, and the paper's figures are captioned with the
_window_ chosen by the author ("Each figure shows an origin-centred finite
window onto an infinite image and is annotated with the width of the window in
logical coordinates", [`fop-conal.pdf`][fi], footnote 3).

Neither renders text. Henderson's basic picture is "about 30 bezier curves"
([`funcgeo2.pdf`][fg2], §5); `Pan`'s primitives are arithmetic on coordinates.
Elliott names text as something a _model_ layer presents "via outline fonts"
(§7.1) and then leaves that layer out of scope. So the model is silent on
shaping, kerning, fallback and grapheme advance — the entire content of
[friction §1](../../specs/ui-skia/canvas-seam-friction.md).

> [!IMPORTANT]
> This bounds how far [F1 in `comparison.md`](./comparison.md)
> generalises. F1 says measurement does not belong on the painter. These two
> subjects appear to say something stronger — that measurement need not exist —
> but they only get there by not rendering text. They are evidence for F1's
> _placement_ claim (measurement is not a painter operation) and no evidence at
> all for eliminating it.

## Q2 — capability declaration

**Dissolved, and expensively.** The contract is a type, stated once:
`Picture = (Vector,Vector,Vector) -> Set GraphicalObject` and
`Image α = Point -> α`. There are no optional methods to probe, no
`__traits(compiles)` at a call site, no `PaintEngineFeature` bitmask — a total
function either typechecks or does not.

The price is that there is **nothing to declare and nothing to degrade**. Qt's
emulation floor and Notcurses' `NCVISUAL_OPTION_NODEGRADE`
([F4](./comparison.md))
have no counterpart here, because a device that cannot draw what the function
denotes has no way to say so: the function has already produced its answer and
the renderer is downstream of it. Henderson has exactly one concession, and it
is a global cutoff rather than a capability:

> So the implementation will need to implement some rule such as
> `p(a,b,c) = {}`, if `|b+c| < ε`, where `ε` is some dimension considered too
> small to draw. ([`funcgeo2.pdf`][fg2], §5)

## Q3 — semantic operations, and where they live

**Both are primitive at the seam and semantic above it — the split `sparkles:ui`
has not made.** Henderson's renderer receives a set of line segments and beziers
and knows nothing of fish, quartets or Square Limit; the semantics live entirely
in the algebra, where they are named, composable and law-checked. `Pan`'s
renderer (such as it is) receives a colour per point; `Region`, `annulus`,
`wedgeAnnulus` and `crop` are all definitions above it.

This is the opposite of Slint's bet
([F3](./comparison.md)),
and it works only because nothing degrades: the model has no target that could
fail to render an `annulus`. As soon as a target exists that must approximate,
the semantics have to survive to the point of approximation — which is exactly
why `scrollbar` is in our drawing seam. Functional images do not refute
friction §3; they show that friction §3 is _caused by_ having heterogeneous
targets, not by careless layering.

Henderson's `rot45` verdict is nevertheless the transferable part: **an operator
whose laws are ugly is telling you it does not belong in the vocabulary.**
`RuleEdge` and `scrollbar`'s eight fields are our `rot45` — application-specific
operations that were admitted to a general algebra.

## Q4 — command shape

**Dissolved, at the cost of the property we most depend on.** There is no
command value. Henderson composes pictures by function composition;
`over(p,q)(a,b,c) = p(a,b,c) ∪ q(a,b,c)` is set union of the results, not a
concatenation of two op streams. `Pan` composes by `lift2` and `(.)`.

So a functional image cannot be recorded, culled, replayed or compared —
`RecordingCanvas` and the op-stream parity harness have no analogue, because the
only way to observe a function is to _apply_ it. Henderson's implementation note
makes the consequence explicit: rather than materialise the denoted set,

> we want to draw each basic graphical object … as we construct it and rely upon
> the fact that it doesn't matter if we draw the same object twice because the
> rendering engine will take care of that. ([`funcgeo2.pdf`][fg2], §5)

Idempotent overdraw substitutes for a comparable stream. That is a defensible
trade for a plotter and an indefensible one for a golden test, which strengthens
[F2](./comparison.md):
reification is not an accident of our design, it is the price of observability,
and the subjects that dispense with it dispense with observability too.

## Q5 — sub-unit placement

**Dissolved, and it names the replacement for `RuleEdge`.** Both domains are
continuous; `Pan`'s is continuous _and_ infinite, so there is no smallest
addressable unit to fall below. This confirms
[F5](./comparison.md)
from the extreme end.

The transferable detail is Henderson's `ε`. Device resolution enters the system
**once, as a scalar supplied at render time**, and its only effect is to prune:
below `ε` a picture denotes nothing. It is not a coordinate, not an enumerated
position, and not a per-operation flag. That is the same shape as Notcurses'
blitter ladder — _name a fidelity, let the renderer own it_ — reached
independently in 1982, and it is a stronger argument for F5 than continuity
alone.

## Q6 — resolved or semantic styling

**Split, and instructively.** `Pan` carries **resolved appearance only**:
`Colour` is premultiplied BGRA and `overC` is Porter–Duff `over` computed on
those numbers. Nothing in an image says _why_ it is that colour; a re-resolving
backend (our HTML class names) has nothing to re-resolve.

Henderson carries **neither**. A picture denotes a set of graphical objects with
no appearance attached, and the paper deliberately sidesteps the one place
appearance would force ordering:

> By avoiding the use of fills, it is not necessary to be concerned with the
> order in which the graphical objects are rendered. ([`funcgeo2.pdf`][fg2], §5)

So the two hedges available at friction §6 — resolved, semantic, or both — are
here reduced to "resolved" and "absent". Neither model pays for both, and
Henderson shows that dropping appearance from the vocabulary buys
order-independence, which is a real property and not merely an omission.

## Q7 — payload ownership

**Dissolved by purity.** A payload _is_ a function: immutable, freely shareable,
with no frame lifetime and no thread affinity. `DrawOp.text`'s borrowed slice
(friction §7) has no counterpart, because there is nothing to borrow from.

The sharp version is `Pan`'s `Array2 Int Int ((Int, Int) -> α)`: even an
imported photograph is stored as its **subscripting function**, with format
conversion performed during subscripting rather than at load. This is
[F6](./comparison.md)'s "share it,
do not borrow it" taken to its limit — the payload's owner is the closure, and
the question of who frees it is the host language's.

## Q8 — extent query

**The clearest result in this doc, and the two subjects disagree.**

Henderson: extent is **pushed down, never queried up**. `p(a,b,c)` receives its
box; a picture has no extent to be asked for, and every combinator's job is to
subdivide the box it was given (`beside` halves `b`, `above` halves `c`). This
is [F7](./comparison.md) —
"extent belongs to the surface, not the scene" — as an architectural law rather
than an observation: the surface picks the parallelogram and the scene is a
function of it.

`Pan`: extent is **undefined in principle**. Images are total over infinite
space; a window is a viewing decision made outside the model. Asking a `Pan`
image how big it is is a type error, not a missing method.

Together they say friction §8 is the wrong request. `skia-canvas-render.d`
scanning every op's rect to recover an extent is a symptom of building the
display list _before_ knowing the box; Henderson's answer is to make the box an
input to the build.

## Strengths

- **The contract is a type, stated once** — no probing, no undeclared surface,
  no divergence between the concept and the real contract (Q2).
- **Algebraic laws are a testing oracle.** `rot(above(p,q)) = beside(rot p, rot q)`
  is a property test that needs no golden image, and law simplicity doubles as
  the admission test for new vocabulary.
- **Extent flows downward**, so no participant ever needs to ask (Q8), and
  resolution independence is free — device fidelity is one render-time scalar (Q5).
- **Payloads are values**, so ownership, threading and lifetime questions do not
  arise (Q7).

## Weaknesses

- **No text.** Neither paper has a glyph, a font, a shaper or an advance. For a
  toolkit whose display list is 90% `textRun`, the model is silent on the
  dominant case (Q1).
- **No device, and therefore no degradation.** Nothing can report that it cannot
  draw a hairline; `ε` prunes but does not negotiate (Q2).
- **No observable command stream** — nothing to record, diff, cull or replay
  (Q4). Henderson explicitly relies on idempotent overdraw instead.
- **Sampling cost is unbounded**, which is why `Pan` needed a whole optimising
  compiler ("`Pan` is implemented as a compiler … produces C code, which is then
  given to an optimising compiler", [`fop-conal.pdf`][fi], §7.1). A seam whose
  performance requires partial evaluation of the user's program is not a seam a
  library can ship.
- **No retained identity.** Hit-testing, focus, incremental repaint and
  accessibility all need to know _which widget_ a pixel belongs to; a
  `Point -> Colour` has thrown that away by construction.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                                  | Trade-off                                                                                                  |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| Picture takes its locating box as an argument           | Abstracts "completely from size and absolute location"; one value serves every output size | Nothing can be built before the box is known; no scene exists to inspect, cache or diff                    |
| Composition is function composition, not a command list | Laws hold, so descriptions can be transformed and reasoned about                           | No reified stream: no recording, culling, replay, or op-stream parity testing                              |
| Image is total over infinite continuous space           | Clipping, layering and masking all become pointwise combinators (`cond`, `overC`, `lift2`) | Extent is undefined; every consumer must supply a window, and sampling has no natural stopping rule        |
| Transforms stored pre-inverted                          | Avoids inverting arbitrary, possibly many-to-one point mappings                            | The vocabulary reads backwards (`uscaleP 2` shrinks); users need the `Filter` wrappers to stay sane        |
| Resolution enters as one render-time `ε`                | Device fidelity is the renderer's business, not the description's                          | A single global cutoff cannot express per-feature fidelity (a hairline vs. a glyph want different answers) |
| No appearance in Henderson's algebra                    | Order-independence: overdraw is idempotent, so render order is unconstrained               | Anything needing fills, blending or colour falls outside the algebra entirely                              |

## Bearing on the proposal

1. **Pass the box down; delete the extent scan (friction §8, F7).** Henderson's
   `p(a,b,c)` is F7 stated as a rule. `buildDisplayList` should take the target
   rect the way a picture takes its parallelogram, so the offscreen consumer that
   forced `skia-canvas-render.d` to scan every op never needs to. This is the
   single directly copyable idea.
2. **`ε`, not more enumerators (friction §5, F5).** A render-time fidelity
   scalar is the 1982 form of Notcurses' blitter ladder. It corroborates F5's
   recommendation to replace `RuleEdge` with a fidelity rather than a seventh
   compass point — from a subject with no cells at all, which makes the
   convergence meaningful.
3. **Adopt law-checking above the seam, not the model below it.** `sparkles:ui`
   cannot be a picture algebra, but its _layout_ combinators can have laws worth
   testing (`above`/`beside` associativity, rotation identities on box-flow).
   Henderson's `rot45` verdict gives the admission test for new vocabulary: if an
   operator has no simple law, it is application-specific and belongs in the
   application. `scrollbar`'s eight `DrawOp` fields fail that test.
4. **Do not read F1 as licence to delete measurement.** These subjects have no
   `measure` because they have no text. F1's evidence is about _placement_; this
   doc adds no support for eliminating a metrics service, and `RND6`'s monospace
   cell advance is precisely the property a `Point -> Colour` model cannot carry.
5. **Reification is the price of observability, and we are right to pay it
   (F2).** The strongest argument against the functional-image seam is that
   Henderson has to fall back on idempotent overdraw because there is no stream
   to compare. `RecordingCanvas` exists for exactly the property this model
   gives up.
6. **Why `sparkles:ui` cannot take this route, stated plainly.** Three blockers,
   each independent: (a) the toolkit's unit is a Unicode grapheme cell whose
   advance is a property of the text (`RND6`), and a function from continuous
   points has nowhere to put shaping; (b) the widget model is retained and
   identity-bearing — focus, hit-testing and incremental repaint all ask "which
   widget", which `Point -> α` erases; (c) the terminal target is a discrete
   grid of cells that a renderer cannot sample its way onto without deciding
   what a half-covered cell is, which is the very question the seam exists to
   answer.

> [!NOTE]
> **Where this contradicts the synthesis.** Nothing here overturns F1–F7, but
> two are narrowed. F1 is narrowed to a placement claim (Q1, above). F3's "the
> axis is _where_ degradation lives" gains a third position — _no degradation at
> all_ — which is available only to a seam with one target class, and is
> therefore evidence that our semantic operations are forced by our target
> spread rather than chosen.

## Sources

- Peter Henderson, _Functional Geometry_, ACM Symposium on LISP and Functional
  Programming, 1982 — [`10.1145/800068.802148`][fg82] (ACM DL refuses automated
  requests; the link is a verified Wayback snapshot).
- Peter Henderson, _Functional Geometry_ (revised), _Higher-Order and Symbolic
  Computation_ 15(4), 2002 — [`10.1023/A:1022986521797`][fg2doi]; author PDF
  [`funcgeo2.pdf`][fg2] (internal timestamp `funcgeo2.tex; 16/10/2002; 13:53`).
- Conal Elliott, _Functional Images_, in Gibbons & de Moor (eds.), _The Fun of
  Programming_, Palgrave, 2003, ch. 7 — [chapter page][fip], PDF
  [`fop-conal.pdf`][fi].
- Conal Elliott, _Functional Image Synthesis_, Bridges 2001 — [abstract][bridges].
- [The Pan home page][pan] — the compiler and gallery.

<!-- References -->

[fg2]: https://eprints.soton.ac.uk/257577/1/funcgeo2.pdf
[fg2doi]: https://doi.org/10.1023/A:1022986521797
[fg82]: http://web.archive.org/web/20241227050435/https://dl.acm.org/doi/10.1145/800068.802148
[fi]: http://conal.net/papers/functional-images/fop-conal.pdf
[fip]: http://conal.net/papers/functional-images/
[bridges]: http://conal.net/papers/bridges2001/
[pan]: http://conal.net/pan/
[guidelines]: ../../guidelines/research-docs.md
