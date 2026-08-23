# Flutter engine — exactly-sized op records, and text that never crosses as a string

**Category:** retained scene. **Last reviewed:** August 23, 2026.
Pinned at [`feab40b8`][rev].

`dart:ui` is famous for being narrow, but the narrow thing is not the drawing
API — it is what the drawing API is allowed to _carry_. Flutter's engine has
three stacked seams (a Dart-facing `Canvas`, an in-engine `DlCanvas`, a
backend-facing `DlOpReceiver`), and the interesting decisions are all about
which facts are computed once during recording and frozen into the stream
versus which are left for the backend to re-derive.

| Field            | Value                                                                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | C++ (engine), Dart (`dart:ui` and framework)                                                                                                      |
| License          | BSD 3-Clause ([`LICENSE`][license])                                                                                                               |
| Repository       | [`flutter/flutter`][repo] (engine merged into the monorepo under `engine/src/flutter/`)                                                           |
| Documentation    | [`docs/about/The-Engine-architecture.md`][engine-arch]                                                                                            |
| Category         | retained scene                                                                                                                                    |
| Pinned revision  | `feab40b83b8d1954106e83bb1d7b52265a41cb45`                                                                                                        |
| Seam under study | `DlCanvas` (recording API) → `DisplayList` (the reified stream) → `DlOpReceiver` (backend)                                                        |
| Backends shipped | Impeller (`impeller::DlDispatcher`), Skia (`DlSkCanvasDispatcher`), plus non-rendering receivers ([`DlOpSpy`][dl-op-spy], complexity calculators) |
| Op record types  | 68 (`FOR_EACH_DISPLAY_LIST_OP`), in 8 categories (`DisplayListOpCategory`)                                                                        |
| Coordinate unit  | continuous `DlScalar` (`impeller::Scalar`, i.e. `float`) logical pixels                                                                           |

## Overview

### What it solves

Flutter's framework produces a scene on the UI thread; the rasterizer consumes
it on a different thread, possibly several frames later, against a GPU API the
framework has never heard of. The engine architecture doc states the goal
plainly:

> The layer tree created by the Dart code on the UI task runner is
> client-rendering-API agnostic. That is, the same layer tree can be used to
> render a frame using OpenGL, Vulkan, software or really any other backend
> configured for Skia.
>
> — [`docs/about/The-Engine-architecture.md`][engine-arch]

That is two problems, not one, and Flutter splits them across two artifacts. A
**layer tree** (`flutter::Layer`, built through `SceneBuilder`) carries the
semantic compositing structure — clips, opacity, backdrop filters, platform
views, cache hints. A **`DisplayList`** is the leaf: an immutable, replayable
op stream for the painting inside one layer.

### Design philosophy

`DlCanvas` is deliberately Skia-shaped — "The only state carried by
implementations of this interface are the clip and transform […] The interface
resembles closely the familiar `|SkCanvas|` interface used throughout the
engine" ([`dl_canvas.h`][dl-canvas]). `DlOpReceiver`, the backend-facing seam,
is explicitly _not_ the same thing:

> Internal API for rendering recorded display lists to backends. […] Unlike
> `DlCanvas`, this interface has attribute state which is global across an
> entire `DisplayList` (not affected by save/restore).
>
> — [`display_list/dl_op_receiver.h`][dl-op-receiver]

The two differ by exactly one design decision: `DlCanvas` takes a `DlPaint` per
draw call; `DlOpReceiver` does not, because the recorder has already turned
paint into a **delta stream of attribute-setting ops**. That single decision
drives most of what follows.

## How it works

### Three seams, not one

```cpp
// display_list/dl_canvas.h — the in-engine recording seam: paint per call
class DlCanvas {
  virtual void DrawRect(const DlRect& rect, const DlPaint& paint) = 0;
  virtual void DrawText(const std::shared_ptr<DlText>& text,
                        DlScalar x, DlScalar y, const DlPaint& paint) = 0;
  virtual DlISize GetBaseLayerDimensions() const = 0;
};

// display_list/dl_op_receiver.h — the backend seam: no paint argument at all
class DlOpReceiver {
  virtual void setColor(DlColor color) = 0;       // persistent attribute state
  virtual void setStrokeWidth(float width) = 0;
  virtual void drawRect(const DlRect& rect) = 0;
  virtual void drawText(const std::shared_ptr<DlText>& text,
                        DlScalar x, DlScalar y) = 0;
};
```

Above both sits `dart:ui`'s Dart `Canvas`, whose `drawRect(Rect, Paint)` and
`drawParagraph(Paragraph, Offset)` are the only drawing surface the framework
ever sees.

`DisplayListBuilder` is the hinge: it implements `DlCanvas` publicly and
`DlOpReceiver` privately, so recording a `DrawRect(rect, paint)` becomes "emit
whatever attribute ops this op actually reads, then emit `DrawRectOp`".

### The op-flags table decides what gets recorded

Every drawing op has a compile-time `DisplayListAttributeFlags` constant
declaring which paint attributes it consults and how its geometry can escape
its own bounds:

```cpp
static constexpr DisplayListAttributeFlags kDrawRectFlags{
    kBasePaintFlags |         //
    kBaseStrokeOrFillFlags |  //
    kMayHaveJoins             //
};
static constexpr DisplayListAttributeFlags kDrawImageFlags{
    kIgnoresPaint  //
};
```

`SetAttributesFromPaint` consults those flags and emits only the deltas the op
will read; every `setX` on the builder is guarded against re-emitting an
unchanged value (`if (current_.getColor() != color) onSetColor(color);`). So
the stream carries resolved appearance **once per change**, not once per op.
An op that `kIgnoresPaint` (`drawImage`, `drawShadow`, `drawDisplayList`)
records no appearance at all.

### The encoding: one struct type per op, allocated into a byte arena

`DisplayList` owns a `DisplayListStorage` — a `malloc`'d buffer plus a
`std::vector<size_t>` of record offsets. `DisplayListBuilder::Push<T>`
placement-news a `T` into it:

```cpp
template <typename T, typename... Args>
void* DisplayListBuilder::Push(size_t pod, Args&&... args) {
  size_t size = SkAlignPtr(sizeof(T) + pod);
  size_t offset = storage_.size();
  auto op = reinterpret_cast<T*>(storage_.allocate(size));
  new (op) T{std::forward<Args>(args)...};
  offsets_.push_back(offset);
  ...
}
```

Each record is a distinct final struct deriving from `DLOp`, sized to its own
payload — `DrawRectOp` is a `DlRect`, `DrawArcOp` is a rect plus three scalars,
`DrawPointsOp` is a `uint32_t` count followed by the points inline past the end
of the struct. There is no union and no field that is dead for some tags. The
header shows how far this is taken: "The point type is packed into 3 different
OpTypes to avoid expanding the fixed payload beyond the 8 bytes"
([`dl_op_records.h`][dl-op-records]). The same discipline splits `ClipIntersectRect` from `ClipDifferenceRect`,
`DrawImage` from `DrawImageWithAttr`, and `DrawShadow` from
`DrawShadowTransparentOccluder`. A boolean that would otherwise widen a record
becomes a second op type instead. That is how a seam with four conceptual
primitives ends up with 68 record types and no wasted bytes.

Dispatch is a switch over `op->type` generated from the same
`FOR_EACH_DISPLAY_LIST_OP` X-macro that generates the enum, the destructor
walk (`DisposeOps`) and the equality walk.

## Q1 — measurement units, and who answers

**Text never crosses the seam as a string.** `DlOpReceiver::drawText` takes a
`std::shared_ptr<DlText>`, and `DlText` is an already-shaped object:

```cpp
class DlText {
 public:
  virtual DlRect GetBounds() const = 0;
  virtual std::shared_ptr<impeller::TextFrame> GetTextFrame() const = 0;
  virtual const SkTextBlob* GetTextBlob() const = 0;
};
```

Neither `DlCanvas` nor `DlOpReceiver` has a `measure`. Measurement lives two
tiers up, on `dart:ui`'s `Paragraph`, which is a stateful object you must
`layout` before you may either measure or draw it:

```dart
abstract class Paragraph {
  double get width;              double get height;
  double get longestLine;        double get alphabeticBaseline;
  double get minIntrinsicWidth;  double get maxIntrinsicWidth;
  void layout(ParagraphConstraints constraints);
  List<TextBox> getBoxesForRange(int start, int end, ...);
  TextPosition getPositionForOffset(Offset offset);
}
```

The framework's `TextPainter` is a thin forwarder onto that object
(`double get width => _paragraph.width;`), and `Canvas.drawParagraph` is
documented as requiring that the layout already happened: "The `[Paragraph]`
object must have had `[Paragraph.layout]` called on it first."

This is the same result as Slint and egui by a third route, and stronger than
either: the measured artifact **is** the drawable artifact, so friction §1's
failure mode — `SkiaCanvas.measure` returning `cellsOf(text)` while Skia would
say something different — is structurally impossible. Note also what
`Paragraph` returns beyond a size: intrinsic widths, baselines, per-range
boxes, hit-testing. A single `Size measure(text)` cannot express any of it.

## Q2 — is the contract stated in one place?

**Yes, and completely — there is no capability query and no optional method.**
`DlOpReceiver` is 49 pure virtuals; a backend implements all of them or does
not compile. Nothing is discovered by probing.

What Flutter provides instead of optionality is **mixins that opt out by
category**: `IgnoreAttributeDispatchHelper`, `IgnoreClipDispatchHelper`,
`IgnoreTransformDispatchHelper` and `IgnoreDrawDispatchHelper` in
[`utils/dl_receiver_utils.h`][dl-receiver-utils] supply empty overrides, so a
receiver interested only in, say, image usage inherits the silence it wants.
Opting out is explicit at the type level, not inferred at each call site.

The other half of the contract is stated as **data**, not as a query: the
`DisplayListOpFlags` table in [`dl_op_flags.h`][dl-op-flags] declares, for every
op, which attributes apply and which geometric hazards it may have. That is a
declared capability set — but of the _operation_, not of the _backend_, which
is the inverse of Qt's `PaintEngineFeature`. It answers "what does this command
need" rather than "what can you do", and it is consumed by the recorder, so a
backend never has to ask.

> [!NOTE]
> This is the strongest available counter-model to friction §2. `isCanvas`
> requires five methods; `rule`, `scrollbar` and the `pushClip`/`popClip` pair
> are probed with `__traits(compiles)` at each call site in
> `interp/immediate.d`, so the concept states less than the contract. Flutter's
> contract is total, and finding **F5** is the reason that is a choice rather
> than a necessity: the cost here is that a minimal backend writes 49 method
> bodies, and the mixins exist precisely to make that bearable.

## Q3 — semantic operations, and where degradation lives

The `DisplayList` seam is **primitive**, with three deliberate exceptions that
are worth more than the rule:

- `drawShadow(path, color, elevation, transparent_occluder, dpr)` — a Material
  elevation shadow, not a blur. Each backend interprets it: Impeller
  re-implements Skia's tonal-colour computation from scratch in
  [`impeller/display_list/dl_dispatcher.cc`][impeller-dispatcher] ("ported from
  `SkShadowUtils::ComputeTonalColors`").
- `drawDashedLine(p0, p1, on_length, off_length)` — dashing as an op, not as a
  path effect the recorder lowers.
- `drawRoundSuperellipse(rse)` — the Apple-style squircle, with its own clip
  variant (`clipRoundSuperellipse`) and its own record type.

Each exists because a backend can do better with the intent than with a
lowering of it — Slint's bet, not Qt's, taken selectively rather than
wholesale. The genuinely semantic vocabulary sits **above** the display list, in the layer
tree that `SceneBuilder` builds: `pushClipRect`, `pushOpacity`,
`pushColorFilter`, `pushImageFilter`, `pushBackdropFilter`, `pushShaderMask`,
`addRetained`, `addPlatformView`, `addTexture`. Those are compositor concepts
(what can be cached, what needs a readback, what is a native view hole) and
they never enter the drawing seam.

The lesson for friction §3 is a **layering answer rather than a yes/no**: a
`scrollbar` is not wrong because it is semantic, it is wrong because it is
semantic at the leaf. Flutter's semantic ops (`drawShadow`) are leaf-level
_appearance_ with a backend-chosen realisation; its semantic _structure_
(opacity, clipping, retention) is a separate tree above the leaf.

## Q4 — command shape

Reified, immutable, comparable — and **not** a closed sum. Flutter reaches the
properties `DrawOp` delivers — a stream that records, replays, culls, caches and
diffs — through one struct type per op rather than through one record with eight
arms.

The replay/compare machinery is the payoff. `DisplayList::Equals` compares two
lists by walking offsets and letting most ops fall through to a **bulk
`memcmp`** across contiguous runs, because "most Ops can be bulk compared using
`memcmp` because they contain only numeric values". Only ops holding a
reference that needs a deep comparison override `equals()` and interrupt the
bulk run. That is only sound because every record is exactly its own payload —
a tag-plus-dead-fields encoding would compare uninitialised bytes.

> [!IMPORTANT]
> **Flutter's standing argument against the encoding `sparkles:ui` uses.**
> `DrawOp` wraps a closed `SumType` over eight payloads under `static
assert(DrawOp.sizeof <= 64)`, so a `PopClip` that carries no fields is as wide
> as `TextRun`, the widest arm. Flutter's position is that the sum is the wrong
> container: a **flat byte arena of heterogeneous exactly-sized records with a
> side table of offsets**, dispatched by a generated switch, keeps value
> semantics and comparability, pays no widest-variant padding, and lets a
> variable-length payload live inline immediately after its record instead of in
> a slice.
>
> The mechanism is its own, and it is real. `DisplayListBuilder::Push<T>`
> placement-news each record at `SkAlignPtr(sizeof(T) + pod)`;
> [`dl_op_records.h`][dl-op-records] splits a payload rather than widen one
> ("packed into 3 different OpTypes to avoid expanding the fixed payload beyond
> the 8 bytes"); `DisplayList::Equals` still bulk-`memcmp`s across contiguous
> runs. In D the shape is a byte `SmallBuffer` plus a `size_t[]` and a `switch`
> on a stored tag.
>
> The price is four things at once. The recovered bytes are only the spread
> between the narrowest arm and 64, on a stream whose text already lives in a
> frame arena. `OpKind` is derived — `DrawOp.kind` is an eight-arm `match!`, so
> the tag and the payload cannot disagree — and a stored tag makes the tag the
> truth again; the exhaustiveness goes with it, since a ninth arm breaks every
> `match!` at compile time where a ninth record type in an arena breaks a
> dispatch at run time. The seventeen accessor members (`kind`, `rect`, `text`,
> `visual`, `slot`, `barContent`, …) are written once against the sum and return
> a neutral value on an arm that cannot answer, and `visualOf` reconstructs a
> `Visual` from whichever resolved fields the payload it is looking at keeps —
> both dispatch on arm identity that a byte range does not have. And two
> `DrawOp`s compare as values, which is what makes `RecordingCanvas` a pairwise
> oracle rather than a golden; an arena compares byte ranges of unequal length
> through a pair of offset tables.
>
> **Answered on that last point.** Variable stride buys nothing once the widest
> payload fits the 64-byte budget, and it costs `RecordingCanvas` its
> pairwise-comparable value semantics — which the friction log lists among the
> things that are working. The evidence stands, and it is why finding **F3** keeps the encoding a live
> trade rather than a settled question.

Two smaller facts transfer. Each record declares `kRenderOpInc` and `kDepthInc`
as `static constexpr`, so the builder accumulates op counts and a Z-depth
budget with no runtime table; and `DisplayList` is indexable
(`GetRecordCount`, `Dispatch(receiver, index)`, `GetCulledIndices(cull_rect)`),
so a backend can plan or reorder instead of being forced through one linear
replay.

## Q5 — sub-unit placement

Flutter's coordinates are continuous `DlScalar` floats, so the six-position
enumeration `RuleEdge` spells out does not arise. The hairline does, which is
the same sub-unit question standing in a different place — finding **F6**'s
point that continuous coordinates relocate the problem rather than dissolve it.
Flutter's answer is F6's second half, a named fidelity:

> Defaults to 0.0, which correspond to a hairline width.
>
> — `Paint.strokeWidth`, [`lib/ui/painting.dart`][painting-dart]

A stroke width of zero is not a degenerate value; it is the toolkit saying "as
thin as you can". The backend decides what that is, in device units, at draw
time. Impeller clamps to `kMinStrokeSize = 1.0f` device pixel, scaled through
the current transform, and pays the difference in coverage rather than in size:

```cpp
Scalar Geometry::ComputeStrokeAlphaCoverage(const Matrix& transform,
                                            Scalar stroke_width) {
  Scalar scaled_stroke_width = transform.GetMaxBasisLengthXY() * stroke_width;
  if (scaled_stroke_width == 0.0 || scaled_stroke_width >= kMinStrokeSize) {
    return 1.0;
  }
  // This scalling is eyeballed from Skia.
  return std::clamp(scaled_stroke_width * 2.0f, 0.f, 1.f);
}
```

The bounds side is symmetric: `AdjustBoundsForPaint` uses its own
`min_stroke_width = 0.01` so a hairline still contributes a non-degenerate
bound during recording. Both numbers are backend/recorder policy; neither is in
the seam vocabulary.

Anti-aliasing is likewise a per-op _request_ rather than a placement:
`clipRect(rect, clip_op, is_aa)` and `setAntiAlias(bool)` say "soften this
edge", leaving the backend to decide what softening means.

## Q6 — resolved or semantic styling

**Resolved only, and delta-encoded.** There is no `Slot`-equivalent anywhere in
the display list. `DlPaint` is fully computed values, decomposed by the flags
table into `setColor`/`setStrokeWidth`/`setBlendMode`/… ops that persist across
`save`/`restore` — which is the one place `DlOpReceiver` deliberately breaks
`SkCanvas` compatibility, because attribute state that ignores the save stack
is cheaper to record and to replay.

The nearest thing to an unresolved value is `DlColor`'s colour space
(`DlColorSpace::kSRGB | kExtendedSRGB | kDisplayP3`), which travels with the
colour and is resolved by the backend against the destination surface. Even
that is a _numeric_ deferral, not a semantic role.

Flutter can afford this because it has no re-resolving backend: there is no
HTML/CSS receiver in-tree that wants class names instead of colours.
`sparkles:ui` has one, so its operations cannot be purely numeric the way a
delta-encoded attribute stream is: alongside the values a primitive actually
paints with — an `Ink`, or `FillRect`'s own colours and its
`const(BoxChrome)*` — six of the eight payloads still name the role those
values were resolved from, in a stored `Slot`. That confirms finding **F9**
rather than contradicting it: no surveyed subject carries both, and the
cost of carrying both is the cost of owning a backend that re-resolves, not an
intrinsic property of a drawing seam. Deriving the `Visual` on demand through
`visualOf` instead of storing one keeps the hedge cheap, which is exactly
friction §6's complaint — cheap is not the same as decided.

## Q7 — payload ownership

**Everything the stream needs, the stream owns**, via reference counting:
`sk_sp<DlImage>`, `std::shared_ptr<DlText>`, `std::shared_ptr<DlVertices>`,
`sk_sp<DisplayList>` for a nested list. `DisposeOps` runs the destructors of
non-trivially-destructible records on teardown, so the refcounts are released
exactly once.

That is the refcount arm of finding **F8**'s eight ownership mechanisms. Then
Flutter does the thing friction §7 actually needs and no other surveyed subject
does: it **computes whether the recorded list may cross a thread**, as a
property of the list.

```cpp
bool isUIThreadSafe() const { return is_ui_thread_safe_; }
```

`is_ui_thread_safe_` starts true and is `&&`-ed with every payload's own answer
as ops are recorded (`is_ui_thread_safe_ = is_ui_thread_safe_ && image->isUIThreadSafe();`),
where a `DlImage` reports true when "the underlying platform image held by this
object has no threading requirements for the release of that image (or if
arrangements have already been made to forward that image to the correct thread
upon deletion)".

Friction §7 is about a GPU backend recording on one thread and submitting on
another. `DrawOp.text` is a `const(char)[]` borrowed from a frame arena that
`CmdBuffer.textRun` copies into, under a rule stated on the type — an operation
is valid while the buffer that built it is alive and unreset — and `UI-O4` is
open on exactly where the retain boundary goes. Flutter's answer is not "make
everything shareable" but "let each
payload declare its own constraint, conjoin the answers during recording, and
let the consumer ask the finished list one question". `DisplayList` carries
several other conjoined summaries computed the same way —
`can_apply_group_opacity()`, `modifies_transparent_black()`,
`root_has_backdrop_filter()`, `root_is_unbounded()`, `max_root_blend_mode()` —
each so the compositor can pick a surface kind without walking the ops.

## Q8 — extent query

**Answered on the surface, on the scene and on every layer — and maintained at
construction in all three.**

The scene knows its extent: `DisplayList::GetBounds()` returns bounds
accumulated during recording, not scanned afterwards. `AccumulateOpBounds`
takes each op's geometry, runs it through `AdjustBoundsForPaint` — which
expands for stroke width, miter joins, square diagonal caps, mask-blur sigma
(`sigma * 3.0`), and image-filter local mapping — then maps and clips it into
both a global and a layer-local accumulator:

```cpp
bool DisplayListBuilder::AccumulateOpBounds(DlRect& bounds,
                                            DisplayListAttributeFlags flags) {
  if (AdjustBoundsForPaint(bounds, flags)) {
    return AccumulateBounds(bounds);
  } else {
    return AccumulateUnbounded();
  }
}
```

The flags table is what lets the accumulator stay ignorant of individual ops:
`may_have_acute_joins()` says whether to multiply by the miter limit,
`is_flood()` says the op has no natural bounds, and `root_is_unbounded()`
propagates that outward. The same pass optionally builds a `DlRTree`
(`prepare_rtree`), which backs `GetCulledIndices(cull_rect)`.

The surface also knows its extent: `DlCanvas::GetBaseLayerDimensions()` is on
the seam, and `DisplayListBuilder` answers it from the cull rect it was
constructed with (`DlIRect::RoundOut(original_cull_rect_).GetSize()`). And the
layer tree has a third answer: every `flutter::Layer` carries a `paint_bounds()`
established during `Preroll`.

> [!IMPORTANT]
> This is the survey's sharpest confirmation of finding **F7**. F7 separates
> surface, layout and ink extent and sorts the answers by
> maintained-at-construction versus derived-by-scan; Flutter answers all three
> and maintains every one. The surface's extent is "how much can I paint", the
> scene's is "how much did I paint", and the second is what culling, caching,
> layer sizing and `skia-canvas-render.d`'s offscreen sizing all need.
> `sparkles:ui` answers none of the three: no figure for how much a finished
> stream covers is kept by the buffer that built it, by the display list it
> produced, or by the arena its text lives in — `CmdBuffer` has `length` and
> `measure` and stops there — so friction §8 sits squarely on the
> derived-by-scan side. Flutter never scans: bounds accumulate at record time,
> on a stream that is being built anyway, through a flags table the recorder
> already consults for a different purpose.

## Strengths

- **The measured object is the drawn object.** Passing a laid-out `Paragraph`
  removes the class of bug where measurement and painting disagree, and it
  carries baselines, intrinsic widths and hit-testing that a `Size` cannot.
- **A total, non-negotiable backend contract.** No probing, no silent
  degradation; opting out of a category is an explicit base class.
- **Zero-waste encoding with full value semantics.** Per-op structs in a byte
  arena give replay, comparison (bulk `memcmp`), culling and caching without a
  widest-variant tax.
- **Declared op metadata drives the recorder.** One `constexpr` flags table
  serves attribute recording, bounds expansion and stroke/fill decisions.
- **Derived facts are computed once, during recording** — bounds, depth, thread
  safety, group-opacity eligibility, blend-mode ceiling — all free during a walk
  that was happening anyway, and all queryable on the finished list.
- **Semantic structure is above the drawing seam**, in the layer tree, where
  caching and platform-view composition can act on it.

## Weaknesses

- **The backend surface is enormous.** 49 pure virtuals on `DlOpReceiver`, 47
  on `DlCanvas`, 68 record types. Writing a new backend is a project, not an
  afternoon; the `Ignore*DispatchHelper` mixins are an admission of this.
- **Attribute state that ignores `save`/`restore`** is cheap to record but is a
  documented deviation from the `SkCanvas` model the seam otherwise imitates —
  a trap for a backend author porting Skia intuitions.
- **The depth protocol is an implicit contract.** `DlOpReceiver`'s header
  spends ~45 lines explaining that a dispatcher must replicate the builder's
  depth allocation exactly to interpret the totals reported by `save`. Nothing
  in the type system enforces it.
- **No software/cell-like target.** Every shipped receiver targets a GPU
  rasterizer, so the seam has never been pressured by a device whose smallest
  unit is not a fraction of a pixel.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                                     | Trade-off                                                                                                       |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Text enters the seam as a shaped `DlText`, never a string          | Measurement and painting cannot disagree; shaping happens once, above, on the UI thread                       | The seam cannot serve a target that wants to shape for itself; font fallback policy is fixed above the seam     |
| One exactly-sized record struct per op, in a `malloc`'d byte arena | No padding for a widest variant; variable payloads inline; bulk `memcmp` equality                             | 68 types to maintain, X-macro-generated dispatch/dispose/compare walks, `reinterpret_cast` at every step        |
| Paint decomposed into persistent attribute-delta ops               | Unchanged attributes cost nothing; ops carry only geometry                                                    | Receiver is stateful and order-dependent; a backend cannot dispatch one op in isolation without replaying state |
| A `constexpr` flags table per op, not a backend capability query   | The recorder can decide what to emit and how to expand bounds without asking anyone                           | Says nothing about what a backend can render; there is no way to be told "no"                                   |
| Bounds accumulated at record time, optional `DlRTree`              | Culling, caching and layer sizing all need per-op bounds; a later scan would be a second pass over everything | Every op must have a bounds rule; unbounded ops need an explicit `is_flood()` escape                            |
| Payloads reference-counted and owned by the record                 | The list outlives the frame that built it and crosses threads                                                 | Refcount traffic during recording; records need real destructors (`DisposeOps`)                                 |
| Thread-safety is a conjoined property of the list                  | The consumer asks one question instead of auditing payloads                                                   | Requires every payload type to answer honestly; one pessimistic payload poisons the whole list                  |
| Semantic compositing lives in a layer tree above the display list  | Caching, retention and platform-view holes are compositor concerns                                            | Two artifacts to reason about; the boundary between them is conventional                                        |

## Bearing on the proposal

1. **Take Q1 as settled.** Finding **F1** puts 35 of 38 subjects' measurement
   somewhere other than the painter, and Flutter is the strongest form: the seam
   accepts only an already-measured object. Whatever takes over from `measure` —
   the fifth of the five methods `isCanvas` requires — should be an _object_
   carrying baselines, intrinsic widths, per-range boxes and hit-testing, not a
   function returning a size.
2. **The encoding argument, and where it stops.** Flutter's position is that
   `DrawOp` should not be a closed sum at all — a **flat arena of heterogeneous
   exactly-sized records plus an offsets table** keeps value semantics and
   comparability, pays no widest-variant padding, and puts a variable-length
   payload inline after its record rather than in a slice, which is friction §7
   from the other end. In D that is a byte `SmallBuffer` plus a `size_t[]` and a
   `switch` on a stored tag. It is **answered**: variable stride buys nothing
   once the widest payload fits the `<= 64`-byte budget, and it costs
   `RecordingCanvas` the pairwise-comparable value semantics the friction log
   records as working, along with the derivation of `OpKind` from the payload
   and the compile-time exhaustiveness of every `match!` walker. Finding **F3**
   holds the trade open on this evidence; this file is the arm arguing for
   stride.
3. **Take the layering answer to §3, not the arm-splitting one.** The
   `Scrollbar` payload carries fourteen fields, two of them (`trackGlyph`,
   `thumbGlyph`) a cell backend's answer riding past every backend that will
   never read them. Flutter's own split is the more useful lesson than its
   record-per-variant discipline: leaf-level _appearance_ with a
   backend-chosen realisation (`drawShadow`) belongs in the drawing seam, and
   semantic _structure_ belongs in a tree above it. That is finding **F4**'s
   axis — where the lowering lives — applied to the one primitive that carries
   both.
4. **Declare op metadata as data, `constexpr`, next to the op** (§2). Flutter's
   flags table is the counter-model to `__traits(compiles)` probing: it states
   what an op needs, is read by the recorder rather than the backend, and is
   reused for bounds accumulation. It does not, however, answer "can this
   backend do it" — so finding **F5**'s refusable arm (a stated floor, a
   defaulted middle, a degrade a backend may decline) gets no support from this
   subject.
5. **`strokeWidth == 0` means hairline is F6's "name a fidelity" already
   shipping.** `rule` is one of the four optional primitives, and its
   stated degradation is `ruleEndpoints` plus a cell-aligned `line`. A fidelity
   name — "thinnest you can draw along this geometry", answered by the backend
   in device pixels (Impeller: clamp to one pixel, pay the difference in alpha)
   — carries more than six `RuleEdge` positions can.
6. **Confirms F7 on all three of its questions.** Flutter puts extent on the
   surface (`GetBaseLayerDimensions`), on the scene (`DisplayList::GetBounds`)
   _and_ on every layer (`Layer::paint_bounds`), and maintains each at
   construction. Accumulate the scene's bounds during `buildDisplayList` — the
   pass already walks every operation — instead of leaving `skia-canvas-render.d`
   to fold `op.rect` for itself.
7. **Steal `isUIThreadSafe` wholesale** for friction §7 / `UI-O4`: a display
   list that answers "may I cross a thread", conjoined from its payloads during
   recording, is cheaper than interning or reference-counting everything and is
   exactly the question M7/T5 asks. Generalise it — `total_depth`,
   `can_apply_group_opacity`, `root_is_unbounded` are all conjunctions
   accumulated for free, so any query `sparkles:ui`'s display list grows should
   be a field `CmdBuffer` sets beside `length`, not a walk.
8. **Do not copy the total-contract shape without pricing it.** 49 pure
   virtuals works because Flutter has two backends and a large team. The
   transferable part is that the contract should be _stated somewhere
   complete_, not that optionality is wrong.

## Sources

Primary sources, all read at `feab40b83b8d1954106e83bb1d7b52265a41cb45` in a
local clone of [`flutter/flutter`][repo] and verified with
`git cat-file -e HEAD:<path>`.

- The seam itself: [`dl_canvas.h`][dl-canvas] (recording API),
  [`dl_op_receiver.h`][dl-op-receiver] (backend API and the depth protocol),
  [`dl_text.h`][dl-text] (shaped text as the only text payload).
- The encoding: [`display_list.h`][display-list-h] (`FOR_EACH_DISPLAY_LIST_OP`,
  `SaveLayerOptions`, the derived-property accessors),
  [`display_list.cc`][display-list-cc] (`CompareOps`, `DisposeOps`),
  [`dl_op_records.h`][dl-op-records] (the record structs and their packing
  commentary), [`dl_storage.h`][dl-storage] (the byte arena).
- The recorder: [`dl_builder.h`][dl-builder-h] / [`dl_builder.cc`][dl-builder-cc]
  (`Push<T>`, attribute dedup, bounds accumulation),
  [`dl_op_flags.h`][dl-op-flags] (the declared per-op attribute/geometry table).
- Backends and payloads: [`skia/dl_sk_dispatcher.h`][dl-sk-dispatcher],
  [`impeller/display_list/dl_dispatcher.cc`][impeller-dispatcher] (including its
  own shadow math), [`impeller/entity/geometry/geometry.cc`][impeller-geometry]
  (`kMinStrokeSize` coverage clamp), [`image/dl_image.h`][dl-image]
  (`isUIThreadSafe`), [`utils/dl_receiver_utils.h`][dl-receiver-utils] (opt-out
  mixins).
- Above the seam: [`lib/ui/painting.dart`][painting-dart] (`Canvas`,
  `Paint.strokeWidth`, `drawParagraph`), [`lib/ui/text.dart`][text-dart]
  (`Paragraph`), [`lib/ui/compositing.dart`][compositing-dart] (`SceneBuilder`),
  [`flow/layers/layer.h`][layer-h] (`Preroll` / `paint_bounds`).
- [`docs/about/The-Engine-architecture.md`][engine-arch] — thread model and rendering-API agnosticism

<!-- References -->

[rev]: https://github.com/flutter/flutter/tree/feab40b83b8d1954106e83bb1d7b52265a41cb45
[repo]: https://github.com/flutter/flutter
[license]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/LICENSE
[engine-arch]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/docs/about/The-Engine-architecture.md
[dl-canvas]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/dl_canvas.h
[dl-op-receiver]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/dl_op_receiver.h
[display-list-h]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/display_list.h
[display-list-cc]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/display_list.cc
[dl-op-records]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/dl_op_records.h
[dl-storage]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/dl_storage.h
[dl-builder-h]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/dl_builder.h
[dl-builder-cc]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/dl_builder.cc
[dl-op-flags]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/dl_op_flags.h
[dl-text]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/dl_text.h
[dl-image]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/image/dl_image.h
[dl-receiver-utils]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/utils/dl_receiver_utils.h
[dl-sk-dispatcher]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/skia/dl_sk_dispatcher.h
[impeller-dispatcher]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/impeller/display_list/dl_dispatcher.cc
[painting-dart]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/lib/ui/painting.dart
[text-dart]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/lib/ui/text.dart
[compositing-dart]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/lib/ui/compositing.dart
[layer-h]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/flow/layers/layer.h
[dl-op-spy]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/common/dl_op_spy.h
[impeller-geometry]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/impeller/entity/geometry/geometry.cc
