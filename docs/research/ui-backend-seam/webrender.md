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
[F4](./comparison.md)
asked for a stated floor; this is the cheapest known encoding of one, and it is
cheaper than both `PaintEngineFeature`'s bitfield and our
`__traits(compiles)` probing.

## Q3 — semantic widgets, or primitives?

**Both, on different channels — and this is the finding that most complicates
[F3](./comparison.md).**

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
the scrollbar's _appearance_ arrives as ordinary rects. Our friction §3 assumes
a binary: either `scrollbar` is an op kind carrying eight fields, or the
semantics are lost. WebRender demonstrates a third position: **semantics as a
flag on a primitive, worth one bit, consumed by the backend for its own
purposes and ignorable by any backend that has no use for it.**

`HitTest` is the same idea taken further — a display item with no appearance at
all, carrying only a rect and an `ItemTag`, described as "A minimal
hit-testable item for the parent browser's convenience, and is slimmer than a
RectangleDisplayItem (no color)".

## Q4, Q7 — command shape and payload ownership

The same mechanism answers both, so they are treated together.

**Q4 (shape).** `DisplayItem` is a sum type at the type level and a
variable-width tagged encoding on the wire. The `#[repr(u8)]` enum with a
per-variant struct is exactly the shape
[F2](./comparison.md)
recommends and exactly what our `DrawOp` is not; WebRender additionally proves
the encoding is not a cost, because `poke_into_vec` writes the discriminant plus
_that variant's_ payload. The eighteen-field-record encoding would have made
every display list pay its widest item. `MAX_TEXT_RUN_LENGTH = 2040` — a text
run is split rather than allowed to grow unbounded — is the only length cap in
the format, and it exists for a GPU texture-width reason, not a format one.

WebRender also documents the residual dead field, and it is friction §4 in
miniature. `LineDisplayItem` carries a `wavy_line_thickness: f32` whose doc says
"Value irrelevant for non-wavy lines", followed by:

```rust
    // FIXME: this was done before we could use tagged unions in enums, but now
    // it should just be part of LineStyle::Wavy.
    pub wavy_line_thickness: f32,
```

A field dead for three of four `LineStyle` values, with an in-tree note that it
should be a variant payload. `DrawOp` has eighteen such fields and no such note.

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

This is a fourth answer to friction §7, distinct from the three
[F6](./comparison.md) found:
not borrowing, not reference counting, not a backend-owned cache, but
**copy-inline for small payloads and an out-of-band keyed store for large
ones**. It is the only one of the four that survives a thread hop and an IPC
boundary, which is precisely the case `M7/T5` walks into.

## Q5 — sub-unit placement

Not a problem WebRender has, for the same reason it is not one for Slint, Qt or
egui: `LayoutRect` is `Box2D<f32, LayoutPixel>` and hairlines are just thin
rects. `LineDisplayItem` carries a `wavy_line_thickness: f32` and a
`LineStyle` (`Solid`, `Dotted`, `Dashed`, `Wavy`) — a fidelity vocabulary, not
a position vocabulary, which is the shape
[F5](./comparison.md)
recommends.

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
arrive as computed stop arrays. WebRender has no equivalent of our `slot`
because it has no re-resolving consumer — there is exactly one backend.

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
sharper version of the choice friction §6 describes as hedging: not "carry both
the resolved and the semantic value on every op", but "carry a two-variant
value where the second variant names a table the consumer already has".

The other half of Q6 is where high-level constructs get lowered.
`DisplayListBuilder::push_shadow`/`pop_all_shadows` accept a semantic `Shadow`
and then **desugar it inside the builder** into blur stacking contexts holding
offset, recolored copies of the shadowed content, so the consumer never sees a
`Shadow` at all. The comment records that this placement was _moved_:

> Desugar the captured shadow scope into standard display items … **This
> replaces the scene builder's shadow expansion.**
>
> — [`display_list.rs`][dlist]

F3's axis is "who degrades: the backend or the framework". WebRender adds a
third site and, over time, migrated toward it: **the producer's own builder,
before the value is serialized.** The construct is semantic at the call site
and primitive on the wire.

## Q8 — extent query

**The display list carries no extent, and this is deliberate.**
`Transaction::set_display_list(epoch, namespace, (pipeline_id, display_list))`
takes no size at all; the viewport is set independently by
`Transaction::set_document_view(device_rect: DeviceIntRect)` ([`render_api.rs`][rapi]).
`BuiltDisplayListDescriptor` holds IPC timestamps and node counts, not bounds.

This is [F7](./comparison.md)
exactly: extent belongs to the surface, and the surface is configured by the
party that owns the window. Notably, items are also _not_ required to be within
any bound — `clip_rect` exists because "Many items are logically infinite".
A scene whose primitives are individually unbounded cannot have its extent
derived by scanning them, which is what `skia-canvas-render.d` does today.

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
   answer to friction §2 and F4 than either a Qt bitfield or our
   `__traits(compiles)` probes: a `CanvasCaps` struct with a documented
   default means adding a capability does not break `GridCanvas`, and a golden
   test can read the struct instead of guessing.
2. **Encode `DrawOp` as a sum type — and note that the wire cost objection is
   answered.** WebRender shows a tagged union that is _cheaper_ than a flat
   record precisely because it is variable-width. This strengthens F2 and
   removes the last argument for the eighteen-field encoding of friction §4.
3. **Carry semantics as flags on a primitive where a boolean suffices.**
   `IS_SCROLLBAR_CONTAINER` is the cheapest thing in this survey. Our
   `scrollbar` op needs _geometry_, so it cannot collapse to a flag entirely —
   but the eight scrollbar fields on every `DrawOp` could become one
   `ScrollbarOp` variant plus a role flag, and the flag is what a backend with
   no scrollbar opinion actually reads. This complicates F3's binary framing.
4. **Solve friction §7 by copying inline, not by borrowing or interning.**
   A `DrawOp` stream that owns its own bytes and hands out `ItemRange`-style
   borrows _into the stream_ is `@safe` under `dip1000`, crosses a thread, and
   costs one copy of the text — which we already pay when a cell backend
   rasterizes it. This is a fourth option F6 does not list, and the only one
   that satisfies `M7/T5`.
5. **Consider a `PropertyBinding`-shaped answer to friction §6** instead of
   carrying `visual` _and_ `slot` on every op: one two-variant value, resolved
   or late-bound to a table the consumer already holds. The HTML interpreter is
   exactly a consumer that holds such a table.
6. **Do not add extent to the display list.** WebRender confirms F7 and adds a
   reason we had not stated: items may be _logically infinite_ and bounded only
   by their clip, so scanning primitives for an extent is unsound in general,
   not merely inconvenient. The offscreen case wants a layout query.
7. **Reconsider `pushClip`/`popClip` as the clip model, not just as an optional
   primitive.** [`CLIPPING_AND_POSITIONING.md`][clipdoc] is a written record of
   a hierarchical clip stack failing against real content. `sparkles:ui` may
   never need non-hierarchical clipping — but the friction log treats the pair
   as settled, and this is evidence that it is a model choice with a known
   failure mode.
8. **Decide, explicitly, what the seam refuses to carry — and name the escape.**
   This is WebRender's largest transferable idea and the one no other surveyed
   subject states. A closed vocabulary is only affordable because `blob.md`
   names the fallback in one sentence. `sparkles:ui` has an unstated version of
   the same thing (`RuleEdge` degradation, glyph fallback, unclipped painting)
   scattered across call sites. Whatever shape the new seam takes, it should
   have a paragraph like `blob.md`'s.

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
