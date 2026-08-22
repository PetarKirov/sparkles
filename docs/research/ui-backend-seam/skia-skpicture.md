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
what a "cell" is. That makes Skia the fifth consecutive subject to put
measurement somewhere other than the painter, and the first one in the survey
where _our own binding already does it that way_: `sparkles:skia`'s C shim
exposes `sparkles_skia_font_measure_utf8` on `SkFont*`, while
[`isCanvas`][canvas-d]'s `measure` still returns cells. Friction §1 is
therefore not a Skia limitation we inherited; it is a seam decision we made on
top of a library that had already made the other one.

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
> This is the shape [F4](./comparison.md#f4-optional-capabilities-need-a-stated-floor-and-a-refusable-degrade)
> asked for, achieved with **no capability enum and no query at all** — no
> `hasFeature`, no `PaintEngineFeature` bitmask. Qt declares capability as
> data; Skia encodes the identical distinction in three C++ constructs the
> compiler already checks. `sparkles:ui` has the same three constructs available
> (`static assert` for the floor, a `static if` default in a mixin or free
> function for the lowering, `Expected`/`bool` for refusal) without inventing a
> vocabulary.

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
That is `scrollbar` in `DrawOp`, judged by Skia's criterion, minus the default
lowering — which `sparkles:ui` also has (`scrollbarThumb`, `scrollbarCell`) but
does not _apply_ on the backend's behalf.

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
   allocation rather than pointing at a caller's slice.
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
> `switch` from drifting; in D a `SumType` over a `struct` per kind gets the
> same guarantee from the language, and `kTags` becomes a UDA or an `enum`
> member the visitor reads with `__traits`. Skia is spending a macro to buy
> what a D sum type is.

## Q5 — sub-unit placement

Does not arise: `SkScalar` is float throughout, and the device transform is an
`SkM44`. A hairline is `SkPaint::setStrokeWidth(0)` — a documented special
case meaning "thinnest line the device can draw", which is _exactly_ the
"name a fidelity, not a position" answer
[F5](./comparison.md)
extracted from Notcurses, arrived at independently in a continuous-coordinate
system. `RuleEdge`'s six enumerators have no counterpart because a caller who
wants a band two pixels below the top edge simply writes the rect.

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

That is a real alternative to friction §6's hedge: **carry one representation
and put the other in a decorator canvas**. It costs a virtual call per op — but
`sparkles:ui` is already structurally typed, so the D equivalent is a
`FilteringCanvas!(Inner, hook)` template with the call inlined.

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

Friction §7 — `DrawOp.text` as a borrowed slice that cannot outlive the frame —
has no analogue anywhere in `SkRecord`. Skia pays a copy or a refcount bump on
every single op to avoid it, in the most performance-obsessed 2-D library in
existence.

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
rect, not used to discover it ([`SkRecordDraw.cpp`][filldraw]):

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

1. **Adopt the floor / lowering / refusal ladder verbatim.** This is the
   concrete mechanism [F4](./comparison.md#f4-optional-capabilities-need-a-stated-floor-and-a-refusable-degrade)
   asked for and it needs no capability enum: make `isCanvas` assert only the
   floor (`fillRect`, `textRun`, `glyph`, `line`); ship the eight-kind
   interpreter's `rule`/`scrollbar`/clip handling as **framework lowerings** a
   backend may override; and give a backend a way to _refuse_ by returning
   `false`. Friction §2 dissolves — the concept states the floor, and the
   lowering table states the rest.
2. **`DrawOp` should be a sum type of per-kind structs, plus tags.** Friction §4
   is confirmed; Skia adds two refinements over egui's flat `enum Shape`: an
   **arena** so a kind may carry variable-length payload, and **`kTags` on each
   kind** so passes select by property. Our scrollbar's eight fields go into a
   `Scrollbar` struct nobody else pays for.
3. **Contradicts the premise, and complicates
   [F7](./comparison.md#f7-extent-belongs-to-the-surface-not-the-scene): Q8 is
   not merely unanswered, it is _declined_.** Skia computes per-op bounds and
   keeps them private, exposing only the rect the caller declared. F7's
   conclusion — extent belongs to the surface — is strengthened by the strongest
   possible witness. The narrow remaining gap (an offscreen consumer sizing to
   content) is what `finishRecordingAsPictureWithCull` addresses: measure, then
   _declare_, as a distinct step from recording.
4. **Complicates [F1](./comparison.md) only by making it embarrassing.** The unanimity is now five of five,
   and the fifth is the library we already link. `sparkles_skia_font_measure_utf8`
   exists in-tree; `SkiaCanvas.measure` calling `cellsOf` is a choice our seam
   forces, not one Skia imposes.
5. **Refines [F3](./comparison.md):
   semantic ops are legitimate _when the framework ships the default lowering_.**
   Skia is in Qt's camp (degrade once, centrally) while looking like Slint's
   (semantic ops in the seam). `sparkles:ui` already owns the lowering
   (`ruleEndpoints`, `scrollbarCellCount`, `scrollbarCell`) but makes each
   backend call it. Making the lowering the default and the override the
   exception moves us into Skia's position without changing the vocabulary.
6. **Replace friction §6's double payload with a decorator canvas.** The HTML
   interpreter's need for `slot` is `SkPaintFilterCanvas`'s use case exactly.
   Carrying `Visual` alone and letting a re-resolving backend wrap costs one
   template layer, not two fields on every op.
7. **Confirms [F6](./comparison.md#f6-payload-ownership-share-it-do-not-borrow-it) at the limit.** Skia copies or refcounts every payload into the
   record; `sk_sp<const SkTextBlob>` is the shaped-text analogue of the interned
   payload friction §7 wants. If Skia will pay that per op, `DrawOp.text` as a
   borrowed slice is not a performance decision worth defending.
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
