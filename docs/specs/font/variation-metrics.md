---
status: draft
owner: sparkles:font
reviewed: 2026-10-14
---

# `sparkles:font` — Variation, metrics and inspection operations (M2)

## Abstract

This page states, operation by operation, what milestone M2 of
[`sparkles:font`](./SPEC.md) delivers: building an instance of a variable
face, applying variation deltas, reading line, glyph, cell and vertical
metrics, reading `BASE` baselines and `MATH` data, and enumerating layout
features, substitutions and colour capabilities. For each operation it fixes
the inputs, the result, every error and its trigger, and the work and
allocation bounds. Measurements are exact in design units, rounded once into
base's physical `LayoutUnit`, and converted to pixels only with an explicit
scale. A value the font does not supply is reported as absent; nothing on
this page invents one.

## Introduction

[`SPEC.md`](./SPEC.md) § 8, § 9 and § 14 state what variation, metrics and
inspection must achieve, in requirements `FTA3`, `FTV1`–`FTV5`, `FTM1`–`FTM7`,
`FTP13` and `FTI2`–`FTI4`. As with [`parsing.md`](./parsing.md) for M1, that
level is enough to agree on scope but not to write code or tests against: it
does not say how a coordinate is rounded, what a variation index past its data
contributes, whether a glyph with no `MATH` record has an italics correction
of zero, or how a baseline the font does not define is told apart from one at
zero. Each such choice changes a result or an error, so each is made here.

The reference engines answer several of these questions by inventing a value.
HarfBuzz gives an uncovered glyph a top-accent attachment at half its advance,
reports an absent `BASE` extent as zero, synthesizes vertical advances from
horizontal metrics, and treats a variation index past its data as a zero delta.
A renderer can live with that; an inspector cannot, and neither can a
publication layout that must know whether a font supplied a value. This page
therefore reports absence and per-item errors where the engines fill in, and
§ 9 lists each such divergence with the oracle that agrees with it.

The operations share four rules: an instance is the only carrier of
coordinates (`FTV3`); measurements stay exact until one explicit conversion
(`FTM6`, base's [`WRAP-UNIT4`](../base/text/wrapping.md#layoutunit)); device
deltas apply only under an explicit ppem; and nothing allocates, with lists
read through ranges over the font bytes or written into caller storage that a
measuring call sizes first.

This page covers the M2 obligations in
[`PLAN.md`](./PLAN.md#m2-variation-metrics-and-inspection). Reference-point
coordinates in `BASE` and the `glyf` route to a vertical origin need M3's
outline points; this page fixes their records and leaves their resolution to
M3. Operation names are proposed, not delivered symbols.

## Contract at a glance

1. **An instance is a small value.** It holds a face, a unit-tagged size, at
   most 64 normalized coordinates with the user values they came from, and a
   synthesis value. Building one does all normalization; nothing else takes
   coordinates.
2. **Normalization is exact fixed point.** Clamp, divide, apply `avar`, then
   round to F2Dot14 the way HarfBuzz does, in integer arithmetic.
3. **Deltas are exact and per item.** Variation deltas are summed in fixed
   point at 1/65,536 font unit; a variation index past its data is an error for
   that value, not a zero.
4. **Three kinds of number, explicit conversions.** Design values are fixed
   point font units; physical values are base's `LayoutUnit`, rounded once
   with ties to even; pixel values need an explicit ppem or device scale.
5. **Absent is a result.** A missing table, a missing record and a stored zero
   are three different outcomes, in every query on this page.

## 1. Common rules

**FTM8: Design values.** A measurement at an instance **must** be available as
a `DesignValue`: a signed 64-bit count of 1/65,536 font units, together with
the face's `unitsPerEm`. A stored integer field is exact in it; a variation
delta is added exactly as `FTV12` computes it. Sums of design values (a run's
advances, an advance plus a kern) **must** be checked and return
`arithmeticExhausted` on overflow, never wrap.

_Rationale:_ 1/65,536 unit is the precision FreeType and fontations
accumulate deltas in, and finer than any engine reports. A 64-bit count holds
2⁴⁷ font units, far past any sum a paragraph produces, so the check guards
hostile input rather than real text.

**FTM9: Physical conversion.** Converting a design value `d` to `LayoutUnit`
at an instance whose physical em size is `e` **must** compute `d · e /
(unitsPerEm · 65,536)` exactly with base's widened rational arithmetic and
round once, to the nearest tick with ties to even
([`WRAP-UNIT5`](../base/text/wrapping.md#layoutunit)). An intermediate or a
result outside `LayoutUnit`'s range **must** return `arithmeticExhausted` and
publish nothing. An instance whose size is in pixels **must** return
`unsupportedCapability` for a physical query, since it has no physical em.

**FTM10: Pixel conversion.** A pixel value **must** be computed from the exact
design value as `d · ppem / (unitsPerEm · 65,536)`, in `double`, rounded once
by that conversion and never to whole pixels (`FTM4`). An instance sized
physically **must** take its ppem from an explicit device scale: `ppem = e ·
dpi / 72` for its em `e` in points. Changing the device scale **must not**
change any physical result. Cell metrics (`FTM16`) are the only whole-pixel
values.

**FTM11: Device deltas.** A Device table (formats 1–3) **must** contribute its
delta only to a query that supplies an integer ppem, and only for a ppem
inside the table's range; outside it, or without a ppem, the delta is zero and
the result says it was not applied. A design or physical query **must not**
apply a device delta. A VariationIndex table (format `0x8000`) **must**
contribute its item variation store delta (`FTV12`) at the instance, to every
query. Its store is the containing table's own when it has one (`BASE` 1.1),
and `GDEF`'s for `MATH` and `GPOS`; a missing store is `missingTable` for that
value.

**FTM12: Absence.** Every query on this page **must** distinguish, as
different results: the table is missing (`missingTable`); the table is
present but has no record for the request (an `absent` result, not an
error); the record is malformed (its error under `FTP14`); and a stored value
of zero (a value). A query **must not** substitute a value for an absent one;
the few fallbacks that exist are separate operations whose results name
their provenance.

## 2. Instances

Proposed operations: `face.axes`, `face.namedInstances`, and
`face.instance(size, coordinates, synthesis)` returning an `Instance`.

**FTV6: Axes and named instances.** `face.axes` **must** be a random-access
range of `Expected!Axis` over `fvar`, as M1's view reads it (`FTP23`), each
with tag, minimum, default, maximum, hidden flag and name ID; an axis whose
values are out of order is its `badValue` entry. `face.namedInstances`
**must** be a random-access range of named instances with subfamily name ID,
the PostScript name ID when `instanceSize` carries it, and user coordinates.
A face without `fvar` has empty ranges, not an error.

**FTV7: Building an instance.** `face.instance` **must** take a unit-tagged
size (a physical em as `LayoutUnit`, or a pixel ppem), user coordinates as
(tag, F16.16 value) pairs, and a synthesis value, and return an `Instance` or
an error:

| Input                                              | Result                                                                     |
| -------------------------------------------------- | -------------------------------------------------------------------------- |
| a tag the face has no axis for                     | ignored, and counted in the instance                                       |
| a tag given twice                                  | the last value wins, as in HarfBuzz                                        |
| an axis left unspecified                           | its default, normalized to 0                                               |
| a value for an axis that is a `badValue` entry     | that entry's error                                                         |
| more than 64 axes in `fvar`                        | `limitExceeded`, naming the axis limit                                     |
| a size that is zero, negative or not finite        | `badValue`                                                                 |
| `avar` unreadable, or not matching `fvar` (`FTV9`) | the instance is built without `avar`, and records the error                |
| a face without `fvar`                              | an instance with no coordinates; coordinates given are ignored and counted |

An `Instance` **must** keep, per axis, the user value it was built from or
the default (`FTV4`), and the normalized F2Dot14 value; it **must** be a
copyable value with no indirection beyond the face's bytes (`FTA3`). Building
it **must** cost O(a + m + v) for `a` axes, `m` `avar` map entries and the
`avar` version 2 work `v` of `FTV10`, and **must not** allocate.

_Rationale:_ 64 axes is four times the most any registered or widely shipped
font uses, and keeps an instance at a few hundred bytes. The limit joins
`FTB3`.

**FTV8: Normalization.** For each axis with minimum `min`, default `def` and
maximum `max`, a user value `u` **must** be normalized as follows, all in
integer arithmetic:

1. Clamp `u` to `[min, max]`.
2. If `u = def`, the result is 0; below `def` it is `(u − def) / (def − min)`;
   above, `(u − def) / (max − def)`. The quotient is rounded to F16.16, to
   nearest with ties away from zero. After the clamp, neither divisor is zero
   on a side that is reached.
3. Apply the axis's `avar` segment map, if any (`FTV9`), to the F16.16 value.
4. Round to F2Dot14 as `(x + 2) >> 2` on the F16.16 value `x`: nearest, ties
   toward positive infinity.

_Rationale:_ These are HarfBuzz's steps and roundings, computed in floating
point there and exactly here; fontations does the same in integers. The
F2Dot14 result is what every table stores coordinates in, so rounding to it
once, after `avar`, is what `FTV5` checks.

**FTV9: `avar` version 1.** `avar` **must** be applied only when its axis
count equals `fvar`'s; otherwise the instance **must** be built without it and
record `badValue` (FreeType's rule). Within a usable `avar`, a segment map
whose `fromCoordinate` values decrease is M1's `badValue` entry, and that axis
**must** be left unmapped and the error recorded. A well-ordered map **must**
be applied with HarfBuzz's piecewise rule: no pairs is the identity; one pair
shifts by `to − from`; a value equal to one or more `from` values takes the
`to` of the middle one, or of the one nearest zero when they are an even
number; a value outside the first or last `from` is shifted by that pair's
`to − from`; any other value is interpolated between its neighbouring pairs,
rounded to F16.16 with ties away from zero. A map missing the −1, 0 or +1
anchors that OpenType requires **must** still be applied this way and be
reported by inspection.

**FTV10: `avar` version 2.** A version-2 `avar` **must** first apply its
segment maps as `FTV9`, round every coordinate to F2Dot14, then, for every
axis `i` and against that same rounded vector, add the delta of variation
index `map(i)` from its item variation store (`FTV12`), rounded to F2Dot14 with
ties away from zero, and clamp the sum to [−1, +1]. A missing axis index map
is the identity (outer 0, inner `i`). This replaces M1's `unsupportedVersion`
for version 2. Its cost is O(a · r · a) for `r` regions.

**FTV11: Synthesis.** The synthesis value **must** be stored in the instance
unchanged: an emboldening strength and an oblique slant, both F16.16, zero by
default. M2 does not apply it; outlines (M3) and rasterization do.

## 3. Variation deltas

**FTV12: Item variation store.** An item variation store **must** be read with
these rules, and the delta of one item is a `DesignValue`:

| Situation                                                           | Result                                                           |
| ------------------------------------------------------------------- | ---------------------------------------------------------------- |
| region list axis count differs from `fvar`'s                        | the store is `badValue`; every delta from it is that error       |
| per axis, `peak = 0` or `coord = peak`                              | factor 1                                                         |
| per axis, `start > peak`, `peak > end`, or `start < 0 < end`        | factor 1 (the axis is ignored), as in every engine               |
| per axis, `coord ≤ start` or `coord ≥ end`                          | factor 0, and the region's scalar is 0                           |
| per axis, otherwise                                                 | `(coord − start)/(peak − start)` or `(end − coord)/(end − peak)` |
| a region index past the region count                                | `badValue` for the item                                          |
| an outer index past the data count, or an inner index past its rows | `indexOutOfRange` for the item                                   |
| outer and inner both `0xFFFF` (`NO_VARIATION_INDEX`)                | delta zero, by definition                                        |
| `LONG_WORDS` set                                                    | 32- and 16-bit deltas; otherwise 16- and 8-bit                   |
| `wordCount` greater than the region index count                     | the item data is `badValue`                                      |

Each axis factor **must** be computed as an F16.16 rounding division, the
region scalar as the product of its factors, each product rounded to F16.16,
and the delta as the exact sum of `scalar · delta` in 1/65,536 units. One delta
**must** cost O(r · a) for `r` regions referenced and `a` axes, and **must
not** allocate.

_Rationale:_ This is fontations' fixed-point evaluation; HarfBuzz and
fontTools sum in floating point and agree with it far inside the 1/64-unit
tolerance `testing.md` sets. Reporting a dangling index, where those engines
add zero, is what lets an inspector show the broken value next to its
unvaried default.

**FTV13: Delta-set index maps.** A DeltaSetIndexMap of format 0 or 1 **must**
map an index at or past its count to its last entry, as every engine does. A
map with count 0 **must** be the identity (outer `i >> 16`, inner
`i & 0xFFFF`), as in HarfBuzz and fontations. Another format **must** make the
map `unsupportedVersion`, and every lookup through it that error.

**FTV14: `HVAR`, `VVAR` and `MVAR`.**

- An advance at an instance with nonzero coordinates **must** add the `HVAR`
  (or `VVAR`) delta when that table is present and major version 1; a missing
  advance map is the identity on the glyph ID. A present but unreadable
  `HVAR` **must** make varied advances that error; it **must not** fall back
  to `gvar` phantom points, which belong to M3. A face with `gvar` and no
  `HVAR` **must** report its varied advances as `unsupportedCapability` until
  M3 delivers phantom points; at the default instance it reports the stored
  advance. A varied advance below zero **must** be reported as computed, not
  clamped.
- An `MVAR` value **must** be found by binary search on its tag, with records
  `valueRecordSize` bytes apart (at least 8); a tag with no record has delta
  zero. Each metric of § 4 that OpenType's `MVAR` value-tag table names takes
  its tag's delta. The `hhea` ascender, descender and line gap take the
  `hasc`, `hdsc` and `hlgp` deltas, as HarfBuzz and FreeType apply them.
  Deltas are fractional; nothing rounds them.

## 4. Metrics

Proposed operations, on an `Instance`: `lineMetrics`, `verticalSets`,
`decorations`, `advance(gid)`, `cellMetrics(ppem)`.

**FTM13: The three sets.** `verticalSets` **must** report the `hhea`
ascender, descender and line gap; the `OS/2` typographic ascender, descender
and line gap; and the `OS/2` Windows ascent and descent, each as stored plus
its `MVAR` delta, with the `USE_TYPO_METRICS` flag (`FTM1`). A set whose table
is missing is absent; the stored sign is kept, never forced.

**FTM14: Line metrics.** `lineMetrics` **must** choose a set by `FTM2`'s rule
and return ascender, descender and line gap with the name of the set used. A
missing `OS/2` counts as a typographic set of zeros without the flag; a
missing `hhea` as an `hhea` set of zeros. The Windows set's descender is the
negated `usWinDescent`, and its line gap is zero. Every value is available as
design, physical and pixel values (§ 1).

**FTM15: Decorations.** `decorations` **must** report x-height and cap height
when `OS/2` is version 2 or later, underline position and thickness when
`post` is present, and strikeout position and size when `OS/2` is present,
each with its `MVAR` delta (`xhgt`, `cpht`, `undo`, `unds`, `stro`, `strs`).
Each is absent otherwise (`FTM3`). A stored zero is reported as zero: this
page does not treat a zero thickness as missing.

**FTM16: Cell metrics.** `cellMetrics(ppem)` **must** return whole device
pixels computed from the pixel values of `FTM10` at that ppem, with this
rounding, which is part of the contract (`FTM5`):

| Quantity  | Rule                                                                                                                                                 |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| width     | the advance of U+0030 DIGIT ZERO, else `OS/2.xAvgCharWidth`, rounded to nearest with ties to even, at least 1                                        |
| ascent    | the line ascender, rounded up                                                                                                                        |
| descent   | the negated line descender, rounded up, at least 0                                                                                                   |
| line gap  | the line gap rounded to nearest with ties to even, at least 0                                                                                        |
| height    | ascent + descent + line gap                                                                                                                          |
| baseline  | ascent + ⌊line gap / 2⌋, from the cell's top                                                                                                         |
| underline | baseline − the underline position rounded to nearest, ties to even; thickness rounded the same way, at least 1; absent when `FTM15` has no underline |

A face that maps neither U+0030 nor has `OS/2` **must** return
`unsupportedCapability`: a cell without a width is not computed.

**FTM17: Advances.** `advance(gid)` **must** return the `hmtx` advance of
`FTP24` plus the `HVAR` delta of `FTV14` as a design value, with physical and
pixel forms by § 1. It **must** cost O(log m + r · a) for an index map of `m`
entries. A run of advances measured together **must** be summed as design
values and converted once (`FTM6`); `Instance.measureRun(gids)` does so.

## 5. Vertical metrics

Proposed operations, on an `Instance`: `verticalLineMetrics`,
`verticalAdvance(gid)`, `verticalOrigin(gid)`.

**FTM18: `vhea` and `vmtx`.** `vhea` **must** be readable at 36 bytes or
more with version 1.0 or 1.1; its ascender, descender and line gap are
reported as stored plus the `vasc`, `vdsc` and `vlgp` deltas. `vmtx` **must**
be read with `vhea`'s `numOfLongVerMetrics` under `FTP24`'s rules, with the
`VVAR` delta of `FTV14`. Without `vhea` or `vmtx`, `verticalAdvance` **must**
be absent.

**FTM19: Vertical origin.** `verticalOrigin(gid)` **must** return a value with
its provenance:

| Face                         | Result                                                                                                                 |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `VORG` present, version 1.0  | the glyph's record by binary search, else `defaultVertOriginY`; plus the `VVAR` origin delta when it has an origin map |
| no `VORG`; `vmtx` and `glyf` | the glyph's top side bearing plus its `yMax`, which needs M3: until then `unsupportedCapability`                       |
| otherwise                    | absent                                                                                                                 |

A layout that needs an origin for a face in the last row chooses its own
fallback; the font **must not** report one as the font's.

## 6. Baselines

Proposed operations, on an `Instance`: `baselineTags(axis)`,
`baseline(axis, script, tag)`, `extents(axis, script, language, feature)`.

**FTM20: `BASE` structure.** `BASE` **must** be readable with major version
1, minor 0 or 1; the item variation store offset exists from 1.1. Its
horizontal and vertical axes are each optional. An axis's tag list and its
script records are random-access ranges; a script record whose offset lies
outside the table is its `badOffset` entry, and the other scripts stay
readable (`FTA11`).

**FTM21: Baseline lookup.** `baseline(axis, script, tag)` **must** find the
script by binary search, then the `DFLT` script; the result **must** say
which script supplied it. The language does not select baselines, as in
OpenType. Each case has its own result:

| Situation                                               | Result                                                                                                                             |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| no `BASE`                                               | `missingTable`                                                                                                                     |
| no such axis                                            | absent                                                                                                                             |
| neither the script nor `DFLT` has a record              | absent                                                                                                                             |
| the script record has no BaseValues                     | absent                                                                                                                             |
| `tag` not in the axis's tag list                        | absent                                                                                                                             |
| the tag's index is past the BaseValues coordinate count | `badValue`                                                                                                                         |
| a coordinate of format 1                                | its coordinate                                                                                                                     |
| format 2                                                | its coordinate, reference glyph and point index; resolving the point is M3's, until then the coordinate with `unresolvedPoint` set |
| format 3                                                | its coordinate plus its Device or VariationIndex delta (`FTM11`)                                                                   |
| another format                                          | `unsupportedVersion`                                                                                                               |

`BaseValues.defaultIndex` **must** be reported, and **must not** be used to
answer a request for another tag. A coordinate of zero is a value.

**FTM22: Extents.** `extents(axis, script, language, feature)` **must** take
the language's MinMax record when it has one, else the script's default; within
it, the feature's record by binary search, else the record's own minimum and
maximum. Each of the minimum and maximum **must** be absent when its offset is
null, never zero.

## 7. Math data

Proposed operations, on an `Instance`: `mathConstants`,
`italicsCorrection(gid)`, `topAccentAttachment(gid)`, `isExtendedShape(gid)`,
`mathKern(gid, corner, height)`, `mathVariants(gid, direction)` and
`mathAssembly(gid, direction, parts[])`.

**FTP34: `MATH` structure.** `MATH` **must** be readable with major version
1; another is `unsupportedVersion`; no table is `missingTable`, and every
query below then returns that error rather than a constant. Coverage tables
of format 1 and 2 are read under the rules M4 uses for layout coverage.

**FTP35: Constants.** `mathConstants` **must** return the 56 constants with
their native kinds: two percentages (`scriptPercentScaleDown`,
`scriptScriptPercentScaleDown`) and `radicalDegreeBottomRaisePercent` as
signed integers, never scaled; two minimum heights
(`delimitedSubFormulaMinHeight`, `displayOperatorMinHeight`) as design values
without a device table; and 51 MathValueRecords as design values with their
device or variation delta under `FTM11`. A constants table shorter than its
fields is `truncated` for the whole set.

**FTP36: Glyph information.**

| Query                      | Glyph not covered | Covered, but its index is past the value array | Otherwise                        |
| -------------------------- | ----------------- | ---------------------------------------------- | -------------------------------- |
| `italicsCorrection`        | absent            | `badValue`                                     | its MathValueRecord              |
| `topAccentAttachment`      | absent            | `badValue`                                     | its MathValueRecord              |
| `isExtendedShape`          | `false`           | —                                              | `true`                           |
| `mathKern(gid, corner, h)` | absent            | `badValue`                                     | `FTP37`; a null corner is absent |

A missing MathGlyphInfo subtable **must** make the first, second and fourth
queries absent for every glyph and the third `false`.

**FTP37: Kern step rule.** A math kern with `n` correction heights and `n + 1`
values **must** return the value at index `k`, the number of heights at or
below `h`: a height equal to `h` selects the value above it. Heights **must**
be compared as design values at the instance, including their variation
deltas and excluding device deltas, so a ppem never changes which step is
chosen. Lookup **must** cost O(log n).

**FTP38: Variants and assemblies.** `mathVariants` **must** be a
random-access range of (glyph, advance measurement) for the glyph's
construction in the requested direction, with `minConnectorOverlap` reported
beside it; a glyph without a construction has an empty range. `mathAssembly`
**must** write the parts (glyph, start connector, end connector, full advance,
the flags word, and whether the extender bit is set) into the caller's array
and return the written slice and the assembly's italics correction, absent
when null. A caller array shorter than the part count **must** return
`limitExceeded` with the length needed and leave the array unchanged; a
measuring call `mathAssemblyLength` returns it first. The library **must
not** compose an assembly.

## 8. Inspection

Proposed operations, on a face or an instance: `layoutScripts(table)`,
`features(table, script, language)`, `lookup(table, index)`,
`substitutions(lookup)`, `colourCapability`.

**FTI7: Script, language and feature lists.** For `GSUB` and `GPOS`,
`layoutScripts` **must** be a random-access range of scripts, each with its
default language system and its language systems, and `features` a range of
the features one language system enables: for each, its tag, its index, its
lookup indices and whether it is the required feature. A required feature
index of `0xFFFF` **must** mean none. A feature index past the feature list,
or a lookup index past the lookup list, **must** be that entry's
`indexOutOfRange` and leave the others readable; a malformed lookup **must**
not hide the rest of the table, unlike HarfBuzz's whole-table rejection.

**FTI8: Feature variations.** At an instance, a table of version 1.1 or later
**must** take the first FeatureVariations record whose conditions all hold,
each condition `min ≤ coord ≤ max` inclusive on an F2Dot14 coordinate, an
axis index past the instance's axes reading as 0 and an empty condition set
holding. That record's substitutions **must** replace the matching feature
tables. `features` at an instance **must** report the substituted lookups and
the record index; on a face it reports the default ones.

**FTI9: Substitutions.** `substitutions(lookup)` **must** be a forward range
of records, read lazily from the font bytes, by `GSUB` lookup type:

| Type                                          | Each record                                                                                                                        |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| 1 single, 2 multiple, 3 alternate, 4 ligature | an input glyph sequence and an output glyph sequence, alternates as one record per alternate                                       |
| 5 context, 6 chained context                  | the lookups it invokes, with the sequence index each applies at                                                                    |
| 7 extension                                   | the records of the subtable it wraps; an extension of an extension, or subtables of differing types, is that subtable's `badValue` |
| 8 reverse chained single                      | an input and an output glyph, with its context marked                                                                              |

Glyph sequences **must** borrow the font bytes. A coverage entry whose glyph
has no matching record, or a record past its subtable, **must** be that
record's error, and the range continues. A whole walk **must** cost time
linear in the lookup's bytes; listing what contextual lookups invoke **must
not** follow them, so it cannot loop.

**FTI10: Colour capability.** `colourCapability` **must** report, for each of
`COLR` version 0 layers (`numBaseGlyphs` above zero), `COLR` version 1 paint
(version 1 and a non-empty BaseGlyphList), `CPAL` (`numPalettes` above zero),
`CBDT` (with a `CBLC`), `sbix` (version 1) and `SVG ` (a document list with
entries), whether the face has it, independent of rendering (`FTI4`). A
`COLR` version above 1, or a `CBDT` without `CBLC`, **must** be reported as
present but unusable, with its error, rather than as supported.

## 9. Oracles

Each operation is checked against an independent implementation, as
[`testing.md`](./testing.md) describes. Where this page deliberately differs
from HarfBuzz, the difference is listed with the oracle that agrees with it.

| Operations       | Oracle                                                                                                                                           | Known divergence, and the substitute oracle                                                                                                                                                                                                                                                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FTV6`–`FTV10`   | `hb_ot_var_normalize_coords` over every axis of every variable bundled face (`FTV5`)                                                             | HarfBuzz reorders an axis whose minimum exceeds its default, and applies `avar` whose axis count differs from `fvar`'s; this page reports `badValue` and leaves `avar` out (`FTV9`). Substitutes: fontTools for the axis check, FreeType for the `avar` count. FreeType itself keeps 16.16 coordinates and is not an oracle for the F2Dot14 result.                                                                                            |
| `FTV12`–`FTV14`  | `hb_font_get_glyph_h_advance` and `hb_ot_metrics_get_variation` at instance extremes, within 1/64 unit                                           | (1) HarfBuzz adds zero for a dangling variation index or region; this page reports an error. Substitute: fontations, which returns no value, and hand-built fixtures. (2) HarfBuzz falls back to `gvar` phantom points for a malformed `HVAR`, and clamps a varied advance at zero; this page reports the error and the computed value. Substitute: fixtures. (3) FreeType rounds each delta to an integer; it is not an oracle for fractions. |
| `FTM13`–`FTM15`  | FreeType's face metrics; `hb_ot_metrics_get_position` where they agree                                                                           | HarfBuzz has no `hhea`-zero fallback, forces the ascender positive and the descender negative, decides that `OS/2` has data from its weight and character-index fields, and reports x-height and cap height absent when both are zero. FreeType and skrifa follow `FTM2`, keep signs, and key absence on the table version. Substitute: FreeType for line metrics, skrifa for decorations.                                                     |
| `FTM16`          | hand-computed values for DejaVu Sans Mono and Maple Mono at 14, 16 and 18 px                                                                     | —                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `FTM18`, `FTM19` | `hb_font_get_glyph_v_advance` and `hb_font_get_glyph_v_origin` on a real vertical face, where it has `vmtx` or `VORG`                            | HarfBuzz synthesizes a vertical advance without `vmtx` and an origin without `VORG`; this page reports them absent. Substitute: FreeType, which records that vertical metrics are missing, and fontTools goldens for the raw tables.                                                                                                                                                                                                           |
| `FTM20`–`FTM22`  | fontTools goldens for `BASE` records; `hb_ot_layout_get_baseline` for format 1 and 3 values                                                      | HarfBuzz ignores a format-2 reference point, reports a null MinMax coordinate as zero, and synthesizes missing baselines in its fallback API; this page reports the point as data and the others absent. Substitute: fontTools, which keeps the fields as stored.                                                                                                                                                                              |
| `FTP34`–`FTP38`  | `hb_ot_math_get_*` over the pinned math face; fontTools goldens for assemblies and raw records                                                   | HarfBuzz gives an uncovered glyph a top accent at half its advance and an italics correction and kern of zero, and selects kern steps on device-adjusted scaled heights; this page reports absence and compares design values (`FTP37`). Substitute: fontations, which returns no value for an uncovered glyph and compares design units.                                                                                                      |
| `FTI7`–`FTI9`    | `hb_ot_layout_table_get_script_tags`, `…_language_get_feature_indexes`, `hb_ot_layout_feature_get_lookups`, `hb_ot_layout_lookup_collect_glyphs` | HarfBuzz rejects a whole `GSUB` or `GPOS` when one part fails its checks; this page reports per entry. Substitute: fontTools for the records of a table HarfBuzz rejects, and fixtures.                                                                                                                                                                                                                                                        |
| `FTI10`          | `hb_ot_color_has_layers`, `…_has_paint`, `…_has_palettes`, `…_has_png`, `…_has_svg`                                                              | HarfBuzz counts `CBDT` without `CBLC`, and any `COLR` version above 0 as version 1; this page reports both as present but unusable. Substitute: FreeType, which keys bitmaps on `CBLC` and refuses `COLR` versions above 1.                                                                                                                                                                                                                    |
