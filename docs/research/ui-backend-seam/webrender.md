# WebRender — the display list is a byte stream, and it says what it cannot draw

**Category:** display list → batching. **Last reviewed:** August 23, 2026.
Pinned at [`44e15142`][rev] (mozilla-central `gfx/wr`, via the
`mozilla-firefox/firefox` GitHub mirror).

The only surveyed subject whose seam is a **serialized value** rather than a
call sequence, and the only one with a written, shipped answer to "what happens
to content this vocabulary cannot express". Both are directly on the questions
[`canvas-seam-friction.md`](../../specs/ui-skia/canvas-seam-friction.md) raises
in §2, §4 and §7.

| Field                | Value                                                                                                 |
| -------------------- | ----------------------------------------------------------------------------------------------------- |
| **Language**         | Rust                                                                                                  |
| **License**          | MPL 2.0 ([`gfx/wr/LICENSE`][license])                                                                 |
| **Repository**       | canonical: `gfx/wr` in mozilla-central; read here through the [`mozilla-firefox/firefox`][rev] mirror |
| **Documentation**    | crate docs in [`webrender/src/lib.rs`][wrlib]; subsystem docs in [`webrender/doc/`][blob]             |
| **Category**         | display list → batching                                                                               |
| **Pinned revision**  | `44e151427db27db6b789e3be5439f0edbcf446de`                                                            |
| **Seam under study** | [`DisplayItem`][ditem] / [`BuiltDisplayList`][dlist] in the `webrender_api` crate                     |
| **Consumers**        | Gecko (Firefox) and Servo, as out-of-process display-list producers                                   |

> [!NOTE]
> [`gfx/wr/README.md`][readme]: "the canonical home for this code is in gfx/wr
> folder of the mozilla-central repository … The Github repository at
> `servo/webrender` should be considered a downstream mirror."

## Overview

### What it solves

WebRender's own summary, from the crate documentation:

> WebRender turns display lists into GPU draw calls. It is the rendering engine
> of Firefox, and can also be used standalone.
>
> — [`webrender/src/lib.rs`][wrlib]

The seam is therefore not "toolkit talks to backend" but "**layout process
talks to renderer process**". A display list is built by one party, finalized
into bytes, handed across a transaction boundary, and consumed by a scene
builder on another thread. That constraint — the command stream must survive
serialization, IPC and a thread hop — is what makes WebRender useful here: it
is `sparkles:ui`'s `DrawOp[]` with the frame-lifetime assumption removed.

### Design philosophy

Three commitments run through the API and shape every answer below.

1. **The vocabulary is closed and CSS-shaped.** `DisplayItem` enumerates
   thirteen "real content" kinds plus clips, spaces and markers — and no escape
   hatch for arbitrary drawing.
2. **What the vocabulary cannot express becomes an image.** Stated verbatim in
   [`webrender/doc/blob.md`][blob]: "Blob image is fallback mechanism for
   webrender that Gecko uses to render primitives that aren't currently
   supported by webrender."
3. **The stream is data, not calls.** Items are poked into a `Vec<u8>` and
   peeked back out; there is no painter object and no virtual dispatch anywhere
   on the producer side.

## How it works

The seam's defining declaration is a plain Rust sum type
([`display_item.rs`][ditem]):

```rust
#[repr(u8)]
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize, PeekPoke)]
pub enum DisplayItem {
    // These are the "real content" display items
    Rectangle(RectangleDisplayItem),
    HitTest(HitTestDisplayItem),
    Text(TextDisplayItem),
    Line(LineDisplayItem),
    Border(BorderDisplayItem),
    BoxShadow(BoxShadowDisplayItem),
    Gradient(GradientDisplayItem),
    RadialGradient(RadialGradientDisplayItem),
    ConicGradient(ConicGradientDisplayItem),
    Image(ImageDisplayItem),
    RepeatingImage(RepeatingImageDisplayItem),
    YuvImage(YuvImageDisplayItem),
    BackdropFilter(BackdropFilterDisplayItem),

    // Clips
    RectClip(RectClipDisplayItem),
    RoundedRectClip(RoundedRectClipDisplayItem),
    ImageMaskClip(ImageMaskClipDisplayItem),
    ClipChain(ClipChainItem),
    // … plus Iframe, Push/PopReferenceFrame, Push/PopStackingContext,
    // the Set* array markers, and DebugMarker.
}
```

Every content variant embeds one shared header — `CommonItemProperties`, four
fields: a `clip_rect` ("Many items are logically infinite, and rely on this
clip_rect to define their bounds"), a `clip_chain_id`, a `spatial_id` ("The
coordinate-space the item is in (yes, it can be really granular)") and
`PrimitiveFlags` — so the per-kind struct carries only what that kind needs.

The list itself is two byte vectors plus a descriptor
([`display_list.rs`][dlist]):

```rust
pub struct DisplayListPayload {
    /// Serde encoded bytes. Mostly DisplayItems, but some mixed in slices.
    pub items_data: Vec<u8>,
    /// Serde encoded SpatialTreeItem structs
    pub spatial_tree: Vec<u8>,
}

pub struct BuiltDisplayList {
    payload: DisplayListPayload,
    descriptor: BuiltDisplayListDescriptor,
}
```

Pushing is a serialization step, not a method call — `push_item_to_section`
reduces to `poke_into_vec(item, …)`. Reading back is the mirror,
`peek_from_slice`, over the in-tree [`peek-poke`][peekpoke] encoding, whose
`unsafe trait Poke` requires each type to declare `max_size()`, "the maximum
number of bytes that the serialized version of `Self` will occupy". That
maximum is an end-of-stream sentinel, never the per-item cost — the iterator
stops when fewer than `max_size()` bytes remain, which is why the builder
appends a red zone with `ensure_red_zone::<di::DisplayItem>`:

```rust
// A "red zone" of DisplayItem::max_size() bytes has been added to the
// end of the serialized display list. If this amount, or less, is
// remaining then we've reached the end of the display list.
if self.data.len() <= di::DisplayItem::max_size() {
    return None;
}
```

Variable-length payloads — glyph runs, gradient stops, filter chains, clip-chain
members — do not live in the item. They are written **after** it as a
length-prefixed array by `push_iter_impl`, whose format comment is exact:

```rust
// Format:
// payload_byte_size: usize, item_count: usize, [I; item_count]
```

and are recovered by the iterator into an `ItemRange<'a, T>` — a borrowed
`&[u8]` window plus a `PhantomData<T>`, iterated lazily. Four `DisplayItem`
variants exist purely to introduce such an array: `SetGradientStops`,
`SetFilterOps`, `SetFilterData`, `SetPoints` are marker items that
`BuiltDisplayListIter::next` consumes and never yields.

## Q1 — measurement unit, and who answers

**Measurement is not on the seam, and it is not even in the same crate as
drawing.** `DisplayItem::Text` carries a `FontInstanceKey`, a `ColorF` and a
`bounds` rect; the glyphs arrive as a trailing array of
`GlyphInstance { index: GlyphIndex, point: LayoutPoint }` — **already shaped,
already positioned**. Shaping and measurement happened entirely in the
producer (Gecko or Servo) before a display item existed. The `bounds` field's
own doc says it is not load-bearing geometry:

> The area all the glyphs should be found in. Strictly speaking this isn't
> necessarily needed, but layout engines should already "know" this, and we
> use it cull and size things quickly before glyph layout is done.
>
> — [`display_item.rs`][ditem]

There _is_ a measurement service, but it sits on the resource API rather than
on any painter: `RenderApi::get_glyph_dimensions(FontInstanceKey, Vec<GlyphIndex>)`
returns `Vec<Option<GlyphDimensions>>` with a device-space `advance: f32`, by a
blocking round-trip to the scene-builder thread ([`render_api.rs`][rapi]). It
is an afterthought and admits as much:

> Note: Internally, the internal texture cache doesn't store 'empty' textures
> (height or width = 0). This means that glyph dimensions e.g. for spaces (' ')
> will mostly be None.

A metrics API that cannot measure a space is not a metrics API; it is a
glyph-cache probe with a public name. **This is a fifth independent confirmation
of [F1](./comparison.md)**,
and the strongest one: WebRender does not merely move measurement off the
painter, it refuses to accept unshaped text at all.

The unit answer is more interesting than "pixels". WebRender has no single
unit; [`units.rs`][units] declares **seven phantom-typed coordinate spaces** —
`DevicePixel`, `FramebufferPixel`, `PicturePixel`, `RasterPixel`, `LayoutPixel`,
`WorldPixel`, `VisPixel` — and every geometric type is `euclid`-tagged with one of them:
`LayoutRect = Box2D<f32, LayoutPixel>`, `DeviceIntRect = Box2D<i32, DevicePixel>`.
A conversion between spaces is a typed `Scale`, so it cannot happen by accident.

## Q2 — is the contract stated in one place?

Two answers, because WebRender has two seams and treats them oppositely.

**The display-list seam has no capability negotiation and no machine-checkable
contract.** A producer may push any `DisplayItem`, and the API's own escape
hatch says what happens when it pushes a wrong one:

> NOTE: It is usually preferable to use the specialized methods to push display
> items. Pushing unexpected or invalid items here may result in WebRender
> panicking or behaving in unexpected ways.
>
> — `DisplayListBuilder::push_item`, [`display_list.rs`][dlist]

The real contract is the two dozen typed `push_*` builder methods plus prose in
[`webrender/doc/`][clipdoc]. `static assert(isCanvas!T)` says little; so does
`BuiltDisplayList` type-checking.

**The compositor seam declares capabilities explicitly**, in the Qt style —
and improves on it. `trait Compositor` ([`composite.rs`][composite]) is the
optional OS-compositor backend, and it has a `get_capabilities` method
returning a struct rather than a bitfield:

```rust
pub struct CompositorCapabilities {
    pub virtual_surface_size: i32,
    pub redraw_on_invalidation: bool,
    pub max_update_rects: usize,
    pub supports_surface_for_backdrop: bool,
    pub supports_external_compositor_surface_negative_scaling: bool,
}
```

The design note on its `Default` impl is the part worth stealing:

> The default set of compositor capabilities for a given platform. These should
> only be modified if a compositor diverges specifically from the default
> behavior so that compositors don't have to track which changes to this
> structure unless necessary.

That is a **declared floor plus a divergence list**: a new backend states only
where it differs, and adding a capability does not break existing backends.
[F5](./comparison.md)
puts a stated floor at the bottom of its floor / defaulted / refusable ladder;
this is the cheapest known encoding of one, and it is cheaper than both
`PaintEngineFeature`'s bitfield and the `__traits(compiles)` probing
`sparkles:ui` does at each interpreter call site (friction §2).

## Q3 — semantic widgets, or primitives?

**Both, on different channels — and this is the finding that most complicates
[F4](./comparison.md).**

The item vocabulary is _presentational_, not widget-level: `Border`,
`BoxShadow`, `Gradient`, `BackdropFilter` are CSS concepts, but there is no
`Scrollbar` item, no `Button`, no `TextInput`. Slint ships `draw_text_input`;
WebRender would not.

Yet a scrollbar _is_ visible at the seam — as **one bit on the shared header**:

```rust
pub struct PrimitiveFlags(u8);

bitflags! {
    impl PrimitiveFlags: u8 {
        const IS_BACKFACE_VISIBLE = 1 << 0;
        /// If set, this primitive represents a scroll bar container
        const IS_SCROLLBAR_CONTAINER = 1 << 1;
        /// This is used as a performance hint - this primitive may be promoted to a native
        /// compositor surface under certain (implementation specific) conditions.
        const PREFER_COMPOSITOR_SURFACE = 1 << 2;
        // …
    }
}
```

The consumer acts on it, in [`scene_building.rs`][scene]:

```rust
// If stacking context is a scrollbar, force a new slice for the primitives
// within. The stacking context will be redundant and removed by above check.
let set_tile_cache_barrier = prim_flags.contains(PrimitiveFlags::IS_SCROLLBAR_CONTAINER);

if set_tile_cache_barrier {
    self.add_tile_cache_barrier_if_needed(SliceFlags::IS_SCROLLBAR);
}
```

So the renderer knows "this is a scrollbar" — for a caching decision — while
the scrollbar's _appearance_ arrives as ordinary rects. Friction §3 —
`scrollbar` is a widget concept in the drawing seam — reads as a binary: either
`scrollbar` is an op kind whose payload carries the whole widget's state — all
fourteen fields of it — or the semantics are lost. WebRender demonstrates a
third position: **semantics as a flag on a primitive, worth one bit, consumed
by the backend for its own purposes and ignorable by any backend that has no
use for it.**

`HitTest` is the same idea taken further — a display item with no appearance at
all, carrying only a rect and an `ItemTag`, described as "A minimal
hit-testable item for the parent browser's convenience, and is slimmer than a
RectangleDisplayItem (no color)".

## Q4, Q7 — command shape and payload ownership

The same mechanism answers both, so they are treated together.

**Q4 (shape).** `DisplayItem` is a sum type at the type level and a
variable-width tagged encoding on the wire. The type-level half is the shape
`DrawOp` also takes — a closed sum over per-kind payloads, dispatched by
`match!`, so an illegal field combination is unrepresentable in either seam. The
wire half is where the two part, and it is exactly the live trade
[F3](./comparison.md)
records. `poke_into_vec` writes the discriminant plus _that variant's_ payload,
so a display list never pays for its widest item; `DrawOp` is one width for
every arm, bounded by `static assert(DrawOp.sizeof <= 64)` and set by `TextRun`,
so a `PopClip` that carries nothing costs what a text run costs (friction §4).

What variable stride buys WebRender is what WebRender needs and `sparkles:ui`
does not: the widest-variant tax is paid per byte shipped across a process
boundary, rather than per slot in an array that never leaves the frame. What the
single width buys back is a `DrawOp[]` whose elements are plain comparable
values — which is what lets `RecordingCanvas` serve as a pairwise-comparable
parity oracle, and the friction log records that as working.

`MAX_TEXT_RUN_LENGTH = 2040` — a text run is split rather than allowed to grow
unbounded — is the only length cap in the format, and it exists for a GPU
texture-width reason, not a format one.

WebRender also documents the residual dead field, and it is friction §3 in
miniature. `LineDisplayItem` carries a `wavy_line_thickness: f32` whose doc says
"Value irrelevant for non-wavy lines", followed by:

```rust
    // FIXME: this was done before we could use tagged unions in enums, but now
    // it should just be part of LineStyle::Wavy.
    pub wavy_line_thickness: f32,
```

A field dead for three of four `LineStyle` values, with an in-tree note that it
should be a variant payload. Splitting the sum by kind is what keeps that class
of field out of most of `DrawOp` — but not out of all of it. The `Scrollbar`
payload carries `trackGlyph` and `thumbGlyph`, a cell backend's answer, past
every pixel backend that will never read them; WebRender's note is the same
observation, written by someone who already knows where the field belongs.

**Q7 (ownership).** Nothing large is ever borrowed by an item.

- **Small variable-length payloads are copied inline**, immediately after the
  item, as `payload_byte_size, item_count, [I; item_count]`. `push_text` copies
  each `GlyphInstance` into the buffer with its point rebased onto the run's
  origin. When the list is read back, `ItemRange<'a, T>` borrows _from the list's
  own bytes_ — so the borrow's lifetime is the list's, not the frame's, and the
  producer that built it is already gone.
- **Large payloads are keyed resources with an explicit, stated lifetime.**
  Images and fonts never appear in a display item; `ImageKey`, `FontKey` and
  `FontInstanceKey` do, and the payload travels in a separate `ResourceUpdate`
  channel on the same transaction, whose doc states the rule the seam cannot
  enforce ([`render_api.rs`][rapi]):

  > It is invalid to continue referring to the image key in any display list in
  > the transaction that contains the `DeleteImage` message and subsequent
  > transactions.

This is the strong form of
[F8](./comparison.md):
**copy-inline for small payloads and an out-of-band keyed store for large
ones**, with the in-stream reference held as a window into bytes the stream
itself owns. `sparkles:ui` copies too — `CmdBuffer.textRun` interns each run
into the frame arena, which is what makes a `scope` source safe to draw — but
the reference it then carries is a `const(char)[]` into that arena, not an
offset into the operation stream. That difference is friction §7: an operation
is valid while the buffer that built it is alive and unreset, so it does not
survive a thread hop or an IPC boundary — precisely the case `M7/T5` walks into,
and the retain boundary `UI-O4` leaves open.

## Q5 — sub-unit placement

Relocated rather than dissolved, which is
[F6](./comparison.md)'s
point. `LayoutRect` is `Box2D<f32, LayoutPixel>` and hairlines are just thin
rects, so the sub-unit question stops being a placement vocabulary and becomes a
snapping question in `DevicePixel` space, answered by the party that knows the
device scale. What the seam carries instead is `LineDisplayItem`'s
`wavy_line_thickness: f32` and a `LineStyle` (`Solid`, `Dotted`, `Dashed`,
`Wavy`) — a fidelity vocabulary, not a position vocabulary, which is the named
half of what F6 recommends. `RuleEdge` is the other kind: a position
vocabulary, six enumerators wide, which is friction §5.

The adjacent finding is about clipping rather than sub-unit placement, and it
bears on friction §2's clip pair. WebRender **abandoned hierarchical clipping**
and does not have a `pushClip`/`popClip` stack: every item names a
`clip_chain_id` and a `spatial_id` in its header, and the clip and spatial trees
travel out of band. [`CLIPPING_AND_POSITIONING.md`][clipdoc] lists what the
push/pop model could not represent, including "Completely non-hierarchical
clipping situations, such as when items are clipped by some clips in the
hierarchy, but not others". A push/pop clip pair is a design that a sufficiently
demanding content model outgrows.

## Q6 — resolved appearance, semantic role, or both

Predominantly **resolved**: colors are `ColorF`, geometry is final, gradients
arrive as computed stop arrays. WebRender has no equivalent of `sparkles:ui`'s
`Slot` because it has no re-resolving consumer — there is exactly one backend.

But it is not fully resolved, and the exception is worth recording.
`RectangleDisplayItem.color` is not a `ColorF`; it is a
`PropertyBinding<ColorF>`:

```rust
/// A binding property can either be a specific value
/// (the normal, non-animated case) or point to a binding location
/// to fetch the current value from.
pub enum PropertyBinding<T> {
    /// Non-animated value.
    Value(T),
    /// Animated binding.
    Binding(PropertyBindingKey<T>, T),
}
```

So a display item may carry a **late-bound handle plus a fallback value**, and
the renderer resolves it per frame from a property table updated by transaction
— which is how an animation runs without rebuilding the display list. That is a
sharper version of the choice friction §6 describes as hedging. `sparkles:ui`
stores a `Slot` on six of its eight payloads, beside the resolved colour the
primitive paints from, and reconstructs a whole `Visual` on demand through
`visualOf` rather than storing one — which makes the hedge cheap without making
it a decision. `PropertyBinding` is a decision: one two-variant value whose
second variant names a table the consumer already holds, and one of the cheaper
encodings [F9](./comparison.md) enumerates.

The other half of Q6 is where high-level constructs get lowered.
`DisplayListBuilder::push_shadow`/`pop_all_shadows` accept a semantic `Shadow`
and then **desugar it inside the builder** into blur stacking contexts holding
offset, recolored copies of the shadowed content, so the consumer never sees a
`Shadow` at all. The comment records that this placement was _moved_:

> Desugar the captured shadow scope into standard display items … **This
> replaces the scene builder's shadow expansion.**
>
> — [`display_list.rs`][dlist]

[F4](./comparison.md)
counts six places a lowering can live, and the producer is one of them.
WebRender is that entry's strongest instance, and it migrated toward it over
time: **the producer's own builder, before the value is serialized.** The
construct is semantic at the call site and primitive on the wire.

## Q8 — extent query

**The display list carries no extent, and this is deliberate.**
`Transaction::set_display_list(epoch, namespace, (pipeline_id, display_list))`
takes no size at all; the viewport is set independently by
`Transaction::set_document_view(device_rect: DeviceIntRect)` ([`render_api.rs`][rapi]).
`BuiltDisplayListDescriptor` holds IPC timestamps and node counts, not bounds.

That is [F7](./comparison.md)'s
three questions kept apart: **surface** extent is configured by the party that
owns the window, **layout** extent stays with the engine that built the list,
and **ink** extent is not offered at all. Notably, items are also _not_ required
to be within any bound — `clip_rect` exists because "Many items are logically
infinite". A scene whose primitives are individually unbounded cannot have its
extent derived by scanning them — and derive-by-scan is the arm `sparkles:ui`
lands on: nothing on `CmdBuffer`, the display list or the arena reports extent,
so `skia-canvas-render.d` folds every operation's rect to obtain one
(friction §8).

## Strengths

- **The stream survives leaving the process.** Serialization is the encoding, not
  a feature bolted on; recording, replay, capture (`DisplayListCapture`) and
  cross-thread submission are free consequences.
- **Variable-width encoding with a max-size sentinel** gets sum-type safety at
  the type level and per-variant cost on the wire, with no pointer chasing, and
  **trailing length-prefixed arrays** carry variable-length payloads without
  interning or borrowing from the producer.
- **A stated floor for the optional backend** (`CompositorCapabilities`
  defaults) that a new backend adopts wholesale and amends selectively.
- **Semantics as flags on primitives** (`IS_SCROLLBAR_CONTAINER`,
  `PREFER_COMPOSITOR_SURFACE`) — one bit, ignorable, no new op kind.
- **A named, documented fallback path** for content outside the vocabulary, so
  the vocabulary is allowed to stay small.

## Weaknesses

- **The producer-side contract is prose and panics.** `push_item` warns that
  invalid items "may result in WebRender panicking"; there is no negotiation.
- **The vocabulary is not extensible by a consumer.** Adding a primitive means
  changing the enum, the builder, the scene builder and the batcher — which is
  why the blob fallback exists.
- **The blob escape hatch is expensive and known to be.** [`blob.md`][blob]
  records eager rasterization of the whole active area during scene building
  ("we potentially process a lot more content than will be displayed"), plus a
  synchronous "late rasterization" path the document itself hopes to delete.
- **The measurement API is vestigial**, cannot measure zero-area glyphs, and
  blocks on another thread.
- **One backend.** Every conclusion about the _drawing_ seam here is about a
  producer/consumer contract, not about backend portability; only the
  `Compositor` trait is a plural-backend seam.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                              | Trade-off                                                                                            |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Display list is a serialized `Vec<u8>`, not a `Vec<DisplayItem>` | Must cross a process and thread boundary; compact and cheap to build                   | No random access; iteration is the only reader; a malformed list is a panic, not a type error        |
| `#[repr(u8)]` sum type with per-variant structs                  | Illegal field combinations unrepresentable; per-variant wire cost                      | Adding a variant is an ABI change for every consumer                                                 |
| Trailing length-prefixed arrays + `Set*` marker items            | Variable-length payloads without pointers or a second allocation                       | Reader must keep per-array cursor state and clear it between items                                   |
| Large payloads are keys into a resource cache                    | Payload lifetime is decoupled from list lifetime; sharing and eviction become possible | Key validity is documented, not enforced — a stale key is a producer bug WebRender cannot catch      |
| Glyphs arrive pre-shaped as `GlyphInstance`                      | Shaping belongs to the layout engine that owns the text model                          | Renderer cannot measure; the metrics API it does expose is incomplete                                |
| Seven phantom-typed coordinate spaces                            | A space confusion is a compile error, not a rendering bug                              | Pervasive `cast_unit` friction, acknowledged in-tree as needing cleanup                              |
| Non-hierarchical clip + spatial trees, referenced by id          | Real CSS content is not hierarchically clipped                                         | Every item pays a `clip_chain_id` and `spatial_id`; the trees are a second stream to keep consistent |
| Semantics as `PrimitiveFlags` bits, not as item kinds            | A backend that does not care ignores the bit; no new op kind, no dead fields           | Only expresses booleans — a scrollbar's geometry still arrives as primitives                         |
| Unsupported content becomes a blob image                         | The item vocabulary stays small and closed while coverage stays total                  | Eager rasterization, a synchronous late path, and a whole second rasterizer the embedder must supply |
| Shadows desugared in the builder                                 | The consumer's vocabulary shrinks; the call site stays semantic                        | The producer must own the lowering, and the wire loses the author's intent                           |

## Bearing on the proposal

1. **Name the floor, then let a backend declare only its divergences.**
   `CompositorCapabilities`'s defaults-plus-divergence pattern is a better
   answer to friction §2 and F5 than either a Qt bitfield or the
   `__traits(compiles)` probes: a `CanvasCaps` struct with a documented
   default means adding a capability does not break `GridCanvas`, and a golden
   test can read the struct instead of guessing.
2. **Price the single width, and keep it for a reason rather than by default.**
   `DrawOp` is already the closed sum `DisplayItem` is; the question friction §4
   leaves open is the second half — that every arm is as wide as `TextRun`.
   WebRender shows what variable stride buys, and where: on a wire, per byte
   shipped, not per slot in a frame-local array. Record the trade
   [F3](./comparison.md) names, and record that the budget is a ceiling the
   widest payload fits under, so the tax is bounded and the operations stay
   comparable values.
3. **Carry semantics as flags on a primitive where a boolean suffices.**
   `IS_SCROLLBAR_CONTAINER` is the cheapest thing in this survey. The
   `Scrollbar` arm needs _geometry_, so it cannot collapse to a flag entirely —
   but its cell-only fields (`trackGlyph`, `thumbGlyph`) are exactly the part a
   pixel backend never reads, and a role flag beside plain rects is what a
   backend with no scrollbar opinion wants in their place. That widens friction
   §3's binary, and gives [F4](./comparison.md) a cheaper spelling of its
   backend-lowered arm: a bit the consumer is free to ignore.
4. **Move the borrow's anchor from the arena to the stream.** The copy is not
   the open question: `CmdBuffer.textRun` already copies each run into the frame
   arena. What friction §7 records is that the resulting `const(char)[]` is
   anchored to a buffer's liveness, and needs the `launder` cast to be
   expressible under `dip1000` at all. An `ItemRange`-style window into bytes
   the operation stream itself owns is the offset-pair form
   [F8](./comparison.md) names as the stronger one — `@safe`, trivially
   copyable, transferable between threads — which is what `M7/T5` and `UI-O4`
   are both asking for.
5. **Consider a `PropertyBinding`-shaped answer to friction §6** instead of
   storing a resolved colour and a `Slot` side by side: one two-variant value,
   resolved or late-bound to a table the consumer already holds. The HTML
   interpreter is exactly such a consumer, and it is the only one that reads the
   role at all.
6. **Answer extent beside the display list, not by scanning it.** WebRender
   separates [F7](./comparison.md)'s three extents cleanly, and adds a reason
   friction §8 does not state: items may be _logically infinite_ and bounded
   only by their clip, so scanning primitives for an extent is unsound in
   general, not merely inconvenient. The scan in `skia-canvas-render.d` works
   only because a `TextRun`'s `rect.width` happens to be its advance in cells.
   The offscreen case wants a layout query, or an extent maintained as the
   stream is built.
7. **Reconsider `pushClip`/`popClip` as the clip model, not just as an optional
   primitive.** [`CLIPPING_AND_POSITIONING.md`][clipdoc] is a written record of
   a hierarchical clip stack failing against real content. `sparkles:ui` may
   never need non-hierarchical clipping — but the friction log questions only
   how the pair is discovered, not whether hierarchy is the right model, and
   this is evidence that the model is a choice with a known failure mode.
8. **Decide, explicitly, what the seam refuses to carry — and name the escape.**
   This is WebRender's largest transferable idea and the one no other surveyed
   subject states. A closed vocabulary is only affordable because `blob.md`
   names the fallback in one sentence. `sparkles:ui` states each degradation at
   the point it is probed — `ruleEndpoints` plus a cell-aligned `line` for a
   missing `rule`, `paintScrollbarCells` glyph-per-cell for a missing
   `scrollbar`, and nothing at all for the clip pair, since the display list has
   already culled what a clip would hide. What it states nowhere is the boundary
   those degradations sit inside: which content the vocabulary declines to
   carry, and what a producer is expected to do with it. That is one paragraph,
   and it belongs beside `isCanvas`.

## Sources

All read at the pinned SHA, under `gfx/wr/`:

- [`webrender_api/src/display_item.rs`][ditem] — `DisplayItem`,
  `CommonItemProperties`, `PrimitiveFlags`, `TextDisplayItem`,
  `LineDisplayItem`, `HitTestDisplayItem`.
- [`webrender_api/src/display_list.rs`][dlist] — `BuiltDisplayList`,
  `DisplayListPayload`, `DisplayListBuilder` (`push_item`, `push_text`,
  `push_iter_impl`, `push_shadow`/`pop_all_shadows`), `BuiltDisplayListIter`.
- [`webrender_api/src/image.rs`][image] — `BlobImageHandler`,
  `AsyncBlobImageRasterizer`, `BlobImageData`; [`font.rs`][font] —
  `GlyphInstance`, `GlyphDimensions`; [`units.rs`][units] — the coordinate
  spaces; [`lib.rs`][apilib] — `PropertyBinding`.
- [`webrender/src/lib.rs`][wrlib] — crate overview, thread split, frame anatomy;
  [`render_api.rs`][rapi] — `Transaction`, `ResourceUpdate`, `set_display_list`,
  `set_document_view`, `get_glyph_dimensions`; [`composite.rs`][composite] —
  `Compositor`, `CompositorCapabilities`; [`scene_building.rs`][scene] —
  `SliceFlags::IS_SCROLLBAR`.
- [`peek-poke/src/lib.rs`][peekpoke] — the `Poke`/`Peek` max-size contract.
- [`webrender/doc/blob.md`][blob] — the fallback mechanism, stated;
  [`doc/CLIPPING_AND_POSITIONING.md`][clipdoc] — why hierarchical clipping was
  abandoned; [`README.md`][readme] — canonical-tree provenance.

Revision pinned by resolving the `mozilla-firefox/firefox` mirror's default
branch to `44e151427db27db6b789e3be5439f0edbcf446de`; every path above was
fetched at that SHA.

<!-- References -->

[rev]: https://github.com/mozilla-firefox/firefox/tree/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr
[readme]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/README.md
[license]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/LICENSE
[ditem]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender_api/src/display_item.rs
[dlist]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender_api/src/display_list.rs
[image]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender_api/src/image.rs
[font]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender_api/src/font.rs
[units]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender_api/src/units.rs
[apilib]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender_api/src/lib.rs
[wrlib]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender/src/lib.rs
[rapi]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender/src/render_api.rs
[composite]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender/src/composite.rs
[scene]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender/src/scene_building.rs
[peekpoke]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/peek-poke/src/lib.rs
[blob]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender/doc/blob.md
[clipdoc]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender/doc/CLIPPING_AND_POSITIONING.md
