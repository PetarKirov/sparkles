# Allsorts (Rust / YesLogic Prince)

An independent (not ported) OpenType parser, shaping engine and subsetter
extracted from the Prince HTML-to-PDF typesetter: hand-written zero-copy
`ReadScope`/`ReadBinary` parsers, a `Font<T: FontTableProvider>` that caches
tables lazily, GSUB/GPOS application over a `Vec` of glyphs, and callback
sinks for outlines and `COLR` paint.

| Field            | Value                                                                                        |
| ---------------- | -------------------------------------------------------------------------------------------- |
| Language         | Rust (edition 2021, MSRV 1.83.0)                                                             |
| License          | Apache-2.0 ([`Cargo.toml`][cargo])                                                           |
| Repository       | [`yeslogic/allsorts`][repo]                                                                  |
| Documentation    | [`README.md`][readme], crate docs in [`src/lib.rs`][lib]; tools in `yeslogic/allsorts-tools` |
| Version at pin   | `0.17.0` ([`Cargo.toml`][cargo])                                                             |
| Category         | parser · shaper                                                                              |
| Layer(s) covered | parse · shape · outline · (subset, instance; no raster, no discovery)                        |
| Pinned revision  | `efab0fc769287f4ced68bbd723c328c9d9b89698` (2026-05-13)                                      |

## Overview

### What it solves

Prince needs to load arbitrary web fonts (TrueType, CFF, WOFF, WOFF2), shape
text in many scripts, and embed subsets into PDF. Allsorts is that need as a
crate: "Font parser, shaping engine, and subsetter for OpenType, WOFF, and
WOFF2 implemented in Rust", which "reached its first release milestone with its
inclusion in Prince 13 in 2019. In Prince it is responsible for all font
loading, and font shaping" ([`README.md`][readme]). It is the second
independent data point (after [`./rustybuzz.md`](./rustybuzz.md)'s port) for
what a non-HarfBuzz shaper costs.

### Design philosophy

Two statements frame the design. The shaper is built from a written
specification rather than from HarfBuzz source:

> The Allsorts shaping engine was developed in conjunction with [a specification
> for OpenType shaping](https://github.com/n8willis/opentype-shaping-documents/),
> which aims to specify OpenType font shaping behaviour.
>
> — [`README.md`][readme]

and the parser is declarative-in-spirit, hand-written-in-fact:

```rust
//! Parse binary data
//!
//! The is module provides the basis for all font parsing in Allsorts. The parsing approach
//! is inspired by the paper,
//! [The next 700 data description languages](https://collaborate.princeton.edu/en/publications/the-next-700-data-description-languages) by Kathleen Fisher, Yitzhak Mandelbaum, David P. Walker.
```

— [`src/binary/read.rs`][read]

The README adds that "the font parsing code is handwritten. It is planned for
this to eventually be replaced by machine generated code via our declarative
data definition language project" (Fathom), and draws the scope line: "Allsorts
does not do font lookup/matching. For this something like font-kit is
recommended" ([`README.md`][readme]).

## How it works

**Read layer.** `ReadScope<'a> { base: usize, data: &'a [u8] }` is a borrowed
window that remembers its absolute offset; `ReadCtxt<'a>` is a cursor over it.
A table type implements `ReadBinary` (`fn read<'a>(ctxt: &mut ReadCtxt<'a>) ->
Result<Self::HostType<'a>, ParseError>`) or `ReadBinaryDep` when parsing needs
arguments (e.g. `InstanceRecord` needs `(instance_size, axis_count)`).
`HostType<'a>` is a generic associated type, so a table can be a borrowing view
(`NameTable<'a>`) or an owned decode; `ReadArray<'a, T>` is a lazily decoded
array over bytes ([`src/binary/read.rs`][read]).

**Container layer.** `scope.read::<FontData<'_>>()` sniffs the magic and
yields `FontData::OpenType | Woff | Woff2`; `table_provider(index)` returns a
boxed `DynamicFontTableProvider` implementing the one trait the rest of the
crate depends on ([`src/font_data.rs`][font-data]):

```rust
pub trait FontTableProvider {
    /// Return data for the specified table if present
    fn table_data(&self, tag: u32) -> Result<Option<Cow<'_, [u8]>>, ParseError>;

    fn has_table(&self, tag: u32) -> bool;
    ...
    fn table_tags(&self) -> Option<Vec<u32>>;
}
```

— [`src/tables.rs`][tables]

`Cow` is the key: OpenType tables are borrowed; WOFF tables are inflated per
request; WOFF2 decompresses the whole Brotli stream up front in
`Woff2Font::read` (`brotli_decompressor::Decompressor`) and reconstructs
transformed `glyf`/`loca` ([`src/woff2.rs`][woff2]).

**Font layer.** `Font::new(provider)` eagerly parses `cmap` (choosing a
subtable), `head`, `maxp`, `hhea`, boxes `hmtx`, and reads the `fvar` axis
count; everything else — `GDEF`, `GSUB`, `GPOS`, `kern`, `morx`, `CFF`,
`CFF2`, `vmtx`, embedded images — is a `LazyLoad<Arc<…>>` filled on first use
([`src/font.rs`][font]).

**Shaping.** `font.map_glyphs(text, script, MatchingPresentation)` produces
`Vec<RawGlyph<()>>`; `font.shape(glyphs, script_tag, opt_lang_tag,
feature_mask, custom_features, tuple, kerning)` runs GSUB (or `morx`), then
GPOS (or `kern` + fallback mark positioning) and returns `Vec<Info>`;
`GlyphLayout::new(&mut font, &infos, direction, vertical).glyph_positions()`
turns `Info` into `GlyphPosition { hori_advance, vert_advance, x_offset,
y_offset }` ([`src/font.rs`][font], [`src/glyph_position.rs`][glyph-position]).

## Analysis spine

### 1. Layering and ownership

| Layer        | Type                                                     | Owns                                                               | Sharing                                |
| ------------ | -------------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------- |
| bytes        | `ReadScope<'a>` / `ReadScopeOwned`                       | borrowed slice + base offset (or a `Box<[u8]>` copy)               | `Copy`                                 |
| container    | `FontData<'a>` → `DynamicFontTableProvider<'a>`          | table directory; WOFF2 decompressed buffer                         | provider is `Send + Sync`              |
| face         | `Font<T: FontTableProvider>`                             | eager `head`/`hhea`/`maxp`/`cmap`/`hmtx`; lazy `Arc` caches        | **`&mut self` for nearly every query** |
| layout cache | `LayoutCache<T> = Arc<LayoutCacheData<T>>`               | parsed GSUB/GPOS + `Mutex`-guarded coverage/classdef/lookup caches | shareable across fonts/threads         |
| workspace    | `Vec<RawGlyph<()>>` → `Vec<Info>` → `Vec<GlyphPosition>` | per call, caller-owned                                             | single-owner                           |

The ownership quirk is `LazyLoad` behind `&mut self`: `lookup_glyph_index`,
`shape`, `horizontal_advance`, `bounding_box` all take `&mut Font`, so one
`Font` cannot shape on two threads; but the expensive part, `LayoutCacheData`,
is an `Arc` with internal `Mutex`es memoizing `(script, lang) → FeatureMask`
and `(script, lang, mask) → lookup list` ([`src/layout.rs`][layout]). Errors
are typed and specific: `ParseError { BadEof, BadValue, BadVersion, BadOffset,
BadIndex, LimitExceeded, MissingValue, MissingTable(u32), CompressionError,
UnsuitableCmap, NotImplemented }`, `ShapingError { ComplexScript, Parse }`
([`src/error.rs`][error]). `shape` "forge[s] ahead in the face of errors
applying what we can", returning `Err((first_error, partial_infos))`
([`src/font.rs`][font]) — a degrade-but-report contract between HarfBuzz's
silence and `rustybuzz`'s refusal.

### 2. Face loading and table access

From bytes only (no path API): `ReadScope::new(&buf).read::<FontData>()`, then
`table_provider(index)` for collections (TTC and WOFF2 collections). Raw tables
are first-class — `provider.table_data(tag)` returns bytes, `table_tags()`
lists them, and every table struct is `pub` under `allsorts::tables`
(`tables::os2`, `tables::cmap`, `tables::colr`, `tables::variable_fonts::{fvar,
avar, gvar, hvar, mvar, stat, cvar}`) ([`src/tables.rs`][tables]). `Font::new`
refuses a font without a usable Unicode `cmap` (`ParseError::UnsuitableCmap`).
WOFF2 costs a full decompression into an owned buffer at read time — the only
non-zero-copy container path.

### 3. Shaping

Input is not a string but `Vec<RawGlyph<()>>` from `map_glyphs`, which already
handles variation selectors and emoji presentation
(`MatchingPresentation::Required` maps an emoji only to a font with color
tables) ([`src/font.rs`][font]). Features are a `FeatureMask =
BitFlags<Feature>` over ~50 known GSUB tags (`default_mask()` = `CCMP | RLIG |
…`), plus `custom_features: &[FeatureInfo { feature_tag, alternate }]` for
arbitrary tags and alternate selection ([`src/gsub.rs`][gsub]). Script and
language are raw OpenType tags (`u32`); direction is only a `GlyphLayout`
parameter. Complex scripts are dispatched to `src/scripts/` — Arabic, Indic
(3 887 lines alone), Khmer, Mongolian, Myanmar, Syriac, Thai/Lao, Tibetan.
Unicode normalization is explicitly unimplemented ([`README.md`][readme]).

**No cluster indices.** Instead of HarfBuzz's `cluster`, each `RawGlyph`
carries `unicodes: TinyVec<[char; 1]>` (the characters it represents) and
`liga_component_pos` ([`src/gsub.rs`][gsub]); mapping back to source offsets
is the caller's job — fine for PDF, awkward for a cursor in `hue`.
Units: font units, `i32` positions, `i16` `kerning` on `Info`
([`src/gpos.rs`][gpos]).

**Line-count evidence** (`find src -name '*.rs' | xargs wc -l` at the pin):

| Part                                                                                                           | Lines  | Share |
| -------------------------------------------------------------------------------------------------------------- | ------ | ----- |
| Total `src/**/*.rs`                                                                                            | 59 466 | 100 % |
| Layout tables + GSUB/GPOS apply (`layout.rs`, `gsub.rs`, `gpos.rs`, `gdef.rs`, `context.rs`, `layout/morx.rs`) | 7 859  | 13 %  |
| Script shapers (`scripts/`)                                                                                    | 8 635  | 15 %  |
| Unicode helpers (`unicode*`)                                                                                   | 598    | 1 %   |
| Other tables (`tables/**`: `cmap`, `glyf`, `colr` 2 484, `morx`, variable fonts 3 677, …)                      | 15 266 | 26 %  |
| CFF/CFF2 parse, charstrings, outlines, subset                                                                  | 9 250  | 16 %  |
| Subsetting (`subset.rs`) + instancing (`variations.rs`)                                                        | 3 288  | 6 %   |
| WOFF + WOFF2                                                                                                   | 1 510  | 3 %   |

The shaping engine proper is ~17 KLOC (29 %), of the same order as
`rustybuzz`'s ~17 KLOC hand-written core, despite independent design — strong
evidence that ~15–20 KLOC is the intrinsic size of an OpenType shaper with
complex-script support.

### 4. Variation and instances

Coordinates are a `Tuple<'a>(&'a [F2Dot14])` (borrowed) or `OwnedTuple`
(`TinyVec<[F2Dot14; 4]>`) of _normalized_ values. `FvarTable::normalize(user_tuple,
avar)` converts 16.16 user values, applies `avar` segment maps, re-clamps, and
converts to 2.14 ([`src/tables/variable_fonts/fvar.rs`][fvar]); `instances()`
iterates named `InstanceRecord`s, and `axis_names()` resolves `STAT`/`name`
([`src/variations.rs`][variations]). The tuple is passed **per call**, not
stored: `shape(…, tuple, …)` uses it for `GSUB`/`GPOS` `FeatureVariations`
([`src/gsub.rs`][gsub]), and `OutlineBuilder::visit(glyph, Option<&OwnedTuple>,
sink)` applies `gvar` / `CFF2` blends ([`src/outline.rs`][outline]). Advances
in `GlyphLayout` come from `hmtx` via `glyph_info::advance` and do not consult
`HVAR` ([`src/font.rs`][font]); `HVAR` is used by the instancer. The instancer,
`variations::instance(provider, user_instance)`, writes a static font
(`Vec<u8>`) — "TrueType fonts with a `gvar` table as well as CFF2 fonts are
supported" ([`src/variations.rs`][variations]).

### 5. Rasterization and outlines

**No rasterizer** — "After shaping, another library such as Pathfinder or
FreeType is responsible for rendering the glyphs" ([`src/lib.rs`][lib]).
Outlines are a callback sink in font units with Pathfinder geometry types:
`OutlineSink { move_to(Vector2F), line_to, quadratic_curve_to(control, to),
cubic_curve_to(LineSegment2F, to), close }`, driven by an `OutlineBuilder`
implemented by `GlyfVisitorContext`, `CFFOutlines` and `CFF2Outlines`
([`src/outline.rs`][outline]). Quadratics stay quadratic. Color:
`Font::visit_colr_glyph(glyph, palette_index, painter)` walks `COLRv0`/`COLRv1`
into a `Painter: OutlineSink` trait (`fill`, `linear_gradient`,
`radial_gradient`, conic, layers) ([`src/tables/colr.rs`][colr]);
`lookup_glyph_image(glyph, target_ppem, max_bit_depth)` returns `CBDT`/`sbix`
bitmaps or `SVG` documents, filtered by `set_embedded_image_filter`
([`src/font.rs`][font]). No atlas, hinting, or gamma.

### 6. Metrics and measurement

All raw: `hhea_table.{ascender, descender, line_gap}`, `os2_table()` with
`s_typo_*`, `us_win_*`, `s_x_height`, `s_cap_height`, `fs_selection`,
`us_weight_class`, `us_width_class`, `panose` ([`src/tables/os2.rs`][os2]).
Allsorts does not choose between them — no `USE_TYPO_METRICS` policy.
Per-glyph: `horizontal_advance`, `vertical_advance` (`u16` font units),
`bounding_box` (via outline), `colr_clip_box`.

### 7. Discovery, matching and fallback

**Absent, explicitly** ("does not do font lookup/matching"). The only
fallback-adjacent features are `MatchingPresentation` for emoji and
`lookup_glyph_index` reporting a missing glyph. For RQ5, however, Allsorts
ships an inspector: the `specimen` feature's `font_specimen::specimen(src,
data, SpecimenOptions)` emits an HTML sheet with "glyph coverage, layout
features, style, and type", including script/langsys tables
([`src/font_specimen.rs`][specimen]).

## What it teaches `sparkles:font`

- **A `tag → Cow<bytes>` provider trait is the right seam.** OpenType borrows,
  WOFF/WOFF2 decode, subsetter output re-enters — one D DbI trait over
  `const(ubyte)[]` with an owned fallback mirrors it.
- **GAT host types (`HostType<'a>`) = D templated `read!T(scope)`** returning
  a view struct; the `ReadScope { base, data }` absolute-offset trick makes
  table-relative offsets safe.
- **Do not put lazy caches behind `&mut`.** Allsorts' `&mut self` everywhere
  blocks sharing a face; keep the face immutable and put caches in a
  separately synchronized (or per-thread) object, as its own `LayoutCache` does.
- **Pass coordinates per call or store them — but feed advances too.**
  Allsorts' shaping ignores `HVAR`; a D design must route the same normalized
  coordinates into advances, outlines and `FeatureVariations`.
- **Report partial results with the first error** (`Err((e, partial))`) — a
  good fit for `Expected` in a font explorer that must show broken fonts.
- **Keep cluster offsets.** `unicodes: TinyVec<char>` is insufficient for
  editors; `hue` needs byte-offset clusters.

## Strengths

- Independent spec-driven shaper with broad script coverage; production-proven
  in Prince since 2019.
- Full container support (TTC, WOFF, WOFF2), subsetting, and variable-font
  instancing in one crate.
- Precise typed errors and degrade-but-report shaping.
- All tables public; HTML specimen generator doubles as an inspector.

## Weaknesses

- `&mut Font` for queries prevents concurrent use of one face.
- No cluster indices, no Unicode normalization, direction only at positioning.
- Shaping advances ignore `HVAR`; variable CFF instancing partly
  `NotImplemented` per `VariationError`.
- Fixed `Feature` enum plus a side channel for custom tags.
- WOFF2 is decompressed whole at parse time.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                        | Trade-off                                                   |
| ----------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------- |
| Shaper from the opentype-shaping-documents spec | Independent implementation, documented behaviour | Divergence from HarfBuzz; HarfBuzz used only as test oracle |
| Hand-written `ReadBinary` parsers               | Zero-copy views with GATs                        | ~60 KLOC of manual code; Fathom codegen still "planned"     |
| `FontTableProvider` returning `Cow`             | One code path for OTF/WOFF/WOFF2/subset          | WOFF2 must be fully decompressed                            |
| `LazyLoad` caches behind `&mut self`            | Simple lazy init without locks                   | A `Font` is not shareable across threads                    |
| Tuple passed per call                           | Stateless face; any instance per call            | Easy to forget for advances (`HVAR` not applied)            |
| `RawGlyph.unicodes` instead of clusters         | PDF text extraction needs chars, not offsets     | Editors must rebuild cluster mapping                        |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Positioning** — [`README.md`][readme], [`Cargo.toml`][cargo], [`src/lib.rs`][lib].
- **Parsing** — [`src/binary/read.rs`][read], [`src/tables.rs`][tables],
  [`src/font_data.rs`][font-data], [`src/woff2.rs`][woff2],
  [`src/tables/os2.rs`][os2], [`src/error.rs`][error].
- **Shaping** — [`src/font.rs`][font], [`src/gsub.rs`][gsub], [`src/gpos.rs`][gpos],
  [`src/layout.rs`][layout], [`src/glyph_position.rs`][glyph-position].
- **Variations, outlines, color** — [`src/tables/variable_fonts/fvar.rs`][fvar],
  [`src/variations.rs`][variations], [`src/outline.rs`][outline],
  [`src/tables/colr.rs`][colr].
- **Inspector** — [`src/font_specimen.rs`][specimen].
- Siblings: [`./rustybuzz.md`](./rustybuzz.md), [`./harfbuzz.md`](./harfbuzz.md),
  [`./ttf-parser.md`](./ttf-parser.md), [`./font-kit.md`](./font-kit.md).

<!-- References -->

[repo]: https://github.com/yeslogic/allsorts
[readme]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/README.md
[cargo]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/Cargo.toml
[lib]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/lib.rs
[read]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/binary/read.rs
[tables]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/tables.rs
[font-data]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/font_data.rs
[woff2]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/woff2.rs
[os2]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/tables/os2.rs
[error]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/error.rs
[font]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/font.rs
[gsub]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/gsub.rs
[gpos]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/gpos.rs
[layout]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/layout.rs
[glyph-position]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/glyph_position.rs
[fvar]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/tables/variable_fonts/fvar.rs
[variations]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/variations.rs
[outline]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/outline.rs
[colr]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/tables/colr.rs
[specimen]: https://github.com/yeslogic/allsorts/blob/efab0fc769287f4ced68bbd723c328c9d9b89698/src/font_specimen.rs
