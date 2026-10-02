# lib-font (JavaScript)

A query-only OpenType reader built for _inspecting_ fonts in the page that
uses them: an `Image`-like `Font` element that loads a URL, registers an
`@font-face`, and then exposes each table as a lazily parsed object with
enumeration methods over GSUB/GPOS scripts, language systems, features and
lookups — and deliberately nothing that draws or shapes.

| Field            | Value                                                                       |
| ---------------- | --------------------------------------------------------------------------- |
| Language         | JavaScript (ES modules; optional `inflate.js`/`unbrotli.js` or Node `zlib`) |
| License          | MIT ([`LICENSE`][license])                                                  |
| Repository       | [Pomax/lib-font][repo]                                                      |
| Documentation    | [`README.md`][readme] (API section self-described as pending)               |
| Category         | parser                                                                      |
| Layer(s) covered | parse                                                                       |
| Version at pin   | 3.0.4 ([`package.json`][pkg])                                               |
| Pinned revision  | `ab532bf9b87572a25805ca7b87bb36119cfa2ccf` (2026-07-25)                     |

## Overview

### What it solves

lib-font answers questions _about_ a font — which scripts and language systems
GSUB covers, which features each language system enables, which lookups a
feature runs, whether a character or variation sequence is mapped, which axes
`fvar` declares — without a rendering or shaping engine. The README's
introduction asks _"What if you could actually inspect your fonts? In the
same context that you actually use those fonts?"_ and walks exactly that
script → langsys → features → axes sequence ([`README.md`][readme]).

### Design philosophy

Shaping and drawing are explicit non-goals, argued in the README's FAQ:

> Proper OpenType text shaping is _incredibly complex_ and requires _a lot_ of
> specialized code; there is no reason for this library to pretend it supports
> text shaping when it's guaranteed to do it worse than other technologies
> you're already using.

and, comparing itself to opentype.js and fontkit:

> The reason _I_ needed this is because it doesn't do text shaping: it just
> lets me query the opentype data to get me the information I need, without
> being too big of a library.

— [`README.md`][readme] (§ "Why can't this draw stuff??", § "Why would I use
this instead of OpenType.js or Fontkit or something?")

## How it works

**An element-shaped loader.** `new Font(name, options)` extends an
`EventManager`; assigning `font.src` (URL, blob or data URL) first injects an
`@font-face` rule for `name` (unless `skipStyleSheet`) so the browser can render
the font, then `fetch`es the bytes ([`lib-font.js`][libfont]). `fromDataBuffer
(buffer, filename)` is the bytes entry point. `validFontFormat` sniffs four
lead bytes into `SFNT`, `WOFF` or `WOFF2` ([`src/utils/validator.js`][validator])
and the matching container class is built; completion is a `load` event, not
a return value.

**A table factory over dynamic imports.** [`createTable.js`][createtable]
`import()`s 41 table classes, maps class name to constructor, and builds a
table on demand from `{ tag, offset, length }` and the shared `DataView`. A tag
with no class logs _"lib-font has no definition for … The table was skipped."_
and yields `{}`.

**Laziness by property.** [`src/lazy.js`][lazy] defines a property whose getter
runs once and memoises:

```js
/**
 * This is a lazy loader but is not optimised for direct record selection,
 * so code will currently load "An entire array" even if it needs only
 * a single element from that array, and the array elements are fixed width.
 */
export default function lazy(object, property, getter) {
  let val;
  Object.defineProperty(object, property, {
    get: () => {
      if (val) return val;
      val = getter();
```

`SFNT` reads the directory and calls `lazy(this.tables, tag, …)` per entry
([`src/opentype/sfnt.js`][sfnt]); inside tables, `CommonLayoutTable` makes
`scriptList`, `featureList`, `lookupList` and `featureVariations` lazy
([`common-layout-table.js`][clt]), and `fvar` makes `axes` and `instances`
lazy ([`fvar.js`][fvar]).

## Analysis spine

### 1. Layering and ownership

One layer: a parser over a borrowed `DataView`. `Font` owns the `DataView` and
`font.opentype` (the `SFNT`/`WOFF`/`WOFF2` container); tables are created on
first property access and cached on `opentype.tables`. Sub-records are built
by repositioning a shared `Parser` cursor (`this.parser.currentPosition =
…`), so — as in [`./fontkit.md`](./fontkit.md) — a table object is not
re-entrant. Errors surface as `error` events from loading and as thrown
exceptions (or a `{}` table) from access.

### 2. Face loading and table access

URL or bytes; single SFNT, WOFF (needs `globalThis.pako` or Node `zlib`) or
WOFF2 (needs `globalThis.unbrotli` or `zlib.brotliDecompressSync`, with the
`glyf`/`loca` transform-version rule implemented,
[`src/opentype/woff2.js`][woff2]). No collections. Every table is raw and
lazy: `font.opentype.tables.cmap`, `.GSUB`, `.fvar`, `['OS/2']`. Coverage is
**uneven by registry, not by file**: the repository contains `avar`, `cvar`,
`gvar`, `HVAR`, `MVAR`, `STAT` and `VVAR` modules under
`src/opentype/tables/simple/variation/`, and `MATH`/`JSTF` under
`advanced/`, but `createTable.js` imports only `fvar` from the variation
directory and neither `MATH` nor `JSTF`, so all of these read as `{}`. `STAT` would be empty
anyway — its class body reads the header parser and stops
([`STAT.js`][stat]). `glyf` is _"not really a table, but a pure data block"_
exposing `getGlyphData(offset, length)` bytes ([`glyf.js`][glyf]).

### 3. Shaping

Not applicable by design (quoted above). What lib-font offers instead is the
**enumeration surface an inspector needs**, on both GSUB and GPOS via
`CommonLayoutTable` ([`common-layout-table.js`][clt]):

```js
getSupportedScripts() {
  return this.scriptList.scriptRecords.map((r) => r.scriptTag);
}
```

followed by `getScriptTable(tag)`, `getSupportedLangSys(script)` (prepending
`dflt` when a default exists), `getDefaultLangSysTable`, `getLangSysTable(script,
tag)`, `getFeatures(langSys)`, `getFeature(indexOrTag)`, `getLookups(feature)`
and `getLookup(index)`. `LookupTable.getSubTable(i)` builds the typed subtable
(GSUB 1–8, GPOS 1–9). It unwraps `lookupType === 7` for both tables —
correct for the GSUB extension, wrong for GPOS, where 7 is contextual
positioning (whose class has no `getSubstTable`) and the extension is type 9,
left wrapped, and e.g. GSUB type 4 offers
`getLigatureSet(i).getLigature(j)` ([`lookup.js`][lookup],
[`lookup-type-4.js`][lt4]). An inspector-grade defect: the `LookupTable` flag
getters are written `this.lookupFlag & (0x0002 === 0x0002)`, which evaluates
to `lookupFlag & 1`, so `ignoreBaseGlyphs`, `ignoreLigatures`, `ignoreMarks`
and the rest all report bit 0 (`rightToLeft`) ([`lookup.js`][lookup]).

### 4. Variation and instances

`fvar` only: `getSupportedAxes()` (tags), `getAxis(tag)` (`minValue`,
`defaultValue`, `maxValue` as 16.16 decoded, `flags`, `axisNameID`), and
`instances` (`subfamilyNameID`, `coordinates[]`, optional `postScriptNameID`
when `instanceSize` allows) ([`fvar.js`][fvar]). Names resolve through
`name.get(id)`. No normalisation, no `avar`, no instancing; `STAT`
unavailable (§2). `featureVariations` is declared as a lazy property on
GSUB/GPOS, but its getter names a `FeatureVariations` class that is never
imported — the source flags it, _"FIXME: This class doesn't actually exist
anywhere in the code..."_ — so touching it on a font that has the offset
throws ([`common-layout-table.js`][clt]).

### 5. Rasterization and outlines

Not applicable: no outline decoding, no path, no raster. Drawing is delegated
to the browser through the injected `@font-face` (§ How it works). Colour
tables `COLR` (v0 `getBaseGlyphRecord`, `getLayers`), `CPAL`, `CBDT`/`CBLC`,
`EBDT`/`EBLC`, `sbix` and `SVG ` are parsed as data for inspection only.

### 6. Metrics and measurement

Raw tables only (`head`, `hhea`, `hmtx`, `OS/2`, `post`, `vhea`, `vmtx`,
`VDMX`, `hdmx`). The one derived measurement, `measureText(text, size)`,
renders a hidden DOM `div` in the registered face and returns
`getBoundingClientRect()` augmented with **`OS/2` `sTypoAscender`/
`sTypoDescender`** ([`lib-font.js`][libfont]) — measurement by the browser,
metrics by table.

### 7. Discovery, matching and fallback

Not applicable. Coverage queries are per face: `font.supports(char)`,
`getGlyphId(char)`, `reverse(glyphId)`, `supportsVariation(seq)` (cmap format
14), and on the table `cmap.getSupportedEncodings()` and
`getSupportedCharCodes(platformID, encodingID)` ([`cmap.js`][cmap]).

## What it teaches `sparkles:font`

- **The inspector API is an enumeration ladder**: scripts → language systems
  (with `dflt` surfaced) → features → lookups → typed subtables. `sparkles:font`
  should expose exactly these as ranges over borrowed offsets, independent of
  the shaper.
- **Tables-as-lazy-properties over one borrowed buffer** is the right cost
  model for a font explorer that opens hundreds of files and reads a few
  tables from each.
- **Registry coverage must be tested, not assumed.** Nine table modules
  (seven variation tables, `MATH`, `JSTF`) exist as source yet are
  unreachable; a D `static foreach` over a tag →
  type table plus a test that every module is registered prevents this.
- **Bit-flag accessors need tests against real fonts** — the `lookupFlag`
  precedence bug shows how inspector output can be silently wrong.
- **Separating "inspect" from "render" is legitimate**: the explorer's
  table views can rest on the parser alone while glyph views use the shaping
  and raster layers.

## Strengths

- Small, query-shaped API that matches what inspectors display.
- Lazy at table and sub-list granularity; cheap opens.
- WOFF/WOFF2 with pluggable decompressors; registered classes cover the
  bitmap (`CBDT`, `EBDT`, `sbix`) and colour (`COLR`, `CPAL`, `SVG `) tables.
- Character, encoding and variation-selector coverage queries.

## Weaknesses

- No outlines, metrics derivation, normalisation or shaping (by design).
- Variation support stops at `fvar`; `STAT` and `avar` unreachable.
- Event-based loading API, no TTC support, README API docs pending.
- Shared parser cursor; `lookupFlag` getters and GPOS extension unwrapping
  incorrect at the pin.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                              | Trade-off                                            |
| ----------------------------------------------- | ------------------------------------------------------ | ---------------------------------------------------- |
| Query-only, no shaping or drawing               | The browser already shapes and renders correctly       | Useless outside a host renderer; no glyph geometry   |
| `Font` modelled on `Image` (`src` + `onload`)   | Familiar web idiom; also registers `@font-face`        | Asynchronous by construction; awkward in tools       |
| Lazy property per table and per list            | Inspectors read few tables from many fonts             | Whole arrays decoded on first touch (`lazy.js` note) |
| Factory over dynamically imported table classes | Classes load in parallel; unknown tags degrade to `{}` | Unregistered modules are silently dead code          |
| Pluggable inflate/brotli via globals or `zlib`  | Keeps the core small                                   | WOFF/WOFF2 failure depends on page setup             |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Entry point** — [`lib-font.js`][libfont], [`src/utils/validator.js`][validator],
  [`src/lazy.js`][lazy].
- **Containers** — [`src/opentype/sfnt.js`][sfnt], [`src/opentype/woff2.js`][woff2],
  [`src/opentype/tables/createTable.js`][createtable].
- **Layout tables** — [`src/opentype/tables/common-layout-table.js`][clt],
  [`src/opentype/tables/advanced/shared/lookup.js`][lookup],
  [`src/opentype/tables/advanced/lookups/gsub/lookup-type-4.js`][lt4].
- **Simple tables** — [`cmap.js`][cmap], [`name.js`][name], [`fvar.js`][fvar],
  [`STAT.js`][stat], [`glyf.js`][glyf].
- **Docs** — [`README.md`][readme], [`package.json`][pkg], [`LICENSE`][license].

<!-- References -->

[repo]: https://github.com/Pomax/lib-font
[readme]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/README.md
[license]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/LICENSE
[pkg]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/package.json
[libfont]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/lib-font.js
[validator]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/utils/validator.js
[lazy]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/lazy.js
[sfnt]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/sfnt.js
[woff2]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/woff2.js
[createtable]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/tables/createTable.js
[clt]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/tables/common-layout-table.js
[lookup]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/tables/advanced/shared/lookup.js
[lt4]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/tables/advanced/lookups/gsub/lookup-type-4.js
[cmap]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/tables/simple/cmap.js
[name]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/tables/simple/name.js
[fvar]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/tables/simple/variation/fvar.js
[stat]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/tables/simple/variation/STAT.js
[glyf]: https://github.com/Pomax/lib-font/blob/ab532bf9b87572a25805ca7b87bb36119cfa2ccf/src/opentype/tables/simple/ttf/glyf.js
