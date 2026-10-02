# FreeType (C core)

FreeType is the reference C font engine: it parses every major font format into one
`FT_Face`, scales it through `FT_Size`, loads one glyph at a time into `FT_GlyphSlot`,
and rasterizes outlines — but it deliberately does **no** shaping and **no** discovery.

| Field            | Value                                                                                                |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| Language         | C89/C99                                                                                              |
| License          | FreeType License (BSD-style, with credit clause) or GPLv2, dual ([`LICENSE.TXT`][license])           |
| Repository       | [`freetype/freetype`][repo]                                                                          |
| Documentation    | Header DDoc-style blocks under [`include/freetype/`][freetype-h]; [`docs/CHANGES`][changes]          |
| Category         | C core                                                                                               |
| Layer(s) covered | parse · raster · outline (plus variation and color-glyph decoding; no shape, no discover, no layout) |
| Version at pin   | 2.15.0 in development ([`docs/CHANGES`][changes], "CHANGES BETWEEN 2.14.3 and 2.15.0")               |
| Pinned revision  | `aff94e1306400217dfd14a35009418d142871f87` (2026-10-02)                                              |

## Overview

### What it solves

FreeType turns bytes of a font file — TrueType, CFF/OpenType, Type 1, CID, Type 42,
PFR, BDF, PCF, Windows FNT, and the color extensions COLR/CPAL (v0 and v1), CBDT/CBLC,
sbix and SVG — into glyph outlines or bitmaps at a requested size, with hinting. Its
public surface is a handful of opaque handles plus a few plain-data structs that the
caller reads directly (`FT_FaceRec`, `FT_GlyphSlotRec`, `FT_Outline`, `FT_Bitmap`).
Everything above the glyph — shaping, line layout, font selection — is explicitly
somebody else's job; HarfBuzz and fontconfig fill those roles and FreeType even
dlopens HarfBuzz for its own auto-hinter ([`src/autofit/ft-hb.c`][ft-hb]).

### Design philosophy

The thread-safety contract, introduced in 2.5.6 / 2.6 and restated on the `FT_Library`
type, is the clearest statement of the ownership model:

```c
   *   [Since 2.5.6] In multi-threaded applications it is easiest to use one
   *   `FT_Library` object per thread.  In case this is too cumbersome, a
   *   single `FT_Library` object across threads is possible also, as long as
   *   a mutex lock is used around @FT_New_Face and @FT_Done_Face.
```

— [`include/freetype/freetype.h`][freetype-h]. The release notes spell out the three
rules: "An `FT_Face` object can only be safely used from one thread at a time",
"An `FT_Library` object can now be used without modification from multiple threads at
the same time", and face creation/destruction on one library "can only be done from one
thread at a time" ([`docs/CHANGES`][changes], 2.6 section).

## How it works

Four handles, strictly nested. `FT_Library` owns the memory manager (`FT_Memory`), the
module list and the rasterizers. `FT_Face` is one face of one font resource, created
from a path (`FT_New_Face`), a caller-owned byte range (`FT_New_Memory_Face`) or an
`FT_Open_Args` describing a custom `FT_Stream` (`FT_Open_Face`). `FT_Size` is the face
scaled to one ppem; `FT_Set_Char_Size` / `FT_Set_Pixel_Sizes` / `FT_Request_Size` /
`FT_Select_Size` (for bitmap strikes) fill `FT_Size_Metrics`. `FT_GlyphSlot` is the
single mutable glyph container every `FT_Load_Glyph` overwrites: it holds `metrics`,
`linearHoriAdvance`, `advance`, `format`, `bitmap` + `bitmap_left`, `outline` and
`lsb_delta` ([`freetype.h`][freetype-h], `FT_GlyphSlotRec`).

Loading is one call with a flags word. `FT_LOAD_DEFAULT` hints and scales;
`FT_LOAD_NO_HINTING` disables hinting; `FT_LOAD_NO_AUTOHINT` forbids the auto-hinter;
`FT_LOAD_NO_SCALE` keeps font units (and implies no hinting, no bitmaps);
`FT_LOAD_RENDER` rasterizes immediately; `FT_LOAD_TARGET_NORMAL/LIGHT/MONO/LCD/LCD_V`
pick the hinting target; `FT_LOAD_COLOR` requests color data. Rendering is a second
call, `FT_Render_Glyph(slot, FT_RENDER_MODE_*)`, which converts `slot->outline` into
`slot->bitmap`.

Module behaviour is configured by string-keyed properties:
`FT_Property_Set(library, "truetype", "interpreter-version", &v)` with
`TT_INTERPRETER_VERSION_35/38/40` ([`ftdriver.h`][ftdriver-h]), likewise
`"autofitter"`/`"no-stem-darkening"`, `"cff"`/`"hinting-engine"`, `"sdf"`/`"spread"`.

## Analysis spine

### 1. Layering and ownership

| Layer        | Type                      | Owns                                                                                          |
| ------------ | ------------------------- | --------------------------------------------------------------------------------------------- |
| engine       | `FT_Library`              | `FT_MemoryRec` (`alloc`/`free`/`realloc` hooks, [`ftsystem.h`][ftsystem-h]), modules, rasters |
| face         | `FT_Face`                 | parsed tables, charmaps, `FT_GlyphSlot`, list of `FT_Size`s                                   |
| scaled font  | `FT_Size`                 | `FT_Size_Metrics`; one face can hold many, `FT_Activate_Size` picks the current               |
| glyph        | `FT_GlyphSlot`            | one glyph's outline/bitmap; overwritten by every load                                         |
| cache (opt.) | `FTC_Manager`, `FTC_Node` | LRU-bounded faces, sizes and refcounted image/sbit/cmap nodes ([`ftcache.h`][ftcache-h])      |

Bytes: `FT_New_Memory_Face` borrows — "You must not deallocate the memory before calling
`FT_Done_Face`" ([`freetype.h`][freetype-h]). `FT_New_Face` opens its own stream.
Lifetimes are manual with optional refcounts (`FT_Reference_Face`,
`FT_Reference_Library`). `FT_Outline` fields are owned by the slot unless
`FT_OUTLINE_OWNER` is set ([`ftimage.h`][ftimage-h]). Errors are an `FT_Error` integer
with a generated table ([`fterrors.h`][fterrors-h]); `0` is success. Thread-safety as
quoted above: a face is single-threaded, a library is shared with a lock around face
create/destroy.

### 2. Face loading and table access

`face_index` packs two values: bits 0–15 the face in a collection, bits 16–30 a named
instance (1-based; `0x00030004` is the third instance of face 4); a negative index
only probes `num_faces` ([`freetype.h`][freetype-h]). Parsing is eager for the sfnt
directory and the core tables, lazy per glyph. Raw tables are exposed two ways:
`FT_Get_Sfnt_Table(face, FT_SFNT_HEAD|MAXP|OS2|HHEA|VHEA|POST|PCLT)` returns a pointer
to a parsed struct "owned by the face object" ([`tttables.h`][tttables-h]), and
`FT_Load_Sfnt_Table(face, tag, offset, buffer, &length)` copies any table by tag into
client memory, with the two-call length probe idiom; tag `0` is the whole file and
tag `1` (since 2.14) the table directory. `FT_Sfnt_Table_Info` enumerates tags.
`FT_Get_Sfnt_Name_Count` / `FT_Get_Sfnt_Name` expose `name` records raw
([`ftsnames.h`][ftsnames-h]). FreeType refuses nothing by design but a face with only
unknown tables fails `FT_New_Face` with `FT_Err_Unknown_File_Format`.

### 3. Shaping

Not provided, by design. The only text-adjacent call is `FT_Get_Kerning` over the
legacy `kern` table; there is no GSUB/GPOS, no cluster model, no script/language
input. The auto-hinter's `afshaper.c` calls HarfBuzz internally only to find which
glyphs belong to a script for blue-zone computation, never to lay out text. The
decision pushes shaping to HarfBuzz ([`./harfbuzz.md`](./harfbuzz.md)), whose `hb-ft`
functions read metrics back from an `FT_Face`.

### 4. Variation and instances

`FT_Get_MM_Var` allocates an `FT_MM_Var` (axes with `minimum`/`def`/`maximum` as 16.16
design coordinates, `tag`, `strid`; `namedstyle` array of named instances) that the
caller frees with `FT_Done_MM_Var` ([`ftmm.h`][ftmm-h]). Coordinates are set on the
**face**, not the size: `FT_Set_Var_Design_Coordinates` (user/design space, `avar`
applied internally) or `FT_Set_Var_Blend_Coordinates` (normalized `[-1,1]`), each with
a `Get` twin; `FT_Set_Named_Instance(face, n)` sets bits 16–30 of `face_index` and
resets explicit coordinates. Because the position lives on the face, every `FT_Size`
and every subsequent `FT_Load_Glyph` sees it — rasterization follows automatically,
and `MVAR` adjusts `ascender`/`descender`/`height`/underline fields of `FT_FaceRec`
([`freetype.h`][freetype-h]). `FT_FACE_FLAG_VARIATION` reports "not at default
position". `STAT` is not interpreted. Since this pin, `VARC` variable composites are
supported ([`docs/CHANGES`][changes]).

### 5. Rasterization and outlines

**Outline API.** `FT_Outline` is a flat array model: `n_contours`, `n_points`,
`points` (`FT_Vector`), `tags` (on/conic/cubic per point) and `contours` (end index
per contour), with `flags` for fill rule (`FT_OUTLINE_EVEN_ODD_FILL`, `FT_OUTLINE_OVERLAP`
since 2.10.3) ([`ftimage.h`][ftimage-h]). `FT_Outline_Decompose(outline, &funcs, user)`
is the callback sink: `move_to`/`line_to`/`conic_to`/`cubic_to` with a `shift` and
`delta` pre-transform (`x' = (x << shift) - delta`) ([`ftoutln.h`][ftoutln-h]). Units
are 26.6 fixed-point pixels after scaling, or font units under `FT_LOAD_NO_SCALE`.
`FT_Outline_Get_CBox` / `FT_Outline_Get_BBox` give control vs. exact bounds;
`FT_Outline_EmboldenXY` and `ftstroke.h` modify paths.

**CPU raster.** `FT_RENDER_MODE_NORMAL` is 256-level coverage AA from the `smooth`
module ([`src/smooth/ftgrays.c`][ftgrays]); `LIGHT` is "equivalent to NORMAL" as a
render mode but as a `FT_LOAD_TARGET_LIGHT` it selects vertical-only auto-hinting;
`MONO` is 1-bpp; `LCD`/`LCD_V` produce 3× wide/tall bitmaps which the caller filters
via `FT_Library_SetLcdFilter` (`FT_LCD_FILTER_DEFAULT/LIGHT/LEGACY`) or
`FT_Library_SetLcdGeometry` ([`ftlcdfil.h`][ftlcdfil-h]); `SDF` (2.11) emits
`128 * (SDF / spread + 1)` clamped to 8 bits, spread a module property
([`src/sdf/ftsdf.c`][ftsdf], [`ftdriver.h`][ftdriver-h]). No gamma handling exists;
the header warns metrics are "unreliable with an error margin of at least one pixel"
once hinting is on. Hinting is either the TrueType bytecode interpreter
([`src/truetype/ttinterp.c`][ttinterp]; v40 "equivalent to the hinting provided by
DirectWrite ClearType", default when `TT_CONFIG_OPTION_SUBPIXEL_HINTING` is built) or
the script-aware `autofit` module. There is no GPU path.

**Color.** `FT_LOAD_COLOR` searches bitmap strikes (CBDT/sbix → `FT_PIXEL_MODE_BGRA`,
premultiplied), then SVG (`FT_GLYPH_FORMAT_SVG`, rendered only through the caller-
supplied hooks in [`otsvg.h`][otsvg-h]), then COLR. COLRv0 is an iterator:
`FT_Palette_Select` then `FT_Get_Color_Glyph_Layer(face, gid, &layer_gid,
&color_index, &iterator)` ([`ftcolor.h`][ftcolor-h]). COLRv1 is a paint-graph walk:
`FT_Get_Color_Glyph_Paint` returns the root `FT_OpaquePaint`, `FT_Get_Paint`
decodes it into an `FT_PaintFormat`-tagged union, `FT_Get_Paint_Layers` and
`FT_Get_Colorline_Stops` iterate children; `FT_Get_Color_Glyph_ClipBox` bounds it.
FreeType does not composite COLRv1 itself.

**Caching.** `FTC_Manager_New(library, max_faces, max_sizes, max_bytes, requester)`
maps caller `FTC_FaceID` values to faces via a callback, keeps MRU lists, and hands out
refcounted `FTC_Node`s from `FTC_ImageCache`, `FTC_SBitCache` and `FTC_CMapCache`
([`ftcache.h`][ftcache-h]). No atlas; glyphs are individual bitmaps.

### 6. Metrics and measurement

`FT_FaceRec` carries `units_per_EM`, `ascender`, `descender`, `height`,
`max_advance_width`, `underline_*` in font units, sourced from `hhea` (falling back to
`bbox.yMax`/`yMin`) ([`freetype.h`][freetype-h]). `FT_Size_Metrics` gives the scaled
versions in 26.6 pixels but **rounded**: `ascender` rounded up, `descender` down; the
header recommends `FT_MulFix(face->ascender, size_metrics->y_scale)` for exact values
and a different rounding for natively hinted TrueType. `TT_OS2` (via
`FT_Get_Sfnt_Table`) exposes `sTypoAscender/Descender/LineGap`, `usWinAscent/Descent`,
`sxHeight`, `sCapHeight`, `fsSelection` — the header itself says `hhea` `Ascender`
"is invalid in many fonts … use the `sTypoAscender` field" ([`tttables.h`][tttables-h]).
Per glyph: `FT_Glyph_Metrics` (26.6), `linearHoriAdvance` (16.16, unhinted),
`FT_Get_Advance` with `FT_ADVANCE_FLAG_FAST_ONLY` for fast `hmtx` reads
([`ftadvanc.h`][ftadvanc-h]).

### 7. Discovery, matching and fallback

Absent, by design. FreeType has no notion of a system font directory, family matching
or codepoint fallback; `FT_Get_Char_Index`, `FT_Get_First_Char`/`FT_Get_Next_Char`
and `FT_Select_Charmap` only answer coverage for one face. The classification data an
engine like fontconfig consumes — `usWeightClass`, `usWidthClass`, `panose[10]`,
`ulUnicodeRange1..4`, `fsSelection` — is reachable through `TT_OS2`, and `family_name`
/ `style_name` / `style_flags` on `FT_FaceRec`. See [`./fontconfig.md`](./fontconfig.md).

## What it teaches `sparkles:font`

- **Separate face from scaled font from glyph slot**, but do not share one mutable
  slot: `FT_GlyphSlot` is the reason an `FT_Face` is single-threaded. A D design can
  keep the face immutable and make the slot a caller-owned value.
- **Variation position belongs on the face, not the size**, so every ppem and every
  consumer sees the same instance; copy `FT_Set_Named_Instance`'s index-in-`face_index`
  trick as a plain field instead.
- **Offer both parsed-struct and raw-bytes table access** (`FT_Get_Sfnt_Table` vs.
  `FT_Load_Sfnt_Table`), with the raw path returning a borrowed slice instead of a
  copy-into-caller-buffer.
- **The outline sink should be a callback table with a pre-transform**, and the
  outline struct a flat SoA (`points`/`tags`/`contours`) — both are trivially `@nogc`.
- **Expose unrounded metrics**: `FT_Size_Metrics` rounding is a documented regret.
- **A memory-manager hook (`FT_MemoryRec`) and a face-ID → face requester
  (`FTC_Face_Requester`)** are the two injection points every consumer actually uses.

## Strengths

- Covers every font format and every color extension with one glyph API.
- Three hinting strategies (bytecode v35/v38/v40, autofit, none) selectable per load.
- Borrowed-memory faces and pluggable allocation make embedding cheap.
- Documented, stable thread model since 2015.

## Weaknesses

- The single `FT_GlyphSlot` per face forces serialization or one face per thread.
- `FT_Size_Metrics` are rounded; `hhea` vs `OS/2` selection is left to the caller.
- No shaping, discovery or atlas; a complete stack needs three more libraries.
- COLRv1 and SVG are decoded but never composited by FreeType itself.
- Error model is an integer code with no payload.

## Key design decisions and trade-offs

| Decision                                  | Rationale                              | Trade-off                                             |
| ----------------------------------------- | -------------------------------------- | ----------------------------------------------------- |
| One mutable `FT_GlyphSlot` per face       | Zero allocation per glyph load         | A face is single-threaded                             |
| Variation coordinates stored on `FT_Face` | All sizes and loads agree              | Two faces needed to render two instances concurrently |
| Scaled values in 26.6, scales in 16.16    | Integer-only arithmetic, deterministic | Every consumer converts units; rounded size metrics   |
| Raw tables by copy (`FT_Load_Sfnt_Table`) | Works for stream-backed faces too      | Two calls and a malloc for every table read           |
| No shaping, no discovery                  | Keep the engine format-focused         | HarfBuzz + fontconfig become mandatory for real text  |
| Module properties as string keys          | Add knobs without ABI breaks           | Untyped; typos fail at run time                       |
| LCD filtering as a library-global setting | Matches the one-display assumption     | Cannot differ per face or per surface                 |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- [`include/freetype/freetype.h`][freetype-h] — `FT_Library`, `FT_FaceRec`,
  `face_index`, `FT_Size_Metrics`, `FT_GlyphSlotRec`, `FT_LOAD_*`, `FT_RENDER_MODE_*`,
  `FT_New_Memory_Face`, thread-safety note
- [`include/freetype/ftoutln.h`][ftoutln-h], [`ftimage.h`][ftimage-h] —
  `FT_Outline`, `FT_Outline_Funcs`, `FT_Outline_Decompose`, fill flags
- [`include/freetype/ftmm.h`][ftmm-h] — `FT_MM_Var`, `FT_Set_Var_Design_Coordinates`,
  `FT_Set_Named_Instance`
- [`include/freetype/ftcolor.h`][ftcolor-h] — COLRv0 layer iterator, COLRv1 paint API
- [`include/freetype/ftcache.h`][ftcache-h] — `FTC_Manager`, `FTC_Node`
- [`include/freetype/ftsystem.h`][ftsystem-h] — `FT_MemoryRec`, `FT_StreamRec`
- [`include/freetype/tttables.h`][tttables-h] — `FT_Get_Sfnt_Table`,
  `FT_Load_Sfnt_Table`, `TT_OS2`
- [`include/freetype/ftdriver.h`][ftdriver-h] — `interpreter-version`, `spread`,
  stem darkening properties
- [`include/freetype/ftlcdfil.h`][ftlcdfil-h], [`ftsnames.h`][ftsnames-h],
  [`ftadvanc.h`][ftadvanc-h], [`otsvg.h`][otsvg-h], [`fterrors.h`][fterrors-h]
- [`src/smooth/ftgrays.c`][ftgrays], [`src/sdf/ftsdf.c`][ftsdf],
  [`src/truetype/ttinterp.c`][ttinterp], [`src/autofit/ft-hb.c`][ft-hb]
- [`docs/CHANGES`][changes] — 2.6 thread model, 2.11 SDF, 2.15 VARC
- [`LICENSE.TXT`][license]

<!-- References -->

[repo]: https://github.com/freetype/freetype
[license]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/LICENSE.TXT
[changes]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/docs/CHANGES
[freetype-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/freetype.h
[ftoutln-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/ftoutln.h
[ftimage-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/ftimage.h
[ftmm-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/ftmm.h
[ftcolor-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/ftcolor.h
[ftcache-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/ftcache.h
[ftsystem-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/ftsystem.h
[ftsnames-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/ftsnames.h
[ftlcdfil-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/ftlcdfil.h
[ftdriver-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/ftdriver.h
[tttables-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/tttables.h
[ftadvanc-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/ftadvanc.h
[otsvg-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/otsvg.h
[fterrors-h]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/include/freetype/fterrors.h
[ftgrays]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/src/smooth/ftgrays.c
[ftsdf]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/src/sdf/ftsdf.c
[ttinterp]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/src/truetype/ttinterp.c
[ft-hb]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/src/autofit/ft-hb.c
