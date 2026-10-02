# Fontations (Rust / Google Fonts)

Google's memory-safe replacement for FreeType's parsing and scaling half: a
code-generated, zero-copy table reader (`read-fonts`) under a mid-level
metadata-and-outline library (`skrifa`) that hands every glyph to a caller-owned
pen or painter — and never rasterizes, shapes or discovers fonts itself.

| Field            | Value                                                                                                                                   |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Rust (edition 2021, `rust-version = "1.85"`; `#![forbid(unsafe_code)]`, `no_std` + `alloc`)                                             |
| License          | MIT OR Apache-2.0 ([`Cargo.toml`][cargo])                                                                                               |
| Repository       | [`googlefonts/fontations`][repo]                                                                                                        |
| Documentation    | [`README.md`][readme], [`skrifa/README.md`][skrifa-readme], [`read-fonts/README.md`][rf-readme], [`docs/codegen-tour.md`][codegen-tour] |
| Version at pin   | `read-fonts` 0.44.0, `skrifa` 0.47.0                                                                                                    |
| Category         | parser                                                                                                                                  |
| Layer(s) covered | parse · outline · metrics (hinting incl. an autohinter; color paint traversal; no raster, no shape, no discover)                        |
| Pinned revision  | `f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be` (2026-10-01)                                                                                 |

## Overview

### What it solves

The workspace splits the FreeType role into crates with one job each
([`README.md`][readme]):

- `font-types` — the scalar vocabulary (`F2Dot14`, `Fixed`, `FWord`, `Tag`,
  `GlyphId`, offsets); 3,472 lines.
- `read-fonts` — "a high performance parser, suitable for shaping. In particular
  this means that it performs no allocation and no copying"; 112,574 lines, of
  which 47,581 are generated (`read-fonts/generated/`).
- `write-fonts` — owned, mutable table types that compile back to bytes; 50,022
  lines.
- `skrifa` — the "mid level" library: metadata, charmap, metrics, scaled and
  hinted outlines, `COLR` paint traversal; 38,563 lines, 28,552 of them under
  `skrifa/src/outline/` (the autohinter alone is 9,638).
- `skera` — the subsetter (the brief's `klippa` does not exist at this pin;
  `skera` occupies that slot, built on `skrifa` + `write-fonts`,
  [`skera/README.md`][skera-readme]).
- `fauntlet` — a differential tester that "compare[s] the output of Skrifa and
  FreeType" on outlines and advances ([`fauntlet/README.md`][fauntlet-readme]).

`skrifa`'s stated purpose "is to replace FreeType in Google applications" and
the README links Chrome's memory-safety post; Skia's Fontations backend is the
consumer that ships in Chrome ([`README.md`][readme]). Shaping lives outside the
repository (HarfRust, which `read-fonts` cites in [`src/read.rs`][read-rs]);
`read-fonts` only provides the `GSUB`/`GPOS`/`GDEF` readers it consumes.

### Design philosophy

Tables are typed views over a byte slice, validated only as far as needed to
make every getter safe:

> All tables are newtype structs wrapping what is essentially a byte slice. When
> a table is parsed, we perform _minimal validation_: that is, we ensure that the
> provided data is at least long enough to contain all of the required,
> non-version-dependent fields.
>
> All other validation occurs at runtime. If table data is malformed, and a field
> cannot be read, we will always return a default value.
>
> — [`read-fonts/README.md`][rf-readme]

and at the `skrifa` level, a hard robustness promise: "This library should not
panic regardless of API misuse or use of corrupted/malicious font files"
([`skrifa/README.md`][skrifa-readme]).

## How it works

**Codegen.** Each table is described once in a Rust-like DSL under
`resources/codegen_inputs/` and `font-codegen` (6,150 lines) emits both the
`read-fonts` view and the `write-fonts` owned type. The `hhea` input reads like
the spec ([`resources/codegen_inputs/hhea.rs`][cg-hhea]):

```rust
#[tag = "hhea"]
table Hhea {
    /// The major/minor version (1, 0)
    #[compile(MajorMinor::VERSION_1_0)]
    version: MajorMinor,
    /// Typographic ascent.
    ascender: FWord,
    /// Typographic descent.
    descender: FWord,
    ...
    /// Number of hMetric entries in 'hmtx' table
    number_of_h_metrics: u16,
}
```

The generated reader is a one-field struct whose `FontRead` impl only checks
`data.len() < Self::MIN_SIZE` before returning `Ok(Self { data })`; every getter
then reads a big-endian scalar at a constant offset
([`read-fonts/generated/generated_hhea.rs`][gen-hhea]). The codegen tour shows
the shape: `pub struct MyTable<'a>(FontData<'a>)` with
`pub fn format(&self) -> u16 { self.0.read_at(0) }`
([`docs/codegen-tour.md`][codegen-tour]). Records with fixed layout are
zerocopy-castable packed structs; variable-length records are copied on read.

**Font access.** `FontData<'a>` wraps `&'a [u8]`
([`read-fonts/src/font_data.rs`][font-data]). `FileRef::new` distinguishes a
`.ttc` from a single font; `FontRef::new(data)` and
`FontRef::from_index(data, index)` parse only the table directory, remember
whether it is sorted (binary vs linear search, because "certain fonts don't seem
to follow that requirement"), and `table_data(tag)` slices the record's range
([`read-fonts/src/lib.rs`][rf-lib]). The `TableProvider<'a>` trait — one
required method, `data_for_tag(&self, tag) -> Option<FontData<'a>>` — supplies
`head()`, `hhea()`, `hmtx()`, `fvar()`, `avar()`, … as default methods that
re-parse on every call ([`read-fonts/src/table_provider.rs`][table-provider]).

**`skrifa`.** `MetadataProvider<'a>` is an extension trait on `FontRef`
([`skrifa/src/provider.rs`][provider]):

```rust
pub trait MetadataProvider<'a>: Sized {
    fn attributes(&self) -> Attributes;
    fn axes(&self) -> AxisCollection<'a>;
    fn named_instances(&self) -> NamedInstanceCollection<'a>;
    fn localized_strings(&self, id: StringId) -> LocalizedStrings<'a>;
    fn glyph_names(&self) -> GlyphNames<'a>;
    fn metrics(&self, size: Size, location: impl Into<LocationRef<'a>>) -> Metrics;
    fn glyph_metrics(&self, size: Size, location: impl Into<LocationRef<'a>>) -> GlyphMetrics<'a>;
    fn charmap(&self) -> Charmap<'a>;
    fn outline_glyphs(&self) -> OutlineGlyphCollection<'a>;
    fn color_glyphs(&self) -> ColorGlyphCollection<'a>;
    fn color_palettes(&self) -> ColorPalettes<'a>;
    fn bitmap_strikes(&self) -> BitmapStrikes<'a>;
}
```

Every result is a cheap borrowed view; the two parameters that recur are `Size`
(`Option<f32>` ppem, `None` = font units) and `LocationRef` (a borrowed
`&[NormalizedCoord]`) ([`skrifa/src/instance.rs`][instance]).

## Analysis spine

### 1. Layering and ownership

| Layer        | Type                                                         | Owns                                                                                                          | Lifetime / sharing                               |
| ------------ | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| bytes        | `FontData<'a>`                                               | nothing — `&'a [u8]`                                                                                          | caller owns the buffer (file, mmap, `Vec`)       |
| file / face  | `FileRef<'a>`, `CollectionRef<'a>`, `FontRef<'a>`            | table directory view, ttc index                                                                               | `Clone`, borrowed, `Send + Sync` by construction |
| table        | generated `Hhea<'a>`, `Gsub<'a>`, …                          | a `FontData` sub-slice                                                                                        | re-created per `TableProvider` call              |
| metadata     | `Metrics`, `Attributes`, `Charmap<'a>`, `AxisCollection<'a>` | values or borrowed views                                                                                      | computed per call from `(Size, LocationRef)`     |
| scaler state | `HintingInstance`                                            | `Vec<NormalizedCoord>`, size, target, hinter state (`Box<glyf::HintInstance>`, CFF subfonts, autohint styles) | owned; the only heavyweight object               |
| output       | `OutlinePen`, `ColorPainter`                                 | caller's                                                                                                      | `&mut` sink                                      |

There is no face cache, no refcount and no mutable shared state: the "face" is a
`Copy`-cheap borrow, so thread-safety is a borrow-checker fact rather than a
documented lock protocol. The only owned, size-specific object is
`HintingInstance::new(&outlines, size, location, options)`, which runs `fpgm`/
`prep` (or builds autohint metrics) once and is then reused per glyph
([`skrifa/src/outline/hint.rs`][hint]). Scratch memory is optional and
caller-supplied: `DrawSettings::with_memory(Some(&mut buf))` sized by
`OutlineGlyph::draw_memory_size(Hinting)`, otherwise allocated internally
([`skrifa/src/outline/mod.rs`][outline-mod]).

Errors are a closed enum, `ReadError { OutOfBounds, InvalidFormat(i64),
InvalidSfnt(u32), InvalidTtc(Tag), InvalidCollectionIndex(u32), InvalidArrayLen,
ValidationError, NullOffset, TableIsMissing(Tag), MalformedData(&'static str) }`
([`read-fonts/src/read.rs`][read-rs]); `skrifa` adds `DrawError` and
`PaintError`. Metadata getters do not fail: a missing table yields defaults or
`None` fields.

### 2. Face loading and table access

From bytes only — there is no file API; the caller mmaps or reads. Collections:
`FontRef::from_index(data, index)`, `FontRef::fonts(data)` iterates every face,
`CollectionRef::len()` counts ([`read-fonts/src/lib.rs`][rf-lib]). Loading is
lazy to the extreme: only the table directory is read; each table is bounds
checked on access; each field on read.

Raw access is the primary API: `FontRef::table_data(tag)`, the public
`table_directory` field (every `TableRecord` with tag, offset, length,
checksum), and typed readers for ~60 tables including `GSUB`, `GPOS`, `GDEF`,
`BASE`, `MATH`, `STAT`, `meta`, `COLR`, `CPAL`, `sbix`, `CBDT`, `SVG`, `VARC`,
`IFT` and the AAT family `morx`/`kerx`/`trak`/`ankr`/`feat`
(`read-fonts/src/tables/`). `TableProvider` is a trait, so a synthetic or
incremental (IFT-patched) font is another implementor — the same "face is a
tag → bytes function" idea as HarfBuzz's `hb_face_create_for_tables`
([./harfbuzz.md](./harfbuzz.md)).

What it refuses: an sfnt version outside `0x00010000`/`OTTO`/`true`
(`ReadError::InvalidSfnt`); WOFF/WOFF2 are not decoded here.

### 3. Shaping

**Absent.** Fontations does not shape. `Charmap` is explicit about the
boundary: "Comprehensive mapping of characters to positioned glyphs requires a
process called shaping" ([`skrifa/src/charmap.rs`][charmap]). What it provides
to a shaper is the zero-copy layout-table readers, which HarfRust consumes, and
`Charmap::map`/`map_variant` (`cmap` 4/12/13/14, with variation selectors).
Glyph advances for a shaper come from `GlyphMetrics::advance_width(gid)` at a
`(Size, LocationRef)`, with `HVAR` applied ([`skrifa/src/metrics.rs`][metrics]).

### 4. Variation and instances

This is fontations' strongest RQ3 answer: **one coordinate type, passed
explicitly to every call**, never stored on a face.

- `font.axes()` → `Axis { tag, index, name_id, is_hidden, min/default/max_value }`
  and `Axis::normalize(user)` (no `avar`) ([`skrifa/src/variation.rs`][variation]).
- `axes.location([("wght", 650.0), ("wdth", 100.0)])` → owned `Location`;
  `location_to_slice` fills a caller buffer. Both go through
  `fvar.user_to_normalized(avar, …)`, so `avar` (v1 and v2) is applied; unknown
  tags are dropped, values clamped, duplicates last-wins
  ([`read-fonts/src/tables/fvar.rs`][fvar]).
- `font.named_instances()` → `NamedInstance { subfamily_name_id,
postscript_name_id, user_coords(), location() }`.
- The normalized coordinates (`NormalizedCoord = F2Dot14`) are then passed as
  `LocationRef` into `metrics(size, loc)` (`MVAR` deltas for ascent, descent,
  line gap, cap/x-height, decorations), `glyph_metrics(size, loc)`
  (`HVAR`), `DrawSettings::unhinted(size, loc)` (`gvar`, `CFF2` blends, `VARC`),
  `HintingInstance::new(…, loc, …)` (`cvar` for TrueType hinting) and
  `ColorGlyph::paint(loc, painter)` (`COLRv1` `ItemVariationStore`).

A shaper (HarfRust) is given the same `&[F2Dot14]`. The upshot: user coords →
normalized happens once, at the edge, and both shaping and rasterization read
the same slice — with no hidden face state to fall out of sync. The cost is
that every call site carries a `LocationRef`.

### 5. Rasterization and outlines

**No rasterizer.** `skrifa` stops at a scaled, optionally hinted path; Skia (or
`vello`, `zeno`, …) fills it. The outline API is a callback sink
([`skrifa/src/outline/mod.rs`][outline-mod]):

```rust
let outlines = font.outline_glyphs();
let glyph = outlines.get(glyph_id).unwrap();
let var_location = font.axes().location(&[("wght", 650.0), ("wdth", 100.0)]);
let settings = DrawSettings::unhinted(Size::new(16.0), &var_location);
glyph.draw(settings, &mut svg_path).unwrap();
```

`OutlinePen` has `move_to`, `line_to`, `quad_to`, `curve_to`, `close` over
`f32` in **pixels at the given ppem**, or font units for `Size::unscaled()`
([`read-fonts/src/model/pen.rs`][pen-model]). Quadratics are kept (no forced
cubic conversion). `PathStyle::FreeType` vs `PathStyle::HarfBuzz` selects which
engine's contour-start rule to reproduce when the first `glyf` point is
off-curve ([`skrifa/src/outline/pen.rs`][pen]) — evidence that bit-exact
compatibility with an incumbent is itself a feature. `draw` returns
`AdjustedMetrics { has_overlaps, lsb, advance_width }`, the hinted
`horiBearingX`/`advance.x` equivalents.

Hinting is chosen per instance: `DrawSettings::hinted(&instance, is_pedantic)`
with `HintingOptions { engine, target }`. `Engine::Interpreter` runs TrueType
bytecode or CFF stem hints; `Engine::Auto(Option<GlyphStyles>)` is a Rust port
of FreeType's autohinter (`skrifa/src/outline/autohint/`, exposing its
`ScriptClass`, blue zones, edges and segments publicly); `Engine::AutoFallback`
(default) mirrors FreeType's choice — interpreter for CFF or when `fpgm`/`prep`
is non-empty, autohinter otherwise. `Target::Mono` vs `Target::Smooth { mode:
Normal | Light | Lcd | VerticalLcd, symmetric_rendering, preserve_linear_metrics }`
corresponds to `FT_LOAD_TARGET_*` ([`skrifa/src/outline/hint.rs`][hint]).
`fauntlet` is the quality evidence: Skrifa's outlines are diffed against
FreeType's at fixed sizes and locations.

Color: `ColorGlyphCollection::get(gid)` → `ColorGlyph` (`ColrV0`/`ColrV1`),
`paint(location, &mut impl ColorPainter)` drives `push_transform`,
`push_clip_glyph`, `push_clip_box`, `fill(Brush)` (solid / linear / radial /
sweep), `fill_glyph`, `paint_cached_color_glyph`, `push_layer(CompositeMode)`;
a `PaintDecycler` rejects cyclic paint graphs ([`skrifa/src/color/mod.rs`][color]).
Palettes: `ColorPalettes`. Bitmaps: `BitmapStrikes::glyph_for_size` over
`CBDT`/`EBDT`/`sbix` ([`skrifa/src/bitmap.rs`][bitmap]). `SVG` is only a raw
table reader. No atlas, gamma or LCD filtering — those belong to Skia.

### 6. Metrics and measurement

`Metrics::new(font, size, location)` returns `f32`s already scaled by
`ppem / upem` ([`skrifa/src/metrics.rs`][metrics]): `units_per_em`,
`glyph_count`, `is_monospace` (`post.isFixedPitch`), `italic_angle`,
`ascent`/`descent`/`leading`, `cap_height`, `x_height`, `average_width`,
`max_width`, `underline`, `strikeout`, `bounds`. The line-metric rule is
FreeType's, stated in the source:

```rust
// We use the same strategy as FreeType:
// 1. Use the OS/2 metrics if the table exists and the USE_TYPO_METRICS
//    flag is set.
// 2. Otherwise, use the hhea metrics.
// 3. If hhea metrics are zero and the OS/2 table exists:
//    3a. Use the typo metrics if they are non-zero
//    3b. Otherwise, use the win metrics
```

then `MVAR` deltas are added when the location is non-default. Per glyph,
`GlyphMetrics` gives `advance_width`, `left_side_bearing` (both `HVAR`-varied)
and `bounds`. Hinted advances only come from `AdjustedMetrics`.

### 7. Discovery, matching and fallback

**Absent by design.** No enumeration, no matching, no fallback. What a matcher
needs is exposed: `Attributes { stretch, style, weight }` from `OS/2`
`usWidthClass`/`fsSelection`/`usWeightClass` with a `head.macStyle` fallback
([`skrifa/src/attribute.rs`][attribute]), `localized_strings(StringId)` for
family names, and `Charmap::mappings()` for coverage. The Linebender stack
builds discovery on top (`fontique` in [./parley.md](./parley.md)); compare
[./fontdb.md](./fontdb.md) and [./fontconfig.md](./fontconfig.md).

## What it teaches `sparkles:font`

- **Generate the table layer.** One declarative description per table yields
  both a zero-copy reader and an owned writer; the reader is a `FontData` slice
  plus constant-offset getters. A D equivalent is a CTFE/mixin generator over a
  table DSL, with `MIN_SIZE` checked once at construction.
- **Minimal validation + default-on-malformed** keeps parsing `@nogc nothrow`:
  `FontRead` returns `Expected`-style errors only for structural failures;
  field reads clamp to defaults.
- **Do not store variation coordinates on the face.** Convert user → normalized
  (with `avar`) once into a `F2Dot14[]`, then pass a borrowed slice to metrics,
  outlines, hinting, paint and the shaper — the inverse of ttf-parser's
  mutable `set_variation` ([./ttf-parser.md](./ttf-parser.md)).
- **`Size` as `Nullable!float` ppem.** "Unscaled = font units" falls out of the
  same API instead of a separate code path.
- **Reify the expensive state as a `HintingInstance`.** Everything else stays a
  view; the one owned object is per (font, size, location, mode) and reusable.
- **Differential testing against FreeType** (`fauntlet`) is the cheapest way to
  prove an own outline/hinting path; `PathStyle` shows that the oracle's quirks
  must be selectable.

## Strengths

- Zero-copy, no-allocation reading with `#![forbid(unsafe_code)]`, fuzzed on
  OSS-Fuzz, shipping in Chrome's Skia backend.
- Broadest table coverage of any Rust parser at the pin, including `VARC`, IFT
  and AAT, generated from a single description.
- Explicit, stateless variation flow; `avar` handled once.
- FreeType-compatible hinting including the autohinter, with hint internals
  (blue zones, edges) exposed for inspection.

## Weaknesses

- No rasterizer, shaper or font database: three more crates are needed for a
  terminal.
- `TableProvider` getters re-parse headers on every call; callers must cache
  views themselves.
- Two API levels to learn (`read-fonts` raw tables vs `skrifa` semantics), with
  some features (bitmap decoding, `SVG`) only at the raw level.
- `skrifa` is pre-1.0 (0.47.0) and changes API frequently.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                                | Trade-off                                            |
| ------------------------------------------ | -------------------------------------------------------- | ---------------------------------------------------- |
| Codegen tables from a DSL                  | One source of truth for read and write; spec-shaped docs | A bespoke generator (6k lines) to maintain           |
| Tables are `FontData` newtypes             | Zero copy, zero alloc, `no_std`                          | Every field read is a bounds-checked big-endian load |
| Defaults on malformed fields               | Never panic on hostile fonts                             | Corruption is silent at the field level              |
| `LocationRef` passed per call              | No hidden mutable face state; thread-safe sharing        | Verbose call sites                                   |
| `HintingInstance` as the only owned object | Amortize `fpgm`/`prep`/autohint analysis per size        | Callers must key and cache instances                 |
| Pens and painters, not path objects        | Consumer picks representation (Skia path, SVG, kurbo)    | No iterable outline; bbox needs a `ControlBoundsPen` |
| Shaping and raster out of scope            | Replace FreeType's parsing/scaling surface precisely     | Integration glue lives in Skia / HarfRust / vello    |

## Sources

All paths verified at the pinned revision with `git cat-file -e`. Line counts
via `find <crate> -name '*.rs' | xargs wc -l`.

- **Workspace** — [`README.md`][readme], [`Cargo.toml`][cargo],
  [`skera/README.md`][skera-readme], [`fauntlet/README.md`][fauntlet-readme].
- **read-fonts** — [`README.md`][rf-readme], [`src/lib.rs`][rf-lib],
  [`src/table_provider.rs`][table-provider], [`src/read.rs`][read-rs],
  [`src/font_data.rs`][font-data], [`src/tables/fvar.rs`][fvar],
  [`src/model/pen.rs`][pen-model].
- **Codegen** — [`docs/codegen-tour.md`][codegen-tour],
  [`resources/codegen_inputs/hhea.rs`][cg-hhea],
  [`read-fonts/generated/generated_hhea.rs`][gen-hhea].
- **skrifa** — [`README.md`][skrifa-readme], [`src/lib.rs`][skrifa-lib],
  [`src/provider.rs`][provider], [`src/instance.rs`][instance],
  [`src/variation.rs`][variation], [`src/metrics.rs`][metrics],
  [`src/attribute.rs`][attribute], [`src/charmap.rs`][charmap],
  [`src/outline/mod.rs`][outline-mod], [`src/outline/hint.rs`][hint],
  [`src/outline/pen.rs`][pen], [`src/outline/autohint/mod.rs`][autohint],
  [`src/color/mod.rs`][color], [`src/bitmap.rs`][bitmap].
- Siblings: [./freetype.md](./freetype.md), [./harfbuzz.md](./harfbuzz.md),
  [./ttf-parser.md](./ttf-parser.md), [./skia.md](./skia.md),
  [./parley.md](./parley.md), [./vello.md](./vello.md).

<!-- References -->

[repo]: https://github.com/googlefonts/fontations
[readme]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/README.md
[cargo]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/Cargo.toml
[skera-readme]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skera/README.md
[fauntlet-readme]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/fauntlet/README.md
[rf-readme]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/read-fonts/README.md
[rf-lib]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/read-fonts/src/lib.rs
[table-provider]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/read-fonts/src/table_provider.rs
[read-rs]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/read-fonts/src/read.rs
[font-data]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/read-fonts/src/font_data.rs
[fvar]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/read-fonts/src/tables/fvar.rs
[pen-model]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/read-fonts/src/model/pen.rs
[codegen-tour]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/docs/codegen-tour.md
[cg-hhea]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/resources/codegen_inputs/hhea.rs
[gen-hhea]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/read-fonts/generated/generated_hhea.rs
[skrifa-readme]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/README.md
[skrifa-lib]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/lib.rs
[provider]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/provider.rs
[instance]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/instance.rs
[variation]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/variation.rs
[metrics]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/metrics.rs
[attribute]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/attribute.rs
[charmap]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/charmap.rs
[outline-mod]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/outline/mod.rs
[hint]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/outline/hint.rs
[pen]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/outline/pen.rs
[autohint]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/outline/autohint/mod.rs
[color]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/color/mod.rs
[bitmap]: https://github.com/googlefonts/fontations/blob/f2c8f01c8d3cfe6cfb29fbc6fb0e5670b52ce7be/skrifa/src/bitmap.rs
