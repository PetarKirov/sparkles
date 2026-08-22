# egui — the backend receives geometry, not commands

**Category:** backend gets geometry. **Last reviewed:** August 23, 2026.
Pinned at [`97603fc0`][rev]; types per the [`epaint::Shape` reference][shape].

The far end of the design space, and on the list to bound it. If Slint tells a
backend _what a thing is_ and Qt tells it _what shape to fill_, egui tells it
_where the triangles are_.

| Field                | Value                                                                                         |
| -------------------- | --------------------------------------------------------------------------------------------- |
| **Language**         | Rust                                                                                          |
| **License**          | `MIT OR Apache-2.0` ([`Cargo.toml`][cargo], [`LICENSE-MIT`][mit], [`LICENSE-APACHE`][apache]) |
| **Repository**       | [`emilk/egui`][repo]                                                                          |
| **Documentation**    | [docs.rs/epaint][shape], [docs.rs/egui][docsegui], [`ARCHITECTURE.md`][arch]                  |
| **Category**         | backend gets geometry                                                                         |
| **Pinned revision**  | [`97603fc082aa4eecfeb7feccbcb6c2507dffaf28`][rev]                                             |
| **Target range**     | GPU (and CPU rasterizers that accept triangles) — native and web; no cell target is reachable |
| **Backends shipped** | `egui-wgpu`, `egui_glow`, and `eframe`'s web painter — all consuming `ClippedPrimitive`       |
| **The seam**         | `Vec<ClippedPrimitive>` — a clip rect plus a `Mesh` or a `PaintCallback`                      |
| **The intermediate** | `epaint::Shape`, a 12-variant Rust `enum`, tessellated to meshes before any backend sees it   |

## Overview

### What it solves

An immediate-mode toolkit that re-emits its whole UI every frame needs a
per-frame representation cheap enough to build, transform and cull, and a
render seam narrow enough that native GPU, WebGL and a headless test target all
implement it. egui's answer is to make painting produce _values_ (`Shape`), and
to lower those values to triangles inside the toolkit, so the render backend's
entire job is "draw these meshes under these clip rects".

### Design philosophy

The `Shape` enum states its own role and its lifetime expectations
([`shapes/shape.rs`][shapesrc]):

> A paint primitive such as a circle or a piece of text. Coordinates are all
> screen space points (not physical pixels).
>
> You should generally recreate your `Shape`s each frame, but storing them
> should also be fine with one exception: `Shape::Text` depends on the
> current `pixels_per_point` (dpi scale) and so must be recreated every time
> `pixels_per_point` changes.

And the seam itself is described in two lines ([`lib.rs`][eplib]):

> A `Mesh` or `PaintCallback` within a clip rectangle.
>
> Everything is using logical points.

Two structures, one of which is an escape hatch. That is the whole contract a
render backend implements.

## Q1 — the backend never sees text at all

`epaint::Shape` has twelve variants — `Noop`, `Vec`, `Circle`, `Ellipse`,
`LineSegment`, `Path`, `Rect`, `Text`, `Mesh`, `QuadraticBezier`,
`CubicBezier`, `Callback` — and the one that matters here is `Text`.

**It carries a `Galley`, not a string.** A `Galley` is
"[t]ext that has been laid out, ready for painting"
([`text/text_layout_types.rs`][galley]) — already shaped, laid out and measured;
the colour is the only thing left to substitute (`TextShape::fallback_color`
replaces "[a]ny `Color32::PLACEHOLDER` in the galley", and
`override_text_color` replaces glyph colour outright,
[`shapes/text_shape.rs`][textshape]). Shapes are then tessellated, so what a
render backend actually consumes is meshes and a texture id.

So egui does not merely keep measurement off the backend — it resolves text
completely before the backend exists, and hands over triangles. A backend
_cannot_ measure text, because by the time it is involved there is no text.

That is the fourth independent subject in this survey to put measurement
somewhere other than the painter, and the most emphatic. Friction §1 is not a
close call.

## Q2 — no capability negotiation, because there is nothing to negotiate

Triangles and a texture are the floor of any GPU backend, so there is nothing
for a backend to decline. egui pays for this by making the toolkit responsible
for everything above triangles — shaping, tessellation, culling — which is
precisely why it cannot target a terminal.

This is the honest cost of the geometry model and the reason it is not
available to us: `sparkles:ui`'s cell backend has no triangles.

## Q3 — geometry, not widgets

Primitives rather than widgets. Nothing in `Shape` names a scrollbar, a text
input or a shadow-as-intent; a `Shadow` exists as a helper that _produces_
shapes, not as a variant a backend must interpret. egui therefore sits with
[Qt][qt] and against [Slint][slint] on this axis, and further along than Qt:
even the primitive vocabulary is gone by the time the seam is reached, since
`ClippedPrimitive` carries a mesh.

## Q4 — a sum type

Unlike Slint and Qt, egui's paint vocabulary is **reified as a sum type**
rather than dispatched through virtual methods. `Shape` is an enum whose
payload varies per variant, which is exactly the shape friction §4 wants for
`DrawOp` and exactly what `sparkles.input.events` already argues for.

Worth noting what this buys egui that inheritance does not: shapes are values,
so they can be collected, transformed, culled and replayed. That is the same
property `RecordingCanvas` and the op-stream parity harness need — which
confirms our reified-command choice was right and only its _encoding_ (a tag
plus eighteen mostly-dead fields) is wrong.

`Shape::Callback` is the escape hatch: backend-specific painting, for the cases
the vocabulary cannot express. A closed sum type with one explicit door — and
the door is typed, since `PaintCallbackInfo` hands the callback its viewport,
clip rect, `pixels_per_point` and screen size ([`paint_callback.rs`][callback]).

Two encoding details are worth copying: `Shape::Vec(Vec<Self>)` makes the
stream a tree where nesting helps and is documented as the slower path
("[f]or performance reasons it is better to avoid it"), and `Shape::Mesh` is
`Arc`-wrapped explicitly "to minimize the size of `Shape`" — the variant's
payload size is treated as a design parameter, which is the discipline
`DrawOp`'s 656-byte era lacked.

## Q5 — sub-unit placement

Continuous coordinates; no sub-unit problem. `Shape`'s own documentation fixes
the unit — "[c]oordinates are all screen space points (not physical pixels)" —
and `ClippedPrimitive` repeats it ("[e]verything is using logical points"), so
the device-pixel conversion is the backend's and the toolkit never names a
position within a cell. Same dissolution of friction §5 as Slint and Qt.

## Q6 — resolved or semantic styling

Fully resolved — colours are concrete by tessellation time. The one deferred
piece is deliberately narrow: `Color32::PLACEHOLDER` inside a `Galley` marks
"colour not yet chosen", resolved at paint time by `TextShape::fallback_color`.
That is a sentinel value inside an otherwise-resolved payload rather than a
second, semantic representation carried alongside — which is a much cheaper
answer to friction §6 than our `visual` _plus_ `slot`.

## Q7 — payload ownership

`Shape::Mesh` is wrapped in `Arc`, and a `Galley` is likewise shared
(`TextShape::galley: Arc<Galley>`), so payloads are **reference-counted rather
than borrowed**. A shape can outlive the frame that built it without the
toolkit interning anything.

The caveat egui states explicitly is a validity rule, not a lifetime one: a
stored `Shape::Text` must be recreated when `pixels_per_point` changes or when
the font atlas is rebuilt. Refcounting answers "may I keep this?"; it does not
answer "is it still correct?", and the second question needs its own stated
invalidation rule.

## Q8 — extent query

`ClippedPrimitive` carries its own clip rect; extent falls out of the
primitives, as in our §8 workaround. There is no "how big is the scene" query
on the seam, because the frame is always painted into a surface whose size the
host already set.

## Strengths

- **The narrowest seam in the survey.** One struct — clip rect plus mesh — so a
  new backend is a rasterizer and nothing else.
- **Commands are values.** Collectable, transformable, cullable, `PartialEq` —
  every property a parity harness wants, with no recorder type.
- **Payload size is a stated design parameter.** `Arc<Mesh>` exists explicitly
  to keep the enum small.
- **Refcounted payloads** remove the "must outlive the frame" question entirely.
- **One typed escape hatch.** `Shape::Callback` makes "the vocabulary cannot
  express this" a visible, contained case with a documented context struct.
- **The deferred-colour trick** (`Color32::PLACEHOLDER`) gets late theming
  without a parallel semantic channel.

## Weaknesses

- **Structurally single-target.** Everything above triangles lives in the
  toolkit, so a device that cannot rasterize a mesh cannot be a backend at all.
- **All fidelity decisions are made before the backend sees anything** — a
  target with different capabilities cannot do better, only differently.
- **Refcounting is not validity.** A retained `Shape::Text` silently goes stale
  on a dpi change or atlas rebuild; the rule is prose in a doc comment.
- **`Shape::Vec` makes the stream a tree** whose flattening cost is real enough
  that the docs discourage it.
- **`Shape::Callback` is unportable by construction** — a frame that uses one
  is no longer backend-neutral.
- **Nothing states which backend behaviours are required**, because the
  question is assumed away rather than answered.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                         | Trade-off                                                                                           |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Resolve text to a **`Galley`** before it can be painted       | Shaping and layout are the toolkit's problem exactly once, and the result is cacheable and shared | The backend cannot improve on the toolkit's shaping, and the galley goes stale on dpi/atlas changes |
| **Tessellate inside the toolkit**; the seam carries meshes    | The narrowest possible backend contract; identical output across wgpu, glow and WebGL             | Excludes every non-triangle target — a cell grid can never be a backend                             |
| A **12-variant `enum`**, not virtual dispatch                 | Shapes are values: collect, transform, cull, compare                                              | The vocabulary is closed; a new primitive is a breaking change to the enum                          |
| `Arc<Mesh>` / `Arc<Galley>` rather than borrowed slices       | No lifetime obligation; a payload may outlive its frame                                           | Refcount traffic per frame, and sharing hides staleness                                             |
| One **escape hatch** (`Shape::Callback`) with a typed context | Backend-specific painting stays possible without widening the vocabulary                          | A frame containing one is no longer portable, and parity testing cannot cover it                    |
| **Logical points** at the seam, device pixels in the backend  | Layout stays resolution-independent; the backend owns `pixels_per_point`                          | Anything pixel-exact (hairlines, snapping) is not expressible at the seam                           |
| Late colour via **`Color32::PLACEHOLDER`**                    | Theming without carrying a second, semantic style channel                                         | A magic sentinel inside the payload; nothing type-checks that it was substituted                    |
| **No capability negotiation at all**                          | Triangles are the floor of every target egui admits                                               | The model gives no guidance whatsoever for a survey subject like ours that spans unlike devices     |

## Bearing on the proposal

1. **A sum type is the right encoding for a reified command** — and egui shows
   the reification itself is worth keeping, which our own tooling depends on.
2. **Reference-counted payloads** are a lighter answer to §7 than interning:
   share the payload, do not index into a host table.
3. **One explicit escape hatch** (`Callback`) beats an open-ended optional
   method set — it makes "the vocabulary cannot express this" a visible,
   contained case rather than a silently skipped op.
4. The geometry model itself is **not** available to us, and the reason is
   worth recording: it moves all fidelity decisions above the seam, which a
   terminal backend cannot honour.
5. **A shared payload needs a stated invalidation rule, not just a refcount.**
   If `sparkles:ui` adopts shared text or image payloads for §7, it must also
   say what makes one stale — egui names dpi changes and atlas rebuilds, and
   that rule lives in prose, which is where ours would rot.

## Sources

Every path verified to resolve at
[`97603fc082aa4eecfeb7feccbcb6c2507dffaf28`][rev] over
`raw.githubusercontent.com`.

- The vocabulary: [`crates/epaint/src/shapes/shape.rs`][shapesrc] (`enum Shape`),
  [`shapes/text_shape.rs`][textshape] (`TextShape`),
  [`shapes/paint_callback.rs`][callback] (`PaintCallbackInfo`)
- The seam: [`crates/epaint/src/lib.rs`][eplib] (`ClippedPrimitive`,
  `enum Primitive`) and [`crates/epaint/src/tessellator.rs`][tess]
- Measurement: [`crates/epaint/src/text/text_layout_types.rs`][galley]
  (`Galley`)
- Context: [`Cargo.toml`][cargo], [`ARCHITECTURE.md`][arch],
  [`LICENSE-MIT`][mit], [`LICENSE-APACHE`][apache], [docs.rs/epaint][shape]

<!-- References -->

[apache]: https://github.com/emilk/egui/blob/97603fc082aa4eecfeb7feccbcb6c2507dffaf28/LICENSE-APACHE
[arch]: https://github.com/emilk/egui/blob/97603fc082aa4eecfeb7feccbcb6c2507dffaf28/ARCHITECTURE.md
[callback]: https://github.com/emilk/egui/blob/97603fc082aa4eecfeb7feccbcb6c2507dffaf28/crates/epaint/src/shapes/paint_callback.rs
[cargo]: https://github.com/emilk/egui/blob/97603fc082aa4eecfeb7feccbcb6c2507dffaf28/Cargo.toml
[docsegui]: https://docs.rs/egui/latest/egui/
[eplib]: https://github.com/emilk/egui/blob/97603fc082aa4eecfeb7feccbcb6c2507dffaf28/crates/epaint/src/lib.rs
[galley]: https://github.com/emilk/egui/blob/97603fc082aa4eecfeb7feccbcb6c2507dffaf28/crates/epaint/src/text/text_layout_types.rs
[mit]: https://github.com/emilk/egui/blob/97603fc082aa4eecfeb7feccbcb6c2507dffaf28/LICENSE-MIT
[qt]: ./qt-qpaintengine.md
[repo]: https://github.com/emilk/egui
[rev]: https://github.com/emilk/egui/tree/97603fc082aa4eecfeb7feccbcb6c2507dffaf28
[shape]: https://docs.rs/epaint/latest/epaint/enum.Shape.html
[shapesrc]: https://github.com/emilk/egui/blob/97603fc082aa4eecfeb7feccbcb6c2507dffaf28/crates/epaint/src/shapes/shape.rs
[slint]: ./slint.md
[textshape]: https://github.com/emilk/egui/blob/97603fc082aa4eecfeb7feccbcb6c2507dffaf28/crates/epaint/src/shapes/text_shape.rs
[tess]: https://github.com/emilk/egui/blob/97603fc082aa4eecfeb7feccbcb6c2507dffaf28/crates/epaint/src/tessellator.rs
