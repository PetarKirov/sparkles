# fontkit (JavaScript)

PDFKit's font engine: format-sniffing loaders over declarative `restructure`
table schemas, tables decoded lazily on first property access and memoised by
a decorator, and a genuine (if HarfBuzz-derived and frozen) OpenType/AAT
shaping engine with Arabic, Hangul, Indic and Universal shapers — the most
complete pure-JavaScript stack from bytes to positioned glyphs and paths.

| Field            | Value                                                                                                             |
| ---------------- | ----------------------------------------------------------------------------------------------------------------- |
| Language         | JavaScript (ES modules with decorators; depends on `restructure`, `brotli`, `tiny-inflate`, `unicode-properties`) |
| License          | MIT ([`package.json`][pkg] `"license"`, [`README.md`][readme] § License)                                          |
| Repository       | [foliojs/fontkit][repo]                                                                                           |
| Documentation    | [`README.md`][readme] (the API reference)                                                                         |
| Category         | parser                                                                                                            |
| Layer(s) covered | parse · shape · outline · layout (single run) · subset                                                            |
| Version at pin   | 2.0.4 ([`package.json`][pkg])                                                                                     |
| Pinned revision  | `eaeb7e997b46cb61b41402108bf2c13928455779` (2026-09-29)                                                           |

## Overview

### What it solves

fontkit opens TTF, OTF, WOFF, WOFF2, TTC and dfont files, maps characters to
glyphs, shapes a string into a `GlyphRun` of glyphs and positions using GSUB/
GPOS or AAT `morx`, exposes glyph paths and colour glyphs, applies variations,
and subsets for PDF embedding. Its README is the API reference
([`README.md`][readme]).

### Design philosophy

Two idioms carry the whole library. Tables are **schemas as data**, declared
with `restructure` combinators rather than hand-written readers:

```js
// horizontal header
export default new r.Struct({
  version:              r.int32,
  ascent:               r.int16,   // Distance from baseline of highest ascender
  descent:              r.int16,   // Distance from baseline of lowest descender
  lineGap:              r.int16,   // Typographic line gap
  advanceWidthMax:      r.uint16,  // Maximum advance width value in 'hmtx' table
```

— [`src/tables/hhea.js`][hhea]

And derived values are **computed once on first access**, by a decorator that
replaces a getter with a data property:

```js
/**
 * This decorator caches the results of a getter or method such that
 * the results are lazily computed once, and then cached.
 * @private
 */
export function cache(target, key, descriptor) {
  if (descriptor.get) {
    let get = descriptor.get;
    descriptor.get = function() {
      let value = get.call(this);
      Object.defineProperty(this, key, { value });
      return value;
    };
```

— [`src/decorators.js`][decorators]

## How it works

**Format registry and sniffing.** [`src/index.js`][index] registers
`TTFFont`, `WOFFFont`, `WOFF2Font`, `TrueTypeCollection` and `DFont`;
`create(buffer, postscriptName)` asks each class's static `probe(buffer)` in
turn, wraps the buffer in a `restructure` `DecodeStream`, and — for a
collection — returns `getFont(postscriptName)` ([`src/base.js`][base]).
`openSync`/`open` just read the file first ([`src/fs.js`][fs]).
`TTFFont.probe` accepts `true`, `OTTO` and `0x00010000`
([`src/TTFFont.js`][ttf]). `WOFF2Font._decompress` sizes the output from the
directory's `transformLength`s and runs the `brotli` decoder once over the
whole compressed block ([`src/WOFF2Font.js`][woff2]).

**Lazy tables.** The `TTFFont` constructor decodes only the table directory,
then defines one getter per present tag — `Object.defineProperty(this, tag, {
get: this._getTable.bind(this, table) })` — so `font.hhea`, `font['OS/2']`,
`font.GSUB` decode on first touch into `this._tables` via the `restructure`
schema in `src/tables/` (49 modules, including shared `opentype.js`, `aat.js` and `variations.js` sub-schemas). A decode failure is swallowed
(logged only if `fontkit.logErrors`) and the property reads `undefined`
([`src/TTFFont.js`][ttf]).

**Glyph objects.** `getGlyph(id, codePoints)` picks the class by table
presence — `SBIXGlyph` if `sbix`, `COLRGlyph` if `COLR`+`CPAL`, else
`TTFGlyph` (`glyf`) or `CFFGlyph` (`CFF `/`CFF2`) — and memoises it in
`this._glyphs`. Each glyph's `path`, `cbox`, `bbox`, `advanceWidth`,
`advanceHeight` and `name` are `@cache` getters ([`src/glyph/Glyph.js`][glyph]).

**Layout.** `font.layout(string, features, script, language, direction)`
delegates to a cached `LayoutEngine`, which picks `AATLayoutEngine` when the
font has `morx` and `OTLayoutEngine` when it has GSUB or GPOS
([`src/layout/LayoutEngine.js`][le]).

## Analysis spine

### 1. Layering and ownership

`TTFFont` is the face; there is no scaled-font object (size is an argument to
`getScaledPath`/`render`). `LayoutEngine` → `OTLayoutEngine` → `ShapingPlan` +
`GSUBProcessor`/`GPOSProcessor` is the shaper; `Glyph` subclasses own outlines;
`GlyphRun` is the output value. All bytes stay in the caller's buffer behind
one `DecodeStream`; tables and glyphs are memoised on the font. That single
stream has a **mutable cursor** (`this.stream.pos = table.offset`) shared by
every lazy decode, so a font object is not re-entrant — harmless on
JavaScript's one thread, disqualifying as a model for D. Errors are thrown,
except table decode errors, which degrade to `undefined`.

### 2. Face loading and table access

From bytes (`create`) or path (`open`/`openSync`); collections by PostScript
name (`collection.getFont(name)`) or `collection.fonts`. Every table is lazy
and exposed raw as a property named by its tag, already decoded into the
schema's field names — `font['OS/2'].capHeight`, `font.head.macStyle.bold`.
Bytes of a table are reachable via `_getTableStream(tag)` (private). Tags
without a schema are invisible.

### 3. Shaping

A real engine. `OTLayoutEngine.setup` builds a `ShapingPlan`; the shaper is
chosen per script tag from a table in
[`src/opentype/shapers/index.js`][shapers]: `ArabicShaper` (arab, mong, syrc,
nko, phag, mand, mani, phlp), `HangulShaper`, `IndicShaper` (the Indic
two-generation tags plus khmr), `UniversalShaper` (USE scripts), else
`DefaultShaper`. The complex shapers are ports — `IndicShaper` says _"Based on code from Harfbuzz"_ ([`IndicShaper.js`][indic]). Sizes: `IndicShaper.js` 911 lines, `HangulShaper.js` 285,
`UniversalShaper.js` 185, `ArabicShaper.js` 123, `DefaultShaper.js` 72, with
generated state machines from `indic.machine`/`use.machine`
([`src/opentype/shapers/`][shapers]). `DefaultShaper` enables `rvrn`, the
direction pair (`ltra`/`ltrm` or `rtla`/`rtlm`), `ccmp`, `locl`, `rlig`,
`mark`, `mkmk`, `calt`, `clig`, `liga`, `rclt`, `curs`, `kern`, plus contextual
`frac`/`numr`/`dnom` around U+2044 ([`DefaultShaper.js`][defshaper]). User
features are an array (added) or `{ tag: bool }` map (toggled); script is
auto-detected from code points when omitted (`Script.forString`). Without
GSUB/GPOS, `UnicodeLayoutEngine` positions marks by Unicode class and
`KernProcessor` applies `kern`. Output `GlyphRun` holds `glyphs` and
`positions` (`GlyphPosition` `xAdvance`, `yAdvance`, `xOffset`, `yOffset`) in
**font units**. Cluster mapping is per-glyph `codePoints` (a ligature lists all
its code points), not string indices ([`README.md`][readme]).
`stringsForGlyph(gid)` reverses the mapping — cmap code points, plus AAT
`morx` paths — and `availableFeatures`/`getAvailableFeatures(script, lang)`
list GSUB+GPOS feature tags.

### 4. Variation and instances

`variationAxes` returns `{ tag: { name, min, default, max } }` and
`namedVariations` returns `{ instanceName: { tag: value } }`, both `@cache`
getters over `fvar` ([`src/TTFFont.js`][ttf]). `getVariation(settings |
name)` clamps **user-space** values to axis ranges and returns a **new
`TTFFont`** over the same buffer that **shares the parent's `_tables`** but
has its own glyph cache. Its `_variationProcessor`
(`GlyphVariationProcessor`) normalises to −1..+1 and remaps through `avar`
segments ([`src/glyph/GlyphVariationProcessor.js`][gvp]); coordinates then
reach **outlines** (`gvar` point deltas in `TTFGlyph`, CFF2 blend), **advances**
(`HVAR`), **GPOS** (`GDEF` item-variation-store deltas on value records and
anchors, [`src/opentype/GPOSProcessor.js`][gpos]) and **GSUB feature
substitution** (`FeatureVariations` via `findVariationsIndex`,
[`src/opentype/OTProcessor.js`][otproc]). `STAT` has no schema;
`getVariation` rejects fonts lacking `gvar`+`glyf` or `CFF2`.

### 5. Rasterization and outlines

No rasterizer. `glyph.path` is a `Path` whose `commands` are `{ command:
'moveTo'|'lineTo'|'quadraticCurveTo'|'bezierCurveTo'|'closePath', args }` in
**font units, y-up** — the names are the Canvas 2D method names, so
`toFunction()` replays them onto a context, and `toSVG()` maps them to
`M L Q C Z` ([`src/glyph/Path.js`][path]). `Path` also offers `bbox` (tight,
curve extrema), `cbox` (control points), `transform`, `translate`, `rotate`,
`scale`, `mapPoints`. `getScaledPath(size)` scales by `size / unitsPerEm`;
`render(ctx, size)` scales the context. Colour: `COLRGlyph.layers` (COLRv0
`{ glyph, color }` from CPAL); `SBIXGlyph.getImageForSize(size)` returns the
first strike with `ppem >= size` as an encoded image. No CBDT, SVG or COLRv1;
no hinting.

### 6. Metrics and measurement

`ascent`, `descent`, `lineGap` come from **`hhea`**; `capHeight` and
`xHeight` from OS/2 (falling back to `ascent` and 0);
`underlinePosition`/`Thickness` and `italicAngle` from `post`; `bbox` from
`head`; `unitsPerEm`, `numGlyphs` ([`src/TTFFont.js`][ttf]). OS/2 typo/win
values need `font['OS/2']` directly. Per glyph: `advanceWidth` from `hmtx`
plus the `HVAR` adjustment, `advanceHeight`, and `cbox`/`bbox` as above
([`src/glyph/Glyph.js`][glyph]).

### 7. Discovery, matching and fallback

Not applicable beyond one file. `characterSet` (all mapped code points) and
`hasGlyphForCodePoint` give per-face coverage — the inputs a fallback chain
needs — but there is no enumeration, matching or fallback.

## What it teaches `sparkles:font`

- **Declare table layouts as data, generate the readers.** `restructure`'s
  `r.Struct` is a runtime version of what D does at compile time: a struct of
  `BigEndian!T` fields plus a `static foreach` decoder, with offsets resolved
  lazily.
- **Lazy-by-tag table access with memoisation** is right; fontkit's shared
  mutable cursor is wrong. Give every lazy read its own slice of the borrowed
  buffer.
- **A variation instance as a cheap derived face sharing parsed tables** is
  the right ownership shape for an explorer scrubbing an axis.
- **Variation must reach GSUB `FeatureVariations` and GPOS deltas as well as
  outlines and `HVAR`** — fontkit is the reference for that complete wiring in
  a small codebase.
- **Expose `availableFeatures` per script/language and a reverse
  glyph-to-strings map** — both are inspector staples.

## Strengths

- Broadest format coverage of the JS parsers (WOFF2, TTC, dfont, AAT `morx`).
- Real complex-script shaping with per-script shapers and default feature
  sets.
- Variation reaches outlines, advances, GSUB and GPOS.
- Declarative schemas keep table code small and uniform.

## Weaknesses

- Shared stream cursor makes font objects non-re-entrant.
- Table decode errors silently become `undefined`.
- No `STAT`, no COLRv1, no CBDT/SVG colour, no hinting.
- Positions in font units with code-point clusters only; no string indices.
- Subsets lack `cmap` and are not standalone fonts ([`README.md`][readme]).

## Key design decisions and trade-offs

| Decision                                         | Rationale                                         | Trade-off                                              |
| ------------------------------------------------ | ------------------------------------------------- | ------------------------------------------------------ |
| `restructure` schemas per table                  | Table code is declarative, compact, reusable      | Runtime interpretation; every field decoded on access  |
| Per-tag lazy getters + `@cache`                  | Open cost is the directory only                   | First access cost hidden in a property read            |
| One `DecodeStream` with a movable cursor         | No copies of the buffer                           | Not re-entrant; nested decodes must save/restore `pos` |
| `getVariation` returns a new font sharing tables | Instances are cheap; parsed tables reused         | Glyph caches are per instance                          |
| Glyph class chosen by table presence             | One `getGlyph` call for every outline/colour kind | A font with `sbix` returns bitmap glyphs for every id  |
| Ported HarfBuzz-style shapers                    | Complex scripts work without native code          | Frozen behaviour; fixes upstream do not flow in        |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Loading** — [`src/index.js`][index], [`src/base.js`][base],
  [`src/fs.js`][fs], [`src/TTFFont.js`][ttf], [`src/WOFF2Font.js`][woff2],
  [`src/TrueTypeCollection.js`][ttc], [`src/decorators.js`][decorators].
- **Tables** — [`src/tables/hhea.js`][hhea], [`src/tables/head.js`][head].
- **Layout** — [`src/layout/LayoutEngine.js`][le],
  [`src/layout/GlyphRun.js`][run], [`src/opentype/OTProcessor.js`][otproc],
  [`src/opentype/GPOSProcessor.js`][gpos], [`src/opentype/shapers/index.js`][shapers],
  [`src/opentype/shapers/DefaultShaper.js`][defshaper].
- **Glyphs** — [`src/glyph/Glyph.js`][glyph], [`src/glyph/Path.js`][path],
  [`src/glyph/GlyphVariationProcessor.js`][gvp],
  [`src/glyph/SBIXGlyph.js`][sbix], [`src/glyph/COLRGlyph.js`][colr].
- **Docs** — [`README.md`][readme], [`package.json`][pkg].

<!-- References -->

[repo]: https://github.com/foliojs/fontkit
[readme]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/README.md
[pkg]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/package.json
[index]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/index.js
[base]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/base.js
[fs]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/fs.js
[ttf]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/TTFFont.js
[woff2]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/WOFF2Font.js
[ttc]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/TrueTypeCollection.js
[decorators]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/decorators.js
[hhea]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/tables/hhea.js
[head]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/tables/head.js
[le]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/layout/LayoutEngine.js
[run]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/layout/GlyphRun.js
[otproc]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/opentype/OTProcessor.js
[gpos]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/opentype/GPOSProcessor.js
[shapers]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/opentype/shapers/index.js
[defshaper]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/opentype/shapers/DefaultShaper.js
[glyph]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/glyph/Glyph.js
[path]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/glyph/Path.js
[gvp]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/glyph/GlyphVariationProcessor.js
[sbix]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/glyph/SBIXGlyph.js
[colr]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/glyph/COLRGlyph.js
[indic]: https://github.com/foliojs/fontkit/blob/eaeb7e997b46cb61b41402108bf2c13928455779/src/opentype/shapers/IndicShaper.js
