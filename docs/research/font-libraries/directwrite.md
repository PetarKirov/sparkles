# DirectWrite (C++ COM / Windows)

Windows' system text stack: a COM object ladder `IDWriteFactory` →
`IDWriteFontCollection` → `IDWriteFontFamily` → `IDWriteFont` →
`IDWriteFontFace`, a stateless `IDWriteTextAnalyzer` that shapes in two calls
(`GetGlyphs`, `GetGlyphPlacements`), an `IDWriteGeometrySink` callback for
outlines, and `IDWriteFontFallback::MapCharacters` for per-run fallback.

| Field            | Value                                                                                                |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| Language         | C++ COM interfaces (`dwrite.h`, `dwrite_1.h` … `dwrite_3.h`, `dcommon.h`); any COM-capable language  |
| License          | Proprietary, ships in `dwrite.dll` with Windows; DWriteCore redistributes it via the Windows App SDK |
| Repository       | none (closed source)                                                                                 |
| Documentation    | [DirectWrite reference on Microsoft Learn][dwrite-ref]                                               |
| Category         | platform text stack                                                                                  |
| Layer(s) covered | parse · discover · match/fallback · shape · raster · outline · layout                                |
| Pinned revision  | n/a (Microsoft Learn documentation, retrieved 2026-10-03)                                            |

## Overview

### What it solves

DirectWrite gives a Windows process everything between "a family name and a
string" and "an alpha mask or an outline": the system font set with name
matching, font fallback, script itemization, bidi, OpenType shaping, glyph
metrics, outline extraction, and ClearType/grayscale rasterization into alpha
textures (`IDWriteGlyphRunAnalysis`). Above it sits `IDWriteTextLayout`
(paragraph layout) and Direct2D (drawing); below it, a pluggable file-loader
seam (`IDWriteFontFileLoader` / `IDWriteFontFileStream`).

### Design philosophy

The factory is a process-wide cache, and its sharing mode is the one explicit
architectural knob:

> A DirectWrite factory object contains information about its internal state,
> such as font loader registration and cached font data. In most cases you
> should use the shared factory object, because it allows multiple components
> that use DirectWrite to share internal DirectWrite state information, thereby
> reducing memory usage. However, there are cases when it is desirable to reduce
> the impact of a component on the rest of the process, such as a plug-in from
> an untrusted source, by sandboxing and isolating it from the rest of the
> process components.
>
> — [`DWRITE_FACTORY_TYPE`][factory-type]

`DWRITE_FACTORY_TYPE_SHARED` additionally "take[s] advantage of cross process
font caching components" ([`DWRITE_FACTORY_TYPE`][factory-type]) — the system
font cache service. The API evolves by interface versioning: `IDWriteFontFace`
grew to `IDWriteFontFace7`, `IDWriteFactory` to `IDWriteFactory8`, each obtained
by `QueryInterface`; nothing is ever removed.

## How it works

`DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, …)` yields the factory;
`GetSystemFontCollection` gives the installed set
([`IDWriteFontCollection`][collection]). The legacy family model is a strict
tree:

| Interface               | Represents                                                                                                                                          |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `IDWriteFontCollection` | "a set of fonts, such as the set of fonts installed on the system" ([ref][collection])                                                              |
| `IDWriteFontFamily`     | WWS family (weight/width/slope); `GetFirstMatchingFont(weight, stretch, style)` ([ref][first-matching])                                             |
| `IDWriteFont`           | a font _description_ in the collection (names, properties, `HasCharacter`)                                                                          |
| `IDWriteFontFace`       | the loaded face: "metrics, names, and glyph outlines … font face type, appropriate file references, and face identification data" ([ref][fontface]) |
| `IDWriteFontFile`       | file reference + loader key; `IDWriteFontFileStream` reads bytes                                                                                    |

Windows 10 added a flat, property-indexed model next to the tree:
`IDWriteFontSet` with `GetMatchingFonts`, `GetPropertyValues`,
`FindFontFaceReference` ([`IDWriteFontSet`][fontset]), and
`IDWriteFontResource`, which "provides axis information for a font resource, and
is used to create specific font face instances" ([`IDWriteFontResource`][resource]).

Shaping is two calls on `IDWriteTextAnalyzer`: `GetGlyphs` (characters →
glyph ids + cluster map) then `GetGlyphPlacements` (glyph ids → advances and
offsets), each taking the same `IDWriteFontFace`, `DWRITE_SCRIPT_ANALYSIS`,
locale and feature ranges ([`GetGlyphs`][getglyphs],
[`GetGlyphPlacements`][placements]).

## Analysis spine

### 1. Layering and ownership

Every object is a refcounted COM interface (`AddRef`/`Release`); every call
returns `HRESULT`. The layering is factory (cache owner) → collection/set
(enumeration) → family → font (description, cheap) → face (loaded, sized-less)
→ glyph run analysis (sized, transformed, rendered). Size never lives on the
face: it is a per-call `emSize` argument to outlines, placements and
`CreateGlyphRunAnalysis`, so a face is DirectWrite's equivalent of an unsized
typeface. Bytes are owned by the file loader; table pointers borrow from it
(§2). The shared factory is designed to be used from multiple components and
threads in one process; isolated factories partition the cache. The error model
is uniform `HRESULT`, with buffer-too-small signalled as
`HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER)` and "retry larger"
([`GetGlyphs`][getglyphs]).

### 2. Face loading and table access

Faces come from the collection/set (`IDWriteFont::CreateFontFace`), from
`IDWriteFactory::CreateFontFace(fileType, files, faceIndex, simulations, …)`
with an explicit collection index, or from in-memory bytes through a custom
`IDWriteFontFileLoader` (and, from `IDWriteFactory5`, an in-memory loader).
`IDWriteFontFace::GetIndex` reports the `.ttc` face index and `GetSimulations`
the synthetic bold/oblique flags ([`IDWriteFontFace`][fontface]).

Raw tables are exposed but borrowed with an explicit release token:

```cpp
HRESULT TryGetFontTable(
  [in]  UINT32     openTypeTableTag,
  [out] const void **tableData,
  [out] UINT32     *tableSize,
  [out] void       **tableContext,
  [out] BOOL       *exists
);
```

— [`IDWriteFontFace::TryGetFontTable`][trygettable]

"The pointer is valid only as long as the font face used to get the font table
still exists; (not any other font face, even if it actually refers to the same
physical font)", and each `tableContext` must be returned through
`ReleaseFontTable` separately. What it refuses: "Unlike GDI, it does not
support the special TTCF and null tags to access the whole font"
([ref][trygettable]). A missing table is `exists == FALSE`, not an error.

### 3. Shaping

`GetGlyphs` takes UTF-16 text, the face, `isSideways`, `isRightToLeft`, a
`DWRITE_SCRIPT_ANALYSIS` from `AnalyzeScript`, an optional locale, optional
number substitution, and feature _ranges_: `features` is an array of pointers to
`DWRITE_TYPOGRAPHIC_FEATURES` and `featureRangeLengths` gives each range's
length in characters ([`GetGlyphs`][getglyphs]). A feature is
`DWRITE_FONT_FEATURE { nameTag, parameter }`, where "a non-zero value generally
enables the feature execution, while the zero value disables it. A feature
requiring a selector uses this value to indicate the selector index"
([`DWRITE_FONT_FEATURE`][feature]).

Outputs are caller-allocated arrays: `clusterMap` (one `UINT16` per character,
"the mapping from character ranges to glyph ranges"), per-character
`DWRITE_SHAPING_TEXT_PROPERTIES`, `glyphIndices`, per-glyph
`DWRITE_SHAPING_GLYPH_PROPERTIES`. The doc gives the sizing rule: "the mapping
from characters to glyphs is, in general, many-to-many. The recommended estimate
for the per-glyph output buffers is (3 \* textLength / 2 + 16). This is not
guaranteed to be sufficient" ([`GetGlyphs`][getglyphs]). `GetGlyphPlacements`
then returns `glyphAdvances` (`FLOAT`) and `DWRITE_GLYPH_OFFSET`s for a
`fontEmSize` "in DIPs" ([`GetGlyphPlacements`][placements]) — 1 DIP = 1/96 inch.
Itemization (script, bidi, line breaks, number substitution) is separate
analyzer calls driven through `IDWriteTextAnalysisSource` / `Sink` callbacks.

### 4. Variation and instances

Variations arrived in `dwrite_3.h` (Windows 10 build 16299). Coordinates are
user-space floats keyed by tag:

```cpp
struct DWRITE_FONT_AXIS_VALUE {
  DWRITE_FONT_AXIS_TAG axisTag;
  FLOAT                value;
};
```

"Weight (1..1000, default == 400) … Width (>0, default == 100) … Slant
(-90..90, default == -20) … Italic (0 or 1)" ([`DWRITE_FONT_AXIS_VALUE`][axis-value]).
They are not set on a face; they _produce_ a face:
`IDWriteFontResource::CreateFontFace` "creates a font face instance with
specific axis values", alongside `GetFontAxisRanges`,
`GetDefaultFontAxisValues`, `GetFontAxisAttributes` (e.g. hidden axes),
`GetAxisNames` and `GetAxisValueNames` (named values from `STAT`)
([`IDWriteFontResource`][resource]). `IDWriteFontFace5` reads them back
(`GetFontAxisValueCount`, `GetFontAxisValues`, `HasVariations`) and links back
to its resource ([`IDWriteFontFace5`][fontface5]). Because the instance _is_ a
face, shaping, metrics, outlines and rasterization all see the coordinates
without further plumbing; `IDWriteFontSet` indexes named instances as separate
entries so matching by weight finds them.

### 5. Rasterization and outlines

Outlines are a callback sink in DIPs, for a whole run:

```cpp
HRESULT GetGlyphRunOutline(
                 FLOAT                     emSize,
  [in]           UINT16 const              *glyphIndices,
  [in, optional] FLOAT const               *glyphAdvances,
  [in, optional] DWRITE_GLYPH_OFFSET const *glyphOffsets,
                 UINT32                    glyphCount,
                 BOOL                      isSideways,
                 BOOL                      isRightToLeft,
                 IDWriteGeometrySink       *geometrySink
);
```

— [`IDWriteFontFace::GetGlyphRunOutline`][outline]

`IDWriteGeometrySink` is Direct2D's `ID2D1SimplifiedGeometrySink`
(`BeginFigure`, `AddLines`, `AddBeziers`, `EndFigure`, `SetFillMode`) — cubic
Béziers only, y-down, already positioned along the run.

CPU raster is `IDWriteFactory::CreateGlyphRunAnalysis(glyphRun, pixelsPerDip,
transform, renderingMode, measuringMode, …)` then `CreateAlphaTexture`: either
a bi-level texture of one byte per pixel (0 or 255) or a ClearType texture of
three bytes per pixel, with `GetAlphaBlendParams` supplying the gamma/contrast
for ClearType blending ([`IDWriteGlyphRunAnalysis`][analysis]). The mode enum
encodes the hinting/AA policy: `ALIASED`, `GDI_CLASSIC` (GDI-compatible,
pixel-snapped), `GDI_NATURAL`, `NATURAL` (subpixel positioning, horizontal AA),
`NATURAL_SYMMETRIC` (AA in both directions), `OUTLINE` ("bypass the rasterizer
and use the outlines directly … at very large sizes")
([`DWRITE_RENDERING_MODE`][rendering-mode]); `GetRecommendedRenderingMode`
picks one per size ([`IDWriteFontFace`][fontface]). No atlas: caching glyph
masks is Direct2D's or the caller's job.

Color is a run _splitter_: `IDWriteFactory2::TranslateColorGlyphRun` returns an
`IDWriteColorGlyphRunEnumerator` of monochrome layer runs plus colors, or
`DWRITE_E_NOCOLOR` "to let the application know that it can just draw the
original glyph run" ([`TranslateColorGlyphRun`][translate-color]). Later
versions filter by `DWRITE_GLYPH_IMAGE_FORMATS` — `TRUETYPE`, `CFF`, `COLR`,
`SVG`, `PNG`, `JPEG`, `TIFF`, `PREMULTIPLIED_B8G8R8A8`, and
`COLR_PAINT_TREE` ([`DWRITE_GLYPH_IMAGE_FORMATS`][image-formats]); COLRv1 paint
graphs are read through `IDWriteFontFace7::CreatePaintReader` →
`IDWritePaintReader` at `DWRITE_PAINT_FEATURE_LEVEL_COLR_V1`
([`IDWritePaintReader`][paint-reader]).

### 6. Metrics and measurement

`IDWriteFontFace::GetMetrics` fills `DWRITE_FONT_METRICS { designUnitsPerEm,
ascent, descent, lineGap, capHeight, xHeight, underlinePosition,
underlineThickness, strikethroughPosition, strikethroughThickness }`, all in
design units; "the recommended line spacing (baseline-to-baseline distance) is
the sum of ascent, descent, and lineGap" ([`DWRITE_FONT_METRICS`][metrics]).
Note `ascent`/`descent` are unsigned and both positive. The docs do not name the
source table (`hhea` vs `OS/2` typo vs win) — an inspector cannot learn the
choice from the API and must read `OS/2`/`hhea` itself via `TryGetFontTable`.
`GetGdiCompatibleMetrics` returns the pixel-snapped variant.
Per-glyph, `GetDesignGlyphMetrics` returns `DWRITE_GLYPH_METRICS` (advance and
side bearings, vertical too) "in font design units" with an `isSideways` flag
because oblique simulation differs sideways
([`GetDesignGlyphMetrics`][design-metrics]).

### 7. Discovery, matching and fallback

Enumeration: `GetSystemFontCollection` then iterate families, or the flat
`IDWriteFontSet` queried by `DWRITE_FONT_PROPERTY_ID` (family names, typographic
family, weight/stretch/style, designed script tags, semantic tags). Matching:
`IDWriteFontFamily::GetFirstMatchingFont(weight, stretch, style)` within one
family ([ref][first-matching]); `IDWriteFontSet::GetMatchingFonts` across the
set ([`IDWriteFontSet`][fontset]). Missing styles are synthesized via
`DWRITE_FONT_SIMULATIONS` (bold, oblique), visible on the face.

Fallback is a first-class object since Windows 8.1:

```cpp
HRESULT MapCharacters(
                 IDWriteTextAnalysisSource *analysisSource,
                 UINT32                    textPosition,
                 UINT32                    textLength,
  [in, optional] IDWriteFontCollection     *baseFontCollection,
  [in, optional] wchar_t const             *baseFamilyName,
                 DWRITE_FONT_WEIGHT        baseWeight,
                 DWRITE_FONT_STYLE         baseStyle,
                 DWRITE_FONT_STRETCH       baseStretch,
  [out]          UINT32                    *mappedLength,
  [out]          IDWriteFont               **mappedFont,
  [out]          FLOAT                     *scale
);
```

— [`IDWriteFontFallback::MapCharacters`][map-characters]

It is a _run_ API, not a per-codepoint one: it returns the longest prefix one
font covers; a `NULL` font means "no font can render the text, and
`mappedLength` is the number of characters to skip"; and `scale` is an em-size
multiplier so the fallback face can be size-matched to the base
([ref][map-characters]). The system fallback is
`IDWriteFactory2::GetSystemFontFallback`; custom chains are built with
`IDWriteFontFallbackBuilder` (Unicode ranges → family list, per locale).

## What it teaches `sparkles:font`

- **Variation instance = new face.** `IDWriteFontResource::CreateFontFace(axisValues)`
  makes coordinates immutable per face; every downstream consumer (shaper,
  metrics, outline, raster) then needs no variation parameter. A D
  `FontResource.instantiate(axes)` returning a cheap face view over the same
  bytes is the direct analogue.
- **Fallback returns a run length plus a scale.** `MapCharacters`' shape
  (`mappedLength`, `mappedFont`, `scale`, `NULL` ⇒ skip N) is what a terminal's
  run iterator needs; the em-size scale is a detail most fallback APIs omit.
- **Borrowed table views need a token, not just a lifetime.** `TryGetFontTable`'s
  `tableContext` + `ReleaseFontTable` is the price of streamed loaders; with
  `sparkles:font`'s whole-file borrowed buffer a `scope const(ubyte)[]` tied to
  the face is sufficient and safer.
- **Split shaping into substitution and positioning only if callers need it.**
  The two-call `GetGlyphs`/`GetGlyphPlacements` lets layout re-position without
  re-substituting, but forces callers to carry five parallel arrays; one call
  with a reusable buffer (HarfBuzz) is simpler.
- **Make the AA/hinting policy an enum with a "recommended" query.**
  `DWRITE_RENDERING_MODE` + `GetRecommendedRenderingMode` is a compact,
  inspectable way to expose raster policy.

## Strengths

- Complete stack in one API, with a cross-process font cache service.
- Variable fonts integrated cleanly: user-space axis values, `STAT` names,
  hidden-axis attributes, instances indexed in the font set.
- `MapCharacters` and `IDWriteFontFallbackBuilder` make fallback configurable data.
- Explicit rendering-mode vocabulary covering GDI-compatible to outline rendering.
- Color glyph coverage from `COLR` layers through COLRv1 paint trees, bitmaps and SVG.

## Weaknesses

- Windows-only and closed-source; behaviour (metric table choice, fallback
  data) is documented only by outcome.
- UTF-16 everywhere; cluster maps are `UINT16` per UTF-16 unit.
- Outlines only as a run-level Direct2D sink in DIPs; no per-glyph design-unit
  path or quadratic segments.
- Interface-version sprawl (`IDWriteFontFace` … `7`, `IDWriteFactory` … `8`)
  with `QueryInterface` capability probing.
- Caller-sized output buffers with heuristic sizing and retry.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                              | Trade-off                                                   |
| ----------------------------------------------------- | ------------------------------------------------------ | ----------------------------------------------------------- |
| Shared vs isolated factory                            | Process- and system-wide cache reuse; sandbox plug-ins | Global mutable state behind the default path                |
| Size as a per-call argument, not face state           | Faces shareable across sizes and transforms            | Every call repeats `emSize`, `pixelsPerDip`, transform      |
| Variation coords baked into the face                  | Downstream APIs unchanged by variations                | A face object per instance; coordinate edits recreate faces |
| Two-phase shaping (`GetGlyphs`, `GetGlyphPlacements`) | Re-position without re-substitution                    | Five parallel arrays the caller must keep consistent        |
| Table access via borrow + release token               | Works over arbitrary `IDWriteFontFileStream` loaders   | Easy to leak or use-after-release; no whole-file access     |
| Run-level fallback with em scale                      | Fewer lookups; size-harmonized fallback faces          | Caller must implement `IDWriteTextAnalysisSource`           |
| Outlines via `ID2D1SimplifiedGeometrySink`            | Feeds Direct2D geometry directly                       | Cubic-only, DIP units, run-positioned                       |

## Sources

- **Object model** — [`IDWriteFontCollection`][collection],
  [`IDWriteFontFamily::GetFirstMatchingFont`][first-matching],
  [`IDWriteFontFace`][fontface], [`DWRITE_FACTORY_TYPE`][factory-type],
  [`IDWriteFontSet`][fontset].
- **Tables and metrics** — [`TryGetFontTable`][trygettable],
  [`DWRITE_FONT_METRICS`][metrics], [`GetDesignGlyphMetrics`][design-metrics].
- **Shaping** — [`GetGlyphs`][getglyphs], [`GetGlyphPlacements`][placements],
  [`DWRITE_FONT_FEATURE`][feature].
- **Variations** — [`IDWriteFontResource`][resource],
  [`IDWriteFontFace5`][fontface5], [`DWRITE_FONT_AXIS_VALUE`][axis-value].
- **Raster, outline, color** — [`GetGlyphRunOutline`][outline],
  [`IDWriteGlyphRunAnalysis`][analysis], [`DWRITE_RENDERING_MODE`][rendering-mode],
  [`TranslateColorGlyphRun`][translate-color],
  [`DWRITE_GLYPH_IMAGE_FORMATS`][image-formats],
  [`IDWritePaintReader`][paint-reader].
- **Fallback** — [`IDWriteFontFallback::MapCharacters`][map-characters].
- Siblings: [`./coretext.md`](./coretext.md), [`./skia.md`](./skia.md),
  [`./crossfont.md`](./crossfont.md), [`./font-kit.md`](./font-kit.md),
  [`./harfbuzz.md`](./harfbuzz.md).

<!-- References -->

[dwrite-ref]: https://learn.microsoft.com/en-us/windows/win32/directwrite/direct-write-portal
[factory-type]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/ne-dwrite-dwrite_factory_type
[collection]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nn-dwrite-idwritefontcollection
[first-matching]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwritefontfamily-getfirstmatchingfont
[fontface]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nn-dwrite-idwritefontface
[fontset]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite_3/nn-dwrite_3-idwritefontset
[resource]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite_3/nn-dwrite_3-idwritefontresource
[fontface5]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite_3/nn-dwrite_3-idwritefontface5
[axis-value]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite_3/ns-dwrite_3-dwrite_font_axis_value
[trygettable]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwritefontface-trygetfonttable
[metrics]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/ns-dwrite-dwrite_font_metrics
[design-metrics]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwritefontface-getdesignglyphmetrics
[getglyphs]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwritetextanalyzer-getglyphs
[placements]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwritetextanalyzer-getglyphplacements
[feature]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/ns-dwrite-dwrite_font_feature
[outline]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwritefontface-getglyphrunoutline
[analysis]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nn-dwrite-idwriteglyphrunanalysis
[rendering-mode]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite/ne-dwrite-dwrite_rendering_mode
[translate-color]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite_2/nf-dwrite_2-idwritefactory2-translatecolorglyphrun
[image-formats]: https://learn.microsoft.com/en-us/windows/win32/api/dcommon/ne-dcommon-dwrite_glyph_image_formats
[paint-reader]: https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/win32/dwrite_3/nn-dwrite_3-idwritepaintreader
[map-characters]: https://learn.microsoft.com/en-us/windows/win32/api/dwrite_2/nf-dwrite_2-idwritefontfallback-mapcharacters
