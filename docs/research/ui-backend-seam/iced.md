# Iced — one austere renderer, refined by sub-traits the widget demands

**Category:** capability by trait decomposition. **Last reviewed:** August 23, 2026.
Pinned at [`3de45144`][rev].

Iced splits its backend contract into a minimal base trait and a family of
**capability sub-traits** — `text::Renderer`, `image::Renderer`,
`svg::Renderer`, `geometry::Renderer`, `mesh::Renderer` — each declaring its own
associated types, and each demanded by name in the `where` clause of the widgets
that need it. It is the direct structural alternative to `isCanvas`'s
`__traits(compiles)` probing, and the closest thing in this survey to what D's
Design-by-Introspection could express natively.

| Field                | Value                                                                                              |
| -------------------- | -------------------------------------------------------------------------------------------------- |
| **Language**         | Rust                                                                                               |
| **License**          | MIT ([`LICENSE`][license], `license = "MIT"` in [`Cargo.toml`][cargo])                             |
| **Repository**       | [`iced-rs/iced`][repo]                                                                             |
| **Documentation**    | [`docs.rs/iced`][docs]                                                                             |
| **Category**         | capability by trait decomposition                                                                  |
| **Pinned revision**  | `3de451447bd28217bb535632867550908e29d5d0` (workspace version `0.15.0-dev`)                        |
| **Target range**     | desktop + web GPU surfaces only; no terminal, no MCU                                               |
| **Backends shipped** | [`iced_wgpu`][wgpu] (Vulkan/Metal/DX12/GL/WebGPU), [`iced_tiny_skia`][tinyskia] (CPU), `()` (null) |
| **Base seam**        | [`core::Renderer`][renderer] — **one** drawing method                                              |

## Overview

### What it solves

Iced's crate graph is organised so that the widget layer, the runtime and the
shell never name a concrete painter. [`iced_core`][core-lib] holds the traits;
[`iced_graphics`][gfx-lib] is, in its own words, "a bunch of backend-agnostic
types that can be leveraged to build a renderer for `iced`"; and
[`iced_renderer`][renderer-crate] picks or composes the two shipped
implementations. The README states the split as a feature: a
"renderer-agnostic native runtime enabling integration with existing systems"
plus "two built-in renderers leveraging `wgpu` and `tiny-skia`" ([`README.md`][readme]).

### Design philosophy

The seam's module doc opens with an invitation — `//! Write your own renderer.`
— and the base trait is deliberately tiny ([`core/src/renderer.rs`][renderer]):

```rust
/// A component that can be used by widgets to draw themselves on a screen.
pub trait Renderer {
    fn start_layer(&mut self, bounds: Rectangle);
    fn end_layer(&mut self);
    fn start_transformation(&mut self, transformation: Transformation);
    fn end_transformation(&mut self);

    fn fill_quad(&mut self, quad: Quad, background: impl Into<Background>);

    fn allocate_image(&mut self, handle: &image::Handle,
        callback: impl FnOnce(Result<image::Allocation, image::Error>) + Send + 'static);

    fn hint(&mut self, scale: Scale);
    fn scale(&self) -> Option<Scale>;
    fn reset(&mut self, new_bounds: Rectangle);
    fn settings(&self) -> Settings;
    fn tick(&mut self) {}
}
```

**A base-conforming backend can draw exactly one thing: a `Quad`.** Text,
images, SVG, vector geometry and meshes are each a separate trait, and a widget
that needs one says so.

> [!NOTE]
> The `Quad` is not as primitive as its name suggests: it carries `bounds`,
> `border: Border`, `shadow: Shadow` and `snap: bool`. Rounded corners, strokes
> and drop shadows are therefore base-seam concepts, not widget-level
> compositions. "Primitive vs semantic" is a gradient here, not a switch.

## How it works

A sub-trait refines the base by inheritance plus associated types. The text one
is the richest ([`core/src/text.rs`][text]):

```rust
/// A renderer capable of measuring and drawing [`Text`].
pub trait Renderer: crate::Renderer {
    type Font: Copy + PartialEq;
    type Paragraph: Paragraph<Font = Self::Font> + 'static;
    type Editor: Editor<Font = Self::Font> + 'static;

    const ICON_FONT: Self::Font;
    const CHECKMARK_ICON: char;
    const ARROW_DOWN_ICON: char;
    /* SCROLL_UP_ICON, SCROLL_DOWN_ICON, SCROLL_LEFT_ICON, SCROLL_RIGHT_ICON, ICED_LOGO */

    fn default_font(&self) -> Self::Font;
    fn default_size(&self) -> Pixels;
    fn fill_paragraph(&mut self, text: &Self::Paragraph, position: Point,
                      color: Color, clip_bounds: Rectangle);
    fn fill_editor(&mut self, editor: &Self::Editor, /* … */);
    fn fill_text(&mut self, text: Text<String, Self::Font>, /* … */);
}
```

[`image::Renderer`][image] adds `type Handle: Clone` plus `load_image`,
`measure_image` and `draw_image`; [`svg::Renderer`][svg] adds `measure_svg` and
`draw_svg` with **no** associated type (the handle is concrete);
[`geometry::Renderer`][geometry] adds `type Geometry: Cached` and
`type Frame: frame::Backend<Geometry = Self::Geometry>`; [`mesh::Renderer`][mesh]
adds two methods and does **not** inherit `core::Renderer`. Two of the five live
outside `iced_core`, in `iced_graphics` — **the capability set is open**: a
third-party crate can add a sub-trait and a widget requiring it without touching
the base seam.

The bound lands on the widget. [`core::Widget`][widget] requires only
`Renderer: crate::Renderer`; a text widget narrows it
([`core/src/widget/text.rs`][widget-text]):

```rust
impl<Message, Theme, Renderer> Widget<Message, Theme, Renderer> for Text<'_, Theme, Renderer>
where
    Theme: Catalog,
    Renderer: text::Renderer,
{
    fn tag(&self) -> tree::Tag { tree::Tag::of::<State<Renderer::Paragraph>>() }
    fn state(&self) -> tree::State {
        tree::State::new(paragraph::Plain::<Renderer::Paragraph>::default())
    }
```

The widget's retained state is `Renderer::Paragraph` — the backend's shaped text
object, held in the widget tree. [`widget::Rule`][rule] requires only
`core::Renderer`; [`widget::Canvas`][canvas] requires `geometry::Renderer`. A
program's capability requirements are the compiler-computed union of its
widgets' bounds.

## Q1 — measurement unit, and who answers

**Not on the base renderer, but not off the backend either.** There is no
`measure` on `core::Renderer`. Measurement happens through the associated
[`Paragraph`][paragraph] type: `Paragraph::with_text(text)` shapes, and
`min_bounds() -> Size` reports "the minimum boundaries that can fit the contents
of the `Paragraph`". The text widget's `layout` builds or updates that paragraph
inside its tree state and returns `paragraph.min_bounds()` as the node size
([`core/src/widget/text.rs`][widget-text]).

So the **shaper is an associated type**, as in Slint — but the **unit is not**.
`min_bounds` returns `Size`, i.e. `f32` logical pixels, fixed by `iced_core`.
Slint abstracts `Font::Length`; iced abstracts the shaper and pins the unit.

Logical and device units are reconciled by a **hint handshake**, not a unit
change: `Renderer::hint(Scale { window, application })` reports the scale
factor, `hint_factor()` returns it when `Settings::metrics_hinting` is on, and
the value rides in every `Text::hint_factor` field so a paragraph may lay out in
physical coordinates — the doc on `hint` says the goal is "keeping layout
coordinates logical and, therefore, maintain linearity."

> [!IMPORTANT]
> The price of an associated shaper shows up in [`fallback::Renderer`][fallback],
> which composes two backends into one type. Its base-trait impl needs only
> `A: core::Renderer, B: core::Renderer`. Its text impl needs
> `B: core::text::Renderer<Font = A::Font, Paragraph = A::Paragraph, Editor = A::Editor>`
> — the two backends must share the _same_ shaper type. `iced_wgpu` and
> `iced_tiny_skia` both set `type Paragraph = Paragraph` from
> [`graphics::text`][gfx-paragraph], which is why the fallback compiles at all.
> **An associated measurement type makes heterogeneous backend composition
> impossible unless the backends agree on it exactly.**

That is the sharpest transferable warning for friction §1, and it lands squarely
on the decision F2 separates from placement: moving `measure` off the canvas is
right, but making its _return type_ backend-chosen has a cost Slint's design
does not pay, because Slint never composes two renderers into one.

## Q2 — where the contract is stated

**In traits, one per capability, checked by the compiler at the widget's use
site.** There is no `hasFeature`, no feature bitmask, no probe. A backend either
implements `image::Renderer` or it does not, and a program that uses the image
widget will not compile against a backend that does not.

This is the cleanest answer in the survey to friction §2, and it is the
structural cousin of what `isCanvas` gestures at: instead of one concept whose
five required methods, plus four optional primitives probed with
`__traits(compiles)` at each interpreter call site, under-describe the eight
kinds the display list actually carries, there are five concepts, each complete,
each named at the point of demand.

Runtime negotiation survives in exactly three typed places:
`image::Error::Unsupported` ("loading images is unsupported", returnable from
`load_image`); `measure_image(&Handle) -> Option<Size<u32>>`, where `None` means
"not loaded yet — I will load in the background and trigger a relayout"; and
`Renderer::scale() -> Option<Scale>`, where `None` means "never hinted".

Backend _selection_ is separate data, not a capability query: the
[`backend::Backend`][backend] enum (`Best`, `Hardware(Api)`, `Software`,
`Custom(String)`) is read from `ICED_BACKEND` by its `Default` impl. Fallback is
**whole-backend at initialisation**: `fallback::Compositor::new` constructs `A`,
and on error `B`, collecting both failures into `backend::Error::List`
([`renderer/src/fallback.rs`][fallback]). Nothing degrades one draw call at a
time.

There is a canonical minimal backend — `impl Renderer for ()` in
[`core/src/renderer/null.rs`][null], `#[cfg(debug_assertions)]`, implementing
every sub-trait with empty bodies, `type Paragraph = ()` and an
`allocate_image` that fabricates a `100 × 100` allocation. It is a _type-check_
seam, not a _test_ seam: it records nothing.

## Q3 — semantic widgets at the seam

**No.** The base seam has one drawing call and does not know what a scrollbar
is. [`widget::Scrollable`][scrollable] paints its own rails and thumbs with
`renderer.fill_quad(...)` inside a `with_layer` bracket; the auto-scroll puck is
two more quads plus a `core::Text`. [`widget::Rule`][rule] — the direct
counterpart of our `rule` op kind — is a widget that resolves a `Style` from the
theme, computes a line rectangle, and emits one quad.

This flatly contradicts Slint, which ships `draw_text_input` and
`draw_box_shadow` as renderer methods, and it is the strongest evidence in the
survey **against** carrying `scrollbar` in the drawing seam (friction §3).

The qualification matters. Semantics do cross the seam — as **associated
constants**, not calls. `text::Renderer` declares `ICON_FONT` plus
`CHECKMARK_ICON`, `ARROW_DOWN_ICON`, `SCROLL_UP_ICON`, `SCROLL_DOWN_ICON`,
`SCROLL_LEFT_ICON`, `SCROLL_RIGHT_ICON` and `ICED_LOGO`. The backend answers
"which glyph means _scroll up_ in your icon font"; the widget draws. That is far
cheaper than handing a backend the fourteen fields of a `Scrollbar` payload and
expecting it to know what a scrollbar is.

## Q4 — command shape

**No reified command at the seam**, and a reified one immediately below it —
per backend, and encoded by kind rather than as one tagged record.

Above the seam it is method dispatch, with scoped-closure conveniences over the
explicit bracket pairs (`with_layer`, `with_transformation`, `with_translation`)
— the only defaulted methods on the base trait besides `tick` and `hint_factor`.
Below it, [`iced_tiny_skia::Layer`][ts-layer] is a struct of parallel vectors:

```rust
pub struct Layer {
    pub bounds: Rectangle,
    pub quads: Vec<(Quad, Background)>,
    pub primitives: Vec<Item<Primitive>>,
    pub images: Vec<Image>,
    pub text: Vec<Item<Text>>,
}
```

and [`graphics::text::Text`][gfx-text] _is_ a Rust `enum` with per-variant
payloads — `Paragraph { paragraph: paragraph::Weak, position, color, … }`,
`Editor { … }`, `Cached { content: String, … }`, `Raw { … }`. The
[`layer::Layer`][layer] trait above them exists so that a backend can "efficiently
record primitives together and defer grouping until the end" (`flush`).

So the shape is neither Slint's pure dispatch nor egui's single `Shape` sum
type: it is **structure-of-arrays by primitive class, one array per kind, chosen
by the backend that will batch it**. It is a third answer beside our own, and
the trade F3 holds open is visible in it whole. `DrawOp` is a closed sum over
eight per-kind payloads, so every operation is as wide as the widest of them —
`TextRun`, under a `static assert(DrawOp.sizeof <= 64)` budget — and a `PopClip`
that carries nothing costs what a text run costs (friction §4). Iced never makes
a record wide enough for every kind, and pays for it by having no single stream
a second backend could replay.

## Q5 — sub-unit placement

Coordinates are continuous `f32`, so the question mostly dissolves as it does
for Slint and Qt — but iced is the one subject that shows what a toolkit does
when it _wants_ device-exact hairlines from continuous coordinates, and it does
it by **asking the backend for the device unit**. From [`widget::Rule`][rule]:

```rust
if style.snap {
    let unit = 1.0 / renderer.hint_factor().unwrap_or(1.0);

    bounds.width = bounds.width.max(unit);
    bounds.height = bounds.height.max(unit);
}

renderer.fill_quad(
    renderer::Quad { bounds, border: border::rounded(style.radius), snap: style.snap,
                     ..renderer::Quad::default() },
    style.color,
);
```

Three mechanisms cooperate: `hint_factor()` reports the device scale, so
`1.0 / factor` is one device pixel in logical units; `Quad::snap` asks the
backend to snap that quad to the pixel grid; and `renderer::CRISP`
(`cfg!(feature = "crisp")`) sets `snap`'s default build-wide.

`RuleEdge` names six positions because our unit is a whole cell. Iced names
none: it _queries_ the smallest addressable unit and clamps to it.

A second ladder belongs to the same friction entry: `text::Shaping` is
`Auto | Basic | Advanced`, documented as "No shaping and no font fallback …
very cheap" versus "Advanced text shaping and font fallback … expensive".
**The caller names a fidelity and the backend delivers it** — the first half of
F6's answer, applied to shaping rather than to hairlines, with the queried
device unit above supplying the second.

## Q6 — resolved appearance, semantic role, or both

**Resolved, with one narrow inheritance channel.** Every widget resolves its
appearance from the theme before drawing, through a per-widget `Catalog` trait
whose `Class<'a>` associated type is the semantic handle
([`widget::Rule`][rule]):

```rust
pub trait Catalog: Sized {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>) -> Style;
}
```

The renderer receives `Background`, `Border`, `Shadow` and `Color`, already
computed. The one semantic thing reaching the seam is
`renderer::Style { text_color: Color }` — the _inherited_ default threaded
through `Widget::draw`, consulted when a widget's own style says `color: None`.

`sparkles:ui` carries both halves (friction §6) because its HTML interpreter
re-resolves: six of the eight payloads store a `Slot` beside the resolved fields
their primitive paints from — an `Ink` for the four content kinds, `FillRect`'s
own colours plus a `const(BoxChrome)*` for a fill — and `DrawOp.visual`
reconstructs a `Visual` from those on demand rather than storing one. Iced has
no re-resolving backend and no role field, which confirms F9's account of the
cost rather than contradicting it: resolved appearance is what a painter needs,
a role is what only a re-resolver reads, and the second channel earns its place
only where somebody re-resolves.

## Q7 — payload ownership

**Shared by reference count, with the recorded command holding a _weak_
reference plus a copy of the geometry it needs.** Nothing is borrowed across a
frame boundary.

`graphics::text::Paragraph` is `Paragraph(Arc<Internal>)`; a recording layer
stores `paragraph.downgrade()`, and the resulting
[`paragraph::Weak`][gfx-paragraph] carries `min_bounds`, `align_x` and `align_y`
inline beside the `sync::Weak<Internal>` — so a command never keeps the shaped
text alive, yet damage tracking still knows its rectangle.

Images go further, with an explicit, documented ownership contract
([`core/src/image.rs`][image]):

> When you obtain an `Allocation` explicitly, you get the guarantee that using a
> `Handle` will draw the corresponding `Image` immediately in the next frame.
> This guarantee is valid as long as you hold an `Allocation`. Only when you
> drop all its clones, the renderer may choose to free the memory of the
> `Handle`. Be careful!

`Allocation` is `Arc<Memory>` with `downgrade`/`upgrade`, and
`Renderer::allocate_image` takes a
`callback: impl FnOnce(Result<Allocation, Error>) + Send + 'static` — the
`Send + 'static` bound is precisely the thread-crossing guarantee that a
`TextRun.text` borrowed from the frame arena cannot give (friction §7,
`UI-O4`). The
synchronous `load_image` exists too and is documented as blocking: "If the image
is not already loaded, this method will block!"

## Q8 — extent query

**The surface declares its extent; the scene never does.**
`Compositor::create_surface(window, width, height)` and
`configure_surface(surface, width, height)` take the dimensions as arguments,
`present` takes a `&Viewport`, and `Renderer::reset(new_bounds)` tells the
renderer where it is drawing ([`graphics/src/compositor.rs`][compositor]).

The offscreen case — ours in `skia-canvas-render.d` — is served the same way.
`renderer::Headless::screenshot(size, scale_factor, background_color)` is given
its size, and `iced_test`'s emulator derives that size from its own declared
window size rather than from the drawn content
([`test/src/emulator.rs`][emulator]):

```rust
let physical_size = Size::new(
    (self.size.width  * scale_factor).round() as u32,
    (self.size.height * scale_factor).round() as u32,
);
let rgba = self.renderer.screenshot(physical_size, scale_factor, style.background_color);
```

Content-derived extent, when wanted, is a **layout** result:
`Widget::layout(...) -> layout::Node` and `paragraph.min_bounds()`. Iced
therefore answers all three of the questions F7 separates, each in a different
place and each maintained at construction: the surface is told its size, layout
reports the layout extent, and the primitives below the seam keep their own ink
bounds. Our display list sits at the other end of that axis — nothing on it,
on `CmdBuffer` or on the arena reports an extent, so `skia-canvas-render.d`
derives one by folding every operation's rect (friction §8).

The one place primitives _are_ self-describing is damage, not allocation:
`graphics::text::Text::visible_bounds()` and the [`layer::Layer`][layer] trait's
`bounds()` exist so `graphics::damage` can diff frames.

## Strengths

- **The contract is complete and named.** Five traits describe the whole
  surface; a widget writes the capability into a `where` clause and the compiler
  enforces it. No probe, no undocumented eighth op kind.
- **Open capability set.** `mesh::Renderer` and `geometry::Renderer` live in
  `iced_graphics`, so new capabilities need no edit to the base seam.
- **Base seam is genuinely small** — one drawing method plus two bracket pairs.
- **Payload ownership is explicit and documented**: a `Send + 'static`
  allocation callback and a weak-reference recording discipline.
- **Backend composition is a first-class type** (`fallback::Renderer<A, B>`),
  not a runtime branch at every call site.
- **Sub-unit fidelity is queried, not enumerated** (`hint_factor`, `Quad::snap`).

## Weaknesses

- **Associated types make composition rigid.** Two backends compose only if
  their `Font`, `Paragraph` and `Editor` types are identical; the shipped pair
  dodges this by sharing `iced_graphics::text`.
- **The `Renderer` type parameter is viral** — `Widget`, `Element` and every
  helper carry it, and a widget tree is monomorphic in its backend.
- **Icon semantics leak into the text trait**: eight associated `char`
  constants, `ICED_LOGO` among them, that every text backend must supply.
- **`Quad` is a grab-bag.** Border, shadow, radius and snapping in one primitive
  makes "add a capability" and "add a `Quad` field" the same operation.
- **No fidelity negotiation at draw time.** A caller cannot ask for a hairline
  and be told no; the only refusals are `image::Error::Unsupported` and two
  `Option` returns.
- **The null backend type-checks but does not record**, so it is no parity
  oracle.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                    | Trade-off                                                                               |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Base trait with exactly one drawing method (`fill_quad`)           | A minimal backend is cheap to write; capabilities are additive               | `Quad` accretes fields (border, shadow, snap) that a true primitive would not carry     |
| Capabilities as separate traits, demanded in widget `where` bounds | Contract is complete, compiler-checked, extensible outside the core crate    | The `Renderer` parameter is viral; one tree cannot mix backends                         |
| `type Paragraph` / `type Font` / `type Handle` as associated types | The backend owns shaping and image decoding; no framework-imposed shaper     | Fallback composition requires the two backends' associated types to be _equal_          |
| Measurement in fixed logical `Pixels`, not an associated length    | Layout stays linear and backend-independent; `Scale` hints reconcile devices | A backend with an exotic unit must convert; the unit is not negotiable                  |
| Semantic widgets built above the seam from quads and paragraphs    | The seam stays tiny; scrollbars/rules/inputs need no backend cooperation     | A backend cannot degrade a scrollbar _as_ a scrollbar — only per-quad                   |
| Semantic glyph identity as associated `const char`s                | Lets the backend own its icon font without a semantic draw call              | Framework-specific constants (`ICED_LOGO`) in a general text trait                      |
| No command value at the seam; SoA-by-kind reification below it     | Each backend encodes what it will batch; damage diffing gets typed bounds    | No portable op stream, so no cross-backend record/replay parity harness                 |
| Fallback as a two-variant `enum` chosen at compositor creation     | Type-safe, no per-call branching, both failures reported together            | All-or-nothing: cannot use the GPU backend for quads and the CPU one for something else |
| Payloads `Arc`-shared, recorded as `Weak` + inline geometry        | Commands never extend payload lifetime; damage still has bounds              | Every recorded text draw pays an atomic upgrade at paint time                           |

## Bearing on the proposal

1. **Split `isCanvas` into a base concept plus capability concepts, and make
   widgets name what they need** (friction §2, F5, F11). This is the single
   most transferable structure here, and D expresses it more cheaply than Rust:
   `isCanvas!T`, `isTextCanvas!T`, `isClippingCanvas!T` as separate `enum bool`
   concepts, each `static assert`ed where it is used, replaces the
   `__traits(compiles)` probes scattered across interpreter call sites without
   introducing a type parameter anywhere. It also states the floor once, in the
   concepts, instead of leaving it to be reconstructed from the call sites —
   F11's requirement, and F5's point that D already has every construct the
   floor / defaulted / refusable ladder needs.
2. **Do not make the measurement _unit_ backend-chosen** — contradicting the
   reading of F1 that Slint's `Font::Length` invites. Iced moves the shaper off
   the painter (agreeing with F1's core claim) but keeps the unit fixed at
   logical pixels, and [`fallback::Renderer`][fallback] shows why: the moment
   two backends must compose, an associated unit forces them to be the same
   type. Move `measure` off the canvas into a font abstraction; keep its return
   type in the toolkit's own unit. Placement and return shape are two of the six
   decisions F2 separates, and iced settles them in opposite directions.
3. **A scale hint is a better reconciliation than a unit change** (friction §1,
   §5). `hint(Scale)` / `hint_factor()` lets layout stay in one unit while a
   backend lays out in device coordinates. A cell-space toolkit could hand a
   backend the cell-to-device factor by the same route.
4. **Replace `RuleEdge` with a queried device unit, not more enumerators**
   (friction §5, F6). `1.0 / hint_factor()` plus a per-op `snap` flag covers
   every case our six enumerators cover, and the ones they do not — a two-pixel
   focus ring, a badge inset. Continuous coordinates on their own would only
   move the problem, which is F6's point; iced settles it by _asking_, and that
   pairing — a named fidelity plus a queried device unit — is exactly F6's
   answer. `Shaping::{Basic, Advanced}` is the same move on a second axis.
5. **Reconsider `scrollbar` after all — but keep a semantic channel that is not
   a draw call** (friction §3, F4). Iced contradicts Slint here: its scrollbar
   is quads emitted by a widget, and the seam is unharmed. What it keeps are
   associated _constants_ (`SCROLL_UP_ICON`, `CHECKMARK_ICON`) by which a
   backend declares its own glyph vocabulary. F4's question is not
   semantic-versus-primitive but where the lowering lives, and ours already
   lives in one place: `scrollbarThumb` in `sparkles.ui.state`, with
   `scrollbarCellCount`, `scrollbarCell` and `ruleEndpoints` built on it. The
   seam then restates it. A `DrawOp`-free equivalent — the canvas exposing
   `trackGlyph`/`thumbGlyph` as backend-owned data while `scrollbarThumb` does
   the geometry once — would shrink the fourteen-field `Scrollbar` payload to
   the geometry a backend paints and retire one of the eight arms that every
   `match!` walker and every accessor spells out, without losing the
   degradation.
6. **Weigh structure-of-arrays by kind against the closed sum** (friction §4,
   F3). F3 leaves the encoding a live trade, and iced is a third answer beside
   the two it names: separate vectors per primitive class, which pays only for
   what each kind uses _and_ is what a batching backend wants. At our scale the
   trade still falls the other way — the widest payload fits inside the seam's
   64-byte budget, so variable stride buys little, and a closed sum keeps every
   operation a comparable value, which is what makes `RecordingCanvas` a
   pairwise-diffable oracle. Iced pays for its per-backend encoding by having no
   cross-backend parity harness at all; that is a cost we should decline (F12).
   The part of friction §4 iced genuinely answers is the other half: a
   `Vec<Item<Text>>` needs no `@trusted` island and no `launder` cast, because
   the payload it holds is owned rather than borrowed.
7. **Record a handle with inline geometry instead of a borrow** (friction §7,
   F8). F8 finds no subject anywhere that borrows a payload across a frame; the
   frame arena is our version of that discipline — `CmdBuffer.textRun` copies
   into it, and the rule stated on the type is that an operation is valid while
   the buffer that built it is alive and unreset. What that discipline does not
   settle is the retain boundary, which `UI-O4` keeps open, and
   `paragraph::Weak { raw, min_bounds, align_x, align_y }` is the shape to copy
   for it: a recorded op that cannot extend a payload's lifetime, carries its
   own extent, and crosses a thread. An allocation callback bounded
   `Send + 'static` is the direct answer to M7/T5's record-here-submit-there
   requirement.
8. **Answer each of F7's three extent questions in its own place** (friction
   §8). `create_surface(w, h)`, `reset(new_bounds)` and
   `Headless::screenshot(size, …)` all take the size, so the surface question
   never reaches the scene; `min_bounds()` answers the layout question; and
   `visible_bounds()` answers the ink question for damage — each maintained at
   construction rather than recovered by a scan. Give `skia-canvas-render.d` a
   layout-side extent instead of making it fold every operation's rect, and
   leave ink extent where damage tracking would want it, rather than loading all
   three onto a self-describing display list.
9. **A null backend that only type-checks is not enough.** `impl Renderer for ()`
   proves conformance and nothing else. `RecordingCanvas` — a conforming backend
   that _records_ — is a capability iced does not have, and it is what makes the
   op stream a parity oracle rather than a golden (F12). The friction log's
   "did not cause friction" list is right to keep it.

## Sources

- **The seam:** [`core/src/renderer.rs`][renderer] (base `Renderer`, `Quad`,
  `Scale`, `Headless`, `CRISP`), [`core/src/text.rs`][text] (`text::Renderer`,
  its associated `Font`/`Paragraph`/`Editor`, icon constants, `Shaping`),
  [`core/src/text/paragraph.rs`][paragraph], [`core/src/image.rs`][image]
  (`Allocation`, `Error`), [`core/src/svg.rs`][svg],
  [`core/src/renderer/null.rs`][null].
- **Capabilities outside core:** [`graphics/src/geometry.rs`][geometry],
  [`graphics/src/mesh.rs`][mesh].
- **Below the seam:** [`graphics/src/layer.rs`][layer],
  [`graphics/src/text.rs`][gfx-text],
  [`graphics/src/text/paragraph.rs`][gfx-paragraph],
  [`graphics/src/compositor.rs`][compositor],
  [`tiny_skia/src/layer.rs`][ts-layer].
- **Backend selection and composition:** [`core/src/backend.rs`][backend],
  [`renderer/src/lib.rs`][renderer-crate], [`renderer/src/fallback.rs`][fallback],
  [`wgpu/src/lib.rs`][wgpu], [`tiny_skia/src/lib.rs`][tinyskia].
- **Consumers:** [`core/src/widget.rs`][widget],
  [`core/src/widget/text.rs`][widget-text], [`widget/src/rule.rs`][rule],
  [`widget/src/scrollable.rs`][scrollable], [`widget/src/canvas.rs`][canvas],
  [`test/src/emulator.rs`][emulator].
- **Positioning:** [`README.md`][readme], [`core/src/lib.rs`][core-lib],
  [`graphics/src/lib.rs`][gfx-lib].

Revision pinned with `gh api repos/iced-rs/iced/commits/master --jq .sha` and
every cited path verified with `git cat-file -e <sha>:<path>` against a clone at
that revision.

<!-- References -->

[rev]: https://github.com/iced-rs/iced/tree/3de451447bd28217bb535632867550908e29d5d0
[repo]: https://github.com/iced-rs/iced
[docs]: https://docs.rs/iced
[license]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/LICENSE
[cargo]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/Cargo.toml
[readme]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/README.md
[renderer]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/renderer.rs
[null]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/renderer/null.rs
[text]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/text.rs
[paragraph]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/text/paragraph.rs
[image]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/image.rs
[svg]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/svg.rs
[widget]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/widget.rs
[widget-text]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/widget/text.rs
[backend]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/backend.rs
[core-lib]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/core/src/lib.rs
[geometry]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/graphics/src/geometry.rs
[mesh]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/graphics/src/mesh.rs
[layer]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/graphics/src/layer.rs
[gfx-text]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/graphics/src/text.rs
[gfx-paragraph]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/graphics/src/text/paragraph.rs
[compositor]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/graphics/src/compositor.rs
[gfx-lib]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/graphics/src/lib.rs
[renderer-crate]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/renderer/src/lib.rs
[fallback]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/renderer/src/fallback.rs
[wgpu]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/wgpu/src/lib.rs
[tinyskia]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/tiny_skia/src/lib.rs
[ts-layer]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/tiny_skia/src/layer.rs
[rule]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/widget/src/rule.rs
[scrollable]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/widget/src/scrollable.rs
[canvas]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/widget/src/canvas.rs
[emulator]: https://github.com/iced-rs/iced/blob/3de451447bd28217bb535632867550908e29d5d0/test/src/emulator.rs
