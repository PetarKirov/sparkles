# egui — the backend receives geometry, not commands

**Category:** backend gets geometry. **Last reviewed:** August 22, 2026.
Pinned at [`97603fc0`][rev]; types per the [`epaint::Shape` reference][shape].

The far end of the design space, and on the list to bound it. If Slint tells a
backend _what a thing is_ and Qt tells it _what shape to fill_, egui tells it
_where the triangles are_.

## Q1 — the backend never sees text at all

`epaint::Shape` has twelve variants — `Noop`, `Vec`, `Circle`, `Ellipse`,
`LineSegment`, `Path`, `Rect`, `Text`, `Mesh`, `QuadraticBezier`,
`CubicBezier`, `Callback` — and the one that matters here is `Text`.

**It carries a `Galley`, not a string.** A `Galley` is already shaped, laid out
and measured; the colour is the only thing left to substitute (uncoloured runs
marked `Color32::PLACEHOLDER` are filled in at paint time). Shapes are then
tessellated, so what a render backend actually consumes is meshes and a texture
id.

So egui does not merely keep measurement off the backend — it resolves text
completely before the backend exists, and hands over triangles. A backend
_cannot_ measure text, because by the time it is involved there is no text.

That is the fourth independent subject in this survey to put measurement
somewhere other than the painter, and the most emphatic. Friction §1 is not a
close call.

## Q3, Q4 — geometry, in a sum type

Primitives rather than widgets, and — unlike Slint and Qt — **reified as a sum
type** rather than dispatched through virtual methods. `Shape` is an enum whose
payload varies per variant, which is exactly the shape friction §4 wants for
`DrawOp` and exactly what `sparkles.input.events` already argues for.

Worth noting what this buys egui that inheritance does not: shapes are values,
so they can be collected, transformed, culled and replayed. That is the same
property `RecordingCanvas` and the op-stream parity harness need — which
confirms our reified-command choice was right and only its _encoding_ (a tag
plus eighteen mostly-dead fields) is wrong.

`Shape::Callback` is the escape hatch: backend-specific painting, for the cases
the vocabulary cannot express. A closed sum type with one explicit door.

## Q2 — no capability negotiation, because there is nothing to negotiate

Triangles and a texture are the floor of any GPU backend, so there is nothing
for a backend to decline. egui pays for this by making the toolkit responsible
for everything above triangles — shaping, tessellation, culling — which is
precisely why it cannot target a terminal.

This is the honest cost of the geometry model and the reason it is not
available to us: `sparkles:ui`'s cell backend has no triangles.

## Q5, Q6, Q7, Q8

- **Q5:** continuous coordinates; no sub-unit problem.
- **Q6:** fully resolved — colours are concrete by tessellation time.
- **Q7:** `Shape::Mesh` is wrapped in `Arc`, and a `Galley` is likewise shared,
  so payloads are **reference-counted rather than borrowed**. A shape can
  outlive the frame that built it without the toolkit interning anything.
- **Q8:** `ClippedPrimitive` carries its own clip rect; extent falls out of the
  primitives, as in our §8 workaround.

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

[rev]: https://github.com/emilk/egui/tree/97603fc082aa4eecfeb7feccbcb6c2507dffaf28
[shape]: https://docs.rs/epaint/latest/epaint/enum.Shape.html
