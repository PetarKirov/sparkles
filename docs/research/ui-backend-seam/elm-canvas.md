# joakin/elm-canvas — the sum type is above the seam; the seam itself is a string

**Category:** commands as pure data in a total language. **Last reviewed:** August 23, 2026.
Pinned at [`4b8b07eb`][rev].

A 2 000-line Elm package that draws to a DOM `<canvas>`. It is on this list
because it is the smallest complete statement of the reification
[`comparison.md`](./comparison.md)'s **F3** describes — draw commands as plain,
immutable, pattern-matchable values in a total language — and because the value
stream has to cross a real boundary into JavaScript to become pixels. Reading it
closely produces two results that qualify F3 rather than simply confirming it.

|                      |                                                                                                   |
| -------------------- | ------------------------------------------------------------------------------------------------- |
| **Language**         | Elm 0.19 (`0.19.0 <= v < 0.20.0`), plus ~90 lines of JavaScript                                   |
| **License**          | BSD-3-Clause ([`LICENSE`][license])                                                               |
| **Repository**       | [`joakin/elm-canvas`][rev]                                                                        |
| **Documentation**    | [package.elm-lang.org][docs]                                                                      |
| **Version**          | `5.0.0` ([`elm.json`][elmjson])                                                                   |
| **Category**         | commands as pure data in a total language                                                         |
| **Pinned revision**  | `4b8b07ebb92521a5937c11198caf437f5c0f7501`                                                        |
| **Backends shipped** | exactly one — `CanvasRenderingContext2D`, via a custom element ([`elm-canvas/elm-canvas.js`][js]) |
| **Seam size**        | `Canvas/Internal/Canvas.elm`, 67 lines; `Canvas/Internal/CustomElementJsonApi.elm`, 922 lines     |

## Overview

### What it solves

Elm is a total, pure functional language with no escape hatch to a mutable
foreign object. `CanvasRenderingContext2D` is a mutable foreign object whose
entire API is imperative state mutation. elm-canvas bridges the two by making
the drawing _description_ a pure value and pushing the mutation into a web
component that replays it.

### Design philosophy

The library is deliberately two layers, and the lower one does not pretend to be
nice. `Canvas.Internal.CustomElementJsonApi` opens by saying so:

> **WARNING**: This library is in development and right now it only exposes a
> low-level API that mirrors the DOM API, providing a bit of extra type safety
> where it makes sense. The DOM API is highly stateful and side-effectful, so be
> careful.
>
> — [`Canvas/Internal/CustomElementJsonApi.elm`][jsonapi]

The upper layer (`Canvas`, `Canvas.Settings.*`) is the one with the algebraic
data types. The lower layer is a name-for-name mirror of the DOM, and it is what
actually crosses the boundary.

## How it works

The seam's defining declaration is 67 lines, and every type in it is a proper
sum type whose constructors are exactly as wide as their payloads — the
variable-width encoding [friction §4][friction] weighs `sparkles:ui`'s
uniform-width operations against:

```elm
type Renderable
    = Renderable
        { commands : Commands
        , drawOp : DrawOp
        , drawable : Drawable
        }

type Drawable
    = DrawableText Text
    | DrawableShapes (List Shape)
    | DrawableTexture Point Texture
    | DrawableClear Point Float Float
    | DrawableGroup (List Renderable)

type DrawOp
    = NotSpecified
    | Fill Color
    | Stroke Color
    | FillAndStroke Color Color

type Shape
    = Rect Point Float Float
    | Circle Point Float
    | Path Point (List PathSegment)
    | Arc Point Float Float Float Bool
```

— [`Canvas/Internal/Canvas.elm`][internal]

`Rect` carries three payload words, `Circle` two, and neither can observe the
other's. `DrawOp` is elm-canvas's own name for the paint state, and it is a
four-constructor lattice, not a bag of nullable colours.

**But `Renderable` is not what reaches the renderer.** `commands : Commands` is
`List Json.Encode.Value`, and each `Value` was produced by one of two private
constructors at the very bottom of the DOM mirror:

```elm
field : String -> Command -> Command
field name value =
    Encode.object [ ( "type", string "field" ), ( "name", string name ), ( "value", value ) ]

fn : String -> List Command -> Command
fn name args =
    Encode.object [ ( "type", string "function" ), ( "name", string name ), ( "args", Encode.list identity args ) ]
```

— [`Canvas/Internal/CustomElementJsonApi.elm`][fnfield]

The whole scene is lowered to a flat `List` of those two shapes by
[`render`][render], attached to the element as a DOM _property_ named `cmds`,
and replayed by the shim with no interpretation whatsoever:

```js
execCommand(cmd) {
  if (cmd.type === "function") {
    this.context[cmd.name](...cmd.args);
  } else if (cmd.type === "field") {
    this.context[cmd.name] = cmd.value;
  }
}
```

— [`elm-canvas/elm-canvas.js`][exec]

So the pattern-matchable command vocabulary is **not the seam**. The seam is
`{ type, name, args }` with `name` a string looked up on a JS object. Every
guarantee the Elm types provide is discharged in
`Canvas/Internal/CustomElementJsonApi.elm` — the one place `"fillRect"` is
spelled — and nothing downstream of that file is typed at all.

> [!NOTE]
> Despite the framing, this is **not** a byte-serialising boundary. Elm's
> `Json.Encode.Value` is the identity wrapper in production builds
> (`_Json_wrap`/`_Json_unwrap` are `function (value) { return value; }`, [elm/json
> kernel][jsonkernel]), and `virtual-dom` hands properties through
> `__Json_unwrap(value)` unchanged ([virtual-dom kernel][vdprop]). The array of
> command objects is passed by reference. The cost of the encoding is not
> `JSON.stringify`; it is the loss of type information and the per-frame
> allocation of one object per command.

## Q1 — measurement units, and who answers

**Text measurement is not merely off the seam; it is unreachable.**
`measureText` appears exactly once in the source tree — in a `TODO` comment
listing DOM functions the library does not support:

```elm
{- TODO: Should these functions be supported:
   ...
   - measureText
```

— [`Canvas/Internal/CustomElementJsonApi.elm`][todo]

The reason is structural, not an oversight. The command channel is a DOM
property carrying a value _out_; there is no return path on it. Anything the
renderer knows and Elm does not can only come back through the Elm update loop
as a message, one frame later.

elm-canvas has exactly one such path, and it is instructive that it exists for
images and not for text. `Texture.loadImageUrl url onLoad` renders a hidden
`<img>` and subscribes to its `load` event; the handler decodes `width` and
`height` off the DOM node and delivers a `Texture` to the application's `update`
([`Canvas/Internal/Texture.elm`][texinternal]). `Texture.dimensions` then reads
them synchronously ([`Canvas/Texture.elm`][texdims]). So the library _does_ have
a measurement channel — asynchronous, message-shaped, one frame of latency — and
uses it for the one payload whose size it can obtain from an ordinary DOM
element.

Without that channel for text, the API substitutes two things a caller would
otherwise compute from a measurement:

- **Anchoring**, delegated: `align : TextAlign -> Setting` and
  `baseLine : TextBaseLine -> Setting` name a reference point and let the
  renderer place the run ([`Canvas/Settings/Text.elm`][settext]). The
  documentation is explicit that the caller cannot do this arithmetic itself —
  "if `textAlign` is `Center`, then the text would be drawn at `x - (width / 2)`"
  — where `width` is precisely the number Elm cannot obtain.
- **Fitting**, delegated: `maxWidth : Float -> Setting`, documented "Specify a
  maximum width. The text is scaled to fit that width." A caller states a
  _constraint_ instead of asking a _question_.

This sharpens **F1**. F1 concluded that measurement belongs somewhere other than
the painter; elm-canvas shows what a seam looks like when measurement is not
merely elsewhere but _absent_ — the API grows constraint-shaped operations
(`align`, `baseLine`, `maxWidth`) to push the arithmetic across. The same
consequence appears in [`elm-ui.md`](./elm-ui.md), from the same root cause: an
Elm program cannot ask the renderer how wide a string is. So this is a warning
about the _shape_ of the F1 fix, not just its location — a redesign that makes
measurement asynchronous or refusable would force cell-grid layout into the same
idiom, and a cell grid has nowhere to put a constraint.

## Q2 — is the contract stated in one place?

**Stated in one place, checked nowhere.**
`Canvas/Internal/CustomElementJsonApi.elm`'s exposing list is the complete
contract — 40-odd operations, each one Elm function wrapping one DOM name — and
a reader learns the whole surface from that header. That is better than
`isCanvas`, whose five checked members understate a contract of eight operation
kinds, four of which the interpreter probes with `__traits(compiles)` at each
call site ([friction §2][friction]).

But there is no capability query, no default, and no degradation, because there
is exactly one backend and it is the DOM. `this.context[cmd.name](...cmd.args)`
is an unguarded property lookup: an unsupported name is a `TypeError` at replay
time, attributed to no Elm expression. The `TODO` list of unimplemented DOM
functions is the capability declaration, and it lives in a comment.

The transferable observation: **a single-backend seam gets to state its contract
as an exposing list and stop**, and that stops working the moment a second
backend exists. `sparkles:ui` has three.

## Q3 — semantic widgets, or primitives?

**Primitives only, and the question does not arise:** elm-canvas is a drawing
library, not a toolkit. There is no scrollbar, no focus ring, no widget layer at
all; `Canvas.toHtml` produces an `Html msg` that sits _beside_ Elm's ordinary
DOM widgets rather than replacing them.

The one place semantics survive lowering is `Canvas.Settings.Advanced.shadow`,
which takes a `Shadow` record and expands to four DOM field-sets
([`Canvas/Settings/Advanced.elm`][advshadow]). Note the direction: the semantic
grouping exists in the _author-facing_ type and is destroyed before the seam.
Slint puts `draw_box_shadow` on the renderer precisely so a backend can degrade
it; elm-canvas, with one backend that supports shadows natively, has no reason
to. This is consistent with **F4**'s reframing — the axis is not
semantic-versus-primitive but _where the lowering lives_. A seam with one backend
and nobody to degrade for puts every lowering in the author-facing layer and
keeps nothing semantic below it.

## Q4 — sum type, or tag plus dead fields?

Above the seam, elm-canvas is the clean closed sum F3 describes. Below it, the seam
is stringly typed. That split is the first of this subject's two contributions.

The second is more uncomfortable. **A sum type does not eliminate illegal
combinations here; it relocates them.** `Setting` is a four-constructor union,
and one constructor carries a function:

```elm
type Setting
    = SettingCommand C.Command
    | SettingCommands C.Commands
    | SettingDrawOp DrawOp
    | SettingUpdateDrawable (Drawable -> Drawable)
```

— [`Canvas/Internal/Canvas.elm`][internal]

Because a `Setting` is applied to _any_ `Renderable`, the cross-product of
settings and drawables is unconstrained, and the excess combinations are handled
by silently doing nothing. `maxWidth` is the clearest case: it pattern-matches
all five `Drawable` constructors and returns the drawable untouched for four of
them ([`Canvas/Settings/Text.elm`][maxwidth]). The module documents this as
intended behaviour:

> You can apply the following styling settings to text specifically. They will do
> nothing if you apply them to other renderables, like `shapes`.
>
> — [`Canvas/Settings/Text.elm`][settext]

`Renderable` itself is a record, not a union: every renderable carries
`commands`, `drawOp` and `drawable` whether or not they apply — `DrawableClear`
ignores `drawOp` entirely, since [`renderClear`][render] emits a single
`clearRect` and never consults it.

So a project that reified its commands as sum types in a total language _still_
ended up with dead fields and no-op settings, one layer up. That does not
disturb **F3** — a closed sum is the right encoding, and `DrawOp` shows what one
buys: a `PopClip` carries no fields at all, `Scrollbar`'s fourteen are reachable
only through the scrollbar arm, and no operation carries another arm's words. But
it falsifies the implicit promise that a sum makes illegal states
unrepresentable. `sparkles:ui` keeps the same residue somewhere else: the
sum-level accessors span arms that cannot answer, so `DrawOp.slot` reports
`Slot.inherit` for the clip pair, the bar accessors answer neutrally on arms that
have no bar, and `visualOf` is lossy on purpose — a fill reports box chrome, a
run reports text chrome, and the combinations no backend reads get defaults.
"Which style input applies to which operation" is a question the encoding does
not address, in Elm or in D.

## Q5 — sub-unit placement

**Does not arise.** Every coordinate in the value language is `Float` CSS pixels
(`type alias Point = ( Float, Float )`), and the device-pixel step is handled
entirely inside the shim, which reads `window.devicePixelRatio`, sizes the
backing store, and applies `context.scale(dpr, dpr)`
([`elm-canvas/elm-canvas.js`][dpr]). Elm never sees a device pixel.

This is **F6** in miniature: continuous coordinates relocate the sub-unit
problem rather than dissolving it. elm-canvas relocates the whole of it into the
shim, where `devicePixelRatio` is a single scalar and the move costs one
`context.scale` call. `sparkles:ui` keeps its unit conversion in the backends the
same way, but cells and glyphs are not related by a scalar, so the same move buys
much less: the sub-cell positions the toolkit has no unit for stay unspellable,
and `rule`'s six `RuleEdge` compass points remain the vocabulary (friction §5).

## Q6 — resolved appearance, semantic role, or both?

**Resolved, and — the part worth stealing — not per-op.** `DrawOp` is one field
per `Renderable`, and it is inherited: [`renderOne`][render] takes a
`parentDrawOp`, `renderGroup` passes the merged value to every child, and
`mergeDrawOp` is a total lattice join over the four constructors, with `Fill`
and `Stroke` composing to `FillAndStroke` rather than overwriting
([`Canvas.elm`][merge]).

The scoping is enforced by construction rather than by discipline: `renderOne`
brackets each renderable's commands with `CE.save` and `CE.restore`, so no
setting can leak into a sibling.

This is exactly the split the survey brief flagged — settings attach to a
_renderable_, not to every primitive inside it — and it is the direct opposite
of every `DrawOp` payload storing the resolved appearance its own primitive
paints from beside a `Slot`, on six of the eight arms
([friction §6][friction]). Two observations follow:

1. **Paint is deferred; everything else is eagerly lowered.** `addSettingsToRenderable`
   is a left fold that turns `SettingCommand`/`SettingCommands` into `Value`s
   immediately, but `SettingDrawOp` is kept as a _value_ until render time
   ([`Canvas.elm`][addsettings]). The reason is ordering: whether a shape emits
   `fill`, `stroke`, both, or neither cannot be decided until the shape's path
   has been built. Deferred styling is not a design preference here; it falls
   out of the primitive's own semantics.
2. **Nothing is semantic.** There is no `slot` analogue, and no re-resolving
   backend to want one — the closest thing, the HTML interpreter's class names,
   has no counterpart in a library whose only backend is a raster context.

The `sparkles:ui` reading: **F9**/§6's cost is real, and elm-canvas shows the
alternative works — a paint state that scopes over a subtree and merges down a
group hierarchy is fewer bytes and fewer decisions than a resolved appearance
plus a `Slot` on every operation. Deriving `Visual` on demand through `visualOf`
instead of storing one takes part of that cost off the operation; taking the
rest depends on the display list keeping grouping structure, which it does not —
`buildDisplayList` returns a flat `DrawOp[]`.

## Q7 — payload ownership and lifetime

**Ownership is a non-problem, and the seam still leaks.**

`Text` holds `text : String` by value, `Shape` holds `Point` tuples of `Float`,
and Elm values are immutable and garbage-collected, so nothing in
[friction §7][friction] — the `const(char)[]` borrowed from a frame arena, valid
only while the buffer that built it is alive and unreset — has any analogue. It
is **F8**'s copy-or-own result read at the far end, and it is worth stating:
**`DrawOp.text`'s lifetime hazard is a consequence of borrowing the arena's
bytes, not of reifying a command.** A reified command stream and owned payloads
are independent choices; `UI-O4` stays open on exactly that boundary.

Two things complicate the "pure data" reading, though:

- **An opaque foreign handle rides inside the value.**
  `Canvas.Internal.Texture.Image` is `{ json : D.Value, width : Float, height :
Float }`, and `json` is the live DOM `<img>` element, captured by
  `decodeImageLoadEvent` as `D.field "target" D.value` and handed straight back
  to `drawImage` ([`Canvas/Internal/Texture.elm`][texinternal]). The payload the
  seam cannot describe is smuggled through as an untyped handle — the same move
  every seam in this survey makes for images, in the language least able to admit
  it.

  This also means the brief's premise that Elm values are "necessarily
  comparable" is false for this type. Elm's `_Utils_eqHelp` walks unknown objects
  with `for (var key in x)` and returns `true` past a depth of 100
  ([elm/core kernel][utils]), so `==` on two `Texture`s traverses live DOM nodes.

- **There is no diffing, so every command is rebuilt and replayed every frame.**
  `commands` attaches the list via `Html.Attributes.property "cmds"`
  ([`Canvas/Internal/CustomElementJsonApi.elm`][commands]), and `virtual-dom`
  compares property values with JavaScript reference equality —
  `if (xValue === yValue && xKey !== 'value' && xKey !== 'checked') continue;`
  ([virtual-dom kernel][vdprop]). `render` allocates a fresh list each view, so
  the comparison never succeeds, the `set cmds` setter fires, and
  `render()` replays the entire scene.

That second point matters for **F12**, whose justification for a reified stream
is that commands are values and can therefore be collected, culled, replayed and
compared. elm-canvas reifies as thoroughly as anything here and cashes exactly
one of the four: replay. It never culls, never diffs, and cannot compare (the
commands are opaque `Value`s). **Reification is necessary for those properties
but nowhere near sufficient** — they need the commands to stay _inspectable_,
which is what lowering to `{ type, name, args }` gives up, and what keeping
`DrawOp` a plain-data value in the toolkit's own language preserves.

## Q8 — can a backend ask the scene its extent?

**No, and it never needs to: the caller states the extent.**
`toHtml ( width, height ) attrs entities` takes the size as its first argument,
and `toHtmlWith` takes it as a record field ([`Canvas.elm`][tohtml]). The shim
reads those back off the element's attributes and sizes the backing store
([`elm-canvas/elm-canvas.js`][dpr]).

Of **F7**'s three questions elm-canvas answers only the surface one, and answers
it by argument: the size is an _input_ to the scene, neither maintained at
construction nor derived by a scan. Nothing in the `Renderable` tree reports
layout or ink extent, even though `Shape`'s constructors are pattern-matchable
enough that a `bounds : Shape -> Rect` would be trivial — it is absent because no
consumer wants it. `sparkles:ui` sits one notch along the same axis: neither
`CmdBuffer` nor the display list reports extent, and a caller that needs painted
bounds folds `op.rect` itself (friction §8).

## Strengths

- **The contract fits on one screen** — 67 lines of type declarations, against
  `isCanvas` plus `OpKind` plus the interpreter's `__traits(compiles)` sites.
- **Constructor-shaped payloads.** `Rect Point Float Float` and `Circle Point
Float` carry what they need and nothing else — the variable-width encoding
  [friction §4][friction] weighs a uniform 64-byte operation against,
  demonstrated at small scale.
- **Paint state scopes over a subtree** and merges down groups, instead of being
  stamped onto every primitive; `save`/`restore` makes that scope structural
  rather than conventional.
- **Ownership is free**, and unit conversion lives entirely in the shim.

## Weaknesses

- **The typed vocabulary is destroyed at the boundary** — `{ type, name, args }`
  with a stringly-typed method name applied by unguarded property lookup: no
  exhaustiveness, no capability check, no error attribution.
- **No measurement channel for text**, and none possible on an outbound-only
  property; `measureText` sits in a `TODO` comment.
- **Sum types did not make illegal states unrepresentable.** The
  setting × drawable cross-product is unconstrained; the excess is
  documented-silent no-ops.
- **No diffing and no culling** — the scene is rebuilt and replayed every
  view by construction; the author lists "Rendering vía hacky interop rather than
  json encoding?" under performance improvements in [`TODO.md`][todomd].
- **One backend**, so every question about negotiating with a second one is
  unanswered by design.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                                                        | Trade-off                                                                                           |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Typed sum types above, `{ type, name, args }` at the wire       | Elm cannot call a foreign method; only data crosses to JS                                                                        | All type information is discharged in one file; a wrong `name` is a runtime `TypeError`             |
| DOM property + custom element, not a `port`                     | Keeps drawing inside `view`, so it participates in the normal render cycle                                                       | `virtual-dom` diffs properties by reference, so the scene is fully rebuilt and replayed every frame |
| `Setting` applies to a `Renderable`, not to a primitive         | Batching: "You can draw many shapes with the same `Setting`s, which makes for very efficient rendering" ([`Canvas.elm`][tohtml]) | Settings that do not apply to a drawable are silent no-ops rather than type errors                  |
| `DrawOp` deferred, other settings eagerly lowered to `Command`s | Fill/stroke emission depends on the path being built first                                                                       | Two representations of "style" coexist in `Renderable`                                              |
| No `measureText`                                                | The command channel has no return path                                                                                           | Text sizing becomes constraint-passing (`align`, `baseLine`, `maxWidth`) instead of arithmetic      |
| Extent is an argument to `toHtml`                               | The surface is a DOM element that must be sized before anything is drawn                                                         | Nothing can size a surface to its content                                                           |
| Image handle carried as an opaque `Json.Value` inside the scene | A decoded `<img>` cannot be expressed as Elm data                                                                                | The "pure data" property is punctured exactly where payloads get expensive; `==` becomes unsound    |

## Bearing on the proposal

1. **F3 survives, but its stated payoff needs a second condition — F12.**
   Reifying the command stream is right, and a closed sum is the right encoding —
   but elm-canvas reifies fully and gets only _replay_ out of it, because the
   commands stop being inspectable at the boundary. What makes `sparkles:ui`'s
   reification pay is that `DrawOp` values are **comparable and introspectable in
   the toolkit's own language**: eight plain-data payloads under one `SumType`,
   dispatched by `match!`, which is what lets `RecordingCanvas` hold two op
   streams side by side and the parity harness read them. Price any change to the
   encoding against that property, not against the union alone.

2. **A sum type relocates illegal states; it does not eliminate them.** This is
   a caveat about `DrawOp`'s encoding, and it stands as one — against the
   implicit reading of F3 and of [friction §4][friction]. `DrawOp` is a closed
   `SumType` over eight payloads and it does what such an encoding is supposed to
   do: a `PopClip` carries nothing, `Scrollbar`'s fourteen fields are reachable
   only through the scrollbar arm, and `match!` keeps every walker exhaustive.
   What it does not do is make "which style input applies to which operation" a
   typed question. elm-canvas is the evidence — a total language with proper
   unions that still ships a documented set of settings doing nothing on four of
   five drawables, `maxWidth` pattern-matching all five `Drawable` constructors
   and returning four of them untouched, documented as intended behaviour.
   The toolkit's residue of the same shape is the neutral answer: `DrawOp.slot`
   reports `Slot.inherit` for the clip pair, the bar accessors answer neutrally
   on arms that have no bar, and `visualOf` is lossy by design, handing defaults
   to the combinations no backend reads. The price of eliminating that residue:
   the seventeen sum-level accessors give way to per-arm ones, so every walker
   that reads `op.slot`, `op.rect` or `op.visual` grows its own eight-arm
   `match!` and `translate` loses the one place that knows which arms carry
   geometry; `Visual` splits into per-primitive types, so the seam stops speaking
   one `Visual` end to end; and none of it moves the 64-byte budget or improves
   `RecordingCanvas` comparability, which the uniform accessor surface is what
   makes practical. So this is a caveat on the encoding, not a complaint about it:
   the sum buys what it claims to buy, and this is the thing it does not buy.

3. **Scope paint over a subtree instead of stamping it on every op.** elm-canvas's
   single inherited `DrawOp` per `Renderable`, merged down groups by a total
   lattice join, is the concrete alternative to friction §6's resolved appearance
   _and_ `Slot` on every operation. It requires the display list to keep grouping
   structure, which the flat `DrawOp[]` `buildDisplayList` returns does not — that
   is the cost to weigh, and it is a bigger change than the op encoding itself.

4. **F1's fix must stay synchronous.** elm-canvas and `elm-ui` both lose text
   measurement for the same reason and both replace it with constraint-passing
   (`maxWidth`, `align`). Moving `measure` off the canvas into a font abstraction
   is right; moving it _out of reach_ of layout — behind a message, a future, or a
   backend that may decline — would push cell-grid layout into the same idiom, and
   a cell grid has nowhere to put the constraint.

5. **F7 read from the far end of its axis.** The extent is an argument to
   `toHtml`, neither maintained on the scene nor derived from it. Nothing in a
   scene of pattern-matchable shapes reports its bounds, though such a function
   would be trivial to write — because only an offscreen consumer wants it. That
   is a reason to leave `DrawOp` alone: `skia-canvas-render.d` folding `op.rect`
   is the derive-by-scan half of F7's axis, and the gap friction §8 records is
   better closed by a layout query for that consumer than by making every
   operation self-describing.

6. **Q2 is not a question a single-backend seam has to answer.** elm-canvas states
   its contract as an exposing list and stops, which works because the only backend
   is the DOM. It is evidence for how much of §2's difficulty is created by having
   three backends, not by `isCanvas`'s formulation — and therefore that the fix
   belongs in a capability declaration rather than in a better concept.

## Sources

- [`src/Canvas/Internal/Canvas.elm`][internal] — the seam's whole type language.
- [`src/Canvas/Internal/CustomElementJsonApi.elm`][jsonapi] — the DOM mirror: the
  `field`/`fn` [encoding][fnfield], the `commands` [property][commands], and the
  unsupported-functions [`TODO`][todo] containing `measureText`.
- [`src/Canvas.elm`][tohtml] — `toHtml`, [`render`/`renderOne`][render],
  [`mergeDrawOp`][merge] and [`addSettingsToRenderable`][addsettings].
- [`src/Canvas/Settings/Text.elm`][settext] — `align`, `baseLine`,
  [`maxWidth`][maxwidth]; [`src/Canvas/Settings/Advanced.elm`][advshadow] — `shadow`.
- [`src/Canvas/Internal/Texture.elm`][texinternal] and
  [`src/Canvas/Texture.elm`][texdims] — the asynchronous image-measurement path
  and the opaque `D.Value` handle.
- [`elm-canvas/elm-canvas.js`][js] — the entire renderer: [`execCommand`][exec]
  and [device-pixel-ratio handling][dpr]. Plus [`TODO.md`][todomd],
  [`elm.json`][elmjson], [`LICENSE`][license].
- Elm platform kernels, for the boundary's actual cost: [elm/json][jsonkernel]
(`_Json_wrap` is identity in production), [elm/virtual-dom][vdprop]
(properties pass through `__Json_unwrap`) and its [property diff][vdprop]
(reference equality), [elm/core `_Utils_eqHelp`][utils].
<!-- References -->

[rev]: https://github.com/joakin/elm-canvas/tree/4b8b07ebb92521a5937c11198caf437f5c0f7501
[internal]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas/Internal/Canvas.elm
[jsonapi]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas/Internal/CustomElementJsonApi.elm
[fnfield]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas/Internal/CustomElementJsonApi.elm#L915-L922
[commands]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas/Internal/CustomElementJsonApi.elm#L908-L912
[todo]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas/Internal/CustomElementJsonApi.elm#L885-L900
[tohtml]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas.elm
[render]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas.elm#L579-L592
[merge]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas.elm#L180-L212
[addsettings]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas.elm#L294-L311
[settext]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas/Settings/Text.elm
[maxwidth]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas/Settings/Text.elm#L166-L185
[advshadow]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas/Settings/Advanced.elm
[texinternal]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas/Internal/Texture.elm
[texdims]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/src/Canvas/Texture.elm#L94-L102
[js]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/elm-canvas/elm-canvas.js
[exec]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/elm-canvas/elm-canvas.js#L79-L85
[dpr]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/elm-canvas/elm-canvas.js#L48-L68
[todomd]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/TODO.md
[elmjson]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/elm.json
[license]: https://github.com/joakin/elm-canvas/blob/4b8b07ebb92521a5937c11198caf437f5c0f7501/LICENSE
[docs]: https://package.elm-lang.org/packages/joakin/elm-canvas/5.0.0/
[jsonkernel]: https://github.com/elm/json/blob/2865dfce97a75724a75583a214d3a287d2abecd4/src/Elm/Kernel/Json.js
[vdprop]: https://github.com/elm/virtual-dom/blob/79d31f5889930aa5d0d8e874a0807076d5c16891/src/Elm/Kernel/VirtualDom.js
[utils]: https://github.com/elm/core/blob/65cea00afa0de03d7dda0487d964a305fc3d58e3/src/Elm/Kernel/Utils.js
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
