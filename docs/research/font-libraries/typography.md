# Typography (C# / .NET, LayoutFarm)

A pure-C# OpenType stack — parser, GSUB/GPOS layout, a ported TrueType bytecode
interpreter and a sink-style outline reader — split across shared-project
assemblies so the rendering back end stays outside the core.

| Field            | Value                                                                                                                                |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Language         | C# (`netstandard2.0`, `net20` for some assemblies; `AllowUnsafeBlocks`)                                                              |
| License          | MIT for the whole, with per-file FTL/Apache-2/BSD headers from the ported sources ([`LICENSE.md`][license])                          |
| Repository       | [`LayoutFarm/Typography`][repo]                                                                                                      |
| Documentation    | [`README.md`][readme], [`Typography.OpenFont/README.MD`][of-readme], [`Docs/Showcase.md`][showcase]                                  |
| Category         | parser (+ shaper, hinting interpreter, outline sink); rasterization lives in the separate PixelFarm repository                       |
| Layer(s) covered | parse · shape · outline · (raster via PixelFarm) · discover (folder scan) · match/fallback (per-codepoint, by Unicode range)         |
| Pinned revision  | `5877180c7c5271091379a0eaf9f03ab6ebd256b3` (2023-09-17, merge of `sep2023_rev6`; the clone is shallow, this is also the last commit) |

## Overview

### What it solves

Typography reads `.ttf`/`.otf`/`.ttc`/`.otc`/`.woff`/`.woff2` into a managed
`Typeface`, runs OpenType substitution and positioning in C#, hints TrueType
glyphs with a managed interpreter and hands outlines to any `IGlyphTranslator`.
It was spun out of the author's PixelFarm renderer so that other .NET renderers
(agg-sharp, SkiaSharp-based CSharpMath, emoji.wpf, zwcloud's ImGui) could reuse
the font side without the raster side ([`README.md`][readme]). Staleness is a
fact to weigh: the pinned revision is 2023-09-17 and nothing newer exists in the
clone.

### Design philosophy

The README states the boundary that organizes the whole repository:

> The core modules (Typography.OpenFont, Typography.GlyphLayout) do **NOT**
> provide a glyph rendering implementation. But as you are able to access and
> read all glyphs, it is easy to render them provided the exact position of each
> glyph.

— [`README.md`][readme]

The second statement is the design: everything below the pixel is a callback
interface, and the renderer is a consumer, not a dependency.

## How it works

The code is organised as MSBuild **shared projects** (`.projitems`) imported by
thin `.csproj` wrappers under `Build/`, so one source tree produces several
assemblies without project references. `Typography.One` imports five of them
into one DLL ([`Typography.One.csproj`][one-csproj]).

```
 Typography.One (single-assembly bundle)
 ├── Typography.OpenFont ─ Typeface, OpenFontReader, Glyph, IGlyphTranslator,
 │                          Tables.* (cmap/glyf/CFF/GSUB/GPOS/COLR/CBDT/SVG/fvar…),
 │                          TrueTypeInterperter/, WebFont/ (WOFF, WOFF2)
 ├── Typography.GlyphLayout ─ GlyphLayout, GlyphSubstitution, GlyphSetPosition,
 │                          UnscaledGlyphPlan → PxScaledGlyphPlan, ScriptLang
 ├── Typography.TextBreak ─ word/line breaking engines (dictionary-based CJK/Thai/…)
 ├── Typography.TextServices ─ InstalledTypefaceCollection, LoadSystemFonts,
 │                          per-codepoint alternative-typeface selection
 └── Unpack_SH ─ Brotli / zlib for WOFF2
 ─────────────── not in this repository ───────────────
 Typography.Contours, Typography.MsdfGen ─ csproj wrappers exist under Build/
     but import ..\..\Typography.Contours\*.projitems and PixelFarm paths that
     are absent from the tree; PixelFarm.Typography (the raster bridge) links
     against the PixelFarm renderer.
```

`Build/Typography.Contours/Typography.Contours.csproj` imports
`..\..\Typography.Contours\Typography.Contours.projitems` and
`..\..\PixelFarm\BackEnd.Triangulation\Triangulation.projitems`
([`Typography.Contours.csproj`][contours-csproj]); `git ls-files` returns zero
files under `Typography.Contours/`, so the MSDF/contour layer is **not
buildable from this clone**. The outline-fitting and atlas code that _is_ here
lives in [`PixelFarm.Typography/`][pf-readme].

**Reading** is `OpenFontReader.Read(Stream, int streamStartOffset, ReadFlags)`;
a collection is handled by first calling `ReadPreview`, which returns a
`PreviewFontInfo` with one member per face and the per-face offset to pass back
([`OpenFontReader.cs`][reader]). `ReadFlags` is `Full | Name | Metrics |
AdvancedLayout | Variation` — a request for a subset of tables.

**Layout** is `GlyphLayout.Layout(char[] str, int startAt, int len)` or the
codepoint overload; the result is read back as `UnscaledGlyphPlan`
(`glyphIndex`, `AdvanceX`, `OffsetX`, `OffsetY` as `short` font units plus
`input_cp_offset`), optionally rescaled to `PxScaledGlyphPlan` floats
([`GlyphLayout.cs`][layout], [`PixelScaleLayoutExtensions.cs`][pxscale]).

**Outlines** flow through `IGlyphTranslator`, and hinting through
`TrueTypeInterpreter.HintGlyph`, which returns a fresh scaled point array rather
than mutating the glyph.

## Analysis spine

### 1. Layering and ownership

Four managed layers, each a class graph owned by the GC: `Typeface` owns parsed
tables (`OS2Table`, `GSUBTable`, `GPOSTable`, `COLRTable`, `CPALTable` are
public properties, [`Typeface.cs`][typeface]) and an array of `Glyph` objects
each holding `GlyphPointF[]` + `ushort[] EndPoints` + `byte[]
GlyphInstructions` ([`Glyph.cs`][glyph]). Bytes are **copied out of the stream**
into these arrays; there is no borrowed buffer and the `Stream` can be closed
after `Read`. `GlyphLayout` caches a `GlyphLayoutPlanContext` (a
`GlyphSubstitution` + `GlyphSetPosition` pair) per `(Typeface, ScriptLang)`
hash ([`GlyphLayout.cs`][layout]). Memory pressure is addressed by an explicit
**trim/restore protocol**: `TrimDown()` drops outline arrays and returns a
`RestoreTicket`; `RestoreUp(ticket, stream)` re-reads them
([`Typeface_TrimableExtensions.cs`][trim]) — `Glyph` documents which fields are
`NULL in _onlyLayoutEssMode`. Thread-safety is unaddressed; `GlyphLayout` holds
reusable scratch lists. Errors are exceptions (`OpenFontException`,
`OpenFontNotSupportedException`) or `null` from `Read`.

### 2. Face loading and table access

From a `Stream` only (no path or memory-span API). Container detection is by the
first four bytes (`IsTtcf`/`IsWoff`/`IsWoff2`); WOFF/WOFF2 are decompressed via
the bundled Brotli/zlib ports. Tables are read **eagerly** in one pass by
`ReadTableEntryCollection`; `ReadFlags` is the only laziness. Raw table bytes
are not exposed — each parsed table is a typed object. The reader refuses a
`.ttc` passed without an offset (`return false`) and tells you to `ReadPreview`
first ([`OpenFontReader.cs`][reader]).

### 3. Shaping

`GlyphLayout` is a per-font, per-script shaper with its own GSUB
([`GSUB.cs`][gsub], 1 628 lines) and GPOS ([`GPOS.cs`][gpos], 1 293 + 888
lines). Controls are coarse booleans — `EnableLigature`, `EnableComposition`,
`EnableGsub`, `EnableGpos`, `EnableBuiltinMathItalicCorrection` — plus
`ScriptLang` (a `(scriptTag, sysLangTag)` pair) and `PositionTechnique`
(`OpenFont` GPOS vs legacy `Kern`). There is no per-feature-tag on/off list and
no direction parameter; RTL is reported by `GlyphPlanSequence.IsRightToLeft`.
Cluster mapping is `input_cp_offset` on every plan plus
`CreateMapFromUserCharToGlyphIndices`. Output is `short` font units.

### 4. Variation and instances

Parsed but **never applied**. `OpenFontReader` reads `STAT`, and if present
`fvar`, `gvar`, `cvar`, `HVAR`, `MVAR`, `avar` into local variables that are
dropped on the spot ([`OpenFontReader.cs`][reader] around the `STAT` block);
`Typeface` has no axis property and `Glyph` has no variation hook. `FVar`
exposes `VariableAxisRecord{axisTag,minValue,defaultValue,maxValue,axisNameID}`
and `InstanceRecord{subfamilyNameID,coordinates,postScriptNameID}`
([`FVar.cs`][fvar]) — enough for an inspector to list axes and named instances,
nothing more. Absence is the finding: a full managed parser stopped exactly at
the point where coordinates would have to flow into `glyf` deltas and `HVAR`.

### 5. Rasterization and outlines

**Outline API** — `IGlyphTranslator` is a pen sink in float font units:

```csharp
    public interface IGlyphTranslator
    {
        void BeginRead(int contourCount);
        void EndRead();
        void MoveTo(float x0, float y0);
        void LineTo(float x1, float y1);
        void Curve3(float x1, float y1, float x2, float y2);
        void Curve4(float x1, float y1, float x2, float y2, float x3, float y3);
        void CloseContour();
    }
```

— [`IGlyphTranslator.cs`][translator]. `IGlyphReaderExtensions.Read(tx,
glyphPoints, contourEndPoints, scale)` walks TrueType on/off-curve points and
synthesises implied on-curve midpoints; CFF charstrings are evaluated by
`CffEvaluationEngine` into the same sink. `BeginRead(contourCount)` is a
pre-allocation hint absent from FreeType's `FT_Outline_Funcs`.

**Hinting** — `TrueTypeInterperter/TrueTypeInterpreter.cs` (2 148 lines, 178
`case OpCode.*` arms) is a C# port of Michael Popoloski's SharpFont (the managed
reimplementation, not the FreeType binding) interpreter. It appends the four
phantom points, scales to pixels, runs `prep` via `SetControlValueTable`, then
executes the glyph program:

```csharp
            //5. hint
            _interpreter.HintGlyph(newGlyphPoints, contourEndPoints, instructions);
```

— [`TrueTypeInterpreter.cs`][interp]. The body honours
`InstructionControlFlags.InhibitGridFitting`, swallows
`InvalidTrueTypeFontException` and has `// TODO: composite glyphs`. An
`agg_x_scale = 1000` trick implements vertical-only hinting by stretching X
before and after. `HintTechnique` offers `None`,
`TrueTypeInstruction`, `TrueTypeInstruction_VerticalOnly`, `CustomAutoFit`
([`GlyphOutlineBuilderBase.cs`][builder-base]).

**Raster** — none in this repo. `PixelFarm.Typography/2_CpuBlit_BitmapAtlas/`
(`GlyphTextureBitmapGenerator`, `GlyphBitmapStore`, `FontAtlasTextPrinter`)
builds atlases over the external agg port; MSDF is the external
`Typography.MsdfGen`. Colour: `COLR`/`CPAL` v0 layers, `CBDT`/`CBLC`,
`EBDT`/`EBLC`, `sbix`-free; `SVG` exposed as a string via
`ReadSvgContent(glyphIndex, StringBuilder)`.

### 6. Metrics and measurement

Font-unit `short`s on `Typeface`: `Ascender`/`Descender`/`LineGap` switch
between `OS/2 sTypo*` and `hhea` on a `_useTypographicMertic` flag;
`ClipedAscender`/`ClipedDescender` are `usWinAscent`/`usWinDescent`;
`UnderlinePosition` comes from `post` ([`Typeface.cs`][typeface]).
`RecommendToUseTypoMetricsForLineSpacing` reads `fsSelection` bit 7 and
`CalculateRecommendLineSpacing(out LineSpacingChoice)` encodes the
hhea-vs-typo-vs-win decision as data ([`Typeface_Extensions.cs`][ext]).
Advances are `GetAdvanceWidthFromGlyphIndex` (`hmtx`); scale is
`CalculateScaleToPixel(px) = px / UnitsPerEm`. `MeasuredStringBox` carries
width plus ascending/descending/line-gap/clip in unscaled units with `*InPx`
projections ([`MeasureStringBox.cs`][msb]).

### 7. Discovery, matching and fallback

`LoadSystemFonts` is a hard-coded folder list — `c:\Windows\Fonts`,
`/usr/share/fonts` (recursive), wine and TeX trees, `/System/Library/Fonts`,
`/Library/Fonts` — overridable via `CustomSystemFontListLoader`
([`FontManagement.cs`][fontmgmt]). `InstalledTypeface` carries `FontName`,
`TypographicFamilyName`, `PostScriptName`, `WeightClass`, `WidthClass`,
`TypefaceStyle` from `OS/2`/`name` ([`InstalledTypeface.cs`][installed]).
Lookup is `GetInstalledTypeface(fontName, TypefaceStyle, weight)` — exact
family + enumerated style, no CSS-style distance scoring. **Per-codepoint
fallback** exists: `TryGetAlternativeTypefaceFromCodepoint` maps the codepoint
to a `UnicodeRangeInfo`, consults a dictionary built from each font's `OS/2`
`ulUnicodeRange` bits (`UpdateUnicodeRanges`), special-cases the emoji block,
and delegates the final choice to an `AltTypefaceSelectorBase`
([`InstalledTypefaceCollection.cs`][coll]). Range bits, not `cmap` coverage,
drive the candidate set — a font that declares a range but lacks the glyph is
still selected.

## What it teaches `sparkles:font`

- **A pen sink with a contour-count prologue.** `BeginRead(contourCount)` lets
  a path builder reserve once; worth adding to any D `OutlineSink` concept.
- **Trim/restore as a first-class protocol.** Dropping outline arrays after
  layout and re-reading from the stream on demand is an explicit answer to
  "who owns glyph bytes"; an offsets-over-borrowed-buffer design gets the same
  effect for free and should say so.
- **`ReadFlags` is the right granularity for an inspector vs a shaper**: name
  only, metrics only, advanced layout, variation.
- **Parsing `fvar` without applying it is a trap.** Reading the tables is the
  easy 20 percent; the design must route coordinates into `glyf`/`gvar`,
  `HVAR` and the hinter from day one.
- **Range-bit fallback is cheap and wrong at the edges.** Candidate selection by
  `OS/2` `ulUnicodeRange` must be confirmed against `cmap`.
- **A managed interpreter port is tractable (~2 100 lines, 178 opcodes) but
  incomplete** (no composites); budget for it accordingly if hinting is in scope.

## Strengths

- Complete managed parser: TrueType, CFF/Type2, WOFF/WOFF2, bitmap and SVG
  tables, `MATH`, `COLR`/`CPAL`.
- Own GSUB/GPOS engine and a TrueType bytecode interpreter in C#.
- Renderer-agnostic by construction — the sink interface is the only contract.
- Per-codepoint alternative-typeface hook with a pluggable selector.

## Weaknesses

- Unmaintained since 2023-09-17; the `Contours`/MSDF layer is not in the tree.
- Variation tables parsed and discarded; no axis API.
- Eager copy-everything loading; mitigated only by trim/restore.
- No feature-tag control, no direction input, no thread-safety statement.
- Fallback keyed on `OS/2` range bits, not `cmap`.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                         | Trade-off                                                       |
| ------------------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------- |
| Shared projects (`.projitems`) instead of assembly refs | One source tree, many assembly shapes (`Typography.One` bundle)   | Parts of the graph live in another repository; clone is partial |
| Copy tables into managed objects                        | GC-safe, stream can be closed                                     | Memory per face; needs `TrimDown`/`RestoreUp` to claw it back   |
| `IGlyphTranslator` pen sink in float font units         | Renderer independence; CFF and TrueType converge on one interface | Caller does all scaling and hinting integration                 |
| Managed TrueType interpreter                            | Hinting without native code                                       | Composite glyphs unimplemented; error swallowed                 |
| Read variation tables, apply none                       | Inspector-grade metadata at low cost                              | Variable fonts render at default instance only                  |
| Fallback by `ulUnicodeRange` bits                       | O(1) candidate lists per range without scanning `cmap`            | False positives when a font under-covers a declared range       |

## Sources

All paths verified with `git -C $REPOS/Typography cat-file -e HEAD:<path>`.

- [`README.md`][readme] — project arrangement and the no-rendering statement.
- [`Typography.OpenFont/OpenFontReader.cs`][reader] — `ReadFlags`, `ReadPreview`, the `STAT`/`fvar` block.
- [`Typography.OpenFont/Typeface.cs`][typeface], [`Typeface_Extensions.cs`][ext], [`Typeface_TrimableExtensions.cs`][trim], [`Glyph.cs`][glyph].
- [`Typography.OpenFont/IGlyphTranslator.cs`][translator] — the outline sink.
- [`Typography.OpenFont/TrueTypeInterperter/TrueTypeInterpreter.cs`][interp] — the hinting interpreter.
- [`Typography.OpenFont/Tables.AdvancedLayout/GSUB.cs`][gsub], [`GPOS.cs`][gpos]; [`Tables.Variations/FVar.cs`][fvar].
- [`Typography.GlyphLayout/GlyphLayout.cs`][layout], [`PixelScaleLayoutExtensions.cs`][pxscale], [`MeasureStringBox.cs`][msb].
- [`Typography.TextServices/FontCollections/FontManagement.cs`][fontmgmt], [`InstalledTypeface.cs`][installed], [`InstalledTypefaceCollection.cs`][coll].
- [`PixelFarm.Typography/3_Typography_Contours/GlyphOutlineBuilderBase.cs`][builder-base], [`PixelFarm.Typography/README.md`][pf-readme].
- [`Build/Typography.One/Typography.One.csproj`][one-csproj], [`Build/Typography.Contours/Typography.Contours.csproj`][contours-csproj].

<!-- References -->

[repo]: https://github.com/LayoutFarm/Typography
[license]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/LICENSE.md
[readme]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/README.md
[of-readme]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/README.MD
[showcase]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Docs/Showcase.md
[pf-readme]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/PixelFarm.Typography/README.md
[reader]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/OpenFontReader.cs
[typeface]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/Typeface.cs
[ext]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/Typeface_Extensions.cs
[trim]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/Typeface_TrimableExtensions.cs
[glyph]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/Glyph.cs
[translator]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/IGlyphTranslator.cs
[interp]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/TrueTypeInterperter/TrueTypeInterpreter.cs
[gsub]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/Tables.AdvancedLayout/GSUB.cs
[gpos]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/Tables.AdvancedLayout/GPOS.cs
[fvar]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.OpenFont/Tables.Variations/FVar.cs
[layout]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.GlyphLayout/GlyphLayout.cs
[pxscale]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.GlyphLayout/PixelScaleLayoutExtensions.cs
[msb]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.GlyphLayout/MeasureStringBox.cs
[fontmgmt]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.TextServices/FontCollections/FontManagement.cs
[installed]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.TextServices/FontCollections/InstalledTypeface.cs
[coll]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Typography.TextServices/FontCollections/InstalledTypefaceCollection.cs
[builder-base]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/PixelFarm.Typography/3_Typography_Contours/GlyphOutlineBuilderBase.cs
[one-csproj]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Build/Typography.One/Typography.One.csproj
[contours-csproj]: https://github.com/LayoutFarm/Typography/blob/5877180c7c5271091379a0eaf9f03ab6ebd256b3/Build/Typography.Contours/Typography.Contours.csproj
