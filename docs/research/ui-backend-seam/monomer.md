# Monomer — the seam as a value: 45 fields, no optional ones

**Category:** record-of-functions seam. **Last reviewed:** August 23, 2026.
Pinned at [`5c623936`][rev] (`monomer` 1.6.0.1, [`monomer.cabal`][cabal]).

A retained desktop widget toolkit in Haskell whose renderer seam is neither a
type class nor an interface but a **plain data record whose fields are
functions** — so a backend is a _value_ that can be constructed, passed, stored
in a sum type, or swapped at runtime. It is the dictionary-passing encoding of
the same contract [Slint][slint] states as a trait and `sparkles:ui` states as
the Design-by-Introspection concept [`isCanvas!T`][canvas], and reading all
three together separates what the contract says from how it is spelled.

| Field                | Value                                                                   |
| -------------------- | ----------------------------------------------------------------------- |
| **Language**         | Haskell (GHC), C shim under [`cbits/`][fmheader]                        |
| **License**          | BSD-3-Clause ([`monomer.cabal`][cabal])                                 |
| **Repository**       | [`fjvallarino/monomer`][rev]                                            |
| **Documentation**    | [Hackage][hackage]; in-tree [`docs/design-decisions.md`][design]        |
| **Category**         | record-of-functions seam                                                |
| **Pinned revision**  | `5c6239365e3a37686b6547bc91c29270ae5487c6`                              |
| **Target range**     | desktop GPU only — one window, one OpenGL context, via SDL2             |
| **Backends shipped** | **one**: `NanoVGRenderer.makeRenderer` ([`NanoVGRenderer.hs`][nanovgr]) |
| **Seam size**        | `Renderer` = 45 fields; `FontManager` = 6; `Widget` = 13                |

## Overview

### What it solves

Monomer is an Elm-architecture toolkit: an immutable widget tree is rebuilt
from a model, laid out, and painted. Painting is the only part of the widget
interface that is effectful, and the project says so explicitly — the entry in
[`design-decisions.md`][design] titled "Why, except for render, is the widget
interface non monadic?" answers:

> I find using regular functions nicer than using bind or do syntax and, given
> those functions do not rely on any effect, I preferred to keep them as such.

So the seam's job is not portability across devices. It is to be the **one
place effects enter**, with everything above it — layout, event handling, size
negotiation — staying pure functions of a `WidgetEnv`.

### Design philosophy

The record-of-functions choice is stated, and its stated reason is about
widgets rather than renderers ([`design-decisions.md`][design], "Why records of
functions instead of typeclasses?"):

> Since all widgets end up inside a list, the instances of those typeclasses
> would need to be wrapped in an existential, losing their specific types in the
> process.

`Renderer` follows the same house style as `Widget`, which is itself a
13-field record of functions ([`WidgetTypes.hs`][widgettypes]). The result is
uniform: everything polymorphic in Monomer is a record, and "an implementation"
is always a value you can hold.

The same document defends the unmaintained nanovg dependency partly on the
grounds that "It's also a kind of small library, which makes porting it to other
backends feasible" — portability as a latent property, not an exercised one.

## How it works

`Renderer` is declared once, in full, in [`Monomer/Graphics/Types.hs`][types].
Every field is a function returning `IO ()`; there is no class, no instance, no
existential wrapper:

```haskell
-- | Low level rendering definitions.
data Renderer = Renderer {
  -- | Begins a new frame.
  beginFrame :: Double -> Double -> IO (),
  -- | Sets, or intersects, a scissor which will limit the visible area.
  intersectScissor :: Rect -> IO (),
  -- | Sets the color of the next fill actions.
  setFillColor :: Color -> IO (),
  -- ... 41 further fields ...
  renderText :: Point -> Font -> FontSize -> FontSpace -> Text -> IO (),
  addImage :: Text -> Size -> ByteString -> [ImageFlag] -> IO ()
}
```

A backend is a function returning that value: `makeRenderer` creates the NanoVG
GL3 context plus an `IORef Env` of bookkeeping, then `RecordWildCards` turns a
`where` block of closures into the record ([`NanoVGRenderer.hs`][nanovgr]):

```haskell
newRenderer :: VG.Context -> Double -> IORef Env -> Renderer
newRenderer c rdpr envRef = Renderer {..} where
  beginPath  = VG.beginPath c
  stroke     = VG.stroke c
  setFillColor color = VG.fillColor c (colorToPaint color)
```

Two structural facts follow.

**The seam is nanovg's API transcribed.** `beginPath`, `closePath`,
`setPathWinding`, `renderQuadTo`, `renderBezierTo`, `setFillBoxGradient`,
`setStrokeImagePattern` are nanovg entry points with Monomer names; nearly
every field body is a single `VG.*` call plus unit conversion. The record is a
_purity_ and _interception_ boundary, not an abstraction over drawing models —
it was derived from one.

**The seam does not own the frame.** `renderWidgets` ([`Main/Core.hs`][maincore])
calls `glViewport`, `glClearColor`, `glClear` and `SDL.glSwapWindow` itself,
bracketing `beginFrame` / `widgetRender` / `endFrame` and then two further
passes (`renderRawTasks`, then `renderOverlays` inside a second frame, then
`renderRawOverlays`). A second `Renderer` implementation would still be executed
by a hard-coded OpenGL/SDL driver. The pinned tree holds exactly one production
implementation and one `mockRenderer` in the test utilities
([`TestUtil.hs`][testutil]).

## Q1 — measurement units, and who answers

**Measurement is not on the renderer.** It is a second record,
`FontManager`, declared in the same module ([`Types.hs`][types]):

```haskell
data FontManager = FontManager {
  computeTextMetrics :: Font -> FontSize -> TextMetrics,
  computeTextMetrics_ :: Double -> Font -> FontSize -> TextMetrics,
  computeTextSize :: Font -> FontSize -> FontSpace -> Text -> Size,
  computeTextSize_ :: Double -> Font -> FontSize -> FontSpace -> Text -> Size,
  computeGlyphsPos :: Font -> FontSize -> FontSpace -> Text -> Seq GlyphPos,
  computeGlyphsPos_ :: Double -> Font -> FontSize -> FontSpace -> Text -> Seq GlyphPos
}
```

Note the types: **no `IO`**. Measurement is pure, which is what lets the pure
`widgetGetSizeReq` call it. The purity is bought with `unsafePerformIO` around
an FFI call ([`FontManager.hs`][fontmgr]), and the context it drives is _not_
the renderer's: `fmInit` returns an `FMContext` ([`FFI.chs`][ffi]) backed by
[`cbits/fontmanager.c`][fmc], whose header says "Based on code from memononen's
... nanovg" and whose `struct FMcontext` holds a bare `FONScontext`
([`fontmanager.h`][fmheader]). Monomer forked nanovg's text path, deleted the GL
half and kept the shaping half, so **layout measures without a graphics context
at all**.

The consumer side is equally explicit: `WidgetEnv` carries
`_weFontManager :: FontManager` and has **no renderer field**
([`WidgetTypes.hs`][widgettypes]) — the `Renderer` appears only as the third
argument of `widgetRender`. Layout reaches metrics through the environment
([`Widgets/Util/Text.hs`][utext], [`Label.hs`][label]):

```haskell
  getSizeReq wenv node = (sizeW, sizeH) where
    Size w h = getTextSize_ wenv style mode trim targetW maxLines caption
```

The unit is `Double` — the same unit as `Point`, `Rect` and `Size`
([`BasicTypes.hs`][basictypes]) — so there is no translation problem, because
the measurer is the authority and layout adopts its answer.

This is an independent confirmation of **F1**, in the strongest form the survey
records: not merely "measurement lives elsewhere" but "measurement is a separate
_backend_, with its own C implementation, deliberately severed from the
painter's context".

> [!IMPORTANT]
> The split is not free. Two font stacks must agree or text is laid out at one
> size and drawn at another, so every measurement field is doubled into a scaled
> variant under a documented warning ([`Types.hs`][types]): applying a scale on
> the `Renderer` "it is recommended to apply the scale here too (otherwise there
> will be differences in size and positioning)". Six fields where three would
> do, plus a coherence obligation the type system does not enforce — which any
> `sparkles:ui` move on F1 inherits.

## Q2 — is the contract stated in one place?

**Maximally yes, and at the cost of having no optional primitives whatsoever.**

The `Renderer` declaration _is_ the contract: 45 fields, all mandatory, all
concrete types. There is no `Maybe` field, no `Default` instance for `Renderer`,
no capability enum, no feature query, and nothing corresponding to Qt's
`hasFeature` ([Qt deep-dive][qt]) or to our `__traits(compiles)` probes. A
backend author reads one data declaration and knows the whole surface — the
thing [friction §2][friction] says `isCanvas` fails to provide.

Four encodings of one contract are now on the table, and they differ exactly
here. [Iced][iced] decomposes its renderer into a base `Renderer` trait plus
supertrait-extending `text::Renderer`, `image::Renderer` and `svg::Renderer`
([`core/src/text.rs`][iced-text]), so a backend implements the subset it
supports and the type system records which. [Slint][slint] uses one trait with
defaults, so absence is silent but recoverable. Monomer uses one record, so
absence is not expressible at all. `isCanvas` is closest to Slint: it names five
methods, and four further primitives — `rule`, `scrollbar`, `pushClip`,
`popClip` — are probed with `__traits(compiles)` at their interpreter call
sites, each with a degradation the interpreter spells out beside the probe
(`ruleEndpoints` plus a cell-aligned `line`; `paintScrollbarCells`
glyph-per-cell; and nothing at all for the clip pair, since the display list has
already culled the hidden subtrees). Absence is therefore recoverable, as in
Slint. What the concept has is neither Iced's decomposition nor Monomer's
exhaustiveness: the four are recoverable but undeclared.

The price is visible in the test utilities, where `mockRenderer` must spell out
all 45 fields to say "do nothing" ([`TestUtil.hs`][testutil]):

```haskell
mockRenderer :: Renderer
mockRenderer = Renderer {
  beginFrame = \w h -> return (),
  intersectScissor = \rect -> return (),
  -- ... 42 more ...
  deleteImage = \name -> return ()
}
```

There is no partial implementation and no graceful floor: a backend that cannot
do radial gradients must supply a field that lies. Monomer's escape valve is not
a capability but a hole — `createRawTask` and `createRawOverlay` take an `IO ()`
closure and run it between passes, documented in [`Types.hs`][types] as "Well
suited for pure OpenGL/Vulkan/Metal" and demonstrated in
[`docs/examples/05-opengl.md`][glex]. A widget needing something the record
lacks bypasses the record and talks to the GPU API directly, which silently
welds the seam to whichever backend is live.

This sharpens **F5** rather than contradicting it. Monomer's floor is the entire
surface, its defaulted set is empty, nothing is refusable, and its degradation
story is "escape to raw GL". That is a coherent point in the design space, and
it is only liveable because exactly one backend exists.

## Q3 — semantic widgets or primitives?

**Primitives, with the semantics one layer above — as free functions over the
record.** Nothing in `Renderer` knows what a scrollbar is. `Scroll`'s
`renderAfter` paints four rectangles itself ([`Scroll.hs`][scroll]):

```haskell
  renderAfter wenv node renderer = do
    when hScrollRequired $ drawRect renderer hScrollRect barColorH Nothing
    when vScrollRequired $ drawRect renderer vScrollRect barColorV Nothing
    when hScrollRequired $ drawRect renderer hThumbRect thumbColorH thumbRadius
    when vScrollRequired $ drawRect renderer vThumbRect thumbColorV thumbRadius
```

`drawRect` is not a field. It lives in
[`Monomer.Widgets.Util.Drawing`][drawing], a module of ~20 helpers
(`drawRectBorder`, `drawArcBorder`, `drawArrowUp`, `drawStyledAction`,
`drawInScissor`, …) each taking the `Renderer` as its first argument and
lowering to fields. Its module header states the layering:

> Utility drawing functions. Built on top the lower level primitives provided by
> "Monomer.Graphics.Types.Renderer".

This is the mechanical advantage of a record over a trait or an interface:
because the seam is a **value**, a new semantic operation is a new _function
taking that value_, not a method every implementation must grow — `drawArrowUp`
cost no backend anything. The counterpart is that no backend can specialize one.
`boxShadow` is a single `setFillBoxGradient` call ([`BoxShadow.hs`][boxshadow])
— a nanovg primitive promoted into the record — so a hypothetical cell backend
would receive "box gradient", not "shadow", and could not degrade it.

> [!NOTE]
> [`comparison.md`][comparison]'s **F4** puts the question not at
> semantic-versus-primitive but at _where the lowering lives_, and Monomer
> occupies the cheapest arm on that list: **nobody lowers in the seam**, because
> the helper layer is written once against a fixed primitive set that is assumed
> present. It is available only to a single-backend project. `sparkles:ui`
> cannot take it, but it should notice that the choice of _encoding_ (value vs.
> vtable) is what decides whether semantic operations must sit inside the seam.
> Slint puts `draw_box_shadow` in the trait partly because a trait is where a
> Rust project puts overridable behaviour; a record lets the same operation sit
> outside without losing dispatch. `scrollbarThumb` lives in `sparkles.ui.state`
> and not in any backend, so the toolkit takes Monomer's arrangement for the
> geometry and Slint's for the primitive that paints it.

## Q4 — command shape

**No reified command values — but not virtual dispatch either.** `widgetRender`
returns `IO ()` ([`WidgetTypes.hs`][widgettypes]); a frame is a call tree, and
nothing exists afterwards to inspect.

The one exception is worth naming precisely, because it is a shape none of the
surveyed subjects has. Deferred passes are queues of **closures**, held in the
backend's own mutable environment ([`NanoVGRenderer.hs`][nanovgr]):

```haskell
data Env = Env {
  overlays :: Seq (IO ()),
  tasksRaw :: Seq (IO ()),
  overlaysRaw :: Seq (IO ()),
  validFonts :: Set Text,
  imagesMap :: ImagesMap
}

  createOverlay overlay =
    modifyIORef envRef $ \env -> env { overlays = overlays env |> overlay }

  renderOverlays = do
    env <- readIORef envRef
    sequence_ $ overlays env
    writeIORef envRef env { overlays = Seq.empty }
```

So Monomer _does_ reify drawing — as opaque actions. That buys reordering (a
dropdown's popup paints last) and nothing else: the queue cannot be compared,
diffed, culled, serialised, golden-tested or moved to another thread. It is
exactly what `RecordingCanvas` and the op-stream parity harness rely on, minus
the data.

That supports **F3** from the other side. F3 holds that reifying the stream is
the right call and leaves the _encoding_ a live trade; Monomer marks the floor
of that trade. Slint, Qt and [Notcurses][notcurses] show that not reifying is
workable; [egui][egui] shows that reifying as a closed sum gives you everything,
which is the shape `DrawOp` has — a `SumType` over eight plain-data payloads;
Monomer shows the degenerate middle. Reification whose payload is a function is
reification you cannot use, which is exactly the boundary **F12** draws.

## Q5 — sub-unit placement

**Does not arise.** `Point`, `Size` and `Rect` are pairs of `Double`
([`BasicTypes.hs`][basictypes]), and scale is explicit: `WidgetEnv` carries
`_weDpr :: Double`, the renderer has `setScale :: Point -> IO ()`, and
`makeRenderer`/`makeFontManager` each take the device pixel rate. There is no
`RuleEdge` analogue because no position needs naming; a one-pixel rule is a
`drawLine` with a `Double` width, and `drawTextLine` computes its underline
offset arithmetically as `max 1.5 (unFontSize _tlFontSize / 20)`
([`Drawing.hs`][drawing]).

Same verdict as Slint, Qt and egui, and it is **F6** in miniature: continuous
coordinates do not dissolve the sub-unit question, they relocate it. Monomer
needs no `RuleEdge` analogue because no position has to be named at the seam —
but the fidelity policy still has to be written down, and it lands in a helper
as `max 1.5 (…)`, a clamp chosen so a hairline survives at small sizes. The
seam sheds the enumerators; the decision they encode moves one layer up.

## Q6 — resolved appearance, semantic role, or both

**Resolved, exclusively, and resolved above the seam.** The record's colour
parameters are `Color` — a four-field RGBA record ([`Types.hs`][types]) — plus
gradient and image-pattern setters. `StyleState` never crosses; the helper layer
consumes it and hands down computed values ([`Drawing.hs`][drawing]):

```haskell
drawTextLine renderer style textLine = do
  setFillColor renderer fontColor
  renderText renderer txtOrigin _tlFont _tlFontSize _tlFontSpaceH _tlText
  where
    fontColor = styleFontColor style
```

There is no `slot` analogue and no re-resolving consumer, because there is no
HTML-like backend. `_weTheme` sits in `WidgetEnv`, so role-to-colour resolution
happens in the widget, once, per frame.

Monomer therefore pays for one representation, as Slint and Qt do. It is a
third confirmation that carrying a resolved appearance beside a semantic role
([friction §6][friction]) is a cost our HTML interpreter incurs specifically,
not one the general problem imposes. The toolkit already keeps the cheaper half
of that bargain — a payload stores only the resolved fields its own primitive
paints from, and `DrawOp.visual` reconstructs a `Visual` on demand rather than
storing one — but `Slot` rides on six of the eight payloads, and Monomer's
answer is that a project with a single target class never needs the second
representation at all.

## Q7 — payload ownership, and crossing the frame

The most transferable section of this subject, because Monomer already has the
threading arrangement [friction §7][friction] anticipates.

**Text** is Haskell's immutable, GC-managed `Text`: shared, not borrowed, free
to outlive the frame. **Images** are owned by the backend, keyed by name, and
reference-counted inside the renderer's `Env` ([`NanoVGRenderer.hs`][nanovgr]):

```haskell
imgDelete name imagesMap = newImageMap where
  deleteInstance img
    | _imCount img > 1 = Just $ img { _imCount = _imCount img - 1 }
    | otherwise = Nothing
```

The seam's image fields are a cache protocol, not a data channel: `getImage`
asks whether an upload exists, `addImage` uploads, `deleteImage` releases one
reference. On allocation failure the backend clears the whole map and retries,
under the comment "Ideally only LRU should be removed" — the honest version of a
policy the seam does not specify.

Lifetime crosses threads by **routing requests, never handles**. The runtime
holds `_mcRenderMethod :: Either Renderer (TChan (RenderMsg s e))`
([`Main/Types.hs`][maintypes]) — possible only because a backend is a value —
and when rendering runs on its own OS thread, what crosses the channel is the
_model_, not the ops:

```haskell
data RenderMsg s e
  = MsgInit (WidgetEnv s e) (WidgetNode s e)
  | MsgRender (WidgetEnv s e) (WidgetNode s e)
  | MsgResize Size
  | MsgRemoveImage Text
  | forall i . MsgRunInRender (TChan i) (IO i)
```

An immutable `WidgetNode` travels; the `Renderer` never leaves the GL thread
("The render function of a widget will be invoked from this thread, but any
other functions will not" — [`05-opengl.md`][glex]); image disposal becomes a
`MsgRemoveImage`, handled as `deleteImage renderer name`
([`Main/Core.hs`][maincore]), which a widget asks for with a
`RemoveRendererImage` request ([`Image.hs`][image]) rather than by calling the
backend.

This is a complete, working answer to the question M7/T5 raises, and it answers
it by **not** moving a command stream across the thread boundary at all.
Combined with **F8**: every ownership mechanism in the survey copies,
reference-counts or arena-allocates, and none hands a payload across a frame.
`CmdBuffer.textRun` copies each run into a frame arena, which puts the toolkit
squarely inside that set; what Monomer adds is the arrangement above it — keep
the GPU handles on one thread, and move the immutable scene rather than the
commands.

## Q8 — extent query

**Absent from the renderer, present in layout — two of F7's three questions,
answered in different modules.** The
surface's size is pushed in: `beginFrame :: Double -> Double -> IO ()`, called
from `renderWidgets` with values obtained from SDL (`getViewportSize window dpr`,
[`Main/Core.hs`][maincore]). `WidgetEnv` separately carries `_weWindowSize` and
`_weViewport`, and a resize reaches the render thread as `MsgResize Size`.

Content extent is a first-class **layout** query instead:
`widgetGetSizeReq :: WidgetEnv s e -> WidgetNode s e -> (SizeReq, SizeReq)`,
where a `SizeReq` is `fixed`/`flex`/`extra`/`factor` in `Double`
([`StyleTypes.hs`][styletypes]). So "how big is this content" is answerable
without a painter, "how big is the surface" is answered by whoever created the
surface, and ink extent is asked by nobody. **F7** is confirmed by a subject
that keeps the questions in different modules and different type signatures.
Both of its answers are maintained at construction; neither is derived by a
scan. That is F7's second axis, and it is the one `sparkles:ui` answers the
other way — nothing on `CmdBuffer`, the display list or the arena reports the
extent of a built stream, so a caller that needs painted bounds folds `op.rect`
itself ([friction §8][friction]).

## Strengths

- **The contract is one declaration.** A backend author reads 45 lines and has
  the whole surface — no probing, no discovery at call sites, no gap between the
  declared concept and the real requirement.
- **A backend is a value.** It can sit in an `Either`, travel a channel, be
  chosen at runtime or wrapped, without a type parameter infecting the widget
  tree — which is what makes the optional render thread expressible.
- **Semantic operations cost nothing.** Helpers are functions of the record, so
  [`Util/Drawing.hs`][drawing] grows without widening the seam.
- **Measurement is severed from painting at the C level**, so layout is pure and
  needs no graphics context.
- **Payload lifetime is explicit and backend-owned**, with disposal routed as a
  request rather than a direct call.

## Weaknesses

- **No optionality of any kind.** Every field is mandatory; a backend that
  cannot do something must supply a field that lies.
- **The abstraction is one library's API.** The record is nanovg's surface with
  Monomer names, so it constrains a future backend to nanovg's drawing model.
- **The seam is not the whole boundary.** `glViewport`/`glClear`/`glSwapWindow`
  sit outside it, so swapping the record does not swap the backend.
- **The interception the encoding buys is unexercised.** `mockRenderer` exists
  and, at the pinned revision, is referenced by no spec under `test/unit`: the
  widget suite tests layout and events through `mockFontManager` and never
  paints.
- **Two font stacks are kept coherent by convention**, with a doubled API and a
  documentation note in place of enforcement.
- **Reified overlays carry closures**, so ordering is the only property gained.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                                              | Trade-off                                                                              |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| Record of functions, not a type class                 | Widgets live in heterogeneous lists; classes would need existentials ([`design-decisions.md`][design]) | No defaults, no partial instances, no capability query — every field mandatory forever |
| `Renderer` mirrors nanovg 1:1                         | Smallest possible mapping layer; nanovg already covers every use ([`design-decisions.md`][design])     | The seam encodes one backend's model; a second must emulate nanovg, not merely draw    |
| Measurement in a separate `FontManager` record        | Layout stays pure and off-thread; needs no GL context                                                  | Two font stacks; scaled/unscaled duplicates; agreement is a convention                 |
| Pure signatures via `unsafePerformIO`                 | Lets `widgetGetSizeReq` stay a pure function of `WidgetEnv`                                            | Purity is asserted, not proven; a stateful FFI context hides behind a pure type        |
| Semantics in helper functions, not fields             | Adding `drawArrowUp` costs no implementation anything                                                  | No backend can specialize or degrade a semantic operation                              |
| Escape hatch (`createRawTask`, `createRawOverlay`)    | Widgets needing real GL/Vulkan/Metal are not blocked by the record                                     | Bypassing widgets bind to the concrete API; the abstraction is voidable per widget     |
| Backend-owned, name-keyed, ref-counted image cache    | The party that knows GPU lifetime owns it; disposal is a routed request                                | Eviction policy unspecified; allocation failure clears the entire map                  |
| Extent pushed via `beginFrame`, content via `SizeReq` | Surface size belongs to whoever made the surface                                                       | An offscreen consumer sizing to content goes through layout, not the painter           |

## Bearing on the proposal

1. **F1 holds, and Monomer prices it.** Moving `measure` off `isCanvas`
   ([friction §1][friction]) has the weight of the survey behind it. The warning
   Monomer adds: once measurement and painting are different objects, keeping
   them coherent under scale is an unenforced obligation. Put the scale/DPR
   argument _in_ the metrics type rather than repeating it at call sites.
2. **A stated contract and optional primitives are in direct tension, and
   `isCanvas` states one of them.** Monomer answers [friction §2][friction]
   perfectly by abolishing optionality; Qt buys optionality by declaring
   features. A DbI concept can have both — the four optional primitives each
   carry a stated degradation already, written beside the probe; what is absent
   is the declaration naming which four they are, rather than leaving them to be
   discovered from `__traits(compiles)` at interpreter call sites. That is the
   concrete shape of **F5**'s floor / defaulted / refusable ladder, and D has a
   construct for every rung.
3. **Reject the escape hatch.** `createRawTask` is what a seam grows when it
   cannot say "this backend can do more"; an equivalent would destroy the
   backend parity the op-stream harness exists to defend.
4. **Semantic operations need not live inside the seam** — which is **F4**'s
   point that the axis is where the lowering lives. Monomer keeps `scrollbar`
   out entirely and still shares one implementation, because helpers take the
   backend as a parameter. `scrollbarThumb` computes the geometry once in
   `sparkles.ui.state`, so a free function `paintScrollbar(ref canvas, …)` over
   the primitive ops would retire a whole arm — the fourteen-field `Scrollbar`
   payload, the eight accessors no other arm can answer, and one `match!` arm in
   every walker ([friction §3][friction]). It would not make an operation
   narrower, since the widest payload is `TextRun` and the budget is measured
   against that (§4); the saving is arm count, not bytes. The price is
   Monomer's — no per-backend degradation — and _that_ is the real decision, not
   "semantic versus primitive". A cell backend that must degrade differently is
   the argument for keeping it in, and should be made on those terms.
5. **Do not reify actions; reify data or nothing.** The overlay queue is the
   cautionary case for **F3**: closures give ordering and foreclose everything
   else. `DrawOp`'s eight payloads are plain data with no callable member, and
   that is the property to defend — **F12**'s point that reification pays only
   while the value stays inspectable.
6. **For M7/T5, move the scene, not the commands.**
   `Either Renderer (TChan (RenderMsg s e))` keeps the GPU handle on one thread
   and ships an immutable widget tree to it, with disposal as a routed request.
   That dissolves [friction §7][friction] without widening the borrow or making
   `DrawOp` sendable — available to us because our display list is already
   built by a pure function. `UI-O4` asks the retain-boundary question directly,
   and this is one shape of answer to it.
7. **A value-shaped seam is worth only what you do with it.** The strongest
   argument for a record — trivial mocking, decoration, recording — is
   unexercised here, while `RecordingCanvas` delivers the same property under a
   structural concept, interns its text on the collected heap so the ops outlive
   the call that drew them, and is actually used. Keep the DbI encoding; the
   friction log is right that this is not the problem.
8. **F7's split is confirmed again**: surface extent belongs to whoever made the
   surface, content extent to layout, and Monomer maintains both at
   construction rather than scanning for either. `widgetGetSizeReq` is the
   layout query [`comparison.md`][comparison] recommends, already shipping;
   [friction §8][friction] is where the toolkit still scans instead.

## Sources

- [`Graphics/Types.hs`][types] — the `Renderer` and `FontManager` records,
  `Color`, `TextLine`, the scale note; [`NanoVGRenderer.hs`][nanovgr] — the only
  production implementation (overlay/raw queues, image cache, ref counting).
- [`Graphics/FontManager.hs`][fontmgr], [`Graphics/FFI.chs`][ffi],
  [`cbits/fontmanager.h`][fmheader], [`cbits/fontmanager.c`][fmc] — the
  measurement backend, its separate `FMContext`, the GL-free nanovg text fork.
- [`Core/WidgetTypes.hs`][widgettypes], [`Core/StyleTypes.hs`][styletypes],
  [`Common/BasicTypes.hs`][basictypes] — `WidgetEnv`, `Widget`, `SizeReq`, units.
- [`Main/Core.hs`][maincore], [`Main/Types.hs`][maintypes] — frame driver,
  `RenderMsg`, `_mcRenderMethod`.
- [`Widgets/Util/Drawing.hs`][drawing], [`Widgets/Util/Text.hs`][utext],
  [`Scroll.hs`][scroll], [`BoxShadow.hs`][boxshadow], [`Label.hs`][label],
  [`Image.hs`][image] — the helper layer and widget-side use.
- [`test/unit/Monomer/TestUtil.hs`][testutil] — `mockRenderer`, `mockFontManager`.
- [`docs/design-decisions.md`][design], [`docs/examples/05-opengl.md`][glex],
  [`monomer.cabal`][cabal] — stated rationale, threading rules, version/licence.

<!-- References -->

[rev]: https://github.com/fjvallarino/monomer/tree/5c6239365e3a37686b6547bc91c29270ae5487c6
[types]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Graphics/Types.hs
[nanovgr]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Graphics/NanoVGRenderer.hs
[fontmgr]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Graphics/FontManager.hs
[ffi]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Graphics/FFI.chs
[fmheader]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/cbits/fontmanager.h
[fmc]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/cbits/fontmanager.c
[widgettypes]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Core/WidgetTypes.hs
[styletypes]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Core/StyleTypes.hs
[basictypes]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Common/BasicTypes.hs
[maincore]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Main/Core.hs
[maintypes]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Main/Types.hs
[drawing]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Widgets/Util/Drawing.hs
[utext]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Widgets/Util/Text.hs
[scroll]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Widgets/Containers/Scroll.hs
[boxshadow]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Widgets/Containers/BoxShadow.hs
[label]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Widgets/Singles/Label.hs
[image]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/src/Monomer/Widgets/Singles/Image.hs
[testutil]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/test/unit/Monomer/TestUtil.hs
[design]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/docs/design-decisions.md
[glex]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/docs/examples/05-opengl.md
[cabal]: https://github.com/fjvallarino/monomer/blob/5c6239365e3a37686b6547bc91c29270ae5487c6/monomer.cabal
[hackage]: https://hackage.haskell.org/package/monomer
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[comparison]: ./comparison.md
[egui]: ./egui.md
[notcurses]: ./notcurses.md
[iced]: ./iced.md
[iced-text]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/text.rs
[slint]: ./slint.md
[qt]: ./qt-qpaintengine.md
