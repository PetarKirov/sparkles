# Zed GPUI — one `draw(&Scene)`, eight primitives a shader can evaluate

**Category:** primitive scene. **Last reviewed:** August 23, 2026.
Pinned at [`d71f1461`][rev].

GPUI's renderer seam is a single method taking a single value: a `Scene` of
eight owned primitive kinds, each shaped so a fragment shader can evaluate it
in one draw call. Text is not in that vocabulary at all — measurement and
shaping are a separate platform service, and by the time a glyph reaches the
scene it is an atlas tile.

| Field                | Value                                                                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**         | Rust                                                                                                                                      |
| **License**          | Apache-2.0 (the `gpui` crate; [`crates/gpui/Cargo.toml`][cargo])                                                                          |
| **Repository**       | [`zed-industries/zed`][repo], crate `crates/gpui`                                                                                         |
| **Documentation**    | [`crates/gpui/README.md`][readme]; declared homepage [gpui.rs][home]                                                                      |
| **Category**         | primitive scene                                                                                                                           |
| **Pinned revision**  | [`d71f1461045c098dc6ca6b1b5adcf1b8949722e8`][rev] (`origin/main`, 2026-08-11)                                                             |
| **Target range**     | desktop GPU only — macOS, Windows, Linux, and wasm. No CPU or character-cell target                                                       |
| **Backends shipped** | Metal ([`metal_renderer.rs`][metal]), Direct3D 11 ([`gpui_windows`][winwindow]), wgpu ([`wgpu_renderer.rs`][wgpu], used by Linux and web) |
| **Seam declaration** | `PlatformWindow::draw(&self, scene: &Scene)` in [`platform.rs`][platform]                                                                 |

## Overview

### What it solves

GPUI is the framework Zed is written in, and its constraint is a text editor's:
tens of thousands of glyphs per frame, with the whole UI — not only the buffer —
on the same path. Its README opens:

> GPUI is a hybrid immediate and retained mode, GPU accelerated, UI framework
> for Rust, designed to support a wide variety of applications.

— [`crates/gpui/README.md`][readme]

The "hybrid" is load-bearing here. Elements are re-run each frame (immediate),
but the **painted output is retained**: `Window::reuse_paint` copies an
unchanged element's primitives out of the previous frame's scene by index range
([`window.rs`][window]). That one feature dictates most of the seam's shape and
is this survey's strongest evidence for [friction §7][friction].

### Design philosophy

The scene is not a picture of what the widget layer meant but a description of
what the GPU will be asked to do, in the smallest vocabulary that covers a real
editor. Two rules follow, both visible throughout [`scene.rs`][scene]:

- **A primitive is what one shader can evaluate.** A rounded, bordered,
  gradient-filled rectangle is _one_ `Quad`, because `fs_quad` in
  [`shaders.wgsl`][shaders] evaluates a signed-distance field with corner radii
  and per-edge border widths. Anything a shader cannot do — an arbitrary path —
  is tessellated to triangles by the framework before it reaches the scene.
- **A primitive is GPU memory.** The structs are `#[repr(C)]`, written straight
  into instance buffers — which is why the file defines its own bool:

  ```rust
  /// A boolean stored as a `u32` so that GPU-facing structs contain no
  /// compiler-inserted padding bytes, which would be undefined behavior to
  /// reinterpret as `&[u8]` when writing instance buffers. Guaranteed to be
  /// `0` or `1` by construction; shaders read it as a `u32`/`uint`.
  #[repr(transparent)]
  pub struct PaddedBool32(u32);
  ```

  — [`scene.rs`][scene]

## How it works

The backend contract is three methods on `PlatformWindow` ([`platform.rs`][platform]),
of which only the first draws:

```rust
fn draw(&self, scene: &Scene);
fn sprite_atlas(&self) -> Arc<dyn PlatformAtlas>;
fn is_subpixel_rendering_supported(&self) -> bool;
```

The value `draw` receives is a sum type of eight variants:

```rust
pub enum Primitive {
    Shadow(Shadow),
    Quad(Quad),
    Path(Path<ScaledPixels>),
    Underline(Underline),
    MonochromeSprite(MonochromeSprite),
    SubpixelSprite(SubpixelSprite),
    PolychromeSprite(PolychromeSprite),
    Surface(PaintSurface),
}
```

— [`scene.rs`][scene]

`Scene` itself is **not** a `Vec<Primitive>`. It is one public vector per kind
(`quads`, `shadows`, `paths`, `underlines`, three sprite vectors, `surfaces`),
plus a private `BoundsTree<ScaledPixels>`, a `layer_stack`, and a
`Vec<PaintOperation>` insertion history.

The enum is the _insertion_ API (`Scene::insert_primitive(impl Into<Primitive>)`);
the storage is struct-of-arrays because the renderer consumes
`Scene::batches()`, an iterator of `PrimitiveBatch` values naming a kind and a
contiguous index range — `Quads(Range<usize>)`,
`MonochromeSprites { texture_id, range }`. Every shipped renderer is one `match`
over that iterator ([`metal_renderer.rs`][metal], [`wgpu_renderer.rs`][wgpu],
`directx_renderer.rs`).

Sorting per-kind vectors destroys insertion order, so painter's order is
reconstructed from an explicit key: `insert_primitive` takes one from a spatial
index — `BoundsTree::insert` returns "one greater than the maximum ordering of
any" intersecting bounds ([`bounds_tree.rs`][boundstree]) — and `Scene::finish`
sorts each vector by that `order: DrawOrder`. Non-overlapping primitives share
an order and batch together; overlapping ones cannot.

Clipping is not an operation. Every primitive carries a
`content_mask: ContentMask<ScaledPixels>` — a single `Bounds` — which the
framework keeps as a stack in `Window::with_content_mask`, intersecting on push
([`window.rs`][window]). `Scene::push_layer`/`pop_layer` exist but are an
_ordering_ device: "a batch of geometry that are non-overlapping and have the
same draw order."

## Q1 — measurement units, and who answers

Measurement is a first-class service on two levels, and **neither of them is the
renderer**.

- `PlatformTextSystem` ([`platform.rs`][platform]) is the per-OS trait —
  CoreText, DirectWrite, cosmic-text — with `font_metrics`, `typographic_bounds`,
  `advance`, `glyph_for_char`, `glyph_raster_bounds`, `rasterize_glyph` and
  `layout_line(&self, text, font_size, runs) -> LineLayout`.
- `TextSystem` and `WindowTextSystem` ([`text_system.rs`][textsystem]) are the
  framework's caching facade over it: `em_advance`, `ch_advance`, `cap_height`,
  `x_height`, `ascent`, `descent`, `baseline_offset`, `shape_line`,
  `line_wrapper`, plus an `Arc`-shared `LineLayoutCache`.

`layout_line` returns a `LineLayout { font_size, width, ascent, descent, runs,
len }` where each `ShapedGlyph` carries `id`, `position` and `index`
([`line_layout.rs`][linelayout]). There is no monospace assumption anywhere: a
caller advances a pen by `ShapedLine::width()`, documented as "the glyph advance
width computed by the text shaping system" ([`line.rs`][line]).

By the time the renderer is involved there is no text. `Window::paint_glyph`
resolves a `GlyphId` to a raster, inserts it into the sprite atlas, and emits a
`MonochromeSprite`/`SubpixelSprite` holding an `AtlasTile` ([`window.rs`][window]).

This is the fifth surveyed subject to keep measurement off the painter, so
[F1][comparison] holds. But it **complicates F1's second clause**. Slint lets
each backend answer in its own `Font::Length`; GPUI fixes one unit —
`Pixels`, a newtype over `f32` — for the framework, the text system and the
scene alike, and converts to `ScaledPixels` exactly once, at paint time, by
multiplying by the window's scale factor. Backend-chosen units are not the
consensus; _not putting measurement on the renderer_ is.

## Q2 — is the contract stated in one place?

Yes, and this is the cleanest answer in the survey. The drawing contract is
`fn draw(&self, scene: &Scene)`. A backend author reads one enum with eight
variants and writes eight match arms; Rust's exhaustiveness check enforces the
surface, so there is nothing to probe for and nothing to discover at a call
site. Compare `isCanvas`, which advertises five methods while the interpreter
discovers three more by `__traits(compiles)` ([friction §2][friction]).

Capability variation is handled by two mechanisms outside the primitive
vocabulary:

- **A boolean query, consulted by the framework.**
  `PlatformWindow::is_subpixel_rendering_supported()` returns `false` on macOS
  ([`gpui_macos/src/window.rs`][macwindow]) and `true` on Windows
  ([`gpui_windows/src/window.rs`][winwindow]). `Window::should_use_subpixel_rendering`
  also folds in window background opacity and the user's `TextRenderingMode`
  before deciding, so the Metal backend simply never receives that variant — its
  batch arm is `PrimitiveBatch::SubpixelSprites { .. } => unreachable!()`.
- **Conditional compilation.** `PaintSurface`'s payload field is
  `#[cfg(target_os = "macos")] pub image_buffer: CVPixelBuffer` — on other
  platforms the variant exists but carries nothing.

> [!NOTE]
> That is Qt's `hasFeature` idea with the negotiation moved up a level: the
> _framework_ asks, once, and lowers to a different primitive; the backend is
> never asked to degrade anything. It supports [F4][comparison]'s "stated floor"
> half — seven of eight variants are mandatory — while showing that the
> negotiable set can be one query, not a bitmask.

## Q3 — semantic widgets, or primitives?

Neither, and the axis this survey has been using does not cut here.

Nothing widget-shaped reaches the scene: no scrollbar, no text input, no
button — Zed's scrollbars are elements in a separate `ui` crate that emit quads
through `Window::paint_quad`. But the primitives are far from raw geometry:

```rust
pub struct Quad {
    pub order: DrawOrder,
    pub border_style: BorderStyle,       // Solid | Dashed
    pub bounds: Bounds<ScaledPixels>,
    pub content_mask: ContentMask<ScaledPixels>,
    pub background: Background,          // solid | linear gradient | slash | checkerboard
    pub border_color: Hsla,
    pub corner_radii: Corners<ScaledPixels>,
    pub border_widths: Edges<ScaledPixels>,
}
```

— [`scene.rs`][scene]

`Shadow` carries `blur_radius`, `corner_radii`, `element_bounds`,
`element_corner_radii` and an `inset` flag ("0 = drop shadow (rendered outside
the element), 1 = inset shadow"). `Underline` carries `thickness` and
`wavy: PaddedBool32` — the same squiggle our `LineStyle.wavy` names.

The organising principle is **what a fragment shader can evaluate in one pass**.
`fs_quad` computes a rounded-rect SDF from `corner_radii` and shades borders
from `border_widths` ([`shaders.wgsl`][shaders]); a dashed border is a shader
branch, not a different primitive. Where the shader runs out, the _framework_
lowers: `PathBuilder` tessellates through `lyon` into `PathVertex` triangles
([`path_builder.rs`][pathbuilder]), and `paint_svg` rasterises into the atlas.

So GPUI answers [F3][comparison]'s "who degrades" with **neither**: it picks a
vocabulary that needs no degradation and pre-lowers the rest. That option exists
only because every target is a GPU, so it is unavailable to `sparkles:ui` — our
`scrollbar` op exists because a cell backend and a pixel backend genuinely
disagree, a situation GPUI designed itself out of rather than solved.

## Q4 — command shape

A sum type at the API — `Primitive`, plus `PaintOperation` for the layer
brackets:

```rust
pub(crate) enum PaintOperation {
    Primitive(Primitive),
    StartLayer(Bounds<ScaledPixels>),
    EndLayer,
}
```

This is the second reifying subject after egui, and the one that reifies for a
reason we share: `Scene::replay(range, prev_scene)` (Q7) needs commands to be
_values_.

> [!IMPORTANT]
> **This partially falsifies [F2][comparison].** F2 concludes that the fix for
> `DrawOp` is "a `SumType`, not the removal of `DrawOp`". GPUI shows that the
> choice is per-layer, not global. Its _authoring_ type is a sum type; its
> _GPU-facing_ payload is exactly the tag-plus-dead-fields record F2 rejects —
> `Background` is a `#[repr(C)]` record of `tag: BackgroundTag`, `color_space`,
> `solid`, `gradient_angle_or_pattern_height`, `colors: [LinearColorStop; 2]`
> and `pad: u32` ([`color.rs`][color]), where a solid colour leaves five fields
> dead. That is deliberate: the struct is memcpy'd into an instance buffer for a
> shader that reads the tag and branches, and a discriminated union with
> per-variant payloads cannot be that. Any re-encoding of `DrawOp` should expect
> a flat record at whatever boundary faces a GPU, with the sum type above it.

Two second-order notes: reification plus batching costs an explicit order key
(our `DrawOp[]` is ordered implicitly by array position — cheaper, and strictly
unable to be reordered for batching); and `Scene::len()` is
`paint_operations.len()`, not a primitive count, so that index ranges into the
history stay meaningful across frames.

## Q5 — sub-unit placement

Coordinates are continuous (`Pixels`, an `f32` newtype), so GPUI has no
`RuleEdge` problem. What it does have — and this is the transferable part — is
an explicit, _role-differentiated_ rounding policy at the moment continuous
logical units meet discrete device pixels ([`window.rs`][window]):

| Helper             | Rule                                                                                            | Used for                       |
| ------------------ | ----------------------------------------------------------------------------------------------- | ------------------------------ |
| `snap_bounds`      | round each edge to a device pixel, clamping so `right >= left`                                  | quad bounds                    |
| `snap_stroke`      | "Rounds half-to-zero but clamps any non-zero input up to 1 dp so thin strokes do not disappear" | border widths                  |
| `cover_bounds`     | floor near edges, ceil far edges — "a strict superset of the raw region"                        | content masks, shadow bounds   |
| glyph quantisation | `SUBPIXEL_VARIANTS_X = 4`, `SUBPIXEL_VARIANTS_Y = 1`                                            | glyph origin → atlas cache key |

`snap_stroke`'s clamp is the hairline rule stated as policy: a stroke the caller
asked for never rounds away to nothing, only down to the thinnest thing the
device has. That is exactly the guarantee our `rule` op provides by naming an
edge — and it needs no enumerators, only a _stroke_ concept plus a rounding rule
per role. It refines [F5][comparison]: the "fidelity" to name is a rounding
policy attached to the kind of thing being placed.

## Q6 — resolved appearance, semantic role, or both?

**Resolved only.** Scene primitives carry `Hsla` and `Background`; element
opacity is folded in at emission (`quad.background.opacity(opacity)`,
`color.opacity(element_opacity)`), and the scale factor is applied on the way
in. There is no slot, role, class name or theme key anywhere in
[`scene.rs`][scene] — Zed's themes resolve entirely above GPUI, in separate
crates.

Nothing re-resolves downstream because nothing could: every backend is a shader
pipeline. That is the fifth subject to pay for one representation rather than
two, leaving [friction §6][friction] unchallenged — while confirming _why_ we
pay: the HTML interpreter is a re-resolving consumer none of these projects has.

## Q7 — payload ownership, and outliving the frame

The strongest result in this deep-dive. **`Primitive` has no lifetime
parameter.** Every variant owns its payload:

- `Quad`, `Shadow`, `Underline` and all three sprite kinds are `Copy` plain data.
- `Path` owns `Vec<PathVertex<ScaledPixels>>`.
- `PaintSurface` owns a `CVPixelBuffer`.
- Glyphs and images are **not** carried at all: a sprite holds an `AtlasTile`
  (`texture_id`, `tile_id`, `padding`, `bounds`) into a **backend-owned atlas**,
  populated through `PlatformAtlas::get_or_insert_with(key, build)`
  ([`platform.rs`][platform]) — Slint's `draw_cached_pixmap` bargain, generalised
  to every raster payload and keyed by `RenderGlyphParams`, a hashable
  description of font, glyph, size, subpixel variant, scale factor and dilation.

The payoff is not thread-safety but **frame reuse**. An element whose input did
not change is not re-painted; `Window::reuse_paint` splices its previous output
forward:

```rust
self.next_frame.scene.replay(
    range.start.scene_index..range.end.scene_index,
    &self.rendered_frame.scene,
);
```

— [`window.rs`][window], alongside `self.text_system.reuse_layouts(...)` for the
matching shaped lines.

That is impossible with a borrowed payload, and it is a sharper argument than
[F6][comparison] currently makes: `DrawOp.text` being a borrowed slice that
"must outlive the op" ([friction §7][friction]) is not merely a hygiene problem,
it forecloses the biggest paint-time optimisation available to a
retained-output frame loop — one `sparkles:ui` cannot even prototype today.

## Q8 — can a backend ask the scene its extent?

**No, and deliberately.** `Scene`'s public surface is `clear`, `len`,
`push_layer`, `pop_layer`, `insert_primitive`, `replay`, `finish`, `batches` and
the per-kind vectors — no bounds accessor. The `BoundsTree` that knows every
primitive's bounds is private and exists only to assign draw order. Extent comes
from the surface:

- On-screen: `PlatformWindow::draw(&Scene)` — the window already knows its
  `content_size()` and `scale_factor()`.
- Offscreen, including golden-image tests: the size is a **separate parameter**
  on `PlatformHeadlessRenderer::render_scene_to_image`, whose signature is
  `(&mut self, scene: &Scene, size: Size<DevicePixels>)`
  ([`platform.rs`][platform]) — and `TestWindow` computes it from the window
  bounds, not the scene ([`platform/test/window.rs`][testwindow]).

This is the strongest confirmation of [F7][comparison] in the survey: the one
consumer [friction §8][friction] identified as needing a scene-derived extent —
an offscreen golden — is exactly the case GPUI serves by passing the size in.

## Strengths

- **The contract is one method and one exhaustively-matched enum.** A new
  backend is a `match` the compiler completes for you; there is no optional
  surface and no probing.
- **The vocabulary is chosen mechanically** — evaluable by one shader — not by
  taste, which is why eight primitives cover a full editor UI with no escape hatch.
- **Commands own their payloads**, buying cross-frame replay, per-kind batching
  and freedom from lifetime plumbing at once.
- **Raster ownership sits with the backend** (`PlatformAtlas`), keyed by a
  hashable description, so the party that knows a payload's lifetime holds it.
- **The coarse/fine boundary is named explicitly** (`snap_bounds`, `snap_stroke`,
  `cover_bounds`) rather than left to each backend's rounding.

## Weaknesses

- **It cannot reach a non-GPU target.** The vocabulary is what a shader can do;
  there is no software or cell backend and no obvious path to one.
- **The unit is fixed at `Pixels` framework-wide** — a backend cannot answer in
  its own unit the way a Slint `AbstractFont` can.
- **Correctness of z-order depends on a spatial index.** Two overlapping
  primitives of different kinds are ordered by an R-tree query; a bug there is a
  z-order bug with no local explanation.
- **The GPU ABI leaks into the API** — `PaddedBool32`, explicit `pad: u32`
  fields, a tag-plus-dead-fields `Background`.
- **Capability negotiation is ad hoc**: one boolean plus `cfg` gating, with no
  declared feature set — the gap Qt fills with `PaintEngineFeature`.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                         | Trade-off                                                                          |
| ------------------------------------------------------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| One seam method, `draw(&self, scene: &Scene)`           | Backend surface is a total function of one value; exhaustive matching enforces it | The scene type is the API; adding a primitive breaks every backend at compile time |
| Primitives = "what one shader can evaluate"             | No backend ever degrades; a rounded bordered gradient quad is one draw call       | Rules out any non-GPU target                                                       |
| Sum type for insertion, struct-of-arrays for storage    | Batching by kind and by atlas texture is the point of the whole scene             | Requires an explicit `DrawOrder` and a spatial index to preserve painter's order   |
| GPU-facing structs are `#[repr(C)]` with padding fields | Instance buffers are written as `&[u8]`; compiler padding would be UB             | The tag-plus-dead-fields encoding a sum type was supposed to eliminate reappears   |
| Primitives own their payloads; no lifetimes             | `Scene::replay` can splice last frame's output forward                            | Path vertices are cloned per frame; the scene is heavier than a borrowed one       |
| Rasters live in a backend-owned atlas, keyed by params  | The party that knows a payload's lifetime owns it; glyph raster cost paid once    | Cache keys (`RenderGlyphParams`) must enumerate every rendering-relevant parameter |
| Clip travels as a `content_mask` field, not an op       | No clip stack to mis-bracket; every primitive is self-describing                  | One rectangle only — no clip shapes, and the field is paid for on every primitive  |
| Extent is never asked of the scene                      | The surface chose its own size; offscreen callers pass it in                      | An offscreen "size to content" consumer must compute bounds itself                 |

## Bearing on the proposal

1. **Own the payload — the argument is frame reuse, not hygiene.**
   [Friction §7][friction] and [F6][comparison] treat `DrawOp.text` as a safety
   and threading problem; `Scene::replay` shows the real cost, which is losing
   the ability to splice an unchanged subtree's ops forward from last frame.
2. **Keep the sum type — but expect a flat record at the GPU boundary.**
   This qualifies [F2][comparison]: `Background` is a tagged struct with dead
   fields _on purpose_, being instance-buffer memory. Re-encode `DrawOp` as a
   `SumType` for authoring and recording; treat whatever a Skia or Graphite path
   uploads as a separate, deliberately flat type.
3. **State the contract as one enum, not five methods plus three probes.**
   [Friction §2][friction] is confirmed by the cleanest counter-example here:
   eight variants, one `match`, compiler-enforced. Whatever we keep of the
   optional-primitive bargain belongs _outside_ the drawing vocabulary — a query
   the framework consults, like `is_subpixel_rendering_supported`, not a
   `__traits(compiles)` at a call site.
4. **Replace `RuleEdge` with a stroke plus a per-role rounding policy.**
   [F5][comparison] says "name a fidelity"; GPUI names three
   (`snap_bounds`/`snap_stroke`/`cover_bounds`) and gives the one that matters a
   rule we can copy verbatim: a non-zero stroke never rounds to zero. That is
   the whole content of our hairline degradation, without six enumerators.
5. **Adopt a backend-owned, key-addressed raster cache.** `PlatformAtlas::get_or_insert_with`
   with a hashable params key generalises Slint's `draw_cached_pixmap` and is the
   answer to glyph and image payloads that [F6][comparison] recommends.
6. **Do not read GPUI as evidence that semantic ops are wrong.** It has none,
   but only because it has designed away the situation that produces them: with
   every target a GPU, no primitive ever needs degrading. That does not
   generalise to a seam that must also paint into character cells, so it neither
   supports nor undermines [friction §3][friction] — it narrows the claim in
   [F3][comparison] to "when all targets share a rendering model, pick a
   vocabulary that needs no degradation."
7. **Note what reification costs once you want batching.** If `sparkles:ui`
   ever sorts ops by kind (a plausible Skia/Graphite optimisation), it inherits
   GPUI's problem: an explicit draw order derived from overlap. Today our
   implicit array order is a feature; it is worth recording as a constraint
   rather than rediscovering it.

> [!WARNING]
> One F1 nuance to carry into the proposal: GPUI keeps measurement off the
> _renderer_ but fixes the unit at `Pixels` for the entire framework. So the
> unanimity behind [F1][comparison] covers only the first half of the
> recommendation — "move `measure` off the canvas" is unanimous; "with a
> backend-chosen unit" is Slint's answer, not the field's.

## Sources

All pinned at [`d71f1461045c098dc6ca6b1b5adcf1b8949722e8`][rev] and verified to
exist at that revision with `git cat-file -e`:

- [`scene.rs`][scene] — `Scene`, `Primitive`, `PaintOperation`, `PrimitiveBatch`,
  `Quad`, `Shadow`, `Underline`, the sprites, `Path`, `PaddedBool32`
- [`platform.rs`][platform] — `PlatformWindow::draw`, `PlatformTextSystem`,
  `PlatformAtlas`, `AtlasTile`, `PlatformHeadlessRenderer`
- [`window.rs`][window] — `paint_quad`, `paint_glyph`, `with_content_mask`,
  `paint_layer`, `snap_bounds`, `snap_stroke`, `cover_bounds`, `reuse_paint`
- [`text_system.rs`][textsystem], [`line_layout.rs`][linelayout],
  [`line.rs`][line] — `TextSystem`, `shape_line`, `LineLayout`, `ShapedLine`
- [`geometry.rs`][geometry] (`Pixels`, `ScaledPixels`), [`color.rs`][color]
  (`Background`), [`bounds_tree.rs`][boundstree] (`insert`),
  [`path_builder.rs`][pathbuilder] (`lyon`), [`test/window.rs`][testwindow]
- [`metal_renderer.rs`][metal], [`wgpu_renderer.rs`][wgpu],
  [`shaders.wgsl`][shaders] — batch consumers;
  [`gpui_macos`][macwindow] / [`gpui_windows`][winwindow] window impls
- [`README.md`][readme], [`Cargo.toml`][cargo]

Related: the [umbrella][index] (Q1-Q8), the [synthesis][comparison] (F1-F7), the
peers argued with — [Slint][slint], [egui][egui], [Qt][qt],
[Notcurses][notcurses] — the seam itself ([`canvas.d`][canvas]) and the
[friction log][friction].

<!-- References -->

[rev]: https://github.com/zed-industries/zed/tree/d71f1461045c098dc6ca6b1b5adcf1b8949722e8
[repo]: https://github.com/zed-industries/zed
[home]: https://gpui.rs
[cargo]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/Cargo.toml
[readme]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/README.md
[scene]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/scene.rs
[platform]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/platform.rs
[window]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs
[textsystem]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/text_system.rs
[linelayout]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/text_system/line_layout.rs
[line]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/text_system/line.rs
[color]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/color.rs
[geometry]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/geometry.rs
[boundstree]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/bounds_tree.rs
[pathbuilder]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/path_builder.rs
[testwindow]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/platform/test/window.rs
[metal]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui_macos/src/metal_renderer.rs
[wgpu]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui_wgpu/src/wgpu_renderer.rs
[shaders]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui_wgpu/src/shaders.wgsl
[macwindow]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui_macos/src/window.rs
[winwindow]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui_windows/src/window.rs
[index]: ./index.md
[comparison]: ./comparison.md
[slint]: ./slint.md
[egui]: ./egui.md
[qt]: ./qt-qpaintengine.md
[notcurses]: ./notcurses.md
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
