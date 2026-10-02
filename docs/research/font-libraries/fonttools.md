# fontTools (Python)

The reference toolkit of the font-engineering world: a lossless, round-trip
OpenType object model (`TTFont`) whose layout tables are generated from a
schema written as data (`otData`), a lossless XML view of every table
(`ttx`), the canonical outline-sink protocol (pens), and the reference
implementations of variation normalisation, instancing, subsetting and
feature compilation — with no shaping and no rasterizer of its own.

| Field            | Value                                                                                                                |
| ---------------- | -------------------------------------------------------------------------------------------------------------------- |
| Language         | Python (≥ 3.11), optional Cython/compiled helpers                                                                    |
| License          | MIT ([`LICENSE`][license])                                                                                           |
| Repository       | [fonttools/fonttools][repo]                                                                                          |
| Documentation    | [`README.rst`][readme]; docstrings rendered at fonttools.readthedocs.io                                              |
| Category         | scripting-language toolkit                                                                                           |
| Layer(s) covered | parse · outline (pen protocol) · variation instancing · subset · feature compile (no shape, no raster, no discovery) |
| Version at pin   | 4.66.2.dev0 ([`Lib/fontTools/__init__.py`][init])                                                                    |
| Pinned revision  | `fb73c333570652fb3f23643ecd3d795cbde76776` (2026-10-02)                                                              |

## Overview

### What it solves

> fontTools is a library for manipulating fonts, written in Python. The
> project includes the TTX tool, that can convert TrueType and OpenType fonts
> to and from an XML text format, which is also called TTX.

— [`README.rst`][readme]

It is the substrate of font production pipelines (`fontmake`,
`ufo2ft`) and of QA tools: it reads and writes every OpenType table, compiles
AFDKO feature files (`feaLib`), builds and instantiates variable fonts
(`varLib`), subsets (`subset`), converts WOFF/WOFF2 (`ttLib.woff2`) and
dumps everything as XML (`ttx`). Shaping is out of scope; the ecosystem pairs
it with `uharfbuzz` (see [`./harfbuzz.md`](./harfbuzz.md)).

### Design philosophy

Two ideas define it. **The table schema is data.** `otData.py` lists every
OpenType Layout structure as a `(name, [FieldSpec, ...])` pair transcribed from
the specification, and `otTables._buildClasses` iterates it to create the
Python classes; `otConverters` turns each `FieldSpec.type` into a reader and
writer ([`otData.py`][otdata], [`otDataSchema.py`][otschema],
[`otTables.py`][ottables]):

```python
(
    "Ligature",
    [
        FieldSpec(
            "GlyphID", "LigGlyph", description="GlyphID of ligature to substitute"
        ),
        FieldSpec(
            "uint16",
            "CompCount",
            description="Number of components in the ligature",
        ),
        FieldSpec(
            "GlyphID",
            "Component",
            repeat="CompCount",
            aux=-1,
            description="Array of component GlyphIDs-start with the second component-ordered in writing direction",
        ),
```

— [`Lib/fontTools/ttLib/tables/otData.py`][otdata]

**Outlines are drawn, not returned.** The pen protocol decouples outline
storage from consumers:

> A Pen is a kind of object that standardizes the way how to "draw" outlines:
> it is a middle man between an outline and a drawing. In other words: it is
> an abstraction for drawing outlines, making sure that outline objects don't
> need to know the details about how and where they're being drawn, and that
> drawings don't need to know the details of how outlines are stored.

— [`Lib/fontTools/pens/basePen.py`][basepen]

## How it works

**`TTFont` is a lazy dict of tables.** `TTFont(file, fontNumber=-1,
lazy=None, ...)` opens an `SFNTReader` over the file (or, unless `lazy=True`,
over an in-memory `BytesIO` copy) and decodes only the directory
([`ttFont.py`][ttfont]). `font["GSUB"]` calls `_readTable`: look up the tag's
class with `getTableClass`, `decompile(data, font)`, cache in `font.tables`.
With `ignoreDecompileErrors=True` a failing table falls back to a
`DefaultTable` holding the raw bytes and the traceback in `.ERROR`.
`lazy` is tri-state: `True` defers arrays longer than eight records into a
`LazyList` (`readArray`, [`otConverters.py`][otconv]); `None` (default) also
defers per-glyph `glyf` expansion; `False` decompiles everything
([`_g_l_y_f.py`][glyf]). Any table can be re-serialised (`getTableData`) and the
font saved (`save`, with `flavor="woff"`/`"woff2"`).

**`getGlyphSet(location=..., normalized=False)`** returns a name-keyed
mapping of glyphs from `glyf`, `CFF ` or `CFF2` (plus a `VARC` wrapper), each
with `.width`/`.lsb` (and `.height`/`.tsb` from `vmtx`) and `.draw(pen)` /
`.drawPoints(pointPen)`; a non-normalised `location` is first sent through
`normalizeLocation` ([`ttFont.py`][ttfont], [`ttGlyphSet.py`][glyphset]).

## Analysis spine

### 1. Layering and ownership

`TTFont` → table objects → (for layout tables) a tree of `BaseTable`
instances generated from `otData`. There is no scaled font, shaper or
rasterizer layer; `_TTGlyphSet` is a view at one variation `location` (with a
`pushLocation` stack for variable composites). Ownership is Python's: tables
are mutable objects owned by `font.tables`; the reader keeps the file open
(context manager supported). `TTCollection(file, shareTables=True)` shares
decoded tables between member fonts through a `(tag, bytes)` cache
([`ttCollection.py`][ttc]). No thread-safety contract. Errors are exceptions
(`TTLibError`), with opt-in degradation to raw bytes per table.

### 2. Face loading and table access

Path or file object; `fontNumber` selects a TTC/OTC member;
`res_name_or_index` reads Mac suitcases. Every table is lazy, raw and
**writable**: `font["OS/2"].sTypoAscender = …; font.save(...)`. Typed
overloads of `__getitem__`/`get` per tag (`Literal["fvar"]` →
`table__f_v_a_r`) give IDE-level discoverability. Unknown tags become
`DefaultTable` (opaque bytes), never errors. `ttx` is the inspector CLI over
this model: `-l` lists the table directory, `-t`/`-x` select or exclude
tables, `-s` splits per table, `-y` picks a collection member, `-i` keeps
TrueType instructions as bytes ([`ttx.py`][ttx]).

### 3. Shaping

Not applicable: fontTools contains no shaping engine. What it contributes to
shaping is _authoring_ and _inspection_: `feaLib.builder.addOpenTypeFeatures
(font, featurefile)` compiles AFDKO feature syntax into GSUB/GPOS/GDEF
([`feaLib/builder.py`][fea]); `otlLib.builder` constructs lookups
programmatically; the subsetter's `_layout_features_groups` documents which
features each HarfBuzz shaper applies by default — `common`: `rvrn`, `ccmp`,
`liga`, `locl`, `mark`, `mkmk`, `rlig`; `horizontal`: `calt`, `clig`,
`curs`, `kern`, `rclt`; plus fractions, vertical, LTR/RTL, East Asian spacing
and per-shaper groups ([`subset/__init__.py`][subset]). `unicodedata` supplies
the script data a shaper caller needs: `script(char)`,
`script_extension(char)`, `script_horizontal_direction(code)`,
`ot_tags_from_script(code)` and `block(char)`
([`unicodedata/__init__.py`][ucd]).

### 4. Variation and instances

The reference implementation. `varLib.models.normalizeValue(v, (min,
default, max))` maps user to normalised space piecewise-linearly around the
default and clamps unless `extrapolate`; `normalizeLocation(location, axes)`
applies it per axis ([`varLib/models.py`][models]). `TTFont.normalizeLocation`
then applies `avar` through `table__a_v_a_r.renormalizeLocation`, which
accepts `avar` major versions 1 and 2 ([`ttFont.py`][ttfont],
[`_a_v_a_r.py`][avar]). Normalised coordinates reach **outlines** (`gvar`
deltas or `CFF2` blends via `VarStoreInstancer` in `_TTGlyphSetCFF`) and
**advances** (`HVAR` in `_TTGlyph`) ([`ttGlyphSet.py`][glyphset]); layout
variation is handled not at use time but by **instancing**:
`varLib.instancer.instantiateVariableFont(varfont, axisLimits, ...)` pins axes
(full instance) or restricts ranges (partial VF), rewriting `gvar`, `HVAR`,
`MVAR`, GPOS/GDEF variation stores, `FeatureVariations`
(`instancer/featureVars.py`) and, with `updateFontNames`, `name` from `STAT`
(`instancer/names.py`) ([`instancer/__init__.py`][instancer]). `fvar` exposes
`axes` (`Axis`: `axisTag`, `minValue`, `defaultValue`, `maxValue`,
`axisNameID`, `flags`) and `instances` (`NamedInstance`: `coordinates`,
`subfamilyNameID`, `postscriptNameID`) ([`_f_v_a_r.py`][fvar]); `STAT` is fully
decoded from `otData`.

### 5. Rasterization and outlines

No rasterizer of its own; `FreeTypePen` hands a drawn outline to
`freetype-py` for a bitmap ([`pens/freetypePen.py`][ftpen]). Outlines are a
**callback sink**: `AbstractPen` has `moveTo(pt)`, `lineTo(pt)`,
`curveTo(*points)` (cubic; more than two off-curve points form a
"super-bézier" decomposed by `decomposeSuperBezierSegment`), `qCurveTo(*points)`
(TrueType quadratic strings with implied on-curve midpoints; the last point
may be `None` for an all-off-curve contour), `closePath()`, `endPath()` and
`addComponent(glyphName, transformation)` ([`basePen.py`][basepen]). The
**point-pen** protocol is the lossless alternative —
`beginPath()`, `addPoint(pt, segmentType, smooth, name)`, `endPath()`,
`addComponent`, `addVarComponent(glyphName, transformation, location)` — with
`PointToSegmentPen`/`SegmentToPointPen` adapters between the two
([`pointPen.py`][pointpen]). Coordinates are **font units, y-up, unscaled**.
The pens directory is a catalogue of consumers: bounds (`BoundsPen` tight,
`ControlBoundsPen` control box), `RecordingPen`, `TransformPen`,
`StatisticsPen`/`MomentsPen` (area, centroid, slant), `SVGPathPen`,
`TTGlyphPen`/`T2CharStringPen` (building outlines), `Cu2QuPen`/`Qu2CuPen`
(curve conversion), plus Cairo, Qt, Quartz, ReportLab and wx backends.
Colour tables are decoded and built: COLRv0/v1 paint graphs (`BaseGlyphList`,
`ClipList` in `otData`; `colorLib.builder`/`unbuilder`), `CPAL`, `CBDT`/`CBLC`,
`sbix`, `SVG `.

### 6. Metrics and measurement

Raw tables only, all exposed: `hhea` (`ascent`, `descent`, `lineGap`),
`OS/2` (`sTypoAscender`/`sTypoDescender`/`sTypoLineGap`, `usWinAscent`/
`usWinDescent`, `sxHeight`, `sCapHeight`, `fsSelection` `USE_TYPO_METRICS`),
`head` (`unitsPerEm`, bbox), `post`, `hmtx`/`vmtx` per glyph name, `MVAR` for
varied metrics. No "the" ascender is chosen. Bounds come from `glyf` records
or from drawing into `BoundsPen`; `ttLib.scaleUpem` rescales a whole font.

### 7. Discovery, matching and fallback

Not applicable: no enumeration or matching. Coverage tooling is per font:
`font.getBestCmap()` returns the best Unicode subtable using HarfBuzz's
preference order — `(3,10)`, `(0,6)`, `(0,4)`, `(3,1)`, `(0,3)`, `(0,2)`,
`(0,1)`, `(0,0)` — as a `{ codepoint: glyphName }` dict
([`ttFont.py`][ttfont]); `cmap.buildReversed()` maps glyph names back to code
point sets ([`_c_m_a_p.py`][cmap]); `unicodedata.block`/`script` classify the
covered set; `name.getBestFamilyName()`/`getBestFullName()`/`getDebugName(id)`
resolve names with platform preference ([`_n_a_m_e.py`][name]).

## What it teaches `sparkles:font`

- **Generate layout-table readers from a schema written as data.** `otData` is
  a direct model for a D table of `FieldSpec`-like UDA'd structs consumed by
  `static foreach`; the same schema then drives reading, inspector display
  (`ttx`-style dumps via `sparkles:reflection`) and tests.
- **Adopt the pen protocol as the outline sink.** A D `isOutlineSink!T` with
  `moveTo`/`lineTo`/`quadTo`/`cubicTo`/`close` (plus an optional point-sink
  shape for editors) lets bounds, SVG export, rasterizers and atlas packers
  share one walk, allocation-free.
- **Normalise once, in one place: user → `normalizeValue` → `avar`.** Expose
  both user and normalised coordinates; let every consumer take normalised.
- **Degrade unknown or broken tables to raw bytes plus an error**, never fail
  the whole open — the inspector must still show the directory.
- **Prefer the HarfBuzz cmap subtable order** so coverage in the explorer
  matches what the shaper will actually use.

## Strengths

- Complete, lossless, writable model of every OpenType table, including
  COLRv1, `avar` 2 and `VARC`.
- Schema-as-data keeps the layout-table code uniform with the spec.
- Pen protocol is the de facto outline interchange interface.
- Reference implementations of normalisation, instancing, subsetting,
  feature compilation and WOFF2.

## Weaknesses

- Python object graphs: high memory and parse cost per font; not a runtime
  engine.
- No shaping, no rasterizer, no font discovery.
- Mutable shared objects; laziness is tri-state and table-specific.
- Layout variation is resolved by instancing, not at query time.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                 | Trade-off                                                  |
| ----------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------- |
| `otData` schema generates table classes         | One transcription of the spec drives read, write and XML  | Runtime metaprogramming; field access is attribute-dynamic |
| Tables decoded on first `font[tag]`             | Opening a font costs only the directory                   | Errors surface late, at first access                       |
| Raw-bytes fallback on decompile errors (opt-in) | Tools can still process and save damaged fonts            | Silent partial models if enabled carelessly                |
| Segment pen and point pen protocols             | Decouple outline storage from every consumer              | Two protocols and adapters to keep consistent              |
| Variation via `normalizeLocation` + instancer   | Exact reference semantics; static output for any consumer | No live layout-variation path                              |
| No shaping; defer to HarfBuzz                   | Avoids a second, divergent shaper                         | Inspection of "what renders" needs `uharfbuzz`             |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Core** — [`Lib/fontTools/ttLib/ttFont.py`][ttfont] (`TTFont`,
  `_readTable`, `getGlyphSet`, `normalizeLocation`, `getBestCmap`),
  [`ttGlyphSet.py`][glyphset], [`ttCollection.py`][ttc], [`ttx.py`][ttx].
- **Schema** — [`otData.py`][otdata], [`otDataSchema.py`][otschema],
  [`otTables.py`][ottables], [`otConverters.py`][otconv].
- **Tables** — [`_f_v_a_r.py`][fvar], [`_a_v_a_r.py`][avar],
  [`_c_m_a_p.py`][cmap], [`_n_a_m_e.py`][name], [`_g_l_y_f.py`][glyf].
- **Pens** — [`basePen.py`][basepen], [`pointPen.py`][pointpen],
  [`freetypePen.py`][ftpen].
- **Variation, subset, features, Unicode** — [`varLib/models.py`][models],
  [`varLib/instancer/__init__.py`][instancer], [`subset/__init__.py`][subset],
  [`feaLib/builder.py`][fea], [`unicodedata/__init__.py`][ucd],
  [`ttLib/woff2.py`][woff2].
- **Docs** — [`README.rst`][readme], [`LICENSE`][license].

<!-- References -->

[repo]: https://github.com/fonttools/fonttools
[readme]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/README.rst
[license]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/LICENSE
[init]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/__init__.py
[ttfont]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/ttFont.py
[glyphset]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/ttGlyphSet.py
[ttc]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/ttCollection.py
[ttx]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttx.py
[otdata]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/tables/otData.py
[otschema]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/tables/otDataSchema.py
[ottables]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/tables/otTables.py
[otconv]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/tables/otConverters.py
[fvar]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/tables/_f_v_a_r.py
[avar]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/tables/_a_v_a_r.py
[cmap]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/tables/_c_m_a_p.py
[name]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/tables/_n_a_m_e.py
[glyf]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/tables/_g_l_y_f.py
[basepen]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/pens/basePen.py
[pointpen]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/pens/pointPen.py
[ftpen]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/pens/freetypePen.py
[models]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/varLib/models.py
[instancer]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/varLib/instancer/__init__.py
[subset]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/subset/__init__.py
[fea]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/feaLib/builder.py
[ucd]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/unicodedata/__init__.py
[woff2]: https://github.com/fonttools/fonttools/blob/fb73c333570652fb3f23643ecd3d795cbde76776/Lib/fontTools/ttLib/woff2.py
