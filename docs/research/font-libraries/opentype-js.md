# opentype.js (JavaScript)

A parse-everything-into-plain-objects OpenType reader and writer for the
browser and Node.js: every table becomes a mutable JavaScript object hung off
`font.tables`, every glyph outline becomes a `Path` whose `commands` array _is_
the outline, and the "shaper" is a handful of hand-wired GSUB features plus
pair kerning — a model that makes inspection trivial and correct text layout
out of reach.

| Field            | Value                                                                                                               |
| ---------------- | ------------------------------------------------------------------------------------------------------------------- |
| Language         | JavaScript (ES modules, `.mjs`)                                                                                     |
| License          | MIT ([`LICENSE`][license])                                                                                          |
| Repository       | [opentypejs/opentype.js][repo]                                                                                      |
| Documentation    | [`README.md`][readme], JSDoc in source; in-repo [`docs/font-inspector.html`][fi], [`docs/glyph-inspector.html`][gi] |
| Category         | parser                                                                                                              |
| Layer(s) covered | parse · outline · shape (minimal) · layout (single line)                                                            |
| Pinned revision  | `5d65b6dcfab5115f90d375f8ba6b7942fdaa0138` (2026-05-19)                                                             |

## Overview

### What it solves

opentype.js turns a font file's bytes into a `Font` object a script can read,
draw and re-serialise. The README scopes it as letterform access — _"It gives
you access to the **letterforms** of text from the browser or Node.js"_ — and
lists bézier paths from text, composite glyphs, WOFF/OTF/TTF with `glyf` and
`cff` outlines, kerning, ligatures, TrueType hinting, Arabic, and COLR/CPAL and
SVG colour glyphs ([`README.md`][readme]). It is also a font _writer_:
`Font.prototype.toArrayBuffer` compiles the object graph back to bytes
([`src/font.mjs`][font]).

### Design philosophy

Tables are data, not views. `parseBuffer` walks the table directory and
decodes each known tag into an object stored on `font.tables`, so the
repository's own font inspector is nothing more than a reflective loop over
that object:

```js
for (tablename in font.tables) {
    table = font.tables[tablename];
    if (tablename == 'name') {
        displayNames(table);
        continue;
    }

    html = '';
    for (property in table) {
        value = table[property];
```

— [`docs/font-inspector.html`][fi]

Positioning, by contrast, is admitted to be partial in the code that does it:

```js
// We should apply position adjustment lookups in a more generic way.
// Here we only use the xAdvance value.
const kerningValue = kerningLookups
  ? this.position.getKerningValue(
      kerningLookups,
      glyph.index,
      glyphs[i + 1].index,
    )
  : this.getKerningValue(glyph, glyphs[i + 1]);
```

— [`src/font.mjs`][font] (`forEachGlyph`)

## How it works

`opentype.parse(buffer, opt)` is `parseBuffer` in
[`src/opentype.mjs`][otjs]. It sniffs the first four bytes: `0x00010000`,
`true` or `typ1` set `font.outlinesFormat = 'truetype'`, `OTTO` sets `'cff'`,
`wOFF` reads WOFF entries and inflates with the vendored `tiny-inflate`, and
`wOF2` throws (_"WOFF2 require an external decompressor library"_). There is
no `ttcf` branch, so collections are refused. A `switch` over the directory
then parses each recognised table — 28 modules in `src/tables/` (`avar`,
`cff`, `cmap`, `colr`, `cpal`, `cvar`, `fvar`, `gasp`, `gdef`, `glyf`, `gpos`,
`gsub`, `gvar`, `head`, `hhea`, `hmtx`, `hvar`, `kern`, `loca`, `ltag`, `maxp`,
`meta`, `name`, `os2`, `post`, `sfnt`, `stat`, `svg`) — and copies headline
values onto the font (`unitsPerEm` from `head`, `ascender`/`descender` from
`hhea`, `numGlyphs` from `maxp`, `names` from `name`).

Glyphs are the one lazy part. `GlyphSet` holds loader thunks;
`ttfGlyphLoader` builds a `Glyph` whose `path` is a function that parses the
`glyf` record and builds the `Path` on first access, and `cffGlyphLoader` does
the same for a charstring ([`src/glyphset.mjs`][glyphset]). The `lowMemory`
option additionally defers glyph-name mapping
([`src/encoding.mjs`][encoding]).

The `Font` constructor attaches managers: `encoding` (cmap),
`position` (GPOS kerning), `substitution` (GSUB read/write), `palettes`,
`layers`, `svgImages`, a lazily created `HintingTrueType` bytecode interpreter
behind the `hinting` getter, and — through a `Proxy` on `tables` that fires
when `fvar` plus `gvar` or `CFF2` appear — a `VariationManager`
([`src/font.mjs`][font]).

## Analysis spine

### 1. Layering and ownership

One object, no layers. `Font` is face, scaled font and layout engine at once;
size is a per-call `fontSize` argument, never state. The caller's
`ArrayBuffer` is wrapped in a `DataView`, parsed tables are fresh objects, and
lazily loaded glyphs keep references into the buffer — ownership is the
garbage collector's. Everything is mutable (the same objects feed
`toArrayBuffer`), which is the opposite of the immutable-after-load contract a
multi-threaded engine needs; JavaScript's single thread hides the question.
Errors are thrown `Error`s, including from the shaper on unsupported lookup
formats.

### 2. Face loading and table access

`parse` (bytes) and `load`/`loadSync` (path/URL); single faces only. Table
decoding is **eager** per table and **lazy** per glyph. Raw access is total:
`font.tables.os2.sTypoAscender`, `font.tables.gsub.features`,
`font.tables.fvar.instances`. Unknown tags are simply not parsed — no raw-bytes
fallback is kept. Refusals: WOFF2 (without an external decoder), TTC/OTC, and
COLRv1 (parsed as v0 with a warning, _"Only COLRv0 is currently fully
supported"_, [`src/tables/colr.mjs`][colr]).

### 3. Shaping

`stringToGlyphs(s, options)` runs a `Bidi` tokenizer, registers a
`glyphIndex` modifier, and applies `options.features` — by default
`{ script: 'arab', tags: ['init','medi','fina','rlig'] }`,
`{ script: 'latn', tags: ['liga','rlig'] }`,
`{ script: 'thai', tags: ['liga','rlig','ccmp'] }`
(`defaultRenderOptions`, [`src/font.mjs`][font]). The appliers in
`src/features/` are per-script modules — `arab/arabicPresentationForms`,
`arab/arabicRequiredLigatures`, `ccmp/ccmpReplacementLigatures`,
`latn/latinLigatures`, `thai/thaiGlyphComposition`, `thai/thaiLigatures`,
`thai/thaiRequiredLigatures`, `unicode/variationSequences`
([`src/bidi.mjs`][bidi]). `FeatureQuery.getLookupMethod` supports GSUB
type/format pairs `11`, `12`, `21`, `41`, `51`, `53`, `63`; anything else
throws _"is not yet supported"_ ([`src/features/featureQuery.mjs`][fq]).
`updateFeatures` hard-codes `script: 'latn'` for user toggles. Output is a
`Glyph[]` with **no cluster map**; positioning is `advanceWidth` plus
`getKerningValue` (GPOS pair kerning, else `kern` pairs) in `forEachGlyph` —
no mark attachment, no cursive, no vertical.

The inspection-side API is richer than the shaping side. `Substitution`
enumerates GSUB contents per `(feature, script, language)`:
`getSingle`, `getMultiple`, `getAlternates`, `getLigatures` (returns
`{ sub: [first, ...components], by: ligGlyph }` records), and `getFeature`,
which dispatches by tag — `ss01`–`ss20` to singles, `aalt`/`salt` to singles
plus alternates, `liga`/`dlig`/`rlig` to ligatures, `ccmp` to
multiples plus ligatures, `stch` to multiples ([`src/substitution.mjs`][subst]).
That is exactly a ligature/stylistic-set catalogue an inspector renders; the
matching `add*` methods make it a feature _editor_.

### 4. Variation and instances

`fvar` axes and instances, `avar`, `STAT`, `gvar`, `cvar` and `HVAR` are
parsed. `font.variation` (`VariationManager`) exposes
`getDefaultCoordinates`, `getInstanceIndex`, `getInstance` and `set(index |
{ tag: value })`, which stores user-space coordinates in
`defaultRenderOptions.variation` ([`src/variation.mjs`][variation]). The
processor normalises to −1..+1 and then applies `avar` segment maps
(`getNormalizedCoords`), applies `gvar` tuple deltas to outline points, and
adjusts `advanceWidth`/`leftSideBearing` from `HVAR`
([`src/variationprocessor.mjs`][vproc]). Coordinates reach **outlines and
advances only**: `FeatureQuery` never consults `FeatureVariations`, and
`src/position.mjs` has no variation path, so GSUB/GPOS ignore the instance.

### 5. Rasterization and outlines

No rasterizer: drawing delegates to a Canvas 2D context (`Path.draw(ctx)`).
The outline is **a path object as data**: `Path.commands` is an array of
`{ type: 'M'|'L'|'Q'|'C'|'Z', x, y, x1, y1, x2, y2 }` in **font units, y-up**
(`glyph.path`). `Glyph.getPath(x, y, fontSize, options, font)` produces a new
`Path` scaled by `fontSize / unitsPerEm` and **y-flipped** for canvas
coordinates, after optionally applying variation (`getTransform`) and TrueType
hinting (`font.hinting.exec`) ([`src/glyph.mjs`][glyph]). `Path` serialises to
SVG (`toPathData`, `toSVG`, `toDOMElement`) and parses SVG back (`fromSVG`)
([`src/path.mjs`][path]). Colour: COLRv0 layers resolved through CPAL into
per-layer filled `Path`s, SVG-table images as `_image` layers; no CBDT, no
sbix, no COLRv1 paint graph. No glyph cache beyond memoised parsed paths.

### 6. Metrics and measurement

`font.ascender`/`descender` come from **`hhea`** only; OS/2 typo and win
values are reachable as `font.tables.os2.sTypoAscender`, `usWinAscent`,
`sxHeight`, `sCapHeight`. `Glyph.getMetrics()` derives `xMin`/`yMin`/
`xMax`/`yMax` from **all command coordinates including control points** (a
control box, not a tight bounding box) and computes `rightSideBearing`
([`src/glyph.mjs`][glyph]). `getAdvanceWidth(text, fontSize)` sums advances
plus kerning. `drawMetrics` overlays the glyph box and advance; the glyph
inspector draws baseline, `head` `yMax`/`yMin`, `hhea` ascender/descender and
OS/2 typo ascender/descender as reference lines
([`docs/glyph-inspector.html`][gi]).

### 7. Discovery, matching and fallback

Not applicable. One file in, one `Font` out; no enumeration, no matching, no
fallback chain. `hasChar` and `charToGlyphIndex` answer coverage for a single
face only.

## What it teaches `sparkles:font`

- **Reflective table objects make an inspector free.** If the D parser exposes
  each table as a struct with named fields, a `sparkles:reflection` walk renders
  the whole font in an explorer — the `for (property in table)` loop above.
- **Expose GSUB as enumerable records per (feature, script, language)**, not
  only as an apply engine: `getLigatures`' `{ sub, by }` shape is the list a
  programming-font explorer shows for `liga`/`calt`/`ssNN`.
- **Keep outline-in-font-units and outline-at-size as separate calls.**
  opentype.js's unscaled `glyph.path` versus scaled, y-flipped `getPath` is the
  right split; the mistake is fusing hinting into the second.
- **A shaper of hand-wired per-script features is a dead end.** Delegate to
  HarfBuzz (see [`./harfbuzz.md`](./harfbuzz.md)) rather than grow a lookup
  type matrix one format at a time.
- **Variation must reach layout, not just glyphs**; opentype.js normalises
  through `avar` correctly but drops `FeatureVariations` and GPOS deltas.

## Strengths

- Every table is a plain object: trivially inspectable, serialisable, editable.
- Read and write in one model (`toArrayBuffer`), with GSUB `add*` builders.
- Lazy glyph loading keeps parse cost proportional to glyphs touched.
- Includes a TrueType bytecode interpreter and full `gvar`/`avar`/`HVAR`
  outline variation.

## Weaknesses

- Shaping covers seven GSUB type/format pairs and pair-kerning only; no
  clusters, marks or vertical layout.
- No WOFF2, no collections, no COLRv1, no bitmap colour formats.
- Eager per-table decoding of a whole font; mutable shared state.
- Variation ignores `FeatureVariations` and GPOS/`MVAR` deltas.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                         | Trade-off                                             |
| ------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------- |
| Decode every known table into plain objects | Uniform inspection and round-trip writing         | Parse cost and memory up front; no zero-copy          |
| Lazy `Glyph.path` thunks                    | Glyph decoding dominates; most glyphs never used  | Glyph objects retain the whole buffer                 |
| Outline as `Path.commands` array            | Directly serialisable to SVG and canvas           | No streaming sink; every outline allocates            |
| Per-script hand-written feature appliers    | Covers Latin ligatures and Arabic joining cheaply | Unsupported lookups throw; no general OpenType layout |
| Size as a per-call argument                 | No scaled-font object to manage                   | Hinting recomputed per call; no size-keyed cache      |
| Variation applied in glyph transform only   | Outlines and advances are what drawing needs      | Shaping is instance-blind                             |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Entry points** — [`src/opentype.mjs`][otjs] (`parseBuffer`, `load`),
  [`src/font.mjs`][font] (`Font`, `defaultRenderOptions`, `forEachGlyph`,
  `getKerningValue`, `stringToGlyphIndexes`, `toArrayBuffer`).
- **Glyphs and outlines** — [`src/glyph.mjs`][glyph], [`src/path.mjs`][path],
  [`src/glyphset.mjs`][glyphset], [`src/encoding.mjs`][encoding].
- **Layout** — [`src/bidi.mjs`][bidi], [`src/features/featureQuery.mjs`][fq],
  [`src/substitution.mjs`][subst], [`src/position.mjs`][position].
- **Variation and colour** — [`src/variation.mjs`][variation],
  [`src/variationprocessor.mjs`][vproc], [`src/tables/fvar.mjs`][fvar],
  [`src/tables/colr.mjs`][colr].
- **Docs and inspectors** — [`README.md`][readme],
  [`docs/font-inspector.html`][fi], [`docs/glyph-inspector.html`][gi].

<!-- References -->

[repo]: https://github.com/opentypejs/opentype.js
[license]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/LICENSE
[readme]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/README.md
[fi]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/docs/font-inspector.html
[gi]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/docs/glyph-inspector.html
[otjs]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/opentype.mjs
[font]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/font.mjs
[glyph]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/glyph.mjs
[path]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/path.mjs
[glyphset]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/glyphset.mjs
[encoding]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/encoding.mjs
[bidi]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/bidi.mjs
[fq]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/features/featureQuery.mjs
[subst]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/substitution.mjs
[position]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/position.mjs
[variation]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/variation.mjs
[vproc]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/variationprocessor.mjs
[fvar]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/tables/fvar.mjs
[colr]: https://github.com/opentypejs/opentype.js/blob/5d65b6dcfab5115f90d375f8ba6b7942fdaa0138/src/tables/colr.mjs
