# font-kit (Rust / Servo)

One `Loader` trait, three OS backends (FreeType, Core Text, DirectWrite), and one
`Source` trait, five font databases — the canonical "one trait, N platform
implementations" font API, written for Servo and Pathfinder.

| Field            | Value                                                                                |
| ---------------- | ------------------------------------------------------------------------------------ |
| Language         | Rust (edition 2018, `rust-version = "1.77"`)                                         |
| License          | MIT OR Apache-2.0 ([`LICENSE-MIT`][license-mit], [`LICENSE-APACHE`][license-apache]) |
| Repository       | [`servo/font-kit`][repo]                                                             |
| Documentation    | crate docs in [`src/lib.rs`][lib] (published at docs.rs); [`README.md`][readme]      |
| Category         | platform text stack (adapter) · font database/discovery                              |
| Layer(s) covered | discover · match/fallback · raster · outline (no shape, no layout)                   |
| Version at pin   | `0.14.3` ([`Cargo.toml`][cargo])                                                     |
| Pinned revision  | `90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4` (2026-08-29)                              |

## Overview

### What it solves

A browser engine needs _installed_ fonts on every OS, needs to match a CSS
`font-family`/`font-weight`/`font-stretch`/`font-style` request against them,
and needs glyph outlines or bitmaps out of whichever font wins — without caring
whether FreeType, Core Text or DirectWrite did the work. `font-kit` separates
the two concerns into two traits and lets them be mixed, which its own crate
documentation states as the design:

> `font-kit` delegates to system libraries to perform tasks. It has two types
> of backends: a _source_ and a _loader_. Sources are platform font databases;
> they allow lookup of installed fonts by name or attributes. Loaders are font
> loading libraries; they allow font files (TTF, OTF, etc.) to be loaded from a
> file on disk or from bytes in memory. Sources and loaders can be freely
> intermixed at runtime; fonts can be looked up via DirectWrite and rendered
> via FreeType, for example.
>
> — [`src/lib.rs`][lib]

### Design philosophy

Shaping is explicitly out of scope — the crate does per-`char` lookup and says
so on the method:

```rust
    /// Returns the usual glyph ID for a Unicode character.
    ///
    /// Be careful with this function; typographically correct character-to-glyph mapping must be
    /// done using a *shaper* such as HarfBuzz. This function is only useful for best-effort simple
    /// use cases like "what does character X look like on its own".
    fn glyph_for_char(&self, character: char) -> Option<u32>;
```

— [`src/loader.rs`][loader]

Everything else — matching, metrics, outlines, raster — is a thin, uniform
veneer over what the platform already does. `font-kit` never parses an
OpenType table itself beyond what `analyze_bytes` needs to classify a file; it
hands `load_font_table(tag) -> Option<Box<[u8]>>` to callers who want to.

## How it works

The pipeline is `Source → Handle → Loader (= Font) → outline | Canvas`.

**`Source`** ([`src/source.rs`][source]) is an object-safe trait with four
required methods — `all_fonts() -> Vec<Handle>`, `all_families() -> Vec<String>`,
`select_family_by_name(&str) -> FamilyHandle`, `as_any()` — and default
implementations for `select_by_postscript_name` (brute-force: open every
family, compare `postscript_name()`), `select_family_by_generic_name` (maps
`FamilyName::Serif` etc. to a platform constant) and `select_best_match`. The
platform alias `SystemSource` is chosen by `cfg`: `CoreTextSource` on
macOS/iOS, `DirectWriteSource` on Windows, `FontconfigSource` elsewhere,
`FsSource` on Android and OpenHarmony.

**`Handle`** ([`src/handle.rs`][handle]) is the currency between the two
traits — a two-variant enum, `Path { path: PathBuf, font_index: u32 }` or
`Memory { bytes: Arc<Vec<u8>>, font_index: u32 }`. A collection is addressed
by index at this level, so `FsSource::discover_fonts` emits one handle per
`font_index` after `analyze_file` returns `FileType::Collection(n)`
([`src/sources/fs.rs`][fs], [`src/file_type.rs`][file-type]).

**`Loader`** ([`src/loader.rs`][loader]) is the face + scaled-font + rasterizer
interface in one trait — `Clone + Sized` with an associated `NativeFont`:

| Group        | Methods                                                                                                                                                                                     |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| construction | `from_bytes(Arc<Vec<u8>>, font_index)`, `from_file(&mut File, idx)`, `from_path`, `unsafe from_native_font`, `from_handle(&Handle)`                                                         |
| probing      | `analyze_bytes`, `analyze_file`, `analyze_path -> FileType`                                                                                                                                 |
| identity     | `native_font()`, `postscript_name()`, `full_name()`, `family_name()`, `is_monospace()`, `properties() -> Properties`, `glyph_count()`                                                       |
| mapping      | `glyph_for_char(char)`, `glyph_by_name(&str)` (default: `warn!("unimplemented")`)                                                                                                           |
| geometry     | `outline(glyph_id, HintingOptions, &mut impl OutlineSink)`, `typographic_bounds(glyph_id) -> RectF`, `advance(glyph_id) -> Vector2F`, `origin(glyph_id)`                                    |
| metrics      | `metrics() -> Metrics`                                                                                                                                                                      |
| raster       | `supports_hinting_options(opts, for_rasterization)`, `raster_bounds(...) -> RectI`, `rasterize_glyph(&mut Canvas, glyph_id, point_size, Transform2F, HintingOptions, RasterizationOptions)` |
| escape hatch | `handle()`, `copy_font_data() -> Option<Arc<Vec<u8>>>`, `load_font_table(u32) -> Option<Box<[u8]>>`, `get_fallbacks(text, locale) -> FallbackResult`                                        |

The crate's `Font` is a re-export of whichever `loaders::<backend>::Font` the
`cfg` picked ([`src/font.rs`][font], [`src/loaders/mod.rs`][loaders-mod]).
Each backend file is roughly a thousand lines — 1249 for FreeType, 1013 for
Core Text, 964 for DirectWrite — and each implements the trait by delegating to
inherent methods of the same name.

## Analysis spine

### 1. Layering and ownership

`font-kit` collapses face, scaled font and rasterizer into one object: a
`Font` is unsized (the `Loader` docs: "fonts in `font-kit` are unsized, so we
ignore [CSS step 4d]" in [`src/matching.rs`][matching]) and every per-size
operation takes `point_size: f32` as an argument. There is no scaled-font
handle and no glyph cache; `rasterize_glyph` on the FreeType backend calls
`FT_Set_Char_Size` before and `reset_freetype_face_char_size` after every
glyph ([`src/loaders/freetype.rs`][ft]).

Ownership of the bytes is `Arc<Vec<u8>>` throughout — in `Handle::Memory`, in
`Loader::from_bytes`, and as the `font_data` field the FreeType `Font` keeps
alive beside its `FT_Face` so `FT_New_Memory_Face` never outlives its buffer.
`Clone` on that `Font` bumps both: `FT_Reference_Face` on the face and the
`Arc` on the data; `Drop` calls `FT_Done_Face` guarded by
`FREETYPE_LIBRARY.try_with`, since the library is a `thread_local!` and may
already be gone ([`src/loaders/freetype.rs`][ft]). That thread-local is the
thread-safety story: one `FT_Library` per thread, so a `Font` is `Clone` but
not `Send` on the FreeType path. The DirectWrite `Font` keeps
`cached_data: Mutex<Option<Arc<Vec<u8>>>>` to lazily materialize
`copy_font_data` ([`src/loaders/directwrite.rs`][dw]).

Errors are three small enums ([`src/error.rs`][error]):
`FontLoadingError { UnknownFormat, NoSuchFontInCollection, Parse, NoFilesystem, Io }`,
`GlyphLoadingError { NoSuchGlyph, PlatformError }`, `SelectionError { NotFound, CannotAccessSource }`.
Several raster paths still `assert_eq!`/`panic!` on FreeType return codes
("FIXME(pcwalton): This function should return a Result instead").

### 2. Face loading and table access

Three entry points per backend — bytes, open `File`, path — each with a
`font_index` for collections; `analyze_*` classifies without loading. Loading
is eager on the platform side (FreeType parses on `FT_New_Memory_Face`).
Raw table access is one call, `load_font_table(tag) -> Option<Box<[u8]>>`,
implemented via `FT_Load_Sfnt_Table` (declared locally because the
`freetype-sys` bindings lack it), `CTFontCopyTable`, and
`IDWriteFontFace::TryGetFontTable` respectively. The `OS/2` table is read
through FreeType's `FT_Get_Sfnt_Table` for `sCapHeight`/`sxHeight`
(`get_os2_table`). What it refuses: bitmap-only glyphs in `outline`
("TODO(pcwalton): What should we do for bitmap glyphs?").

### 3. Shaping

None, by design (quote above). `glyph_for_char` and `advance` are the only
mapping primitives; `get_fallbacks(text, locale)` exists on the trait but is
implemented only by DirectWrite (`IDWriteFontFallback::MapCharacters`) —
FreeType and Core Text return `warn!("unsupported")` with an empty list
([`src/loaders/freetype.rs`][ft], [`src/loaders/core_text.rs`][ct]).

### 4. Variation and instances

**Absent.** No `fvar`/`avar` reading, no `FT_Set_Var_Design_Coordinates`, no
`CTFontDescriptor` variation attribute, no named-instance enumeration;
`properties()` reads `OS/2` `usWeightClass`/`usWidthClass` and style flags
only. A variable font loads as its default instance and `Stretch::MAPPING`
quantizes `usWidthClass` 1–9 onto the nine CSS stretch values
([`src/properties.rs`][properties]).

### 5. Rasterization and outlines

**Outlines** are a push sink in font units, y-up:

```rust
pub trait OutlineSink {
    fn move_to(&mut self, to: Vector2F);
    fn line_to(&mut self, to: Vector2F);
    fn quadratic_curve_to(&mut self, ctrl: Vector2F, to: Vector2F);
    fn cubic_curve_to(&mut self, ctrl: LineSegment2F, to: Vector2F);
    fn close(&mut self);
}
```

— [`src/outline.rs`][outline], which also ships `OutlineBuilder`, a sink that
accumulates into a flat `Outline { contours: Vec<Contour { positions, flags }> }`
with `PointFlags::CONTROL_POINT_0/1`. The FreeType implementation walks
`FT_Outline` tags by hand, synthesizing implied on-curve midpoints between
consecutive quadratic controls; when `HintingOptions` carries a grid-fitting
size, points are hinted at that size then rescaled back to font units
(`point_position * units_per_em / grid_fitting_size`) so the sink's unit never
changes ([`src/loaders/freetype.rs`][ft]). Core Text uses
`CTFontCreatePathForGlyph` and multiplies by `units_per_point`.

**Hinting** is a four-variant enum that names what each platform does:
`None` ("macOS and FreeType no-hinting"), `Vertical(f32)` ("DirectWrite and
FreeType light"), `VerticalSubpixel(f32)` ("DirectWrite, GDI ClearType,
FreeType LCD"), `Full(f32)` ("GDI non-ClearType, FreeType normal")
([`src/hinting.rs`][hinting]). `supports_hinting_options(opts, for_rasterization)`
is the capability query: FreeType answers true for hinted _raster_ and false
for hinted _outlines_.

**Raster** goes into a caller-owned `Canvas { pixels: Vec<u8>, size, stride, format }`
with `Format::{A8, Rgb24, Rgba32}` and `RasterizationOptions::{Bilevel, GrayscaleAa, SubpixelAa}`
([`src/canvas.rs`][canvas]). The backend renders into its own buffer and
`blit_from` converts formats on the way in (`A8↔Rgb24`, `Rgb24↔Rgba32`, 1-bpp
via a 256-entry LUT; `A8↔Rgba32` is `unimplemented!()`). Gamma is not touched
anywhere; LCD filtering is `FT_LCD_FILTER_DEFAULT` set once on the thread-local
library. No atlas, no cache, no GPU path, no color glyphs (`FT_PIXEL_MODE_BGRA`
hits `panic!("Unexpected FreeType pixel mode!")`). Both the FreeType and the
DirectWrite `rasterize_glyph` carry the same comment: "woefully incomplete.
See WebRender's code for a more complete implementation."

### 6. Metrics and measurement

`Metrics` is in **font units** with `units_per_em: u32`, and its
`descent` is negative "to match `sTypoDescender`" ([`src/metrics.rs`][metrics]).
Where each backend gets them differs and the struct hides it: FreeType uses
`FT_FaceRec::ascender/descender/height` (whatever FreeType chose — `hhea`
unless `OS/2` `USE_TYPO_METRICS` is set) plus `OS/2` for `cap_height`/`x_height`;
Core Text takes `CTFontGetAscent/Descent/Leading/CapHeight/XHeight` in points
and multiplies back by `units_per_em / pt_size`; `bounding_box` is the `head`
box. `line_gap` on FreeType is derived: `height + descender - ascender`.
Per-glyph: `advance` and `typographic_bounds` in font units; `raster_bounds`
has a default implementation that scales and `round_out()`s the typographic box.

### 7. Discovery, matching and fallback

Enumeration is per source: fontconfig `FcFontList` with an `ObjectSet` of
`file`+`index` ([`src/sources/fontconfig.rs`][fc-src]), Core Text
`CTFontCollectionCreateFromAvailableFonts` plus `NSFontFamilyAttribute`
descriptors ([`src/sources/core_text.rs`][ct-src]), DirectWrite's system
collection, and `FsSource`'s `walkdir` over hard-coded directories — on Linux
`/usr/share/fonts`, `/usr/local/share/fonts`, three Flatpak `/run/host/*`
paths, `~/.fonts`, `~/.local/share/fonts`, `$XDG_DATA_HOME/fonts`; on Android
only `/system/fonts` ([`src/sources/fs.rs`][fs]). `MemSource` is the in-memory
index (a `Vec<FamilyEntry>` sorted by family, binary-searched; "FIXME:
Case-insensitive comparison"), `FsSource` wraps one, and `MultiSource` chains
`Vec<Box<dyn Source>>` with first-hit-wins and `find_source::<T>()` downcasting
([`src/sources/multi.rs`][multi]).

Matching is `find_best_match(candidates: &[Properties], query) -> usize`, a
literal transcription of CSS Fonts Level 3 § 5.2 steps 4a–4c
([`src/matching.rs`][matching]): narrow the set by stretch (exact, else
nearest narrower-first below normal / wider-first above), then style with the
preference lists `Italic→[Italic, Oblique, Normal]`, `Oblique→[Oblique, Italic, Normal]`,
`Normal→[Normal, Oblique, Italic]`, then weight with the 400/500 special cases
("The spec doesn't say what to do if the weight is between 400 and 500
exclusive, so we just use 450 as the cutoff"). The `Properties` values are
read by _loading every font in the family_ (`select_descriptions_in_family`),
so a `select_best_match` on a 20-face family opens 20 faces. Generic families
resolve to one hard-coded name per platform — `Times New Roman` / `Arial` /
`Courier New` / `Comic Sans MS` / `Impact`-or-`Papyrus` on Windows and macOS,
the fontconfig alias strings elsewhere — with the FIXME "This only returns one
family instead of multiple". Per-codepoint fallback exists only through
DirectWrite's `get_fallbacks`; there is no charset-based or script-based
fallback on the other two platforms and no classification data beyond
`is_monospace` (`FT_IS_FIXED_WIDTH`, `kCTFontMonoSpaceTrait`).

## What it teaches `sparkles:font`

- **Split discovery from loading with a serializable handle.** `Handle::Path{path, index} | Memory{bytes, index}`
  is the whole contract between a database and a loader; it lets a fontconfig
  answer be opened by FreeType or by an own parser interchangeably. A D
  `FontHandle` should be exactly this, and `index` belongs on it, not on the
  face.
- **One trait for the OS seam is fine; one trait for face + scaled font + raster is not.** Pushing
  `point_size` into every call forced `FT_Set_Char_Size` per glyph and left no
  place for a glyph cache. Keep a `ScaledFont` (face × size × hinting) as its
  own value.
- **Hinting as a platform-descriptive enum works.** `None/Vertical/VerticalSubpixel/Full`
  plus `supports_hinting_options(opts, for_rasterization)` is a cheap,
  honest capability query; adopt the enum and the query, and extend the
  latter with LCD/colour/variation axes.
- **Keep outline units fixed at font units even when hinting.** The rescale
  trick in `get_point` means a consumer never has to know which backend or
  size produced the path.
- **Do not load a family to match it.** `select_descriptions_in_family` opens
  every face to read `OS/2`; the database must cache `Properties` at scan time
  (as fontconfig and `fontdb` do — see [`./fontdb.md`](./fontdb.md)).
- **Transcribe CSS § 5.2 directly** — the ~130-line `find_best_match` is the
  reference implementation to port, including the 450 cutoff.

## Strengths

- Smallest complete "one trait, three OS backends" font loader in the survey;
  the trait is readable in one sitting and every method has a reason.
- `Source`/`Loader` orthogonality is real: the fontconfig source can feed the
  Core Text loader, and `MultiSource` composes app fonts with system fonts.
- Canonical CSS Fonts 3 matcher, reused by Pathfinder, Servo and several
  downstream crates.
- Format-converting `Canvas::blit_from` means callers pick `A8`/`Rgb24`/`Rgba32`
  once and never special-case the backend's native output.

## Weaknesses

- No variation support at all, 2026 and counting.
- Per-glyph `FT_Set_Char_Size`/reset, no scaled-font object, no cache, no
  atlas — unusable as a terminal's hot path without a layer above it.
- Per-codepoint fallback only on Windows; Linux and macOS return empty lists.
- Thread-local `FT_Library` makes the FreeType `Font` non-`Send`; the Core Text
  `Font` is `Send` only through an `unsafe impl`.
- Still `assert!`/`panic!` on FreeType errors and on `BGRA` bitmaps; colour
  glyphs are unsupported.
- Matching loads whole families to read weights; generic families map to one
  hard-coded face per platform.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                                | Trade-off                                                                                    |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Two traits, `Source` and `Loader`, joined by a `Handle` enum   | Database and loader vary independently per platform; Servo wanted DirectWrite + FreeType | `Handle::Memory` is `Arc<Vec<u8>>`, so a memory font is always GC-free but always heap-owned |
| Unsized `Font`; `point_size` per call                          | Matches Core Text and DirectWrite, which size at draw time                               | FreeType pays a `FT_Set_Char_Size` round-trip per glyph; no natural cache key                |
| `OutlineSink` push callbacks + `OutlineBuilder` accumulator    | Zero-copy path for Pathfinder; buffer form for everyone else                             | Cubic control pair passed as `LineSegment2F`, an odd shape for non-Pathfinder consumers      |
| `HintingOptions` names platform behaviours, not FreeType flags | Portable intent; `supports_hinting_options` lets a caller degrade                        | Core Text ignores the enum entirely except for bilevel                                       |
| `Canvas` owned by caller, backend blits with conversion        | One output contract across three rasterizers                                             | Always one extra copy; `A8↔Rgba32` unimplemented; no premultiplied-colour path               |
| Thread-local `FT_Library`                                      | Avoids a global mutex around every FreeType call                                         | `Font` is not `Send`; `Drop` must tolerate the library being gone                            |
| `Properties` read by loading each face in a family             | No own parser, so metadata requires the platform loader                                  | Matching is O(family size) face opens; Core Text source special-cases this via descriptors   |
| Shaping and fallback out of scope                              | HarfBuzz exists; DirectWrite's fallback is wrapped where free                            | Two of three platforms have no fallback; `get_fallbacks` is a trait method most impls stub   |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- [`src/loader.rs`][loader] — the `Loader` trait, `FallbackResult`, default
  `raster_bounds`.
- [`src/source.rs`][source] — the `Source` trait, `SystemSource` cfg aliases,
  generic-family constants, `select_best_match`.
- [`src/handle.rs`][handle], [`src/family_handle.rs`][family-handle],
  [`src/file_type.rs`][file-type] — the discovery → loading currency.
- [`src/matching.rs`][matching] — CSS Fonts 3 § 5.2 transcription.
- [`src/properties.rs`][properties], [`src/family_name.rs`][family-name] —
  `Properties`, `Weight`, `Stretch::MAPPING`, `FamilyName`.
- [`src/outline.rs`][outline], [`src/hinting.rs`][hinting],
  [`src/canvas.rs`][canvas], [`src/metrics.rs`][metrics], [`src/error.rs`][error].
- [`src/loaders/freetype.rs`][ft], [`src/loaders/core_text.rs`][ct],
  [`src/loaders/directwrite.rs`][dw], [`src/loaders/mod.rs`][loaders-mod],
  [`src/font.rs`][font] — the three backends and the default alias.
- [`src/sources/fs.rs`][fs], [`src/sources/mem.rs`][mem],
  [`src/sources/multi.rs`][multi], [`src/sources/fontconfig.rs`][fc-src],
  [`src/sources/core_text.rs`][ct-src] — the databases and their directory
  lists.
- [`Cargo.toml`][cargo], [`README.md`][readme], [`src/lib.rs`][lib] — features,
backend table, the source/loader quote.
<!-- References -->

[repo]: https://github.com/servo/font-kit
[license-mit]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/LICENSE-MIT
[license-apache]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/LICENSE-APACHE
[cargo]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/Cargo.toml
[readme]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/README.md
[lib]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/lib.rs
[loader]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/loader.rs
[source]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/source.rs
[handle]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/handle.rs
[family-handle]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/family_handle.rs
[file-type]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/file_type.rs
[matching]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/matching.rs
[properties]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/properties.rs
[family-name]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/family_name.rs
[outline]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/outline.rs
[hinting]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/hinting.rs
[canvas]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/canvas.rs
[metrics]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/metrics.rs
[error]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/error.rs
[font]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/font.rs
[loaders-mod]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/loaders/mod.rs
[ft]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/loaders/freetype.rs
[ct]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/loaders/core_text.rs
[dw]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/loaders/directwrite.rs
[fs]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/sources/fs.rs
[mem]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/sources/mem.rs
[multi]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/sources/multi.rs
[fc-src]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/sources/fontconfig.rs
[ct-src]: https://github.com/servo/font-kit/blob/90bb48c6a5a8e48b4c8f3e197bb6b17620f3f3a4/src/sources/core_text.rs
