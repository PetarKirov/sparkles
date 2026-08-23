# Gloss `Picture` — the scene _is_ the seam, and it is fifteen constructors

**Category:** pure sum-type scene. **Last reviewed:** August 23, 2026.
Pinned at [`ca666dc7`][rev].

The purest form of the encoding [`comparison.md`](./comparison.md)'s **F3**
weighs `DrawOp` against: a scene described entirely by one algebraic data
type, small enough to read in a single screen, with no renderer abstraction of
any kind underneath it. Gloss has exactly one renderer — OpenGL — so it is on
this list for its _data type_, not for its portability, and half the survey's
questions do not arise for it. Where it does have an answer, the answer is
unusually clean, because nothing in the design is hedging against a second
backend.

| Field                  | Value                                                                                                 |
| ---------------------- | ----------------------------------------------------------------------------------------------------- |
| **Language**           | Haskell                                                                                               |
| **License**            | MIT ([`gloss.cabal`][cabal])                                                                          |
| **Repository**         | [`benl23x5/gloss`][repo]                                                                              |
| **Documentation**      | Haddocks in-tree; [`Graphics.Gloss`][gloss-hs] is the entry module                                    |
| **Category**           | pure sum-type scene                                                                                   |
| **Pinned revision**    | [`ca666dc7ca09beca9c0be3aad177385e224d8919`][rev]                                                     |
| **Version at pin**     | `gloss` 1.13.2.2, `gloss-rendering` 1.13.2.1 ([`gloss.cabal`][cabal])                                 |
| **Seam type**          | `data Picture` — 15 constructors ([`Internals/Data/Picture.hs`][picture])                             |
| **Renderers shipped**  | one (OpenGL, [`Internals/Rendering/Picture.hs`][render])                                              |
| **Windowing backends** | two (GLUT, GLFW) — a `class Backend` that explicitly excludes drawing ([`Backend/Types.hs`][backend]) |

## Overview

### What it solves

Gloss is a teaching-and-demos 2D vector library whose entire public drawing API
is one data type plus a handful of `display`/`animate`/`simulate`/`play`
drivers. Its own summary:

> Gloss hides the pain of drawing simple vector graphics behind a nice
> data type and a few display functions. Gloss uses OpenGL under the hood, but
> you won't need to worry about any of that. Get something cool on the screen in
> under 10 minutes.
>
> — [`gloss.cabal`][cabal], `Description`

The `Description` field is the design statement: the abstraction boundary is a
**value**, not an interface. A user program is a pure function
`world -> Picture`; the impure part is a single interpreter that pattern-matches
that value into GL calls.

### Design philosophy

The split is enforced by package boundaries. `gloss-rendering` "picture data
types and rendering functions … don't do any window management"
([`gloss-rendering.cabal`][rcabal]), and the windowing abstraction that _does_
exist is documented as knowing nothing about drawing:

> The Backend module interfaces with the window manager, and handles opening
> and closing the window, and managing key events etc.
>
> It doesn't know anything about drawing lines or setting colors.
>
> — [`Backend/Types.hs`][backend], the Haddock on `class Backend`

So Gloss has a class-based seam, and it deliberately put drawing on the other
side of it. Drawing is a data type consumed by one concrete function.

## How it works

### The seam's defining declaration

```haskell
data Picture
        -- Primitives -------------------------------------
        = Blank
        | Polygon       Path
        | Line          Path
        | Circle        Float
        | ThickCircle   Float Float
        | Arc           Float Float Float
        | ThickArc      Float Float Float Float
        | Text          String
        | Bitmap        BitmapData
        | BitmapSection Rectangle BitmapData
        -- Color ------------------------------------------
        | Color         Color           Picture
        -- Transforms -------------------------------------
        | Translate     Float Float     Picture
        | Rotate        Float           Picture
        | Scale         Float   Float   Picture
        -- More Pictures ----------------------------------
        | Pictures      [Picture]
        deriving (Show, Eq, Data, Typeable)
```

— [`Internals/Data/Picture.hs`][picture]

Ten leaf constructors, four **wrapper** constructors (`Color`, `Translate`,
`Rotate`, `Scale`), and one **branch** constructor (`Pictures`). Every field is
live for its constructor; there is no tag-plus-dead-fields anywhere. `Path` is
`[(Float, Float)]` and `Point`/`Vector` are the same tuple — the geometry
vocabulary is three type synonyms.

Two structural properties `sparkles:ui`'s [`DrawOp`][canvas] lacks:

1. **Transform and style are nodes, not fields.** `Color col p` and
   `Translate x y p` each wrap a child. An op never carries a colour it did not
   need, and a subtree is moved by wrapping it rather than by rewriting each
   member.
2. **The scene is a tree.** `Pictures [Picture]` makes composition
   structural, and the `Monoid`/`Semigroup` instances make it the standard
   Haskell one: `mempty = Blank`, `a <> b = Pictures [a, b]`, `mconcat =
Pictures` ([`Internals/Data/Picture.hs`][picture]).

### The interpreter

There is a single consumer of the type in the whole repository:

```haskell
drawPicture :: State -> Float -> Picture -> IO ()
```

— [`Internals/Rendering/Picture.hs`][render]

`State` holds four booleans and a texture cache
([`Internals/Rendering/State.hs`][state]); the `Float` is "view port scale,
which controls the level of detail" ([`Rendering.hs`][rendering]). Wrapper
nodes are handled by recursion into the child with the GL state changed around
it — `Color` saves and restores `GL.currentColor`, `Translate`/`Rotate`/`Scale`
use `GL.preservingMatrix`, and `Pictures ps` is `mapM_ (drawPicture state
circScale) ps`.

Because transforms are nodes, the interpreter can pattern-match _compositions_
and shortcut them:

```haskell
        -- Easy translations are done directly to avoid calling GL.perserveMatrix.
        Translate posX posY (Circle radius)
         -> renderCircle posX posY circScale radius 0

        Translate tx ty (Rotate deg p)
         -> GL.preservingMatrix
          $ do  GL.translate (GL.Vector3 (gf tx) (gf ty) 0)
                GL.rotate    (gf deg) (GL.Vector3 0 0 (-1))
                drawPicture state circScale p
```

— [`Internals/Rendering/Picture.hs`][render]

That peephole is only available to a tree. A flat op array has already lowered
`Translate (Circle …)` to an absolute-coordinate circle before the backend sees
it, so there is nothing left to recognise — the toolkit did the optimisation,
once, for every backend. **This is the clearest statement of the trade: a tree
gives the backend structure to exploit; a flat array gives it work already
done.**

## Q1 — measurement unit, and who answers

**Not answerable by construction, and this is the finding.** `Text` carries a
bare `String`: no font, no size, no metrics. Its entire rendering is two lines:

```haskell
        Text str
         -> do  GL.blend        $= GL.Disabled
                GL.preservingMatrix $ GLUT.renderString GLUT.Roman str
                GL.blend        $= GL.Enabled
```

— [`Internals/Rendering/Picture.hs`][render]

The font is `GLUT.Roman`, a stroke font compiled into GLUT, and it is the only
one. A grep of the tree at this revision finds `renderString` at exactly one
site and `stringWidth` — GLUT's own metric query — at none. There is no
`Picture -> Size` function, no metrics module, and no place for a caller to ask
how wide `Text "Hello World"` is.

The consequence shows up in the shipped examples as hand-tuned constants:

```haskell
picture :: Picture
picture
        = Translate (-170) (-20) -- shift the text to the middle of the window
        $ Scale 0.5 0.5          -- display it half the original size
        $ Text "Hello World"     -- text to display
```

— [`gloss-examples/picture/Hello/Main.hs`][hello]

`-170` is the measurement, done by eye, baked into the program. Text is sized
by wrapping it in `Scale`, which is a fidelity-preserving transform on a stroke
font and therefore _almost_ free of the problem — the string still cannot be
centred, boxed, wrapped, or laid out beside anything.

> [!IMPORTANT]
> This is what a single-backend design can get away with, and it bounds the
> claim in **F1**. F1 says measurement does not belong on the painter; Gloss
> agrees by not having measurement at all. But the reason it can is that its
> font is a compile-time constant of its one renderer. `sparkles:ui` has three
> backends that genuinely disagree about advance width, so the option Gloss
> took — omit the query — is closed to us. Gloss strengthens F1's negative half
> ("not on the painter") and says nothing about where it should go instead.

## Q2 — is the contract stated in one place?

**Yes, and completely — because the contract is a closed data type.** `Picture`
is exported with all constructors (`Picture(..)`, [`Data/Picture.hs`][api]), so
a would-be consumer reads fifteen cases and knows the surface exactly. Haskell's
exhaustiveness checking turns "did you handle everything" into a compiler
warning rather than a documentation problem. Compare
[friction §2](../../specs/ui-skia/canvas-seam-friction.md): `isCanvas` names five
methods, four further primitives are discovered by `__traits(compiles)` at each
interpreter call site, and the eight kinds a caller can ask about are derived
from the payload rather than read off the concept. Deriving `OpKind` from the
sum is **F11** working — the two cannot disagree — but the optional four are
the part of the surface no single statement covers, which is the same finding
pointing at the gap.

The cost is the other half of the bargain: because the type is closed and total,
**there is no optionality at all**. There is no capability query, no default,
no degrade hook. A backend that cannot render `ThickArc` has no way to say so;
it must render something. Gloss never pays for this because it has one backend,
but the structure is worth naming: a closed sum type states the contract
perfectly and provides no vocabulary for a backend to decline part of it.

The most telling absence is clipping. There is **no clip node**, and a
case-insensitive grep for `clip` or `scissor` across `gloss` and
`gloss-rendering` at this revision returns nothing. The only bounded region is
the window's orthographic projection, set once per frame from the window size
([`Internals/Rendering/Common.hs`][common], `withModelview`). A scene cannot
express "confine this subtree" — so `sparkles:ui`'s optional `pushClip`/`popClip`
pair has no analogue here, and Gloss cannot advise on **F5**. Our clip pair is
the cheapest case of the optional-primitive ladder anyway: a backend that
supplies neither method paints unclipped and loses nothing, because the display
list culls the hidden subtrees before any backend sees them.

## Q3 — semantic widgets, or primitives?

**Primitives, exclusively, with no widget layer above them.** Every constructor
is geometry (`Polygon`, `Line`, `Circle`, `Arc`), pixels (`Bitmap`) or a
transform. Nothing in `Picture` knows what a button, a scrollbar or a focus ring
is, and `Graphics.Gloss.Data.Picture` ([`Data/Picture.hs`][api]) offers only
compound _shape_ helpers — `rectangleSolid`, `lineLoop`, `sectorWire`,
`circleSolid` — each defined as a plain function returning a `Picture`, e.g.
`circleSolid r = thickCircle (r/2) r`.

That is the structural point worth carrying into
[friction §3](../../specs/ui-skia/canvas-seam-friction.md): in Gloss the
"semantic" layer is **ordinary functions that build values**, not extra
constructors. `circleSolid` is a widget-shaped helper that costs the seam
nothing, because the seam is a type and the helper is above it. A `Scrollbar`
arm costs every backend; a function returning a `DrawOp[]` — over
`scrollbarThumb` and the `scrollbarCellCount`/`scrollbarCell` lowerings
[`canvas.d`][canvas] re-exports — costs none. Gloss does not disprove
**F4**'s claim that semantic ops are legitimate; it is the clean instance of one
of the six places F4 names a lowering can live — **the widget: a shared function
lowers the composite before any backend sees it, so no backend degrades
anything.**

Gloss can afford that because it has no backend that would degrade differently.
`sparkles:ui` does — which is exactly the argument for keeping `scrollbar`
semantic, and it should be made on that ground rather than by default.

## Q4 — command shape

**A sum type, and the survey's cleanest example of one.** `Picture` is what
[`sparkles.input.events`][events] argues for and what `DrawOp` is: a closed sum
over per-kind payloads, so illegal combinations are unrepresentable and every
field is live for the arm that carries it. `deriving (Show, Eq, Data, Typeable)`
then gives structural equality, a printable form and generic traversal for free,
where D's `SumType` gives comparison and a `match!` and leaves the rest to the
consumer.

Two axes are separable, and Gloss picks the far end of both:

| Axis      | Gloss                       | `DrawOp`                       | What each buys                                                         |
| --------- | --------------------------- | ------------------------------ | ---------------------------------------------------------------------- |
| Width     | per-constructor             | uniform, `sizeof <= 64` budget | an exact fit vs. an array of equal-stride, index-addressable values    |
| Structure | tree (`Pictures`, wrappers) | flat `DrawOp[]`                | no redundant style/transform per op; O(1) subtree wrap; peephole match |

**F3 weighs the first and is silent on the second.** They are independent:
`sparkles:ui` takes the uniform-width sum and the flat array together, and Gloss
is the evidence for what the second of those leaves on the table. The flat
array's payoff is concrete and load-bearing here:

- `RecordingCanvas` ([`canvas.d`][canvas]) collects a `DrawOp[]` — the op-stream
  parity harness diffs two backends' _painted_ sequences, which is **F12**'s
  reason for reifying at all: the stream earns its keep as the cross-target
  oracle, not as an artifact anyone stores. Gloss's `Eq` compares
  two scenes **as authored**, which is a different and weaker property: two
  `Picture`s that paint identically can differ structurally (`Pictures [a, b]`
  vs `Pictures [Pictures [a], b]`), and one that paints differently can compare
  equal only if the interpreter is nondeterministic, which it is not.
- Iteration and culling are linear and index-addressable over an array; over a
  tree they are a traversal with an accumulated transform, and **no node can be
  interpreted out of context**. `drawPicture` must carry `circScale` down the
  recursion precisely because a `Circle`'s on-screen size is not knowable from
  the `Circle` node.

And the tree's structural cost is documented in-tree, as an error message:

> This program uses the Gloss vector graphics library, which tried to draw a
> picture using more nested transforms (Translate/Rotate/Scale) than your OpenGL
> implementation supports. The OpenGL spec requires all implementations to have
> a transform stack depth of at least 32 …
>
> — [`Internals/Rendering/Picture.hs`][render], `handleError`

Nesting depth is a resource, and the seam exposes the backend's limit to the
application author with no way to query or flatten it. A flat array has no such
failure mode.

## Q5 — sub-unit placement

**Does not arise: coordinates are `Float` throughout**, so Gloss joins Slint,
Qt and egui on the continuous side of **F6** — which finds that continuity
relocates the sub-unit problem rather than dissolving it. Gloss adds something
the other three do not, and it bears directly on F6's answer, a named fidelity
plus a queried device unit: Gloss names **no** fidelity, and derives it from the
accumulated transform instead.

```haskell
-- | Decide how many line segments to use to render the circle.
--   The number of segments we should use to get a nice picture depends on
--   the size of the circle on the screen, not its intrinsic radius.
--   If the viewport has been zoomed-in then we need to use more segments.
circleSteps :: Float -> Int
circleSteps sDiam
        | sDiam < 8     = 8
        | sDiam < 16    = 16
        | sDiam < 32    = 32
        | otherwise     = 64
```

— [`Internals/Rendering/Circle.hs`][circle]

`Scale sx sy p` recurses with `circScale * max sx sy`
([`Internals/Rendering/Picture.hs`][render]), so a subtree's device size is
known at the point of painting, and the backend degrades on it — including the
floor case, commented "If the circle is smaller than a pixel, render it as a
point", which renders `GL.Points` instead of a ring
([`Circle.hs`][circle]).

That is a fidelity ladder like Notcurses's blitters, but **implicit**: the scene
says nothing, the backend measures the accumulated scale and picks. It only
works because transforms are nodes — a flat array of absolute coordinates
carries no scale factor by the time the backend runs, leaving the
backend to infer fidelity from a rect's size, which is what
`skia-canvas-render.d` does for extent
([friction §8](../../specs/ui-skia/canvas-seam-friction.md)) and is equally
fragile.

## Q6 — resolved appearance, semantic role, or both

**Resolved only, and as a node rather than a field.** `Color` wraps a subtree
with an RGBA value ([`Internals/Data/Picture.hs`][picture]); there is no slot,
role, theme or class name anywhere in the type. So Gloss pays once, like Slint,
and for the same reason — no backend re-resolves.

Two consequences are specific to the node encoding and worth noting against
[friction §6](../../specs/ui-skia/canvas-seam-friction.md):

- **Colour is inherited, not carried.** A leaf under no `Color` node has no
  colour of its own; it uses whatever `GL.currentColor` the enclosing scope set,
  saved and restored around the recursion. Each `DrawOp` payload stores the
  resolved appearance its own primitive paints from — an `Ink` for the four
  content primitives, colour fields plus a `const(BoxChrome)*` for a fill —
  because a flat array has no enclosing scope to inherit from. That half of §6
  is a consequence of flatness, not of hedging; the hedge is the `Slot` stored
  beside it on six of the eight payloads.
- **The backend may ignore the node entirely.** `stateColor`/`stateWireframe`
  ([`State.hs`][state]) turn `Color` into a no-op and `Polygon` into a
  `GL.LineLoop`. A style node the backend can globally disable is a much cheaper
  place to put a debug mode than a per-op field.

## Q7 — payload ownership and lifetime

**The scene owns everything, and outliving the frame is the normal case.**
`Text` holds a Haskell `String` and `Path` a list of tuples — immutable,
garbage-collected, freely retained and shared across threads. A `Picture` is a
value; the drivers build a fresh one per frame from
`world -> Picture` and keep no reference. That retention is what
[friction §7](../../specs/ui-skia/canvas-seam-friction.md) records `DrawOp.text`
cannot do: the bytes are copied into a frame arena, and an operation is valid
while the buffer that built it is alive and unreset. Gloss buys unlimited
retention not by interning or reference-counting but from the language, and it
pays for it in a garbage collector our `@nogc` display-list walk does not have.

The interesting case is `Bitmap`, and it lands squarely inside **F8**'s
observation that no subject borrows a payload across a frame. `BitmapData`
carries a `ForeignPtr Word8` and a `bitmapCacheMe` flag, documented as "The
boolean flag controls whether Gloss should cache the
data between frames for speed. If you are programatically generating the image
for each frame then use `False`" ([`Internals/Data/Picture.hs`][picture]). The
renderer keeps `stateTextures :: !(IORef [Texture])` ([`State.hs`][state]) and
looks a texture up by **object identity**:

```haskell
        name            <- makeStableName imgData
        let mTexCached
                = find (\tex -> texName   tex == name
                             && texWidth  tex == width
                             && texHeight tex == height)
                textures
```

— [`Internals/Rendering/Picture.hs`][render], `loadTexture`

A **backend-owned cache keyed by payload identity**, with the scene supplying a
per-payload hint about whether caching is worth it — Slint's
`draw_cached_pixmap` in a different language, arrived at independently. The
`freeTexture` counterpart deletes the GL object immediately when `cacheMe` is
false. F8 is confirmed by a second, unrelated subject, and this is the
mechanism `sparkles:ui` has no image analogue of: `UI-O4` stays open on exactly
the retain boundary a `cacheMe` hint answers.

## Q8 — extent query

**None, and the question is answered on the surface side.** There is no
`Picture -> Rectangle`; the only function in the tree with a `Picture -> …`
signature besides the renderer is `applyViewPortToPicture`
([`ViewPort.hs`][viewport]). Extent comes from `Display`
([`Display.hs`][display]) — `InWindow String (Int, Int) (Int, Int)` or
`FullScreen` — and at paint time from the window manager, through
`getWindowDimensions :: IORef a -> IO (Int, Int)` on `class Backend`
([`Backend/Types.hs`][backend]), which the drivers call each frame and hand to
`withModelview` ([`Common.hs`][common]).

**F7** separates three extent questions — surface, layout and ink — and Gloss
answers exactly one of them: the surface declares itself, and nothing in the
library answers the other two. Gloss adds the detail that the extent flows from
the _window system_ rather than from the renderer — which is why the query sits
on the windowing class that "doesn't know anything about drawing".

Gloss also shows the price of having no scene extent. Because the projection is
window-sized and origin-centred, a `Picture` that does not fit is simply
cropped, silently — the same failure
[friction §8](../../specs/ui-skia/canvas-seam-friction.md) records, and it went
unfixed for the library's whole life because it is invisible in a live window
and only bites an offscreen consumer. Gloss has no offscreen consumer.

## Strengths

- **The contract is a closed, exported, exhaustively-checkable data type.** A
  reader learns the whole seam in one screen; a consumer that misses a case gets
  a compiler warning.
- **No dead fields anywhere.** Every constructor's arguments are live for that
  constructor — the property `sparkles.input.events` argues for, and the one a
  closed sum buys in either language.
- **Free structural equality, printing and generic traversal** from
  `deriving (Show, Eq, Data, Typeable)` — recording and comparison need no
  purpose-built harness.
- **Style and transform cost nothing when unused**, because they are wrapper
  nodes rather than fields on every op.
- **O(1) global transform.** `applyViewPortToPicture = Scale … . Rotate … .
Translate …` ([`ViewPort.hs`][viewport]) pans and zooms an arbitrarily large
  scene by allocating three nodes.
- **Fidelity derived, not declared.** The backend picks segment counts from the
  accumulated scale, so the scene stays resolution-independent with no fidelity
  vocabulary at all.
- **Backend-owned texture cache keyed by identity**, with a scene-side caching
  hint.

## Weaknesses

- **Text is unmeasurable by construction**, so nothing above the seam can lay
  text out; example programs hard-code pixel offsets.
- **No optionality vocabulary.** No capability query, no default, no way for a
  backend to decline a constructor — invisible with one renderer, fatal with
  three.
- **No clipping**, at all.
- **Nesting depth is a backend resource** exposed to application authors as a
  runtime error with no query and no flattening pass.
- **No node is interpretable out of context** — the accumulated transform lives
  in the traversal, so subtrees cannot be cached, culled or diffed
  independently.
- **Structural equality is not painting equality**: `Pictures [Pictures [a], b]`
  ≠ `Pictures [a, b]` as values, though they paint the same. A tree gives
  comparison for free but not the comparison a parity harness wants.
- **No extent query**, so offscreen use silently crops.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                                            | Trade-off                                                                                      |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Seam is a data type, not a class                        | A pure `world -> Picture` is the whole user API; the impure part is one pattern match                | Only one renderer can exist without a rewrite; no capability negotiation is expressible        |
| Transform and colour as wrapper nodes                   | No redundant style per primitive; a subtree is re-styled or moved in O(1)                            | Every leaf must be interpreted in traversal context; nesting depth becomes a GL stack resource |
| `Pictures [Picture]` tree with a `Monoid` instance      | Composition is the language's, not the library's                                                     | No index addressing, no cheap culling, and structural equality diverges from painting equality |
| `Text String` with no font or size                      | One compiled-in stroke font; `Scale` covers sizing                                                   | Measurement is impossible, so no layout above the seam                                         |
| No clipping constructor                                 | The window's ortho projection is the only bound anyone needed                                        | Scrolling panes and bounded subtrees have no expression at all                                 |
| Fidelity from accumulated scale (`circScale`)           | "size on the screen, not intrinsic radius" — the backend knows the device, the scene doesn't         | Only works while transforms remain nodes; a pre-flattened stream has thrown the scale away     |
| `bitmapCacheMe` hint + `StableName`-keyed texture cache | The party that knows a payload's lifetime (the author) hints; the party that owns GPU memory decides | Identity-keyed caching is sensitive to how the payload value is constructed and shared         |
| Extent from `Display`/the window manager                | The surface that will be painted knows its own size                                                  | An offscreen or content-sized consumer has no answer, and over-large scenes crop silently      |

## Bearing on the proposal

1. **Keep the flat array, and reject the tree on the record.** Gloss holds the
   far end of the encoding trade **F3** describes — but encoding and _structure_
   are independent choices, and F3 weighs only the first. A sum in a `DrawOp[]`
   keeps `RecordingCanvas`, the op-stream parity harness, linear culling and
   index addressing, and gives up only the redundancy the tree avoids. Say so
   explicitly in the proposal, so the tree is rejected by argument rather than
   by omission ([friction §4](../../specs/ui-skia/canvas-seam-friction.md)).
2. **Lower composites with a shared function, not with an op kind, wherever
   every backend would degrade the same way.** Gloss's `circleSolid`/`sectorWire`
   are the pattern: widget-shaped helpers above the seam that cost it nothing.
   That is the widget slot in **F4**'s list of six places a lowering can live.
   `Scrollbar` should stay an arm only if the cell and pixel degradations
   genuinely differ — which they do — but the fourteen fields on that payload,
   which exist so each backend can _re-derive_ the same rail geometry from
   `scrollbarThumb`, are the part this argues against, and they are exactly the
   derived geometry F4 says the seam should not carry
   ([friction §3](../../specs/ui-skia/canvas-seam-friction.md)).
3. **Resolved appearance on every payload is a cost of flatness, not of
   hedging.** Gloss pays nothing for style because `Color` is a scope. While
   `DrawOp` is flat, each payload's `Ink` or fill colours are the price of that
   decision and should be defended as such. What
   [friction §6](../../specs/ui-skia/canvas-seam-friction.md) actually records
   is the `Slot` carried beside them, and **F9** says which way that decision
   goes if it is ever made: resolved appearance follows from a role plus a
   theme, and a role does not follow from resolved appearance.
4. **A closed sum type states the contract but provides no optionality.** This
   sharpens **F5**: `DrawOp`'s sum answers
   [friction §2](../../specs/ui-skia/canvas-seam-friction.md)'s "what are the
   kinds" half and says nothing about the "which can this backend do" half,
   which the interpreter still asks one `__traits(compiles)` at a time. They
   need separate mechanisms — F5's floor / defaulted / refusable ladder is the
   one for the second — and Gloss, having neither problem, is proof only of the
   first.
5. **F8 confirmed again, independently.** A backend-owned cache keyed by payload
   identity, plus a scene-side "is this worth caching" hint, is the shape to copy
   for images at [friction §7](../../specs/ui-skia/canvas-seam-friction.md), and
   it answers the retain-boundary question `UI-O4` holds open for text. Two
   subjects reached it without contact.
6. **F7's surface question, answered — and the other two left open.** Extent
   comes from the window manager here, which is the surface question settled at
   the cheapest possible price. But Gloss also demonstrates the exact
   failure mode `skia-canvas-render.d` guards against by scanning every
   operation's rect — a scene larger than the surface crops silently. `CmdBuffer`
   reports an operation count and a run's cell extent, so a caller that wants
   painted bounds folds `op.rect` itself: the derived-by-scan end of F7's axis,
   with nothing maintained at construction. Gloss shows that a silent crop can
   persist indefinitely in a project that only ever paints into a live
   window. The offscreen case is the one that needs a layout answer, and it
   needs it because it is the one where the crop is invisible
   until a golden pins it
   ([friction §8](../../specs/ui-skia/canvas-seam-friction.md)).
7. **F1's negative half is unanimous; its positive half is untested here.**
   Gloss makes text measurement structurally impossible and ships anyway, which
   is only survivable for a single-backend library with a compiled-in stroke
   font. It reinforces "not on the painter" and offers no evidence for where
   measurement should live.

> [!NOTE]
> **What Gloss cannot answer.** It has one renderer, so nothing here is evidence
> about multi-backend negotiation, degradation policy, or whether a terminal and
> a GPU can share a seam. Q2's optionality half, Q5's cell-target half and all of
> **F5** are outside what this subject can speak to. Its value is that the
> _shape_ of a pure sum-type scene is visible in full, undistorted by any
> compromise made for a second backend.

## Sources

Read at [`ca666dc7ca09beca9c0be3aad177385e224d8919`][rev]; every path below was
verified to exist at that revision.

- [`gloss-rendering/Graphics/Gloss/Internals/Data/Picture.hs`][picture] — the
  `Picture` declaration, the `Monoid`/`Semigroup` instances, `BitmapData` and
  the `cacheMe` flag.
- [`gloss-rendering/Graphics/Gloss/Internals/Rendering/Picture.hs`][render] —
  `drawPicture`, the transform peepholes, the `Text`/`GLUT.Roman` call site,
  `loadTexture`/`freeTexture`, the transform-stack error text.
- [`gloss-rendering/Graphics/Gloss/Internals/Rendering/State.hs`][state] —
  `State`, `stateColor`/`stateWireframe`, `stateTextures`.
- [`gloss-rendering/Graphics/Gloss/Internals/Rendering/Circle.hs`][circle] —
  `circleSteps`, the sub-pixel point fallback.
- [`gloss-rendering/Graphics/Gloss/Internals/Rendering/Common.hs`][common] —
  `withModelview`, `withClearBuffer`.
- [`gloss-rendering/Graphics/Gloss/Rendering.hs`][rendering] — `renderPicture` /
  `displayPicture` signatures and the "level of detail" parameter.
- [`gloss/Graphics/Gloss/Data/Picture.hs`][api] — constructor aliases and the
  compound-shape helpers.
- [`gloss/Graphics/Gloss/Data/ViewPort.hs`][viewport] —
  `applyViewPortToPicture`, `invertViewPort`.
- [`gloss/Graphics/Gloss/Data/Display.hs`][display] — `Display`.
- [`gloss/Graphics/Gloss/Internals/Interface/Backend/Types.hs`][backend] —
  `class Backend` and its "doesn't know anything about drawing" Haddock.
- [`gloss-examples/picture/Hello/Main.hs`][hello] — the hand-tuned text offset.
- [`gloss/gloss.cabal`][cabal], [`gloss-rendering/gloss-rendering.cabal`][rcabal]
  — versions, licence, package-level descriptions.
- Local seam under study: [`libs/ui/src/sparkles/ui/canvas.d`][canvas],
  [`libs/input/src/sparkles/input/events.d`][events],
  [`canvas-seam-friction.md`](../../specs/ui-skia/canvas-seam-friction.md).

<!-- References -->

[repo]: https://github.com/benl23x5/gloss
[rev]: https://github.com/benl23x5/gloss/tree/ca666dc7ca09beca9c0be3aad177385e224d8919
[picture]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss-rendering/Graphics/Gloss/Internals/Data/Picture.hs
[render]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss-rendering/Graphics/Gloss/Internals/Rendering/Picture.hs
[state]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss-rendering/Graphics/Gloss/Internals/Rendering/State.hs
[circle]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss-rendering/Graphics/Gloss/Internals/Rendering/Circle.hs
[common]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss-rendering/Graphics/Gloss/Internals/Rendering/Common.hs
[rendering]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss-rendering/Graphics/Gloss/Rendering.hs
[api]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss/Graphics/Gloss/Data/Picture.hs
[viewport]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss/Graphics/Gloss/Data/ViewPort.hs
[display]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss/Graphics/Gloss/Data/Display.hs
[backend]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss/Graphics/Gloss/Internals/Interface/Backend/Types.hs
[gloss-hs]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss/Graphics/Gloss.hs
[hello]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss-examples/picture/Hello/Main.hs
[cabal]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss/gloss.cabal
[rcabal]: https://github.com/benl23x5/gloss/blob/ca666dc7ca09beca9c0be3aad177385e224d8919/gloss-rendering/gloss-rendering.cabal
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[events]: ../../../libs/input/src/sparkles/input/events.d
