# Cairo and Direct2D — the device abstraction that had to grow a command stream

**Category:** device abstraction. **Last reviewed:** August 23, 2026.
Cairo pinned at [`bd04e43e`][cairo-rev]; Direct2D/DirectWrite have no public
source, so they are pinned to their documentation repositories —
[`MicrosoftDocs/sdk-api@4502fff1`][sdkapi-rev] and
[`MicrosoftDocs/win32@47e64c18`][win32-rev].

The previous generation's answer to "one drawing API, many devices", read for
where it leaks. The shared result: both built a virtual-device seam, and both
ended up routing their hardest device — the printer, and vector output
generally — through a **reified, replayable command stream** rather than
through that seam.

|                     | Cairo                                                                 | Direct2D + DirectWrite                                                  |
| ------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Language            | C                                                                     | C++ / COM                                                               |
| License             | LGPL-2.1 or MPL-1.1 (dual)                                            | proprietary (Windows SDK)                                               |
| Repository          | [gitlab.freedesktop.org/cairo/cairo][cairo-repo]                      | not published                                                           |
| Documentation       | [cairographics.org][cairo-docs]                                       | [Direct2D on Microsoft Learn][d2d-portal]                               |
| Pinned revision     | `bd04e43e201ef9beddcacdf379b610a0e199112e` (master, 2026-07-11)       | docs repos, SHAs above                                                  |
| Latest release read | 1.18.4 (2025-03-08), per [`NEWS`][cairo-news]                         | `d2d1_1.h` era (Windows 8 / Platform Update for Windows 7)              |
| The seam            | `cairo_surface_backend_t` — a 30-slot vtable, **private header**      | `ID2D1RenderTarget` / `ID2D1DeviceContext` — COM, **not implementable** |
| Backends shipped    | image, PDF, PS, SVG, Xlib, XCB, Quartz, Win32, script, recording, tee | vendor-internal (D3D, WARP software, GDI-compat)                        |
| Replay seam         | `cairo_recording_surface_t` + `cairo_surface_t` replay targets        | `ID2D1CommandList` + `ID2D1CommandSink`                                 |

## Overview

### What it solves

Both let an application draw once and land the result on a screen, an
offscreen bitmap, or a printed page. Direct2D's printing docs state the goal
without hedging:

> All print-specific details are hidden from Direct2D apps, which means
> Direct2D apps can print without knowing what devices they are drawing to, or
> how the drawings are translated to printing.
>
> — [`printing-and-command-lists.md`][d2d-printing]

Cairo makes the same promise through `cairo_t`: `cairo_paint`, `cairo_fill`,
`cairo_stroke` and `cairo_show_text_glyphs` are identical whatever
`cairo_surface_t` sits underneath.

### Design philosophy

Both seams are **closed**. Cairo's `cairo_surface_backend_t` is declared in
[`cairo-surface-backend-private.h`][cairo-backend-h] and the installed header
set in [`src/meson.build`][cairo-meson] is exactly `cairo.h`,
`cairo-version.h` and `cairo-deprecated.h` — a third party cannot implement a
surface, only pick one from the closed `cairo_surface_type_t` enum. Direct2D
goes further: no interface in the drawing path is documented as
application-implementable. The only seam Microsoft opens is the **playback**
one, `ID2D1CommandSink`, and its documentation says so plainly:

> The command sink is implemented by you for an application when you want to
> receive a playback of the commands recorded in a command list. A typical
> usage will be for transforming the command list into another format such as
> XPS…
>
> — [`nn-d2d1_1-id2d1commandsink.md`][d2d-sink]

> [!IMPORTANT]
> That closure is the precondition for everything else here. A 30-slot vtable
> and a fat COM interface are affordable because the vendor writes every
> implementation. `sparkles:ui` is in the same position — three in-tree
> backends, no third-party ones — which means the friction log's implicit cost
> model ("a backend author must learn the surface") is a cost we choose to
> pay, not one the design imposes.

## How it works

Cairo's seam is a plain struct of function pointers. Absence is `NULL`;
the dispatcher checks and falls back.

```c
struct _cairo_surface_backend {
    cairo_surface_type_t type;
    /* … lifecycle, similar-surface and image-mapping slots … */
    cairo_bool_t (*get_extents)     (void *surface, cairo_rectangle_int_t *extents);
    void         (*get_font_options)(void *surface, cairo_font_options_t  *options);
    /* the five drawing operations, each able to decline */
    cairo_warn cairo_int_status_t (*paint) (…);
    cairo_warn cairo_int_status_t (*mask)  (…);
    cairo_warn cairo_int_status_t (*stroke)(…);
    cairo_warn cairo_int_status_t (*fill)  (…);
    cairo_warn cairo_int_status_t (*show_glyphs) (…);
    cairo_bool_t (*has_show_text_glyphs) (void *surface);
    cairo_warn cairo_int_status_t (*show_text_glyphs) (…);
    cairo_bool_t (*supports_color_glyph) (…);
    cairo_warn cairo_int_status_t (*tag) (void *surface, cairo_bool_t begin,
                                          const char *tag_name, const char *attributes);
};
```

Every backend spells the whole table out positionally, `NULL`s included and
commented — the SVG surface's entry is literally
`_cairo_svg_surface_show_glyphs, NULL, /* has_show_text_glyphs */ NULL, /* show_text_glyphs */`
([`cairo-svg-surface.c`][cairo-svg]), so one backend file states the full
contract _and_ that backend's refusals in one place.

Below it sits a second, internal seam that does the real degradation:
`cairo_compositor_t`, a **linked chain**. Each compositor has a `delegate`, and
both a `NULL` slot and a returned `CAIRO_INT_STATUS_UNSUPPORTED` advance down it:

```c
do {
    while (compositor->paint == NULL)
        compositor = compositor->delegate;

    status = compositor->paint (compositor, &extents);

    compositor = compositor->delegate;
} while (status == CAIRO_INT_STATUS_UNSUPPORTED);
```

— [`cairo-compositor.c`][cairo-compositor-c]. The chain runs from
hardware-specific (`cairo-xlib-render-compositor.c`) through spans and traps to
`cairo-fallback-compositor.c`: fidelity is a **ladder walked at run time, per
operation**, not a static capability set.

Direct2D has no equivalent open ladder, having no third-party devices. Its
interesting structure is the 1.1 split — `ID2D1DeviceContext` inherits
`ID2D1RenderTarget` and adds one thing the older interface lacks, a choice of
what it draws _into_:

> Represents a set of state and command buffers that are used to render to a
> target. The device context can render to a target bitmap or a command list.
>
> — [`nn-d2d1_1-id2d1devicecontext.md`][d2d-dc]

```cpp
pD2D1DeviceContext->SetTarget(pCommandList1);   // record, resolution-independent
pD2D1DeviceContext->BeginDraw();
RenderMyVectorContent(pD2D1DeviceContext);
pD2D1DeviceContext->EndDraw();

pD2D1DeviceContext->SetTarget(pBitmap2);        // …then replay into a raster target
pD2D1DeviceContext->BeginDraw();
pD2D1DeviceContext->DrawImage(pCommandList1);
pD2D1DeviceContext->EndDraw();
```

— [`nn-d2d1_1-id2d1commandlist.md`][d2d-cl]. Cairo's `cairo_recording_surface_t`
is the same idea reached from the other side: recording is _a surface type_,
so it needs no new API at all.

## Q1 — measurement units, and who answers

**Neither library measures on the painter.** Cairo measures on
`cairo_scaled_font_t`: [`cairo_scaled_font_text_extents`][cairo-text-extents]
and `cairo_scaled_font_glyph_extents` fill a `cairo_text_extents_t` in user
space. Direct2D does not measure at all — DirectWrite does, and
`DWRITE_TEXT_METRICS` is documented "All coordinates are in device independent
pixels (DIPs)" ([`ns-dwrite-dwrite_text_metrics.md`][dwrite-metrics]). That
confirms [F1](./comparison.md) on two more subjects.

Two results go beyond F1.

**A single `Size` is the wrong return type, independently of the unit.** Cairo's
`cairo_text_extents_t` separates the inked rectangle from `x_advance`/`y_advance`,
and documents that "whitespace characters do not directly contribute to the
size of the rectangle … though they will affect the `x_advance`".
`DWRITE_TEXT_METRICS` carries `width` _and_
`widthIncludingTrailingWhitespace` for the same reason. `isCanvas`'s
`Size measure(text)` cannot express the distinction in any unit, so
[friction §1](../../specs/ui-skia/canvas-seam-friction.md) understates the
problem: it is not only that `SkiaCanvas` must answer in cells, it is that
there is no shape for the answer.

**The device does reach measurement — as options flowing the other way.** The
backend slot `get_font_options` lets a surface state how it wants text
resolved, and `CAIRO_HINT_METRICS_ON` means "quantizing them so that they are
integer values in device space" ([`cairo.h`][cairo-hint-metrics]). A character
grid is that setting taken to its limit. So the seam between painter and font
layer is a **one-way options channel**, not a measurement call — which is
exactly the shape `sparkles:ui` needs and does not have.

DirectWrite adds the mirror image. `IDWriteTextRenderer` — the app-implemented
text backend — inherits `IDWritePixelSnapping`, whose `GetPixelsPerDip` lets
the _renderer tell the text layer_ its grid
([`nn-dwrite-idwritepixelsnapping.md`][dwrite-snapping]). And the regime itself
is a named value: `DWRITE_MEASURING_MODE` is `NATURAL`, `GDI_CLASSIC` or
`GDI_NATURAL` ([`ne-dcommon-dwrite_measuring_mode.md`][dwrite-measuring]).
`sparkles:ui` has exactly one regime — cells — and no name for it.

## Q2 — is the contract stated in one place?

Cairo states it **three times, at three different binding times**, and this is
the survey's most detailed answer to
[friction §2](../../specs/ui-skia/canvas-seam-friction.md):

1. **Structurally** — a `NULL` vtable slot. `_cairo_surface_get_extents` reads
   `if (surface->backend->get_extents != NULL)`; the analysis surface reads
   `if (surface->target->backend->paint == NULL) backend_status = CAIRO_INT_STATUS_UNSUPPORTED;`
   ([`cairo-analysis-surface.c`][cairo-analysis-c]).
2. **By predicate** — `has_show_text_glyphs`, `supports_color_glyph`. The
   public `cairo_surface_has_show_text_glyphs` exists for a specific caller
   benefit: "Users can use this function to avoid computing UTF-8 text and
   cluster mapping if the target surface does not use it"
   ([`cairo-surface.c`][cairo-surface-c]).
3. **Per call, per operation** — a returned `CAIRO_INT_STATUS_UNSUPPORTED`,
   which the caller resolves by trying the next thing. `_cairo_surface_show_text_glyphs`
   tries `show_text_glyphs`, and on `UNSUPPORTED` re-tries `show_glyphs`; the
   compositor chain loops on the same status.

Level 3 is the one no surveyed subject had before. Qt's `PaintEngineFeature`
is a static bitmask; Cairo's capability is a **function of the actual
operation and its arguments**. Paginated surfaces exploit this: each page is
replayed twice, once in `CAIRO_PAGINATED_MODE_ANALYZE` where "the drawing
functions simply need to return `CAIRO_STATUS_SUCCESS` or
`CAIRO_INT_STATUS_UNSUPPORTED` to indicate whether rendering would be
supported" ([`cairo-paginated-private.h`][cairo-paginated-h]). The framework
then partitions the page into a natively-emitted region and an image-fallback
region — `has_supported` / `has_unsupported`, `supported_region` /
`fallback_region` in `cairo_analysis_surface_t`.

Direct2D is the opposite pole. `ID2D1RenderTarget::IsSupported` sounds like a
capability query and is not one: it takes a `D2D1_RENDER_TARGET_PROPERTIES`
and answers about pixel format, hardware-vs-software type and
`D2D1_FEATURE_LEVEL` ("The video card must support DirectX 9" / "DirectX 10")
— never about a drawing primitive ([`nf-…-issupported`][d2d-issupported],
[`ne-d2d1-d2d1_feature_level.md`][d2d-featurelevel]). There is no primitive to
negotiate because the framework guarantees a software path. Direct2D does not
even report _errors_ per call: "Render target drawing commands do not indicate
whether the requested operation was successful. To find out whether there are
drawing errors, call … `Flush` … or `EndDraw`" ([`render-targets-overview.md`][d2d-rt]).

## Q3 — semantic operations, or primitives

Both draw with **primitives** — five in Cairo (`paint`, `mask`, `stroke`,
`fill`, glyphs), shapes and geometries in Direct2D — and neither puts a widget
concept in the drawing vocabulary. That looks like support for friction §3
until you look at how semantics _do_ travel.

Cairo carries them in a **separate bracketing channel**: `tag` is its own
vtable slot, its own recorded command kind (`CAIRO_COMMAND_TAG`), and its own
public API, `cairo_tag_begin(cr, tag_name, attributes)` with a stringly-typed
attribute payload — "The attributes string is of the form
`key1=value2 key2=value2 ...`" ([`cairo.c`][cairo-c]) — over well-known names
`CAIRO_TAG_DEST`, `CAIRO_TAG_LINK`, `CAIRO_TAG_CONTENT` ([`cairo.h`][cairo-tags]).
A backend that does not implement `tag` ignores it and still paints correctly.

DirectWrite carries them **as ops with resolved geometry plus provenance**.
`IDWriteTextRenderer` receives `DrawGlyphRun`, `DrawUnderline`,
`DrawStrikethrough` and `DrawInlineObject` — an underline is not a rectangle
the app must recognise. `DWRITE_UNDERLINE` ships `width`, `thickness`,
`offset`, `runHeight`, `readingDirection`, `flowDirection`, `localeName` (so a
vertical-text renderer can put the line on the correct side) and
`measuringMode`, whose documented purpose is degradation: "useful to the
renderer to determine how underlines are rendered, such as rounding the
thickness to a whole pixel in GDI-compatible modes"
([`ns-dwrite-dwrite_underline.md`][dwrite-underline]).

## Q4 — command shape

Cairo's recording surface reifies, and it reifies as a **tagged union**:

```c
typedef struct _cairo_command_header {
    cairo_command_type_t type;
    cairo_operator_t     op;
    cairo_rectangle_int_t extents;
    cairo_clip_t         *clip;
    int index;
    struct _cairo_command_header *chain;
} cairo_command_header_t;

typedef union _cairo_command {
    cairo_command_header_t           header;
    cairo_command_paint_t            paint;
    cairo_command_mask_t             mask;
    cairo_command_stroke_t           stroke;
    cairo_command_fill_t             fill;
    cairo_command_show_text_glyphs_t show_text_glyphs;
    cairo_command_tag_t              tag;
} cairo_command_t;
```

— [`cairo-recording-surface-private.h`][cairo-rec-h]. Six kinds; each payload
struct embeds the header and adds only its own live fields. `stroke` carries
`cairo_stroke_style_t` and two matrices; `fill` does not. This is a C
implementation of exactly what [F2](./comparison.md) recommends, confirmed from
a second, independent direction: egui reached the sum type through a Rust
`enum`, Cairo reached it by hand in a language that has none.

The header is the part worth stealing. It is the fields that are live for
_every_ kind — operator, clip, and a per-command `extents` — which is what
makes the recording surface's `bbtree` spatial index and its replay culling
possible without re-deriving geometry.

Direct2D's `ID2D1CommandList` is deliberately opaque: the recorded stream has
no public value type and is read only by streaming it to an
`ID2D1CommandSink`, where "Not all methods implemented by `ID2D1DeviceContext`
are present" ([`nn-d2d1_1-id2d1commandsink.md`][d2d-sink]). So recording also
**normalises** — the replay vocabulary is a narrowed subset of the drawing
vocabulary. `sparkles:ui`'s `DrawOp` set and `isCanvas` set are the same set,
and Direct2D suggests they need not be.

## Q5 — sub-unit placement

Neither has the problem, for the usual reason: coordinates are continuous
(`double` user space in Cairo, `FLOAT` DIPs in Direct2D), with a device
transform applied underneath. That is a third and fourth confirmation of
[F5](./comparison.md).

Two mechanisms remain transferable to a toolkit whose unit is coarse.
**`cairo_surface_set_device_scale`** is a hidden per-surface multiplier so
"code that assumes 1 pixel will be a certain size will still work", deliberately
not expressible as a CTM change "since functions like `cairo_device_to_user()`
would expose the hidden scale" ([`cairo-surface.c`][cairo-devscale]) — the unit
conversion lives on the surface, invisible to drawing code. **`D2D1_UNIT_MODE`**
lets a device context switch between `D2D1_UNIT_MODE_DIPS` and
`D2D1_UNIT_MODE_PIXELS` at run time, with DPI still consulted "to determine the
threshold for enabling vertical antialiasing for text"
([`ne-d2d1_1-d2d1_unit_mode.md`][d2d-unitmode]): the unit is a _mode_, not a
compile-time property of the vocabulary. `sparkles:ui` has `RuleEdge` but
neither — no declared scale, no named unit mode.

## Q6 — resolved appearance, semantic role, or both

Resolved, and only resolved. A drawing op carries a `cairo_pattern_t` or an
`ID2D1Brush` and **no semantic role field**. The role travels separately — in a
bracket around the ops (Cairo's `tag`, see Q3 above)
or in the method name plus a metadata-bearing struct (`DWRITE_UNDERLINE`'s
`localeName` and `measuringMode`). Neither subject pays for `visual` _and_
`slot` on every op, and Cairo's arrangement is the one that would serve
`sparkles:ui`'s re-resolving HTML interpreter: a tag bracket is emitted once per
styled region rather than per primitive, and a pixel backend that leaves the
`tag` slot `NULL` ignores it at no cost.

## Q7 — payload ownership

The strongest answers in the survey so far, and both reject borrowing.

Cairo's recording surface **copies data and snapshots resources**.
`_cairo_recording_surface_show_text_glyphs` `memcpy`s the UTF-8, the glyph
array and the cluster array into malloc'd command storage, and takes
`cairo_scaled_font_reference (scaled_font)`; sources go through
`_cairo_pattern_init_snapshot` ([`cairo-recording-surface.c`][cairo-rec-c]).
A recorded command owns everything it needs and can outlive both the frame and
the caller's buffers.

Direct2D publishes a **per-resource-kind ownership table** for command lists
([`nn-d2d1_1-id2d1commandlist.md`][d2d-cl]):

| Resource                     | How the command list treats it                               |
| ---------------------------- | ------------------------------------------------------------ |
| Solid-color brush            | passed by value                                              |
| Bitmap brush                 | brush by value; the bitmap it was created from is referenced |
| Gradient brush               | brush by value; the gradient stop collection is referenced   |
| Bitmaps                      | passed by reference                                          |
| Drawing state block          | converted into set-transform-style calls, passed by value    |
| Geometry, stroke style, mesh | immutable object, passed by value                            |

The rule underneath both is the same: **small immutable things by value, large
or mutable things by reference count.** And in Direct2D the payloads are
created by the render target in the first place ("Like a factory, a render
target can create drawing resources", [`render-targets-overview.md`][d2d-rt]),
so the backend owns them by construction — Slint's backend-owned cache,
generalised to every resource.

## Q8 — can a backend ask the scene its extent?

**Yes — and this is where the survey's existing synthesis is wrong.**

[F7](./comparison.md) says extent belongs to the surface, not the scene, and
that friction §8's need is narrow. Cairo has both, and names the second one after friction §8's exact use
case:

- The surface answers when it can: `get_extents` on the backend, and if the
  slot is `NULL` or returns `FALSE` the surface "is considered to be boundless
  and infinite bounds are used for it" ([`cairo-surface-backend-private.h`][cairo-backend-h]).
- The **scene** answers when the surface cannot.
  `cairo_recording_surface_ink_extents` is documented: "Measures the extents of
  the operations stored within the recording-surface. This is useful to compute
  the required size of an image surface (or equivalent) into which to replay
  the full sequence of drawing operations" ([`cairo-recording-surface.c`][cairo-ink]).

The implementation is the interesting half. `_recording_surface_get_ink_bbox`
does not read stored bounds; it creates a **null surface wrapped in an analysis
surface and replays the whole scene into it**, then reads
`_cairo_analysis_surface_get_bounding_box`. Extent is computed by replaying the
display list into a conforming backend that measures instead of painting —
which is precisely `RecordingCanvas`'s role, generalised into a measurement
service. `skia-canvas-render.d`'s hand-rolled scan over `op.rect` is the right
idea implemented in the wrong place.

Direct2D confirms it from the other side, and adds a wrinkle F7 does not
model. `ID2D1DeviceContext::GetImageLocalBounds` takes any `ID2D1Image` —
a command list included — and returns its bounds. It is a method on the
**context**, not on the image, because "They do reflect the current DPI, unit
mode, and interpolation mode of the context"
([`nf-…-getimagelocalbounds.md`][d2d-bounds]). Extent is a function of the
scene _and_ the device, so neither owning it alone is correct.

## Strengths

- **The refusal channel is per operation, not per backend.** `UNSUPPORTED` as
  a return value lets a backend accept an easy case of an operation and decline
  a hard one — something a static capability bitmask cannot express.
- **Degradation composes.** The `delegate` chain makes fallback a list, so a
  new intermediate fidelity is a link, not an `if`.
- **A `NULL` with a comment is a readable contract**: every Cairo backend file
  states its whole surface, refusals included, in declaration order.
- **Recording is a device, not a mode**, so drawing code is unchanged and the
  recorded stream is by construction what a real device would have seen.
- **Ownership is stated per resource kind**, not left to convention.
- **Semantics ride a side channel** (`tag`) an unaware backend can ignore
  without the picture being wrong.

## Weaknesses

- **The seam is private in both cases**, so neither is evidence that a wide
  seam is affordable when third parties implement it.
- **Cairo's vtable is positional**: adding a slot touches every backend, and a
  misordered `NULL` is a silent behaviour change, not a compile error.
- **The capability answer is spread over three mechanisms** that disagree about
  binding time: a `NULL` check, a predicate, and a status code.
- **The abstraction did not survive the GPU.** [`NEWS`][cairo-news] for 1.18
  records: "In a continuing effort to reduce the amount of legacy code, and
  increase the long-term maintainability of cairo, the following backends have
  been removed: - GL and GLES drawing", and `cairo.h` marks ten surface types
  deprecated in 1.18 — Glitz, BeOS, DirectFB, OS/2, Qt, VG, GL, DRM, Skia,
  Cogl. Every GPU-targeting backend Cairo ever had is gone; what remains either _is_ the
  image surface or serialises to a vector format. **That is where "one drawing
  API, many devices" leaks** — the seam was shaped by its first implementation,
  and devices that did not resemble it could not be maintained behind it.
- **Direct2D's `IsSupported` is a naming trap**: it answers about surface
  properties while reading as a feature query.

## Key design decisions and trade-offs

| Decision                                                                             | Rationale                                                                 | Trade-off                                                                    |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Backend vtable in a private header (Cairo); no implementable drawing interface (D2D) | The vendor can widen the seam freely and fix all callers at once          | No third-party devices; the seam's real cost is never tested by an outsider  |
| Capability as a per-call `UNSUPPORTED` status                                        | Support can depend on the operation's arguments, not just the device      | Every call site must handle a retry; the contract is not statically readable |
| Fallback as a `delegate` chain of compositors                                        | New fidelities are links, not branches; ordering is data                  | A failed operation may be attempted several times before it succeeds         |
| Measurement on `cairo_scaled_font_t` / DirectWrite, never on the painter             | Fonts, not painters, are what differ between targets                      | The device must influence metrics indirectly, through `get_font_options`     |
| Device influence on metrics as one-way options (`CAIRO_HINT_METRICS_ON`)             | Keeps measurement out of the painter while letting a grid device quantize | Two surfaces can legitimately measure the same string differently            |
| Recording as a surface / render target                                               | No second API; recorded stream is exactly what a device sees              | The recorder must copy or snapshot everything, since it outlives the caller  |
| Command union with a common header carrying `extents` + `clip`                       | Enables spatial indexing, culling and replay without re-deriving geometry | Every command pays for the header even when its extent is unused             |
| Semantics in a bracketing `tag` channel rather than per-op fields                    | Ops stay purely graphical; unaware backends ignore tags safely            | Tag payload is a string, so it is unchecked and un-typed                     |
| Scene extent by replay into an analysis surface                                      | Correct for unbounded scenes; needs no per-op bookkeeping at record time  | Measuring costs a full replay                                                |

## Bearing on the proposal

1. **Q8: revise F7.** Extent is not simply the surface's. Cairo ships both
   `get_extents` (surface-owned, `NULL` ⇒ unbounded) _and_
   `cairo_recording_surface_ink_extents` (scene-owned), and `GetImageLocalBounds`
   shows extent is a function of the scene **and** the device's DPI and unit
   mode. Friction §8 is a real gap, not the narrow one F7 describes.
2. **Implement that gap as a measuring backend, not as a field.** Cairo derives
   ink extents by replaying into a null surface behind an analysis surface.
   `sparkles:ui` already has the conforming backend that would do it — let
   `RecordingCanvas` (or a sibling `MeasuringCanvas`) answer `extent()`, and
   delete `skia-canvas-render.d`'s ad-hoc scan over `op.rect`.
3. **Q1: `Size measure(text)` is under-specified twice over.** Beyond F1's
   "wrong place", both subjects return the inked box _and_ the advance
   separately. Whatever replaces `measure` returns a record, not a `Size`.
4. **Q1/Q5: make the measurement regime a named value.** `DWRITE_MEASURING_MODE`
   and `D2D1_UNIT_MODE` name what `sparkles:ui` leaves implicit. A `cells` /
   `device` regime carried with the text would let a Skia backend stop lying in
   `measure` without the toolkit abandoning cell layout — the cheapest partial
   answer to friction §1 found so far.
5. **Q2: adopt the per-call refusal.** `CAIRO_INT_STATUS_UNSUPPORTED` returned
   from a primitive is strictly more expressive than a static capability set,
   it is what a golden test wants when it asks for a hairline, and it subsumes
   `__traits(compiles)` probing: a canvas that cannot clip _this_ rect can say
   so at the call. This gives F4's "refusable degrade" a mechanism.
6. **Q2: order the fallbacks as data.** The ten-line `delegate` loop in
   `cairo-compositor.c` is the whole of Cairo's degradation policy. If
   `sparkles:ui` keeps degradation in the backends (F3's first camp), a delegate
   chain is how to stop it being scattered across them.
7. **Q4: F2 confirmed from a second direction — and the header is the lesson.**
   Cairo hand-built a tagged union in a language without sum types. Copy
   `cairo_command_header_t`: fields live for _every_ op (clip, and a per-op
   extent) in a shared header, the rest in per-kind payloads. That answers §4
   and item 1 at once.
8. **Q3/Q6: stop paying for `visual` and `slot` on every op.** Neither subject
   does. Cairo's `tag` bracket is the cheaper shape for the HTML interpreter's
   re-resolution — emit `pushSlot`/`popSlot` bracket ops that pixel backends
   ignore, instead of a field on all eighteen.
9. **Q7: F6 gains a third technique — snapshot at record time.** Cairo neither
   borrows nor interns: it copies bytes and reference-counts resources at the
   moment of recording, which is exactly what would make a `DrawOp` safe to
   move to another thread (friction §7, `UI-O4`).
10. **The closed-seam caveat cuts against the friction log's framing.** Both
    subjects afford wide seams because nobody outside implements them, and
    `sparkles:ui` is in that position too. §2's complaint that a _backend
    author_ cannot learn the contract from `isCanvas` is therefore weaker than
    it looks; the real cost of the unstated contract falls on the _interpreter_,
    which re-derives it by introspection at several call sites.
11. **Read the deprecation list as a warning.** Cairo's seam outlived every GPU
    backend that tried to sit behind it. A seam whose shape is set by its first
    backend may not survive a genuinely different second one — the umbrella's
    open question, restated as an empirical result rather than a worry.

## Sources

- Cairo, pinned at [`bd04e43e201ef9beddcacdf379b610a0e199112e`][cairo-rev]
  (`master` head as reported by the GitLab API, dated 2026-07-11; verified by
  a `--depth 1` clone whose `git rev-parse HEAD` matched). Files read:
  [`cairo-surface-backend-private.h`][cairo-backend-h],
  [`cairo-surface.c`][cairo-surface-c],
  [`cairo-compositor.c`][cairo-compositor-c],
  [`cairo-compositor-private.h`][cairo-compositor-h],
  [`cairo-analysis-surface.c`][cairo-analysis-c],
  [`cairo-paginated-private.h`][cairo-paginated-h],
  [`cairo-recording-surface-private.h`][cairo-rec-h],
  [`cairo-recording-surface.c`][cairo-rec-c],
  [`cairo-scaled-font.c`][cairo-text-extents],
  [`cairo-svg-surface.c`][cairo-svg], [`cairo.h`][cairo-tags],
  [`cairo.c`][cairo-c], [`meson.build`][cairo-meson], [`NEWS`][cairo-news].
- Direct2D and DirectWrite have **no public source**. Every API claim is taken
  from the Microsoft documentation repositories at a pinned SHA rather than
  from the rendered site, so the revision is honest:
  [`MicrosoftDocs/sdk-api@4502fff176b3b56beddb6a63c9f980377b11ba9b`][sdkapi-rev]
  (branch `docs`) for `d2d1`/`d2d1_1`/`dwrite`/`dcommon` reference pages, and
  [`MicrosoftDocs/win32@47e64c189dcb1c1a42c221380ccf0ec81cc82d4b`][win32-rev]
  (branch `docs`) for the conceptual topics. The reader-facing equivalents are
  on [Microsoft Learn][d2d-portal].

> [!NOTE]
> Because the Direct2D and DirectWrite headers are not published, no claim
> here is grounded in an implementation — only in Microsoft's description of
> one. Behavioural claims about Cairo are grounded in its source.

<!-- References -->

[cairo-rev]: https://gitlab.freedesktop.org/cairo/cairo/-/tree/bd04e43e201ef9beddcacdf379b610a0e199112e
[cairo-repo]: https://gitlab.freedesktop.org/cairo/cairo
[cairo-docs]: https://www.cairographics.org/manual/
[cairo-backend-h]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-surface-backend-private.h
[cairo-surface-c]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-surface.c
[cairo-devscale]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-surface.c#L1773
[cairo-compositor-c]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-compositor.c#L61
[cairo-compositor-h]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-compositor-private.h
[cairo-analysis-c]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-analysis-surface.c
[cairo-paginated-h]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-paginated-private.h
[cairo-rec-h]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-recording-surface-private.h
[cairo-rec-c]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-recording-surface.c
[cairo-ink]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-recording-surface.c#L2603
[cairo-text-extents]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-scaled-font.c#L1521
[cairo-svg]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-svg-surface.c#L4155
[cairo-tags]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo.h#L1083
[cairo-hint-metrics]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo.h#L1396
[cairo-c]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo.c#L2922
[cairo-meson]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/meson.build#L121
[cairo-news]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/NEWS
[sdkapi-rev]: https://github.com/MicrosoftDocs/sdk-api/tree/4502fff176b3b56beddb6a63c9f980377b11ba9b
[win32-rev]: https://github.com/MicrosoftDocs/win32/tree/47e64c189dcb1c1a42c221380ccf0ec81cc82d4b
[d2d-portal]: https://learn.microsoft.com/en-us/windows/win32/direct2d/direct2d-portal
[d2d-dc]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/d2d1_1/nn-d2d1_1-id2d1devicecontext.md
[d2d-cl]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/d2d1_1/nn-d2d1_1-id2d1commandlist.md
[d2d-sink]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/d2d1_1/nn-d2d1_1-id2d1commandsink.md
[d2d-issupported]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/d2d1/nf-d2d1-id2d1rendertarget-issupported%28constd2d1_render_target_properties%29.md
[d2d-featurelevel]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/d2d1/ne-d2d1-d2d1_feature_level.md
[d2d-unitmode]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/d2d1_1/ne-d2d1_1-d2d1_unit_mode.md
[d2d-bounds]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/d2d1_1/nf-d2d1_1-id2d1devicecontext-getimagelocalbounds.md
[d2d-rt]: https://github.com/MicrosoftDocs/win32/blob/47e64c189dcb1c1a42c221380ccf0ec81cc82d4b/desktop-src/Direct2D/render-targets-overview.md
[d2d-printing]: https://github.com/MicrosoftDocs/win32/blob/47e64c189dcb1c1a42c221380ccf0ec81cc82d4b/desktop-src/Direct2D/printing-and-command-lists.md
[dwrite-metrics]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/dwrite/ns-dwrite-dwrite_text_metrics.md
[dwrite-underline]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/dwrite/ns-dwrite-dwrite_underline.md
[dwrite-snapping]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/dwrite/nn-dwrite-idwritepixelsnapping.md
[dwrite-measuring]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/dcommon/ne-dcommon-dwrite_measuring_mode.md
