# Vty Image — the scene is an algebra, and it knows its own size

**Category:** image algebra (cell). **Last reviewed:** August 23, 2026.
Pinned at [`2650dc85`][rev].

Vty is the terminal substrate under [Brick][brick]; this deep-dive reads only its
**output value model** — `Image`, `Picture`, `SpanOp` — because that is the part
with a lesson the rest of the survey does not supply. Vty's scene is a six-case
sum type closed under two associative join operators, and **every node caches its
own extent as a field**, so `imageWidth` is a field read rather than a traversal.
That is the direct, affirmative answer to Q8 that
[friction §8][friction] says `sparkles:ui` lacks.

| Field         | Value                                                                          |
| ------------- | ------------------------------------------------------------------------------ |
| Language      | Haskell (plus a small C width table in `cbits/`)                               |
| License       | BSD-3-Clause ([`vty.cabal`][cabal])                                            |
| Repository    | [`jtdaugherty/vty`][repo]                                                      |
| Documentation | [Hackage `vty`][hackage]                                                       |
| Category      | image algebra (cell)                                                           |
| Version       | `6.6` ([`vty.cabal`][cabal])                                                   |
| Target range  | character cells only — one target class, no GPU end                            |
| Seam shipped  | `Output`, a record of ~20 functions; platform packages (`vty-unix`) fill it in |
| Pinned rev    | `2650dc859cdbc2892ba211d0ed337b2c1537c3e1`                                     |

## Overview

### What it solves

An application hands Vty a **value**, not a sequence of calls. The top-level module
states the whole contract in two bullets:

> Output is provided to by the application to Vty in the form of a `Picture`. A
> `Picture` is one or more layers of `Image`s.
>
> Each platform on which Vty is supported provides a package that provides Vty with
> access to the platform-specific terminal interface.
>
> — [`src/Graphics/Vty.hs`][vty-hs]

Two seams are stacked, different in kind. The **upper** seam is a pure data type the
application constructs (`Image`); the **lower** seam is a record of `IO` functions a
platform package supplies (`Output`). Composition lives above the line, capability
below it.

### Design philosophy

The `Image` type is a closed algebra of six constructors, and the documentation for
the internal type says exactly what they mean:

> Images are: a horizontal span of text; a horizontal or vertical join of two images;
> a two dimensional fill of the `Picture`'s background character; a cropped image; an
> empty image of no size or content.
>
> — [`Graphics.Vty.Image.Internal`][internal] (reflowed from its bullet list)

No border, no scrollbar, no shadow, no rounded rect — six structural cases and nothing
semantic. Everything a user would call a widget is composed above this, which is what
Brick is.

The constructors are **not exported**: `Graphics.Vty.Image` re-exports the type
`Image` abstractly, and the constructor module carries `{-# OPTIONS_HADDOCK hide #-}`
with the instruction "Use the constructors in `Graphics.Vty.Image` to create
instances" ([`Internal.hs`][internal]). Access is through smart constructors that
maintain the type's invariants.

## How it works

### The type, with extent in the constructors

```haskell
data Image =
      HorizText { attr :: Attr, displayText :: TL.Text
                , outputWidth :: Int   -- display columns
                , charWidth :: Int }   -- characters
    | HorizJoin { partLeft :: Image, partRight :: Image
                , outputWidth :: Int, outputHeight :: Int }
    | VertJoin  { partTop :: Image, partBottom :: Image
                , outputWidth :: Int, outputHeight :: Int }
    | BGFill    { outputWidth :: Int, outputHeight :: Int }
    | Crop      { croppedImage :: Image, leftSkip :: Int, topSkip :: Int
                , outputWidth :: Int, outputHeight :: Int }
    | EmptyImage
```

— [`Internal.hs`][internal]. The extent fields are the point. Every composite case
stores its own resulting width and height, so the query is one pattern match:

```haskell
imageWidth :: Image -> Int
imageWidth HorizText { outputWidth = w } = w
imageWidth HorizJoin { outputWidth = w } = w
-- …
imageWidth EmptyImage = 0
```

— [`Internal.hs` L154–L170][internal-extent].

### The joins, and what they pay to keep that true

`horizJoin` is where the invariant is bought. The doc comment on `HorizJoin` states
it: "a `HorizJoin` instance is required to be between two images of equal height. The
`horizJoin` constructor adds background fills to the provided images that assure this
is true" ([`Internal.hs`][internal]). The implementation pads the shorter side with a
`BGFill` before building the node:

```haskell
horizJoin EmptyImage i          = i
horizJoin i          EmptyImage = i
horizJoin i0@(HorizText a0 t0 w0 cw0) i1@(HorizText a1 t1 w1 cw1)
    | a0 == a1 = HorizText a0 (TL.append t0 t1) (w0 + w1) (cw0 + cw1)
    | otherwise  = HorizJoin i0 i1 (w0 + w1) 1
horizJoin i0 i1
    | h0 == h1 = HorizJoin i0 i1 w h0
    | h0 < h1  = let padAmount = h1 - h0
                 in HorizJoin (VertJoin i0 (BGFill w0 padAmount) w0 h1) i1 w h1
```

— [`Internal.hs` L192–L215][internal-join]. Three things at once: the identity
equations for `EmptyImage`; the **coalescing** of adjacent same-attribute text into one
node; and the normalisation that makes the cached height honest. `vertJoin` is
symmetric, and `emptyImage` is the algebraic identity, declared as such —
`instance Monoid Image where mempty = EmptyImage`, `(<>) = vertJoin`
([`Internal.hs`][internal]). `(<|>)` and `(<->)` alias the two joins at `infixr 5` and
`infixr 4` ([`Image.hs`][image-hs]).

> [!NOTE]
> The internal comment claims "Any image of zero size equals the empty image", but
> `Eq` is `deriving`d structurally, so `text a ""` builds `HorizText a "" 0 0`, which
> is a zero-size image that is not `==` to `EmptyImage`. The law is upheld where a
> constructor can uphold it — `backgroundFill 0 h`, `crop 0 _ _`, `cropLeft 0 _` all
> return `EmptyImage` ([`Image.hs`][image-hs]) — not by the equality instance.

### No translate node

There is no `Translate` constructor. `translateX`/`translateY` are **defined in terms
of the other cases**: a positive offset is a `HorizJoin` with a leading `BGFill`, a
negative offset is a `cropLeft` ([`Image.hs` L257–L271][image-translate]). `pad` is four
applications of join-with-`BGFill`; `resize` is crop-or-pad per axis; `cropLeft`/`cropTop`
fuse into an existing `Crop` by bumping `leftSkip`/`topSkip`. The algebra is smaller
than its published surface: eighteen exported combinators and modifiers over six constructors.

### The result reification: `Image` → `SpanOp`

`displayOpsForPic :: Picture -> DisplayRegion -> DisplayOps`
([`PictureToSpans.hs` L89][p2s-entry]) is the lowering: a depth-first walk carrying a
`BlitState` of `skipColumns`/`skipRows`/`remainingColumns`/`remainingRows`, emitting
into a mutable `Vector` of per-row op vectors. The target vocabulary is **three** cases:

```haskell
data SpanOp =
      TextSpan { textSpanAttr :: !Attr, textSpanOutputWidth :: !Int
               , textSpanCharWidth :: !Int, textSpanText :: TL.Text }
    | Skip !Int      -- skip this many columns
    | RowEnd !Int    -- end of row; this many columns left clear
    deriving Eq
```

— [`Span.hs` L37][span-op]. Layers are merged by `mergeUnder`, then
`substituteSkips` replaces every remaining `Skip` with the `Picture`'s background —
either a real character span, or, for `ClearBackground`, a trailing `RowEnd` plus
spaces. The `Skip` case is unrepresentable in output: `writeSpanOp` calls
`error "writeSpanOp for Skip"` if one survives ([`Output.hs`][output-hs]).

The author's own assessment of the blitter is worth quoting, because it is the price
of the algebra:

> This is a very touchy algorithm. Too touchy. For instance, the `Crop`
> implementations is odd. They pass the current tests but something seems terribly
> wrong about all this.
>
> — [`PictureToSpans.hs` L244][p2s-touchy]

## Q1 — text measurement unit, and who answers

**Columns, measured once at construction, by a process-global oracle.**

`text` computes the width eagerly and stores it: `text a txt = HorizText a txt
(safeWctlwidth txt) (fromIntegral $! TL.length txt)` ([`Image.hs` L121][image-text]).
`safeWcwidth` is `max 0 . wcwidth`, and `wcwidth` is an FFI call:
`foreign import ccall unsafe "vty_mk_wcwidth" wcwidth :: Char -> Int`
([`Width.hs` L29][width-hs]).

The surprising part is where that C function's answer comes from. It reads a
**mutable process-global table**: `static uint8_t* custom_table` guarded by
`custom_table_ready` in [`cbits/mk_wcwidth.c`][cbits], installed once at startup by
`installUnicodeWidthTable` under an `MVar` lock, with `isCustomTableReady` to observe
it ([`Install.hs`][install]). The README explains the motive:

> Vty also needs to rely on such a table to compute the width of Vty images to do
> image layout. Since those tables can disagree if Vty and the terminal emulator
> support different versions of Unicode … it's likely that for some wide characters,
> Vty applications will exhibit rendering problems.
>
> — [`README.md`][readme]

Vty ships `vty-build-width-table` to interrogate the actual terminal and generate that
table, and a `widthMap "xterm" "/path/to/map.dat"` config directive to load it per
`TERM` ([`README.md`][readme]). Installation is one-shot and irrevocable: "Only one
custom table load can be performed in a Vty program."

Two results follow. The first is [F1][comparison]'s: measurement is indeed **not on the
painter** — it is not on `Output` at all. The second lands squarely on
[F2][comparison]'s _oracle authority_ decision, and answers it in a way no per-backend
measurer could. Vty's oracle is not a font object owned by whichever backend is
painting; it is **one global table that the toolkit and the device are negotiated into
agreeing on**, because in a terminal the device's opinion of a width is a fact the
toolkit must match, not a service the toolkit can request. A per-backend measurer would
let two backends disagree, which is precisely the failure the width-table machinery
exists to eliminate.

`HorizText` also caches `charWidth` beside `outputWidth`. Both units survive into
`TextSpan`, and both are needed: `cursorColumnOffset` uses `spanOpHasWidth`'s
`(charWidth, outputWidth)` pair and `columnsToCharOffset` to translate a logical
character cursor into a terminal column ([`Output.hs`][output-hs]). **A cell seam that
carries only one number cannot place a cursor.**

## Q2 — is the contract stated in one place?

**Yes, and emphatically.** The lower seam is a single record:

```haskell
data Output = Output
    { terminalID :: String
    , releaseTerminal :: IO ()
    , reserveDisplay :: IO ()
    , displayBounds :: IO DisplayRegion
    , outputByteBuffer :: BS.ByteString -> IO ()
    , supportsCursorVisibility :: Bool
    , supportsMode :: Mode -> Bool
    , setMode :: Mode -> Bool -> IO ()
    , mkDisplayContext :: Output -> DisplayRegion -> IO DisplayContext
    , supportsBell :: IO Bool
    , supportsItalics :: IO Bool
    , supportsStrikethrough :: IO Bool
    , outputColorMode :: ColorMode
    , … }
```

— [`Output.hs` L61][output-record], documented as "The library's device output
abstraction. Platform-specific implementations must implement an `Output`". Every
field is mandatory; there is no optional method and nothing to probe for. Capability
is expressed as **data inside the mandatory record**: five `supports*` fields plus an
`outputColorMode` enum. That is Qt's declared-feature model reached by a different
route — a record of functions instead of a virtual base with a feature bitmask — and
it lands in a library with one target class, where nobody would have predicted the
need.

The upper seam has no capability question at all, because `Image` is data.

## Q3 — semantic widgets, or primitives?

**Primitives, at both levels, with zero semantic operations.** Six image constructors,
three span ops, and not one of them names a UI concept. A scrollbar in Brick is
[built from `Image`s][brick]; Vty never learns that one exists.

This is the survey's cleanest counter-example to Slint's eight semantic operations,
and the reason is structural rather than philosophical: **Vty has one target class**.
Every consumer of a `Picture` is a terminal, so there is no backend that would degrade
a scrollbar differently from another backend, and therefore nothing for a semantic
operation to buy. [F4][comparison] says the axis is _where the lowering lives_; Vty adds
the prior question — _is there more than one lowering to choose between?_ When the
answer is no, the seam has nowhere to put a semantic operation that a caller could not
put above it, and semantics in the seam are pure cost.

## Q4 — command shape

**A closed, abstractly-exported sum type with per-constructor named fields** — the same
side of [F3][comparison]'s encoding trade that `DrawOp` takes, a closed
`SumType` over eight per-kind payloads whose fields are case-local and whose walkers
are `match!` arms. Vty adds two properties on top of that shape, and only one of them
is a property `DrawOp` shares:

1. **Illegal states are unconstructible, not merely unrepresentable.** `HorizJoin` of
   two unequal-height images cannot be built, because the only way in is `horizJoin`,
   which pads first. This is the half `DrawOp` does not have. Its payloads are public
   structs, so case-local fields eliminate the cross-arm nonsense — a `PopClip` has no
   colour to set wrongly — without eliminating the within-arm kind: nothing stops a
   caller building a `TextRun` whose `rect.width` disagrees with the advance, or a
   `PushClip` with no matching `PopClip`. Sum-typing relocates illegal states; only a
   constructor boundary removes them.
2. **Structural equality on the reified result** — which `DrawOp` does have, as plain
   value semantics on the sum, and which is why the op-stream parity harness can
   compare two `RecordingCanvas` runs pairwise. Vty spends it on redraw: `SpanOp`
   derives `Eq`, and `outputPicture` keeps the previous frame's `DisplayOps` in
   `assumedStateRef` and emits only rows where `Vector.zipWith (/=) previousOps ops`
   says something changed ([`Output.hs` L217][output-picture]). The whole redraw
   optimisation is one `/=` on the reified value. What separates the two is not
   comparability but how long a compared value stays readable — Q7.

Note the two reifications differ in shape on purpose: `Image` is a **tree** with
per-case payloads (recursion is the composition mechanism), and `SpanOp` is a **flat
three-case record** in row-major vectors (linear scan is the consumption mechanism).
`sparkles:ui`'s `DrawOp[]` is the second shape being asked to do the first job.

## Q5 — sub-unit placement

**Not expressible, and the refusal is explicit.** Every coordinate in the algebra is a
whole cell; `Crop` carries integer `leftSkip`/`topSkip`; `translate` is integer
pad-or-crop. There is no `RuleEdge` analogue because there is no operation that could
consume one.

What Vty does instead, when a clip lands _inside_ a multi-column character, is
substitute a glyph that says so. `clipText` returns a flag for a partially-consumed
character and prepends or appends `'…'`:

```haskell
let (toDrop,padPrefix) = clipForCharWidth leftSkip txt 0
    txt' = if padPrefix then TL.cons '…' (TL.drop (toDrop+1) txt) else TL.drop toDrop txt
```

— [`Internal.hs` L30][internal-cliptext]. The same choice appears in
`swapSkipsForCharSpan`, where a background fill whose width is not a multiple of the
background character's width pads the `ow mod w` remainder with `'…'`
([`PictureToSpans.hs`][p2s-swap]).

So the third answer to Q5, after "continuous floats" (Slint, Qt) and "a fidelity
ladder" ([Notcurses][notcurses]), is **"name the partial cell with a substitute
glyph"** — visible degradation at cell granularity, no sub-cell vocabulary anywhere.

## Q6 — resolved appearance, semantic role, or both?

**One channel, resolved at construction.** `Attr` is a field of `HorizText`, set when
the image is built, and copied unchanged into `TextSpan`. There is no slot, no role,
no second channel — nothing in Vty re-resolves an attribute from a semantic name, so
nothing pays for the ability.

Device narrowing happens **once, in the framework, at the last moment**:
`limitAttrForDisplay` clamps the fore/back colour against the `Output`'s declared
`outputColorMode`, folding a `Color240` above the terminal's count or an RGB colour on
a 240-colour terminal down to `Default`, and mapping bright ISO colours to their dim
counterparts on `ColorMode8` ([`Output.hs` L340][output-limit]). The platform backend
never sees a colour it cannot emit.

That is Qt's "framework emulates, backend stays simple" placement in a cell library, and
it is another subject on [F9][comparison]'s side of the count: one channel per
operation, and nothing pays for a second. Friction §6, _a resolved appearance and a
semantic role on every drawing op_, is the contrast. Six of `DrawOp`'s eight payloads
store a `Slot` beside the resolved `Ink` or colour fields the primitive paints from, so
the pixel backends read the resolved half and the HTML interpreter re-resolves from the
role. Deriving `Visual` on demand rather than storing it makes that hedge cheap; it
does not make it one channel. Vty's lesson for it is the placement: resolve to one
channel early, then clamp against the backend's declared capability in a single
function, so no backend re-implements degradation.

> [!WARNING]
> "Resolved" is not quite total. `Attr`'s colour field is three-state —
> `Default | KeepCurrent | SetTo c` — and `limitAttrForDisplay` passes the first two
> through untouched. `KeepCurrent` is a _semantic_ value ("inherit whatever the
> terminal is currently showing") living inside the resolved channel, and it exists
> because a terminal is a stateful device. A GPU-plus-terminal seam should expect the
> same leak.

## Q7 — payload ownership

**The image owns everything, and outlives the frame by construction.** `displayText`
is a `TL.Text` the node owns; there is no borrowed slice anywhere in `Image` or
`SpanOp`. `horizJoin`'s coalescing case _allocates a new_ `TL.Text` rather than
retaining a reference to a caller's buffer. An `NFData` instance is provided so an
application can force an image to normal form before handing it over
([`Internal.hs`][internal]).

The frame-lifetime question is answered in the strongest possible way: `outputPicture`
**stores the reified result across frames** in `prevOutputOps :: Maybe DisplayOps`
inside an `IORef`, and diffs the next frame against it ([`Output.hs`][output-picture]).
[F8][comparison] finds no subject in the survey borrowing a payload across a frame;
Vty is the case where _the optimisation itself_ is the reason.

`sparkles:ui` sits on both sides of that line, and the split is the interesting part.
`DrawOp.text` is a `const(char)[]` borrowed from an arena — `CmdBuffer.textRun` copies
the caller's bytes in, which is what makes a `scope` source safe — and the rule stated
on the type is that _an operation is valid while the buffer that built it is alive and
unreset_. Which arena it borrows from decides whether Vty's diff is available. Under
`FrameArena`, `reset()` reclaims the chunks and last frame's runs stop being readable,
so a retained `DrawOp[]` is a set of dangling slices; under `GcArena`, `intern` is an
`idup` and `reset` a no-op, so the `DrawOp[]` that `buildDisplayList` returns is owned
outright and diffs exactly as Vty's does. `RecordingCanvas` interns on the collected
heap for the same reason: its ops must outlive the call that drew them. Friction §7 is
the price of the first path and `UI-O4` is open on precisely where the retain boundary
should fall.

## Q8 — extent query

**The single strongest result in this deep-dive: the scene is self-describing, and it
costs O(1).**

`imageWidth`/`imageHeight` read a cached field per constructor; no traversal, no
bounding-box accumulation, no scan of a flat op list ([`Internal.hs`
L154–L170][internal-extent]). The value is computed **by construction**, at each join,
crop and pad, from the two operands' cached values. This is the same result
[GTK4/GSK][gtk4] reports for `GskRenderNode`'s bounds and the inverse of
[Skia's][skia] refusal to expose an `SkPicture`'s extent as anything but a
caller-declared cull rect.

The invariant is property-tested, not merely intended
([`tests/programs/VerifyImageOps.hs`][verify]):

| Property                        | What it pins                                                         |
| ------------------------------- | -------------------------------------------------------------------- | ------ | ---------- | ------ | ---------------------------------------- |
| `manySwHorizConcat`             | `imageWidth (horizCat cs) == length cs` for single-column characters |
| `manyDwHorizConcat`             | …`== 2 * length cs` for double-column characters                     |
| `horizConcatSwAssoc`            | `(a <                                                                | > b) < | > c == a < | > (b < | > c)` — associativity, by value equality |
| `disjointHeightHorizJoinBgFill` | both `HorizJoin` parts really are the join's height after padding    |
| `translationIsLinearOnOutSize`  | `imageWidth (translate x y i) == imageWidth i + x`                   |
| `paddingIsLinearOnOutSize`      | `pad l t r b` is linear on both axes                                 |
| `cropLeftLimitsWidth`           | `v >= imageWidth (cropLeft v i)`                                     |

And crucially, the **surface declares its extent too, independently**: `displayBounds
:: IO DisplayRegion` on `Output`, and `displayOpsForPic pic r` takes the region as an
argument and crops the self-describing image into the surface-declared one. Vty has
both numbers and uses each for what it is good for — the image's for layout and
composition, the surface's for clipping and the output loop.

That combination is [F7][comparison] in its clearest form: extent is not one question
but three, and Vty answers the surface one from `displayBounds` and the layout one from
the scene, keeping each where it is authoritative. On F7's other axis —
maintained-at-construction versus derived-by-scan — Vty is the purest instance of the
first pole in the survey, and the reason its scene copy is cheap is exactly that it is
never derived: the constructors that build the scene are the only place it could be
computed, so computing it there costs one addition per node.

## Strengths

- **O(1) extent, maintained by construction**, with no separate bounds pass and no
  scan of a flat command list.
- **Two associative operators with a shared identity**, so composition is an algebra
  a caller can reason about and a test can property-check.
- **An abstract sum type with smart constructors**: illegal nodes are unconstructible,
  not merely discouraged.
- **A single, mandatory, fully-stated backend record** with capability as data
  (`supportsItalics`, `outputColorMode`) rather than as something to probe for.
- **Owned payloads throughout**, which is what makes cross-frame retention and row
  diffing possible.
- **Device narrowing in one framework function** (`limitAttrForDisplay`), and **two
  units carried side by side** (`outputWidth`, `charWidth`) where the terminal needs
  both.

## Weaknesses

- **The interpreter is the fragile part.** The
  `addMaybeClipped`/`addMaybeClippedJoin` pair is dense skip/remaining arithmetic the
  author himself calls "too touchy" ([`PictureToSpans.hs`][p2s-touchy]).
  A tree algebra pushes complexity out of the data and into the traversal.
- **Global mutable measurement state.** One process-wide width table, installable
  once, never replaceable — correct for the problem, but it means measurement cannot
  differ per output device in a single process.
- **No sub-cell vocabulary of any kind**; the fallback is an ellipsis character.
- **`Crop` composes awkwardly**: `cropLeft` bumps an existing `Crop`'s `leftSkip` in
  one branch and wraps a new node in another — the two paths the interpreter comment
  singles out. **Padding is materialised as `BGFill` nodes**, so the tree grows with
  adjustments that changed nothing visible.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                              | Trade-off                                                                                      |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Cache `outputWidth`/`outputHeight` in every constructor | Layout asks for extent constantly; a traversal per query is quadratic over a deep tree | Every constructor must maintain it; joins must pad to keep the cached number honest            |
| Normalise joins by inserting `BGFill` padding           | Keeps the cached extent meaningful and the blitter's arithmetic uniform                | The tree grows nodes that draw nothing; equality distinguishes trees that render identically   |
| Export `Image` abstractly, hide the constructors        | Smart constructors are the only place the invariants can be enforced                   | Consumers cannot pattern-match a scene or write a new lowering outside the library             |
| Six structural cases, zero semantic ones                | One target class — no backend would degrade a widget differently                       | Every widget concept must be rebuilt above the seam, per consumer (which is Brick's whole job) |
| Lower to a _different_, flat three-case op vocabulary   | Output is row-major and linear; a tree is the wrong shape for byte emission            | Two vocabularies to keep in sync; the lowering pass carries all the difficulty                 |
| Measure via a global, terminal-negotiated width table   | Toolkit and terminal must agree on a width or output desynchronises                    | Process-global mutable state; one install per process; no per-device measurement               |
| Capability as mandatory data fields on `Output`         | A backend cannot forget to answer; the framework can degrade centrally                 | Adding a capability is a breaking change to every platform package                             |
| Own all payloads; keep the previous frame's ops         | Enables the row diff that makes redraw cheap                                           | Allocation per join in the coalescing case; the previous frame is retained for the app's life  |

## Bearing on the proposal

1. **Maintain extent at construction, and stop treating friction §8 as a query
   problem.** `skia-canvas-render.d` folds `op.rect` over the whole stream to get a
   bounding box, because neither `CmdBuffer` — which reports `length` and a run's
   `measure`, and nothing about painted bounds — nor the display list nor the arena
   carries one. The answer is not an `extent()` method on the seam but a
   `buildDisplayList` that hands back the extent it already knew while emitting. Vty
   prices that at one addition per composition. This puts us on
   [F7][comparison]'s derived-by-scan pole and Vty on the other one, on the same axis
   and for a cheaper price.
2. **Q4's remaining half is the constructor boundary, not the sum.** `DrawOp` is
   already the closed sum [F3][comparison] argues for; what Vty adds is that publicly
   constructible cases leave the invariants as conventions — `rect.width` is the
   advance in cells, a `popClip` matches a `pushClip`, and nothing in the type says so.
   Make the `CmdBuffer` emitters the only way in.
3. **Carry both units on a text op.** `HorizText` caches `outputWidth` _and_
   `charWidth`, and `sparkles:ui` needs the same pair the moment a cursor or a
   selection has to be placed in a proportional-font backend. `TextRun` carries one
   rectangle in cells and nothing else, which is friction §1 seen from the cursor's
   end. This is [F2][comparison]'s _return shape_ decision, and it should be settled
   together with the unit rather than after it.
4. **Oracle authority may differ between the two ends.** Vty's measurement is a global
   oracle negotiated against the device precisely so two consumers _cannot_ disagree.
   A per-backend `Font::Length` (Slint's model) is right for the GPU end and wrong for
   the terminal end, where the device's width table is authoritative. That is evidence
   on [F2][comparison]'s second decision, and for the umbrella's open question — the
   two ends may want different measurement ownership, which is a reason to doubt one
   seam.
5. **Put device narrowing in one framework function.** `limitAttrForDisplay` is the
   model for friction §6: resolve to one channel early, then clamp against the
   backend's _declared_ capability in a single place, so no backend re-implements
   degradation. Combine with [F5][comparison]'s floor — a stated minimum plus a
   refusable degrade is what lets the clamp read a capability instead of guessing at
   one.
6. **Zero semantic operations is a live option, but only at Vty's target count.**
   [F4][comparison] frames the axis as where the lowering lives; Vty adds that a seam
   with one target class has only one place to put it, so semantics buy nothing.
   `sparkles:ui` has three backends that degrade a scrollbar three ways, so the option
   is not open — but this is why `scrollbar`, with its fourteen fields including the
   two cell glyphs every pixel backend ignores (friction §3), should be justified by
   _backend divergence_ and by nothing else.
7. **The reified result must be ownable to be diffable, and which arena builds it
   decides that.** Vty's redraw optimisation is `Vector.zipWith (/=)` against the
   previous frame's ops. `DrawOp` compares fine, so the obstacle is never equality: it
   is that a `FrameArena` stream stops being readable at `reset()`, while a `GcArena`
   one does not. Anyone reaching for a cross-frame diff is choosing the second arena
   and paying GC ownership for it (friction §7, `UI-O4`).
8. **Expect the traversal to absorb the complexity the data sheds.** Vty's algebra is
   beautiful and its blitter is "too touchy". A `sparkles:ui` display list that gets
   more structural will move work into `interp/immediate.paint`; budget for it and
   test it the way `VerifyImageOps.hs` tests the laws — property tests over the
   algebra, not goldens over the output.

## Sources

- [`src/Graphics/Vty/Image/Internal.hs`][internal] — the `Image` sum type, cached
  extent fields, `horizJoin`/`vertJoin`, the `Monoid` instance, `clipText`.
- [`src/Graphics/Vty/Image.hs`][image-hs] — the exported combinator surface: `text`,
  `crop*`, `pad`, `translate*`, `resize*`, `horizCat`/`vertCat`.
- [`src/Graphics/Vty/Picture.hs`][picture-hs] — `Picture`, `Cursor`, `Background`;
  [`src/Graphics/Vty/Span.hs`][span-op] — `SpanOp`, `DisplayOps`, `splitOpsAt`.
- [`src/Graphics/Vty/PictureToSpans.hs`][p2s-entry] — the lowering, `BlitState`,
  layer merging, background substitution.
- [`src/Graphics/Vty/Output.hs`][output-record] — the `Output` backend record,
  `outputPicture`'s row diff, `limitAttrForDisplay`.
- [`src/Graphics/Text/Width.hs`][width-hs], [`cbits/mk_wcwidth.c`][cbits] and
  [`UnicodeWidthTable/Install.hs`][install] — measurement FFI, global table, one-shot
  install; [`README.md`][readme] — the multi-column rationale.
- [`tests/programs/VerifyImageOps.hs`][verify] — the algebraic laws as QuickCheck
  properties.
- Related deep-dives: [Notcurses][notcurses] (the sub-cell alternative),
  [Ratatui][ratatui] (the other cell-only seam), [GTK4/GSK][gtk4] and
  [Skia][skia] (the other two Q8 data points), and
  [Brick][brick] in the TUI-libraries catalog (the consumer of this algebra).

<!-- References -->

[rev]: https://github.com/jtdaugherty/vty/tree/2650dc859cdbc2892ba211d0ed337b2c1537c3e1
[repo]: https://github.com/jtdaugherty/vty
[hackage]: https://hackage.haskell.org/package/vty
[cabal]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/vty.cabal
[vty-hs]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty.hs
[internal]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Image/Internal.hs
[internal-extent]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Image/Internal.hs#L154-L170
[internal-join]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Image/Internal.hs#L192-L215
[internal-cliptext]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Image/Internal.hs#L30
[image-hs]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Image.hs
[image-text]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Image.hs#L121
[image-translate]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Image.hs#L257-L271
[picture-hs]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Picture.hs
[span-op]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Span.hs#L37
[p2s-entry]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/PictureToSpans.hs#L89
[p2s-touchy]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/PictureToSpans.hs#L244
[p2s-swap]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/PictureToSpans.hs#L179
[output-hs]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Output.hs
[output-record]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Output.hs#L61
[output-picture]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Output.hs#L217
[output-limit]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/Output.hs#L340
[width-hs]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Text/Width.hs#L29
[cbits]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/cbits/mk_wcwidth.c
[install]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/src/Graphics/Vty/UnicodeWidthTable/Install.hs
[verify]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/tests/programs/VerifyImageOps.hs
[readme]: https://github.com/jtdaugherty/vty/blob/2650dc859cdbc2892ba211d0ed337b2c1537c3e1/README.md
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[comparison]: ./comparison.md
[notcurses]: ./notcurses.md
[ratatui]: ./ratatui.md
[gtk4]: ./gtk4-gsk.md
[skia]: ./skia-skpicture.md
[brick]: ../tui-libraries/brick.md
