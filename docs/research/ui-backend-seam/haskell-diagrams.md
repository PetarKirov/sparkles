# Haskell `diagrams` — a seam where the primitive vocabulary is a set of instances

**Category:** typed backend seam. **Last reviewed:** August 23, 2026.
Pinned at [`15ec9e35`][core-rev] (`diagrams-core` 1.5.1.2) and
[`e3d6819d`][lib-rev] (`diagrams-lib` 1.6).

The strongest formal analogue to `isCanvas!T` in this survey. A backend is a
type; the pipeline it must implement is one class ([`Backend`][backend]) with
three associated types; and **what it can draw is not declared anywhere — it is
the set of [`Renderable p b`][renderable] instances that happen to exist.** A
diagram that uses a primitive its backend lacks is a type error at the point the
diagram is written, not a degrade at paint time. That is the design
[`canvas-seam-friction.md`][friction] §2 gestures at, taken to its limit — and
the interesting result is where it still leaks.

|                     |                                                                                                                        |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| **Language**        | Haskell (GHC 8.4 – 9.14, per `Tested-with`)                                                                            |
| **License**         | BSD-3-Clause (both packages)                                                                                           |
| **Repository**      | [`diagrams/diagrams-core`][core-repo], [`diagrams/diagrams-lib`][lib-repo]                                             |
| **Documentation**   | [diagrams.github.io][site]                                                                                             |
| **Category**        | typed backend seam                                                                                                     |
| **Pinned revision** | core [`15ec9e35af83983495ed65b5c93af018ee52b4a7`][core-rev]; lib [`e3d6819dbb56d35646933aa8703350096c3737c3`][lib-rev] |
| **Target range**    | vector output only — SVG, Cairo, PostScript, Rasterific, HTML5 canvas, PGF. No raster-cell or text-grid target exists  |
| **Seam shape**      | one type class for the pipeline; one class _per primitive_ for the vocabulary                                          |

## Overview

### What it solves

`diagrams` is an EDSL for building 2-D (and 3-D) vector graphics compositionally
— a `QDiagram b v n m` is a monoid, and `<>` is overlay. The seam question it
answers is: given that diagrams are assembled by users out of an _open_ set of
shapes, and rendered by an _open_ set of backends, how does the library stop
someone handing a PostScript backend an embedded PNG?

### Design philosophy

The answer is stated outright in the `$prim` section of
[`Diagrams/Core/Types.hs`][types]:

> Ultimately, every diagram is essentially a tree whose leaves are
> _primitives_, basic building blocks which can be rendered by backends.
> However, not every backend must be able to render every type of primitive;
> the collection of primitives a given backend knows how to render is
> determined by instances of `Renderable`.

Two consequences follow, and both are unusual. The primitive set is **open** —
any `Transformable`, `Typeable` type with a `Renderable` instance is a
primitive, including one a backend defines for itself. And backend capability is
**not a value**: there is no feature enum, no `hasFeature`, no probe. Capability
is the existence of an instance, checked by the compiler.

## How it works

### The pipeline class

[`Backend`][backend] is small — three associated types and two methods, one of
which has a default:

```haskell
class Backend b v n where
  data Render  b v n :: Type   -- backend-chosen intermediate representation
  type Result  b v n :: Type   -- what rendering produces
  data Options b v n :: Type   -- backend-specific options

  adjustDia :: (Additive v, Monoid' m, Num n) => b -> Options b v n
            -> QDiagram b v n m -> (Options b v n, Transformation v n, QDiagram b v n m)
  adjustDia _ o d = (o, mempty, d)

  renderRTree :: b -> Options b v n -> RTree b v n Annotation -> Result b v n
```

`Render` and `Options` are **data families** (each backend defines its own
constructors, and they cannot be confused across backends); `Result` is a
**type family** (it may be an existing type). The `b` parameter of every method
is a "backend token" carrying no information — the source comments say it is
"solely to help out the type system", because type families are not injective
and `Render b` could not otherwise be unified.

The spread across shipped backends shows how much the associated types absorb:

| Backend                | `Result b V2 n`        | `Render b V2 n`     |
| ---------------------- | ---------------------- | ------------------- |
| [SVG][svg]             | `Element`              | `R (SvgRenderM n)`  |
| [Cairo][cairo]         | `(IO (), C.Render ())` | `C (RenderM ())`    |
| [PostScript][ps]       | `B.Builder`            | `C (RenderM ())`    |
| [Rasterific][rast]     | `Image PixelRGBA8`     | —                   |
| [`NullBackend`][types] | `()`                   | `NullBackendRender` |

A backend that produces a pure value (`Element`, `Builder`, `Image`) and one
that produces an `IO` action satisfy the same class with neither lying. This is
the exact property `isCanvas`'s structural typing buys us with inferred
`@safe`/`@nogc`, obtained by a different mechanism: an associated type rather
than attribute inference.

### The vocabulary class

```haskell
class Transformable t => Renderable t b where
  render :: b -> t -> Render b (V t) (N t)
```

One instance per (primitive, backend) pair. `Renderable` is not a member of
`Backend` and is never enumerated; it is discovered only by the constraint
solver. The bridge is an existential:

```haskell
data Prim b v n where
  Prim :: (Transformable p, Typeable p, Renderable p b) => p -> Prim b (V p) (N p)

instance Renderable (Prim b v n) b where
  render b (Prim p) = render b p
```

`Prim` erases the primitive's type but **captures the `Renderable p b` dictionary
inside the constructor**, so the instance for `Prim` itself can dispatch without
knowing what `p` was. The type checker has therefore already discharged the
capability question by the time a display tree exists; the backend walking that
tree cannot encounter a primitive it does not support.

Where the check actually fires is the _use site_. Every constructor in
`diagrams-lib` carries the constraint forward — `text`, for instance:

```haskell
text :: (TypeableFloat n, Renderable (Text n) b) => String -> QDiagram b V2 n Any
```

So `text "hi" :: Diagram Postscript` compiles because
[`instance Renderable (Text Double) Postscript`][ps] exists, and
`image (uncheckedImageRef "foo.png" 200 200) :: Diagram Postscript` does not,
because no `Renderable (DImage n a) Postscript` instance does. The [`Backend`
documentation][types] reproduces exactly that error verbatim as its worked
example: `No instance for (Renderable (DImage n0 External) b0)`.

### The tree the backend receives

`renderRTree` is handed an `RTree`, a rose tree over a four-constructor sum:

```haskell
data RNode b v n a = RStyle (Style v n)   -- a style node
                   | RAnnot a             -- an annotation
                   | RPrim (Prim b v n)   -- a primitive
                   | REmpty
```

with a documented invariant backends may rely on: `RPrim` nodes never have
children. [`renderDiaT`][compile] is the whole driver —
`renderRTree b opts' . toRTree g2o $ d'` after `adjustDia` — and `toRTree`
performs the framework-side lowering: it flattens the dual monoid tree, then
maps [`unmeasureAttrs`][style] over every `RStyle` to convert relative units to
output units before the backend sees them.

## Q1 — measurement units, and who answers

**Nobody. `diagrams` does not measure text at all, and pays for it in the
layout model.** [`mkText'`][text] builds the text diagram with
`pointEnvelope origin` — a zero-extent envelope — and the haddock on every
public constructor says so:

> Create a primitive text diagram from the given string, with center
> alignment, equivalent to `alignedText 0.5 0.5`.
>
> Note that it _takes up no space_, as text size information is not available.

`topLeftText`, `alignedText` and `baselineText` each repeat "Note that it
_takes up no space_". A string therefore contributes nothing to any envelope,
so `hcat [text "a", text "bb"]` overlaps rather than laying out. The user's
workaround is to compose text with an explicitly sized invisible rectangle.

This is the sharpest data point in the survey against reading
[F1][comparison] ("text measurement is not a method of the drawing seam") as
license to simply delete `measure`. `diagrams` did delete it — there is no
metrics class, no shaping trait, no `Font::Length` — and the result is a
layout engine that cannot lay out text. The subjects behind F1 all put
measurement _somewhere_ other than the painter; `diagrams` is the control
experiment showing what putting it _nowhere_ costs.

> [!IMPORTANT]
> The reason is structural, not an oversight: the backend does not exist as a
> value during diagram construction. `b` is a phantom type parameter of
> `QDiagram b v n m`, and the token is only supplied at `renderDia`. A
> measurement service reachable from `text`'s type would have to be a class
> method on `b` returning a pure value — possible, but it would make every
> shaping backend's answer a pure function, which is false for anything with
> a font cache. The seam's purity is what forbids the query.

## Q2 — is the contract stated in one place?

**No — it is stated in exactly two places, and the split is principled.**

- The **pipeline** contract is one declaration. `Backend`'s haddock names its
  minimal complete definition outright: "A minimal complete definition consists
  of `Render`, `Result`, `Options`, and `renderRTree`." A backend author reads
  one class and knows the whole lifecycle.
- The **vocabulary** contract is not stated anywhere. It is the set of
  `Renderable p b` instances, and there is no way to ask a backend for that set
  at compile time or run time. Discovering that PostScript cannot draw images
  means grepping its module for `instance Renderable`, or writing the program
  and reading the type error.

That is the same locus as our friction §2 (_five methods, eight kinds_) —
capability discovered at the call site by introspection rather than declared at
the seam — with the opposite default. `sparkles:ui`'s `__traits(compiles)` in
`interp/immediate.d` _takes the primitive's stated degradation_: `ruleEndpoints`
plus a cell-aligned `line` where `rule` is missing, `paintScrollbarCells`
glyph-per-cell where `scrollbar` is, and nothing at all for the clip pair, since
the display list has already culled the hidden subtrees. GHC's instance
resolution at each diagram-construction site _fails the build_. Both are "the
concept does not describe the contract"; only one of them is silent.

The `Backend` class is also the honest place to note what it does **not**
contain: no capability enum, no `hasFeature`, no floor. Compare Qt's
`PaintEngineFeature` ([F5][comparison]) — `diagrams` has no equivalent, and
cannot have one, because its capabilities are not values.

## Q3 — semantic operations or primitives

**Primitives, and the set is open at both ends.**

`diagrams-lib`'s shipped primitive types are few — [`Path v n`][path],
[`Text n`][text], and [`DImage n a`][image] in 2-D, plus the 3-D shapes. There
is no `draw_box_shadow`, no `draw_text_input`, no scrollbar. Everything a user
would call a widget is built compositionally _above_ the seam and arrives as
paths.

But the set is not closed by the framework. Two escape hatches sit at the seam:

1. **A backend may add its own primitives.** [`diagrams-svg`][svg] declares
   `instance Renderable Element B` and `elementToDiagram e = mkQD (Prim e) mempty mempty mempty mempty`,
   making a raw SVG `Element` a first-class primitive of that backend and of no
   other. A diagram using it is statically bound to SVG.
2. **A primitive may be refined by a phantom type.** [`DImage`][image] is
   indexed by `Embedded`, `External`, or `Native t`, and backends instance them
   separately: `diagrams-svg` provides `Renderable (DImage n Embedded) SVG` and
   `Renderable (DImage n (Native Img)) SVG` but **not** `External`;
   `diagrams-cairo` provides `External` and `Embedded`. So "can draw an image"
   is not one capability but three, and the type index is how the seam says
   which.

That second mechanism is the transferable one. It is a way to make a
sub-capability a type rather than a flag — the shape friction §2 wants for
`rule`, `scrollbar` and the clip pair, which the seam probes identically and
types identically even though `rule`'s absence changes the picture and the clip
pair's does not.

## Q4 — command shape

**A small closed sum for structure; an open existential for payload.** `RNode`
has four constructors and no dead fields; the primitive is `Prim`, whose payload
is whatever type the constructor captured. Nothing in the pipeline is a flat
record carrying fields another kind owns, and there is no way to construct an
illegal combination: an `RPrim` carries a `Prim` and nothing else, an `RStyle`
carries a `Style` and nothing else.

That elimination is the same one `DrawOp` gets from being a `SumType` over eight
per-kind payloads, and on the settled half of [F3][comparison] — that reifying
the stream is right — the two designs agree outright. Where `diagrams` bears on
F3's open half, the encoding, is a second axis: `RNode` pushes the variability
one level down into an existential, so its structural sum stays at four cases
however many primitives the ecosystem grows, while `sparkles:ui` spends one arm
per drawing kind and therefore eight `match!` arms in every walker and every
member accessor. `RNode` has never needed a fifth case.

The cost of the existential is exactly the property `RecordingCanvas` rests on:
an `RTree` **cannot be compared or replayed generically**. `Prim` erases the
type, so two trees can be tested for equality only if every primitive is `Eq`
and you `cast` back through [`_Prim`][types], the `Prism'` provided for that
purpose. `diagrams` has no op-stream parity harness, and the existential is why;
a `DrawOp` stream is a sequence of plain values that compares pairwise, which is
what makes it a parity oracle ([F12][comparison]).

## Q5 — sub-unit placement

**Does not arise as a placement problem, but `diagrams` has the general
mechanism the survey has been looking for.** Coordinates are `Floating n` — the
numeric type is a parameter, so there is no coarse unit to be below.

The mechanism worth stealing is [`Measured`][measure], the four-level unit
ladder attributes are written in:

```haskell
newtype Measured n a = Measured { unmeasure :: (n,n,n) -> a }
-- (local, global, normalized) -> output
```

`local 1`, `global 1`, `normalized 1` and `output 1` are all `Measure n`, and
the framework — not the backend — collapses them to `output` units in
`toRTree`, using `avgScale` of the global-to-output transform and the diagram's
own diameters. A line width can therefore be authored as "1% of the diagram's
size" and arrive at the backend as an absolute number.

That is a direct answer to friction §5's real complaint, which is not that
`RuleEdge` names six positions but that **the toolkit has no vocabulary for a
quantity smaller than its own unit**. `Measured` is that vocabulary: a
relative-unit type resolved by the framework before the seam, so the backend
receives one absolute number and the toolkit never learns about device pixels.
It generalises [F6][comparison]'s answer — a named fidelity plus a queried
device unit — from a ladder of discrete fidelities to a continuous function of
scale.

## Q6 — resolved or semantic styling

**Semantic and open — and the backend re-resolves, every time.** A
[`Style v n`][style] is a `HashMap TypeRep (Attribute v n)`: a heterogeneous,
type-keyed map holding at most one attribute of any given type, with the
`Semigroup` instance of each attribute type deciding how nesting combines. The
`Attribute` existential has three shapes — plain, `MAttribute` (measured, so
subject to `unmeasureAttrs`), and `TAttribute` (transformable, so a gradient
follows its shape).

The backend pulls what it recognises, one type at a time; the PostScript
backend's helper is literally
`getStyleAttrib f = (fmap f . getAttr) <$> use accumStyle`, used as
`getStyleAttrib getFillTexture`, `getStyleAttrib getFont`, and so on. **An
attribute type no backend queries is silently dropped**, and nothing reports it.

So `diagrams` does not pay friction §6's double cost — a resolved appearance and
a semantic role on every drawing operation, which [F9][comparison] finds no
subject carrying. It keeps only the semantic side and pays instead in
re-resolution per backend plus a silent-drop channel. `sparkles:ui` stores the
resolved half each primitive paints from — an `Ink` on the four content
primitives, `FillRect`'s own colour fields and its `BoxChrome` pointer — with a
`Slot` beside it on six of the eight payloads; `Visual` is reconstructed through
`visualOf` rather than stored, which makes the hedge cheaper without making it a
decision. Note the asymmetry against Q3: primitives are open
and _non-ignorable_ (absence of an instance is an error), attributes are open
and _ignorable_ (absence of a query is nothing at all). One vocabulary, two
enforcement regimes, in the same seam.

There is a documented third tier. [`Annotation`][types] is a closed sum
(`Href`, `OpacityGroup`, `KeyVal`) riding on `RAnnot` nodes, and `href`'s
haddock says plainly: "Note that only some backends will honor hyperlink
annotations." That is an explicitly-blessed silent degrade, in writing, in a
library whose whole seam is otherwise type-enforced.

## Q7 — payload ownership

**Not a question here, and the reason is instructive.** Haskell values are
immutable and garbage-collected: `Text n` owns its `String`,
`DImage n Embedded` owns a `DynamicImage`, and a `Prim` owns whatever it
wrapped. Nothing is borrowed, nothing must outlive a frame, and `Result b v n`
is a value that outlives the render entirely.

The one place lifetime reappears is `Result` itself: Cairo's is
`(IO (), C.Render ())`, so the _effect_ is deferred as a value and run later —
the same trick as `RecordingCanvas`, reached by making the result type an
action rather than by making the command stream a data structure. Friction §7
therefore gets one lesson from this subject, and it is [F8][comparison]'s: of
thirty-eight subjects, not one borrows a payload across a frame. `diagrams`
shares by GC, which a `@nogc` seam cannot copy wholesale. `DrawOp.text` is a
`const(char)[]` borrowed from a frame arena that `CmdBuffer.textRun` copies
into, under a rule stated on the type — an operation is valid while the buffer
that built it is alive and unreset — which makes the borrow enforceable rather
than advisory. It is still a borrow, and the retain boundary it implies is
exactly what `UI-O4` keeps open.

## Q8 — can a backend ask the scene its extent?

**Yes — and this is where the survey's extent finding gets its strongest
evidence.** Every diagram carries an [`Envelope`][envelope] as part of its
value, defined not as a bounding box but as a support function:

```haskell
newtype Envelope v n = Envelope (Maybe (v n -> Max n))
```

> An envelope is an _extensional_ representation of such a "bounding region".
> Instead of storing some sort of direct representation, we store a _function_
> which takes a direction as input and gives a distance to a bounding
> half-plane as output. The important point is that envelopes can be composed,
> and transformed by any affine transformation.

Because it is a function of direction and composes monoidally under overlay,
extent is available at every node of the tree for free — no scan, no traversal,
no separate pass. `boundingBox` and `size` are derived from it.

`adjustDia` is then the seam's **negotiation hook**, and both parties get a
say. The stock implementation, [`adjustSize2D`][adjust], reads the requested
`SizeSpec` out of the backend's own `Options`, reads `boundingBox d` off the
scene, and calls [`sizeAdjustment`][size] to produce a concrete size and the
transform that fits one to the other — then **writes the resolved size back
into the options record** the backend will render with:

```haskell
adjustSize2D szL _ opts d = (set szL spec opts, t, d # transform t)
  where
    spec    = dims sz
    (sz, t) = sizeAdjustment (opts ^. szL) (boundingBox d)
```

A backend may thus request `absolute`, `mkWidth 400`, or fully specified
`dims` and receive, before it allocates anything, the size it will actually
paint plus the transform to get there. This is the survey's strongest case for
[F7][comparison]: extent is three questions — surface, layout and ink — and
`diagrams` answers all three from the scene, maintained at construction rather
than derived by a scan, then puts an explicit resolution step in the seam so the
surface's request and the scene's answer meet. `sparkles:ui` sits at the far end
of that axis. Nothing on `CmdBuffer`, the display list or the arena reports the
extent of a built stream — `CmdBuffer` exposes `length`, the operation count,
and `measure`, a run's cell extent — so a caller that needs painted bounds folds
`op.rect` itself (friction §8). `adjustDia` is also the step that returns the
inverse transform for mapping device coordinates back to scene coordinates, a
capability `sparkles:ui` does not have and will want for hit-testing under a
scaled GPU canvas.

## Strengths

- **Capability is checked, not probed.** A missing primitive is a compile error
  at the site that used it, naming both the primitive and the backend.
- **Associated types absorb backend disagreement.** Pure-value (`Element`,
  `Builder`, `Image`) and `IO`-action backends satisfy one class with neither
  reduced to a lowest common denominator.
- **The structural sum stays at four cases** however many primitives exist,
  because variability lives in an existential rather than in more tags.
- **Sub-capability as a type index** (`DImage n Embedded` vs `External`) splits
  one capability into several without a flag set.
- **Relative units are a framework concern** — `Measured` is collapsed to output
  units before the backend sees anything, so no backend re-implements it.
- **Extent is free and compositional**, and `adjustDia` makes size a two-way
  negotiation that also returns the inverse transform.

## Weaknesses

- **The vocabulary contract is unwritten.** Nothing enumerates a backend's
  `Renderable` instances; there is no `hasFeature`, and a user learns the answer
  from a type error.
- **`mempty` is an undetectable lie.** `render _ _ = mempty` type-checks
  identically to a real implementation. `diagrams-core` even _recommends_ the
  pattern — "It is courteous, when defining a new primitive `P`, to make an
  instance ... `render _ _ = mempty`" — for `NullBackend`, and `diagrams-lib`
  supplies it for [`Path`][path], [`Text`][text] and [`DImage`][image]. Sound
  for the null backend; but nothing distinguishes a real backend adopting it.
  **A seam that could have made every unsupported primitive a compile error
  leaves the silent degrade one line away, unmarked.**
- **The check is coarser than the capability.** [`diagrams-cairo`][cairo]
  declares `Renderable (DImage Double External) Cairo`, then at run time refuses
  anything but PNG, printing
  `Warning: Cairo backend can currently only render embedded images in .png format.`
  to stdout and dropping the image. The
  instance grants permission at the granularity of a type; the real capability
  is finer, so the residue becomes a runtime warning.
- **No text measurement at all**, and therefore no text layout (Q1).
- **The reified tree is not replayable.** Existential erasure blocks generic
  comparison, so no `RecordingCanvas` equivalent is possible.
- **Attributes degrade invisibly** — an unrecognised attribute type is dropped
  with no diagnostic, in the same seam that makes an unrecognised primitive a
  build failure.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                                      | Trade-off                                                                                  |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Capability = existence of a `Renderable p b` instance   | The compiler already resolves instances; no runtime feature negotiation is needed              | No backend can be interrogated for its capabilities; discovery is by type error or grep    |
| `Prim` as a `Renderable`-capturing existential          | Keeps the tree monomorphic while the primitive set stays open                                  | Type erasure blocks generic equality/replay, so no op-stream parity harness is possible    |
| `Render`/`Result`/`Options` as associated families      | Backends disagree about intermediate representation and output type without a common supertype | Every helper must thread the inert backend token to keep type families unifiable           |
| Primitives non-ignorable, attributes ignorable          | Attributes are unbounded in kind; requiring an instance per attribute would be unusable        | Two enforcement regimes in one seam; unrecognised attributes vanish with no diagnostic     |
| `Annotation` as an explicitly best-effort closed sum    | Hyperlinks and group opacity are meaningless in some outputs                                   | A blessed silent-degrade channel inside a type-enforced seam                               |
| Text carries `pointEnvelope origin`                     | The backend is a phantom parameter during construction; no metrics are reachable purely        | Text cannot participate in layout; users compose with sized invisible shapes               |
| Extent as a compositional support function (`Envelope`) | Composes monoidally under overlay and survives affine transforms                               | Only convex-hull-in-a-direction, not a tight region; a diagram's envelope can overstate it |
| `adjustDia` negotiates size and returns the transform   | Backends want to request a size; scenes have an intrinsic one                                  | An extra seam method most backends must implement rather than inherit the no-op default    |

## Bearing on the proposal

1. **Do not delete `measure` without deciding where measurement goes**
   (friction §1, [F1][comparison]). This subject is the negative control: it
   removed measurement from the seam and from everywhere else, and its layout
   engine cannot lay out a string. F1 remains right that measurement is not a
   method of the drawing seam; `diagrams` shows the requirement is to _relocate_
   it, not merely to remove it.
2. **Split a capability with a type index rather than a flag** (friction §2).
   `DImage n Embedded` / `External` / `Native t` splits one "draw an image"
   capability into three, each separately instanceable. `rule`, `scrollbar` and
   the clip pair are four optional primitives probed and typed alike, though the
   clip pair's absence is invisible and the other two's is not; typed
   sub-capabilities are a cheaper fix than a feature enum and compose better with
   structural typing.
3. **The structural sum should be small, with the variability one level down.**
   This subject argues against `DrawOp`'s one-arm-per-drawing-kind encoding:
   eight arms is one axis too many, and few structural cases carrying a payload
   type would serve the same stream. The mechanism is `RNode` — four
   constructors that have survived the whole ecosystem's primitive growth
   because the variable part is a `Prim` existential capturing its own
   `Renderable p b` dictionary, not another tag ([`Core/Types.hs`][types]).
   Priced against the seam as it stands: `DrawOp.kind` is an eight-arm `match!`
   precisely so a derived `OpKind` and the payloads cannot disagree, `visualOf`
   reconstructs a `Visual` per arm, and each member accessor — `rect`, `text`,
   `glyph`, `to`, `lineStyle`, `ruleEdge`, `slot`, the `bar*` group,
   `expandPercent`, `translate` — is another eight, since an arm that cannot
   answer must return a neutral value rather than read another arm's bytes.
   Collapsing the arms collapses all of that, and costs the exhaustiveness that
   makes an unhandled kind a compile error at every consumer. It buys nothing on
   size: `TextRun` is the widest payload either way, and `DrawOp.sizeof <= 64`
   holds regardless. **Live** — arm count is a maintenance argument the size
   budget does not answer. Eight arms means eight `match!` arms in every walker
   and every accessor, and that cost is real whatever the budget says.
4. **But keep the payload comparable.** `diagrams` pays for its existential
   with no replay and no parity harness ([F12][comparison]). `RecordingCanvas`
   is on the friction log's "did not cause friction" list because a `DrawOp`
   stream is a sequence of plain, pairwise-comparable values; a payload type
   that erased its own identity would take that with it. Whatever shape the
   structural sum takes, the payload stays a value.
5. **A typed seam does not remove the silent degrade — it hides it better**
   (friction §2, [F5][comparison]). `render _ _ = mempty` type-checks like a
   real implementation, and Cairo's PNG-only `External` image path degrades at
   run time with a `putStrLn`. F5's ladder — floor, defaulted, refusable — is
   not weakened by adding static checking; it is needed in addition to it. This
   is the single most transferable negative result here.
6. **Adopt a framework-resolved relative unit** in place of more `RuleEdge`
   enumerators (friction §5, [F6][comparison]). `Measured`'s
   `(local, global, normalized) -> output` collapse generalises F6's named
   fidelity plus queried device unit: the toolkit authors a quantity relative to
   something it knows, and the framework hands the backend one absolute number.
7. **Extent is answerable from the scene, and the transform comes with it**
   (friction §8, [F7][comparison]). `diagrams` is F7's maintained-at-construction
   end taken as far as it goes: the scene knows its extent by construction
   (`Envelope`), the backend states a request (`SizeSpec` in its own `Options`),
   and `adjustDia` resolves the two _and returns the inverse transform_. Painted
   bounds in `sparkles:ui` come from folding `op.rect` over the stream, outside
   the seam. That inverse transform is the part the toolkit will want
   independently of friction §8, because a scaled GPU canvas needs it to map
   pointer coordinates back into cell space.
8. **Note what does not transfer.** Attribute purity, GC-shared payloads, and
   instance-resolution-as-capability all depend on the backend being a phantom
   type rather than a value. `isCanvas` takes `ref T c` — a real object with
   state — which is why our seam can host `measure` at all and why `diagrams`
   cannot.

## Sources

Primary sources, all read at the pinned revisions above:

- `diagrams-core`: [`Core/Types.hs`][types] (the `Backend` class, `Renderable`,
  `Prim`, `RTree`/`RNode`, `Annotation`, `NullBackend`),
  [`Core/Compile.hs`][compile] (`renderDia`/`renderDiaT`/`toRTree`),
  [`Core/Envelope.hs`][envelope], [`Core/Measure.hs`][measure],
  [`Core/Style.hs`][style].
- `diagrams-lib`: [`TwoD/Text.hs`][text], [`TwoD/Image.hs`][image],
  [`Path.hs`][path] (the 2-D primitive set and its `NullBackend` instances),
  [`Size.hs`][size] and [`TwoD/Adjust.hs`][adjust] (`SizeSpec`,
  `sizeAdjustment`, `adjustDia2D`).
- Backend instances read for capability evidence: [`diagrams-svg`][svg],
  [`diagrams-cairo`][cairo], [`diagrams-postscript`][ps],
  [`diagrams-rasterific`][rast].
- `sparkles:ui`'s seam under study: [`canvas.d`][canvas]; the friction log
  [`canvas-seam-friction.md`][friction]; the synthesis [`comparison.md`][comparison].

Revisions were pinned with `gh api repos/diagrams/<pkg>/commits/master --jq .sha`
and every cited file fetched from `raw.githubusercontent.com` at that SHA.

<!-- References -->

[core-rev]: https://github.com/diagrams/diagrams-core/tree/15ec9e35af83983495ed65b5c93af018ee52b4a7
[lib-rev]: https://github.com/diagrams/diagrams-lib/tree/e3d6819dbb56d35646933aa8703350096c3737c3
[core-repo]: https://github.com/diagrams/diagrams-core
[lib-repo]: https://github.com/diagrams/diagrams-lib
[site]: https://diagrams.github.io
[types]: https://github.com/diagrams/diagrams-core/blob/15ec9e35af83983495ed65b5c93af018ee52b4a7/src/Diagrams/Core/Types.hs
[backend]: https://github.com/diagrams/diagrams-core/blob/15ec9e35af83983495ed65b5c93af018ee52b4a7/src/Diagrams/Core/Types.hs#L837
[renderable]: https://github.com/diagrams/diagrams-core/blob/15ec9e35af83983495ed65b5c93af018ee52b4a7/src/Diagrams/Core/Types.hs#L993
[compile]: https://github.com/diagrams/diagrams-core/blob/15ec9e35af83983495ed65b5c93af018ee52b4a7/src/Diagrams/Core/Compile.hs
[envelope]: https://github.com/diagrams/diagrams-core/blob/15ec9e35af83983495ed65b5c93af018ee52b4a7/src/Diagrams/Core/Envelope.hs
[measure]: https://github.com/diagrams/diagrams-core/blob/15ec9e35af83983495ed65b5c93af018ee52b4a7/src/Diagrams/Core/Measure.hs
[style]: https://github.com/diagrams/diagrams-core/blob/15ec9e35af83983495ed65b5c93af018ee52b4a7/src/Diagrams/Core/Style.hs
[text]: https://github.com/diagrams/diagrams-lib/blob/e3d6819dbb56d35646933aa8703350096c3737c3/src/Diagrams/TwoD/Text.hs
[image]: https://github.com/diagrams/diagrams-lib/blob/e3d6819dbb56d35646933aa8703350096c3737c3/src/Diagrams/TwoD/Image.hs
[path]: https://github.com/diagrams/diagrams-lib/blob/e3d6819dbb56d35646933aa8703350096c3737c3/src/Diagrams/Path.hs
[size]: https://github.com/diagrams/diagrams-lib/blob/e3d6819dbb56d35646933aa8703350096c3737c3/src/Diagrams/Size.hs
[adjust]: https://github.com/diagrams/diagrams-lib/blob/e3d6819dbb56d35646933aa8703350096c3737c3/src/Diagrams/TwoD/Adjust.hs
[svg]: https://github.com/diagrams/diagrams-svg/blob/6530b1500f10de49660cf2c6509208658b3e7e56/src/Diagrams/Backend/SVG.hs
[cairo]: https://github.com/diagrams/diagrams-cairo/blob/bd8402c845f255bb6793b9b2949392e8bb1c9baf/src/Diagrams/Backend/Cairo/Internal.hs
[ps]: https://github.com/diagrams/diagrams-postscript/blob/5f9f65ed2e8f88a3bf75d30ff3a7b411154c8f38/src/Diagrams/Backend/Postscript.hs
[rast]: https://github.com/diagrams/diagrams-rasterific/blob/290ddde30ebce322eeb1eee22e049e46f34177ba/src/Diagrams/Backend/Rasterific.hs
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[comparison]: ./comparison.md
