# SixLabors.Fonts (C# / .NET)

A complete managed text stack — parser, shaper, hinter, outline emitter, fallback — with no native rasterizer and no native dependency except three optional platform font matchers.

| Field            | Value                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Language         | C# (`net10.0`, nullable enforced as errors, `IsTrimmable`) ([`SixLabors.Fonts.csproj`][csproj])                          |
| License          | Six Labors Split License 1.0 — Apache 2.0 for OSS / small-revenue consumers, commercial otherwise ([`LICENSE`][license]) |
| Repository       | [`SixLabors/Fonts`][repo]                                                                                                |
| Documentation    | [`sixlabors.github.io/docs`][docs]; XML doc comments on every public member                                              |
| Category         | layout engine (managed, pure C#)                                                                                         |
| Layer(s) covered | parse · discover · match/fallback · shape · outline · layout (no raster)                                                 |
| Pinned revision  | `4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5` (2026-09-17)                                                                  |

## Overview

### What it solves

SixLabors.Fonts is the text engine under ImageSharp.Drawing. It reads TrueType, CFF1/CFF2, WOFF and WOFF2, runs its own GSUB/GPOS engine with script-specific shapers, interprets TrueType hinting bytecode, resolves variation axes down to the outline, and emits outlines plus decorations into a caller-supplied sink. It deliberately stops before pixels: the `IGlyphRenderer` sink is the last thing it owns. The `Tables/AdvancedTypographic/` tree alone is 129 files and 29,989 lines of C# — a shaper the size of a small HarfBuzz, written in a GC language.

### Design philosophy

> **SixLabors.Fonts** is a cross-platform library for loading, measuring, and laying out fonts and text. It supports TrueType and OpenType fonts (including CFF1 and CFF2 outlines), WOFF/WOFF2 web fonts, variable fonts, color fonts (COLR v0/v1 and SVG), and TrueType hinting. The library provides a full OpenType layout engine with GSUB/GPOS support, advanced text shaping for complex scripts, and bidirectional text rendering.

— [`README.md`][readme]

"Loading, measuring, and laying out" is the whole scope; "rendering" means driving a sink. Everything is managed memory, parsed eagerly into typed table objects, and shared read-only between threads via immutable `Font` instances and `ConcurrentDictionary` caches.

## How it works

Three public nouns, one abstract spine:

- **`FontCollection`** (`Add(path|Stream)`, `AddCollection` for `.ttc`, `Get`/`TryGet`, `*ByCulture` variants) is a locked `List<FontCollectionEntry>` of `FontMetrics` ([`FontCollection.cs`][collection]). **`SystemFonts`** is a static facade over a lazy `SystemFontCollection` ([`SystemFonts.cs`][sysfonts]).
- **`FontFamily`** is a `struct` holding a name, a culture and a back-reference to its collection; `CreateFont(size, style, params FontVariation[])` yields an immutable **`Font`** whose `FontMetrics` is a `Lazy<FontMetrics?>` resolved on first use ([`FontFamily.cs`][family], [`Font.cs`][font]).
- **`FontMetrics`** is the abstract face: `UnitsPerEm`, `HorizontalMetrics`/`VerticalMetrics`, OS/2 sub/superscript and strikeout, `post` underline and italic angle, `TryGetTableData(Tag, out ReadOnlyMemory<byte>)`, `OpenStream()`, `TryGetVariationAxes`, `TryGetGlyphMetrics(codePoint|glyphId, attributes, decorations, layoutMode, colorSupport, palette, out FontGlyphMetrics)` and `GetAvailableCodePoints()` ([`FontMetrics.cs`][metrics]). `FileFontMetrics` wraps a `Lazy<StreamFontMetrics>` so a collection can hold thousands of faces having read only each one's `name`/`OS/2`/`head` ([`FileFontMetrics.cs`][filemetrics]).

Text enters through `TextOptions(Font)` — fallback families, resolver, DPI, hinting, wrapping, direction, script, features, `TextRuns` — and leaves through `TextMeasurer` (advance, bounds, renderable bounds, per-glyph/grapheme/word/line metrics, intersections) or `TextRenderer.RenderTo(IGlyphRenderer, text, options)` ([`TextOptions.cs`][options], [`TextMeasurer.cs`][measurer], [`TextRenderer.cs`][renderer]). A lower door, `TextShaper.Shape(Font, TextShapingBuffer)`, exposes the shaper without layout ([`TextShaper.cs`][shaper]).

## Analysis spine

### 1. Layering and ownership

Five layers, all managed: `FontSource` (bytes) → `FontReader`/`TableLoader` (directory + typed tables) → `StreamFontMetrics` (face + caches) → `Font` (face × size × variations × style) → `TextShaper`/`TextLayout`/`TextRenderer` (text). There is no scaled-font object: `Font.Size` is a float carried into every call and applied at the edge (`glyphOrigin *= dpi` in `FontGlyphMetrics.RenderTo`, [`FontGlyphMetrics.cs`][glyphmetrics]).

Ownership is the GC's. `FontSource` is a `string path, long offset` or a `byte[]`; every table read reopens a `FileStream`/`MemoryStream` ([`FontSource.cs`][source]). No `IDisposable` appears on the public surface; `FontReader` is disposable but internal and short-lived. Thread-safety is by immutability plus three `ConcurrentDictionary` caches keyed on `(codePoint, glyphId, attributes, colorSupport, isVertical, palette)` in `StreamFontMetrics` ([`StreamFontMetrics.cs`][streammetrics]); `Font.WithWeight` copies its variation array because "Font instances are immutable and can be shared by concurrent layouts" ([`Font.cs`][font]). The TrueType interpreter is pooled (`ObjectPool<TrueTypeInterpreter>`) since it is stateful. Errors are exceptions: `InvalidFontFileException`, `MissingFontTableException`, `GlyphMissingException`, `FontFamilyNotFoundException`; lookups the caller expects to fail are `Try*` with `out`.

### 2. Face loading and table access

`FontReader` reads the directory (sfnt, `OTTO`, TTC via `TtcHeader`, WOFF, WOFF2 with inflate in `IO/ZlibInflateStream.cs`) and dispatches by tag through a registry of 32 loaders ([`TableLoader.cs`][tableloader]). Loading is **eager and ordered**: `LoadTrueTypeFont` reads `head`, `hhea`, `maxp`, `OS/2`, `hmtx`, `cmap`, `fpgm`, `prep`, `cvt`, `hdmx`, `loca`, `glyf`, `kern`, `name`, `post`, `vhea`/`vmtx`, `BASE`, `GDEF`, `GSUB`, `GPOS`, `fvar`, `avar`, `gvar`, `HVAR`, `VVAR`, `MVAR`, `cvar`, `COLR`, `CPAL`, `SVG` in one pass "using recommended order for best performance" ([`StreamFontMetrics.TrueType.cs`][tt]). Everything is parsed into managed objects; the file is closed. Raw bytes remain reachable through `TryGetTableData(Tag)`, which re-reads the directory — the inspector's escape hatch for tables the library does not model. The lightweight path is `FontDescription.LoadDescription(path|Stream)`: "Only read the name tables" — `head`, `OS/2`, `name` — and `LoadFontCollectionDescriptions` walks a `.ttc` the same way ([`FontDescription.cs`][description]). That is exactly what a font browser wants for a first listing pass.

### 3. Shaping

Own engine, HarfBuzz-shaped. `ShaperFactory` picks among `DefaultShaper`, `ArabicShaper`, `HebrewShaper`, `IndicShaper`, `KhmerShaper`, `MyanmarShaper` (+ Zawgyi), `ThaiShaper`, `HangulShaper` and `UniversalShaper` ([`ShaperFactory.cs`][shaperfactory]); GSUB lookup types 1–8 and GPOS 1–9 each have a subtable class, with `NotImplementedSubTable` as the explicit hole. Features are `IReadOnlyList<Tag> FeatureTags` on options or per `TextRun`; script is `ScriptClass?`, language `CultureInfo`, direction `TextDirection.Auto|LeftToRight|RightToLeft` with `TextBidiMode`. The low-level contract is `TextShapingBuffer`: `Add(text)`, set `TextDirection`/`Language`/`Script`/`LayoutMode`/`KerningMode`, call `TextShaper.Shape` or `ShapeRun`, read `ReadOnlySpan<ShapedGlyph> Glyphs` and `LineEnds` ([`TextShapingBuffer.cs`][buffer]). Cluster mapping is `ShapedGlyphInfo{CodePointIndex, CodePoint, CodePointCount, GlyphId, RunIndex, Flags}` with `Substituted`/`Decomposed`/`Placeholder` flags; positions are `ShapedGlyphPosition{AdvanceWidth, AdvanceHeight, Offset, Bearing}` in `ushort` design units ([`ShapedGlyphInfo.cs`][info], [`ShapedGlyphPosition.cs`][pos]). The shaper doc states the unit rule: "Advances and offsets are scaled to the supplied font's size."

### 4. Variation and instances

Full `fvar`/`avar`/`gvar`/`cvar`/`HVAR`/`VVAR`/`MVAR` plus CFF2 blend. `FontVariation(tag, value)` is a user-coordinate pair; `KnownVariationAxes` names `ital`/`opsz`/`slnt`/`wdth`/`wght` ([`FontVariation.cs`][variation], [`KnownVariationAxes.cs`][knownaxes]). `StreamFontMetrics.CreateVariationInstance` fills a `float[]` from `fvar` defaults, overwrites matching tags, and builds a `GlyphVariationProcessor` that **shares every table and the glyph-id caches** with the parent while owning new glyph and metric state ([`StreamFontMetrics.cs`][streammetrics]). Normalization and `avar` mapping live in the processor (`NormalizedCoordinates`); `TransformPoints` applies `gvar` deltas to the outline, `AdvanceAdjustment` applies `HVAR`, `ApplyCvtDeltas` feeds `cvar` into the hinter's CVT, and `ApplyMVarDeltas` rewrites ascender, descender, line gap, sub/superscript, strikeout and underline ([`GlyphVariationProcessor.cs`][gvp]). `fvar` named instances are parsed (`FVarTable.Instances`) but there is no public API to select one — a caller must read `TryGetVariationAxes` and set coordinates ([`FVarTable.cs`][fvar]). `Font.WithWeight` prefers the `wght` axis of a variable face over hunting for a static sibling ([`Font.cs`][font]).

### 5. Rasterization and outlines

**No rasterizer.** Output is a callback sink:

```csharp
public interface IGlyphRenderer
{
    public void BeginText(in FontRectangle bounds);
    public void EndText();
    public bool BeginGlyph(in FontRectangle bounds, in GlyphRendererParameters parameters);
    public void EndGlyph();
    public void BeginLayer(Paint? paint, FillRule fillRule);
    public void EndLayer();
    public void BeginGroup(CompositeMode mode);
    public void EndGroup();
    public void BeginFigure();
    public void MoveTo(Vector2 point);
    public void LineTo(Vector2 point);
    public void QuadraticBezierTo(Vector2 secondControlPoint, Vector2 point);
    public void CubicBezierTo(Vector2 secondControlPoint, Vector2 thirdControlPoint, Vector2 point);
    public void ArcTo(float radiusX, float radiusY, float rotation, bool largeArc, bool sweep, Vector2 point);
    public void EndFigure();
    public TextDecorations EnabledDecorations();
    public void SetDecoration(TextDecorations textDecorations, Vector2 start, Vector2 end, float thickness, ReadOnlyMemory<float> intersections);
}
```

— [`Rendering/IGlyphRenderer.cs`][iglyphrenderer]

Points arrive in **device pixels** (already scaled by `pointSize × dpi / 72` and translated to the glyph origin). `BeginGlyph` returns `bool` so a sink may serve the glyph from its own cache keyed on `GlyphRendererParameters{Font, GlyphId, PointSize, Dpi, FontStyle, HintingMode, FontPalette, …}` and decline the outline ([`GlyphRendererParameters.cs`][params]). Colour glyphs become `BeginLayer(Paint, FillRule)`/`BeginGroup(CompositeMode)` nests — COLRv0, COLRv1 (gradients, transforms, composites) and `SVG` are all modelled, selected by `ColorFontSupport` flags ([`ColorFontSupport.cs`][colorsupport]). Hinting is real: `HintingMode.None|Standard|Full`, where `Standard` "matches the behavior of FreeType's v40 subpixel hinting interpreter, with horizontal hinting disabled" and `Full` lifts the backward-compatibility restrictions — a 4,549-line managed port of the TrueType bytecode interpreter plus 479 lines of opcodes ([`TrueTypeInterpreter.cs`][interp]). Scaled, hinted outlines are cached per `(scaledPPEM, HintingMode)` on each `TrueTypeGlyphMetrics` ([`TrueTypeGlyphMetrics.cs`][ttgm]). CFF hinting data is parsed (`CffHintMask`, `HintMap`) for bounds, not applied as grid fitting. AA, LCD, gamma and atlases are the sink's problem.

### 6. Metrics and measurement

Font-level metrics are `short` design units on `HorizontalMetrics{Ascender, Descender, LineGap, LineHeight, AdvanceWidthMax, AdvanceHeightMax}` ([`HorizontalMetrics.cs`][hmetrics]); `ScaleFactor = unitsPerEm × 72` so one point equals one pixel at 72 dpi. The ascender rule is FreeType's, stated in a comment: honour `OS/2` `USE_TYPO_METRICS` (fsSelection bit 7) → `sTypo*`; else `hhea`; if those are zero, `sTypo*` if non-zero, else `usWin*` ([`StreamFontMetrics.cs`][streammetrics]). `XHeight`/`CapHeight` come from `OS/2`; underline from `post`; strikeout and sub/superscript from `OS/2`; `MVAR` deltas apply to all of them. Per-glyph `FontGlyphMetrics` carries `AdvanceWidth/Height`, four side bearings, `Width`/`Height`, `GlyphType`, and `TryGetHintedAdvanceWidth` for `Full` hinting ([`FontGlyphMetrics.cs`][glyphmetrics]). `TextMeasurer` distinguishes `MeasureAdvance` (pen), `MeasureBounds` (ink), and `MeasureRenderableBounds` (ink plus decorations) and returns `ReadOnlyMemory<GlyphMetrics>` per glyph with `GraphemeIndex` and `StringIndex` ([`TextMeasurer.cs`][measurer]).

### 7. Discovery, matching and fallback

Enumeration is a directory scan with per-OS roots — Windows `%SYSTEMROOT%\Fonts` and the two per-user folders; Linux `~/.fonts`, `~/.local/share/fonts`, `/usr/local/share/fonts`, `/usr/share/fonts`; macOS the four `Library/Fonts`; Android `/system/fonts/` — layered under native family lists ([`SystemFontCollection.cs`][syscollection]). `SystemFontMatcher` dispatches to `DirectWriteSystemFontMatcher` (COM vtables hand-declared), `CoreTextSystemFontMatcher` (`LibraryImport` of `CTFontManagerCopyAvailableFontFamilyNames`, `CTFontCreateForStringWithLanguage`) and `FontConfigSystemFontMatcher` (`libfontconfig.so.1`: `FcPatternAddCharSet` + `FcFontMatch`, with a lock when `FcGetVersion()` predates thread safety) ([`SystemFontMatcher.cs`][matcher], [`FontConfigSystemFontMatcher.cs`][fcmatcher], [`CoreText.cs`][coretext], [`DirectWriteSystemFontMatcher.cs`][dwmatcher]). Each native face is reduced to `NativeSystemFontFace{FamilyName, FaceName, Path, Style, StyleScore, FaceIndex}` ([`NativeSystemFontFace.cs`][nativeface]). Matching inside a collection is by family name (culture-aware comparer) and `FontStyle` flags (`Regular|Bold|Italic`), with `FontWeight` only honoured for system faces or variable `wght`. Fallback is three-tier and explicit: shape with `Font`; re-run the still-unmapped code points through each `FallbackFontFamilies` entry in order; then ask `IFontFallbackResolver.TryResolve(codePoint, requestedFamily, style, culture)` "at most once per distinct unresolved code point per shaping operation" ([`TextShaper.Pipeline.cs`][pipeline], [`IFontFallbackResolver.cs`][resolver]). `SystemFontFallbackResolver` is the platform-backed implementation with a `ConcurrentDictionary` cache ([`SystemFontFallbackResolver.cs`][sysresolver]). No PANOSE or OS/2 classification is used for matching.

## What it teaches `sparkles:font`

- **A face handle plus a size value, not a scaled-font object.** `Font` is `(FontMetrics, float size, FontVariation[], style)`; scaling happens once in `RenderTo`. For a terminal with one size this is the right economy; cache hinted outlines by `(ppem, hintingMode)` as `TrueTypeGlyphMetrics` does.
- **Two-level loading.** `LoadDescription` reads three tables; `FileFontMetrics` defers the rest behind `Lazy`. The explorer's listing pass should be the first; `TryGetTableData(Tag)` keeps raw bytes reachable for the inspector.
- **`BeginGlyph` returns `bool`.** A sink that caches rasters by `GlyphRendererParameters` can refuse the outline. That is the atlas seam, named at the right place.
- **Fallback as an ordered list, then a resolver, each consulted once per unmapped code point.** The `FallbackFontFamilies` list is user configuration; `IFontFallbackResolver` is the platform; the pipeline documents the order.
- **Variation instances share tables and caches with their parent.** `CreateVariationInstance` is cheap because only `GlyphVariationProcessor` and glyph caches are new. Offsets over one borrowed buffer make this free in D.
- **State the ascender rule in code.** The `USE_TYPO_METRICS` → `hhea` → `sTypo` → `usWin` ladder is a comment-with-code; copy it verbatim and test it.

## Strengths

- One language, zero native code on the hot path; trimmable; the entire GSUB/GPOS/hinting stack is debuggable in a managed debugger.
- Modern coverage: CFF2, COLRv1, WOFF2, `MVAR`/`cvar`, caret and hit testing, text decorations with skip-ink.
- The sink interface models layers, groups and decorations, not just paths.
- Honest `Try*` APIs and documented fallback order.

## Weaknesses

- No rasterizer, no atlas, no LCD/gamma — every consumer re-solves rendering.
- Eager parsing into managed objects: a 20 MB CJK face is fully materialized on first `Font` use, and `TryGetTableData` re-reads the file each call.
- No named-instance selection and no `STAT` table.
- Static-face weight matching in user collections is by `FontStyle` flags only.
- Split license: Apache 2.0 only below 1M USD revenue or for OSS consumers.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                    | Trade-off                                                  |
| -------------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------------- |
| Pure managed parser + shaper + hinter              | One deployable assembly, trimmable, no P/Invoke on hot paths | Every table is a heap object; GC owns 30k lines of shaping |
| Outline sink instead of rasterizer                 | ImageSharp.Drawing owns pixels; reusable by any 2-D backend  | Atlas, AA, LCD, gamma all pushed to consumers              |
| Eager table load in spec order                     | Sequential I/O, simple invariants, immutable face            | Startup cost per face; memory proportional to font size    |
| `Lazy<StreamFontMetrics>` behind `FontDescription` | Enumerate thousands of system faces cheaply                  | Two metric classes with forwarding boilerplate             |
| Variation instance shares parent tables and caches | Cheap per-coordinate instances for animation / UI sliders    | Glyph caches per instance; no named-instance API           |
| Ordered fallback list + single-shot resolver       | Deterministic, user-controllable, platform as last resort    | Per-codepoint, so a run can fragment across fonts          |
| Native matchers only for discovery, never parsing  | Platform knows installed families; library keeps one parser  | Three bespoke bindings (COM vtables, CoreText, fontconfig) |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- Collection and discovery — [`FontCollection.cs`][collection], [`SystemFonts.cs`][sysfonts], [`SystemFontCollection.cs`][syscollection], [`Native/SystemFontMatcher.cs`][matcher], [`Native/FontConfigSystemFontMatcher.cs`][fcmatcher], [`Native/CoreText.cs`][coretext], [`Native/DirectWriteSystemFontMatcher.cs`][dwmatcher], [`Native/NativeSystemFontFace.cs`][nativeface].
- Face and metrics — [`FontFamily.cs`][family], [`Font.cs`][font], [`FontMetrics.cs`][metrics], [`FileFontMetrics.cs`][filemetrics], [`StreamFontMetrics.cs`][streammetrics], [`StreamFontMetrics.TrueType.cs`][tt], [`FontSource.cs`][source], [`FontDescription.cs`][description], [`Tables/TableLoader.cs`][tableloader], [`HorizontalMetrics.cs`][hmetrics], [`FontGlyphMetrics.cs`][glyphmetrics].
- Shaping and fallback — [`TextShaper.cs`][shaper], [`TextShaper.Pipeline.cs`][pipeline], [`TextShapingBuffer.cs`][buffer], [`ShapedGlyphInfo.cs`][info], [`ShapedGlyphPosition.cs`][pos], [`Tables/AdvancedTypographic/Shapers/ShaperFactory.cs`][shaperfactory], [`IFontFallbackResolver.cs`][resolver], [`SystemFontFallbackResolver.cs`][sysresolver], [`TextOptions.cs`][options], [`TextRun.cs`][textrun].
- Variation — [`FontVariation.cs`][variation], [`KnownVariationAxes.cs`][knownaxes], [`Tables/AdvancedTypographic/Variations/VariationAxis.cs`][axis], [`FVarTable.cs`][fvar], [`GlyphVariationProcessor.cs`][gvp].
- Outlines, hinting, rendering — [`Rendering/IGlyphRenderer.cs`][iglyphrenderer], [`Rendering/TextRenderer.cs`][renderer], [`Rendering/GlyphRendererParameters.cs`][params], [`HintingMode.cs`][hinting], [`ColorFontSupport.cs`][colorsupport], [`Tables/TrueType/Hinting/TrueTypeInterpreter.cs`][interp], [`Tables/TrueType/TrueTypeGlyphMetrics.cs`][ttgm], [`Tables/TrueType/Glyphs/GlyphVector.cs`][glyphvector], [`TextMeasurer.cs`][measurer].
- Project — [`README.md`][readme], [`LICENSE`][license], [`SixLabors.Fonts.csproj`][csproj].
<!-- References -->

[repo]: https://github.com/SixLabors/Fonts
[docs]: https://sixlabors.github.io/docs/
[readme]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/README.md
[license]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/LICENSE
[csproj]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/SixLabors.Fonts.csproj
[collection]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/FontCollection.cs
[sysfonts]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/SystemFonts.cs
[syscollection]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/SystemFontCollection.cs
[matcher]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Native/SystemFontMatcher.cs
[fcmatcher]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Native/FontConfigSystemFontMatcher.cs
[coretext]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Native/CoreText.cs
[dwmatcher]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Native/DirectWriteSystemFontMatcher.cs
[nativeface]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Native/NativeSystemFontFace.cs
[family]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/FontFamily.cs
[font]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Font.cs
[metrics]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/FontMetrics.cs
[filemetrics]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/FileFontMetrics.cs
[streammetrics]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/StreamFontMetrics.cs
[tt]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/StreamFontMetrics.TrueType.cs
[source]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/FontSource.cs
[description]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/FontDescription.cs
[tableloader]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Tables/TableLoader.cs
[hmetrics]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/HorizontalMetrics.cs
[glyphmetrics]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/FontGlyphMetrics.cs
[shaper]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/TextShaper.cs
[pipeline]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/TextShaper.Pipeline.cs
[buffer]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/TextShapingBuffer.cs
[info]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/ShapedGlyphInfo.cs
[pos]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/ShapedGlyphPosition.cs
[shaperfactory]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Tables/AdvancedTypographic/Shapers/ShaperFactory.cs
[resolver]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/IFontFallbackResolver.cs
[sysresolver]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/SystemFontFallbackResolver.cs
[options]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/TextOptions.cs
[textrun]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/TextRun.cs
[variation]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/FontVariation.cs
[knownaxes]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/KnownVariationAxes.cs
[axis]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Tables/AdvancedTypographic/Variations/VariationAxis.cs
[fvar]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Tables/AdvancedTypographic/Variations/FVarTable.cs
[gvp]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Tables/AdvancedTypographic/Variations/GlyphVariationProcessor.cs
[iglyphrenderer]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Rendering/IGlyphRenderer.cs
[renderer]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Rendering/TextRenderer.cs
[params]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Rendering/GlyphRendererParameters.cs
[hinting]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/HintingMode.cs
[colorsupport]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/ColorFontSupport.cs
[interp]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Tables/TrueType/Hinting/TrueTypeInterpreter.cs
[ttgm]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Tables/TrueType/TrueTypeGlyphMetrics.cs
[glyphvector]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/Tables/TrueType/Glyphs/GlyphVector.cs
[measurer]: https://github.com/SixLabors/Fonts/blob/4eb468d9b7f4b209859ff98c6c2ab41d9c7df6c5/src/SixLabors.Fonts/TextMeasurer.cs
