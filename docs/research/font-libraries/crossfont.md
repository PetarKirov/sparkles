# crossfont (Rust / Alacritty)

A terminal's entire font API in one five-method trait: load a face by
description and size, get a key, hand back `Metrics` and rasterized bitmaps —
over FreeType+fontconfig, Core Text or DirectWrite.

| Field            | Value                                                                                 |
| ---------------- | ------------------------------------------------------------------------------------- |
| Language         | Rust (edition 2021, `rust-version = "1.77.0"`)                                        |
| License          | Apache-2.0 ([`LICENSE`][license])                                                     |
| Repository       | [`alacritty/crossfont`][repo]                                                         |
| Documentation    | [`README.md`][readme], crate docs in [`src/lib.rs`][lib]; [`CHANGELOG.md`][changelog] |
| Category         | terminal font stack                                                                   |
| Layer(s) covered | discover · match/fallback · raster (no parse, no shape, no outline, no layout)        |
| Version at pin   | `0.9.0` ([`Cargo.toml`][cargo])                                                       |
| Pinned revision  | `0c34d199b1515389bbed48a0338018e45817876e` (2025-07-08)                               |

## Overview

### What it solves

Alacritty draws a grid of cells. It needs, per configured font and size, a
cell width and line height, and per `(font, char, size)` a bitmap to upload
into a GPU atlas — and nothing else: no shaping, no proportional layout, no
outlines. `crossfont` is that need extracted into a crate, and it says so:

> Since crossfont was originally made solely for rendering monospace fonts in
> Alacritty, there currently is only very limited support for proportional
> fonts.
>
> Loading a lot of different fonts might also lead to resource leakage since
> they are not explicitly dropped from the cache.
>
> — [`README.md`][readme]

### Design philosophy

The crate header is the whole architecture:

```rust
//! Compatibility layer for different font engines.
//!
//! CoreText is used on macOS.
//! DirectWrite is used on Windows.
//! FreeType is used everywhere else.
```

— [`src/lib.rs`][lib]

One `cfg`-selected `pub use <backend>::…Rasterizer as Rasterizer;` per
platform; no runtime backend choice, no own parser, every platform's native
engine trusted for both matching and rendering.

## How it works

The public vocabulary is ~250 lines of [`src/lib.rs`][lib]:

```rust
pub trait Rasterize {
    /// Create a new Rasterizer.
    fn new() -> Result<Self, Error>
    where
        Self: Sized;

    /// Get `Metrics` for the given `FontKey`.
    fn metrics(&self, _: FontKey, _: Size) -> Result<Metrics, Error>;

    /// Load the font described by `FontDesc` and `Size`.
    fn load_font(&mut self, _: &FontDesc, _: Size) -> Result<FontKey, Error>;

    /// Rasterize the glyph described by `GlyphKey`..
    fn get_glyph(&mut self, _: GlyphKey) -> Result<RasterizedGlyph, Error>;

    /// Kerning between two characters.
    fn kerning(&mut self, left: GlyphKey, right: GlyphKey) -> (f32, f32);
}
```

— [`src/lib.rs`][lib]

Note what is _not_ there at this revision: `new()` takes no device pixel ratio
and there is no `update_dpr` — `0.6.0` removed it ("users should scale fonts
themselves", [`CHANGELOG.md`][changelog]). DPR is folded into `Size`.

| Type              | Shape                                                                                                                                                   |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FontDesc`        | `{ name: String, style: Style }`; `Style::Specific(String)` (a face name like `"Bold Italic"`) or `Style::Description { slant: Slant, weight: Weight }` |
| `Slant`/`Weight`  | `Normal`/`Italic`/`Oblique`; `Normal`/`Bold` — two weights only                                                                                         |
| `Size`            | `Size(u32)` = points × 1 000 000, clamped to `[1., 3999.]` pt; `from_px`/`as_px` assume 96 dpi                                                          |
| `FontKey`         | `{ token: u32 }`, `Copy + Hash`; `FontKey::next()` is a global `AtomicUsize` counter                                                                    |
| `GlyphKey`        | `{ character: char, font_key: FontKey, size: Size }` — keyed by **character**, not glyph id                                                             |
| `RasterizedGlyph` | `{ character, width: i32, height: i32, top: i32, left: i32, advance: (i32, i32), buffer: BitmapBuffer }`                                                |
| `BitmapBuffer`    | `Rgb(Vec<u8>)` — "RGB alphamask" (one byte per LCD channel) — or `Rgba(Vec<u8>)` premultiplied colour                                                   |
| `Metrics`         | `{ average_advance: f64, line_height: f64, descent: f32, underline_position, underline_thickness, strikeout_position, strikeout_thickness: f32 }`       |
| `Error`           | `FontNotFound(FontDesc)`, `MetricsNotFound`, `MissingGlyph(RasterizedGlyph)`, `UnknownFontKey`, `PlatformError(String)`                                 |

`Error::MissingGlyph` carries the already-rendered `.notdef` bitmap, so a
caller can draw it and remember not to retry.

## Analysis spine

### 1. Layering and ownership

There is exactly one layer: the `Rasterizer` is face loader, font manager,
scaled font and rasterizer at once. Every backend is a struct of `HashMap`s
keyed by `FontKey` with no eviction (the README's leak warning). The FreeType
backend splits storage in two — `FreeTypeLoader { library: Library, faces: HashMap<FontKey, FaceLoadingProperties>, ft_faces: HashMap<FtFaceLocation, Rc<FtFace>> }`
— so one `FT_Face` (keyed by `(path, index)`) is shared via `Rc` between
several `FaceLoadingProperties` (one per fontconfig-rendered pattern, i.e. per
size/hinting/LCD configuration). `Rc` plus a raw `FT_Library` means the type is
not thread-safe; the crate asserts `unsafe impl Send for FreeTypeRasterizer {}`
and `unsafe impl Send for Font {}` on Core Text so Alacritty can move it to the
render thread ([`src/ft/mod.rs`][ft], [`src/darwin/mod.rs`][darwin]).
Byte ownership never surfaces: fonts are opened by path through the platform,
never from memory.

The `FontKey` is not opaque on the FreeType path: it is
`lhs.0.rotate_left(1) ^ rhs.0` of two `FcPatternHash` values (the request
pattern and the render-prepared result), so loading the same description twice
yields the same key and hits the cache ([`src/ft/mod.rs`][ft]).

### 2. Face loading and table access

Loading is description-driven only: `load_font(&FontDesc, Size)`. FreeType
builds an `FcPattern` with `family`, `pixelsize`, and either `weight`+`slant`
or `style`, runs `FcConfigSubstitute`/`FcDefaultSubstitute`, then
`FcFontSort(trim = 0)`; the first result goes through `FcFontRenderPrepare`
and its `file`/`index` open an `FT_Face` (`FtFaceLocation`). The render-prepared
pattern then dictates every FreeType flag — `antialias`, `autohint`, `hinting`,
`hintstyle`, `rgba`, `lcdfilter`, `embeddedbitmap`, `embolden`, `matrix`,
`pixelsizefixupfactor` — so fontconfig's `~/.config/fontconfig/fonts.conf`
is the user's rendering settings UI
([`src/ft/mod.rs`][ft], [`src/ft/fc/pattern.rs`][pattern]). `load_font` also
calls `FcInitBringUptoDate` once two seconds after construction, picking up
newly installed fonts. No table access exists; the only table read is the
`OS/2` strikeout pair via `freetype-rs`'s `TrueTypeOS2Table`.

### 3. Shaping

None. `GlyphKey.character: char` is mapped with `FT_Get_Char_Index` /
`CTFontGetGlyphsForCharacters` / `GetGlyphIndices` one codepoint at a time.
`kerning()` is `FT_Get_Kerning(FT_KERNING_DEFAULT)` on FreeType and a constant
`(0., 0.)` on both other backends. Alacritty draws grapheme clusters by
overdrawing cells, so ligatures are structurally impossible here.

### 4. Variation and instances

Absent. There is no axis API; a variable font renders at its default instance
unless fontconfig's `FcFontRenderPrepare` yields a named instance via the
`index` high bits, which `crossfont` passes through unexamined as `FT_Face`
index.

### 5. Rasterization and outlines

No outline API — the trait returns bitmaps only. Each backend renders with its
native engine and normalizes to `BitmapBuffer`:

- **FreeType** (`get_glyph`): set `FT_Library_SetLcdFilter` per face, load with
  the fontconfig-derived `LoadFlag`s, optionally `FT_GlyphSlot_Embolden`
  (synthetic bold) and `FT_Outline_Transform` with the fontconfig matrix
  (synthetic italic), `render_glyph(render_mode)`, then `normalize_buffer`
  expands `Mono`/`Gray`/`Lcd`/`LcdV` to three bytes per pixel honouring
  `Rgba::Bgr`/`Vbgr` channel order, and `Bgra` to premultiplied RGBA. Colour
  bitmap strikes (`has_color && !is_scalable`) select strike 0 and are
  box-filter downsampled by fontconfig's `pixelsizefixupfactor`
  (`downsample_bitmap`). Scalable colour fonts are filtered out of the fallback
  list ("Ignore colored outline fonts, since we can not render them") —
  the pinned commit's whole subject ([`src/ft/mod.rs`][ft]).
- **Core Text**: `CTFontGetBoundingRectsForGlyphs` sizes a
  `CGBitmapContext` (premultiplied first, host byte order), fills black,
  enables smoothing per the `AppleFontSmoothing` user default (the full
  `NSNumber`/`NSString` type dance is in-tree), subpixel quantization and
  positioning on, draws white, and `extract_rgb`/`extract_rgba` split the
  result ([`src/darwin/mod.rs`][darwin]).
- **DirectWrite**: a one-glyph `DWRITE_GLYPH_RUN`, the face's
  `GetRecommendedRenderingMode`, `IDWriteGlyphRunAnalysis` with
  `DWRITE_TEXTURE_CLEARTYPE_3x1`, `CreateAlphaTexture` → `Rgb`
  ([`src/directwrite/mod.rs`][dw]).

No gamma handling, no atlas (Alacritty owns the atlas), no caching of bitmaps
(Alacritty caches `RasterizedGlyph`s by `GlyphKey`). `Metrics.average_advance`
is the terminal's cell width, so every bitmap's `left`/`top`/`advance` are
relative to a cell the caller already laid out.

### 6. Metrics and measurement

`Metrics` is in **device pixels at the loaded size**, not font units — the
opposite of [`./font-kit.md`](./font-kit.md). The set is exactly what a
terminal paints: cell advance, line height, descent, underline and strikeout
position/thickness. Sources differ per backend and are hidden:

| Field             | FreeType                                                             | Core Text                                                   | DirectWrite                                    |
| ----------------- | -------------------------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------- |
| `average_advance` | `horiAdvance` of `'0'`, else `size_metrics.max_advance`              | advance of `'0'`                                            | `advanceWidth` of `'!'` × scale                |
| `line_height`     | `max(size_metrics.height, ascender − descender)`                     | `round(ascent) + round(descent) + round(leading)`           | `ascent − descent + lineGap` from `metrics0()` |
| underline         | `FT_FaceRec` values × `x_scale`; if zero, synthesized from `descent` | `CTFontGetUnderlinePosition/Thickness`                      | `underlinePosition/Thickness` × scale          |
| strikeout         | `OS/2` `yStrikeoutPosition/Size`; fallback `height/2 + descent`      | synthesized: `line_height/2 − descent`, underline thickness | `strikethroughPosition/Thickness` × scale      |

The "sanity checks" live in the fallbacks: a bitmap font with zero underline
metrics gets `thickness = round(|descent| / 5)`, `position = descent / 2`; a
font with no `OS/2` gets a strikeout at mid-height. `average_advance` is
measured from one glyph (`'0'` or `'!'`) rather than `OS/2` `xAvgCharWidth` —
a monospace assumption baked into the metric set ([`src/ft/mod.rs`][ft],
[`src/darwin/mod.rs`][darwin], [`src/directwrite/mod.rs`][dw]).

### 7. Discovery, matching and fallback

Discovery is delegated wholesale. Matching: fontconfig `FcFontSort` on Linux;
on macOS `CTFontCollectionCreateWithFontDescriptors` for the family, then
either a `style_name == "Bold Italic"` string compare (`Style::Specific`) or
`symbolic_traits().is_bold()/is_italic()` (`Style::Description`), with a
hard-coded fallback to `Menlo` when the family is missing; on Windows
`IDWriteFontFamily::GetFirstMatchingFont(weight, Normal, style)` or a
`face_name()` scan.

Per-codepoint fallback is the crate's one sophisticated mechanism, and it is
charset-driven on FreeType: the rest of the `FcFontSort` list becomes a
`FallbackList { requested_pattern, list: Vec<FallbackFont>, coverage: CharSet }`
(each `FallbackFont` is `Ref` until first use, then `Rendered`),
where each candidate is kept only if `coverage.merge(charset)` reports it adds
codepoints (`FcCharSetMerge`), so dominated fonts are dropped before any face
opens. `face_for_glyph` first checks the primary face's `cmap`, then
`coverage.has_char(c)` as a global early-out, then walks the list lazily
`FcFontRenderPrepare`-ing and opening faces on first use
([`src/ft/mod.rs`][ft], [`src/ft/fc/char_set.rs`][charset]). Core Text uses
`CTFontCopyDefaultCascadeListForLanguages` with a hard-coded `["en"]`, drops
descriptors whose `kCTFontEnabledAttribute` is false, and appends
`Apple Symbols` by hand because the `.Apple Symbol Fallback` entries cannot be
loaded by path. DirectWrite calls `IDWriteFontFallback::MapCharacters` with
the user's locale for each missing glyph. No classification data (PANOSE,
`OS/2` family class) is consulted anywhere.

Compared with Ghostty's `Collection` — a deferred-loading multi-face set with
explicit style slots, codepoint-map overrides and a `Descriptor` that carries
variation axes ([`./ghostty.md`](./ghostty.md)) — `crossfont` has no
collection object at all: the fallback list is private to one `FontKey`, there
is no user override of which face serves which codepoint, and bold/italic are
separate `load_font` calls the terminal must correlate itself.

## What it teaches `sparkles:font`

- **A terminal's metric set is seven numbers in device pixels:** cell advance,
  line height, descent, underline ×2, strikeout ×2. Make that a named struct at
  the top of the API and derive it from the face metrics in one place, with
  the bitmap-font and missing-`OS/2` fallbacks `crossfont` learned the hard way.
- **Measure cell width from a glyph, but say which one.** `'0'` on two
  backends and `'!'` on the third is a latent cross-platform inconsistency;
  pick `'0'` (or `xAvgCharWidth` when `OS/2` is trustworthy) and document it.
- **Charset-pruned, lazily opened fallback lists** (`FcCharSetMerge` to drop
  dominated fonts, open faces on first miss) are the right shape for a
  terminal; port the mechanism and back it with the own `cmap` parser instead
  of fontconfig's charset where fontconfig is absent (macOS, Android).
- **Let fontconfig's render-prepared pattern own rendering policy on Linux.**
  `hintstyle`/`rgba`/`lcdfilter`/`embolden`/`matrix` → FreeType flags is a
  ~70-line table worth copying verbatim.
- **Return the `.notdef` bitmap inside the error.** `Error::MissingGlyph(RasterizedGlyph)`
  lets the caller draw something and cache the miss in one step.
- **Do not key glyphs by `char`.** It forbids ligatures and shaped fallback;
  key by `(face, glyph id, size, subpixel bucket)` and keep a separate
  `char → face` cache.

## Strengths

- Minimal: one trait, five methods, a hundred lines of shared types; a new
  backend is one file.
- Fontconfig integration is faithful — user `fonts.conf` rendering settings
  are honoured flag for flag, including synthetic bold/italic and LCD channel
  order.
- Fallback list pruning by charset coverage is cheap and correct for the
  monospace case.
- Carries real production mileage: Alacritty's font stack since 2016.

## Weaknesses

- No outlines, no shaping, no variation axes, no table access — unusable as a
  base for a code viewer or inspector.
- Caches grow forever; `Rc`/raw-pointer internals need `unsafe impl Send`.
- `GlyphKey` is per character; bold/italic are separate fonts with no
  collection semantics.
- Metrics differ in source and rounding per platform behind one struct.
- Scalable colour (SVG/`COLR`) fonts are skipped outright; only bitmap colour
  strikes render.
- Hard-coded `"en"` cascade list on macOS and `Menlo` fallback; `Weight` has
  two values.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                         | Trade-off                                                                     |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| One `Rasterize` trait, compile-time backend                   | Terminal needs bitmaps and seven metrics; native engines already match user prefs | No runtime engine choice; FreeType cannot be used on macOS for A/B comparison |
| `GlyphKey { character, font_key, size }`                      | A cell holds one character; cache key is obvious                                  | No ligatures, no glyph-id addressing, shaping impossible                      |
| `Metrics` in device pixels at load size                       | The renderer consumes them directly                                               | Re-load on every size change; `Size` is part of the identity                  |
| `FontKey` = XOR of two fontconfig pattern hashes              | Same request → same key → cache hit without a lookup table                        | Key stability depends on fontconfig's hash; opaque elsewhere (atomic counter) |
| Fallback list pruned by `FcCharSetMerge`, faces opened lazily | Hundreds of candidates, few ever used                                             | Charset is fontconfig's cached view, can disagree with the real `cmap`        |
| Rendering policy read from the render-prepared `FcPattern`    | User's `fonts.conf` is the settings UI                                            | Linux-only; macOS/Windows have fixed policies (`AppleFontSmoothing` aside)    |
| `Error::MissingGlyph(RasterizedGlyph)`                        | Caller draws `.notdef` and caches the miss                                        | Error type is large and not `Copy`                                            |
| `unsafe impl Send` on `Rc`-holding rasterizers                | Alacritty renders on one thread; the type merely moves there                      | Soundness rests on usage discipline, not the type system                      |
| No eviction from any cache                                    | Alacritty loads a handful of fonts                                                | README-documented leak for font-heavy apps                                    |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- [`src/lib.rs`][lib] — `Rasterize`, `FontDesc`, `Style`, `Size`, `FontKey`,
  `GlyphKey`, `RasterizedGlyph`, `BitmapBuffer`, `Metrics`, `Error`.
- [`src/ft/mod.rs`][ft] — `FreeTypeRasterizer`, `FreeTypeLoader`,
  `FallbackList`, `FaceLoadingProperties`, `ft_load_flags`, `normalize_buffer`,
  `downsample_bitmap`, metric fallbacks.
- [`src/ft/fc/mod.rs`][fc], [`src/ft/fc/pattern.rs`][pattern],
  [`src/ft/fc/char_set.rs`][charset] — the fontconfig wrapper
  (`font_sort(trim=0)`, `render_prepare`, `PatternHash`, `CharSet::merge`).
- [`src/darwin/mod.rs`][darwin] — Core Text backend, cascade list,
  `AppleFontSmoothing`, `CGBitmapContext` raster.
- [`src/directwrite/mod.rs`][dw] — DirectWrite backend, `IDWriteFontFallback`,
  `DWRITE_TEXTURE_CLEARTYPE_3x1`.
- [`Cargo.toml`][cargo], [`README.md`][readme], [`CHANGELOG.md`][changelog],
[`LICENSE`][license].
<!-- References -->

[repo]: https://github.com/alacritty/crossfont
[license]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/LICENSE
[cargo]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/Cargo.toml
[readme]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/README.md
[changelog]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/CHANGELOG.md
[lib]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/src/lib.rs
[ft]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/src/ft/mod.rs
[fc]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/src/ft/fc/mod.rs
[pattern]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/src/ft/fc/pattern.rs
[charset]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/src/ft/fc/char_set.rs
[darwin]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/src/darwin/mod.rs
[dw]: https://github.com/alacritty/crossfont/blob/0c34d199b1515389bbed48a0338018e45817876e/src/directwrite/mod.rs
