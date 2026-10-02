# glyphon (Rust, wgpu)

A 1 775-line wgpu middleware that turns [`cosmic-text`](./cosmic-text.md)
layout into one instanced draw call over two GPU glyph atlases, the
"rasterize on the CPU, sample on the GPU" counterpoint to
[`vello`](./vello.md)'s per-frame compute rasterization.

| Field            | Value                                                                                  |
| ---------------- | -------------------------------------------------------------------------------------- |
| Language         | Rust (edition 2021) + one WGSL shader                                                  |
| License          | MIT OR Apache-2.0 OR Zlib ([`Cargo.toml`][cargo])                                      |
| Repository       | [`grovesNL/glyphon`][repo]                                                             |
| Documentation    | [`README.md`][readme], rustdoc on [`docs.rs/glyphon`][docsrs], [`examples/`][ex-hello] |
| Category         | rasterizer (GPU atlas renderer)                                                        |
| Layer(s) covered | raster (atlas + composite only; shape/layout/raster delegated to `cosmic-text`)        |
| Version at pin   | 0.12.0, on `cosmic-text` 0.19, `wgpu` 30, `etagere` 0.3                                |
| Pinned revision  | `49dc8f7bafa8091f4d71521fd62ee6f647b556f5` (2026-07-09)                                |

## Overview

### What it solves

Drawing text inside an existing wgpu frame without a dedicated render pass or a
font stack of its own. All font work is `cosmic-text`'s: glyphon re-exports
`FontSystem`, `Buffer`, `SwashCache`, `CacheKey`, `SubpixelBin` and the rest
verbatim ([`lib.rs`][lib], lines 24–31). What glyphon adds is the GPU half: a
texture atlas with LRU eviction and doubling growth, an instance buffer, and a
render pipeline. The crate is 1 647 lines of Rust plus 128 lines of WGSL in
`src/` (2 773 `.rs` lines counting examples and benches).

### Design philosophy

The README states the three-stage split and the integration contract:

> - shaping/calculating layout/rasterizing glyphs (with `cosmic-text`)
> - packing the glyphs into texture atlas (with `etagere`)
> - sampling from the texture atlas to render text (with `wgpu`)
>
> To avoid extra render passes, rendering uses existing render passes
> (following the middleware pattern described in `wgpu`'s Encapsulating
> Graphics Work wiki page).

— [`README.md`][readme]

The middleware pattern means a `prepare` phase that owns every mutation
(rasterize, upload, write vertices) and a `render` phase that only borrows a
`RenderPass` and records commands, so the caller's pass ordering is untouched.

## How it works

Four public objects, each with a distinct lifetime:

- **`Cache`** — `Arc<Inner>` holding the shader module, sampler, bind-group
  layouts and a `Mutex<Vec<…>>` of render pipelines keyed by
  `(TextureFormat, MultisampleState, Option<DepthStencilState>)`
  ([`cache.rs`][cache], lines 22–43). One per device, cloned freely.
- **`TextAtlas`** — two `InnerAtlas`es (`mask_atlas`: `R8Unorm`;
  `color_atlas`: `Rgba8UnormSrgb` or `Rgba8Unorm` by `ColorMode`) plus the
  bind group over both ([`text_atlas.rs`][atlas], lines 285–293).
- **`Viewport`** — a uniform buffer with the screen resolution; written only
  when it changes ([`viewport.rs`][viewport]).
- **`TextRenderer`** — a vertex buffer, a pipeline and a
  `Vec<GlyphToRender>` rebuilt on every `prepare`.

`TextRenderer::prepare(device, queue, &mut FontSystem, &mut TextAtlas,
&Viewport, text_areas, &mut SwashCache)` walks each `TextArea`'s
`Buffer::layout_runs()`, skipping runs outside `bounds` vertically, and for each
`LayoutGlyph` calls `glyph.physical((left, top), scale)` to get a
`cosmic_text::CacheKey` with the integer pixel position and the subpixel bins
([`text_render.rs`][render], lines 247–313). A cache hit stamps
`last_used = generation`; a miss calls `SwashCache::get_image_uncached` —
glyphon deliberately bypasses `SwashCache`'s CPU image map, since the atlas is
the cache — allocates a rectangle, and `queue.write_texture`s the bitmap
(lines 463–545). Each glyph becomes a 28-byte instance:

```rust
pub(crate) struct GlyphToRender {
    pos: [i32; 2],
    dim: [u16; 2],
    uv: [u16; 2],
    color: u32,
    content_type_with_srgb: [u16; 2],
    depth: f32,
}
```

— [`lib.rs`][lib], lines 58–67

Clipping to `TextBounds` is done on the CPU by shrinking `dim` and shifting
`uv` (lines 585–613), so the shader needs no scissor. `render` is five lines:

```rust
pass.set_pipeline(&self.pipeline);
pass.set_bind_group(0, &atlas.bind_group, &[]);
pass.set_bind_group(1, &viewport.bind_group, &[]);
pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
pass.draw(0..4, 0..self.glyph_vertices.len() as u32);
```

— [`text_render.rs`][render], lines 359–363

That is the one-draw-call property: a triangle strip of four vertices,
instanced once per glyph (`VertexStepMode::Instance`, [`cache.rs`][cache], line
65), expanded in [`shader.wgsl`][shader] from `vertex_index` bits. It holds per
`TextRenderer`, across any number of `TextArea`s, mask and color glyphs mixed.

## Analysis spine

### 1. Layering and ownership

glyphon is a fifth layer on top of `cosmic-text`'s four (font database,
`Font`, `Buffer`, `SwashCache`): the **GPU glyph cache**. Ownership is split by
lifetime — `Cache` per device (`Arc`, shareable across threads behind its
`Mutex`), `TextAtlas` per surface format, `TextRenderer` per draw site,
`Viewport` per render target. Every mutable input arrives as `&mut`, so
`prepare` is single-threaded by construction, and the `FontSystem` borrow ties
it to the thread that owns fonts. Errors are two enums: `PrepareError::AtlasFull`
when eviction and growth both fail, and `RenderError` ([`error.rs`][error]).
The frame contract is explicit in the example: `prepare` → `render` → submit →
`atlas.trim()` ([`hello-world.rs`][ex-hello], lines 186, 259), where `trim`
just bumps the generation counter that marks glyphs as in use.

### 2. Face loading and table access

Not applicable. glyphon never sees a font file; faces come from
`cosmic-text`'s `FontSystem` and its `fontdb` database.

### 3. Shaping

Not applicable: shaping and line layout happen in `cosmic-text`'s `Buffer`
before `prepare`. glyphon consumes only positioned `LayoutGlyph`s.

### 4. Variation and instances

Not applicable. Whatever variation `cosmic-text` applies is folded into its
`CacheKey` (font id, glyph id, size bits, weight, flags), which glyphon uses
verbatim as its atlas key, so distinct instances get distinct atlas slots
without glyphon knowing about axes.

### 5. Rasterization and outlines

**No outline access (RQ6).** glyphon receives bitmaps only.

**Atlas strategy (RQ2).** Each `InnerAtlas` starts at 256×256
(`INITIAL_SIZE`, [`text_atlas.rs`][atlas], line 33), packed by `etagere`'s
`BucketedAtlasAllocator`. On allocation failure `try_allocate` pops the LRU
entry until it reaches one touched this generation — then the atlas is full
for this frame (lines 73–106). Only then does `grow` double the side up to
`max_texture_dimension_2d`, create a new texture and **re-rasterize every
cached glyph from scratch** via `get_image_uncached`, because the old texture's
contents are not copied (lines 112–217). Growth is therefore a full re-render
of the working set, bounded by the device's texture limit.

**Subpixel positioning.** The key carries `cosmic-text`'s `SubpixelBin`, four
bins per axis ([`glyph_cache.rs`][ct-bin], lines 65–70), so one glyph at one
size occupies up to 16 atlas slots. Custom glyphs can opt out with
`snap_to_physical_pixel` ([`custom_glyph.rs`][custom]).

**Sampling, gamma and LCD.** The sampler is `FilterMode::Nearest` everywhere
([`cache.rs`][cache], lines 50–52): quads land on integer pixels and the
fractional offset lives in the bin, so no bilinear blur. The mask path
multiplies `color.a` by the R8 coverage; `ColorMode::Accurate` converts the
vertex color sRGB→linear in the shader, `Web` does not
([`shader.wgsl`][shader]). There is no gamma or contrast adjustment of coverage
itself. LCD output is unsupported: `SwashContent::SubpixelMask` is mapped to
`Mask` with the comment _"Not implemented yet, but don't panic if this
happens."_ ([`text_render.rs`][render], lines 292–295).

**Color glyphs.** Whatever `swash` renders as `SwashContent::Color` (COLR,
bitmap strikes) goes to the RGBA atlas. `CustomGlyph` plus a
`rasterize_custom_glyph` callback lets the caller inject SVG icons or images
into the same atlases (the `custom-glyphs` example rasterizes SVGs with
`resvg`).

### 6. Metrics and measurement

Not applicable beyond placement: glyph `left`/`top` bearings come from the
`swash` image placement, and line positions from `LayoutRun::line_y`. All
units are physical pixels after `TextArea::scale`.

### 7. Discovery, matching and fallback

Not applicable; delegated wholly to `cosmic-text` (see
[`cosmic-text`](./cosmic-text.md) §7).

## What it teaches `sparkles:font`

- **Separate the GPU glyph cache from the font stack.** glyphon proves the
  atlas needs exactly one input from the font layer: a hashable
  `(face, glyph, size, subpixel bins, flags)` key plus a "rasterize this key"
  function. `sparkles:font` should export that key type and keep atlas policy
  in `sparkles:raylib-text` / `sparkles:ui-raylib`.
- **Two atlases by content type** (R8 coverage, RGBA color) with a per-instance
  flag in one pipeline is the minimal colour-emoji design; `FontSet` today has
  neither a colour atlas nor a content-type flag.
- **Generation-stamped LRU eviction before growth** is cheap and correct: a
  glyph touched this frame is never evicted, so `AtlasFull` means the frame
  genuinely does not fit.
- **Growth by re-rasterization** is the simple answer when the CPU rasterizer
  is cheap and deterministic; a texture-to-texture copy would avoid it and is
  the obvious improvement.
- **Subpixel bins plus nearest sampling** beats bilinear oversampling for
  crisp text: quarter-pixel horizontal bins cost a 16× worst-case slot
  multiplier, which a terminal grid (integer cell origins) can drop to 1×.
- **Instanced quads with CPU clipping** is the one-draw-call recipe a
  terminal renderer can copy directly: 28 bytes per glyph, no index buffer,
  no scissor state.

## Strengths

- Tiny: 1 647 lines of Rust, one WGSL file; easy to read whole.
- One instanced draw per renderer, inside the caller's render pass.
- Mask and color atlases with LRU eviction and doubling growth.
- Custom glyph hook shares the atlas with text.
- Correct sRGB handling selectable per atlas (`ColorMode`).

## Weaknesses

- No LCD/subpixel AA; `SubpixelMask` silently degrades to grayscale.
- Growth re-rasterizes the whole cached set; capped at the device texture
  limit, then `AtlasFull`.
- Hard-wired to `cosmic-text` types and wgpu; no outline or SDF path, so
  large or transformed text is re-rasterized per size.
- No coverage gamma or stem darkening; quality is whatever `swash` produces.
- `prepare` needs `&mut FontSystem`, so text preparation cannot run off the
  font-owning thread.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                       | Trade-off                                                 |
| ----------------------------------------------- | ----------------------------------------------- | --------------------------------------------------------- |
| Middleware: `prepare` mutates, `render` records | Fits into an existing render pass               | Caller must sequence `prepare`/`render`/`trim` each frame |
| Atlas key = `cosmic_text::CacheKey`             | Zero translation; variations and size come free | Couples glyphon to `cosmic-text` versions                 |
| Separate R8 mask and RGBA color atlases         | 4× less memory for monochrome text              | Two textures, two growth paths                            |
| LRU eviction gated by frame generation          | Never evicts a glyph in use this frame          | Working set must fit one texture                          |
| Grow ×2 and re-rasterize everything             | No GPU copy, simple code                        | Growth frames stall on CPU rasterization                  |
| Subpixel bins + nearest sampling                | Crisp glyphs at fractional positions            | Up to 16 slots per glyph per size                         |
| CPU clipping into instance `dim`/`uv`           | One pipeline, no scissor                        | CPU work per glyph per frame                              |
| Bypass `SwashCache` image map                   | Avoid a second (unbounded) CPU copy             | Re-rasterize on growth instead                            |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- [`README.md`][readme] — scope and the middleware pattern.
- [`src/lib.rs`][lib] — re-exports, `GlyphToRender`, `TextArea`, `TextBounds`.
- [`src/text_render.rs`][render] — `TextRenderer::prepare`/`render`,
  `prepare_glyph` (cache lookup, allocation, upload, clipping).
- [`src/text_atlas.rs`][atlas] — `InnerAtlas`, eviction, growth, `ColorMode`.
- [`src/cache.rs`][cache] — shared pipelines, sampler, instance layout.
- [`src/shader.wgsl`][shader] — quad expansion and mask/color sampling.
- [`src/viewport.rs`][viewport], [`src/custom_glyph.rs`][custom],
  [`src/error.rs`][error].
- [`examples/hello-world.rs`][ex-hello] — the per-frame call sequence.
- `cosmic-text` [`src/glyph_cache.rs`][ct-bin] — `CacheKey` and `SubpixelBin`.

<!-- References -->

[repo]: https://github.com/grovesNL/glyphon
[docsrs]: https://docs.rs/glyphon
[readme]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/README.md
[cargo]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/Cargo.toml
[lib]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/src/lib.rs
[render]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/src/text_render.rs
[atlas]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/src/text_atlas.rs
[cache]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/src/cache.rs
[shader]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/src/shader.wgsl
[viewport]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/src/viewport.rs
[custom]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/src/custom_glyph.rs
[error]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/src/error.rs
[ex-hello]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/examples/hello-world.rs
[ct-bin]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/glyph_cache.rs
