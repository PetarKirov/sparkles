# Skia (C++ / Chrome, Android, Flutter)

Google's 2D library ships a complete platform-abstracted text stack: an
immutable refcounted `SkTypeface`, a small value-type `SkFont` that adds size
and rendering flags, an `SkFontMgr` virtual interface with one port per
platform, a private `SkScalerContext` seam that every glyph backend implements,
and `SkShaper` / `SkParagraph` modules on top that drive HarfBuzz.

| Field            | Value                                                                                                                          |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Language         | C++17 (plus a Rust `fontations` backend over `skrifa` / `read-fonts`)                                                          |
| License          | BSD-3-Clause ([`LICENSE`][license])                                                                                            |
| Repository       | [`google/skia`][repo]                                                                                                          |
| Documentation    | Doc comments in `include/core/*.h`; [skia.org][site]                                                                           |
| Category         | platform text stack                                                                                                            |
| Layer(s) covered | parse (via ports) · discover · match/fallback · shape (`modules/skshaper`) · raster · outline · layout (`modules/skparagraph`) |
| Pinned revision  | `3ad790ab4d6d596efae0d70e4b8bf7d339121984` (2026-08-13)                                                                        |

## Overview

### What it solves

Skia must draw text identically-enough on Linux, Android, macOS, iOS, Windows
and Fuchsia while honouring each platform's native font configuration and
rasterizer. It therefore does not own a font parser of its own: each port
supplies a typeface subclass (`SkTypeface_FreeType`, `SkTypeface_Mac`,
`DWriteFontTypeface`, `SkTypeface_Fontations`) and a matching
`SkScalerContext` that turns glyph ids into masks, paths and drawables. Skia
owns everything above that seam: the glyph cache, mask gamma, subpixel
positioning, GPU atlases, and the public `SkFont` measuring API.

### Design philosophy

The typeface header states the sharing rule outright:

```cpp
/** \class SkTypeface

    The SkTypeface class specifies the typeface and intrinsic style of a font.
    This is used in the paint, along with optionally algorithmic settings like
    textSize, textSkewX, textScaleX, kFakeBoldText_Mask, to specify
    how text appears when drawn (and measured).

    Typeface objects are immutable, and so they can be shared between threads.
*/
class SK_API SkTypeface : public SkWeakRefCnt {
```

— [`include/core/SkTypeface.h`][typeface-h]

Construction is deliberately routed through a font manager: at the pin
`SkTypeface` has no public `MakeFromFile` / `MakeFromData`; only `MakeEmpty`,
`MakeDeserialize` and `makeClone(const SkFontArguments&)` remain, and bytes
become a typeface via `SkFontMgr::makeFromData` / `makeFromStream` /
`makeFromFile` ([`include/core/SkFontMgr.h`][fontmgr-h]). The backend that
parses the bytes is therefore always a choice of the manager.

## How it works

- **`SkTypeface`** (refcounted, `SkWeakRefCnt`): unsized face. Pure virtuals
  `onCreateScalerContext`, `onFilterRec`, `onOpenStream`, `onMakeClone`,
  `onGetVariationDesignPosition`, `onGetVariationDesignParameters` and the
  table hooks are what a port implements ([`SkTypeface.h`][typeface-h]).
- **`SkFont`** (value type, `sk_is_trivially_relocatable`): `sk_sp<SkTypeface>`
  plus `size`, `scaleX`, `skewX`, `Edging` (`kAlias`, `kAntiAlias`,
  `kSubpixelAntiAlias`), `SkFontHinting` (`kNone`, `kSlight`, `kNormal`,
  `kFull`) and flags (`subpixel`, `linearMetrics`, `embolden`,
  `forceAutoHinting`, `embeddedBitmaps`, `baselineSnap`)
  ([`SkFont.h`][font-h], [`SkFontTypes.h`][fonttypes-h]).
- **`SkScalerContextRec`**: the canonicalised key — `fTextSize`,
  `fPreScaleX`, `fPreSkewX`, `fPost2x2[2][2]`, `fMaskFormat`, gamma/contrast,
  flags — serialised into an `SkDescriptor` that keys the strike cache
  ([`src/core/SkScalerContext.h`][scaler-h]). Each typeface may clamp the rec
  in `onFilterRec` (e.g. disable LCD where the backend cannot do it).
- **`SkScalerContext`**: the rasterization seam with four virtuals:
  `generateMetrics`, `generateImage`, `generatePath`, `generateDrawable`, plus
  `generateFontMetrics`.
- **`SkStrike` / `SkStrikeCache`**: per-descriptor glyph cache guarded by
  `fStrikeLock`, globally budgeted (`SK_DEFAULT_FONT_CACHE_LIMIT` 2 MiB,
  `SK_DEFAULT_FONT_CACHE_COUNT_LIMIT` 2048) under one `SkMutex`
  ([`SkStrikeCache.h`][strikecache-h], [`SkStrike.h`][strike-h]).

## Analysis spine

### 1. Layering and ownership

| Layer       | Type                          | Ownership                                                    | Thread-safety                                 |
| ----------- | ----------------------------- | ------------------------------------------------------------ | --------------------------------------------- |
| bytes       | `SkData`, `SkStreamAsset`     | `sk_sp<SkData>` (non-virtual refcount), `unique_ptr` streams | immutable `SkData`                            |
| face        | `SkTypeface`                  | `sk_sp`, weak refs for caches                                | immutable, shared                             |
| sized font  | `SkFont`                      | value, holds `sk_sp<SkTypeface>`                             | value semantics, copy per thread              |
| rasterizer  | `SkScalerContext` (private)   | `unique_ptr`, owned by `SkStrike`                            | used under `fStrikeLock`                      |
| glyph cache | `SkStrike`, `SkStrikeCache`   | global singleton, LRU purge                                  | per-strike lock + cache `SkMutex`             |
| discovery   | `SkFontMgr`, `SkFontStyleSet` | `sk_sp`                                                      | per-port; fontconfig port takes a global lock |
| shaping     | `SkShaper`                    | `unique_ptr`, non-copyable                                   | one per thread                                |

The error model is nullable `sk_sp` returns ("will return nullptr if no
'good' match is found") and `-1` / `0` sentinel counts; there is no error
object. The fontconfig port documents why its own lock exists: "FontConfig was
thread antagonistic until 2.10.91 with known thread safety issues until
2.13.93. Before that, lock with a global mutex."
([`SkFontMgr_fontconfig.cpp`][fc-cpp]).

**Binding hazard (sparkles prior finding).** `sk_sp<T>` is declared
`SK_TRIVIAL_ABI` (`[[clang::trivial_abi]]` when available). nixpkgs builds
Skia with gcc on Linux and clang on Darwin, so every factory that returns
`sk_sp` by value — i.e. every `SkFontMgr::match*` and `makeFrom*` above —
returns via Itanium sret on one target and in a register on the other. A D
`extern(C++)` declaration links cleanly and returns garbage on the wrong one.
The sparkles Skia shim therefore lets only primitives and pointers cross the
boundary; any D binding to `SkFontMgr` must go through a C shim too.

### 2. Face loading and table access

Bytes enter via `SkFontMgr::makeFromData (sk_sp<SkData>, ttcIndex)`,
`makeFromStream (unique_ptr<SkStreamAsset>, ttcIndex)`, the experimental
`makeFromStream (stream, const SkFontArguments&)` and `makeFromFile (path,
ttcIndex)`; the Rust backend has its own `SkTypeface_Make_Fontations`
([`include/ports/SkTypeface_fontations.h`][fontations-h]). `SkFontArguments`
carries collection index, variation position, palette and synthetic
bold/oblique together ([`SkFontArguments.h`][fontargs-h]).

Raw tables are exposed, but by copy:

```cpp
    int countTables() const;
    int readTableTags(SkSpan<SkFontTableTag> tags) const;
    size_t getTableSize(SkFontTableTag) const;
    size_t getTableData(SkFontTableTag tag, size_t offset, size_t length,
                        void* data) const;
    sk_sp<SkData> copyTableData(SkFontTableTag tag) const;
```

— [`include/core/SkTypeface.h`][typeface-h]

`openStream (int* ttcIndex)` returns the whole file. This "copy out" contract
exists because CoreText and DirectWrite typefaces have no contiguous file to
borrow from; the HarfBuzz shaper glue reflects it by first trying
`openExistingStream` + `hb_face_create`, and falling back to
`hb_face_create_for_tables (skhb_get_table, …)` that copies each table on
demand ([`SkShaper_harfbuzz.cpp`][hb-cpp]).

### 3. Shaping

`SkShaper` is a separate module. Factories: `SkShapers::HB::ShaperDrivenWrapper`,
`ShapeThenWrap`, `ShapeDontWrapOrReorder` (HarfBuzz + `SkUnicode` for ICU
bidi/line-break), `SkShapers::CT::CoreText`, and a `Primitive` fallback
([`SkShaper_harfbuzz.h`][hb-h], [`SkShaper_coretext.h`][ct-h]). Input is UTF-8
plus four run iterators — `FontRunIterator`, `BiDiRunIterator`,
`ScriptRunIterator`, `LanguageRunIterator` — each a `consume` /
`endOfCurrentRun` / `atEnd` cursor; `MakeFontMgrRunIterator` performs
per-codepoint fallback through an `SkFontMgr`. Features are
`Feature { tag, value, start, end }` in UTF-8 offsets. Output is a push-style
sink:

```cpp
        struct Buffer {
            SkGlyphID* glyphs;  // required
            SkPoint* positions; // required, if (!offsets) put glyphs[i] at positions[i]
                                //           if ( offsets) positions[i+1]-positions[i] are advances
            SkPoint* offsets;   // optional, if ( offsets) put glyphs[i] at positions[i]+offsets[i]
            uint32_t* clusters; // optional, utf8+clusters[i] starts run which produced glyphs[i]
            SkPoint point;      // offset to add to all positions
        };
```

— [`modules/skshaper/include/SkShaper.h`][shaper-h]

The `RunHandler` lifecycle (`beginLine`, `runInfo` × N, `commitRunInfo`,
`runBuffer` → `commitRunBuffer` × N, `commitLine`) lets the handler compute
line metrics before glyphs are written, and the handler owns the glyph
storage. Positions are `SkPoint` floats in the font's size units (pixels at
identity matrix). The HarfBuzz glue sets `hb_font_set_scale` to the font size
in 16.16 and installs Skia-backed `nominal_glyph`, `h_advance(s)` and
`glyph_extents` funcs over a parent `hb_ot` font, so advances may be hinted.
`SkParagraph` adds styling, line breaking and a `FontCollection` with layered
managers (`setAssetFontManager`, `setDynamicFontManager`,
`setDefaultFontManager`) ([`FontCollection.h`][paragraph-fc-h]).

### 4. Variation and instances

Coordinates are user-space `{SkFourByteTag axis; float value;}` with
constants for `wght`, `wdth`, `slnt`, `ital`, `opsz`. They live on the
**typeface**, not the font: `makeClone (SkFontArguments)` returns a new
`SkTypeface` at that position, and "Any axis not specified will use the
default value. Any specified axis not actually present in the font will be
ignored." ([`SkFontArguments.h`][fontargs-h]). Introspection is
`getVariationDesignPosition (span)` and `getVariationDesignParameters (span)`
(axis tag, min, default, max, hidden). `SkTypeface` itself has no
named-instance API. Named instances surface one level down, in
`SkFontScanner::scanInstance` ("instanceIndex 0 is the default instance, 1 to
numInstances are the named instances"), which managers use to index a file
into one typeface record per instance ([`SkFontScanner.h`][scanner-h]).

Coordinates reach shaping by re-reading them: the HarfBuzz glue calls
`typeface.getVariationDesignPosition` and `hb_font_set_variations`
([`SkShaper_harfbuzz.cpp`][hb-cpp]); they reach rasterization because the
scaler context is created from the cloned typeface. Normalized coordinates
are never public. Variable fonts also cause `SkFontMetrics` to deprecate
`fTop`/`fBottom`/`fXMin`/`fXMax` ([`SkFontMetrics.h`][metrics-h]).

### 5. Rasterization and outlines

Outlines: `std::optional<SkPath> SkFont::getPath (SkGlyphID)` — "If it is not
(e.g. it is represented with a bitmap) return {}" — and a batched
`getPaths (glyphs, proc, ctx)` callback that receives a path plus an
`SkMatrix` ([`SkFont.h`][font-h]). Units: the font's size (pixels),
y-down. `SkPath` is a retained object; quadratics and cubics are kept native.

Raster formats come from `SkMask::Format`: `kBW`, `kA8`, `k3D`, `kARGB32`
(color), `kLCD16` (565 subpixel), `kSDF` ([`SkMask.h`][mask-h]). The scaler
contract is two-phase — `generateMetrics` sizes the glyph, then
`generateImage` fills a preallocated buffer — with
`GenerateImageFromPath` as Skia's own CPU fallback rasterizer for any backend
that only produces paths (e.g. Fontations). Mask gamma and contrast are
applied by a pre-blend table (`SK_GAMMA_EXPONENT`, `SK_GAMMA_CONTRAST` in
[`SkScalerContext.cpp`][scaler-cpp]). Subpixel positioning quantises x/y to
`kSubPixelPosLen = 2` bits (4 positions) packed into `SkPackedGlyphID`
([`SkGlyph.h`][glyph-h]).

Color glyphs: `COLRv1` is rendered by the FreeType port through
`FT_Get_Color_Glyph_Paint` into an `SkCanvas`
([`SkFontHost_FreeType_common.cpp`][ft-common]) and by the Fontations port
through a `ColorPainter` over `skrifa` ([`colr.rs`][colr-rs]); both surface as
`generateDrawable`, which also returns `sbix`/`CBDT` images and `SVG`.
`SkFontArguments::Palette` selects `CPAL` palette and per-entry overrides.
GPU text (Ganesh/Graphite) draws from the same strikes into atlases, choosing
direct masks, SDF (`kSDF_Format`) or paths by size.

### 6. Metrics and measurement

`SkFont::getMetrics (SkFontMetrics*)` returns line spacing (`descent - ascent

- leading`) and fills `fAscent`(negative, y-down),`fDescent`, `fLeading`,
`fAvgCharWidth`, `fMaxCharWidth`, `fXHeight`, `fCapHeight`, underline and
strikeout, with `fFlags` bits saying which are valid
(`kUnderlineThicknessIsValid_Flag`, …, `kBoundsInvalid_Flag`)
([`SkFontMetrics.h`][metrics-h]). The source tables are the port's choice;
the FreeType port uses `OS/2` `sTypo\*`only when`fsSelection`bit 7 is set,
else FreeType's`hhea`-derived `ascender`/`descender`, and synthesises
x-height and cap-height from glyph outlines when `OS/2` lacks them
([`SkFontHost_FreeType.cpp`][ft-host]). Per glyph: `getWidthsBounds`,
`getPos`, `getXPos`, `measureText`, `getIntercepts`(underline gaps). All
values are scaled to the font size;`setLinearMetrics` opts out of hinted
  advances.

### 7. Discovery, matching and fallback

`SkFontMgr` is the abstraction: enumerate (`countFamilies`,
`getFamilyName`, `createStyleSet` → `SkFontStyleSet::count`/`getStyle`/
`createTypeface`), match (`matchFamily`, `matchFamilyStyle`,
`SkFontStyleSet::matchStyleCSS3` — CSS3 weight/width/slant nearest), and
per-codepoint fallback:

```cpp
    sk_sp<SkTypeface> matchFamilyStyleCharacter(const char familyName[], const SkFontStyle&,
                                                const char* bcp47[], int bcp47Count,
                                                SkUnichar character) const;
```

At the pin a newer `Request`-based pair is landing: `match (Request)` ("The
familyName must strongly match, everything else is tie breakers") and
`fallback (Request)` ("The first cmapEntry must match. Then matched by bcp47,
then familyName, then model (italic, slant, width, weight), with synthetics
allowed or not"), where `cmapEntries` carry a codepoint plus variation
selector and `model` is a variation position — style expressed as axes
([`SkFontMgr.h`][fontmgr-h]).

Ports: `SkFontMgr_New_FontConfig (FcConfig*, unique_ptr<SkFontScanner>)`
builds an `FcPattern` with `FC_CHARSET`, `FC_LANG` and a weak family, runs
`FcConfigSubstitute` + `FcDefaultSubstitute` + `FcFontMatch`
([`SkFontMgr_fontconfig.cpp`][fc-cpp]); CoreText calls
`CTFontCreateForStringWithLanguage` ([`SkFontMgr_mac_ct.cpp`][mac-cpp]);
DirectWrite uses `IDWriteFontFallback::MapCharacters`, or a
`FontFallbackRenderer` text-layout trick on older Windows
([`SkFontMgr_win_dw.cpp`][dw-cpp]); `SkFontMgr_New_Custom_Directory (dir)`
scans a directory with FreeType ([`SkFontMgr_directory.h`][dir-h]). The
`SkFontScanner` parameter decouples "parse a file into face records" from
the matcher, so fontconfig matching can use the Fontations parser.

## What it teaches `sparkles:font`

- **Make the rasterizer a private seam keyed by a canonical record.**
  `SkScalerContextRec` → `SkDescriptor` → `SkStrike` gives one cache key for
  size, matrix, mask format and gamma; every backend fills the same two-phase
  `metrics` then `image` contract. A D `GlyphKey` struct + `Rasterizer`
  interface maps directly.
- **Ship a path-to-mask fallback.** `GenerateImageFromPath` means a backend
  only needs outlines; a from-scratch D parser gets rasterization for free
  once it emits paths.
- **Separate the file scanner from the matcher** (`SkFontScanner`), so the
  fontconfig/CoreText index and the own parser are independently swappable.
- **Expose metric validity bits**, not zeros: `SkFontMetrics::fFlags` is the
  pattern an inspector and a terminal (underline placement) both need.
- **Model style as axis coordinates in fallback requests** (`Request::model`),
  which unifies static families and variable fonts.
- **Never return refcounted smart pointers by value across a C ABI** — the
  sparkles Skia shim already learned this.

## Strengths

- One API over five native font stacks plus a Rust parser, with a common glyph
  cache, gamma model and GPU atlas path.
- Clean push-sink shaper interface with pluggable itemisation iterators.
- `COLRv1`, `CPAL` palette overrides, `sbix`, `CBDT`, `SVG` all supported.
- Metric validity flags and synthesised x/cap height.

## Weaknesses

- Raw tables only by copy; no borrowed view of font bytes.
- Variation coordinates on the typeface force a new `SkTypeface` per instance;
  no named-instance or normalized-coordinate API.
- No error channel beyond `nullptr` and `-1`.
- `sk_sp` by-value ABI is compiler-dependent, making non-C++ bindings costly.
- Font metric selection rules differ per port, so cross-platform metrics are
  only approximately equal.

## Key design decisions and trade-offs

| Decision                               | Rationale                                                | Trade-off                                              |
| -------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------ |
| Typeface creation only via `SkFontMgr` | The port decides which parser/rasterizer backs the bytes | Cannot load a file without picking a manager           |
| `SkFont` as a small value type         | Cheap copies per draw call; no shared mutable state      | Every measuring call rebuilds or looks up a descriptor |
| Private `SkScalerContext` seam         | Native rasterizers per platform; one cache above         | Rendering differs per platform by design               |
| Global budgeted `SkStrikeCache`        | Bounded memory across all fonts and threads              | Global lock; tuning by `-D` macros                     |
| Table access by copy                   | CoreText/DirectWrite have no contiguous file             | Inspector and shaper pay copies                        |
| Shaper as a module with run iterators  | Core stays HarfBuzz/ICU-free                             | Itemisation and fallback live outside `SkFontMgr`      |
| Variations via `makeClone`             | Typeface stays immutable                                 | One typeface object per coordinate set                 |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Core API** — [`SkTypeface.h`][typeface-h], [`SkFont.h`][font-h],
  [`SkFontTypes.h`][fonttypes-h], [`SkFontMgr.h`][fontmgr-h],
  [`SkFontArguments.h`][fontargs-h], [`SkFontMetrics.h`][metrics-h],
  [`SkFontScanner.h`][scanner-h].
- **Raster seam and cache** — [`SkScalerContext.h`][scaler-h],
  [`SkScalerContext.cpp`][scaler-cpp], [`SkStrike.h`][strike-h],
  [`SkStrikeCache.h`][strikecache-h], [`SkGlyph.h`][glyph-h],
  [`SkMask.h`][mask-h].
- **Ports** — [`SkFontMgr_fontconfig.cpp`][fc-cpp],
  [`SkFontMgr_mac_ct.cpp`][mac-cpp], [`SkFontMgr_win_dw.cpp`][dw-cpp],
  [`SkFontMgr_custom_directory.cpp`][dir-cpp], [`SkFontMgr_directory.h`][dir-h],
  [`SkFontMgr_fontconfig.h`][fc-h], [`SkFontHost_FreeType.cpp`][ft-host],
  [`SkFontHost_FreeType_common.cpp`][ft-common],
  [`SkTypeface_fontations.cpp`][fontations-cpp],
  [`SkTypeface_fontations.h`][fontations-h], [`ffi.rs`][ffi-rs],
  [`colr.rs`][colr-rs].
- **Shaping and layout** — [`SkShaper.h`][shaper-h],
  [`SkShaper_harfbuzz.h`][hb-h], [`SkShaper_coretext.h`][ct-h],
  [`SkShaper_harfbuzz.cpp`][hb-cpp], [`FontCollection.h`][paragraph-fc-h].
- Siblings: [`./harfbuzz.md`](./harfbuzz.md), [`./freetype.md`](./freetype.md),
  [`./fontconfig.md`](./fontconfig.md), [`./coretext.md`](./coretext.md),
  [`./directwrite.md`](./directwrite.md), [`./fontations.md`](./fontations.md).

<!-- References -->

[repo]: https://github.com/google/skia
[site]: https://skia.org/
[license]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/LICENSE
[typeface-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkTypeface.h
[font-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkFont.h
[fonttypes-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkFontTypes.h
[fontmgr-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkFontMgr.h
[fontargs-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkFontArguments.h
[metrics-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkFontMetrics.h
[scaler-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkScalerContext.h
[scaler-cpp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkScalerContext.cpp
[strike-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkStrike.h
[strikecache-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkStrikeCache.h
[glyph-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkGlyph.h
[mask-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkMask.h
[fc-cpp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/ports/SkFontMgr_fontconfig.cpp
[fc-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/ports/SkFontMgr_fontconfig.h
[mac-cpp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/ports/SkFontMgr_mac_ct.cpp
[dw-cpp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/ports/SkFontMgr_win_dw.cpp
[dir-cpp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/ports/SkFontMgr_custom_directory.cpp
[dir-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/ports/SkFontMgr_directory.h
[ft-host]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/ports/SkFontHost_FreeType.cpp
[ft-common]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/ports/SkFontHost_FreeType_common.cpp
[fontations-cpp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/ports/SkTypeface_fontations.cpp
[fontations-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/ports/SkTypeface_fontations.h
[ffi-rs]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/ports/fontations/src/ffi.rs
[colr-rs]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/ports/fontations/src/colr.rs
[shaper-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skshaper/include/SkShaper.h
[hb-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skshaper/include/SkShaper_harfbuzz.h
[ct-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skshaper/include/SkShaper_coretext.h
[hb-cpp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skshaper/src/SkShaper_harfbuzz.cpp
[scanner-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkFontScanner.h
[paragraph-fc-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skparagraph/include/FontCollection.h
