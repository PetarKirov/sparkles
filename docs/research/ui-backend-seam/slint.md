# Slint — one `ItemRenderer` from an MCU to Skia

**Category:** spans the range. **Last reviewed:** August 23, 2026.
Pinned at [`12d762c5`][rev].

The closest peer to `sparkles:ui`'s problem in the survey. Slint targets
microcontrollers with a software renderer and desktops with Skia or femtovg,
behind a single [`ItemRenderer`][renderer] trait — so it has already had to
decide everything [`canvas-seam-friction.md`][friction]
raises, under a wider spread of targets than ours.

| Field                 | Value                                                                                                                           |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **Language**          | Rust, with C++, JavaScript and Python APIs ([`Cargo.toml`][cargo])                                                              |
| **License**           | Triple-licensed: `GPL-3.0-only OR LicenseRef-Slint-Royalty-free-2.0 OR LicenseRef-Slint-Software-3.0` ([`LICENSE.md`][license]) |
| **Repository**        | [`slint-ui/slint`][repo]                                                                                                        |
| **Documentation**     | [docs.slint.dev][docs], [docs.rs/i-slint-core][docsrs]                                                                          |
| **Category**          | spans the range                                                                                                                 |
| **Pinned revision**   | [`12d762c53b6d2022145dcb0cbf58eb91e31d76b9`][rev]                                                                               |
| **Target range**      | bare-metal microcontrollers → desktop GPU → WebAssembly → Android, behind one renderer trait                                    |
| **Renderers shipped** | `software` (MCU-capable), `skia`, `femtovg`, `anyrender` ([`Cargo.toml`][cargo] workspace members)                              |
| **Backends shipped**  | `winit`, `qt`, `linuxkms`, `android-activity`, `testing`, `selector` ([`Cargo.toml`][cargo])                                    |
| **The seam**          | `trait ItemRenderer` — eight semantic `draw_*` methods plus visit/clip/transform state                                          |
| **The intermediate**  | none: virtual dispatch on the trait, no reified command stream                                                                  |

## Overview

### What it solves

One declarative UI language has to produce pixels on a microcontroller with
tens of kilobytes of RAM and on a desktop GPU through Skia, without the
`.slint` source, the layout, or the item tree knowing which. Slint's answer is
to put a single trait between the item tree and every target, and to keep the
things that genuinely differ per target — font shaping, length units, layer
support — behind _other_ abstractions rather than behind that one.

### Design philosophy

The trait's own doc comment states the contract in two sentences
([`item_rendering.rs`][renderer]):

> Trait used to render each items.
>
> The item needs to be rendered relative to its (x,y) position. For example,
> draw_rectangle should draw a rectangle in `(pos.x + rect.x, pos.y + rect.y)`

The project's design goals are stated as an acronym in the [`README.md`][readme],
and two of the four bear directly on the seam:

> - **Scalable**: Slint should support responsive UI design, allow cross-platform
>   usage across operating systems and processor architectures and support
>   multiple programming languages.
> - **Lightweight**: Slint should require minimal resources, in terms of memory
>   and processing power, and yet deliver a smooth, smartphone-like user
>   experience on any device.

"Lightweight" is why there is no reified command stream (Q4), and "scalable" is
why measurement is generic over the font rather than fixed by the framework
(Q1).

## Q1 — measurement units, and who answers

**The finding that matters most in this survey: Slint does not put text
measurement on the renderer at all.** `ItemRenderer` has no `measure`. Sizing
lives in a separate font/shaping layer ([`textlayout.rs`][textlayout],
[`textlayout/shaping.rs`][shaping]), reached through its own traits:

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

## Q2 — capability declaration

Slint has **no general capability declaration**, and covers the same ground
three ways:

- **Default trait methods.** `visit_opacity` defaults to applying opacity and
  continuing; `visit_layer` is documented `// Not supported` and continues
  without enforcing. A backend overrides what it can do better.
- **A feature-gated optional trait.** `LayerRenderer` exists only under `std`
  ([`item_rendering.rs`][renderer]), so layer support is opt-in at the type
  level rather than probed.
- **One compile-time constant.** `ItemRendererFeatures` declares exactly one
  associated const, `SUPPORTS_TRANSFORMATIONS: bool`.

So Slint sits where we do — the contract is the trait plus its defaults, and
what a backend actually supports is not queryable at runtime. It does not
vindicate our `__traits(compiles)` probing so much as show that a mature project
has not solved this either, which lowers the expected value of inventing
something elaborate here.

> [!NOTE]
> `ItemRendererFeatures` is the one place Slint _does_ declare a capability as
> data, and it is worth reading as a scoping result rather than a
> counter-example: after a decade of targets, exactly one capability earned a
> declaration, and it is a `const bool` resolved at compile time, not a
> queryable flag set. Compare Qt's [`PaintEngineFeature`][qt] bitmask, which
> names a dozen.

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

## Q4 — command shape

**Does not arise.** Slint dispatches through trait methods rather than
reifying a command stream, so there is no tagged union to get wrong. That is
itself an answer: our `DrawOp` exists because we wanted a recordable,
comparable stream (`RecordingCanvas`, the op-stream parity harness), and Slint
pays no such cost because it does not want that.

The trade it makes instead is visible in the signatures: every `draw_*` method
takes `_self_rc: &ItemRc` and `_cache: &CachedRenderingData` alongside the
item, so per-item caching is threaded through the call rather than derived from
a stream a later pass could inspect.

## Q5 — sub-unit placement

Not a problem Slint has, because its coordinates are **already continuous**:
`LogicalRect`/`LogicalLength` ([`lengths.rs`][lengths]) are floats, and the
backend applies `scale_factor()`. Corner radius rides along as
`LogicalBorderRadius` in `combine_clip(rect, radius)`.

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

## Q8 — extent query

**Not found in this pass.** `get_current_clip()` returns accumulated clip
bounds, which is related but is not "how big is the scene".

The absence is consistent with Q4: there is no scene to ask. An item tree is
walked once against a target whose size the platform layer already fixed, so
the question friction §8 poses — a backend sizing a surface to its content —
never comes up in this design.

## Strengths

- **The widest target spread in the survey behind one trait.** A bare-metal
  software renderer and Skia implement the same eight `draw_*` methods; that is
  the existence proof `sparkles:ui` most needs.
- **Measurement is not a renderer concern, and the unit is not the framework's.**
  `Font::Length` as an associated type is the strongest form of Q1's answer any
  subject gives.
- **Semantic operations survive contact with an MCU.** Eight named widget-ish
  operations did not make the software renderer prohibitive.
- **Defaults do the capability work.** `visit_opacity`/`visit_layer` ship
  behaviour, so a minimal backend is small without being wrong.
- **Backend-owned caches** (`draw_cached_pixmap`) put expensive payloads with
  the party that knows their lifetime.

## Weaknesses

- **The contract is not stated in one place a backend author can read.** It is
  the trait, plus its defaults, plus `ItemRendererFeatures`, plus the
  `std`-gated `LayerRenderer`, plus what each `Render*` payload trait exposes.
- **No runtime capability query at all.** A caller cannot ask whether layers
  are honoured; `visit_layer`'s documented `// Not supported` is a silent
  degrade with no refusable half (contrast [Notcurses][notcurses]'
  `NCVISUAL_OPTION_NODEGRADE`).
- **Nothing is reified**, so there is no cross-renderer parity harness of the
  kind `RecordingCanvas` enables — differences between the software and Skia
  renderers can only be caught as pixels.
- **`#[allow(missing_docs)]` sits on the trait**, so most of the seam is
  undocumented by construction.
- **The per-call `ItemRc`/`CachedRenderingData` plumbing** ties the seam to
  Slint's item-tree representation; the trait is portable across targets but
  not across toolkits.

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                                         | Trade-off                                                                                         |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Measurement behind `AbstractFont`, not on the renderer                  | The thing that differs per target is the _font_, not the _painter_; an MCU font and Skia disagree | Two backends compose only if their `Length` types line up; the framework cannot compare sizes     |
| **Semantic** `draw_*` operations (eight of them)                        | A target that cannot draw a real box shadow must know one was intended in order to degrade it     | Every new semantic operation is a new obligation for every renderer, including the MCU one        |
| Virtual dispatch, **no reified command stream**                         | "Lightweight" — no arena, no tag, no per-frame allocation on a microcontroller                    | No recording, no replay, no cross-renderer op-stream parity test                                  |
| Capability by **default method**, not by query                          | A minimal backend is small; the framework never branches on support                               | Degradation is silent and unrefusable; the real contract is spread across defaults                |
| One capability as a **compile-time const** (`SUPPORTS_TRANSFORMATIONS`) | Zero runtime cost, and the compiler propagates it                                                 | Not extensible without changing every implementor; only earns its keep once per decade            |
| Continuous `LogicalLength` geometry, `scale_factor()` at the backend    | Sub-unit placement is expressible everywhere, including on the software renderer                  | The cell-grid target class is simply not in scope, so the hard case is avoided rather than solved |
| Payloads borrowed (`Pin<&dyn …>`), plus `SharedString`                  | No lifetime obligation in the common case; retention is opt-in and cheap where needed             | A backend that wants to defer work must copy or clone deliberately                                |
| **Backend-owned** pixmap cache with a populate callback                 | The party that knows a payload's lifetime owns it                                                 | The framework cannot reason about, bound, or evict what the backend cached                        |

## Bearing on the proposal

1. **Split measurement off the canvas** into a font/shaping abstraction with a
   backend-chosen unit. This is the single strongest transferable result.
2. **Semantic draw operations are not the error.** Reconsider §3 before acting
   on it.
3. **Continuous coordinates dissolve §5.** Whether `sparkles:ui` can afford
   them is a separate question — its layout is cell-based on purpose.
4. **Backend-owned caches** are a credible answer to §7 that does not require
   interning everything.

## Sources

All paths verified to resolve at
[`12d762c53b6d2022145dcb0cbf58eb91e31d76b9`][rev] over
`raw.githubusercontent.com`.

- The seam: [`internal/core/item_rendering.rs`][renderer] — `trait ItemRenderer`,
  `trait ItemRendererFeatures`, `trait LayerRenderer`, `draw_cached_pixmap`,
  `combine_clip`, `get_current_clip`
- Measurement: [`internal/core/textlayout.rs`][textlayout] (`text_size`) and
  [`internal/core/textlayout/shaping.rs`][shaping] (`TextShaper`, `FontMetrics`,
  `AbstractFont`)
- Geometry vocabulary: [`internal/core/lengths.rs`][lengths],
  [`internal/core/graphics.rs`][graphics]
- Targets: [`Cargo.toml`][cargo] workspace members —
  [`internal/renderers/software`][sw], [`internal/renderers/skia`][skia]
- Context: [`README.md`][readme], [`LICENSE.md`][license],
  [docs.slint.dev][docs], [docs.rs/i-slint-core][docsrs]

<!-- References -->

[cargo]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/Cargo.toml
[docs]: https://docs.slint.dev/
[docsrs]: https://docs.rs/i-slint-core/latest/i_slint_core/item_rendering/trait.ItemRenderer.html
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[graphics]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/internal/core/graphics.rs
[lengths]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/internal/core/lengths.rs
[license]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/LICENSE.md
[notcurses]: ./notcurses.md
[qt]: ./qt-qpaintengine.md
[readme]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/README.md
[renderer]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/internal/core/item_rendering.rs
[repo]: https://github.com/slint-ui/slint
[rev]: https://github.com/slint-ui/slint/tree/12d762c53b6d2022145dcb0cbf58eb91e31d76b9
[shaping]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/internal/core/textlayout/shaping.rs
[skia]: https://github.com/slint-ui/slint/tree/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/internal/renderers/skia
[sw]: https://github.com/slint-ui/slint/tree/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/internal/renderers/software
[textlayout]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/internal/core/textlayout.rs
