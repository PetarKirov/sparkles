# swash (Rust)

A pure-Rust shaper, scaler and introspection crate built around one rule: the
font is a borrowed `FontRef` with no caches, and every cache and scratch buffer
lives in a per-thread _context_ (`ShapeContext`, `ScaleContext`) that the caller
owns.

| Field            | Value                                                                                                             |
| ---------------- | ----------------------------------------------------------------------------------------------------------------- |
| Language         | Rust (edition 2021, `no_std` + `alloc` capable via the `libm` feature)                                            |
| License          | Apache-2.0 OR MIT ([`Cargo.toml`][cargo])                                                                         |
| Repository       | [`dfrg/swash`][repo]                                                                                              |
| Documentation    | [`README.md`][readme]; module-level guides in [`src/shape/mod.rs`][shape-mod] and [`src/scale/mod.rs`][scale-mod] |
| Version at pin   | `0.2.10` ([`Cargo.toml`][cargo]); depends on `skrifa` `>= 0.31.1, <= 0.44`, `zeno` `0.3.3`, `yazi` `0.2.1`        |
| Category         | shaper · rasterizer                                                                                               |
| Layer(s) covered | parse · shape · outline · raster · metrics (no discovery, no layout)                                              |
| Pinned revision  | `7773843df0d63cd468db61a29c152b5e7a99d4ab` (2026-07-17)                                                           |

## Overview

### What it solves

`swash` takes a font file's bytes and answers three kinds of question without
any other font library: what is in the font (names, axes, instances, writing
systems, features, palettes, strikes, metrics), how a run of clusters maps to
positioned glyphs (OpenType `GSUB`/`GPOS`, AAT `morx`/`kerx`, the Universal
Shaping Engine, Arabic joining), and what a glyph looks like at a size (hinted
outline or rendered alpha / subpixel / color image). It is the rasterizer under
[`cosmic-text`](./cosmic-text.md), which at its pin
(`f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6`) calls `ScaleContext::builder` and
`Render::render` in `src/swash.rs` but shapes elsewhere.

Size at the pin, counted with `find <dir> -name '*.rs' | xargs wc -l`:

| Directory       | Lines  | Content                                                                                           |
| --------------- | ------ | ------------------------------------------------------------------------------------------------- |
| whole crate     | 26 528 |                                                                                                   |
| `src/shape/`    | 4 721  | buffer, cluster output, OpenType (`at.rs`) and AAT (`aat.rs`) engines                             |
| `src/scale/`    | 2 693  | scaler, render, color layers, bitmap decode (PNG), hinting cache                                  |
| `src/internal/` | 5 412  | the private table readers (`cmap`, `glyf`, `head`, `var`, `xmtx`, `at`, `aat`)                    |
| `src/text/`     | 8 816  | Unicode properties, cluster parser, composition, line/word analysis; mostly generated data tables |

The shaper is under 5 KLOC of hand-written code because the script-specific
logic lives in the cluster parser under `src/text/cluster/` and the lookup
application in `src/internal/at.rs`. Outline loading and hinting are no longer
`swash`'s own: the `Scaler` builds a `skrifa::FontRef` and draws through
`skrifa`'s `OutlineGlyphCollection` (see [`./fontations.md`](./fontations.md)).
The rasterizer is the separate `zeno` crate.

### Design philosophy

The README's "General features" list is the ownership model:

> - Simple borrowed font representation that imposes no requirements on resource
>   management leading to...
> - Thread friendly architecture. Acceleration structures are completely separate from
>   font data and can be retained per thread, thrown away and rematerialized at any
>   time
> - Zero transient heap allocations. All scratch buffers and caches are maintained by
>   contexts. Resources belonging to evicted cache entries are immediately reused
>
> — [`README.md`][readme]

Its non-goals are equally explicit: text layout ("highly application
specific") and composition ("Glyph caching, geometry batching and rendering all
belong here and should integrate well with the application and the hardware
environment") are left to the caller ([`README.md`][readme]).

## How it works

Three tiers of type, one per lifetime:

- **Data.** `FontDataRef<'a>` validates a file or collection
  (`is_collection`, `len`, `get(index)`, `fonts()`); `FontRef<'a> { data,
offset, key }` names one face by the byte offset of its table directory and a
  `CacheKey` ([`src/font.rs`][font-rs]). The doc comment warns that "internal
  references in the font are stored relative to the base of the file, so the
  entire file must be kept in memory and it is an error to slice the data at
  the offset."
- **Proxies.** `CharmapProxy`, `MetricsProxy`, `VariationsProxy`,
  `BitmapStrikesProxy` and the internal `ColorProxy` are small `Copy` structs
  holding table offsets. `CharmapProxy::from_font(&font)` is computed once and
  `materialize(&font)` rebuilds a borrowed `Charmap<'a>` in O(1)
  ([`src/charmap.rs`][charmap-rs], [`src/variation.rs`][variation-rs]). A
  caller keeps the proxy next to its owned bytes and re-borrows.
- **Contexts.** `ShapeContext` owns an LRU `FontCache<FontEntry>` and a
  `FeatureCache` (max entries clamped to `1..=64`, default 16) plus scratch
  buffers; `ScaleContext` owns the outline/image scratch and a `HintingCache`.
  The `CacheKey` is a process-global `AtomicUsize` counter
  ([`src/cache.rs`][cache-rs]), so cache identity is "this `FontRef` was made
  from that file once", not a content hash.

A `ShaperBuilder` or `ScalerBuilder` is obtained from `context.builder(font)`
and borrows the context mutably; `build()` returns a `Shaper<'a>` / `Scaler<'a>`
that is used and dropped.

## Analysis spine

### 1. Layering and ownership

| Layer            | Type                                        | Owns                                               | Lifetime                                            |
| ---------------- | ------------------------------------------- | -------------------------------------------------- | --------------------------------------------------- |
| bytes            | caller's `Vec<u8>` / mmap                   | everything                                         | caller                                              |
| face view        | `FontRef<'a>`                               | nothing (`&'a [u8]`, `offset`, `key`)              | transient, `Copy`                                   |
| table views      | `Charmap<'a>`, `Variations<'a>`, `Metrics`  | nothing / plain values                             | transient                                           |
| retained offsets | `*Proxy`                                    | `u32` table offsets                                | caller keeps next to the bytes                      |
| shaper           | `ShapeContext` → `ShaperBuilder` → `Shaper` | LRU per-font feature maps, glyph buffer, coords    | context per thread; shaper per run                  |
| scaler           | `ScaleContext` → `ScalerBuilder` → `Scaler` | outline/image scratch, LRU of 8 `HintingInstance`s | context per thread; scaler per (font, size, coords) |
| raster           | `zeno::Mask` (inside `Render`)              | coverage scratch                                   | per call                                            |

Thread-safety is by construction: nothing shared is mutable, and the module
docs instruct "if doing multithreaded glyph rasterization, one instance per
thread" ([`src/scale/mod.rs`][scale-mod]) and "If you're doing multithreaded
layout, you should keep a context per thread" ([`src/shape/mod.rs`][shape-mod]).
The error model is `Option` throughout: `FontRef::from_index` returns `None`
for a non-font, `scale_outline` returns `None` "if an outline was not available
or if there was an error during the scaling process". Every producing call has
an `_into` twin (`scale_outline_into`, `render_into`) that refills a
caller-owned `Outline` / `Image`.

### 2. Face loading and table access

Bytes only — there is no path or file API. `FontRef::from_index(data, index)`
and `from_offset(data, offset)` locate a face; `FontDataRef::fonts()` iterates a
`ttc`/`otc`. Validation is shallow and every table is read lazily by offset from
the `internal` readers. Raw access is one call, `FontRef::table(tag) ->
Option<&'a [u8]>` ([`src/lib.rs`][lib-rs]); there is no table-directory iterator,
so an inspector must parse the directory itself or go through `skrifa`.
`glyph_name` exists but is flagged "an internal function used for testing and
stability is not guaranteed".

### 3. Shaping

The builder sets one _item_: `script(Script)`, `language(Option<Language>)`,
`direction(Direction)`, `size(ppem)`, `features(…Setting<u16>)`,
`variations(…Setting<f32>)` or `normalized_coords(…)`,
`insert_dotted_circles`, `retain_ignorables` ([`src/shape/mod.rs`][shape-mod]).
A feature value of `0` disables, non-zero enables or selects an alternate;
absent features are ignored. Itemization (splitting by script, font, bidi
level) is declared out of scope.

Input is either `add_str(&str)` or, the interesting path, `add_cluster(&CharCluster)`.
The caller runs `text::cluster::Parser` over `Token { ch, offset, len, info,
data }` — offsets and lengths in _the caller's_ code units (UTF-8 or UTF-16),
`data` a pass-through `u32` such as a style-span index. `CharCluster::map`
maps each character to a nominal glyph and returns `Status::Complete`,
`Keep` or `Discard`, which is the documented hook for per-cluster fallback:

```rust
fn select_font<'a>(fonts: &[FontRef<'a>], cluster: &mut CharCluster) -> Option<usize> {
    let mut best = None;
    for (i, font) in fonts.iter().enumerate() {
        let charmap = font.charmap();
        match cluster.map(|ch| charmap.map(ch)) {
            // This font provided a glyph for every character
            Status::Complete => return Some(i),
            // This font provided the most complete mapping so far
            Status::Keep => best = Some(i),
            // A previous mapping was more complete
            Status::Discard => {}
        }
    }
    best
}
```

— [`src/shape/mod.rs`][shape-mod]

`CharCluster` keeps both composed and decomposed forms so each candidate font
is tried with the form it covers. Output is pushed, not returned:
`shape_with(|cluster: &GlyphCluster| …)` yields `GlyphCluster { source:
SourceRange, info: ClusterInfo, glyphs: &[Glyph], components: &[SourceRange],
data }`, with `Glyph { id, info, x, y, advance, data }` in `f32`
([`src/shape/cluster.rs`][cluster-rs]). Units: pixels at `size`, or font units
when `size` is `0` (the default). Ligature components carry their own source
ranges, so caret positions inside a ligature are recoverable. RTL runs are
_not_ reversed: "for correctness, line breaking must be done in logical order
and reversing runs should occur during bidi reordering" — and the caller must
reverse clusters, not glyphs.

### 4. Variation and instances

Introspection: `FontRef::variations()` yields `Variation { index, tag, name_id,
name(lang), is_hidden, min_value, default_value, max_value, normalize(value) }`;
`instances()` yields `Instance { name, postscript_name, values(),
normalized_coords() }` with `find_by_name` / `find_by_postscript_name`
([`src/variation.rs`][variation-rs]). `normalize` clamps, maps to `[-1, 1]`
and applies the `avar` v1 segment map through `skrifa`'s `Avar` reader
([`src/internal/var.rs`][var-rs]); there is no `avar` v2.

Flow: coordinates are `NormalizedCoord` (`i16`, 2.14) slices passed
explicitly. The shaper's `variations()` normalizes once; `Shaper::normalized_coords()`
returns the result, and the scale-module docs recommend feeding exactly that
slice to `ScalerBuilder::normalized_coords` because "a sequence of `i16` is more
compact and easier to fold into a key in a glyph cache"
([`src/scale/mod.rs`][scale-mod]). `FontRef::metrics(coords)` and
`glyph_metrics(coords)` take the same slice (`MVAR`, `HVAR` via
`advance_delta`/`sb_delta`). Inside the scaler the slice becomes a
`skrifa::instance::LocationRef` for `gvar`/`CFF2`. `Attributes::synthesize`
compares requested stretch/weight/style with the face and the presence of
`wdth`/`wght`/`slnt`/`ital` axes and returns a `Synthesis` (variation settings
to apply, embolden yes/no, skew angle) ([`src/attributes.rs`][attributes-rs]).

### 5. Rasterization and outlines

`ScalerBuilder` takes `size(ppem)`, `hint(bool)`, `variations` /
`normalized_coords`. With hinting on, `build()` looks up or reconfigures a
`skrifa::outline::HintingInstance` in an 8-entry LRU keyed by `(font id, size,
coords)`. The mode is a crate constant, not a caller choice:

```rust
const HINTING_MODE: HintingMode = HintingMode::Smooth {
    lcd_subpixel: Some(LcdLayout::Horizontal),
    preserve_linear_metrics: true,
};
```

— [`src/scale/hinting_cache.rs`][hinting-rs]

So `swash` exposes only "smooth, vertical-only, linear advances" hinting, which
is the README's "Asymmetric vertical hinting".

Outlines: `scale_outline(glyph)` returns an owned `Outline` — `points(): &[Point]`
plus `verbs(): &[Verb]`, `bounds()`, `transform(&Transform)`,
`embolden(x, y)`, and `layers` with `color_index()` for `COLR` glyphs
([`src/scale/outline.rs`][outline-rs]). Internally a private `OutlineWriter`
implements `skrifa::outline::OutlinePen`, keeping `skrifa` "a private
dependency of swash". Units are pixels at `size`, or font units at size `0`.
The path type is iterable (`PathData`), unlike HarfBuzz's sink, and plugs into
`zeno`, `lyon` or Pathfinder.

Rendering: `Render::new(&[Source])` tries sources in priority order —
`Source::ColorOutline(palette)`, `Source::ColorBitmap(StrikeWith)`,
`Source::Bitmap(StrikeWith)`, `Source::Outline` — with `format(Format::Alpha |
Subpixel)`, `offset(Vector)` for fractional positioning, `transform`,
`embolden`, `style` (fill or stroke/dash) and `default_color`
([`src/scale/mod.rs`][scale-mod]). The result is `Image { source, content:
Mask | SubpixelMask | Color, placement: Placement { left, top, width, height },
data: Vec<u8> }` ([`src/scale/image.rs`][image-rs]). Color coverage is
`COLR` v0 layers + `CPAL` only (`ColorProxy::layers` binary-searches the v0
base-glyph records in [`src/scale/color.rs`][color-rs]); `sbix` and `CBDT`
come through `StrikeWith::{ExactSize, BestFit, LargestSize}` with an internal
PNG decoder; there is no `COLRv1` and no `SVG`. No gamma, no atlas: the
subpixel mask is linear coverage and atlas packing is the caller's.

### 6. Metrics and measurement

`FontRef::metrics(coords) -> Metrics` with `units_per_em`, `glyph_count`,
`is_monospace`, `has_vertical_metrics`, `ascent`, `descent`, `leading`,
`vertical_*`, `cap_height`, `x_height`, `average_width`, `max_width`,
`underline_offset`, `strikeout_offset`, `stroke_size`; `.scale(ppem)` converts
from font units ([`src/metrics.rs`][metrics-rs]). Selection is `OS/2`
`sTypo*` when `fsSelection.USE_TYPO_METRICS` is set, otherwise `hhea`
ascender/descender/lineGap; `usWin*` is not surfaced. Descent is stored
positive. `GlyphMetrics` answers per-glyph advances and side bearings, with
synthesized vertical metrics when `vhea`/`vmtx` are absent (README).

### 7. Discovery, matching and fallback

**No discovery and no matching.** The crate enumerates nothing on disk. What it
contributes is the _mechanism_ for per-cluster fallback inside shaping
(`CharCluster::map` + `Status`, §3) and the classification inputs a matcher
needs: `Attributes { stretch, weight, style }` packed in a `u32`, with
`has_weight_variation` etc., and `Attributes::synthesize` for faux bold /
oblique decisions. `cosmic-text` supplies the database (via
[`fontdb`](./fontdb.md)) and the fallback lists.

## What it teaches `sparkles:font`

- **Separate "retained offsets" from "borrowed view".** The `Proxy` →
  `materialize(&font)` pair lets a D owner store a few `uint` offsets beside its
  bytes and rebuild a `scope` view per call, with no self-referential struct —
  a direct fit for `-preview=dip1000`.
- **Put every cache in a caller-owned context, one per thread.** No locks, no
  refcounts, and the context is the natural place for a D `UniqueBuffer`
  scratch arena. A terminal's render thread owns one `ScaleContext`.
- **Feed the shaper clusters, not strings, and let `map` report coverage.**
  `Complete`/`Keep`/`Discard` is the smallest API that makes per-cluster
  fallback cheap; `hue` and the terminal both need it.
- **Normalize once, pass `short[]` everywhere.** The shaper computes the 2.14
  slice; the scaler, metrics and the glyph-cache key reuse it.
- **A priority list of glyph sources** (`ColorOutline`, `ColorBitmap`,
  `Outline`) is a clean answer to emoji in a monospace grid.
- **Do not hard-code the hinting mode.** `swash` does, and a terminal wanting
  full hinting or grayscale-without-LCD cannot ask for it.

## Strengths

- One crate covers introspection, shaping and rendering with zero transient
  allocation and no global state beyond an atomic key counter.
- Cluster-structured output with source ranges, ligature components and user
  data is far easier for an editor than HarfBuzz's flat glyph array.
- AAT `morx` support alongside OpenType, which most non-HarfBuzz shapers lack.
- The `Render` source-priority builder handles emoji fallback inside one glyph.

## Weaknesses

- `COLR` v0 only; no `COLRv1`, no `SVG` glyphs, no `avar` v2.
- Hinting mode fixed to smooth/vertical with horizontal LCD; no autohinter
  switch, no full hinting, no gamma.
- `Option`-only errors; a broken table and a missing glyph look the same.
- Outline loading now delegates to `skrifa`, so the crate is half its own
  parser and half fontations, and two parsers read the same bytes.
- Shaping completeness trails HarfBuzz; ecosystem consumers such as
  `cosmic-text` shape with `harfrust` and keep `swash` only for scaling.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                            | Trade-off                                                      |
| ----------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------- |
| `FontRef` borrows; contexts own caches          | Unopinionated resource management; per-thread contexts need no locks | Caller writes its own owning `Font` type (the docs show how)   |
| `CacheKey` from a global atomic counter         | Cheap identity without hashing the file                              | Same file loaded twice gets two keys and two cache entries     |
| Proxies of table offsets                        | `Copy`-able, storable, O(1) re-materialize                           | Extra API surface: every table has a proxy and a view twin     |
| Cluster-in / cluster-out shaping                | Fallback and source mapping without heuristic re-shaping             | Caller must run the cluster parser to get the benefits         |
| No RTL reversal in the shaper                   | Line breaking must stay in logical order                             | Differs from HarfBuzz; ports must reverse clusters themselves  |
| Outlines via `skrifa`, raster via `zeno`        | Reuse a maintained hinting engine; keep rasterizer generic           | Hinting mode not exposed; dependency on `skrifa` version range |
| Owned `Outline` / `Image` with `_into` variants | Iterable path data; buffer reuse                                     | Allocation unless the caller keeps the buffers                 |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Overview** — [`README.md`][readme], [`Cargo.toml`][cargo], [`src/lib.rs`][lib-rs].
- **Data and proxies** — [`src/font.rs`][font-rs], [`src/cache.rs`][cache-rs],
  [`src/charmap.rs`][charmap-rs], [`src/variation.rs`][variation-rs],
  [`src/attributes.rs`][attributes-rs], [`src/metrics.rs`][metrics-rs],
  [`src/strike.rs`][strike-rs], [`src/internal/var.rs`][var-rs].
- **Shaping** — [`src/shape/mod.rs`][shape-mod], [`src/shape/cluster.rs`][cluster-rs],
  [`src/text/cluster/`][text-cluster].
- **Scaling** — [`src/scale/mod.rs`][scale-mod], [`src/scale/outline.rs`][outline-rs],
  [`src/scale/image.rs`][image-rs], [`src/scale/color.rs`][color-rs],
  [`src/scale/hinting_cache.rs`][hinting-rs].
- **Consumer** — `cosmic-text` `src/swash.rs` at
  `f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6` ([link][cosmic-swash]).
- Siblings: [`./fontations.md`](./fontations.md), [`./cosmic-text.md`](./cosmic-text.md),
  [`./harfbuzz.md`](./harfbuzz.md), [`./rustybuzz.md`](./rustybuzz.md),
  [`./fontdb.md`](./fontdb.md).

<!-- References -->

[repo]: https://github.com/dfrg/swash
[readme]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/README.md
[cargo]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/Cargo.toml
[lib-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/lib.rs
[font-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/font.rs
[cache-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/cache.rs
[charmap-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/charmap.rs
[variation-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/variation.rs
[attributes-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/attributes.rs
[metrics-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/metrics.rs
[strike-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/strike.rs
[var-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/internal/var.rs
[shape-mod]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/shape/mod.rs
[cluster-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/shape/cluster.rs
[text-cluster]: https://github.com/dfrg/swash/tree/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/text/cluster
[scale-mod]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/scale/mod.rs
[outline-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/scale/outline.rs
[image-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/scale/image.rs
[color-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/scale/color.rs
[hinting-rs]: https://github.com/dfrg/swash/blob/7773843df0d63cd468db61a29c152b5e7a99d4ab/src/scale/hinting_cache.rs
[cosmic-swash]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/swash.rs
