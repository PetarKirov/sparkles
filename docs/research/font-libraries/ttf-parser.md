# ttf-parser (Rust / HarfBuzz org)

The smallest complete OpenType reader in the Rust ecosystem: one stack-resident
`Face<'a>` borrowed over the caller's bytes, every answer in integer font units,
outlines through a five-method `OutlineBuilder` sink — and, at the pin, a
maintenance-mode project that points new users at Fontations.

| Field            | Value                                                                                                            |
| ---------------- | ---------------------------------------------------------------------------------------------------------------- |
| Language         | Rust (edition 2024, Rust 1.88+; `#![no_std]`, `#![forbid(unsafe_code)]`, zero dependencies) + a C API (`c-api/`) |
| License          | MIT OR Apache-2.0 ([`README.md`][readme])                                                                        |
| Repository       | [`harfbuzz/ttf-parser`][repo]                                                                                    |
| Documentation    | [`README.md`][readme], crate docs in [`src/lib.rs`][lib], [`CHANGELOG.md`][changelog]                            |
| Version at pin   | 0.25.1 ([`Cargo.toml`][cargo]); 23,792 lines of Rust under `src/`                                                |
| Category         | parser                                                                                                           |
| Layer(s) covered | parse · outline · metrics (layout tables exposed raw for a shaper; no shape, no raster, no discover)             |
| Pinned revision  | `0c7291223fe9e0bc2808f0255cb991066eedd796` (2026-08-06)                                                          |

## Overview

### What it solves

`ttf-parser` answers "what is in this font" without allocating: global metrics,
`cmap` lookup, advances, outlines (`glyf`, `gvar`, `CFF`, `CFF2`), bitmap and
SVG glyph images, `COLR` painting, names, variation axes — over TrueType,
OpenType and AAT. It is the parser under [./rustybuzz.md](./rustybuzz.md),
[./fontdb.md](./fontdb.md) and [./ab-glyph.md](./ab-glyph.md), which is why its
`GSUB`/`GPOS`/`GDEF`/`morx`/`kerx` readers exist even though it never shapes.

### Design philosophy

The README's feature list is the design statement: "Zero heap allocations. Zero
unsafe. Zero dependencies. `no_std`/WASM compatible. … Stateless. All parsing
methods are immutable." The safety section adds bounded _work_, not just depth:

> All recursive methods have a depth limit, and the ones whose input forms a
> graph (composite glyphs, the COLRv1 paint graph, CFF subroutines) additionally
> bound the _total_ work per call. A depth limit alone does not: with fan-out `b`
> and depth `d`, a small font can force `b^d` visits without ever exceeding the
> depth.
>
> — [`README.md`][readme]

The brief asked for the README's "what it does not do" section; **at this pin
that section no longer exists** (the clone carries a single squashed commit).
In its place the README opens with a scope statement of a different kind:

> **This crate is in maintenance mode. Bug fixes only — no new features.** …
> **For new projects, we recommend [fontations](https://github.com/googlefonts/fontations)**
> (`read-fonts` and `skrifa`), which is actively developed by Google Fonts, has
> broader table support, and is the direction the Rust font ecosystem is moving.
>
> — [`README.md`][readme]

The non-goals are instead stated per method in [`src/lib.rs`][lib]:
`glyph_raster_image` "will return an encoded image. It should be decoded by the
caller"; `glyph_svg_image` "should be rendered or even decompressed (in case of
SVGZ) by the caller". No rasterizer, no shaper, no PNG/SVG decoding, no font
discovery.

## How it works

Three tiers, all borrowing `&'a [u8]` ([`src/lib.rs`][lib]):

- **`RawFace<'a> { data, table_records: LazyArray16<TableRecord> }`** — the
  table directory only. `RawFace::parse(data, index)` handles `.ttc`;
  `RawFace::table(tag)` returns the table's bytes.
- **`FaceTables<'a>`** — one public field per supported table, each a parsed
  header view (`head::Table`, `Option<cmap::Table<'a>>`, `Option<glyf::Table<'a>>`,
  `Option<gsub::…>`, …). `RawFaceTables<'a>` is the same struct as raw slices,
  and `Face::from_raw_tables` builds a face from tables obtained elsewhere.
- **`Face<'a> { raw_face, tables, coordinates: VarCoords }`** — the high-level
  API. Its doc comment states the ownership model bluntly:

```rust
/// Note that `Face` doesn't own the font data and doesn't allocate anything in heap.
/// Therefore you cannot "store" it. The idea is that you should parse the `Face`
/// when needed, get required data and forget about it.
/// That's why the initial parsing is highly optimized and should not become a bottleneck.
///
/// If you still want to store `Face` - checkout
/// [owned_ttf_parser](https://crates.io/crates/owned_ttf_parser). Requires `unsafe`.
///
/// While `Face` is technically copyable, we disallow it because it's almost 2KB big.
```

`Face::parse(data, index)` eagerly locates every known table and parses its
header ("If an optional table has invalid data it will be skipped"); only
`head`, `hhea` and `maxp` are mandatory. Per-glyph data (`glyf` records, `CFF`
charstrings, `gvar` tuples) is decoded on demand inside each query. Cargo
features gate whole table families — `variable-fonts` ("Increases binary size
almost twice"), `opentype-layout`, `apple-layout`, `glyph-names`, `gvar-alloc`
([`Cargo.toml`][cargo]).

## Analysis spine

### 1. Layering and ownership

| Layer     | Type                                  | Owns                                            | Notes                                         |
| --------- | ------------------------------------- | ----------------------------------------------- | --------------------------------------------- |
| bytes     | `&'a [u8]`                            | nothing                                         | caller owns; `owned_ttf_parser` adds self-ref |
| directory | `RawFace<'a>`                         | `LazyArray16<TableRecord>` view                 | `Copy`                                        |
| tables    | `FaceTables<'a>`                      | ~35 `Option<…::Table<'a>>` header views         | public fields — the low-level API             |
| face      | `Face<'a>`                            | the above + `VarCoords` (64 × `F2Dot14` inline) | ~2 KB, `Clone` only; stack-resident           |
| output    | `OutlineBuilder`, `colr::Painter<'a>` | caller's                                        | `&mut dyn` sinks                              |

There is no scaled-font layer: nothing takes a size. Thread-safety follows from
immutability — every query is `&self`, and the doc comment calls `set_variation`
"one of the two only mutable methods in the library". Errors: `Face::parse`
returns `FaceParsingError { MalformedFont, UnknownMagic, FaceIndexOutOfBounds,
NoHeadTable, NoHheaTable, NoMaxpTable }`; every later query returns `Option`,
so a malformed glyph and an absent glyph are indistinguishable.

### 2. Face loading and table access

Bytes only, with `fonts_in_collection(data)` for the `.ttc` count and `index`
to select. Raw access is two-level: `face.raw_face().table(tag)` for any tag
(including ones the crate does not know), and `face.tables()` for the parsed
`FaceTables` — e.g. `face.tables().gsub` is a `LayoutTable { scripts, features,
lookups, variations }` ([`src/ggg/layout_table.rs`][layout-table]). Each table
module also has a standalone `Table::parse(&[u8])`, so a single table can be
read "without loading the whole font/face" ([`README.md`][readme]).

What it refuses: anything that is not sfnt (`UnknownMagic` — no WOFF/WOFF2),
and faces with more than 64 axes for `set_variation` (the coordinate array is
inline).

### 3. Shaping

**Absent.** ttf-parser parses `GDEF`, `GSUB`, `GPOS`, `MATH` (2,632 lines under
`src/ggg/` plus the three table modules), `kern`, `kerx`, `morx`, `trak` and
`ankr`, and exposes the lookup lists, coverage, class definitions and
`FeatureVariations`, but applies none of them. Shaping is
[./rustybuzz.md](./rustybuzz.md)'s job. The shaper-facing primitives are
`glyph_index(char)` (first Unicode `cmap` subtable that maps it),
`glyph_variation_index(char, variation_selector)` (`cmap` format 14) and
`glyph_index_by_name`.

### 4. Variation and instances

Coordinates are stored **on the face**, the opposite choice to
[./fontations.md](./fontations.md):

```rust
/// Sets a variation axis coordinate.
///
/// This is one of the two only mutable methods in the library.
/// We can simplify the API a lot by storing the variable coordinates
/// in the face object itself.
///
/// Since coordinates are stored on the stack, we allow only 64 of them.
pub fn set_variation(&mut self, axis: Tag, value: f32) -> Option<()> {
```

`set_variation` takes a **user** value, normalizes it against `fvar` with
`VariationAxis::normalized_value`, then remaps through `avar`; the result is
readable via `variation_coordinates() -> &[NormalizedCoordinate]` and is what
every variation-aware query reads implicitly: `ascender`/`descender`/
`line_gap`/`x_height` (via `MVAR` tags `hasc`, `hdsc`, `hlgp`, `hcla`, `hcld`),
`glyph_hor_advance` (`HVAR`, else `gvar` phantom points), `outline_glyph`
(`gvar` or `CFF2`), `glyph_bounding_box` and `paint_color_glyph` (`COLRv1`).
A shaper reads the same array from the face it wraps.

`variation_axes()` yields `VariationAxis { tag, min_value, def_value,
max_value, name_id, hidden }` ([`src/tables/fvar.rs`][fvar]). **Named
instances are not exposed** — `fvar` instance records are not parsed at the
pin — so an inspector must read them from `raw_face().table(b"fvar")` itself.
`STAT` is parsed (`AxisRecord`, axis value formats 1–4,
[`src/tables/stat.rs`][stat]) but has no `Face` method.

### 5. Rasterization and outlines

**No rasterizer**; outlines go to a sink ([`src/lib.rs`][lib]):

```rust
pub trait OutlineBuilder {
    fn move_to(&mut self, x: f32, y: f32);
    fn line_to(&mut self, x: f32, y: f32);
    fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32);
    fn curve_to(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32);
    fn close(&mut self);
}
```

`outline_glyph(id, &mut dyn OutlineBuilder) -> Option<Rect>` emits **unscaled
font units**, `y` up, quadratics as `quad_to` (`glyf`) and cubics as `curve_to`
(`CFF`/`CFF2`), and returns the computed bounding box. Dispatch order is `gvar`
(with `glyf`) → `glyf` → `CFF` → `CFF2`. There is no hinting of any kind; a
`dyn` sink rather than a generic keeps code size down.

Color and bitmap paths are separate entry points:

- `glyph_raster_image(id, pixels_per_em) -> RasterGlyphImage { x, y, width,
height, pixels_per_em, format, data }`, choosing the next-larger strike from
  `sbix`, `bloc`/`bdat`, `EBLC`/`EBDT`, `CBLC`/`CBDT` in that order; PNG bytes
  are returned undecoded.
- `glyph_svg_image(id) -> SvgDocument` — raw (possibly gzipped) SVG.
- `paint_color_glyph(id, palette, foreground, &mut dyn colr::Painter)` —
  `COLRv0` and `COLRv1` through `outline_glyph`, `paint(Paint)`, `push_clip`,
  `push_clip_box`, `push_layer(CompositeMode)`, `push_transform` and their pops
  ([`src/tables/colr.rs`][colr]); `is_color_glyph`, `color_palettes`.

Size evidence for RQ2-adjacent work: `glyf.rs` is 692 lines, `gvar.rs` 1,974,
the `CFF`/`CFF2` interpreter 3,938, `colr.rs` 1,945 — a complete outline +
color source in under 9k lines.

### 6. Metrics and measurement

All integers in font units; scaling is the caller's. The three ascender
accessors encode three different policies ([`src/lib.rs`][lib]):

- `ascender()` / `descender()` / `line_gap()` — the FreeType rule (the code
  cites `sfobjs.c`): `OS/2` typo metrics if `USE_TYPO_METRICS`, else `hhea`; if
  `hhea` is zero, typo, then `usWin*`; `MVAR` deltas applied.
- `typographic_ascender()` etc. — `Option<i16>`, raw `OS/2` `sTypo*` + `MVAR`,
  `None` without `OS/2`; documented as "Prefer `Face::ascender` unless you
  explicitly want this".
- `height()` — simply `ascender() - descender()`; **it excludes line gap**, so a
  terminal's line height is `height() + line_gap()`.

Also: `units_per_em`, `x_height`, `capital_height`, `underline_metrics`,
`strikeout_metrics`, `subscript_metrics`, `superscript_metrics`, the vertical
family (`vertical_ascender`, …), `italic_angle`, `global_bounding_box`. Per
glyph: `glyph_hor_advance(id) -> Option<u16>` (rounded integer even when `HVAR`
supplies a fractional delta), `glyph_ver_advance`, `glyph_hor_side_bearing`,
`glyph_y_origin`, `glyph_bounding_box`.

### 7. Discovery, matching and fallback

**Absent.** The classification inputs a database needs are exposed and are
exactly what [./fontdb.md](./fontdb.md) consumes: `names()` (with
`Name::language()` and `to_string()` for UTF-16 entries), `style()`,
`is_regular/is_italic/is_bold/is_oblique` (from `OS/2.fsSelection`), `weight()`
(`usWeightClass`), `width()` (`usWidthClass`), `is_monospaced()` (`post` only),
`is_variable()` (presence of `fvar`), `unicode_ranges()` (`OS/2` bits),
`permissions()` (`fsType`), and `os2::Table::panose` — which the changelog notes
`is_bold`/`is_monospaced` "deliberately do not consult: PANOSE is a design
classification, not a style flag" ([`CHANGELOG.md`][changelog]).

## What it teaches `sparkles:font`

- **A zero-alloc `Face` can be a stack value over a borrowed slice**, eagerly
  locating tables (cheap) and lazily decoding glyphs. In D: a `struct Face`
  with `scope const(ubyte)[]` and `@safe pure nothrow @nogc` queries.
- **Do not put variation state in the face** — ttf-parser's own comment admits
  it was an API simplification, and it caps axes at 64, makes `Face` mutable,
  and silently couples every query to hidden state. Prefer fontations' passed
  `LocationRef`.
- **Return fractional advances.** `Option<u16>` advances lose `HVAR` precision;
  a terminal computing cell width from a variable font needs the fraction.
- **Name the ascender policies.** Expose both the FreeType-rule `ascender` and
  the raw `typo`/`hhea`/`win` triplets so the font explorer can show all three
  and the terminal can pick one.
- **Distinguish malformed from absent.** `Option` everywhere makes diagnostics
  impossible; a D `Expected!(T, FontError)` costs nothing in `@nogc`.
- **Bound total work, not just depth**, for composites, `COLRv1` and CFF
  subroutines.

## Strengths

- Zero allocation, zero `unsafe`, zero dependencies, `no_std`; a C API.
- One readable file (`src/lib.rs`) is the whole high-level API; tables are also
  usable standalone.
- Covers `glyf`/`gvar`/`CFF`/`CFF2`, `COLRv0`/`v1`, all bitmap formats, `SVG`,
  AAT and the OpenType layout tables.
- Explicit total-work bounds on graph-shaped inputs.

## Weaknesses

- Maintenance mode: no new tables (e.g. no `VARC`, no IFT), no named instances.
- Variation coordinates on a mutable, 2 KB face; 64-axis cap.
- Integer advances; no hinting; no size concept.
- `Option`-only error model after `parse`.
- Storing a `Face` needs `owned_ttf_parser` and `unsafe` self-reference.

## Key design decisions and trade-offs

| Decision                             | Rationale                                         | Trade-off                                              |
| ------------------------------------ | ------------------------------------------------- | ------------------------------------------------------ |
| Borrowed, non-storable `Face<'a>`    | Zero alloc; re-parse is "free"                    | Self-referential ownership pushed to another crate     |
| Eager table-directory + header parse | Each query is a field read, no lazy-init branches | ~2 KB face; parse cost paid even for one query         |
| Coordinates stored in the face       | Simpler query signatures                          | Mutation, hidden coupling, 64-axis inline cap          |
| `&mut dyn OutlineBuilder` sink       | Small code, no generics bloat                     | Virtual call per segment                               |
| Font-unit integers everywhere        | No float policy in the parser                     | Caller scales; fractional `HVAR` advances rounded away |
| Cargo features per table family      | Binary size for WASM/embedded                     | Variable-font support is opt-out, not opt-in           |
| Undecoded PNG/SVG payloads           | No codec dependencies                             | Every consumer brings decoders                         |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Crate** — [`README.md`][readme], [`Cargo.toml`][cargo],
  [`CHANGELOG.md`][changelog], [`src/lib.rs`][lib], [`c-api/ttfparser.h`][c-api].
- **Tables** — [`src/tables/fvar.rs`][fvar], [`src/tables/avar.rs`][avar],
  [`src/tables/stat.rs`][stat], [`src/tables/gvar.rs`][gvar],
  [`src/tables/glyf.rs`][glyf], [`src/tables/cff/mod.rs`][cff],
  [`src/tables/colr.rs`][colr], [`src/tables/svg.rs`][svg],
  [`src/tables/cmap/mod.rs`][cmap], [`src/tables/os2/mod.rs`][os2],
  [`src/tables/name.rs`][name], [`src/ggg/layout_table.rs`][layout-table].
- Siblings: [./fontations.md](./fontations.md), [./rustybuzz.md](./rustybuzz.md),
  [./fontdb.md](./fontdb.md), [./ab-glyph.md](./ab-glyph.md),
  [./freetype.md](./freetype.md).

<!-- References -->

[repo]: https://github.com/harfbuzz/ttf-parser
[readme]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/README.md
[cargo]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/Cargo.toml
[changelog]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/CHANGELOG.md
[lib]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/lib.rs
[c-api]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/c-api/ttfparser.h
[fvar]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/fvar.rs
[avar]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/avar.rs
[stat]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/stat.rs
[gvar]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/gvar.rs
[glyf]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/glyf.rs
[cff]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/cff/mod.rs
[colr]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/colr.rs
[svg]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/svg.rs
[cmap]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/cmap/mod.rs
[os2]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/os2/mod.rs
[name]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/tables/name.rs
[layout-table]: https://github.com/harfbuzz/ttf-parser/blob/0c7291223fe9e0bc2808f0255cb991066eedd796/src/ggg/layout_table.rs
