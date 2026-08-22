# Slint — one `ItemRenderer` from an MCU to Skia

**Category:** spans the range. **Last reviewed:** August 22, 2026.
Pinned at [`12d762c5`][rev].

The closest peer to `sparkles:ui`'s problem in the survey. Slint targets
microcontrollers with a software renderer and desktops with Skia or femtovg,
behind a single [`ItemRenderer`][renderer] trait — so it has already had to
decide everything [`canvas-seam-friction.md`](../../specs/ui-skia/canvas-seam-friction.md)
raises, under a wider spread of targets than ours.

## Q1 — measurement units, and who answers

**The finding that matters most in this survey: Slint does not put text
measurement on the renderer at all.** `ItemRenderer` has no `measure`. Sizing
lives in a separate font/shaping layer ([`textlayout.rs`][textlayout]), reached
through its own traits:

```rust
pub trait AbstractFont { type Length: /* numeric ops */; }

pub trait TextShaper {
    type Length;
    fn shape_text<GlyphStorage>(&self, text: &str, glyphs: &mut GlyphStorage);
}

pub fn text_size(&self, text: &str, max_width: Option<Font::Length>,
                 text_wrap: TextWrap, max_lines: Option<usize>)
    -> (Font::Length, Font::Length)
```

Two things follow. Measurement returns **`Font::Length`, an associated type**,
so the unit is the implementation's own rather than the framework's. And
different backends **may legitimately disagree** about the size of the same
string — that is the design, not a defect to be papered over.

There is no monospace assumption in production code; every `Glyph<Length>`
carries its own `advance`. The 10-pixel-wide test font is a fixture.

This is the direct answer to friction §1. Our `measure` is on the canvas and
returns cells, so a backend with real shaping must discard it. Slint's split
lets a shaping backend answer in its own unit and a fixed-cell backend answer
in cells, without either lying — because the thing being abstracted is the
_font_, not the _painter_.

## Q3 — semantic operations, deliberately

Slint's renderer is **more** semantic than ours, not less:

`draw_rectangle`, `draw_border_rectangle`, `draw_window_background`,
`draw_image`, `draw_text`, `draw_text_input`, `draw_path`, `draw_box_shadow`.

A backend is told "this is a text input" and "this is a box shadow", not "fill
these rects". That is evidence **against** friction §3's instinct that
`scrollbar` in the drawing seam is a layering violation. Slint bets the other
way, and for the same reason we did: a target that cannot render a real box
shadow needs to know a shadow was intended in order to degrade it sensibly.

The disagreement to resolve is therefore not "semantic or primitive" but _how
many_ semantic operations a seam can carry before a new backend becomes
prohibitive — Slint answers with eight, we have eight, and ours is the one that
feels wrong. That suggests the problem is `DrawOp`'s shape (§4), not the
presence of semantics.

## Q2 — capability declaration

Slint has **no explicit capability declaration**, and covers the same ground
two other ways:

- **Default trait methods.** `visit_opacity` defaults to applying opacity and
  continuing; `visit_layer` is documented "Not supported" and continues without
  enforcing. A backend overrides what it can do better.
- **A feature-gated optional trait.** `LayerRenderer` exists only under `std`,
  so layer support is opt-in at the type level rather than probed.

So Slint sits where we do — the contract is the trait plus its defaults, and
what a backend actually supports is not queryable. It does not vindicate our
`__traits(compiles)` probing so much as show that a mature project has not
solved this either, which lowers the expected value of inventing something
elaborate here.

## Q5 — sub-unit placement

Not a problem Slint has, because its coordinates are **already continuous**:
`LogicalRect`/`LogicalLength` are floats, and the backend applies
`scale_factor()`. Corner radius rides along as `LogicalBorderRadius` in
`combine_clip(rect, radius)`.

The lesson for friction §5 is that `RuleEdge` is a symptom of integer cell
coordinates, not of a missing enumerator. A toolkit whose geometry is
continuous never needs to name an edge.

## Q6 — resolved or semantic styling

**Resolved**, with the role carried by the method name rather than by a field.
Parameters are computed values — `Brush`, `LogicalLength` — and geometry
arrives final; `BorderRectLayout` pre-computes stroke geometry.

So Slint pays for one, not both. We carry `visual` _and_ `slot` on every op
(§6) because the HTML backend re-resolves; Slint has no such backend and does
not pay for it.

## Q7 — payload ownership

Borrowed for the duration of the call: `Pin<&dyn RenderText>`,
`Pin<&dyn RenderImage>`. Strings are `SharedString` (reference-counted), so a
backend that needs to retain one can.

The technique worth stealing is `draw_cached_pixmap(item_cache, update_fn)`:
the **backend owns a cache**, keyed by item, and is handed a callback to
populate it on demand. Ownership of expensive payloads sits with the party that
knows their lifetime, instead of the display list carrying borrowed slices that
must outlive the frame.

## Q4, Q8 — not answered here

**Q4 (command shape):** does not arise. Slint dispatches through trait methods
rather than reifying a command stream, so there is no tagged union to get
wrong. That is itself an answer: our `DrawOp` exists because we wanted a
recordable, comparable stream (`RecordingCanvas`, the op-stream parity harness),
and Slint pays no such cost because it does not want that.

**Q8 (extent query):** not found in this pass. `get_current_clip()` returns
accumulated clip bounds, which is related but is not "how big is the scene".

## Bearing on the proposal

1. **Split measurement off the canvas** into a font/shaping abstraction with a
   backend-chosen unit. This is the single strongest transferable result.
2. **Semantic draw operations are not the error.** Reconsider §3 before acting
   on it.
3. **Continuous coordinates dissolve §5.** Whether `sparkles:ui` can afford
   them is a separate question — its layout is cell-based on purpose.
4. **Backend-owned caches** are a credible answer to §7 that does not require
   interning everything.

[rev]: https://github.com/slint-ui/slint/tree/12d762c53b6d2022145dcb0cbf58eb91e31d76b9
[renderer]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/internal/core/item_rendering.rs
[textlayout]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/internal/core/textlayout.rs
