# Skia — three seams at three widths, and the narrowest is the real one

**Category:** reified command stream. **Last reviewed:** August 23, 2026.
Pinned at [`3ad790ab`][rev].

The library `sparkles:skia` binds, read as a seam design rather than as a
renderer. Skia is the subject that ought to have answered
[Q4](./index.md#what-each-subject-must-answer) and
[Q8](./index.md#what-each-subject-must-answer) outright — `SkPicture` is a
reified, replayable, cullable command stream with a `cullRect()` accessor. It
answers Q4 emphatically and **Q8 not at all**, for a reason worth transferring.

| Field            | Value                                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------- |
| Language         | C++                                                                                           |
| License          | BSD-3-Clause ([`LICENSE`][license])                                                           |
| Repository       | [`google/skia`][rev] (canonical: `skia.googlesource.com/skia`)                                |
| Documentation    | in-header DDoc-style comments; [`skia.org`][site]                                             |
| Category         | reified command stream                                                                        |
| Pinned revision  | [`3ad790ab4d6d596efae0d70e4b8bf7d339121984`][rev]                                             |
| Backends shipped | raster CPU, Ganesh (GL/Vulkan/Metal/D3D), Graphite (Vulkan/Metal/Dawn), PDF, SVG, XPS, record |
| Seam widths      | 33 public `SkCanvas::draw*` → 26 `onDraw*` virtuals → **10** pure-virtual `SkDevice` draws    |

## Overview

### What it solves

One drawing vocabulary that reaches a CPU bitmap, three GPU APIs, and two
document formats, plus a recording target that turns the same calls into a
value. [`SkPicture.h`][picture] states the recording contract in its class
comment:

```cpp
    SkPicture records drawing commands made to SkCanvas. The command stream may be
    played in whole or in part at a later time.
    ...
    SkPicture has a cull SkRect, which is used as
    a bounding box hint. To limit SkPicture bounds, use SkCanvas clip when
    recording or drawing SkPicture.
```

Two clauses in that paragraph carry the whole Q8 answer: the cull rect is a
**hint**, and it is something you _pass in_, not something the picture derives.

### Design philosophy

`SkCanvas` is documented as an _interface for drawing_, not as a backend
port — the destination is a separate object ([`SkCanvas.h`][canvas]):

```cpp
    SkCanvas provides an interface for drawing, and how the drawing is clipped and transformed.
    SkCanvas contains a stack of SkMatrix and clip values.

    SkCanvas and SkPaint together provide the state to draw into SkSurface or SkDevice.
```

That sentence is the design: `SkCanvas` owns the _transform and clip stacks_ and
nothing else; the pixels belong to `SkDevice`. A "Skia backend" is an `SkDevice`
subclass, and `SkDevice` is in `src/`, not `include/` — it is deliberately not
public API.

## How it works

Three distinct seams sit on top of each other, each narrower than the last.

**1. `SkCanvas`, the wide convenience surface.** 33 public `draw*` entry points
(`drawCircle`, `drawRoundRect`, `drawString`, `drawIRect`, …) that are
non-virtual sugar collapsing into 26 protected `onDraw*` virtuals.
`drawString` is literally an inline forward to `drawSimpleText` ([`SkCanvas.h`][canvas]).

**2. `SkCanvasVirtualEnforcer`, the subclass contract.** A CRTP-ish template
whose entire body re-declares the interesting `onDraw*` hooks as pure virtual,
so a subclass that forgets one fails to compile ([`SkCanvasVirtualEnforcer.h`][enforcer]):

```cpp
// If you would ordinarily want to inherit from Base (eg SkCanvas, SkNWayCanvas), instead
// inherit from SkCanvasVirtualEnforcer<Base>, which will make the build fail if you forget
// to override one of SkCanvas' key virtual hooks.
template <typename Base>
class SkCanvasVirtualEnforcer : public Base {
protected:
    void onDrawPaint(const SkPaint& paint) override = 0;
    void onDrawBehind(const SkPaint&) override {} // make zero after android updates
    void onDrawRect(const SkRect& rect, const SkPaint& paint) override = 0;
    ...
};
```

This is a **capability declaration expressed in the type system**: opting into
`SkCanvasVirtualEnforcer` converts "the contract is whatever the base class
happens to default" into "here is the list, handle all of it". `SkCanvas.h`
carries the maintenance rule beside its virtuals: _"NOTE: If you are adding a
new onDraw virtual to SkCanvas, PLEASE add an override to
SkCanvasVirtualEnforcer"_.

**3. `SkDevice`, the actual backend port.** Of 26 virtual `draw*` members
([`SkDevice.h`][device]) exactly **ten** are pure virtual — `drawPaint`,
`drawPoints`, `drawRect`, `drawOval`, `drawRRect`, `drawPath`, `drawImageRect`,
`drawVertices`, `drawMesh` and `onDrawGlyphRunList`. Every other operation has a
base-class lowering. `SkDevice::drawArc` is the pattern ([`SkDevice.cpp`][devicecpp]):

```cpp
void SkDevice::drawArc(const SkArc& arc, const SkPaint& paint) {
    bool isFillNoPathEffect = SkPaint::kFill_Style == paint.getStyle() && !paint.getPathEffect();
    SkPath path = SkPathPriv::CreateDrawArcPath(arc, isFillNoPathEffect);
    this->drawPath(path, paint);
}
```

### The reified stream

`SkRecordCanvas` is one such `SkCanvas` subclass; it appends into an `SkRecord`,
and `SkPictureRecorder` wraps the pair. `SkRecord` is **not** a tagged struct.
It is a parallel array of `{type tag, arena pointer}` over a heterogeneous
arena, with one C++ struct per operation ([`SkRecord.h`][record]):

```cpp
    // An SkRecord is structured as an array of pointers into a big chunk of memory where
    // records representing each canvas draw call are stored:
    //
    // fRecords:  [*][*][*]...
    //             |  |  |
    //             v  v  v
    //   fAlloc:  [SkRecords::DrawRect][SkRecords::DrawPosTextH][SkRecords::DrawRect]...
```

The 42 op types are generated from one macro list, `SK_RECORD_TYPES(M)`, which
simultaneously defines the `SkRecords::Type` enum, the structs, and the
`switch` in `visit`/`mutate` ([`SkRecords.h`][records]):

```cpp
#define RECORD(T, tags, ...)                \
    struct T {                              \
        static const Type kType = T##_Type; \
        static const int kTags = tags;      \
        __VA_ARGS__;                        \
    };

RECORD(DrawRect, kDraw_Tag|kHasPaint_Tag,
        SkPaint paint;
        SkRect rect)
```

Dispatch is a template functor, not a `switch` the caller writes:

```cpp
    template <typename F>
    auto visit(int i, F&& f) const -> decltype(f(SkRecords::NoOp())) {
        return fRecords[i].visit(f);
    }
```

A visitor supplies `template <typename T> R operator()(const T&)`; a visitor
that fails to handle a type fails to compile — `SkRecords::Draw` relies on this
explicitly: _"No base case, so we'll be compile-time checked that we implement
all possibilities"_ ([`SkRecordDraw.h`][recorddraw]).

## Q1 — measurement unit, and who answers

**Not on the canvas.** Text measurement is on `SkFont`:
`SkFont::measureText`, `SkFont::getWidthsBounds`, `SkFont::getMetrics`
([`SkFont.h`][font]). `SkCanvas` has no `measure`. Shaping is further out
still, in a separate module (`modules/skshaper`, `modules/skparagraph`).

The unit is `SkScalar` — device-independent float, one number, no policy about
what a "cell" is. That puts Skia with the large majority
[F1](./comparison.md) counts, and makes it the one subject where _our own
binding does it that way_: `sparkles:skia`'s C shim exposes
`sparkles_skia_font_measure_utf8` on `SkFont*`, while the fifth method of
[`isCanvas`][canvas-d] — `Size measure(const(char)[])` — is denominated in
cells. Friction §1 is therefore not a Skia limitation we inherited; it is a
seam decision we make on top of a library that answers the other way.

## Q2 — is the contract stated, or probed?

Stated, three times, in three different mechanisms — and this is Skia's most
transferable idea.

- **The floor is `= 0`.** Ten `SkDevice` draws must be implemented. There is no
  probing and no degrading: a device that cannot fill a path is not a device.
- **The negotiable set is a virtual with a working default.** `drawArc`,
  `drawDRRect`, `drawRegion`, `drawPatch`, `drawAtlas`, `drawImageLattice`,
  `drawShadow` and `drawEdgeAAQuad` all lower to the floor in the base class.
  Overriding one is an _optimisation_, never a requirement.
- **Refusal is a `bool` return.** `drawBlurredRRect` is documented _"Draw rrect
  with an optimized path for analytic blurs, if provided by the device"_ and
  defaults to `return false;`; `drawAsTiledImageRect` and `onPeekPixels` do the
  same. The caller then takes the generic route.

For genuinely optional _semantics_ the answer is silence, stated as policy —
[`SkAnnotation.h`][annotation] promises: _"If the backend of this canvas does
not support annotations, this call is safely ignored."_

> [!IMPORTANT]
> This is the shape [F5](./comparison.md) asks for, achieved with **no
> capability enum and no query at all** — no `hasFeature`, no
> `PaintEngineFeature` bitmask. Qt declares capability as data; Skia encodes the
> identical distinction in three C++ constructs the compiler already checks.
> `sparkles:ui` holds two of the three: `isCanvas!T`'s five methods are the
> floor, and each of the four optional primitives carries a stated degradation
> that `interp/immediate.d` applies where `__traits(compiles, …)` reports the
> backend has no better answer. The third rung — a way for a backend that _does_
> implement a primitive to hand one call back, the way `drawBlurredRRect`
> returns `false` — has no spelling in the seam. And the whole ladder is learned
> by reading the interpreter rather than the concept, which is friction §2
> ("five methods, eight kinds") stated from the other side.

What Skia does _not_ have is a way for a **caller** to ask a device what it
supports; `recordingContext()`, `recorder()` and `baseRecorder()` returning
`nullptr` are the closest thing, and they answer "which family are you", not
"can you do this".

## Q3 — semantic operations, or primitives?

Overwhelmingly primitive, with exactly two exceptions, and both exceptions are
instructive.

`DrawShadowRec` carries `fZPlaneParams`, `fLightPos`, `fLightRadius`,
`fAmbientColor`, `fSpotColor` ([`SkDrawShadowInfo.h`][shadow]) — a _lighting
model_, not a blurred rect. `SkDevice::drawShadow` has a default that
computes the geometry, so a device may override it for a fast path or ignore
the distinction entirely. And `DrawAnnotation` carries a `const char key[]` plus
opaque `SkData` — a pure semantic channel that the PDF backend consumes as
hyperlinks and every raster backend drops on the floor.

So Skia's answer to "does a semantic concept belong in the drawing seam" is:
**yes, when a backend could do something genuinely different with it, and the
default lowering exists in the framework so no backend is obliged to care.**
Judged by that criterion, `scrollbar` in `DrawOp` passes: a cell backend
degrades a scrollbar differently from a pixel backend, and the framework does
ship the default lowering — `scrollbarThumb` in `sparkles.ui.state`, with
`scrollbarCellCount` and `scrollbarCell` re-exported from `canvas.d`, which the
interpreter paints glyph-per-cell for any backend that declines the primitive.
The distance from Skia is one of _declaration_, not of behaviour:
`SkDevice::drawShadow` is a virtual with a body, so the lowering sits on the
type a backend author is subclassing, while ours is a branch taken inside
`interp/immediate.d`.

## Q4 — command shape

**An open sum type built from a macro list, dispatched by a template visitor.**
This is the single richest result in the survey for friction §4.

Skia rejects both the tagged-struct-with-dead-fields encoding _and_ the closed
discriminated union. `SkRecord::Record` is a type tag beside a raw arena
pointer — and the payload is a distinct struct per op, placement-newed
into an arena, sized exactly for that op. `DrawRect` is a paint plus a rect;
`DrawImageLattice` is eleven fields. Neither pays for the other:

> The cost to append a T to this structure is 8 + sizeof(T) bytes.

Three properties follow that our `DrawOp[]` does not have:

1. **Variable-size payloads.** `PODArray<SkPoint>` and `Optional<SkPaint>` are
   arena-backed handles, so `DrawPoints` stores `n` points inline in the same
   allocation. `TextRun` reaches the same safety by a different route —
   `CmdBuffer.textRun` copies the bytes into a frame arena and the operation
   holds a 16-byte `const(char)[]` into it — but the operation itself stays
   fixed-width, and a `PopClip` that carries nothing costs what a `TextRun`
   costs.
2. **Op-level metadata as data.** Each record declares `kTags` —
   `kDraw_Tag`, `kHasImage_Tag`, `kHasText_Tag`, `kHasPaint_Tag`,
   `kMultiDraw_Tag` — so a pass can select "ops that contain text" generically
   instead of enumerating kinds.
3. **Mutation in place.** `SkRecord::mutate`, `replace<T>`, `defrag()` and the
   `SkRecordOpts` passes (`SkRecordNoopSaveRestores`,
   `SkRecordNoopSaveLayerDrawRestores`) rewrite the stream _before_ any backend
   sees it ([`SkRecordOpts.h`][recordopts]).

> [!NOTE]
> The macro-list trick is the C++ substitute for what D gives directly.
> `SK_RECORD_TYPES(M)` exists to keep the enum, the structs and the dispatch
> `switch` from drifting. `DrawOp` is that sum written in the language instead:
> a `SumType` over eight per-kind structs, `match!` in place of the visitor,
> exhaustiveness checked by the compiler, and `OpKind` derived from the arm
> rather than stored beside it so the tag and the payload cannot disagree. Skia
> spends a macro to buy what a D sum type is. What the macro buys and the sum
> does not is `kTags` — which in D is a UDA on each payload struct, read with
> `__traits`.

## Q5 — sub-unit placement

`SkScalar` is float throughout and the device transform is an `SkM44`, so there
is no enumerated vocabulary of positions: a caller who wants a band two pixels
below the top edge writes the rect, and `RuleEdge`'s six enumerators have no
counterpart. What the float seam does not do is make the sub-unit question
disappear — it moves it, which is the point [F6](./comparison.md) makes. Skia's
answer at the relocated site is a _named fidelity_: a hairline is
`SkPaint::setStrokeWidth(0)`, a documented special case meaning "thinnest line
the device can draw". Friction §5's compass directions are the cell-space form
of the same pressure; a continuous coordinate would spell the position and
still need the fidelity named.

## Q6 — resolved appearance, semantic role, or both?

**Resolved only, in one aggregate.** Every drawing record that has appearance
carries an `SkPaint` by value (or `Optional<SkPaint>`), and `SkPaint` is fully
resolved: colour, blend mode, shader, stroke width, mask/path/colour filters.
There is no slot, no role, no theme token anywhere in `SkRecords.h`.

The re-resolving use case — our `Slot`, for the HTML backend's class names — is
served _outside_ the record, by wrapping the canvas.
[`SkPaintFilterCanvas`][paintfilter] intercepts every draw and hands the paint
to a subclass hook before forwarding:

```cpp
class SK_API SkPaintFilterCanvas : public SkCanvasVirtualEnforcer<SkNWayCanvas> {
protected:
    virtual bool onFilter(SkPaint& paint) const = 0;
```

`SkNWayCanvas` multiplexes one command stream into N canvases, and
`SkNoDrawCanvas` is a canvas that records state and discards draws. Composed,
these are how Skia gets overdraw visualisation, debug capture and paint
overrides without a second field on every op.

That is a real alternative to friction §6, "a resolved appearance and a semantic
role on every drawing op". `DrawOp` stores the resolved half as an `Ink` — or,
on `FillRect`, as its own colour fields plus a `const(BoxChrome)*` that is null
unless the box has a border, shadow, radius or arrow — and keeps a `Slot` on six
of its eight payloads; `Visual` is reconstructed through `visualOf` rather than
stored, which makes the hedge cheap without making it a decision. Skia's route
is to **carry one representation and put the other in a decorator canvas**. It
costs a virtual call per op — but `sparkles:ui` is structurally typed, so the D
equivalent is a `FilteringCanvas!(Inner, hook)` template with the call
inlined.

## Q7 — payload ownership

**Value or reference count, never a borrow.** `DrawPath` stores an `SkPath` by
value; `DrawRect` an `SkRect`; `DrawTextBlob` an `sk_sp<const SkTextBlob>`;
`DrawImage` an `sk_sp<const SkImage>`. POD arrays are copied into the record's
own arena via `SkRecord::alloc<T>`. `SkRecords::Optional<T>` explicitly _"doesn't
own the pointer's memory, but may need to destroy non-POD data"_ — the memory is
the record's arena, and the destructor still runs.

`SkTextBlob` is the pre-shaped payload: _"SkTextBlob combines multiple text runs
into an immutable container. Each text run consists of glyphs, SkPaint, and
position"_ ([`SkTextBlob.h`][textblob]), refcounted with `SkNVRefCnt`, carrying
its own `bounds()` and `uniqueID()`. It is the equivalent of egui's `Galley`,
and it is what makes `finishRecordingAsPicture()` able to promise an
**immutable** picture that outlives its recorder and crosses threads.

Friction §7 — "`DrawOp.text` is borrowed, and the borrow is not expressible" —
meets Skia at a narrower place than it first looks. The copy is not the
difference: `CmdBuffer.textRun` copies its bytes into a frame arena exactly as
`SkRecord::alloc<T>` copies POD arrays into the record's, and that copy is what
makes a `scope` source safe to draw from. The difference is the _retain
boundary_. `SkRecord` owns its arena for the life of the picture, so
`finishRecordingAsPicture()` hands out an immutable value that crosses threads;
`DrawOp` states its rule on the type — an operation is valid while the buffer
that built it is alive and unreset — and that buffer resets at frame end.
`UI-O4` is open on exactly that boundary.

## Q8 — extent query

**Skia does not have one, and it declined to build one on purpose.** This is
the finding that contradicts the premise this subject was surveyed under.

`SkPicture::cullRect()` looks like a bounds query and is not:

```cpp
    /** Returns cull SkRect for this picture, passed in when SkPicture was created.
        ...
        @return  bounds passed when SkPicture was created
    */
    virtual SkRect cullRect() const = 0;
```

`SkBigPicture` stores it as `const SkRect fCullRect`, straight from the
`SkPictureRecorder::beginRecording(bounds, …)` argument. The _caller_ declares
the extent before recording; the picture repeats it back.

Skia is fully capable of deriving content bounds — `SkRecordFillBounds`
computes a conservative identity-space rect **per op** to fill an
`SkBBoxHierarchy` for culling. But that machinery is clamped by the declared
rect rather than being the means of discovering it
([`SkRecordDraw.cpp`][filldraw]):

```cpp
        // Nothing can draw outside the cull rect.
        if (!rect.intersect(fCullRect)) {
            return Bounds::MakeEmpty();
        }
```

The bounds array is handed to the `SkBBoxHierarchy` and never surfaced. The one
concession is `finishRecordingAsPictureWithCull(cullRect)` — _revise_ the
declared rect at the end of recording, still with a number the caller computed.

> [!WARNING]
> Skia had every reason to expose a content-extent query — it already computes
> per-op bounds, it has a spatial index of them, and `SkTextBlob::bounds()`
> means even text is measurable without shaping again. It exposes
> `approximateOpCount()` and `approximateBytesUsed()` instead. Extent is
> the surface's business.

## Strengths

- **The floor / lowering / refusal ladder** is enforced by the compiler and
  costs no runtime vocabulary. A new `SkDevice` implements ten methods and is
  correct, then overrides more and is fast.
- **A per-op struct in an arena** gives exact-size payloads and variable-length
  data without a widest-member tax, and stays cache-dense (16-byte index array).
- **Compile-time-exhaustive visitors.** Adding an op breaks every consumer that
  does not handle it, at build time.
- **Interception is composition, not a field.** `SkNWayCanvas`,
  `SkPaintFilterCanvas` and `SkNoDrawCanvas` bolt behaviour onto the stream
  without widening the op.
- **The stream is optimisable before dispatch.** `SkRecordOptimize` deletes
  no-op save/restore pairs the recorder emitted naively — a property that only
  exists because the stream is a mutable value.
- **`kTags` makes ops queryable by property**, not only by kind.

## Weaknesses

- **The backend seam is private.** `SkDevice` lives in `src/core/`; an
  out-of-tree backend is not a supported thing. The public `SkCanvas` subclass
  route exists but gives you a _proxy_, not a rasteriser.
- **Three widths is three chances to drift.** The `SkCanvas.h` comment begging
  contributors to update `SkCanvasVirtualEnforcer` is the maintenance cost made
  visible.
- **`SkPaint` by value on most records is heavy** — Skia mitigates with the
  comment _"if you have an SkPaint, it's fastest to put it first"_, which is a
  layout micro-optimisation standing in for a resolved-style interning scheme.
- **No caller-facing capability query at all.** Fine when the framework owns
  every lowering; harder for a toolkit that wants to lay out differently
  depending on what the target can draw.
- **The macro-list encoding is opaque** — `SK_RECORD_TYPES` is load-bearing for
  the enum, the structs, `visit`, `mutate` and the `Draw` visitor at once.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                             | Trade-off                                                                    |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Split `SkCanvas` (transform/clip) from `SkDevice` (pixels)       | One clip/matrix implementation shared by every backend; proxies are cheap             | The real backend contract is private and undocumented as API                 |
| Ten pure-virtual device draws; everything else defaults          | A new backend is small and correct before it is fast                                  | Silent performance cliffs — a device can be "complete" and slow              |
| `SkCanvasVirtualEnforcer` re-declares hooks as pure virtual      | Turns "did you handle the new op" into a compile error for opt-in subclasses          | Must be hand-maintained in lockstep with `SkCanvas`                          |
| One struct per op in a heterogeneous arena, tag stored beside it | Exact-size payloads, variable-length data, dense index array                          | Requires macro machinery in C++; ops are not copyable values                 |
| Payloads copied or refcounted into the record                    | A picture is immutable, thread-safe and outlives its recorder                         | A copy or atomic bump per op, even for a picture played once                 |
| Cull rect is a caller-supplied hint, never derived               | Bounds are cheap to declare and expensive to discover; the surface knows its own size | An offscreen consumer sizing to content must measure it itself               |
| Appearance resolved into `SkPaint`; role carried by op identity  | The stream stays one representation; roles do not multiply fields                     | Re-resolving consumers need a decorator canvas, i.e. a whole extra traversal |
| Semantic ops (`DrawShadowRec`, `DrawAnnotation`) with defaults   | A backend that can do better may; one that cannot is not burdened                     | Two ops in 42 are a different kind of thing, which is easy to miss           |

## Bearing on the proposal

1. **Adopt the floor / lowering / refusal ladder as a _declaration_.** This is
   the concrete mechanism [F5](./comparison.md) asks for, and it needs no
   capability enum. Two rungs are in place: `isCanvas!T` states a floor, and the
   interpreter carries a lowering for each of the four optional primitives —
   `ruleEndpoints` plus a cell-aligned `line` for `rule`, `paintScrollbarCells`
   for `scrollbar`, and nothing at all for the clip pair, because the display
   list has culled hidden subtrees before a backend sees it. What Skia has and
   the seam does not is a place a backend author can _read_ them: the lowerings
   are selected by `__traits(compiles, …)` at each interpreter call site rather
   than declared beside the concept — friction §2 — and a backend that
   implements a primitive has no way to hand one call back the way
   `drawBlurredRRect` returns `false`.
2. **Take `kTags`; leave the arena.** `DrawOp` is the sum of per-kind structs
   `SK_RECORD_TYPES` is emulating: eight arms, `match!` for dispatch,
   exhaustiveness from the language, `Scrollbar`'s fourteen fields confined to
   the one arm that paints a scrollbar. The arena refinement does not transfer.
   Variable stride buys nothing once the widest payload — `TextRun` — fits
   inside `static assert(DrawOp.sizeof <= 64)`, and it costs `RecordingCanvas`
   the pairwise-comparable value semantics the friction log lists among the
   things that work. `kTags` is the part with no equivalent: a pass that wants
   "every op that carries text" or "every op that carries a `Slot`" has to
   enumerate arms, where a UDA per payload struct read with `__traits` gives
   Skia's property-selection without touching the encoding.
3. **Skia is the extreme point of [F7](./comparison.md), and worth stating as
   one.** F7 splits extent into three questions — surface, layout and ink — and
   finds most subjects answering at least one of them from the scene. Skia
   answers none of them that way: it computes a conservative per-op bound to
   fill its `SkBBoxHierarchy`, keeps it private, and exposes only the rect the
   caller declared. `sparkles:ui` sits at the same point by omission rather than
   by decision — `CmdBuffer` reports `length` and `measure` and nothing about
   extent, so a backend allocating its own surface folds `op.rect` itself
   (friction §8). `finishRecordingAsPictureWithCull` is the shape of the fix
   that keeps Skia's discipline: measure, then _declare_, as a step distinct
   from recording.
4. **Confirms [F1](./comparison.md), from inside our own dependency.** Skia puts
   measurement on `SkFont` and shaping further out still, in `skshaper` and
   `skparagraph`. `sparkles_skia_font_measure_utf8` is in-tree and reachable;
   `SkiaCanvas.measure` answers `cellsOf(text)` regardless, because the seam's
   fifth method is denominated in cells (friction §1). That is a vocabulary
   decision of ours, not a limit of the library underneath.
5. **Refines [F4](./comparison.md): semantic ops are legitimate _when the
   framework ships the default lowering_.** F4's axis is where the lowering
   lives, and Skia's lives in the framework — `SkDevice::drawArc` and
   `drawShadow` are virtuals with working bodies, so a backend overrides for
   speed and never for correctness. `sparkles:ui` puts its lowerings in the same
   place; the difference is visibility, not location. Skia's default is a method
   on the type a backend author subclasses, ours is a `static if` branch inside
   `interp/immediate.d` — which is why item 1 asks for a declaration rather than
   a relocation.
6. **Answer friction §6 with a decorator canvas.** The HTML interpreter's need
   for `slot` is `SkPaintFilterCanvas`'s use case exactly. Carrying the resolved
   half alone and letting a re-resolving backend wrap costs one template layer,
   against a `Slot` stored on six of the eight payloads.
7. **Confirms [F8](./comparison.md) at the limit — and locates the real
   difference.** F8 finds no subject borrowing a payload across a frame, and
   Skia is the strongest witness for it: a copy or an atomic bump per op, in the
   most performance-obsessed 2-D library in existence. The seam is on the same
   side of that line, since `CmdBuffer.textRun` copies into a frame arena. What
   separates the two is how long the arena lives: `sk_sp<const SkTextBlob>`
   outlives its recorder, while a `DrawOp` is valid only while the buffer that
   built it is alive and unreset. `UI-O4` holds that question open.
8. **`SkTextBlob` is the shape of a `textRun` payload that survives the frame.**
   Immutable, refcounted, pre-shaped, with its own `bounds()` and `uniqueID()`
   for caching. That is the thing to build if `sparkles:ui` ever records on one
   thread and submits on another — which M7/T5 does next.

## Sources

- Public seam: [`SkPicture.h`][picture] (`cullRect()` as a hint, `playback`,
  `approximateOpCount`), [`SkPictureRecorder.h`][recorder]
  (`beginRecording(bounds, bbh)`, `finishRecordingAsPictureWithCull`),
  [`SkCanvas.h`][canvas] (33 public draws, 26 `onDraw*` virtuals,
  `getBaseLayerSize`, `quickReject`), [`SkCanvasVirtualEnforcer.h`][enforcer],
  [`SkSurfaceProps.h`][props], [`SkAnnotation.h`][annotation],
  [`SkBBHFactory.h`][bbh].
- Payload and measurement: [`SkTextBlob.h`][textblob] (immutable pre-shaped
  runs), [`SkFont.h`][font] (`measureText`, `getWidthsBounds`, `getMetrics`).
- Interception by composition: [`SkNWayCanvas.h`][nway],
  [`SkPaintFilterCanvas.h`][paintfilter], [`SkNoDrawCanvas.h`][nodraw].
- The reified stream: [`SkRecord.h`][record], [`SkRecords.h`][records] (42 op
  structs, `SK_RECORD_TYPES`, `kTags`), [`SkRecordDraw.h`][recorddraw] and
  [`SkRecordDraw.cpp`][filldraw] (the exhaustive `Draw` visitor,
  `SkRecordFillBounds`), [`SkRecordOpts.h`][recordopts],
  [`SkBigPicture.h`][bigpicture] (`fCullRect`).
- The backend port: [`SkDevice.h`][device] and [`SkDevice.cpp`][devicecpp] (ten
  pure virtuals, the default lowerings), [`SkDrawShadowInfo.h`][shadow].
- The seam under study: [`libs/ui/src/sparkles/ui/canvas.d`][canvas-d] and
  [`canvas-seam-friction.md`][friction].

Revision pinned by `git -C <clone> rev-parse HEAD` against a clone of
[`google/skia`][rev]; every cited path verified at that SHA with
`git cat-file -e`.

<!-- References -->

[rev]: https://github.com/google/skia/tree/3ad790ab4d6d596efae0d70e4b8bf7d339121984
[site]: https://skia.org/
[license]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/LICENSE
[picture]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkPicture.h
[recorder]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkPictureRecorder.h
[canvas]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkCanvas.h
[enforcer]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkCanvasVirtualEnforcer.h
[props]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkSurfaceProps.h
[textblob]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkTextBlob.h
[font]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkFont.h
[bbh]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkBBHFactory.h
[annotation]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkAnnotation.h
[nway]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/utils/SkNWayCanvas.h
[paintfilter]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/utils/SkPaintFilterCanvas.h
[nodraw]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/utils/SkNoDrawCanvas.h
[record]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRecord.h
[records]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRecords.h
[recorddraw]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRecordDraw.h
[filldraw]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRecordDraw.cpp
[recordopts]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRecordOpts.h
[bigpicture]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkBigPicture.h
[device]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkDevice.h
[devicecpp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkDevice.cpp
[shadow]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkDrawShadowInfo.h
[canvas-d]: ../../../libs/ui/src/sparkles/ui/canvas.d
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
