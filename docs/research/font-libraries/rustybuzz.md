# rustybuzz (Rust / HarfBuzz port)

A line-by-line Rust port of HarfBuzz's shaping algorithm over a borrowed
`ttf_parser::Face`: one `Face`, one `UnicodeBuffer` in, one `GlyphBuffer` out,
no font size, no system glue — and, at the pin, an archived project whose
maintainers redirect users to HarfRust.

| Field            | Value                                                                                        |
| ---------------- | -------------------------------------------------------------------------------------------- |
| Language         | Rust (edition 2021, `rust-version = "1.65.0"`, `#![no_std]` + `alloc`)                       |
| License          | MIT ([`Cargo.toml`][cargo]; HarfBuzz itself is Old MIT)                                      |
| Repository       | [`harfbuzz/rustybuzz`][repo]                                                                 |
| Documentation    | [`README.md`][readme], crate docs in [`src/lib.rs`][lib], [`benches/README.md`][bench]       |
| Version at pin   | `0.20.1` ([`Cargo.toml`][cargo]); "Matches `harfbuzz` v10.1.0" ([`README.md`][readme])       |
| Category         | shaper                                                                                       |
| Layer(s) covered | shape (parse delegated to [`ttf-parser`](./ttf-parser.md); no raster, outline, or discovery) |
| Pinned revision  | `9faca967408677f17bc15366dbdc3d2b683d1489` (2026-07-26)                                      |

## Overview

### What it solves

`rustybuzz` gives Rust programs HarfBuzz-equivalent shaping without a C++
compiler or system libraries. Its README states the motivation ("you can add
`rustybuzz = "*"` to your project and it just works") and the conformance
level: it "passes nearly all of harfbuzz shaping tests (2221 out of 2252 to be
more precise)" ([`README.md`][readme]). It was the shaper of the earlier Rust
text stacks; at its own pin [`./cosmic-text.md`](./cosmic-text.md) has already
moved to `harfrust` (`harfrust = { version = "0.5.0", … }` in its `Cargo.toml`).

The first line of the README at the pin is the most important fact for a
reader planning a dependency:

> **NOTE:** This project is not developed further, unmaintained, and archived.
> We recommend that all users witch to [HarfRust](https://github.com/harfbuzz/harfrust) instead.
>
> — [`README.md`][readme]

HarfRust is the successor that rebases the same port onto
[`./fontations.md`](./fontations.md)'s `read-fonts`; HarfBuzz at its own pin
already lists `harfrust` as a compiled-in shaper (see
[`./harfbuzz.md`](./harfbuzz.md)).

### Design philosophy

"rustybuzz is not a faithful port" — it keeps _only_ the shaping part of
HarfBuzz and pushes everything else out:

> harfbuzz can roughly be split into 6 parts: shaping, subsetting, TrueType parsing,
> Unicode routines, custom containers and utilities (harfbuzz doesn't use C++ std)
> and glue for system/3rd party libraries. In the mean time, rustybuzz contains only shaping.
> All of the TrueType parsing was moved to the [ttf-parser](https://github.com/RazrFalcon/ttf-parser).
> Subsetting was removed. Unicode code was mostly moved to external crates.
> We don't need custom containers because Rust's std is good enough.
> And we do not use any non Rust libraries, so no glue code either.
>
> In the end, we still have around 23 KLOC. While harfbuzz is around 80 KLOC.
>
> — [`README.md`][readme]

The second principle is code alignment over idiom: internal types keep their C
names (`hb_font_t`, `hb_buffer_t`, `hb_ot_shape_plan_t`) and are re-exported
under Rust names, so upstream HarfBuzz commits can be back-ported by diff
([`src/lib.rs`][lib]).

## How it works

The whole public surface is eight re-exports:

```rust
pub use ttf_parser;

pub use hb::buffer::hb_glyph_info_t as GlyphInfo;
pub use hb::buffer::{GlyphBuffer, GlyphPosition, UnicodeBuffer};
pub use hb::common::{script, Direction, Feature, Language, Script, Variation};
pub use hb::face::hb_font_t as Face;
pub use hb::ot_shape_plan::hb_ot_shape_plan_t as ShapePlan;
pub use hb::shape::{shape, shape_with_plan};
```

— [`src/lib.rs`][lib]

- **`Face<'a>`** (`hb_font_t`) owns a `ttf_parser::Face<'a>`, `units_per_em`,
  optional `pixels_per_em` / `points_per_em`, the preferred `cmap` subtable
  index, and pre-wrapped `gsub`/`gpos` tables. It `Deref`s to
  `ttf_parser::Face`, so every parser query is available on it
  ([`src/hb/face.rs`][face]).
- **`UnicodeBuffer`** wraps `hb_buffer_t`; `push_str`, `add(char, cluster)`,
  `set_pre_context` / `set_post_context`, direction/script/language setters,
  `set_cluster_level`, `set_flags` ([`src/hb/buffer.rs`][buffer]).
- **`shape(face, features, buffer) -> GlyphBuffer`** consumes the buffer,
  guesses segment properties, builds an `hb_ot_shape_plan_t`, and runs
  `shape_internal`. The doc comment warns the plan is the expensive part:
  "If you plan to shape multiple strings using the same [`Face`] prefer
  [`shape_with_plan`]. This is because [`ShapePlan`] initialization is pretty
  slow" ([`src/hb/shape.rs`][shape]).
- **`GlyphBuffer::clear()`** returns the `UnicodeBuffer`, so the allocation is
  reused across calls — the same buffer-as-workspace idiom as `hb_buffer_t`,
  expressed as a typestate.

## Analysis spine

### 1. Layering and ownership

| Layer        | Type                            | Owns                                                       | Mutability / sharing                         |
| ------------ | ------------------------------- | ---------------------------------------------------------- | -------------------------------------------- |
| bytes        | `&'a [u8]`                      | nothing — caller owns the font file                        | borrowed for `'a`                            |
| typeface     | `ttf_parser::Face<'a>`          | table offsets + variation coords (fixed-size array)        | `Clone`, `&mut` only for `set_variation`     |
| shaping face | `Face<'a>`                      | the above + ppem/ptem + GSUB/GPOS wrappers                 | `&Face` is all `shape` needs                 |
| plan         | `ShapePlan`                     | compiled feature map and lookups for one segment-props key | immutable; caller caches                     |
| workspace    | `UnicodeBuffer` / `GlyphBuffer` | glyph info + position arrays                               | moved through `shape`, recycled by `clear()` |

There is no refcounting and no interior mutability: lifetimes do the work
HarfBuzz does with `hb_blob_t` reference counts. Face and font are _merged_ —
HarfBuzz's unsized `hb_face_t` and sized `hb_font_t` collapse into one value
because there is no size. Thread-safety falls out of Rust: `&Face` and
`&ShapePlan` are shareable; each thread brings its own buffer. Error model:
`Face::from_slice` returns `Option<Self>`, discarding `ttf_parser::FaceParsingError`;
`shape` is infallible. The README lists the departure from HarfBuzz:
"Malformed fonts will cause an error. HarfBuzz uses fallback/dummy shaper in
this case" ([`README.md`][readme]).

### 2. Face loading and table access

`Face::from_slice(data, face_index)` or `Face::from_face(ttf_parser::Face)`;
"Data will be referenced, not owned" ([`src/hb/face.rs`][face]). Parsing is
whatever [`ttf-parser`](./ttf-parser.md) does: header and table directory on
construction, everything else on demand. Raw tables are reached through the
re-exported `ttf_parser` (`face.tables()`, `face.raw_face()`). Refused: AAT
`mort`, `avar2` and "other parts of the boring-expansion-spec"; no
FreeType/CoreText/DirectWrite font-loading integration ([`README.md`][readme]).

### 3. Shaping

The port keeps HarfBuzz's full pipeline: normalization
([`src/hb/ot_shape_normalize.rs`][normalize]), the feature map
([`src/hb/ot_map.rs`][ot-map]), the GSUB/GPOS lookup engine
([`src/hb/ot_layout_gsubgpos.rs`][gsubgpos], `src/hb/ot/layout/{GSUB,GPOS}/`),
script shapers (Arabic, Indic, Khmer, Myanmar, USE, Thai, Hangul, Hebrew) with
Ragel-generated syllable machines (`*_machine.rl` → `*_machine.rs`), AAT
`morx`/`kerx`/`trak` ([`src/hb/aat_layout.rs`][aat]), and the fallback mark
positioner ([`src/hb/ot_shape_fallback.rs`][fallback]).

Features are HarfBuzz's `hb_feature_t` verbatim — `Feature { tag, value, start,
end }`, built with `Feature::new(tag, value, range)` from any `RangeBounds`, and
parsable from the CSS-like `"liga=0"` syntax ([`src/hb/common.rs`][common]).
Script, `Direction` and `Language` are set on the buffer or guessed.
`BufferClusterLevel` has three variants — `MonotoneGraphemes` (default),
`MonotoneCharacters`, `Characters` — HarfBuzz's newer `GRAPHEMES` level is
absent ([`src/lib.rs`][lib]). `GlyphInfo` exposes `glyph_id`, `cluster` and
`unsafe_to_break()` / `unsafe_to_concat()` / `safe_to_insert_tatweel()`;
`BufferFlags::PRODUCE_UNSAFE_TO_CONCAT` opts into the costlier flag
([`src/hb/buffer.rs`][buffer]).

Units: "No font size property. Shaping is always using UnitsPerEm. You should
scale the result manually" ([`README.md`][readme]). `GlyphPosition { x_advance,
y_advance, x_offset, y_offset }` are `i32` font units. `set_pixels_per_em` only
affects bitmap-glyph extents and `set_points_per_em` only Apple optical sizing
via `trak` ([`src/hb/face.rs`][face]).

**Line-count evidence for a D shaper** (`find src -name '*.rs' | xargs wc -l`
at the pin, partitioned by file name):

| Part                                                                              | Lines  | Share |
| --------------------------------------------------------------------------------- | ------ | ----- |
| Total `src/**/*.rs`                                                               | 29 232 | 100 % |
| GSUB/GPOS engine (`ot_layout*`, `ot/layout/**`, `kerning`, `set_digest`)          | 4 224  | 14 %  |
| Script shapers (`ot_shaper_*`), of which 3 218 generated machines/tables          | 8 401  | 29 %  |
| Shape driver, plan, map, normalize, fallback, buffer, face                        | 5 138  | 18 %  |
| AAT (`aat_*`)                                                                     | 2 279  | 8 %   |
| Unicode, tag tables, common types (`unicode_norm.rs` 3 063, `tag_table.rs` 2 483) | 7 837  | 27 %  |
| Optional `wasm-shaper`                                                            | 570    | 2 %   |

Generated or tabular files (`*_machine.rs`, `*_table.rs`, `unicode_norm.rs`,
`ot_shaper_vowel_constraints.rs`) total 10 588 lines; the README's own `tokei`
recipe puts the hand-written core at "around 17 KLOC". This excludes the
GSUB/GPOS _parsing_ living in `ttf-parser` (`src/ggg/`, `src/tables/gsub.rs`,
`src/tables/gpos.rs`: 2 442 lines at its pin). So an OpenType-only shaper for
Latin/Cyrillic/Greek/CJK is ~10 KLOC (layout engine + driver), and complex
scripts roughly double it. Performance cost of a straight port without
HarfBuzz's accelerators: "We're 1.5-2x slower than harfbuzz"
([`README.md`][readme]); the benchmark table shows `english::paragraph_long_mono`
at 80.9 µs vs 18.4 µs (4.4×) but `arabic::word_1` faster than HarfBuzz
([`benches/README.md`][bench]).

### 4. Variation and instances

`Face::set_variations(&[Variation { tag, value: f32 }])` forwards each pair to
`ttf_parser::Face::set_variation`, which maps user → normalized coordinates
and applies `avar` _at set time_, storing normalized values in the face
([`src/hb/face.rs`][face]). From there one array serves everything:
`ot_map.rs` reads `variation_coordinates()` to pick `GSUB`/`GPOS`
`FeatureVariations`; GPOS device/variation-index deltas read the same slice
([`src/hb/ot_layout_gpos_table.rs`][gpos-table]); advances come from
`ttf-parser`'s `HVAR`-aware `glyph_hor_advance`, and when a variable face has
no `HVAR`/`VVAR` and no phantom points the port falls back to bounding boxes
([`src/hb/face.rs`][face]). Named instances and `STAT` are not exposed — the
caller reads `fvar` through `ttf_parser`. Because the face is the only holder
of coordinates, shaping and a [`ttf-parser`](./ttf-parser.md)-driven
rasterizer agree on the instance by construction if they share the `Face`.

### 5. Rasterization and outlines

**Absent.** `rustybuzz` draws nothing. Outlines are available only because
`Face: Deref<Target = ttf_parser::Face>` exposes `outline_glyph`. Internally
the port _evaluates_ color glyphs only to compute extents: `glyph_extents`
reads PNG bitmap metrics (`sbix`/`CBDT`), then the `COLR` clip box, then walks
the `COLRv1` paint graph through `hb_paint_extents_context_t`
([`src/hb/face.rs`][face], [`src/hb/paint_extents.rs`][paint-extents]).

### 6. Metrics and measurement

No metrics API of its own; vertical fallbacks use `ttf_parser`'s `ascender()` /
`descender()` (the `TODO: Original code calls h_extents_with_fallback`
comments mark where HarfBuzz's richer logic was not ported)
([`src/hb/face.rs`][face]). Advances are integer font units. Per-glyph extents
exist internally (`hb_glyph_extents_t`) and surface only through buffer
serialization (`SerializeFlags::GLYPH_EXTENTS`) ([`src/lib.rs`][lib]).

### 7. Discovery, matching and fallback

**Absent, by design** — the README excludes all platform glue. There is not
even HarfBuzz's coverage collector; a fallback engine must iterate
`ttf_parser`'s `cmap` subtables. In Rust stacks this is
[`./fontdb.md`](./fontdb.md) plus per-run fallback in
[`./cosmic-text.md`](./cosmic-text.md).

## What it teaches `sparkles:font`

- **A port of HarfBuzz is ~17 KLOC hand-written, ~10 KLOC without complex
  scripts.** A D shaper is feasible in size; the real cost is _tracking
  upstream_, which killed this project — it was archived in favour of HarfRust.
  Calling HarfBuzz via ImportC is the cheaper default; a native D shaper must
  budget for continuous back-porting.
- **Typestate buffers** (`UnicodeBuffer` → `shape` → `GlyphBuffer` →
  `clear()`) make "codepoints in vs glyphs out" a type, not the
  `hb_buffer_get_content_type` runtime flag — directly expressible as two D
  structs over one `UniqueBuffer`.
- **Shape at upem, scale outside.** A terminal shapes a cell run once and
  scales per size; `rustybuzz` shows the API loses nothing by dropping scale.
- **Store normalized coordinates on the face, apply `avar` at set time.**
  One array feeds `FeatureVariations`, `HVAR`, device deltas and outlines.
- **Expose the plan.** `shape_with_plan` lets `hue` cache one plan per
  `(face, script, direction, language, features)`.

## Strengths

- HarfBuzz-conformant output (2221/2252 tests) with a ~8-symbol API.
- `no_std`, no `unsafe` beyond one POD cast ("The library is completely safe",
  [`README.md`][readme]).
- Borrow-based ownership; trivially `Send`/`Sync` shared faces.
- Exposes break-safety flags and cluster levels needed for incremental
  re-shaping.

## Weaknesses

- Archived and unmaintained at the pin; pinned to HarfBuzz 10.1.0 behaviour.
- 1.5–2× slower than HarfBuzz (up to 4.4× on long monospace Latin) because
  accelerators were not ported.
- No Arabic fallback shaper, no `avar2`, no `GRAPHEMES` cluster level, no
  coverage queries, no metrics or outline API of its own.
- `Option` on load discards the parser's error reason.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                               | Trade-off                                                               |
| ------------------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------- |
| Keep only shaping; delegate parsing to ttf-parser | Smaller port, pure Rust, reusable parser                | Two crates must agree on table semantics; GSUB parsing lives elsewhere  |
| 1:1 C-name translation (`hb_font_t`, …)           | Back-port upstream fixes by diff                        | Unidiomatic internals; still too costly to sustain — project archived   |
| No font size; output in font units                | Removes scale bugs; deterministic integers              | Caller must scale; hinted advances impossible                           |
| Face and font merged into one `Face`              | No size ⇒ nothing to put on a separate sized object     | Variation coords mutate the face; sharing two instances needs two faces |
| Consuming typestate buffers                       | Codepoints vs glyphs encoded in types; allocation reuse | Less flexible than HarfBuzz's re-entrant buffer                         |
| Error on malformed fonts                          | Rust `Option`/`Result` idiom                            | Diverges from HarfBuzz's degrade-gracefully contract                    |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Positioning and port notes** — [`README.md`][readme], [`Cargo.toml`][cargo],
  [`benches/README.md`][bench].
- **API** — [`src/lib.rs`][lib], [`src/hb/face.rs`][face],
  [`src/hb/buffer.rs`][buffer], [`src/hb/shape.rs`][shape],
  [`src/hb/common.rs`][common], [`src/hb/ot_shape_plan.rs`][plan].
- **Engine** — [`src/hb/ot_layout_gsubgpos.rs`][gsubgpos],
  [`src/hb/ot_layout_gpos_table.rs`][gpos-table], [`src/hb/ot_map.rs`][ot-map],
  [`src/hb/ot_shape_normalize.rs`][normalize],
  [`src/hb/ot_shape_fallback.rs`][fallback], [`src/hb/aat_layout.rs`][aat],
  [`src/hb/paint_extents.rs`][paint-extents].
- **CLI** — [`examples/shape.rs`][example] (the `hb-shape` clone).
- Siblings: [`./harfbuzz.md`](./harfbuzz.md), [`./ttf-parser.md`](./ttf-parser.md),
  [`./allsorts.md`](./allsorts.md), [`./swash.md`](./swash.md),
  [`./fontations.md`](./fontations.md).

<!-- References -->

[repo]: https://github.com/harfbuzz/rustybuzz
[readme]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/README.md
[cargo]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/Cargo.toml
[bench]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/benches/README.md
[lib]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/lib.rs
[face]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/face.rs
[buffer]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/buffer.rs
[shape]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/shape.rs
[common]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/common.rs
[plan]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/ot_shape_plan.rs
[gsubgpos]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/ot_layout_gsubgpos.rs
[gpos-table]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/ot_layout_gpos_table.rs
[ot-map]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/ot_map.rs
[normalize]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/ot_shape_normalize.rs
[fallback]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/ot_shape_fallback.rs
[aat]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/aat_layout.rs
[paint-extents]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/src/hb/paint_extents.rs
[example]: https://github.com/harfbuzz/rustybuzz/blob/9faca967408677f17bc15366dbdc3d2b683d1489/examples/shape.rs
