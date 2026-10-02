# Font libraries — concepts

The shared vocabulary of the [font-libraries survey](./index.md). Every term is
defined once here, grounded in the OpenType specification or a surveyed library,
and the deep-dives use it without redefining it. Where two libraries name the
same thing differently, both names are given.

**Last reviewed:** October 3, 2026

---

## Units and coordinate spaces

| Term                 | Definition                                                                                                                                                                                                                                                                            |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **font unit**        | The integer grid a font's outlines and metrics are designed on. `head.unitsPerEm` (**upem**) says how many make one em; `1000` (CFF tradition) and `2048` (TrueType tradition) are typical. Every table stores font units; nothing in a font file is in pixels.                       |
| **em / em square**   | The nominal size box. A 12 px font is one whose em maps to 12 px; glyphs may extend past it.                                                                                                                                                                                          |
| **ppem**             | Pixels per em — the font size in device pixels, and the only size a rasterizer cares about. Points become ppem through DPI: `ppem = pt × dpi / 72`.                                                                                                                                   |
| **26.6 fixed point** | FreeType's and Go's subpixel unit: a signed integer with 6 fractional bits, so `64` is one pixel. [`freetype.md`](./freetype.md), [`golang-image-font.md`](./golang-image-font.md).                                                                                                   |
| **scale**            | HarfBuzz's name for "font units → output units". `hb_font_set_scale(font, upem, upem)` makes shaping output design units; setting it to `ppem × 64` makes it 26.6 pixels. Shaping is size-independent until this is set. [`harfbuzz.md`](./harfbuzz.md).                              |
| **y-up vs y-down**   | Font outlines are y-up from the baseline; screens are y-down from the top. Every rasterizer flips once; where it flips is an API decision ([`ab-glyph.md`](./ab-glyph.md) and [`fontdue.md`](./fontdue.md) hand back y-down coverage, [`freetype.md`](./freetype.md) a y-up outline). |
| **cell**             | Not a font concept: the terminal's fixed advance box. Its width and height are _derived_ from font metrics by a policy ([`ghostty.md`](./ghostty.md), [`crossfont.md`](./crossfont.md)); no table states them.                                                                        |

## The object layers

Most surveyed libraries split a font into the same four or five objects, though
the names differ. The [comparison](./comparison.md) answers RQ1 over this table.

| Layer                   | What it holds                                                                     | Names in the survey                                                                                               |
| ----------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **blob / data**         | The file's bytes, owned or memory-mapped                                          | `hb_blob_t`, `FontData`, `Blob`, `SkData`, `Source::SharedFile`                                                   |
| **face**                | One font inside the bytes (a collection holds several): tables, upem, glyph count | `FT_Face`, `hb_face_t`, `FontRef`, `ttf_parser::Face`, `SkTypeface`, `IDWriteFontFace`, `CTFontDescriptor`        |
| **font (face at size)** | A face plus ppem, variation coordinates, synthetic style, hinting choice          | `FT_Size`, `hb_font_t`, `SkFont`, `PxScaleFont`, `CTFont`, `x/image/font.Face`                                    |
| **shaper**              | Turns text plus a font into positioned glyph ids                                  | `hb_shape`, `SkShaper`, `ShapeContext`, `rustybuzz::shape`, `IDWriteTextAnalyzer`                                 |
| **scaler / rasterizer** | Turns a glyph id plus a font into an outline or pixels                            | `FT_GlyphSlot` + `FT_Render_Glyph`, `SkScalerContext`, `ScaleContext`, `skrifa::OutlineGlyph`                     |
| **font manager**        | Enumerates installed faces, matches a request, picks fallbacks                    | `FcConfig`, `SkFontMgr`, `fontdb::Database`, `fontique::Collection`, `IDWriteFontCollection`, `fontscan::FontMap` |

**collection index** — the integer that picks one face out of a `.ttc`/`.otc`
file. Every face-loading API in the survey takes it, usually as a second
argument defaulting to `0`; raylib's `LoadFontEx` is the outlier that cannot.

## Characters, glyphs and clusters

- **codepoint** — a Unicode scalar value. Text is codepoints; fonts are glyphs.
- **glyph id (gid)** — an index into the font's glyph array, `0` being `.notdef`
  ("tofu"). Glyph ids are font-specific and meaningless across fonts.
- **`cmap`** — the table mapping codepoints to glyph ids. A cmap lookup is the
  _whole_ of "shaping" in libraries that do not shape
  ([`stb-truetype.md`](./stb-truetype.md), [`golang-image-font.md`](./golang-image-font.md)).
- **cluster** — the shaper's unit of correspondence between input and output: a
  run of input codepoints and the glyphs they became. HarfBuzz reports it as the
  input index of the cluster's first character; [`swash.md`](./swash.md) hands back
  `Cluster` objects with an explicit source range. A cursor, a selection or a
  terminal cell is placed by cluster, never by glyph.
- **grapheme cluster** — Unicode's user-perceived character (UAX #29), decided
  from text alone. A shaping cluster is decided by the font, and may merge
  several grapheme clusters (a ligature) or none.

## Shaping and layout features

- **shaping** — mapping a run of text in one font, script, language and
  direction to positioned glyphs: cmap lookup, then `GSUB` substitutions, then
  `GPOS` positioning (or the legacy `kern` table).
- **`GSUB` / `GPOS`** — the OpenType layout tables. `GSUB` replaces glyphs
  (ligatures, alternates, contextual forms); `GPOS` moves them (kerning, mark
  attachment). Both are organised as script → language system → feature →
  lookup.
- **feature tag** — a four-byte name for a set of lookups the shaper may apply:
  `liga` (standard ligatures), `calt` (contextual alternates), `kern`,
  `ss01`–`ss20` (stylistic sets), `cv01`–`cv99` (character variants), `zero`
  (slashed zero), `tnum` (tabular figures). An inspector lists them per script;
  the same tag appears once per language system, which is why a raw listing
  repeats `locl`.
- **programming ligature** — in practice almost always `calt`, not `liga`, and
  in the fonts measured for this survey it never changes the glyph count: `->`
  becomes two glyphs of one advance each that draw as one arrow, and `!=` becomes
  a zero-ink spacer plus one glyph that overhangs leftwards. The cell grid
  survives shaping. See the [runnable example](./examples/harfbuzz-shape-features.d)
  and the [comparison](./comparison.md).
- **script, language, direction** — the three properties a shaper needs beyond
  the font. HarfBuzz can guess them from the text
  (`hb_buffer_guess_segment_properties`); layout engines set them per run after
  itemization.
- **itemization** — splitting text into runs that share one font, script,
  direction and style. It is where per-character fallback actually happens:
  a run breaks whenever the selected face cannot cover the next character
  ([`pango.md`](./pango.md), [`cosmic-text.md`](./cosmic-text.md)).

## Variable fonts

- **axis** — a design dimension declared in `fvar`, with a four-byte tag,
  minimum, default and maximum in **user coordinates**: `wght` 100–900, `wdth`
  in percent, `opsz` in points, `slnt` in degrees, `ital` 0–1, plus private
  upper-case tags.
- **normalized coordinate** — the internal −1…0…+1 coordinate (stored as
  F2Dot14) every variation table interpolates in. User → normalized is a
  piecewise-linear map from `fvar`, then remapped through `avar` if present.
  Libraries differ on which space their API takes
  ([`fontations.md`](./fontations.md) exposes both; `hb_font_set_variations`
  takes user values; `FT_Set_Var_Design_Coordinates` takes user values in 16.16).
- **named instance** — a point in the design space with a name, listed in
  `fvar` ("Bold Condensed"). It is how a variable font pretends to be a family of
  static styles.
- **`STAT`** — the style-attributes table that names positions on each axis
  and links them, so an app can compose a style name for an arbitrary location.
- **variation flow** — the coordinates must reach _both_ the shaper (`GPOS`
  and `HVAR` change advances) and the rasterizer (`gvar`/`CFF2` change
  outlines). A library that sets them in one place for both is the subject of
  RQ3.

## Outlines and rasterization

- **outline** — a glyph's contours: quadratic Béziers in `glyf` (TrueType),
  cubic in `CFF`/`CFF2`. Exposed either as a **sink** (the caller implements
  `moveTo/lineTo/quadTo/cubicTo/close` — FreeType's `FT_Outline_Funcs`,
  HarfBuzz's `hb_draw_funcs_t`, fontTools' pens, skrifa's `OutlinePen`) or as
  **data** (an array of segments — stb's `stbtt_vertex`, ab_glyph's
  `OutlineCurve`, Go's `sfnt.Segments`). RQ6 compares the two.
- **hinting** — adjusting an outline to the pixel grid at a given ppem, either
  by the font's own TrueType bytecode, or by an **autohinter** that infers stems
  and blue zones. Hinting changes advances unless the library forbids it.
- **anti-aliasing (AA)** — coverage-based grayscale rendering. **Signed-area
  accumulation** (font-rs, stb v2, fontdue, ab_glyph, Go's `vector`) computes
  exact coverage per pixel in one pass and is the algorithm every from-scratch
  CPU rasterizer in the survey uses.
- **LCD / subpixel AA** — three coverage samples per pixel for the R, G, B
  stripes. It produces colour fringes on anything that is not an RGB-stripe
  panel, and cannot be composited over arbitrary backgrounds.
- **gamma / stem darkening** — coverage is linear but displays are not;
  libraries differ on whether they gamma-correct coverage or embolden thin stems
  to compensate.
- **subpixel positioning** — rendering a glyph at a fractional x offset, so a
  cache must key on (glyph, size, offset bucket). [`glyphon.md`](./glyphon.md)
  and [`cosmic-text.md`](./cosmic-text.md) quantise to four buckets.
- **SDF / MSDF** — a distance field stored in a texture, from which a shader
  reconstructs the edge at any scale. Multi-channel fields
  ([`msdfgen.md`](./msdfgen.md)) keep sharp corners.
- **direct GPU rendering** — evaluating the outline itself per pixel in a
  shader, with no bitmap at all ([`slug.md`](./slug.md), [`vello.md`](./vello.md)).
- **atlas** — a texture packing many rasterized glyphs, addressed by rectangle.
  Atlas growth and eviction are where a cache's correctness lives.

## Colour glyphs

| Format      | What it is                                                           | Typical font                    |
| ----------- | -------------------------------------------------------------------- | ------------------------------- |
| `COLR` v0   | Layered outlines, each layer filled with a flat colour from `CPAL`   | older Windows emoji             |
| `COLR` v1   | A paint graph: gradients, transforms, compositing over outline clips | Noto Color Emoji (vector build) |
| `CBDT/CBLC` | Embedded PNG bitmaps at fixed strikes                                | Noto Color Emoji (bitmap build) |
| `sbix`      | Apple's embedded bitmap strikes                                      | Apple Color Emoji               |
| `SVG `      | Embedded SVG documents per glyph                                     | some display fonts              |

A rasterizer that only fills outlines renders all five as tofu or as their
monochrome fallback.

## Metrics

- **ascender / descender / line gap** — three sets exist and disagree:
  `hhea` (Apple tradition), `OS/2` typographic (`sTypoAscender` …) and `OS/2`
  Windows (`usWinAscent` …, clipping bounds). `OS/2.fsSelection` bit 7
  `USE_TYPO_METRICS` says the typographic set is authoritative. Which set a
  library reads is a recurring finding in the deep-dives' spine §6.
- **x-height, cap height** — `OS/2.sxHeight` and `sCapHeight` (version 2+), or
  measured from the `x` and `H` outlines when absent.
- **advance** — horizontal distance to the next pen position, from `hmtx`,
  adjusted by `HVAR` under variation and by `GPOS` after shaping.
- **bearings / bounds** — the ink box relative to the pen position. A bitmap
  is placed by its left/top bearing, not at the pen.
- **underline / strikeout** — `post.underlinePosition/Thickness` and
  `OS/2.yStrikeoutPosition/Size`. Terminals need them; most UI libraries do not
  surface them ([`crossfont.md`](./crossfont.md) does).

## Discovery, matching and fallback

- **font database** — an index of installed faces with enough metadata to
  match without opening each file: family names (per language), style, weight,
  width, monospace flag, coverage. Built by scanning directories
  ([`fontdb.md`](./fontdb.md)) or asked of the OS ([`fontconfig.md`](./fontconfig.md),
  [`coretext.md`](./coretext.md), [`directwrite.md`](./directwrite.md)).
- **style attributes** — `OS/2.usWeightClass` (100–900), `usWidthClass` (1–9),
  `fsSelection` italic/oblique bits, `post.isFixedPitch`, and `PANOSE`
  classification bytes. fontconfig rescales weight to its own 0–210 scale;
  CSS keeps 100–900.
- **matching** — choosing the best face for a request (family, weight, width,
  slant). The CSS Fonts algorithm narrows by width, then style, then weight;
  fontconfig scores every pattern element in a fixed priority order.
- **fallback** — choosing another face when the matched one lacks a glyph.
  Three strategies appear in the survey: an ordered **fallback list** the user
  or OS supplies (fontconfig's `FcFontSort`, SixLabors' `FallbackFontFamilies`),
  **per-codepoint query** of the OS (`CTFontCreateForString`,
  `IDWriteFontFallback::MapCharacters`, `SkFontMgr::matchFamilyStyleCharacter`),
  and **per-script preference tables** shipped with the library
  ([`cosmic-text.md`](./cosmic-text.md), [`go-text-typesetting.md`](./go-text-typesetting.md)).
- **coverage / charset** — the set of codepoints a face maps. fontconfig
  stores it as an `FcCharSet`; the `sparkles-fonts` bundle precomputes it as
  `.charset` sidecars so a device without fontconfig can still match.
- **presentation** — text versus emoji rendering of the same codepoint,
  selected by variation selectors VS15 (U+FE0E) and VS16 (U+FE0F) and the
  `Emoji_Presentation` property.
- **synthetic style** — faking bold by emboldening outlines (or
  double-striking) and italic by shearing, when the family has no real face.
  [`parley.md`](./parley.md) carries it as an explicit `Synthesis` value.
- **activation** — making a font file visible to other applications without
  installing it (`CTFontManagerRegisterFontsForURL`, `AddFontResourceEx`,
  fontconfig `FcConfigAppFontAddFile`). A font manager feature; not a library
  feature anywhere in this survey.

## Sources

- [OpenType specification][ot-spec] — `head`, `hhea`, `hmtx`, `OS/2`, `post`,
  `cmap`, `GSUB`, `GPOS`, `fvar`, `avar`, `STAT`, `COLR`, `CPAL`, `CBDT`, `sbix`,
  `SVG `.
- [OpenType font variations overview][ot-var] — user and normalized
  coordinates, `avar`.
- [Feature tag registry][ot-features].
- [CSS Fonts Module Level 4, §5 font matching][css-match].
- [UAX #29 Unicode text segmentation][uax29].
- [Raph Levien, "Inside the fastest font renderer in the world"][font-rs] — the
  signed-area accumulation rasterizer.

<!-- References -->

[ot-spec]: https://learn.microsoft.com/en-us/typography/opentype/spec/
[ot-var]: https://learn.microsoft.com/en-us/typography/opentype/spec/otvaroverview
[ot-features]: https://learn.microsoft.com/en-us/typography/opentype/spec/featuretags
[css-match]: https://www.w3.org/TR/css-fonts-4/#font-matching-algorithm
[uax29]: https://www.unicode.org/reports/tr29/
[font-rs]: https://medium.com/@raphlinus/inside-the-fastest-font-renderer-in-the-world-75ae5270c445
