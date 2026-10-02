# Parley + Fontique (Rust, Linebender)

Linebender's rich-text layout stack: `fontique` enumerates system fonts and
answers fallback queries, `parley` turns styled text into lines, runs and
positioned glyphs via HarfRust (shaping) and Skrifa (metrics), and leaves
rasterization to whoever paints the `Layout`.

| Field            | Value                                                                                          |
| ---------------- | ---------------------------------------------------------------------------------------------- |
| Language         | Rust (edition 2024, MSRV 1.88); `fontique` is `no_std` + `alloc`                               |
| License          | Apache-2.0 OR MIT ([`Cargo.toml`][cargo])                                                      |
| Repository       | [`linebender/parley`][repo]                                                                    |
| Documentation    | Crate docs in [`parley/src/lib.rs`][lib]; stack overview in [`README.md`][readme]; docs.rs     |
| Category         | layout engine · font database/discovery                                                        |
| Layer(s) covered | discover · match/fallback · shape · layout (parse via `read-fonts`/`skrifa`; raster delegated) |
| Version at pin   | workspace `0.11.0`                                                                             |
| Pinned revision  | `dd7e0b04966c2fda89356668e5b5dc46904d45c5` (2026-10-02)                                        |

Size at the pin (`find <dir> -name '*.rs' | xargs wc -l`):

| Crate           | Role                                                           | `.rs` lines |
| --------------- | -------------------------------------------------------------- | ----------- |
| `fontique`      | enumeration, matching, fallback, synthesis                     | 6 119       |
| `parley_engine` | analysis, itemization, HarfRust shaping, shaped text           | 6 660       |
| `parley`        | styles, builders, line breaking, alignment, editing            | 14 006      |
| `parlance`      | shared vocabulary (`Script`, `GenericFamily`, `FontVariation`) | 2 862       |

## Overview

### What it solves

GUI toolkits (Xilem, Masonry, Blitz's WPT-tested HTML engine) need CSS-grade
paragraph layout — bidi, line breaking, per-span font properties, inline
boxes, font fallback — without a C dependency. Parley composes four Rust
crates rather than one monolith, and the README states the division of labour
literally.

### Design philosophy

```text
Parley has four key dependencies: Fontique, HarfRust, Skrifa, and ICU4X. These
crates cover different pieces of the text-rendering process.
...
Fontique provides font enumeration and fallback.
...
The library is responsible for loading fonts into memory; it will use
memory-mapped IO to load portions into memory lazily and share them between
processes on the system.
```

— [`README.md`][readme], lines 19–29

The second governing idea is the context split, from the crate docs:

```rust
//! - [`FontContext`] and [`LayoutContext`] are resources which should be shared globally (or at coarse-grained boundaries).
//!   - [`FontContext`] is database of fonts.
//!   - [`LayoutContext`] is scratch space that allows for reuse of allocations between layouts.
```

— [`parley/src/lib.rs`][lib], lines 7–9

Shaping at this pin is **HarfRust**, not swash: `parley_engine` depends on
`harfrust` and `skrifa` only ([`parley_engine/src/shape/shaper.rs`][shaper]
line 8); `swash` survives as a workspace dependency of the
`examples/swash_render` rasterization demo ([`main.rs`][swash-ex]).

## How it works

`FontContext` is two public fields, `collection: fontique::Collection` and
`source_cache: fontique::SourceCache` ([`parley/src/font.rs`][font-cx]).
`LayoutContext<B>` holds the resolver, style tables, an ICU-backed `Analyzer`
and `Analysis`, and a `Shaper` ([`context.rs`][context], lines 21–45). A
`RangedBuilder` (flat `push(StyleProperty, range)`), `TreeBuilder` (nested
spans) or `StyleRunBuilder` resolves styles, then `build(&text)` runs analysis
(bidi, script, segmentation, emoji), itemizes, selects a font per character
cluster, shapes each single-font run, and returns `Layout<B>`. Line breaking
(`break_all_lines(max_width)`) and `align(...)` can be repeated on the same
`Layout`; a text or style change requires a new builder. Iteration is
`layout.lines()` → `line.items()` → `PositionedLayoutItem::GlyphRun` or
`InlineBox` → glyphs, each `Glyph { id: u32, x, y, advance: f32 }`
([`parley_engine/src/glyph.rs`][glyph]).

## Analysis spine

### 1. Layering and ownership

| Layer          | Type(s)                                                             | Owner / lifetime                                |
| -------------- | ------------------------------------------------------------------- | ----------------------------------------------- |
| Font bytes     | `Blob<u8>` (`linebender_resource_handle`, `Arc` + `u64` id)         | refcounted; mmap'd by `SourceCache`             |
| Font manager   | `fontique::Collection`, `SourceCache`                               | `Clone`; optional `Arc<Mutex<…>>` shared store  |
| Face reference | `FontInfo` (metadata), `QueryFont`, `FontInstance{font, synthesis}` | value types holding a `Blob` + collection index |
| Shaper state   | `Shaper` (three 16-entry LRU caches of HarfRust objects)            | inside `LayoutContext`, `&mut`                  |
| Output         | `Layout<B>` → `Line` → `Run` → `Cluster` → `Glyph`                  | owned by caller, generic over brush `B`         |

There is no sized-font object: size is `ShapeOptions::font_size`, a field of
each shaping call. The parsed-face caches are keyed by **blob id + index**, not
by pointer: `ShapeDataKey { font_blob_id: u64, font_index: u32 }`, and
`ShapeInstanceId` adds `Synthesis` and the variation list
([`cache.rs`][cache], lines 8–47). Thread-safety is by `&mut`: every
`Collection` accessor, even `family_names`, takes `&mut self` because it calls
`sync_shared()` first. With `CollectionOptions { shared: true }`, clones share
an `Arc<Shared>` holding `Mutex` data and an atomic version counter, and each
clone re-syncs lazily ([`collection/mod.rs`][coll], lines 37–58, 251–280); the
doc comment calls sharing _"pure overhead"_ for single-threaded use. Errors are
`Option` throughout; `harfrust::FontRef::from_index(...).unwrap()` with a
`// TODO: How do we want to handle errors like this?` is the shaping path's
error model ([`shaper.rs`][shaper], lines 275–279).

### 2. Face loading and table access

Two sources: `SourceKind::Path` (mmap via `memmap2`, std only) and
`SourceKind::Memory(Blob)`. `FontInfo::from_source(source, index)` parses with
`read-fonts`' `FontRef::from_index` and extracts width/style/weight, `fvar`
axes and a `CharmapIndex` ([`fontique/src/font.rs`][finfo], lines 31–48,
224–254); `scan.rs` walks directories and enumerates every face of a `.ttc`
([`scan.rs`][scan], lines 148–195). Raw tables are not exposed by fontique or
parley — a consumer re-opens `Blob` + index with `skrifa`/`read-fonts`, which
is the intended inspector path. `CharmapIndex` remembers the chosen `cmap`
subtable and maps only formats 4 and 12 ([`charmap.rs`][charmap], lines
80–86).

### 3. Shaping

`Shaper::shape_text` takes the analysed text, a `FontSelector` callback and
`ShapeOptions { font_size, language, features: &[FontFeature], variations:
&[FontVariation] }` ([`shaper.rs`][shaper], lines 25–37). Per run it fetches
three cached HarfRust objects — `ShaperData` (per face), `ShaperInstance`
(per face × variations), `ShapePlan` (per instance × script × language ×
direction × features):

```rust
pub struct Shaper {
    shape_data_cache: LruCache<cache::ShapeDataKey, harfrust::ShaperData>,
    shape_instance_cache: LruCache<cache::ShapeInstanceId, harfrust::ShaperInstance>,
    shape_plan_cache: LruCache<cache::ShapePlanId, harfrust::ShapePlan>,
    unicode_buffer: Option<harfrust::UnicodeBuffer>,
    features: Vec<harfrust::Feature>,
    char_cluster: CharCluster,
}
```

— [`shaper.rs`][shaper], lines 87–94 (`MAX_ENTRIES = 16`, line 98)

Features are OpenType tag/value pairs applied to the whole item (later
duplicates win). The buffer uses `BufferClusterLevel::MonotoneCharacters`, so
glyph clusters map back to UTF-8 byte ranges; `Cluster` exposes text range,
visual order and ligature components. Output is pixels at `font_size`, with
optional quantization (`quantize: bool` on the builders).

### 4. Variation and instances

Coordinates enter from two places and are concatenated in a fixed order:
`fontique::Synthesis::variation_settings()` first, then the style's
`StyleProperty::FontVariations` (accepts a CSS `font-variation-settings`
string or a `&[FontVariation]` list, [`style/font.rs`][style-font]):

```rust
fn variations_iter<'a>(
    synthesis: &'a fontique::Synthesis,
    item: &'a [FontVariation],
) -> impl Iterator<Item = harfrust::Variation> + 'a {
    synthesis
        .variation_settings()
        .iter()
        .map(|(tag, value)| harfrust::Variation { tag: *tag, value: *value })
        .chain(item.iter().map(|variation| harfrust::Variation {
            tag: harfrust::Tag::new(&variation.tag.to_bytes()),
            value: variation.value,
        }))
}
```

— [`shaper.rs`][shaper], lines 433–450 (lightly reflowed)

User-space values go into `harfrust::ShaperInstance::from_variations`; the
**normalized** coordinates it computes (`avar` applied) are stored on the run
(`harf_shaper.coords()`, line 372) and surface as
`Run::normalized_coords() -> &[NormalizedCoord]` ([`run.rs`][run], line 111).
Metrics recompute the location independently through
`skrifa`'s `font_ref.axes().location(...)` ([`shaped_text.rs`][shaped],
lines 82–99). The rasterizer receives the run's normalized coords — the swash
example passes `.normalized_coords(normalized_coords.iter().map(|c|
c.to_bits()))` to its `Scaler` ([`main.rs`][swash-ex], lines 250–261). So the
contract is: user coords in, `F2Dot14` normalized coords out per run, handed
to any rasterizer. `FontInfo::axes()` exposes `fvar` min/default/max; named
instances and `STAT` are not read.

`Synthesis` is the novel piece: when a requested attribute differs from the
face, fontique prefers a real axis over faking. A requested weight sets `wght`
whenever the axis default differs (even 400 vs a `wght` default of 100);
without an axis and more than 200 units short, it sets `embolden`. Italic tries
`ital=1`, then `slnt=14`, then `skew=14`° ([`font.rs`][finfo], lines 90–150).

### 5. Rasterization and outlines

Absent by design — Parley ends at positioned glyph ids plus
`Run::synthesis()` (embolden/skew hints) and `normalized_coords()`. Outlines,
hinting, AA and color glyphs belong to the painter: the repo ships
`swash_render`, `tiny_skia_render` and `vello_cpu_render` examples, and
[`vello`](./vello.md) consumes runs via `skrifa`. CoreText fallback carries a
telling hack: _"if we don't have a usable PingFangUI due to our inability to
render hvgl outlines then try another font"_ ([`coretext.rs`][ct], lines
79–85) — fallback is constrained by what the downstream rasterizer can draw.

### 6. Metrics and measurement

`FontMetrics { ascent, descent, leading, underline_*, strikethrough_*,
cap_height, x_height }` is built from `skrifa::metrics::Metrics::new(font,
Size::new(font_size), &location)` — i.e. variation-aware and in pixels, with
skrifa deciding hhea vs `OS/2` typo (`USE_TYPO_METRICS`) ([`shaped_text.rs`][shaped],
lines 32–52, 95–125). Missing underline/strikeout fall back to HarfBuzz's
defaults (`units_per_em / 18`), and a source `TODO` admits these stay in design
units while the other fields are scaled. Layout-level metrics are
`LineMetrics { line_height, baseline, offset, advance, hanging_advance, … }`
([`line.rs`][line], lines 159–185) and `SpanMetrics { ascent, descent,
x_height }`.

### 7. Discovery, matching and fallback

Discovery is per-platform behind one `system` module selected by `cfg`
([`backend/mod.rs`][backend]): fontconfig on Linux/FreeBSD (linked or
`fontconfig-dlopen`), CoreText enumeration plus a `Library/Fonts` scan on
Apple, DirectWrite on Windows, and `$ANDROID_ROOT/etc/fonts.xml` parsed with
`roxmltree` on Android. Families get a `FamilyId`; `GenericFamily` is the CSS
set plus `UiRounded`, `Emoji`, `Math` ([`generic_family.rs`][generic]).

Matching is the CSS Fonts 4 algorithm over a family's `FontInfo` list
(`match_font`, [`matching.rs`][matching], 483 lines). A `Query` takes a family
list, `Attributes { width, style, weight }` and a `FallbackKey { script,
locale }`; `matches_with(|font| QueryStatus)` yields candidates from the
requested families then the fallback families
([`query.rs`][query], lines 96–170). Every query also appends the `Hani`
fallback to catch CJK punctuation in `Common` (issue 597 hack, lines 105–112).
Fallback families are resolved **per script + locale**, each backend in its
own way:

| Backend     | Fallback mechanism                                                                       |
| ----------- | ---------------------------------------------------------------------------------------- |
| fontconfig  | `FcPattern` with `FC_LANG` + an `FcCharSet` of the script's sample chars → `FcFontMatch` |
| CoreText    | `CTFontCreateForString` (`…WithLanguage` when a locale is set) on the sample string      |
| DirectWrite | `IDWriteFontFallback::MapCharacters` over the sample                                     |
| Android     | locale table, then script table, then first sans-serif                                   |

The per-script sample strings live in `SCRIPT_SAMPLES` ([`script.rs`][script]).
Parley then chooses **per character cluster**: in `select_font` it scores each
query candidate by `cluster.calculate_coverage(charmap.map(ch) != 0)` and keeps
the best; emoji clusters append `GenericFamily::Emoji`; a last-resort "any
font" is cached when nothing has a charmap ([`parley/src/shape/mod.rs`][pshape],
lines 318–420). Classification is `OS/2` `usWidthClass`, `fsSelection`
italic/oblique, `post.italicAngle`, and weight — no PANOSE.

## What it teaches `sparkles:font`

- **Two contexts, not one**: a long-lived font database (`FontContext`) and a
  reusable scratch arena (`LayoutContext`) passed by `ref` to builders. In D,
  that is `FontCollection` + a `UniqueBuffer`-backed `LayoutScratch`.
- **Key caches by blob id + face index, not by pointer**, and split shaping
  state into per-face / per-instance / per-plan caches with an LRU bound — the
  HarfBuzz `hb_face_t`/`hb_font_t`/`hb_shape_plan_t` split, made explicit.
- **`Synthesis` as data**: matching returns "set `wght`=600" or "embolden" /
  "skew 14°" as a value the shaper and rasterizer both consume. `hue`'s
  bold/italic face selection should return this, not a boolean.
- **Fallback = script sample string → platform matcher → family id**, then
  per-cluster charmap coverage scoring. Probe with a sample, cache by
  `(script, locale)`, decide per cluster.
- **Hand the rasterizer normalized coords per run**, never re-derive them; the
  layout output must carry `normalizedCoords` alongside glyph ids.

## Strengths

- Clean crate seams: discovery, shaping engine, layout and vocabulary are
  separately usable; `fontique` is `no_std`.
- Real system fallback on all four target platforms, including Android
  `fonts.xml`.
- Variation-aware end to end: synthesis, shaping, metrics and the per-run
  coordinate hand-off agree.
- CSS-conformant matching; tested against WPT via Blitz.
- Lazy mmap loading and `Blob` sharing across clones.

## Weaknesses

- No raw table, feature-list or name-table API: an inspector must bypass it.
- `Collection` read accessors require `&mut`; sharing needs `Mutex` + resync.
- `unwrap()` on malformed faces in the shaping path.
- Fallback is per script, not per codepoint, until cluster coverage scoring;
  hacks (`Hani` always appended, PingFang `hvgl`) show the seams.
- No named instances or `STAT`; underline metrics left in design units.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                             | Trade-off                                           |
| ------------------------------------------------------ | ----------------------------------------------------- | --------------------------------------------------- |
| Separate `fontique` (discovery) from `parley` (layout) | Reuse discovery without layout; `no_std` core         | Two contexts to thread through every call           |
| HarfRust for shaping, Skrifa for metrics               | Pure-Rust HarfBuzz parity; one fontations parser      | Two parses of the same blob (`harfrust` + `skrifa`) |
| Size as a call parameter, caches keyed by blob id      | No sized-font lifetime; cheap clones                  | 16-entry LRU can thrash with many faces × instances |
| `Synthesis` returned by matching                       | Prefer real axes over fake bold/italic                | Renderer must honour `embolden`/`skew` itself       |
| Script-sample fallback via platform matchers           | Reuses OS policy (fontconfig rules, CoreText cascade) | Platform-dependent results; locale-only on Android  |
| No rasterization                                       | Painters (vello, swash, tiny-skia) differ             | Every consumer re-solves glyph caching              |
| `Layout` rebreakable but not restylable                | Cheap resize reflow                                   | Any edit rebuilds the layout                        |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- [`README.md`][readme] — the four-crate stack description.
- [`parley/src/lib.rs`][lib], [`context.rs`][context], [`font.rs`][font-cx] — contexts and builders.
- [`parley_engine/src/shape/shaper.rs`][shaper], [`cache.rs`][cache],
  [`shaped_text.rs`][shaped], [`glyph.rs`][glyph] — HarfRust shaping, caches, metrics.
- [`parley/src/shape/mod.rs`][pshape] — per-cluster font selection.
- [`parley/src/layout/run.rs`][run], [`line.rs`][line], [`style/font.rs`][style-font].
- [`fontique/src/collection/mod.rs`][coll], [`query.rs`][query],
  [`font.rs`][finfo], [`matching.rs`][matching], [`charmap.rs`][charmap],
  [`script.rs`][script], [`scan.rs`][scan], [`source_cache.rs`][srccache].
- Backends: [`mod.rs`][backend], [`fontconfig.rs`][fc], [`coretext.rs`][ct],
  [`dwrite.rs`][dw], [`android.rs`][android].
- [`parlance/src/generic_family.rs`][generic]; [`examples/swash_render/src/main.rs`][swash-ex].

<!-- References -->

[repo]: https://github.com/linebender/parley
[cargo]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/Cargo.toml
[readme]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/README.md
[lib]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley/src/lib.rs
[context]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley/src/context.rs
[font-cx]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley/src/font.rs
[shaper]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley_engine/src/shape/shaper.rs
[cache]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley_engine/src/shape/cache.rs
[shaped]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley_engine/src/shape/shaped_text.rs
[glyph]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley_engine/src/glyph.rs
[pshape]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley/src/shape/mod.rs
[run]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley/src/layout/run.rs
[line]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley/src/layout/line.rs
[style-font]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parley/src/style/font.rs
[coll]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/collection/mod.rs
[query]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/collection/query.rs
[finfo]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/font.rs
[matching]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/matching.rs
[charmap]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/charmap.rs
[script]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/script.rs
[scan]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/scan.rs
[srccache]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/source_cache.rs
[backend]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/backend/mod.rs
[fc]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/backend/fontconfig.rs
[ct]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/backend/coretext.rs
[dw]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/backend/dwrite.rs
[android]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/fontique/src/backend/android.rs
[generic]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/parlance/src/generic_family.rs
[swash-ex]: https://github.com/linebender/parley/blob/dd7e0b04966c2fda89356668e5b5dc46904d45c5/examples/swash_render/src/main.rs
