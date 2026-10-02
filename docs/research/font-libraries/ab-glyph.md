# ab_glyph (Rust)

A glyph-at-a-time OpenType loader and coverage rasterizer: a `Font` trait over
[`ttf-parser`](./ttf-parser.md), a `PxScaleFont` font-at-size wrapper, outlines
as a `Vec` of curve values, and a ~550-line accumulation rasterizer forked from
`font-rs` — the shape `rusttype` was rewritten into.

| Field            | Value                                                                                                                       |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Language         | Rust 2021; `no_std` + `alloc` (with `libm`) supported in both crates                                                        |
| License          | Apache-2.0 ([`glyph/Cargo.toml`][cargo])                                                                                    |
| Repository       | [`alexheretic/ab-glyph`][repo] — workspace of `ab_glyph` 0.2.32 (`glyph/`) and `ab_glyph_rasterizer` 0.1.10 (`rasterizer/`) |
| Documentation    | docs.rs rustdoc; [`glyph/README.md`][readme], [`rasterizer/README.md`][rreadme]                                             |
| Category         | rasterizer                                                                                                                  |
| Layer(s) covered | parse (delegated) · raster · outline                                                                                        |
| Pinned revision  | `3eb21a592819d9ed78e9a13ad7392d46c60ce39e` (2026-08-30)                                                                     |

## Overview

### What it solves

Rust GUI and game code that needs "this `char` at 24 px, as coverage" without
C dependencies. `ab_glyph` is the rasterization substrate under `glyph_brush`
(the atlas/section-layout crate used by `wgpu_glyph`, `ggez` and older `iced`),
which supplies the cache, queueing and naive layout this crate deliberately
omits. Its README positions it as a performance rewrite of `rusttype`:
_"ab_glyph is a rewrite of rusttype made after I added .otf support for the
latter and saw some performance issue's with the rusttype API"_, quoting a
May 2020 `layout_a_sentence` benchmark of 11.1 µs vs 17.3 µs (TTF) and 11.1 µs
vs 98.1 µs (OTF) against `rusttype` 0.9 ([`glyph/README.md`][readme]).

### Design philosophy

The whole API is the chain id → scaled, positioned glyph → outlined glyph →
coverage callback; the crate doc shows it in four lines:

```rust
let font = FontRef::try_from_slice(include_bytes!("../../dev/fonts/Exo2-Light.otf"))?;

// Get a glyph for 'q' with a scale & position.
let q_glyph: Glyph = font.glyph_id('q').with_scale_and_position(24.0, point(100.0, 0.0));

// Draw it.
if let Some(q) = font.outline_glyph(q_glyph) {
    q.draw(|x, y, c| { /* draw pixel `(x, y)` with coverage: `c` */ });
}
```

— [`glyph/README.md`][readme]

Parsing is entirely `ttf-parser`'s; `glyph/src/ttfp.rs` opens with
_"ttf-parser crate specific code. ttf-parser types should not be leaked
publicly."_ ([`ttfp.rs`][ttfp], line 1). The public surface is a trait plus
plain values, so the parser is swappable.

## How it works

`Font` ([`font.rs`][font], line 39) is an object-safe trait of _unscaled_
accessors in font units — `units_per_em`, `ascent_unscaled`,
`descent_unscaled`, `line_gap_unscaled`, `italic_angle`, `glyph_id(char)`,
`h_advance_unscaled`, `h_side_bearing_unscaled`, `v_*`, `kern_unscaled`,
`outline(GlyphId) -> Option<Outline>`, `glyph_count`, `codepoint_ids`,
`glyph_raster_image2`, `glyph_svg_image`, `font_data` — with provided methods
`as_scaled`/`into_scaled`, `outline_glyph` and `glyph_bounds`. Three
implementors: `FontRef<'font>` wraps `owned_ttf_parser::PreParsedSubtables<Face>`
over a borrowed slice, `FontVec` the same over an `OwnedFace` (owned
`Vec<u8>`), and `FontArc` is `Arc<dyn Font + Send + Sync>` for type erasure and
cheap clones ([`ttfp.rs`][ttfp], lines 36, 99; [`font_arc.rs`][arc]).
`PreParsedSubtables` caches the chosen `cmap` and `kern` subtables at load so
`glyph_id`/`kern_unscaled` skip the per-call table walk (the code comments
_"Using `PreParsedSubtables` method for better performance."_).

The sized layer is `PxScaleFont<F>` — `{ font: F, scale: PxScale }` — whose
`ScaleFont` trait multiplies each unscaled accessor by
`scale.y / height_unscaled()` ([`scale.rs`][scale], lines 79–130, 248). `Glyph`
is a value `{ id, scale, position }`; `outline_glyph` computes the `Outline`,
derives `px_bounds` once, and `OutlinedGlyph::draw` folds the curves into a
fresh `Rasterizer` and calls `for_each_pixel_2d` ([`outlined.rs`][outlined],
lines 107–160).

## Analysis spine

### 1. Layering and ownership

Three layers, two crates: face (`Font` trait over `ttf-parser`), scaled font
(`PxScaleFont`, a by-value pair, not a cache), rasterizer
(`ab_glyph_rasterizer::Rasterizer`, independent of fonts — it draws lines,
quads and cubics). Shaper and font manager are absent. Ownership is Rust's:
`FontRef` borrows (`Clone`), `FontVec` owns, `FontArc` refcounts and is
`Send + Sync`. Nothing is mutable after load except variation coordinates
(`&mut self`, §4); every `outline()` allocates a `Vec<OutlineCurve>` and every
`draw` allocates a `width × height + 4` `f32` grid. No caching at any layer —
`glyph_brush` owns that. Errors: load returns `Result<_, InvalidFont>`; per-glyph
failure is `Option` (`None` for glyphs with empty or inverted bounds); missing
metrics silently become `0.0`.

### 2. Face loading and table access

Bytes only: `FontRef::try_from_slice(&[u8])`,
`try_from_slice_and_index(data, index)` for collections, `FontVec::try_from_vec(_and_index)`;
no path API. Table directory parsing is `ttf-parser`'s (eager directory, lazy
tables). Raw access is limited to `font_data()` (the whole buffer); `ttf-parser`
types are intentionally not re-exported, so an inspector cannot reach `Face::tables()`
through `ab_glyph` and must parse the bytes itself.

### 3. Shaping

None. The text unit is a `char`; `glyph_id` consults one `cmap` subtable;
positioning is `h_advance` plus `kern_unscaled(first, second)`, which reads the
legacy `kern` table via `glyphs_hor_kerning` — not `GPOS`
([`ttfp.rs`][ttfp], line 255). No GSUB, script, direction or clusters. Shaping
in the Rust ecosystem sits beside it ([`rustybuzz`](./rustybuzz.md),
[`cosmic-text`](./cosmic-text.md)).

### 4. Variation and instances

Supported behind the default `variable-fonts` feature. `VariableFont` has two
methods — `set_variation(&mut self, tag: &[u8; 4], value: f32) -> bool` and
`variations() -> Vec<VariationAxis>` with `tag`, `name` (from `name`),
`min/default/max_value` and `hidden` ([`variable.rs`][var],
[`ttfp/variable.rs`][tvar]). Values are user-space; normalization, `avar` and
`gvar`/`HVAR` application happen inside `ttf-parser`, so outlines, advances
and (via `MVAR` tags `hasc`, `hcla`) metrics all follow. Coordinates are
mutable state on the face, so a variable instance cannot be shared by two
sizes with different settings without cloning. Named instances and `STAT` are
not exposed. The `gvar-alloc` feature (default since 0.2.31) enables full
`gvar` support.

### 5. Rasterization and outlines

**Outline API (RQ6).** `Font::outline` returns
`Outline { bounds: Rect, curves: Vec<OutlineCurve> }` in font units, Y-up,
built by a `ttf-parser` `OutlineBuilder` sink that converts callbacks into
values and inserts the implicit closing line ([`outliner.rs`][outliner]):

```rust
pub enum OutlineCurve {
    /// Straight line from `.0` to `.1`.
    Line(Point, Point),
    /// Quadratic Bézier curve from `.0` to `.2` using `.1` as the control.
    Quad(Point, Point, Point),
    /// Cubic Bézier curve from `.0` to `.3` using `.1` as the control at the beginning of the
    /// curve and `.2` at the end of the curve.
    Cubic(Point, Point, Point, Point),
}
```

— [`outlined.rs`][outlined], line 164. Every segment carries its start point,
so there is no move/close vocabulary: contours are implicit. `draw` scales by
`(h_factor, −v_factor)` and offsets by the glyph position, flipping to Y-down
pixels.

**CPU raster (RQ2).** `ab_glyph_rasterizer` is 563 lines of Rust in total;
`raster.rs` is 342 lines of which 195 are code, `geometry.rs` 76 code lines.
It is the `font-rs` signed-area accumulation algorithm: `draw_line_scalar`
adds each line's exact trapezoid area contribution into a flat `Vec<f32>`
(two cells when the span crosses ≤1 pixel, a ramp otherwise), and
`for_each_pixel` turns it into coverage with one running prefix sum,
`acc += c; px_fn(idx, acc.abs())` ([`raster.rs`][raster], lines 104–175,
259–268). `abs()` makes it nonzero-ish winding with the same overlapping-contour
over-coverage as [`stb_truetype`](./stb-truetype.md); values `>= 1.0` mean full
coverage (the clamp was removed in 0.1.5 for speed). Quads are subdivided into
`1 + floor(sqrt(sqrt(3·dev²)))` lines; cubics use stb's recursive midpoint split
with `OBJSPACE_FLATNESS = 0.35` and depth 16 — commented
`// ...I'm not sure either ¯\_(ツ)_/¯` (line 219). The SIMD is runtime dispatch
(`is_x86_feature_detected!` AVX2 / SSE4.2) of the _same_ scalar body recompiled
under `#[target_feature]` ([`raster.rs`][raster], lines 300–340). No hinting,
no LCD/subpixel AA, no gamma, no SDF; sub-pixel positioning is free because
`position` is `f32`.

**Color.** `glyph_raster_image2` returns `CBDT`/`sbix`/`EBDT` strikes as raw
`&[u8]` tagged with `GlyphImageFormat` (PNG, mono/gray packed, premultiplied
BGRA) — undecoded; `glyph_svg_image` returns the raw `SVG ` document range.
`COLR`/`CPAL` are not exposed.

**Atlas.** None here; `glyph_brush` / `glyph_brush_draw_cache` provides the GPU
texture cache above it.

### 6. Metrics and measurement

Unscaled `f32` font units; scaled values are pixels. Ascent/descent/line gap
are `ttf-parser`'s `ascender()`/`descender()`/`line_gap()`: `OS/2` typo when
`USE_TYPO_METRICS` is set, else `hhea`, falling back to typo then `usWin*` when
`hhea` is zero, with `MVAR` deltas applied ([`ttf-parser` `lib.rs`][ttfp-asc],
line 1554). The distinguishing choice is `PxScale`: _"This is the pixel-height
of text"_ — i.e. `ascent − descent`, not pixels per em ([`scale.rs`][scale],
lines 5–28). `pt_to_px_scale` converts at 96 DPI with an explicit
`height_unscaled / units_per_em` factor. No x-height, cap-height or
underline metrics. Two bounds: `glyph_bounds` (layout box from advance and
ascent/descent) and `px_bounds` (conservative integer outline box), documented
as unrelated.

### 7. Discovery, matching and fallback

Absent. No enumeration, matching, or fallback; a missing `char` maps to
`GlyphId(0)`. The only coverage primitive an inspector or fallback chain can
use is `codepoint_ids()`, an unordered iterator of distinct `(GlyphId, char)`
pairs over all Unicode `cmap` subtables ([`ttfp.rs`][ttfp], lines 293–325).
Discovery in this ecosystem is [`fontdb`](./fontdb.md)'s job.

## What it teaches `sparkles:font`

- **A face trait of unscaled accessors plus a by-value `Scaled!Face` wrapper**
  is a clean two-layer split for D: the wrapper is two words, needs no
  lifetime of its own, and keeps the face shareable.
- **Outline as a slice of self-contained segments** (`Line`/`Quad`/`Cubic`
  each with its own start) is trivially transformable and feeds a rasterizer
  without a sink — but loses contour boundaries, which an inspector wants.
  Keep explicit `moveTo`/`close`.
- **The accumulation rasterizer fits in ~200 lines of code** and needs only a
  `float[]` grid plus a prefix sum; it is the minimum credible RQ2 baseline.
  Fix the `abs()` overlap defect and add gamma before shipping it.
- **Do not make variation coordinates face state.** `set_variation(&mut self)`
  forces cloning per instance; pass a coordinate slice to the scaled layer.
- **Define the size unit as px-per-em.** `PxScale` as `ascent − descent` makes
  the same "24 px" differ between fonts — wrong for a terminal cell grid.

## Strengths

- Small, pure-Rust, `no_std`, no unsafe outside the SIMD dispatch.
- Trait-based face API with borrowed, owned and `Arc` implementors.
- Variable fonts (outlines, advances, `MVAR` metrics) through `ttf-parser`.
- Fast: no per-call table walks thanks to pre-parsed `cmap`/`kern` subtables.

## Weaknesses

- No shaping, no `GPOS` kerning, no hinting, LCD, gamma or SDF.
- Allocates an outline `Vec` and a coverage grid per glyph draw; no reuse API.
- Overlapping contours over-cover (`abs()` of the running sum).
- Color glyphs returned as raw undecoded bytes; no `COLR`.
- Non-standard `PxScale` unit.
- Raw tables unreachable by design.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                        | Trade-off                                |
| ------------------------------------------------- | ------------------------------------------------ | ---------------------------------------- |
| Delegate parsing to `ttf-parser`, hide its types  | Parser swappable; small public surface           | No table access for inspectors           |
| `Font` trait + `PxScaleFont` value wrapper        | Size is cheap and composable                     | No per-size cache or hinting state       |
| Outline as `Vec<OutlineCurve>` values             | Inspectable, transformable, feeds the rasterizer | Allocation per glyph; contours implicit  |
| `font-rs` accumulation rasterizer, `f32` grid     | Exact area AA in ~200 lines; vectorizes          | Over-coverage on overlaps; no gamma/LCD  |
| Runtime SIMD by `#[target_feature]` recompilation | One scalar source, AVX2/SSE4.2 speed             | `static mut` + `Once` dispatch; x86 only |
| `PxScale` = ascent − descent in px                | Matches `rusttype` and line-height intuition     | Not em-based; cross-font sizes disagree  |
| Variations as `&mut` face state                   | Simple API                                       | One instance per face object             |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- [`glyph/src/font.rs`][font] — the `Font` trait, units and layout concepts.
- [`glyph/src/ttfp.rs`][ttfp] — `FontRef`/`FontVec`, `ttf-parser` adapter.
- [`glyph/src/ttfp/outliner.rs`][outliner] — sink → `OutlineCurve` values.
- [`glyph/src/outlined.rs`][outlined] — `Outline`, `OutlinedGlyph::draw`.
- [`glyph/src/scale.rs`][scale] — `PxScale`, `ScaleFont`, `PxScaleFont`.
- [`glyph/src/variable.rs`][var], [`glyph/src/ttfp/variable.rs`][tvar] — variations.
- [`glyph/src/font_arc.rs`][arc] — `FontArc`.
- [`rasterizer/src/raster.rs`][raster] — the rasterizer; [`rasterizer/README.md`][rreadme].
- [`glyph/README.md`][readme] — positioning and the `rusttype` benchmark.
- [`ttf-parser` `src/lib.rs`][ttfp-asc] — `Face::ascender` metric source.

<!-- References -->

[repo]: https://github.com/alexheretic/ab-glyph
[cargo]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/glyph/Cargo.toml
[readme]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/glyph/README.md
[rreadme]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/rasterizer/README.md
[font]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/glyph/src/font.rs
[ttfp]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/glyph/src/ttfp.rs
[outliner]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/glyph/src/ttfp/outliner.rs
[outlined]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/glyph/src/outlined.rs
[scale]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/glyph/src/scale.rs
[var]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/glyph/src/variable.rs
[tvar]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/glyph/src/ttfp/variable.rs
[arc]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/glyph/src/font_arc.rs
[raster]: https://github.com/alexheretic/ab-glyph/blob/3eb21a592819d9ed78e9a13ad7392d46c60ce39e/rasterizer/src/raster.rs
[ttfp-asc]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/lib.rs
