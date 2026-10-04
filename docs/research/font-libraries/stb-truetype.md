# stb_truetype (C, single header)

A public-domain, 5 000-line, zero-dependency TrueType/CFF parser and
anti-aliased scanline rasterizer whose entire ownership model is "you keep the
file bytes alive; everything else is a value".

| Field            | Value                                                                                                                                                                          |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language         | C89 (single header; `#define STB_TRUETYPE_IMPLEMENTATION` in one TU)                                                                                                           |
| License          | Dual MIT / Unlicense ([`stb_truetype.h`][stbtt] tail, "ALTERNATIVE A" / "ALTERNATIVE B")                                                                                       |
| Repository       | [`nothings/stb`][repo]                                                                                                                                                         |
| Documentation    | The header itself: a usage block, two complete sample programs, per-function comments ([`stb_truetype.h`][stbtt]); [`tests/oversample/README.md`][oversample] for oversampling |
| Category         | parser · rasterizer                                                                                                                                                            |
| Layer(s) covered | parse · raster · outline                                                                                                                                                       |
| Version at pin   | v1.26 (2021-08-28 per the header's history)                                                                                                                                    |
| Pinned revision  | `2c980bb59875b0d32144a71867fbdebb2f77cd20` (2026-08-01)                                                                                                                        |

## Overview

### What it solves

Games and tools that need "a font on a texture" without linking FreeType. The
header lists its own scope in five lines — parse files, extract glyph metrics,
extract glyph shapes, render glyphs to one-channel bitmaps with box-filter
anti-aliasing, render glyphs to one-channel SDF bitmaps — followed by a
`Todo` list that is a catalogue of everything a serious font stack has and this
one does not: `non-MS cmaps`, `crashproof on bad data`, `hinting?`,
`cleartype-style AA?` ([`stb_truetype.h`][stbtt], lines 13–27). raylib's
`LoadFontEx` is built on it, which is why every raylib text limit `sparkles`
has hit traces back here (see [What it teaches](#what-it-teaches-sparklesfont)).

### Design philosophy

The header opens with the ownership contract and the threat model in the same
breath, and the first is the whole design:

```c
// stb_truetype.h - v1.26 - public domain
// authored from 2009-2021 by Sean Barrett / RAD Game Tools
//
// =======================================================================
//
//    NO SECURITY GUARANTEE -- DO NOT USE THIS ON UNTRUSTED FONT FILES
//
// This library does no range checking of the offsets found in the file,
// meaning an attacker can use it to read arbitrary memory.
```

— [`stb_truetype.h`][stbtt], lines 1–9

and, in the `NOTES` section: _"The system uses the raw data found in the .ttf
file without changing it and without building auxiliary data structures. This
is a bit inefficient on little-endian systems (the data is big-endian), but
assuming you're caching the bitmaps or glyph shapes this shouldn't be a big
deal."_ ([`stb_truetype.h`][stbtt], line 251). Offsets over a borrowed
big-endian buffer, no parse-time copy, no validation — the exact shape
`sparkles:font`'s table parser is planned to take, minus the "no validation".

## How it works

`stbtt_InitFont(info, data, offset)` walks the table directory with a linear
`stbtt__find_table` and records the offsets of `loca`, `head`, `glyf`, `hhea`,
`hmtx`, `kern`, `GPOS` and `SVG `, plus the first `cmap` subtable it
understands (Microsoft Unicode BMP/full, or Unicode platform). `cmap`, `head`,
`hhea`, `hmtx` are required; when `CFF ` replaces `glyf`/`loca` it parses the
CFF INDEX structures into `stbtt__buf` views over the same bytes
([`stb_truetype.h`][stbtt], lines 1383–1490). The result is a plain struct:

```c
struct stbtt_fontinfo
{
   void           * userdata;
   unsigned char  * data;              // pointer to .ttf file
   int              fontstart;         // offset of start of font
   int numGlyphs;                     // number of glyphs, needed for range checking
   int loca,head,glyf,hhea,hmtx,kern,gpos,svg; // table locations as offset from start of .ttf
   int index_map;                     // a cmap mapping for our chosen character encoding
   int indexToLocFormat;              // format needed to map from glyph index to glyph
   stbtt__buf cff;                    // cff font data
   ...
};
```

— [`stb_truetype.h`][stbtt], lines 713–728

Every downstream call takes `const stbtt_fontinfo *` plus a `float scale`
(`stbtt_ScaleForPixelHeight` = `pixels / (hhea.ascender − hhea.descender)`, or
`stbtt_ScaleForMappingEmToPixels` = `pixels / head.unitsPerEm`). There is no
sized-font object: scale is a parameter, not state. Rendering is
`stbtt_GetGlyphShape` → `stbtt_FlattenCurves` (subdivision to a
`flatness_in_pixels` tolerance, default 0.35 px) → `stbtt__rasterize` (sorted
edge list) → `stbtt__rasterize_sorted_edges` (per-scanline signed-area
accumulation), each stage allocating and freeing its intermediate — _"There are
a lot of memory allocations."_ (line 245).

## Analysis spine

### 1. Layering and ownership

One layer. There is no library handle, no face lifetime, no sized-font object
and no glyph slot. `stbtt_fontinfo` is _"pure value data with no additional
data structures"_ — _"You don't need to do anything special to free it"_
([`stb_truetype.h`][stbtt], lines 733–738) — and it borrows `data`: the caller
keeps the file bytes alive for as long as any call is made. Allocation goes
through overridable `STBTT_malloc(x,u)`/`STBTT_free(x,u)` with `userdata` as
`u`, for shapes, bitmaps, SDFs and rasterizer intermediates. Thread-safety is
unstated; nothing is mutated after `stbtt_InitFont` except one lazy `svg`
offset, so concurrent reads are safe in practice but not promised. Errors are
`0`/`-1` returns and `NULL` bitmaps; malformed input is undefined behaviour by
declaration.

### 2. Face loading and table access

From bytes only; there is no path API. Collections are handled by
`stbtt_GetNumberOfFonts(data)` and `stbtt_GetFontOffsetForIndex(data, index)`,
which recognise the `ttcf` tag (versions 1.0 and 2.0) and return the offset to
pass to `stbtt_InitFont`; a bare `.ttf` returns 0 for index 0 and −1 otherwise
([`stb_truetype.h`][stbtt], lines 697–710, 1320–1340). The table directory is
read eagerly, glyph data lazily from the buffer on every call. Raw table access
is not an API: the struct exposes `int` offsets and `stbtt__find_table` is
`static`, so an inspector cannot enumerate tables. It refuses nothing — a
`typ1`-tagged file is accepted with the comment _"we don't support this!"_
(line 1298) — and offset 0 of a `.ttc` hands the collection header to
`stbtt_InitFont`, which reads it as a font.

### 3. Shaping

None. The unit of work is one codepoint or glyph index; `stbtt_FindGlyphIndex`
is the only cmap lookup (no format 14, no GSUB, no script/language, no
clusters). The only positioning beyond `hmtx` advances is pair kerning:
`stbtt_GetGlyphKernAdvance(info, g1, g2)` reads `GPOS` lookup type 2 (PairPos
formats 1 and 2, first matching subtable, no feature or script selection) when
present, else `kern` format 0 ([`stb_truetype.h`][stbtt], lines 2496–2627).
`stbtt_GetKerningTable` dumps `kern` as `stbtt_kerningentry` triples — _"only
kern not GPOS"_ per the 1.23 changelog. Units are font units; the caller scales.

### 4. Variation and instances

None. `fvar`, `avar`, `gvar`, `HVAR` and `STAT` are never read; there is no
coordinate parameter anywhere. A variable font renders at its default
instance only. Named instances are invisible.

### 5. Rasterization and outlines

**Outline API (RQ6).** `stbtt_GetGlyphShape(info, glyph, &vertices)` returns a
malloc'd array — not a callback sink — of

```c
   typedef struct
   {
      stbtt_vertex_type x,y,cx,cy,cx1,cy1;
      unsigned char type,padding;
   } stbtt_vertex;
```

with `type` ∈ `STBTT_vmove`, `STBTT_vline`, `STBTT_vcurve` (quadratic, control
`cx,cy`), `STBTT_vcubic` (CFF; controls `cx,cy,cx1,cy1`), coordinates
_"expressed in 'unscaled' coordinates"_ — `short` font units
([`stb_truetype.h`][stbtt], lines 830–857). Composite glyphs are flattened
into the same array with their component transforms applied. `stbtt_IsGlyphEmpty`
answers without allocating. The `short` width is a real limit: a glyph
coordinate beyond ±32767 units cannot be represented.

**CPU raster (RQ2).** The v2 rasterizer (`STBTT_RASTERIZER_VERSION 2`, since
1.06) flattens curves to segments, sorts edges by `y0`, and per scanline
accumulates exact signed trapezoid areas into `float scanline[]` plus a
`scanline_fill[]` running coverage
(`scanline_fill[x] += height; // everything right of this pixel is filled`,
line 3139), summed and clamped to 0–255. It is a nonzero-winding signed-area
rasterizer with a documented defect: _"where multiple shapes overlap … it
overestimates the AA pixel coverage"_ (line 134); v1, a 5×/15× vertical
supersampler, stays behind the macro at _"about a 15% speed hit"_. Output is
linear coverage — no gamma, no LCD mode, no hinting (`Todo`: `hinting? (no
longer patented)`), no dropout control. Subpixel _positioning_ comes from
`shift_x`/`shift_y` on every `*Subpixel` entry point: _"Since the font is
anti-aliased, not hinted, this is very import[ant] for quality."_

**SDF.** `stbtt_GetGlyphSDF(info, scale, glyph, padding, onedge_value,
pixel_dist_scale, …)` computes a single-channel SDF analytically from the
flattened outline, `onedge_value`/`pixel_dist_scale` being bias and scale into
0–255, with the caveat _"not been optimized at all"_ (lines 945–1000). Not
multi-channel; compare [`msdfgen`](./msdfgen.md).

**Atlas.** `stbtt_PackBegin` / `stbtt_PackFontRanges` / `stbtt_PackEnd` pack
glyph bitmaps into a caller-owned 1-channel buffer via `stb_rect_pack.h`;
`stbtt_PackSetOversampling(h, v)` rasterizes at `h×v` resolution and
box-prefilters so bilinear sampling gives sub-pixel placement
(`STBTT_MAX_OVERSAMPLE` 8); the `GatherRects`/`PackRects`/`RenderIntoRects`
split packs several fonts into one texture (lines 588–665). The atlas is
one-shot: no eviction, no growth, no insertion after `PackEnd`.

**Color.** None rendered. `stbtt_GetGlyphSVG` returns a pointer into the
`SVG ` table (line 2694); `COLR`/`CPAL`, `CBDT` and `sbix` are never read.

### 6. Metrics and measurement

All metrics are `int` font units scaled by the caller's `float`.
`stbtt_GetFontVMetrics` reads `hhea` ascender/descender/lineGap (offsets
4/6/8); `stbtt_GetFontVMetricsOS2` reads `OS/2` `sTypo*` (offsets 68/70/72)
and returns 0 when absent ([`stb_truetype.h`][stbtt], lines 2634–2650).
`usWin*`, x-height and cap-height are not exposed. `stbtt_GetFontBoundingBox`
reads `head`; `stbtt_GetGlyphHMetrics` reads `hmtx` (short-tail rule);
`stbtt_GetGlyphBox` reads `glyf` bounds or runs the CFF charstring. The bitmap
box is the glyph box after scale, shift and `floor`/`ceil`, so the box, not the
rasterizer, sizes the bitmap. The header argues against point sizes and for
"ascender − descender in pixels" as the sizing unit (lines 170–192).

### 7. Discovery, matching and fallback

Deliberately absent, with a stated reason: _"You should really just solve
this offline, keep your own tables of what font is what, and don't try to get
it out of the .ttf file."_ ([`stb_truetype.h`][stbtt], lines 1004–1020).
Two helpers exist: `stbtt_FindMatchingFont(fontdata, name, flags)`
(case-sensitive `name`-record match plus `STBTT_MACSTYLE_*` flags) and
`stbtt_GetFontNameString` (any `name` record by platform/encoding/language/ID).
No `OS/2` weight/width/PANOSE, no coverage beyond `stbtt_FindGlyphIndex` per
codepoint, no fallback: a missing codepoint is glyph 0.

## What it teaches `sparkles:font`

- **Offsets over a borrowed buffer is a proven parser shape** — `stbtt_fontinfo`
  is a dozen `int`s and a pointer, trivially copyable and `@nogc`. What
  `sparkles:font` must add is the one thing stb refuses: bounds-checked reads
  that return an error instead of reading arbitrary memory.
- **Scale as a parameter, not a sized-font object, is where the model stops
  scaling** — nothing can cache per-size state and every call re-flattens and
  re-rasterizes. A `ScaledFont` layer (FreeType's `FT_Size`, HarfBuzz's
  `hb_font_t`) is the price of avoiding that.
- **Outline-as-array suits a D API**: a slice of `Vertex` with a `kind` enum is
  iterable, `pure` and testable without a sink; keep the four kinds, widen
  coordinates past `short`.
- **A signed-area scanline rasterizer is ~700 lines** — v2 is the reference
  answer to RQ2's CPU-feasibility question, and its overlapping-contour
  overestimate is the defect a from-scratch design must solve. FreeType's
  `smooth` renderer shares it and solves it by supersampling glyphs the font
  flags as overlapping ([`comparison.md`](./comparison.md#a-cpu-rasterizer-in-d-go)).
- **Oversampling + bilinear is the cheap sub-pixel answer for a static atlas**,
  and the atlas being one-shot is why `FontSet` reloads whole fonts on growth.
- **Every raylib text limit in `sparkles` is an stb limit.** `.ttc` collections
  are excluded from discovery because `LoadFontEx` calls `stbtt_InitFont` at
  offset 0 and reads the collection header as a font ([`font_coretext.d`][sp-ct],
  [`font_discovery.d`][sp-disc]); color emoji render as tofu because `COLR`/`CBDT`
  are never read ([`gui.md` `FNT7`][sp-gui]); glyph lookup is an `O(glyphCount)`
  scan that `font.d` re-sorts into its own map ([`font.d`][sp-font]); and there
  is no shaping, so complete clusters go through a separate FreeType/HarfBuzz
  path ([`font_set.d`][sp-fs]).

## Strengths

- One file, no dependencies, dual MIT/Unlicense, C89 and C++.
- Zero-copy parse; `stbtt_fontinfo` is value data with no destructor.
- Allocation redirectable through macros with a `userdata` context.
- TrueType `glyf` and CFF/Type 2 (CID-keyed `FDSelect` included), composites,
  `kern` and `GPOS` PairPos kerning.
- Exact-area AA rasterizer, analytic SDF and an oversampling atlas packer in
  one header; the documentation is the source.

## Weaknesses

- No bounds checking; explicitly unsafe on untrusted fonts.
- No shaping, GSUB, cmap format 14 or mark positioning; `GPOS` is read without
  feature or script selection.
- No variations, hinting, LCD filtering, gamma or color glyphs.
- Overlapping contours over-cover in AA, documented and unfixed since 1.06.
- `short` outline coordinates; per-call `malloc`/`free`; linear table lookup;
  no per-size caching.
- A `.ttc` at offset 0 silently misparses.
- Unmaintained since v1.26 (2021-08-28); `Todo` items from 2009 remain open.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                | Trade-off                                                                  |
| --------------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------- |
| Parse by offsets over the caller's buffer, build nothing  | No copies, no destructor, trivially embeddable           | Big-endian reads on every call; caller owns lifetime of the bytes          |
| No range checking                                         | Smaller, faster code; fonts assumed to be shipped assets | Arbitrary memory read on hostile input; unusable for a system-font browser |
| Scale is a `float` parameter, not an object               | No sized-font state to manage                            | No per-size cache, no hinting hook, every render re-flattens               |
| Outline returned as a malloc'd `stbtt_vertex[]`           | Iterable, inspectable, feeds `stbtt_Rasterize` directly  | One allocation per glyph; `short` coordinates                              |
| v2 signed-area rasterizer, no supersampling               | Exact coverage per pixel, faster than v1                 | Overlapping contours over-cover; no hinting or LCD                         |
| Single-channel analytic SDF                               | Resolution-independent text from one bitmap              | Unoptimized; rounded corners vs MSDF                                       |
| One-shot atlas via `stb_rect_pack`, optional oversampling | Shippable texture in three calls                         | No growth or eviction; consumers reload whole fonts                        |
| No discovery or matching                                  | "Solve this offline"                                     | Every consumer (raylib included) invents its own fallback                  |
| Kerning only, `GPOS` PairPos or `kern`                    | Covers Latin polish cheaply                              | No shaping; the header is a glyph library, not a text library              |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- [`stb_truetype.h`][stbtt] — the whole library: header comment (lines 1–260),
  public API (503–1040), `stbtt_InitFont` (1383–1490), outline extraction
  (1680–2300), kerning/`GPOS` (2317–2627), metrics (2634–2670), SVG (2677–2715),
  rasterizers v1/v2 (2807–3400), `stbtt_FlattenCurves` (3620), SDF, packer
  (3970–4200), license (5040–5078).
- [`stb_rect_pack.h`][rectpack] — the skyline packer `stbtt_PackBegin` uses.
- [`tests/oversample/README.md`][oversample] — the oversampling rationale.
- In-tree consumers: [`font_coretext.d`][sp-ct], [`font_discovery.d`][sp-disc],
[`font.d`][sp-font], [`font_set.d`][sp-fs], [`docs/specs/hue/gui.md`][sp-gui].
<!-- References -->

[repo]: https://github.com/nothings/stb
[stbtt]: https://github.com/nothings/stb/blob/2c980bb59875b0d32144a71867fbdebb2f77cd20/stb_truetype.h
[rectpack]: https://github.com/nothings/stb/blob/2c980bb59875b0d32144a71867fbdebb2f77cd20/stb_rect_pack.h
[oversample]: https://github.com/nothings/stb/blob/2c980bb59875b0d32144a71867fbdebb2f77cd20/tests/oversample/README.md
[sp-ct]: ../../../libs/raylib-text/src/sparkles/raylib_text/font_coretext.d
[sp-disc]: ../../../libs/raylib-text/src/sparkles/raylib_text/font_discovery.d
[sp-font]: ../../../libs/raylib-text/src/sparkles/raylib_text/font.d
[sp-fs]: ../../../libs/raylib-text/src/sparkles/raylib_text/font_set.d
[sp-gui]: ../../specs/hue/gui.md
