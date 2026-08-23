# Chromium `cc::PaintOpBuffer` — a reified command stream that survives a process boundary

**Category:** reified command stream. **Last reviewed:** August 23, 2026.
Pinned at [`b0e30a99`][rev].

The industrial-scale answer to [Q4](./index.md#what-each-subject-must-answer):
36 op types, one C++ struct per op, packed nose-to-tail in a byte arena, replayed
into an `SkCanvas` — and, for out-of-process raster, serialised by hand and
replayed in the GPU process. If `sparkles:ui`'s `DrawOp` encoding is defensible,
this is where the defence lives; where Chromium diverges from it, the divergence
is deliberate and paid for.

| Field               | Value                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------- |
| **Language**        | C++20                                                                                       |
| **License**         | BSD-3-Clause ([`LICENSE`][license])                                                         |
| **Repository**      | [`chromium/chromium`][repo] (GitHub mirror of the canonical Gerrit tree)                    |
| **Documentation**   | [`cc/paint/README.md`][readme] — the component's only prose doc; the headers carry the rest |
| **Category**        | reified command stream                                                                      |
| **Pinned revision** | `b0e30a9973232cee28901ea5d6cd4de6ea9428aa`                                                  |
| **Op types**        | 36 (`PaintOpType`), of which 19 are draw ops (`kIsDrawOp`)                                  |
| **Seam surface**    | `PaintCanvas`: 45 pure-virtual methods, two production implementations                      |
| **Backends**        | `SkiaPaintCanvas` (raster), `RecordPaintCanvas` (record into a `PaintOpBuffer`)             |

## Overview

### What it solves

Blink paints; cc composites; the GPU process rasters. Those are three different
places, two of them different processes, and the paint result has to travel.
[`cc/paint/README.md`][readme] states the motive without hedging:

> cc/paint is a replacement for SkPicture/SkCanvas/SkPaint recording data
> structures throughout the Chrome codebase, primarily meaning Blink and ui. The
> reason for a separate data structure is to change the way that recordings are
> stored to improve transport and recording performance.

`SkPicture` was rejected as the transport, and [`paint_canvas.h`][paint_canvas]
says exactly why:

> Its reason for existence is so that it can do custom serialization logic into a
> PaintOpBuffer which (unlike SkPicture) is mutable, handles image replacement,
> and can be serialized in custom ways (such as using the transfer cache).

Mutability, payload substitution and a bespoke wire format — those three
requirements are what force reification. A virtual-dispatch painter cannot be
paused, inspected, culled by rect, re-serialised with different images and shipped
to another process.

### Design philosophy

Two seams, stacked, with different jobs:

1. **`PaintCanvas`** — an ordinary abstract painter, `SkCanvas` trimmed "back to
   only what Chrome uses" ([`paint_canvas.h`][paint_canvas]). This is the API
   _callers_ see. It has no notion of ops.
2. **`PaintOpBuffer`** — the reified stream, "a reimplementation of SkLiteDL"
   ([`paint_op_buffer.h`][pob]). This is what _travels_.

`RecordPaintCanvas` is the adapter between them: a `PaintCanvas` whose
implementation of every method is `buffer_.push<SomeOp>(…)`. `SkiaPaintCanvas`
is the other one and forwards straight to Skia. So a caller never chooses
between "drawing" and "recording" — that choice is a subclass — while the
op stream exists as data whenever anyone needs it to.

## How it works

### The op vocabulary

`PaintOpType` is a `uint8_t` enum with 36 members, and the base class carries
that tag and nothing else that varies:

```cpp
enum class PaintOpType : uint8_t {
  kAnnotate, kClipPath, kClipRect, kClipRRect, kConcat, kCustomData,
  kDrawArc, kDrawArcLite, kDrawColor, kDrawDRRect, kDrawImage, kDrawImageRect,
  kDrawIRect, kDrawLine, kDrawLineLite, kDrawOval, kDrawPath, kDrawRecord,
  kDrawRect, kDrawRRect, kDrawScrollingContents, kDrawSkottie, kDrawSlug,
  kDrawTextBlob, kDrawVertices, kNoop, kRestore, kRotate, kSave, kSaveLayer,
  kSaveLayerAlpha, kSaveLayerFilters, kScale, kSetMatrix, kSetNodeId,
  kTranslate,
  kLastPaintOpType = kTranslate,
};

class CC_PAINT_EXPORT PaintOp {
 public:
  void DestroyThis();
  uint8_t type;
  PaintOpType GetType() const { return static_cast<PaintOpType>(type); }
  void Raster(SkCanvas* canvas, const PlaybackParams& params) const;
  bool IsDrawOp() const { return g_is_draw_op[type]; }
  uint16_t AlignedSize() const { return g_type_to_aligned_size[type]; }
  // …
};
```

Every op is a separate `final` subclass carrying **only its own fields**
([`paint_op.h`][paint_op]) — `ClipRectOp` is `{SkRect rect; SkClipOp op; bool
antialias;}`, `DrawRectOp` is `{PaintFlags flags; SkRect rect;}`. There is no
union, and no field that is dead for the op that holds it.

### Storage: a variable-stride byte arena

`PaintOpBuffer` is a single `uint8_t` heap array. Ops are placement-newed into
it at their own size, aligned to 8:

```cpp
template <typename T, typename... Args>
const T& push(Args&&... args) {
  static_assert(std::is_base_of<PaintOp, T>::value, "T not a PaintOp.");
  static_assert(alignof(T) <= kPaintOpAlign, "");
  uint16_t aligned_size = ComputeOpAlignedSize<T>();
  base::span<uint8_t> storage = AllocatePaintOp(aligned_size);
  T* op = new (storage.data()) T{std::forward<Args>(args)...};
  DCHECK_EQ(op->type, static_cast<uint8_t>(T::kType));
  AnalyzeAddedOp(op);
  return *op;
}
```

Iteration reads the leading tag byte, looks the stride up in
`g_type_to_aligned_size[type]`, and advances. Destruction is manual —
`PaintOpBuffer::DestroyOps()` walks the same way calling `op->DestroyThis()`,
because "ops are usually contained in memory buffers and so don't have their
destructors run automatically" ([`paint_op.h`][paint_op]).

### Dispatch: a hand-rolled vtable, checked for exhaustiveness

There are no virtual methods on `PaintOp`. [`paint_op.cc`][paint_op_cc] builds
parallel function-pointer tables from one X-macro list, and asserts the list is
complete:

```cpp
#define TYPES(M)             \
  M(AnnotateOp)              \
  M(ClipPathOp)              \
  /* … 34 more … */          \
  M(TranslateOp)

// Verify that every op is in the TYPES macro.
#define M(T) +1
static_assert(kNumOpTypes == TYPES(M), "Missing op in list");
#undef M

constexpr std::array<RasterFunction, kNumOpTypes> g_raster_functions = {TYPES(M)};
```

The same list generates `g_serialize_functions`, `g_deserialize_functions`,
`g_destructor_functions`, `g_equal_for_testing_functions`, `g_is_draw_op`,
`g_has_paint_flags` and `g_type_to_aligned_size`. Exhaustiveness is a
`static_assert` over a macro, not a language guarantee — the C++ cost of a sum
type the language does not provide.

### Playback

`PaintOpBuffer::Playback(SkCanvas*, const PlaybackParams&, bool local_ctm)`
walks the arena through `PlaybackFoldingIterator`, which peeks ahead and folds
`saveLayerAlphaf` / draw / `restore` triples into a single draw with baked alpha
(`PaintFlags::SupportsFoldingAlpha`, [`paint_op_buffer_iterator.h`][iter] /
[`.cc`][iter_cc]). It
also quick-rejects draws outside the clip when an `ImageProvider` is installed,
"to save performing an expensive decode that will never be rasterized"
([`paint_op_buffer.cc`][pob_cc]). Both are peephole optimisations that only
exist because the stream is data.

### Serialisation: per-op, stateful, and not type-stable

Each op declares a serialisation pair through a macro:

```cpp
#define HAS_SERIALIZATION_FUNCTIONS()                                         \
  void Serialize(PaintOpWriter& writer, const PaintFlags* flags_to_serialize, \
                 const SkM44& current_ctm, const SkM44& original_ctm) const;  \
  static PaintOp* Deserialize(PaintOpReader& reader, void* output)
```

Bodies are hand-written and trivially field-by-field
(`ClipRectOp::Serialize` is three `writer.Write(…)` calls). Three properties of
this boundary matter more than the mechanics:

- **Serialisation needs replay state.** `PaintOpBufferSerializer` plays every
  transform and clip op onto an analysis `SkCanvas` as it goes, because it needs
  "the correct ctm at which text and images will be rasterized, and the clip
  rect so we can skip sending data for ops which will not be rasterized"
  ([`paint_op_buffer_serializer.cc`][serializer_cc]). A `PaintOp` cannot be
  encoded in isolation.
- **Two ops refuse to serialise at all.** `DrawRecordOp::Serialize` and
  `DrawScrollingContentsOp::Serialize` are both `NOTREACHED()` with the comment
  `// These are flattened in PaintOpBufferSerializer.` Nesting exists in memory
  and is inlined away on the wire.
- **The op type changes across the boundary.** `PaintOp::Serialize` ends with

  ```cpp
  // Convert DrawTextBlobOp to DrawSlugOp.
  if (GetType() == PaintOpType::kDrawTextBlob) {
    return writer.FinishOp(static_cast<uint8_t>(PaintOpType::kDrawSlug));
  }
  ```

  A recorded text blob arrives at the raster process as a Skia _slug_ —
  position-baked glyphs against a strike the `SkStrikeServer` has locked. The
  received stream is not the sent stream.

### The layer above: `DisplayItemList`

`PaintOpBuffer` has no spatial index. [`display_item_list.h`][dil] adds one:
ops are pushed between `StartPaint()` and `EndPaintOfUnpaired(visual_rect)`, the
caller-supplied rect is stored in a parallel `visual_rects_` vector, and
`Finalize()` builds an `RTree<size_t>` of byte offsets so that "when rasterizing
a rect, it queries the rtree to extract only the byte offsets of the ops
required and replays those into a canvas."

## Q1 — measurement units, and who answers

**The seam contains no measurement of any kind.** `measure`, `advance` and
their synonyms do not appear in `paint_canvas.h` or `paint_op.h` at this
revision. Text reaches the seam already shaped, as `sk_sp<SkTextBlob>` on
`DrawTextBlobOp` with an `(x, y)` origin; shaping happened in Blink, far above.

Where cc needs a text extent it asks the payload, not a canvas:
`PaintOp::GetBounds` for `kDrawTextBlob` evaluates
`text_op.blob->bounds().makeOffset(text_op.x, text_op.y)`
([`paint_op.cc`][paint_op_cc]).

This is [F1](./comparison.md)
at maximum scale and by the most extreme route in the survey: not "measurement
lives in a sibling abstraction" but "measurement has already happened by the
time the seam exists". The subject with a real process boundary agrees hardest:
a measurement answerable only by the far side of an IPC would be unaffordable,
so the question is settled before the boundary exists. `isCanvas`'s fifth
method, `Size measure(const(char)[])`, is the one obligation on this list that
Chromium's seam does not carry at all (friction §1, `measure` is denominated in
cells).

## Q2 — is the contract stated in one place?

**Yes, and it is total: `PaintCanvas` is 45 pure-virtual methods with no
optional members and no capability query.** Nothing is probed. A new backend
implements all 45 or does not compile. There is no `hasFeature`, no
default-implemented method, no `__traits(compiles)` analogue.

Optionality is expressed three other ways instead, and each is a distinct
technique worth naming:

- **By subclass.** `RecordPaintCanvas`'s doc comment states that "the methods
  that inspect the current clip or CTM are not implemented (DCHECK will fail if
  called). Use `InspectableRecordPaintCanvas` instead if the client needs to
  call those methods" ([`record_paint_canvas.h`][rpc]). The optional capability
  is a _type_, chosen at construction, not a runtime probe.
- **By options flowing inward.** The sink's abilities arrive as plain fields on
  `PaintOpBuffer::SerializeOptions`: `can_use_lcd_text`,
  `context_supports_distance_field_text`, `max_texture_size`
  ([`paint_op_buffer.h`][pob]). The producer is told what the consumer can do;
  it does not ask.
- **By content predicates flowing outward.** `AnalyzeAddedOp` maintains
  `has_draw_text_ops_`, `has_non_aa_paint_`, `has_discardable_images_`,
  `has_save_layer_alpha_ops_` and `num_slow_paths_up_to_min_for_MSAA_` as ops
  are pushed. The _stream_ declares its own requirements — the MSAA decision
  reads `num_slow_paths_up_to_min_for_MSAA()`, capped at
  `kMinNumberOfSlowPathsForMSAA = 6` so counting stops once the answer is known.

That inversion is the finding.
[F5](./comparison.md)
asks for a stated floor and a refusable degrade; Chromium's floor is
"everything", and negotiation happens over _content properties_ rather than over
_primitives_. Nobody asks "can you draw a hairline"; the recording says "I
contain non-AA paint" and the scheduler picks a target accordingly.

## Q3 — semantic operations, and the escape hatch

The 19 draw ops are almost entirely Skia primitives — rects, rrects, ovals,
arcs, paths, images, vertices. There is no `scrollbar`, no `focus ring`, no
`text input`. So on the naive axis Chromium is at the opposite pole from
[Slint](./slint.md#q3--semantic-operations-deliberately).

But three semantic escapes survive, and they do not widen the drawing
vocabulary:

- **`DrawScrollingContentsOp`** carries an `ElementId scroll_element_id` and a
  `scoped_refptr<DisplayItemList>` — no geometry at all. The
  scroll offset is _not_ in the op; it is looked up at playback time from
  `PlaybackParams::raster_inducing_scroll_offsets`, and the serializer emits a
  `TranslateOp` for it ([`paint_op_buffer_serializer.cc`][serializer_cc]). One
  scroller is one identity plus one nested list.
- **`CustomDataOp`** is a bare `uint32_t id`, documented as "user defined id as
  a placeholder op", resolved at playback by a caller-supplied
  `PlaybackCallbacks::CustomDataRasterCallback`. It is a hole in the stream that
  the embedder fills.
- **`AnnotateOp`** (`kUrl`, `kNameDestination`, `kLinkToDestination`) and
  **`SetNodeIdOp`** carry PDF/accessibility identity that has no pixels.

This complicates
[F4](./comparison.md)
usefully. F4's axis is where the lowering lives, and Chromium adds a place the
list does not name: **carry an identity and a nested stream, and let the
consumer supply the state at playback**. Applied to friction §3 (`scrollbar` is
a widget concept in the drawing seam), a scrollbar operation would be an id plus
the rail rect, with the state the `Scrollbar` payload spells out —
`content`, `viewport`, `offset`, `expandPercent`, the two track colours, the
lit-track flag and the `trackGlyph`/`thumbGlyph` fallbacks — looked up from a
paint-params struct, exactly as Chromium looks up scroll offsets.

The price is specific. Twelve of the `Scrollbar` payload's fourteen fields
leave the arm, and with them the eight accessors that read them — `barContent`,
`barViewport`, `barOffset`, `expandPercent`, `barTrackLit`, `barTrackColor`,
`barTrackGlyph`, `barThumbGlyph` — become lookups against a struct the caller
must now thread through `interp/immediate.d` alongside the operation. It buys no
bytes: `TextRun`, not `Scrollbar`, is the widest payload, so the 64-byte budget
does not move. What it buys is that the drawing vocabulary stops knowing what a
scrollbar is, while `scrollbarThumb` stays the one `STM2` formula every backend
renders.

## Q4 — the command's shape

**Tag plus per-op struct, in variable-stride heterogeneous storage.** This is
the survey's most direct evidence on friction §4, and it says three things.

**First, the dead-field cost is real and Chromium pays engineering to avoid it.**
`CorePaintFlags` exists solely to be smaller than `PaintFlags`, documented as:

> Minimal set of commonly used paint state. Using a minimal set means PaintOps
> takes up less space in memory as well as less data to read/write.
> — [`paint_flags.h`][paint_flags]

And `DrawLineLiteOp` / `DrawArcLiteOp` are duplicate op types that differ from
`DrawLineOp` / `DrawArcOp` _only_ by carrying `CorePaintFlags` instead of
`PaintFlags`, each prefaced with
`// TODO(crbug.com/340122178): figure out a better way to unify types.`
([`paint_op.h`][paint_op]). Chromium duplicated two ops and left a bug open
rather than let every line carry unused paint state. `DrawOp` answers the same
pressure by a different route: each kind gets its own payload, so `Scrollbar`'s
fourteen fields ride on the `Scrollbar` arm alone and `PopClip` declares no
fields at all. What the two encodings disagree about is not dead fields but
stride.

**Second, exhaustiveness is not free.** `TYPES(M)` plus
`static_assert(kNumOpTypes == TYPES(M))` is a manual reconstruction of what D's
`SumType` + `final switch` gives by construction. `PaintOp::GetBounds` is a
36-arm `switch` written out by hand, precisely so a new op type breaks the
build.

**Third — and this is the sharpest evidence in the survey for the second half of
[F3](./comparison.md)
— a closed sum type is a fixed-size cell, and that is exactly the cost Chromium
routes around.** The union appears in the tree only once, at the deserialisation
scratch buffer:

```cpp
using LargestPaintOp =
    typename std::conditional<(sizeof(DrawImageRectOp) > sizeof(DrawDRRectOp)),
                              DrawImageRectOp, DrawDRRectOp>::type;
inline constexpr size_t kLargestPaintOpAlignedSize =
    PaintOpBuffer::ComputeOpAlignedSize<LargestPaintOp>();
```

Everywhere else — recording, playback, serialisation — an op occupies
`ComputeOpAlignedSize<T>()` bytes and no more. Chromium's standing argument
against `sparkles:ui`'s encoding is exactly this: `DrawOp` is
`SumType!(FillRect, TextRun, Glyph, Line, Rule, Scrollbar, PushClip, PopClip)`,
every element of a `DrawOp[]` is as wide as `TextRun` — the widest payload,
which is what the `static assert(DrawOp.sizeof <= 64)` budget guards — and a
`PopClip`, which carries no fields, costs what a text run costs. Chromium's
position is that reification wants **two** things: a closed tag for exhaustive
dispatch, and per-op-sized storage. It buys the second with an arena and pays
for the first with macros.

The price of taking that trade here is concrete. Per-op-sized storage means a
`DrawOp` stops being a value: the display-list walk becomes an offset-and-tag
cursor over `sparkles.ui.arena` bytes rather than a `foreach` over a slice, and
`op.match!(…)` — with `final switch` exhaustiveness supplied by the compiler
rather than by a `TYPES(M)` macro and a hand-written 36-arm switch — is replaced
by a cast per arm. `visualOf` and the seventeen accessors on `DrawOp` all take
a pointer of unknown arm instead of a sum, so each of them regains the
"which arm is it" question that `DrawOp.kind` derives once. Most expensive of
all, `RecordingCanvas`'s operations stop being pairwise comparable:
the op-stream parity harness compares two collected `DrawOp[]`s element by
element, which is a `==` on a sum type and nothing more.

And the win is denominated in a browser's units, not the toolkit's. Chromium
records a whole page's display list, rect-culls it through an rtree and ships it
across a process boundary where every byte is written by hand and read back; a
`sparkles:ui` frame is thousands of operations, and 4096 of them at the 64-byte
budget is 256 KiB, bump-allocated once and reset. Variable stride
buys nothing once the widest payload fits the budget, and it costs
`RecordingCanvas` its pairwise-comparable value semantics — which the friction
log lists under what did _not_ cause friction. The fixed cell stays.

## Q5 — sub-unit placement

Not a problem Chromium has: coordinates are `SkScalar` floats throughout, and
the display list is in layer space with the device scale applied by the CTM.

There is, however, a precedent worth transplanting for friction §5.
`DrawLineOp` carries a `bool draw_as_path`, documented as "used to indicate if
rasterization should treat the line as a path […] in some situations it can be
quicker to raster lines as paths". `RecordPaintCanvas` decides it with a
heuristic over `draw_path_count_` / `draw_line_count_`, and exposes
`DisableLineDrawingAsPaths()` to override ([`record_paint_canvas.h`][rpc]).

So the op carries **the same geometry plus a realisation strategy**, chosen by
the recorder. That is
[F6](./comparison.md)'s
"name a fidelity, not a position" in a shipping codebase — and it lands on the
side F6 argues for, since float coordinates did not spare Chromium the choice,
they only moved it onto the op. The twist is that the strategy is a _hint on the
op_, not a separate primitive, and that the producer can force it off.

## Q6 — resolved appearance or semantic role

**Resolved, exclusively.** `PaintFlags` is a fully computed `SkPaint` analogue —
colour, blend mode, stroke width, shader, filters, looper. No op carries a
semantic style role, and there is no theme layer below the seam to re-resolve
one.

Where identity must survive to the far end it gets **its own op**, not a field
on every op: `SetNodeIdOp` for PDF marked content, `AnnotateOp` for links,
`ElementId` on `DrawScrollingContentsOp`. And `DrawTextBlobOp::node_id` is
explicitly excluded from the wire — `// This field isn't serialized.` — because
the consumer that needs it (`DisplayItemList::CaptureContent`) is in the same
process as the producer.

This is a clean answer to friction §6 (a resolved appearance and a semantic role
on every drawing op), and it is [F9](./comparison.md) argued from the largest
codebase in the survey: pay for one representation, and when a second consumer
needs the semantic role, give that role a dedicated op or a side channel rather
than a field on the hot path. `sparkles:ui` stores `Slot` on six of the eight
payloads — `PushClip` and `PopClip` carry none, and `DrawOp.slot` answers
`Slot.inherit` for them — so that one interpreter, HTML, can re-derive class
names from the role while the pixel backends read the resolved `Ink` beside it.
Deriving `Visual` on demand through `visualOf` rather than storing one keeps
that hedge cheap; it does not make it a decision. Chromium's equivalent would be
a `SetSlotOp` bracketing a run in the stream, costing nothing when the HTML
interpreter is not the consumer.

## Q7 — payload ownership across a process boundary

**Nothing is borrowed. Ever.** Every payload-bearing field is an owning smart
pointer: `sk_sp<SkData>` (`AnnotateOp`), `sk_sp<SkTextBlob>`
(`DrawTextBlobOp`), `PaintImage` (`DrawImageOp`), `PaintRecord`
(`DrawRecordOp`), `scoped_refptr<DisplayItemList>`
(`DrawScrollingContentsOp`), `scoped_refptr<RefCountedBuffer<SkPoint>>`
(`DrawVerticesOp`). This is why `DestroyThis()` and the manual destructor table
exist at all — placement-new into an arena means somebody must run those
destructors, and `PaintOpBuffer::DestroyOps()` does.

Consequently an op **always** outlives its frame. `PaintRecord` is a refcounted
immutable snapshot: "Copy/assignment and movement are cheap […] On copy the new
PaintRecord shares the same underlying data with the source"
([`paint_record.h`][paint_record]). A recording is produced on one thread and
rastered on another (or in another process) with no lifetime negotiation at all.

Across the process boundary, ownership is solved four different ways depending
on the payload's cost and lifetime:

| Payload                | Mechanism                                                                | Why                                                          |
| ---------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------ |
| Small immediate fields | inlined into the byte stream by `PaintOpWriter`                          | cheapest; no identity needed                                 |
| Images                 | `SerializedImageType`: `kImageData` / `kTransferCacheEntry` / `kMailbox` | three transports for one field, chosen by size and residency |
| Paths, runtime effects | `ClientPaintCache` ↔ `ServicePaintCache`, keyed by `PaintCacheId`        | small, high-frequency, client-budgeted                       |
| Text                   | transcoded to `sktext::gpu::Slug`; glyphs locked via `SkStrikeServer`    | the far side has no fonts loaded the way the near side does  |

The `ClientPaintCache` docstring is the most useful sentence in the component
for our purposes, because it states the trade-off explicitly:

> using a client controlled PaintCache with a tighter budget is better for these
> data types since it avoids the need for cross-process ref-counting required by
> the TransferCache — [`paint_cache.h`][paint_cache]

That is
[F8](./comparison.md)
confirmed and then sharpened: reference counting and an identity-keyed cache are
not alternatives, they are a _tier list_, and the tiering axis is the cost of
maintaining the reference, not the cost of the payload.

`sparkles:ui` sits inside F8's family rather than outside it. `TextRun.text` is
a `const(char)[]` borrowed from a frame arena, and `CmdBuffer.textRun`
**copies** into that arena, which is what makes a `scope` source safe.
`FrameArena` bump-allocates over never-moving chunks, and `RecordingCanvas`
interns on the collected heap so its operations outlive the call that drew them.
What Chromium's tier list bears on is friction §7 (`DrawOp.text` is borrowed,
and the borrow is not expressible): the arena copy answers _where the bytes
live_, and leaves open the question `UI-O4` tracks — how long an operation may
be retained, and by whom.
The lifetime rule is stated on the type (_an operation is valid while the buffer
that built it is alive and unreset_) and the buffer is move-only, so the rule is
enforceable rather than advisory. But nothing in `cc/paint` asks a caller to
observe a rule of that shape at all: the system that most needs cheap recording
chose owning payloads and paid for a manual destructor table to get them, which
is what lets a `PaintRecord` cross a thread with no negotiation.

## Q8 — can a backend ask the scene its extent?

**The ops do not carry bounds; the container does, and the producer supplied
them.**

`PaintOp` has no bounds field. `PaintOp::GetBounds(op, rect)` derives a
conservative rect for 16 of the 36 types by `switch` and returns `false` for the
other 20. Three of those are draw ops: `kDrawColor` (unbounded by definition),
`kDrawRecord` and `kDrawScrollingContents` (unknown without descending into the
nested list). `ComputePaintRect` handles that failure by
assuming the op "covers the complete current clip", with a
`// TODO(khushalsagar): See if we can do something better for non-draw ops.`

One layer up, the answer is exact and cheap:
`DisplayItemList::bounds()` returns `std::optional<gfx::Rect>` from
`rtree_.bounds()` — and the rtree is built from `visual_rects_`, which the
_painter_ declared at `EndPaintOfUnpaired(visual_rect)` time. Blink knows each
display item's visual rect because it computed the layout; it hands that rect
over rather than making anyone re-derive it.

This is
[F7](./comparison.md)
at its most emphatic, and on the pole F7 argues for. F7 separates surface,
layout and ink extent and puts the real axis at maintained-at-construction
versus derived-by-scan; Chromium maintains, and it maintains at the container
rather than at the op. The offscreen case is not marginal here — it is tiled
raster, the main path. Note what Chromium does _not_ do: the ops stay silent
about their bounds, and per-op derivation is the lossy fallback.

`sparkles:ui` is at the other pole on both counts. It has no `visual_rects_`
equivalent anywhere in the stack: `buildDisplayList` emits operations with no
rect declared alongside them, and none of the three containers that hold them —
`CmdBuffer`, the display list, the arena the text is interned in — accumulates a
bound as they are pushed, so none of the three can be asked what a finished
stream covers. `CmdBuffer` answers `length` and a run's cell `measure`; painted
bounds are whatever a consumer derives for itself by folding `op.rect`
(friction §8, no extent query). `skia-canvas-render.d` scanning
every operation's rect is precisely `PaintOp::GetBounds`, and Chromium's verdict
on that technique is that it is conservative, incomplete, and worth having only
as a backstop.

## Strengths

- **One tag, one struct, no dead fields.** Per-op types with variable-stride
  storage mean the encoding cost of a rich vocabulary is paid only by the ops
  that use it.
- **Reification pays compounding dividends.** Rect culling via an rtree, alpha
  folding in `PlaybackFoldingIterator`, solid-colour analysis
  (`GetColorIfSolidInRect`), `EqualsForTesting`, tracing snapshots, fuzzers, and
  IPC transport all fall out of the stream being data. None is available to a
  virtual-dispatch painter.
- **Ownership is unambiguous.** Every payload is owned or shared; recordings
  cross threads and processes without lifetime rules for callers to remember.
- **Optionality by type, not by probe.** `RecordPaintCanvas` vs
  `InspectableRecordPaintCanvas` makes "can this canvas answer clip queries" a
  compile-time fact.
- **The stream declares its own needs.** Content predicates computed at push
  time let schedulers decide MSAA, LCD text and invalidation without re-walking.

## Weaknesses

- **Exhaustiveness is macro-enforced.** Adding an op means touching a `TYPES`
  list, seven tables and a 36-arm `GetBounds` switch. The `static_assert` catches
  the list, not the switch.
- **Serialisation is hand-written per op and stateful.** 36 `Serialize` /
  `Deserialize` pairs, plus an analysis canvas replay to recover CTM and clip.
  Two ops cannot serialise at all and are flattened by a separate class.
- **The wire format is not the memory format.** `DrawTextBlobOp` arrives as
  `DrawSlugOp`; nesting disappears; `node_id` is dropped. Round-tripping is not
  an identity, which makes "compare the op stream" a weaker test than it looks.
- **Bounds are second-class.** 20 of 36 op types cannot state their extent, and
  the fallback is "the whole clip".
- **Two seams to learn.** `PaintCanvas` and `PaintOpBuffer` overlap heavily;
  `paint_canvas.h` itself carries `// TODO(enne): this only appears to mostly be
used to determine if this is recording or not, so could be simplified or
removed` about `imageInfo()`.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                          | Trade-off                                                                            |
| ------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| One C++ struct per op, not a tag with a field union     | No dead fields; op size tracks op content                          | 36 subclasses, seven parallel dispatch tables, macro-enforced exhaustiveness         |
| Variable-stride byte arena with placement-new           | Recording is a bump allocation; no per-op heap node                | Manual destructor walk (`DestroyThis`); `LargestPaintOp` scratch on deserialise      |
| `PaintCanvas` above `PaintOpBuffer`                     | Callers write drawing code once; recording is a subclass choice    | Two overlapping abstractions; recording-only methods DCHECK on the raster canvas     |
| Owning/refcounted payloads everywhere                   | Recordings cross threads and processes freely                      | Destructors in an arena; refcount traffic on the paint hot path                      |
| Hand-written per-op serialisation                       | Full control of the wire format (transfer cache, mailboxes, slugs) | 36 pairs to maintain; a fuzzer per entry point; not type-stable                      |
| Text shaped before the seam, transcoded at the boundary | The raster process never needs shaping context                     | The op type changes on the wire; `node_id` cannot travel                             |
| Extent from producer-declared visual rects, in an rtree | Blink already knows the rects; culling is exact and cheap          | Ops themselves cannot answer; `GetBounds` is a lossy backstop                        |
| Semantics as identity + nested stream, not as widgets   | The vocabulary stays primitive while scrollers stay meaningful     | Playback needs a params struct carrying the state (`raster_inducing_scroll_offsets`) |

## Bearing on the proposal

1. **`DrawOp`'s closed sum is a fixed-size cell, and Chromium's position is that
   per-op structs in variable-stride storage are the encoding that earns its
   keep.** The mechanism is `ComputeOpAlignedSize<T>()`: an op occupies its own
   size everywhere except the deserialisation scratch buffer, where
   `LargestPaintOp` appears exactly once and is treated as a cost to be
   contained. Aimed at `sparkles:ui`, the argument is that every element of a
   `DrawOp[]` should cost the width of what it holds rather than the width of
   `TextRun`. The price is
   the whole value semantics: the display-list walk becomes a tag-and-offset
   cursor, `op.match!` and its `final switch` exhaustiveness become a cast per
   arm, `visualOf` and the seventeen accessors take a pointer of unknown arm,
   and `RecordingCanvas`'s collected operations stop comparing pairwise — which
   is how the op-stream parity harness works. **Answered: variable stride buys
   nothing once the widest payload fits the 64-byte budget, and it costs
   `RecordingCanvas` its pairwise-comparable value semantics, which the friction
   log lists among the things that are working.** The trade reads differently at
   4096 operations bump-allocated and reset than at a browser's millions copied
   across a process boundary. This is the strongest statement of the
   variable-stride side of F3; the toolkit takes the other side knowingly.
   (friction §4, the encoding is neither `@safe` nor variable-width)
2. **Answer friction §3 with `DrawScrollingContentsOp`'s shape, not Slint's.**
   Emit `scrollbar` as an identity plus a rail rect, and look
   `barContent`/`barViewport`/`barOffset`/`expandPercent` up from a
   paint-params struct at interpretation time — exactly as Chromium resolves
   scroll offsets from `PlaybackParams`. Twelve of the `Scrollbar` payload's
   fourteen fields leave the arm along with the eight `bar*` accessors that read
   them, the semantics survive, and `scrollbarThumb` stays the single `STM2`
   formula. It saves no bytes — `TextRun` is the widest payload either way.
   **This complicates F4**, which lists six places a lowering can live; playback
   against a caller-supplied params struct is a seventh.
   (friction §3, `scrollbar` is a widget concept in the drawing seam)
3. **Move `measure` off the canvas — the strongest result in the survey just got
   a fifth unanimous vote, from the subject under the most pressure.** Chromium
   does not merely relocate measurement; it makes text arrive pre-shaped, so the
   seam never asks. (F1, friction §1, `measure` is denominated in cells)
4. **Carry a realisation strategy on the op, and let the recorder choose it.**
   `DrawLineOp::draw_as_path` plus `DisableLineDrawingAsPaths()` is F6's
   "fidelity, not position" already shipping, in the form of a hint field with a
   producer-side override — from a subject whose coordinates are floats, which
   is F6's point. A `Rule` payload carrying a fidelity enum rather than a
   `RuleEdge` compass follows the same pattern.
   (F6, friction §5, sub-cell placement as a compass direction)
5. **Drop `Slot` from the six payloads that store one; give the semantic role
   its own op.** Chromium pays for resolved appearance only, and routes identity
   through `SetNodeIdOp`, `AnnotateOp` and `ElementId`. A `SetSlotOp` (or a
   slot-run bracket) costs nothing when the HTML interpreter is not the
   consumer, and `DrawOp.slot` — which already answers `Slot.inherit` for the
   two clip payloads — would answer it for a stream nobody bracketed.
   (F9, friction §6, a resolved appearance and a semantic role on every drawing
   op)
6. **Price the retain boundary from Chromium's tier list, not from the copy.**
   No op in `cc/paint` borrows anything, in the system whose entire reason for
   existing is cheap recording. `sparkles:ui`'s frame arena is a copy, so it is
   inside F8's family; what it does not answer is how long an operation may be
   retained and by whom, which is the open half of `UI-O4`. Chromium's tiers —
   inline / refcount / identity-keyed client cache / transcode — are the menu,
   and the selection axis is the cost of maintaining the reference, not the size
   of the payload. (F8, friction §7, `DrawOp.text` is borrowed, and the borrow
   is not expressible)
7. **Maintain extent at construction, the way F7 argues.** Chromium's scene
   answers its own extent (`DisplayItemList::bounds()`), and does so because the
   _producer_ declares each item's visual rect while emitting it — which
   `sparkles:ui`'s layout pass already knows. Recording a rect alongside each op
   group during `buildDisplayList` is cheaper and more exact than folding
   `op.rect` on the backend side, and it is what makes rect-culled partial
   replay possible later. **This is F7's strongest confirmation.**
   (F7, friction §8, no extent query)
8. **Declare content predicates on the display list, not capabilities on the
   backend.** `AnalyzeAddedOp`'s `has_draw_text_ops_` / `has_non_aa_paint_` bits
   are computed for free at push time and let a consumer decide policy without
   re-walking. That is a cheaper half of F5's ask than a capability protocol, and
   it composes with the optional-primitive bargain the friction log wants kept —
   the four probed primitives (`rule`, `scrollbar`, `pushClip`, `popClip`) each
   already have a stated degradation; what `isCanvas` does not state is that they
   exist. (F5, friction §2, five methods, eight kinds)

## Sources

- [`cc/paint/README.md`][readme] — the component's stated purpose.
- [`cc/paint/paint_op.h`][paint_op] — `PaintOpType`, `PaintOp`,
  `PaintOpWithFlags`, the 36 op subclasses, `HAS_SERIALIZATION_FUNCTIONS`,
  `LargestPaintOp`.
- [`cc/paint/paint_op.cc`][paint_op_cc] — the `TYPES(M)` dispatch tables,
  `PaintOp::Serialize` (including the `DrawTextBlobOp` → `DrawSlugOp`
  conversion), `PaintOp::GetBounds`, `DrawSlugOp::SerializeSlugs`.
- [`cc/paint/paint_op_buffer.h`][pob] / [`.cc`][pob_cc] — arena storage,
  `push<T>`, `AnalyzeAddedOp`, `Playback`, `DestroyOps`, `SerializeOptions`.
- [`cc/paint/paint_op_buffer_iterator.h`][iter] / [`.cc`][iter_cc] —
  `PlaybackFoldingIterator` and the alpha-folding rule.
- [`cc/paint/paint_op_buffer_serializer.h`][serializer] /
  [`.cc`][serializer_cc] — `Preamble`, record flattening, the analysis canvas.
- [`cc/paint/paint_canvas.h`][paint_canvas] — the 45-method abstract painter.
- [`cc/paint/record_paint_canvas.h`][rpc] — `RecordPaintCanvas`,
  `InspectableRecordPaintCanvas`, `draw_as_path` heuristics.
- [`cc/paint/paint_record.h`][paint_record] — the refcounted immutable snapshot.
- [`cc/paint/paint_flags.h`][paint_flags] — `CorePaintFlags` and its rationale.
- [`cc/paint/paint_cache.h`][paint_cache] — client/service cache tiering.
- [`cc/paint/transfer_cache_entry.h`][transfer_cache] — the large-payload tier.
- [`cc/paint/display_item_list.h`][dil] — visual rects, the rtree, `bounds()`.
- [`cc/paint/paint_op_writer.h`][writer] — the wire encoder and its alignment
  contract.

Revision pinned with `git -C <clone> rev-parse HEAD` against a local Chromium
checkout and confirmed present on the GitHub mirror
(`gh api repos/chromium/chromium/commits/<sha>`); every cited path verified with
`git cat-file -e <sha>:<path>`.

<!-- References -->

[rev]: https://github.com/chromium/chromium/tree/b0e30a9973232cee28901ea5d6cd4de6ea9428aa
[repo]: https://github.com/chromium/chromium
[license]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/LICENSE
[readme]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/README.md
[paint_op]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_op.h
[paint_op_cc]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_op.cc
[pob]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_op_buffer.h
[pob_cc]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_op_buffer.cc
[iter]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_op_buffer_iterator.h
[iter_cc]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_op_buffer_iterator.cc
[serializer]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_op_buffer_serializer.h
[serializer_cc]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_op_buffer_serializer.cc
[paint_canvas]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_canvas.h
[rpc]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/record_paint_canvas.h
[paint_record]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_record.h
[paint_flags]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_flags.h
[paint_cache]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_cache.h
[transfer_cache]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/transfer_cache_entry.h
[dil]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/display_item_list.h
[writer]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_op_writer.h
