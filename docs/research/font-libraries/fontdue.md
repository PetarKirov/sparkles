# fontdue (Rust)

A `no_std` pure-Rust glyph rasterizer that pays for its speed up front: every
glyph outline is flattened into pre-scaled line segments when the font is
loaded, so `rasterize` is a 125-line signed-area accumulation over cached
segments.

| Field            | Value                                                   |
| ---------------- | ------------------------------------------------------- |
| Language         | Rust 2018, `no_std` + `alloc`                           |
| License          | MIT OR Apache-2.0 OR Zlib ([`Cargo.toml`][cargo])       |
| Repository       | [`mooman219/fontdue`][repo]                             |
| Documentation    | [docs.rs/fontdue][docsrs]; [`README.md`][readme]        |
| Category         | rasterizer                                              |
| Layer(s) covered | parse (via `ttf-parser`) · raster · layout              |
| Version at pin   | 0.9.4 (2026-07-29 per [`CHANGELOG.md`][changelog])      |
| Pinned revision  | `2924772fb4439b8aca40b1bffca70088acba5a1b` (2026-07-29) |

## Overview

### What it solves

Games and immediate-mode UIs that want "a coverage bitmap for this character at
this pixel size" with the lowest possible per-call latency and no C
dependency. The README positions it as a replacement for the non-shaping class
of Rust font crates — `rusttype`, [`ab_glyph`](./ab-glyph.md), parts of
`glyph_brush` — and defers anything needing shaping to
[`cosmic-text`](./cosmic-text.md) ([`README.md`][readme], "Roadmap"). Table
parsing is delegated to [`ttf-parser`](./ttf-parser.md) (`0.25`, features
`opentype-layout`, `no-std-float`; [`Cargo.toml`][cargo]); fontdue owns the
geometry, the rasterizer, a naive layout and its own `kern` reader.

### Design philosophy

The README states the inversion of the usual parser contract explicitly:

> A **non-goal** of this library is to be allocation free and have a fast,
> "zero cost" initial load. This library _does_ make allocations and depends on
> the `alloc` crate. Fonts are fully parsed on creation and relevant
> information is stored in a more convenient to access format. Unlike other
> font libraries, the font structures have no lifetime dependencies since it
> allocates its own space.

— [`README.md`][readme], line 15

and the rasterizer carries a warning that it is not a reusable component:

```rust
/* Notice to anyone that wants to repurpose the raster for your library:
 * Please don't reuse this raster. Fontdue's raster is very unsafe, with nuanced invariants that
 * need to be accounted for. Fontdue sanitizes the input that the raster will consume to ensure it
 * is safe. Please be aware of this.
 */
```

— [`src/raster.rs`][raster], lines 1–5

## How it works

`Font::from_bytes(data, FontSettings)` ([`src/font.rs`][font], line 242) runs
`ttf_parser::Face::parse`, hashes the bytes, walks every `cmap` subtable to
build a `HashMap<char, NonZeroU16>`, optionally adds every glyph reachable from
`GSUB` single/multiple/alternate/ligature/reverse-chain substitutions
([`src/table/gsub.rs`][gsub]), and then for each glyph to load drives
`Face::outline_glyph` into a `Geometry` that implements
`ttf_parser::OutlineBuilder` ([`src/math.rs`][math], line 343 onward). The
`parallel` feature does this per-glyph work with `rayon`.

`Geometry` flattens quadratics and cubics by recursive midpoint subdivision
until twice the triangle area of the chord falls under `max_area`:

```rust
const ERROR_THRESHOLD: f32 = 3.0; // In pixels.
let max_area = ERROR_THRESHOLD * 2.0 * (units_per_em / scale);
```

— [`src/math.rs`][math], lines 411–412

where `scale` is `FontSettings::scale` (default `40.0` px/em). The flattening
tolerance is therefore baked in at one design size — the field's doc says
glyphs larger than it _"will looks worse but perform slightly better"_
([`src/font.rs`][font], line 161 onward). Segments are split at load into
`v_lines` (vertical) and `m_lines` (sloped), horizontal ones are dropped, the
glyph's total signed area decides whether all points are reversed
(`self.reverse_points = self.area > 0.0`, line 449), and each `Line` caches
its DDA stepping parameters. The parsed `Face` is then discarded; the `Font`
owns `Vec<Glyph>` and no reference to the source bytes.

At render time `rasterize_indexed(index, px)` computes the bitmap box from the
cached bounds, allocates a `Raster` of `w*h+3` `f32`s, walks each line cell by
cell adding `height − height·mid_x` and `height·mid_x` to two adjacent
accumulators (`add`, [`src/raster.rs`][raster], line 41), and
`get_bitmap` prefix-sums each row into `u8` coverage — four lanes at a time
with SSE on x86 ([`src/platform/float/get_bitmap.rs`][getbitmap]).

## Analysis spine

### 1. Layering and ownership

Two public types: `Font` (immutable, `Clone`, owns everything, _"Fonts are
immutable after creation and owns its own copy of the font data"_,
[`src/font.rs`][font], line 187) and `layout::Layout<U>` (a reusable mutable
scratch context). There is no face/sized-font split: size is a `px: f32`
argument on every call, but per-glyph geometry is prepared once for the
`FontSettings::scale` design size, so the "scaled font" is half-baked into the
face. `Font` holds no interior mutability, so `&Font` is shareable across
threads. Errors are `FontResult<T> = Result<T, &'static str>`
([`src/lib.rs`][lib]), with `ttf-parser`'s `FaceParsingError` mapped to fixed
strings. Every rasterization returns a freshly allocated `Vec<u8>`; there is
no caller-supplied buffer and no glyph cache.

### 2. Face loading and table access

Bytes only (`Data: Deref<Target = [u8]>`); `FontSettings::collection_index`
selects a `.ttc` member. Loading is maximally eager: every `cmap`-reachable
glyph (plus `GSUB` outputs) is outlined and flattened, so load cost scales with
glyph count — a CJK font pays for tens of thousands of glyphs it may never
draw. No raw table access is exposed; the inspector-relevant surface is
`name()` (name ID 4 only), `chars()` (the full codepoint→glyph map, i.e.
coverage), `units_per_em()`, `glyph_count()` and `file_hash()`.

### 3. Shaping

None, by stated scope. `GSUB` is read only to decide which glyphs to
pre-flatten so `rasterize_indexed` can draw a ligature glyph an external shaper
picked; no substitution is ever applied. Kerning is `horizontal_kern(left,
right, px)` over fontdue's own `kern` reader (formats 0 and 3,
[`src/table/kern.rs`][kern]) — `GPOS` is not consulted, and `Layout::append`
does not call it at all ([`src/layout.rs`][layout]): layout advances are
`ceil(advance_width)` per `char`, with UAX #14-style line breaking from its
own tables.

### 4. Variation and instances

None. No coordinate parameter exists on `Font` or `FontSettings`, and because
outlines are flattened once at load, supporting variations would require
re-flattening per instance. `ttf-parser` does apply `MVAR` deltas inside
`Face::ascender`, but fontdue never sets coordinates, so the default instance
is all it can render.

### 5. Rasterization and outlines

**Outline API (RQ6).** Not exposed. Outlines exist only as the internal
`Glyph { v_lines, m_lines, bounds }` of pre-flattened, pre-scaled `f32`
segments; a caller wanting curves must go to `ttf-parser` directly.

**CPU raster (RQ2).** The rasterizer is a font-rs-descended signed-area
accumulator: [`src/raster.rs`][raster] is 125 lines and the prefix-sum
[`get_bitmap.rs`][getbitmap] 73 (scalar + SSE), about 200 lines in all, with
curve flattening in [`src/math.rs`][math] (480 lines including point/curve
helpers). The whole crate is 5 060 lines of Rust, 1 520 of which are Unicode
line-break tables. Coverage is `clamp(abs(height) * 255.9, 0, 255)` of the
running sum, so it is a nonzero-like fill on accumulated winding, not exact
per-contour area; hinting is absent by design, output is linear coverage with
no gamma. `rasterize_subpixel` renders at triple horizontal resolution and
returns "swizzled RGB coverage" with no LCD filter
([`src/font.rs`][font], line 616). Positions are whole-pixel: there is no
sub-pixel offset parameter, only the fractional outline origin. No SDF, no
color glyphs (`COLR`, `CBDT`, `sbix`, `SVG ` unread), no atlas —
`GlyphRasterConfig { glyph_index, px, font_hash }` is offered as a hashable
cache key for the caller's own.

**Benchmark claim.** The README claims _"the lowest end to end latency for a
font rasterizer"_ (line 8) and shows only charts. The method, from
[`dev/benches/rasterize.rs`][bench], is Criterion with a 4 s measurement time,
rasterizing every `char` of `"Sphinx of black quartz, judge my vow."` with
Exo2 Regular `.ttf` and `.otf` at 10, 20, 40, 80, 160 and 200 px, against
`rusttype`, `ab_glyph` and FreeType (`load_char(…, RENDER)`). The
[TrueType chart][chartglyf] reads, at 200 px, roughly 235 µs for fontdue,
545 µs for FreeType and about 1 000 µs for `rusttype 0.9.2` and
`ab_glyph 0.2.3`; at 10 px, roughly 15 µs against 45–60 µs. Two caveats are in
the harness itself: fontdue's `FontSettings::scale` is set to the benchmarked
size, and its outline loading and flattening happen in `from_bytes` outside
the timed closure, whereas FreeType's timed loop includes `set_char_size`,
outline load and render. The chart compares a cached-geometry fill against
full decode-and-fill, with years-old competitor versions.

### 6. Metrics and measurement

`horizontal_line_metrics(px)` returns `LineMetrics { ascent, descent,
line_gap, new_line_size }` scaled by `px / units_per_em`
([`src/font.rs`][font], line 376), from `ttf-parser`'s `Face::ascender`,
`descender`, `line_gap` — `OS/2` typo values when `USE_TYPO_METRICS` is set,
else `hhea`, falling back to typo then win values when `hhea` is zero.
`vertical_line_metrics` reads `vhea`. Per-glyph `Metrics` give whole-pixel
`xmin`/`ymin`/`width`/`height` of the bitmap, `f32` `advance_width`/
`advance_height`, and the exact `OutlineBounds` — but those bounds come from
the flattened segments, not `glyf`/`CFF` boxes. No x-height, cap-height,
underline or strikeout metrics.

### 7. Discovery, matching and fallback

Absent. There is no system enumeration or matching. `Layout::append(fonts,
style)` takes a slice of fonts and a `font_index` per `TextStyle`; a missing
codepoint renders glyph 0 of that font. Fallback, if any, is the caller
splitting text into styles by `has_glyph`.

## What it teaches `sparkles:font`

- **Separate "prepare geometry" from "fill" and cache the former per glyph.**
  fontdue's speed is the cached segment list, not the fill loop; a
  `sparkles:font` rasterizer can get the same win lazily, keyed by glyph and
  size bucket, without fontdue's eager whole-font load.
- **The fill core is small.** About 200 lines of signed-area accumulation plus
  a prefix sum is the RQ2 lower bound for an AA CPU rasterizer; the cost is in
  flattening tolerance, winding correctness and hinting, which fontdue skips.
- **Do not bake the flattening tolerance into the face.** A single
  `FontSettings::scale` makes large glyphs coarser; tolerance must follow the
  render size, as FreeType's and stb's do.
- **Benchmark against equal work.** fontdue's headline chart excludes its own
  outline decode; any `sparkles:font` comparison against FreeType must time
  decode + flatten + fill on both sides, or a warmed cache on both.
- **Return coverage into a caller buffer.** A fresh `Vec<u8>` per glyph is
  the shape `@nogc` code cannot use; take an output slice or atlas region.

## Strengths

- No C dependency, `no_std`, triple-licensed, small.
- Fastest per-glyph fill in its class once geometry is cached; SSE prefix sum.
- `Font` is owned, immutable and thread-shareable; no lifetimes.
- `.ttc` index, `GSUB`-reachable glyph loading, `kern` formats 0 and 3.

## Weaknesses

- Eager whole-font flattening; load cost scales with glyph count.
- Flattening tolerance fixed at one design size.
- No shaping, no `GPOS`, no variations, no hinting, no gamma, no LCD filter,
  no color glyphs, no outline API, no sub-pixel positioning.
- `Layout` ignores kerning and rounds advances up to whole pixels.
- Unsafe raster core whose invariants are guarded only by load-time
  sanitization.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                    | Trade-off                                                     |
| ------------------------------------------ | -------------------------------------------- | ------------------------------------------------------------- |
| Flatten every glyph at `from_bytes`        | Render calls touch only cached segments      | Slow, memory-heavy load; no variations; no outline API        |
| Tolerance from `FontSettings::scale`       | One geometry serves all sizes                | Large sizes coarser; caller must guess the design size        |
| Signed-area accumulation + prefix sum      | ~200 lines, SIMD-friendly, exact-ish AA      | Overlap/winding approximated by `abs` of running sum          |
| Own the bytes, drop the `Face`             | No lifetimes; `Font` is `Clone` and `Send`   | No table access afterwards; inspectors must re-parse          |
| No hinting, gamma or LCD filter            | Simplicity; resolution-independent output    | Soft small-size text; colour fringing in `rasterize_subpixel` |
| No shaping; `GSUB` only to pre-load glyphs | Scope limited to a `glyph_brush` replacement | Needs an external shaper for any complex script               |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- [`README.md`][readme] — positioning, non-goal statement, benchmark charts.
- [`src/font.rs`][font] — `Font`, `FontSettings`, `from_bytes`, metrics,
  `rasterize*`.
- [`src/raster.rs`][raster] — the 125-line accumulation rasterizer.
- [`src/platform/float/get_bitmap.rs`][getbitmap] — scalar and SSE prefix sum.
- [`src/math.rs`][math] — `Geometry`, curve flattening, line preparation.
- [`src/layout.rs`][layout] — `Layout`, `TextStyle`, `GlyphRasterConfig`.
- [`src/table/kern.rs`][kern], [`src/table/gsub.rs`][gsub] — own table readers.
- [`dev/benches/rasterize.rs`][bench], [`images/rasterize_glyf.png`][chartglyf]
  — benchmark method and published result.
- [`Cargo.toml`][cargo], [`CHANGELOG.md`][changelog], [`src/lib.rs`][lib].

<!-- References -->

[repo]: https://github.com/mooman219/fontdue
[docsrs]: https://docs.rs/fontdue
[readme]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/README.md
[cargo]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/Cargo.toml
[changelog]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/CHANGELOG.md
[lib]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/src/lib.rs
[font]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/src/font.rs
[raster]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/src/raster.rs
[getbitmap]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/src/platform/float/get_bitmap.rs
[math]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/src/math.rs
[layout]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/src/layout.rs
[kern]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/src/table/kern.rs
[gsub]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/src/table/gsub.rs
[bench]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/dev/benches/rasterize.rs
[chartglyf]: https://github.com/mooman219/fontdue/blob/2924772fb4439b8aca40b1bffca70088acba5a1b/images/rasterize_glyf.png
