# Fontconfig (C)

The system font database for Linux and the BSDs: every font is a bag of typed
properties, every request is the same kind of bag, and matching is a fixed
lexicographic scoring of one against the other — a design in which the
_fallback list_ (`FcFontSort`) is the primary output and the single best match
is merely its first element.

| Field            | Value                                                                                                                       |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Language         | C (with an optional Rust indexer, `fc-fontations`)                                                                          |
| License          | MIT-style ([`COPYING`][copying])                                                                                            |
| Repository       | [fontconfig/fontconfig][repo] (GitLab, freedesktop.org)                                                                     |
| Documentation    | [`doc/fontconfig-devel.sgml`][devel] (assembled from the `doc/*.fncs` function files), [`doc/fontconfig-user.sgml`][user]   |
| Category         | font database/discovery                                                                                                     |
| Layer(s) covered | discover · match/fallback (plus a sliver of parse: `FcFreeTypeQuery` reads tables to _describe_ a face, never to render it) |
| Version at pin   | 2.18.3 ([`fontconfig.h.in`][hdr] `FC_MAJOR`/`FC_MINOR`/`FC_REVISION`)                                                       |
| Pinned revision  | `d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc` (2026-10-01)                                                                     |

## Overview

### What it solves

Fontconfig answers one question for every application on a Linux desktop: _given
a request like "monospace, bold, 11 pt, covers Devanagari", which font files, in
what order?_ It scans the configured directories, describes every face as an
`FcPattern` (the FreeType-backed scanner in [`src/fcfreetype.c`][fcft] builds the
charset, the language set, the OS/2-derived weight and width, the variable-axis
ranges), serialises the resulting `FcFontSet` per directory into an mmap-able
cache ([`src/fccache.c`][fccache]), and exposes a matcher over the union. It owns
no glyphs, no outlines and no rasterizer; its deliverable is a prepared
`FcPattern` holding `FC_FILE`, `FC_INDEX` and the render hints a FreeType caller
should honour.

### Design philosophy

The user manual states the two-module split and the intended division of labour
with applications in one paragraph:

> Fontconfig contains two essential modules, the configuration module which
> builds an internal configuration from XML files and the matching module which
> accepts font patterns and returns the nearest matching font. […] Font
> configuration is separate from font matching; applications needing to do
> their own matching can access the available fonts from the library and
> perform private matching.

— [`doc/fontconfig-user.sgml`][user]

The matching module's governing data structure is a _priority table_, and the
source says plainly that its order is the algorithm:

```c
/*
 * Order is significant, it defines the precedence of
 * each value, earlier values are more significant than
 * later values
 */
#define FC_OBJECT(NAME, Type, Cmp) { FC_##NAME##_OBJECT, Cmp, PRI_##NAME##_STRONG, PRI_##NAME##_WEAK },
static const FcMatcher _FcMatchers[] = {
    { FC_INVALID_OBJECT, NULL, -1, -1 },
#include "fcobjs.h"
};
```

— [`src/fcmatch.c`][fcmatch]

## How it works

**Everything is an `FcPattern`.** A pattern is a small header plus an array of
`FcPatternElt` (one per property, keyed by an interned `FcObject` integer), each
pointing at a linked `FcValueList` whose nodes carry a tagged `FcValue` and a
`FcValueBinding` (`Strong`/`Weak`/`Same`) ([`src/fcint.h`][fcint]). The property
vocabulary is a table of string names with declared types — `FC_FAMILY`
(`String`), `FC_WEIGHT` (`Range`), `FC_CHARSET` (`CharSet`), `FC_LANG`
(`LangSet`), `FC_FILE`, `FC_INDEX`, `FC_VARIABLE`, `FC_FONT_VARIATIONS`, … —
and the same list with each property's comparator is what
`#include "fcobjs.h"` expands into above ([`src/fcobjs.h`][fcobjs]).

**The request pipeline is three calls.** `FcConfigSubstitute(config, pat,
FcMatchPattern)` runs the XML rules, `FcDefaultSubstitute(pat)` fills in weight
`NORMAL`, slant `ROMAN`, width `NORMAL`, size 12, dpi 75 → `pixelsize`, hint
style `FULL` and the locale's `FC_LANG` ([`src/fcdefault.c`][fcdefault]); then
`FcFontMatch` or `FcFontSort` scores. The docs insist on the order: `FcFontSort`
_"should be called only after FcConfigSubstitute and FcDefaultSubstitute have
been called for p; otherwise the results will not be correct"_
([`doc/fcconfig.fncs`][fncs-config]).

**Scoring is a vector, compared lexicographically.** `FcCompare` fills a
`double score[PRI_END]` for every candidate; `FcCompareValueList` visits every
(pattern value, font value) pair for a property, calls the property's comparator,
and folds position into the number — `v * 1000 + j * 100 + k` — so an earlier
pattern value beats a later one at equal distance ([`src/fcmatch.c`][fcmatch]).
`FcSortCompare` then walks the vectors from index 0 and returns on the first
differing slot. The slot order is the `FcMatcherPriority` enum: `FILE`,
`FONT_WRAPPER`, `FONTFORMAT`, `VARIABLE`, `NAMED_INSTANCE`, `SCALABLE`, `COLOR`,
`FOUNDRY`, `CHARSET`, `FAMILY_STRONG`, `GENERIC_FAMILY`, `POSTSCRIPT_NAME_STRONG`,
`LANG`, `FAMILY_WEAK`, `POSTSCRIPT_NAME_WEAK`, `SYMBOL`, `SPACING`, `SIZE`,
`PIXEL_SIZE`, `STYLE`, `SLANT`, `WEIGHT`, `WIDTH`, `FONT_HAS_HINT`, `DECORATIVE`,
`ANTIALIAS`, `RASTERIZER`, `OUTLINE`, `ORDER`, `FONTVERSION`. Two consequences:
**charset coverage outranks family** (a font lacking requested codepoints loses
to any font that has them, whatever its name), and **a strongly bound family
outranks language, which outranks a weakly bound family** — how
`<alias binding="strong">` in a config file beats locale preference.

**`FcFontRenderPrepare` merges request and answer** into a new pattern: the
font's elements, the request's elements the font lacks, and for shared
properties the _best matching value_ found during scoring, then the
`FcMatchFont` rule pass ([`doc/fcconfig.fncs`][fncs-config]). Render hints get
their final values here, and a variable font's ranges collapse to one coordinate
(§4).

## Analysis spine

### 1. Layering and ownership

Three opaque heap types carry the surface: `FcConfig` (directories, rule sets,
the `FcSetSystem`/`FcSetApplication` font sets, a `FcRef`), `FcFontSet` (a
growable `FcPattern **fonts` array) and `FcPattern` ([`src/fcint.h`][fcint]);
`FcCharSet` and `FcLangSet` are owned through patterns. Ownership is
**reference counting with a "constant" sentinel**: `FcPatternReference`
increments unless `FcRefIsConst`, `FcPatternDestroy` frees at one, and a pattern
inside an mmap'd cache is constant, neither counted nor freed
([`src/fcpat.c`][fcpat]). Cache-resident structures use **offsets instead of
pointers** (`FcIsEncodedOffset` tests the low bit), so a whole `FcFontSet` is
position-independent ([`src/fcint.h`][fcint]). `FcFontSetDestroy` releases every
member ([`src/fcfs.c`][fcfs]); the `FcFontSort` docs warn that results _"may be
shared by the return value from multiple FcFontSort calls, applications must not
modify these patterns"_ ([`doc/fcconfig.fncs`][fncs-config]). Thread-safety was
retrofitted in 2.11 (atomic refcounts, a mutex around the current `FcConfig`,
[`src/fcmutex.h`][fcmutex]); the contract is immutability after publication, not
safe concurrent mutation. Errors are `FcBool` plus an out-`FcResult`
(`FcResultMatch`, `NoMatch`, `TypeMismatch`, `NoId`, `OutOfMemory`).

### 2. Face loading and table access

Fontconfig never hands out a face. `FcFreeTypeQuery(file, id, blanks, &count)`
and `FcFreeTypeQueryAll` open the file with FreeType, and `FcFreeTypeQueryFace`
describes an already-open `FT_Face` ([`fcfreetype.h`][fcfth]). The `id` argument
packs a **collection index in the low 16 bits and a named-instance index in the
high 16** — `set_face_num = id & 0xFFFF`, `set_instance_num = id >> 16`, with
instance `0x8000` meaning "the variable font itself" ([`src/fcfreetype.c`][fcft]);
this is the `FC_INDEX` a pattern carries and the number `FT_New_Face` accepts
unchanged. Table access is internal: the scanner reads OS/2 (`usWeightClass`,
`usWidthClass`), `head` (`FC_FONTVERSION`), `name`, `GSUB`/`GPOS`/`Silf`
presence (`FC_CAPABILITY` as `"otlayout:…"` strings) and colour tables
(`FC_COLOR`); an optional Rust indexer on Fontations is a build option
([`src/fcfontations.c`][fcfont]). Nothing is lazy: a directory is scanned fully,
every charset enumerated via `FT_Get_First_Char`/`FT_Get_Next_Char`, then cached.

### 3. Shaping

Not applicable: fontconfig performs no shaping and has no glyph vocabulary. Its
only contribution to a shaper is the `FC_FONT_FEATURES` string property (a
pass-through for `+liga`-style settings written in config files) and the
`FC_CAPABILITY` tag list. Absence is the finding: the database stops at _which
file_, and leaves cluster mapping, script and direction to Pango or HarfBuzz
(see [`./pango.md`](./pango.md), [`./harfbuzz.md`](./harfbuzz.md)).

### 4. Variation and instances

Variable fonts are modelled as **ranges on ordinary properties**. The scanner
calls `FT_Get_MM_Var`, and for the variable face itself records `FC_WEIGHT`,
`FC_WIDTH` and `FC_SIZE` as `FcRange` spanning the axis `minimum..maximum`
(16.16 fixed converted to double; `wght` passed through `FcWeightFromOpenTypeDouble`),
sets `FC_VARIABLE = true`, and emits one further pattern per named instance with
point values and `FC_NAMED_INSTANCE = true` ([`src/fcfreetype.c`][fcft]).
`FcCompareRange` scores _zero_ on overlap and takes the intersection midpoint as
the best value ([`src/fcmatch.c`][fcmatch]); `VARIABLE` and `NAMED_INSTANCE`
sit near the top of the priority list so a config can prefer instances over the
bare variable face. `FcFontRenderPrepare` then writes the chosen
weight/width/size into `FC_FONT_VARIATIONS` as `"wght=700,wdth=…,opsz=…"`
(weight mapped back with `FcWeightToOpenType`) ([`src/fcmatch.c`][fcmatch]). The
caller parses that string and applies it via `FT_Set_Var_Design_Coordinates` or
`hb_font_set_variations`; fontconfig never touches `avar` or normalised
coordinates, and custom axes are invisible to matching.

### 5. Rasterization and outlines

Not applicable: no raster, no outline, no colour rendering. What fontconfig
_does_ own is the **policy** half of rasterization: `FC_ANTIALIAS`,
`FC_HINTING`, `FC_HINT_STYLE` (`FC_HINT_NONE`/`SLIGHT`/`MEDIUM`/`FULL`),
`FC_AUTOHINT`, `FC_RGBA` (`FC_RGBA_RGB`/`BGR`/`VRGB`/`VBGR`/`NONE`),
`FC_LCD_FILTER`, `FC_EMBEDDED_BITMAP`, `FC_EMBOLDEN` (a bold request matched a
regular face: synthesise), `FC_MATRIX` (synthetic oblique) and
`FC_DPI`/`FC_PIXEL_SIZE` ([`fontconfig.h.in`][hdr]). The defaults table in
[`src/fcdefault.c`][fcdefault] names the FreeType load flag each one controls
(`FC_HINTING_OBJECT, FcTrue /* !FT_LOAD_NO_HINTING */`). `FC_COLOR` is matchable,
so an emoji request can demand a colour face.

### 6. Metrics and measurement

Not applicable beyond classification. `FC_SPACING` is derived by measuring the
advances of the charset's glyphs: `FC_SPACING_MONO`, `FC_SPACING_DUAL` (two
advances, the wider double the narrower — the CJK terminal case),
`FC_SPACING_CHARCELL`, or `FC_SPACING_PROPORTIONAL` ([`src/fcfreetype.c`][fcft]).
No ascender, descender, x-height or line gap is stored; the caller gets those
from the face it opens with `FC_FILE`/`FC_INDEX`.

### 7. Discovery, matching and fallback

This is the whole library. **Enumeration**: `FcInitLoadConfigAndFonts` parses
`fonts.conf` and `conf.d/*.conf`, then per font directory maps the `.cache-N`
file or rescans; `FcFontList(config, pat, objectset)` filters the flat set by
_equality_, not scoring ([`fontconfig.h.in`][hdr]). Caches are validated by
directory mtime and format version, and files above `FC_CACHE_MIN_MMAP` are
`mmap`'d `MAP_SHARED` so every process shares one copy
([`src/fccache.c`][fccache]). **Fallback**:
`FcFontSort(config, pat, trim, &csp, &result)` scores _every_ font, sorts, then
runs a second pass over `FC_LANG` — each requested language is claimed once, in
request order, and fonts satisfying none get `score[PRI_LANG] = 10000` — and
re-sorts. `FcSortWalk` then accumulates an `FcCharSet` union down the list and,
with `trim`, _drops any font that adds no codepoints_ ([`src/fcmatch.c`][fcmatch]).
That is the per-codepoint fallback chain; `csp` returns the union so a layout
engine can test renderability without opening a face. **Coverage** is
`FcCharSet`: sorted 256-codepoint page numbers plus `FcCharLeaf` bitmaps,
binary-searched by `ucs4 >> 8` ([`src/fccharset.c`][fccharset]). **Language** is
`FcLangSet`, a bitmap over the orthographies in `fc-lang/*.orth`
([`fc-lang/fc-lang.py`][fclang-py]), derived by `FcLangSetFromCharSet` — a
language is supported when its orthography minus the font's charset is empty
([`src/fclang.c`][fclang]). **Classification**: weight on a 0–215 scale
(`FC_WEIGHT_THIN`=0, `REGULAR`=80, `BOLD`=200, `EXTRABLACK`=215) mapped
piecewise-linearly from OpenType 0–1000 by a 13-row table in
[`src/fcweight.c`][fcweight]; width on the OpenType percentage scale; slant
`ROMAN`=0/`ITALIC`=100/`OBLIQUE`=110 ([`fontconfig.h.in`][hdr]). Generic family
is config data, not table data — no PANOSE. **CLI mapping**: `fc-list` is
`FcFontList`; `fc-match` is `FcFontMatch`, `-s` is `FcFontSort(trim=true)`, `-a`
is `FcFontSort(trim=false)`, each through `FcFontRenderPrepare`; `fc-query` is
`FcFreeTypeQueryAll` ([`fc-list.c`][fclist-c], [`fc-match.c`][fcmatch-c],
[`fc-query.c`][fcquery-c]).

## What it teaches `sparkles:font`

- **Make the fallback _list_ the primary API and the best match a view of it.**
  `FcFontSort` with `trim` plus the coverage union `csp` is what a terminal
  needs: one ordered chain per style, pruned to fonts that add coverage.
- **Score lexicographically over a declared priority table, coverage above
  family.** A D `enum MatchPriority` with one comparator per property is a
  direct, testable transcription; strong/weak bindings let user aliases outrank
  locale without a second mechanism.
- **Describe a face as data and cache it position-independently** — low-bit
  offsets, a constant-refcount sentinel for mapped objects, mtime-validated
  per-directory files — so `hue` and the terminal share one discovery cache.
- **Variation as ranges on ordinary properties** keeps matching axis-agnostic
  but loses custom axes and `avar`; expose standard axes as ranges _and_ keep raw
  `fvar` for the inspector.
- **Spacing classification (`MONO`/`DUAL`/`CHARCELL`) from measured advances
  at scan time** is exactly what a terminal must know before choosing a face.

## Strengths

- One data model (`FcPattern`) for fonts, requests, results and config rules;
  the vocabulary extends without ABI change.
- Scoring order is explicit in source and user-tunable through binding strength;
  `FC_DEBUG` prints the full score vector per candidate.
- `FcFontSort` + `trim` + coverage union is a complete per-codepoint fallback
  with no glyph loading at match time.
- Weight and width round-trip losslessly to OpenType
  (`FcWeightFromOpenTypeDouble`/`ToOpenTypeDouble`).

## Weaknesses

- The 0–215 weight scale predates OpenType's; non-standard axes never reach
  matching, and `FcFontRenderPrepare` emits variations as a string.
- Matching is O(fonts × properties × values) per request with no index; Pango
  and Qt cache sorted sets themselves.
- Charset-based language inference misclassifies accidental coverage, and the
  `FC_LANG` second pass is a heuristic, not a stated contract.
- No metrics, no classification beyond weight/width/slant/spacing, and the XML
  configuration is a second, imperative language that can override any score.

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                             | Trade-off                                                                           |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Fonts and requests are the same type (`FcPattern`)                    | One matcher, one serialiser, one config language                                      | Weak typing: every property is a runtime lookup with an `FcResult`                  |
| Lexicographic priority vector, charset before family                  | Coverage failures are the worst outcome; a renamed font is not                        | A single missing codepoint can override an explicit family request                  |
| Strong/weak value bindings                                            | Lets config aliases outrank locale preference without a second rule engine            | Two slots (`FAMILY_STRONG`, `FAMILY_WEAK`) for one property; subtle to reason about |
| `FcFontSort` returns a trimmed, ordered set plus coverage union       | Fallback computed once per style, no glyph loading at match time                      | O(n) over all fonts per request; callers must cache                                 |
| Variable axes as `FcRange` on `weight`/`width`/`size`                 | Matching stays axis-agnostic; instances compete as ordinary patterns                  | Custom axes and `avar` invisible; chosen coordinates leave as a string              |
| Offset-encoded, mmap-shared per-directory caches                      | Thousands of fonts enumerated without parsing; shared across processes                | Cache-resident patterns are immutable; format version bumps invalidate every cache  |
| Refcounts with a "constant" sentinel                                  | Mapped objects need no counting; heap ones share safely                               | Mutating a returned pattern is undefined; the API trusts the caller                 |
| Render policy (`hinting`, `rgba`, `embolden`, `matrix`) is match data | The database knows which face was substituted and can tell the renderer to compensate | Fontconfig decides rendering options it never executes; renderers may ignore them   |
| Thread-safety retrofitted (2.11) around immutable published objects   | Safe concurrent matching on one `FcConfig`                                            | Concurrent mutation of a pattern or set is still the caller's problem               |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Public API** — [`fontconfig/fontconfig.h.in`][hdr],
  [`fontconfig/fcfreetype.h`][fcfth].
- **Matcher** — [`src/fcmatch.c`][fcmatch] (`FcMatcherPriority`, `_FcMatchers`,
  `FcCompareValueList`, `FcCompareRange`, `FcFontRenderPrepare`,
  `FcFontSetSort`, `FcSortWalk`), [`src/fcobjs.h`][fcobjs].
- **Data model** — [`src/fcint.h`][fcint], [`src/fcpat.c`][fcpat],
  [`src/fcfs.c`][fcfs], [`src/fccharset.c`][fccharset], [`src/fclang.c`][fclang],
  [`src/fcweight.c`][fcweight], [`src/fcmutex.h`][fcmutex].
- **Scanning and caching** — [`src/fcfreetype.c`][fcft],
  [`src/fcfontations.c`][fcfont], [`src/fccache.c`][fccache],
  [`src/fcdefault.c`][fcdefault], [`fc-lang/fc-lang.py`][fclang-py].
- **CLI** — [`fc-list/fc-list.c`][fclist-c], [`fc-match/fc-match.c`][fcmatch-c],
  [`fc-query/fc-query.c`][fcquery-c].
- **Documentation** — [`doc/fontconfig-user.sgml`][user],
[`doc/fontconfig-devel.sgml`][devel], [`doc/fcconfig.fncs`][fncs-config],
[`doc/fcfontset.fncs`][fncs-fontset].
<!-- References -->

[repo]: https://gitlab.freedesktop.org/fontconfig/fontconfig
[copying]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/COPYING
[hdr]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/fontconfig/fontconfig.h.in
[fcfth]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/fontconfig/fcfreetype.h
[fcmatch]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fcmatch.c
[fcobjs]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fcobjs.h
[fcint]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fcint.h
[fcpat]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fcpat.c
[fcfs]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fcfs.c
[fccharset]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fccharset.c
[fclang]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fclang.c
[fcweight]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fcweight.c
[fcmutex]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fcmutex.h
[fcft]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fcfreetype.c
[fcfont]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fcfontations.c
[fccache]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fccache.c
[fcdefault]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/src/fcdefault.c
[fclang-py]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/fc-lang/fc-lang.py
[fclist-c]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/fc-list/fc-list.c
[fcmatch-c]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/fc-match/fc-match.c
[fcquery-c]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/fc-query/fc-query.c
[user]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/doc/fontconfig-user.sgml
[devel]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/doc/fontconfig-devel.sgml
[fncs-config]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/doc/fcconfig.fncs
[fncs-fontset]: https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/d416ada7b20a1cdd5050b60a7a1bbdb3d9ddd2dc/doc/fcfontset.fncs
