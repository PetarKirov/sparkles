---
status: accepted
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
horizontal metrics, and treats a dangling variation region as a zero delta. A
renderer can live with that; an inspector cannot, and neither can a
publication layout that must know whether a font supplied a value. This page
therefore reports absence and per-item errors where the engines fill in, and
§ 9 lists each such divergence with the oracle that agrees with it.

The operations share four rules: an instance is the only carrier of
coordinates (`FTV3`); measurements stay exact until one explicit conversion
(`FTM6`, base's [`WRAP-UNIT4`](../base/text/wrapping.md#layoutunit)); device
deltas apply only under an explicit integer ppem; and nothing allocates, with
lists read through ranges over the font bytes or written into caller storage
that a measuring call sizes first.

This page covers the M2 obligations in
[`PLAN.md`](./PLAN.md#m2-variation-metrics-and-inspection). Reference-point
coordinates in `BASE` and the `glyf` route to a vertical origin need M3's
outline points; this page fixes their records and leaves their resolution to
M3. Operation names are proposed, not delivered symbols. In cost bounds, `a`
is the number of axes, `r` the regions one delta references, and `n` the
entries of the array an operation searches.

## Contract at a glance

1. **An instance is a small value.** It holds a face, a unit-tagged size, at
   most 64 normalized coordinates with the user values they came from, and a
   synthesis value. Building one does all normalization; nothing else takes
   coordinates.
2. **Normalization is exact fixed point.** Clamp, divide, apply `avar`, then
   round to F2Dot14 the way HarfBuzz does, in integer arithmetic.
3. **Deltas are exact and per item.** Variation deltas are summed in fixed
   point at 1/65,536 font unit; a variation reference the font cannot resolve
   is an error for that value, not a zero.
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

_Rationale:_ 1/65,536 unit is the precision fontations accumulates deltas in,
and finer than any engine reports. A 64-bit count holds 2⁴⁷ font units, far
past any sum a paragraph produces, so the check guards hostile input rather
than real text.

**FTM9: Physical conversion.** Converting a design value `d` to `LayoutUnit`
at an instance whose physical em size is `e` **must** compute `d · e /
(unitsPerEm · 65,536)` exactly with base's widened rational arithmetic and
round once, to the nearest tick with ties to even
([`WRAP-UNIT5`](../base/text/wrapping.md#layoutunit)). A result outside
`LayoutUnit`'s range **must** return `arithmeticExhausted` and publish
nothing; the product fits base's signed 128-bit intermediate, so no other
overflow arises. An instance sized in pixels **must** return
`unsupportedCapability` for a physical query, since it has no physical em.

**FTM10: Pixels and ppem.** A ppem **must** be a positive rational. An
instance sized in pixels carries it; a physically sized instance takes it
from an explicit device scale as `ppem = e · dpi / 72` for its em `e` in
points, kept exact. A pixel value **must** be the exact rational
`d · ppem / (unitsPerEm · 65,536)` converted once to the nearest `double`,
ties to even, and never rounded to whole pixels (`FTM4`). Changing the device
scale **must not** change any physical result. Cell metrics (`FTM16`) are the
only whole-pixel values. A pixel query costs O(1).

**FTM11: Device and variation deltas.** A Device table of format 1, 2 or 3
**must** contribute its delta only to a pixel query whose ppem is an integer
inside the table's range; otherwise its delta is zero and the result says it
was not applied. Design and physical queries **must not** apply a device
delta. A VariationIndex table (format `0x8000`) **must** contribute its item
variation store delta (`FTV12`) at the instance, to every query; its store is
the containing table's own when it has one (`BASE` 1.1), and `GDEF`'s for
`MATH` and `GPOS`. A VariationIndex with no store to read is `badValue` for
that value. Another delta format **must** be `unsupportedVersion` for that
value.

**FTM12: Absence.** Every query on this page **must** distinguish, as
different results: the table is missing (`missingTable`); the table is present
but has no record for the request (an `absent` result, not an error); the
record is malformed (its error under `FTP14`); and a stored value of zero (a
value). A query **must not** substitute a value for an absent one.

**FTM13: Error kinds and limits.** An index read from font data that lies past
the array it indexes **must** be `badValue`; `indexOutOfRange` is reserved for
caller-supplied indices (`FTP15`). A caller array shorter than a result
**must** be `limitExceeded` naming the limit `callerStorage` with the length
needed, and leave the array unchanged. More than 64 `fvar` axes is
`limitExceeded` naming `variationAxes`, `FTB3`'s axis limit.

**FTM14: Default coordinates.** At an instance whose normalized coordinates
are all zero, including any instance of a face without `fvar`, no item
variation store **must** be read and every variation delta is zero, so a
malformed store cannot fail a query at the default.

## 2. Instances

Proposed operations: `face.axes`, `face.namedInstances`, and
`face.instance(size, coordinates, synthesis)` returning an `Instance`.

**FTV6: Axes and named instances.** `face.axes` **must** be a random-access
range of `Expected!Axis` over `fvar`, as M1's view reads it (`FTP23`), each
with tag, minimum, default, maximum, hidden flag and name ID; an axis whose
values are out of order is its `badValue` entry. `face.namedInstances`
**must** be a random-access range of named instances with subfamily name ID,
the PostScript name ID when `instanceSize` carries it, and user coordinates.
A face without `fvar` has empty ranges, not an error; an unreadable `fvar`
makes both ranges its error. Obtaining either range costs O(1) and each
element O(1).

**FTV7: Building an instance.** `face.instance` **must** take a unit-tagged
size (a physical em as `LayoutUnit`, or a pixel ppem), `c` user coordinates
as (tag, F16.16 value) pairs, and a synthesis value, and return an `Instance`
or an error:

| Input                                              | Result                                                                     |
| -------------------------------------------------- | -------------------------------------------------------------------------- |
| a tag no axis has                                  | ignored, and counted in the instance                                       |
| a tag given twice                                  | the last value wins, as in HarfBuzz                                        |
| a tag that several axes share                      | every axis with that tag takes the value, as in fontations                 |
| an axis left unspecified                           | its default, normalized to 0                                               |
| a value for an axis that is a `badValue` entry     | that entry's error                                                         |
| an unspecified axis that is a `badValue` entry     | normalized to 0, and the error recorded                                    |
| more than 64 axes in `fvar`                        | `limitExceeded` naming `variationAxes`                                     |
| an unreadable `fvar`                               | its error                                                                  |
| a size or ppem that is zero or negative            | `badValue`                                                                 |
| `avar` unreadable, or not matching `fvar` (`FTV9`) | the instance is built without `avar`, and records the error                |
| a face without `fvar`                              | an instance with no coordinates; coordinates given are ignored and counted |

An `Instance` **must** keep, per axis, the user value it was built from or
the default (`FTV4`), and the normalized F2Dot14 value; it **must** be a
copyable value with no indirection beyond the face's bytes (`FTA3`). Building
it **must** cost O(c · a + m + v) for `m` `avar` map entries and the `avar`
version-2 work `v` of `FTV10`, and **must not** allocate.

_Rationale:_ 64 axes is four times the most any registered or widely shipped
font uses, and keeps an instance at a few hundred bytes.

**FTV8: Normalization.** For each axis with minimum `min`, default `def` and
maximum `max`, a user value `u` **must** be normalized as follows, all in
integer arithmetic:

1. Clamp `u` to `[min, max]`.
2. If `u = def`, the result is 0; below `def` it is `(u − def) / (def − min)`;
   above, `(u − def) / (max − def)`. The quotient is rounded to F16.16, to
   nearest with ties away from zero. After the clamp, neither divisor is zero
   on a side that is reached.
3. Apply the axis's `avar` segment map, if `FTV9` makes it usable, to the
   F16.16 value.
4. Round to F2Dot14 as `(x + 2) >> 2` on the F16.16 value `x`: nearest, ties
   toward positive infinity.

_Rationale:_ These are HarfBuzz's steps and roundings, computed in floating
point there and exactly here, as fontations does. The F2Dot14 result is what
every table stores coordinates in, so rounding to it once, after `avar`, is
what `FTV5` checks.

**FTV9: `avar` version 1.** `avar` **must** be applied only when its axis
count equals `fvar`'s; otherwise the instance **must** be built without it and
record `badValue` (FreeType's rule). A segment map whose `fromCoordinate`
values decrease is M1's `badValue` entry; that axis **must** be left unmapped
and the error recorded. A well-ordered map **must** be applied to an F16.16
value `v` with HarfBuzz's rule, every quotient rounded to F16.16 with ties
away from zero:

1. Drop a leading pair (−1, −1) when the next pair's `from` is also −1, and a
   trailing pair (+1, +1) when the previous pair's `from` is also +1.
2. No pairs is the identity; one pair shifts `v` by `to − from`.
3. If `v` equals the `from` of some pairs: exactly one, its `to`; exactly
   three, the middle one's `to`; otherwise, for `v < 0` the last match's
   `to`, for `v > 0` the first's, and for `v = 0`, of the first and the last
   match, the one whose `to` has the smaller magnitude, the last on a tie.
4. If `v` is below the first `from` or above the last, shift it by that pair's
   `to − from`.
5. Otherwise interpolate linearly between the pair before `v` and the pair
   after it, taking the first pair whose `from` exceeds `v`.

A map missing the −1, 0 or +1 anchors that OpenType requires **must** still
be applied this way and be reported by inspection. Applying one map costs
O(n) for its `n` pairs.

**FTV10: `avar` version 2.** A version-2 `avar` **must** first apply its
segment maps as `FTV9`, giving F16.16 values `x`. It then evaluates, for every
axis `i`, the delta `δ` of variation index `map(i)` (`FTV12`) against the
vector of `x / 4` rounded to F2Dot14 with ties away from zero, the same vector
for every axis; adds `4δ`, clamped to [−131,072, 131,072] and rounded with
ties away from zero, to the F16.16
`x`; clamps the sum to [−65,536, 65,536]; and applies `FTV8` step 4. A missing
axis index map is the identity (outer 0, inner `i`). This replaces M1's
`unsupportedVersion` for version 2. Its cost is O(a · r · a).

**FTV11: Synthesis.** The synthesis value **must** be stored in the instance
unchanged: an emboldening strength and an oblique slant, both F16.16, zero by
default. M2 does not apply it; outlines (M3) and rasterization do.

## 3. Variation deltas

**FTV12: Item variation store.** An item variation store **must** be read with
these rules, applied in order, the first matching row deciding; the delta of
one item is a `DesignValue`:

| Situation                                                           | Result                                                                              |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| region list axis count differs from `fvar`'s                        | the store is `badValue`; every delta from it is that error                          |
| outer and inner both `0xFFFF` (`NO_VARIATION_INDEX`)                | delta zero, by definition                                                           |
| an outer index past the data count, or an inner index past its rows | `badValue` for the item                                                             |
| `wordCount` greater than the region index count                     | the item data is `badValue`                                                         |
| a region index past the region count                                | `badValue` for the item                                                             |
| per axis, `peak = 0` or `coord = peak`                              | factor 1                                                                            |
| per axis, `start > peak`, `peak > end`, or `start < 0 < end`        | factor 1 (the axis is ignored), as in every engine                                  |
| per axis, `coord ≤ start` or `coord ≥ end`                          | factor 0                                                                            |
| per axis, otherwise                                                 | `(coord − start)/(peak − start)` below the peak, `(end − coord)/(end − peak)` above |

`LONG_WORDS` selects 32- and 16-bit deltas; otherwise they are 16- and 8-bit.
The region scalar **must** start at 1 (F16.16), and each axis that the rows
above do not decide as 1 **must** update it as `round(scalar · numerator /
denominator)`, one rounding to F16.16 per axis, to nearest with ties away from
zero, as fontations computes it; the
delta is the exact sum of `scalar · delta` in 1/65,536 units. One delta
**must** cost O(r · a), and **must not** allocate.

_Rationale:_ This is fontations' fixed-point evaluation. HarfBuzz rounds an
advance's delta to a whole unit and fontTools sums in floating point, so
neither can check the fractional result exactly; § 9 names fontations as the
oracle.

**FTV13: Delta-set index maps.** A DeltaSetIndexMap of format 0 or 1 **must**
map an index at or past its count to its last entry, as every engine does. A
map with count 0 **must** be the identity (outer `i >> 16`, inner
`i & 0xFFFF`), as in HarfBuzz and fontations. Another format **must** make the
map `unsupportedVersion`, and every lookup through it that error. A lookup
costs O(1).

**FTV14: `HVAR`, `VVAR` and `MVAR`.**

- At nonzero coordinates an advance **must** add the `HVAR` (or `VVAR`) delta
  when that table is present; a missing advance map is the identity on the
  glyph ID. `HVAR` of a major version other than 1 is `unsupportedVersion`. A
  present but unreadable `HVAR` **must** make varied advances that error; it
  **must not** fall back to `gvar` phantom points, which belong to M3. A face
  with no `HVAR` (or, for vertical advances, no `VVAR`) **must** report varied
  advances as `unsupportedCapability`
  until M3 delivers phantom points. A varied advance below zero **must** be
  reported as computed, not clamped.
- `MVAR` of major version 1 with `valueRecordSize` at least 8 **must** be
  searched by binary search on its tag, records `valueRecordSize` bytes apart;
  a tag with no record has delta zero. Another major version is
  `unsupportedVersion`, and a smaller record size `badValue`; at nonzero
  coordinates every metric that takes an `MVAR` delta is then that error. A
  lookup costs O(log n + r · a).
- Each metric that OpenType's `MVAR` value-tag table names takes its tag's
  delta. The typographic set takes `hasc`, `hdsc` and `hlgp`; the `hhea` set
  takes the same three, as HarfBuzz applies them (FreeType applies them only
  to its chosen line metrics); the Windows set
  takes `hcla` and `hcld` only. Deltas are fractional; nothing rounds them.

## 4. Metrics

Proposed operations, on an `Instance`: `verticalSets`, `lineMetrics`,
`decorations`, `advance(gid)`, `measureRun(gids)` and `cellMetrics(ppem)`.
Each of the first three costs O(1) plus one `MVAR` lookup per value.

**FTM15: The three sets.** `verticalSets` **must** report the `hhea`
ascender, descender and line gap; the `OS/2` typographic ascender, descender
and line gap; and the `OS/2` Windows ascent and descent, each as stored plus
its `MVAR` delta, with the `USE_TYPO_METRICS` flag (`FTM1`). A set whose table
is missing is absent; the stored sign is kept, never forced.

**FTM16: Line metrics.** `lineMetrics` **must** apply `FTM2`'s order to the
sets `FTM15` reports, skipping any that is absent: the typographic set when
`USE_TYPO_METRICS` is set; otherwise `hhea` when its ascender or descender is
nonzero; otherwise the typographic set when its ascender or descender is
nonzero; otherwise the Windows set, whose descender is the negated
`usWinDescent` and whose line gap is zero. The set is chosen on its stored
values; its `MVAR` deltas are then added. If no set remains, `lineMetrics` is
absent. The result names the set used, and every value is available as
design, physical and pixel values (§ 1).

**FTM17: Decorations.** `decorations` **must** report x-height and cap height
when `OS/2` is version 2 or later, underline position and thickness when
`post` is present, and strikeout position and size when `OS/2` is present,
each with its `MVAR` delta (`xhgt`, `cpht`, `undo`, `unds`, `stro`, `strs`).
Each is absent otherwise (`FTM3`). A stored zero is reported as zero.

**FTM18: Advances.** `advance(gid)` **must** return the `hmtx` advance of
`FTP24` plus the `HVAR` delta of `FTV14` as a design value, with physical and
pixel forms by § 1, in O(r · a). `measureRun(gids)` **must** sum the advances
of a run as design values and convert the sum once (`FTM6`); it covers
advances only, not kerning, which is shaping's. It **must** return the first
error any glyph gives and publish nothing, and cost O(n · r · a) for `n`
glyphs.

**FTM19: Cell metrics.** `cellMetrics(ppem)` **must** take an integer ppem and
return whole device pixels computed from the pixel values of `FTM10`, with
this rounding, which is part of the contract (`FTM5`):

| Quantity  | Rule                                                                                                                                                         |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| width     | the advance of the glyph U+0030 DIGIT ZERO maps to, else `OS/2.xAvgCharWidth`, rounded to nearest with ties to even, at least 1; the result names its source |
| ascent    | the line ascender, rounded up                                                                                                                                |
| descent   | the negated line descender, rounded up, at least 0                                                                                                           |
| line gap  | the line gap rounded to nearest with ties to even, at least 0                                                                                                |
| height    | ascent + descent + line gap                                                                                                                                  |
| baseline  | ascent + ⌊line gap / 2⌋, from the cell's top                                                                                                                 |
| underline | baseline − the underline position, and the thickness, each rounded to nearest with ties to even, the thickness at least 1; absent without an underline       |

An error from the U+0030 advance **must** be returned, not replaced by
`xAvgCharWidth`. A face that maps no U+0030 and has no `OS/2`, or whose line
metrics are absent, **must** return `unsupportedCapability`. It costs one
`cmap` lookup, one advance and one line-metrics query.

## 5. Vertical metrics

Proposed operations, on an `Instance`: `verticalLineMetrics`,
`verticalAdvance(gid)`, `verticalOrigin(gid)`.

**FTM20: `vhea` and `vmtx`.** `vhea` **must** be readable at 36 bytes or more
with version 1.0 or 1.1; another version is `unsupportedVersion`.
`verticalLineMetrics` reports its ascender, descender and line gap as stored
plus the `vasc`, `vdsc` and `vlgp` deltas, in O(1) plus three `MVAR` lookups.
`verticalAdvance` **must** read `vmtx` with `vhea`'s `numOfLongVerMetrics`
under `FTP24`'s rules, plus the `VVAR` delta of `FTV14`, in O(r · a).
`verticalLineMetrics` is absent without `vhea`; `verticalAdvance` is absent
without
`vhea` or `vmtx`.

**FTM21: Vertical origin.** `verticalOrigin(gid)` **must** return a value with
its provenance, in O(log n + r · a):

| Face                         | Result                                                                                                                     |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `VORG` present, version 1.0  | the glyph's record by binary search, else `defaultVertOriginY`; plus the `VVAR` origin delta when `VVAR` has an origin map |
| `VORG` of another version    | `unsupportedVersion`                                                                                                       |
| no `VORG`; `vmtx` and `glyf` | the glyph's top side bearing plus its `yMax`, which needs M3: until then `unsupportedCapability`                           |
| otherwise                    | absent                                                                                                                     |

A layout that needs an origin for a face in the last row chooses its own
fallback; the font **must not** report one as the font's.

## 6. Baselines

Proposed operations, on an `Instance`: `baselineTags(axis)`,
`baseline(axis, script, tag)`, `extents(axis, script, language, feature)`.

**FTM22: `BASE` structure.** `BASE` **must** be readable with major version
1; minor 0 or 1, a later minor read as 1; the item variation store offset
exists from 1.1. Another major version is `unsupportedVersion`. Its horizontal
and vertical axes are each optional. `baselineTags` is a random-access range
over an axis's tag list, costing O(1) per element; a script record whose
offset lies outside the table is its `badOffset` entry, and the other scripts
stay readable (`FTA11`).

**FTM23: Baseline lookup.** `baseline(axis, script, tag)` **must** find the
script by binary search, then the `DFLT` script, and say which supplied it;
the language does not select baselines, as in OpenType. It costs
O(log s + log t + r · a) for `s` scripts and `t` tags:

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

**FTM24: Extents.** `extents(axis, script, language, feature)` **must**
return a minimum and a maximum, each resolved by `FTM23`'s coordinate rows,
in O(log s + log l + log f + r · a) for `l` language records and `f` feature
records:

| Situation                                                              | Result                                                      |
| ---------------------------------------------------------------------- | ----------------------------------------------------------- |
| no `BASE`; no such axis; neither the script nor `DFLT` has a record    | as in `FTM23`                                               |
| the language has a MinMax record (binary search on its tag)            | that record                                                 |
| otherwise                                                              | the script's default MinMax; absent when its offset is null |
| within the record, the feature has a record (binary search on its tag) | that feature's minimum and maximum                          |
| otherwise                                                              | the record's own minimum and maximum                        |
| a minimum or maximum offset that is null                               | that one absent, never zero                                 |
| an offset outside the table                                            | `badOffset` for that value                                  |

## 7. Math data

Proposed operations, on an `Instance`: `mathConstants`,
`italicsCorrection(gid)`, `topAccentAttachment(gid)`, `isExtendedShape(gid)`,
`mathKern(gid, corner, height)`, `mathVariants(gid, direction)`,
`mathAssemblyLength(gid, direction)` and `mathAssembly(gid, direction, parts[])`.

**FTP34: `MATH` structure.** `MATH` **must** be readable with major version
1; another is `unsupportedVersion`; no table is `missingTable`, and every
query below then returns that error rather than a constant. Coverage tables
of formats 1 and 2 are searched by binary search; another format is
`unsupportedVersion` for the queries that use it.

**FTP35: Constants.** `mathConstants` **must** return the 56 constants, each
its own `Expected` so that one constant's error leaves the others readable
(`FTA11`), with their native kinds: `scriptPercentScaleDown`,
`scriptScriptPercentScaleDown` and `radicalDegreeBottomRaisePercent` as signed
integer percentages, never scaled; `delimitedSubFormulaMinHeight` and
`displayOperatorMinHeight` as design values without a device table; and 51
MathValueRecords as design values with their delta under `FTM11`. A constants
table shorter than its fields is `truncated` for the constants past its end.
It costs O(1) per constant plus its variation delta.

**FTP36: Glyph information.** Each query costs O(log n) for the coverage, plus
its variation delta:

| Query                      | Glyph not covered | Covered, index past the value array | Otherwise                        |
| -------------------------- | ----------------- | ----------------------------------- | -------------------------------- |
| `italicsCorrection`        | absent            | `badValue`                          | its MathValueRecord              |
| `topAccentAttachment`      | absent            | `badValue`                          | its MathValueRecord              |
| `isExtendedShape`          | `false`           | —                                   | `true`                           |
| `mathKern(gid, corner, h)` | absent            | `badValue`                          | `FTP37`; a null corner is absent |

A missing MathGlyphInfo subtable, or a missing subtable within it, **must**
make the corresponding queries absent for every glyph, and `isExtendedShape`
`false`.

**FTP37: Kern step rule.** `h` **must** be a `DesignValue`. A math kern with
`n` correction heights and `n + 1` kern values **must** resolve each height at
the instance, with its variation delta and without any device delta, and
return the kern value at index `k`, where `k` is the position of the first
height, in stored order, that is greater than `h`, or `n` when none is. A
height equal to `h` therefore selects the value above it, and a ppem never
changes the step. Heights are resolved in stored order until one is greater
than `h`; the first error met is the
query's error. The lookup costs O(n · r · a); unsorted heights are reported
by inspection, not reordered.

**FTP38: Variants and assemblies.** `mathVariants` **must** be a
random-access range of (glyph, advance measurement) for the glyph's
construction in the requested direction, with `minConnectorOverlap` beside
it; a glyph without a construction has an empty range, and a construction
index past its array is `badValue`. It costs O(log n), and O(1) per element.
`mathAssemblyLength` **must** return the part count, or absent when the glyph
has no assembly, in O(log n); `mathAssembly` for a glyph with no assembly is
absent too. `mathAssembly` **must** write the parts (glyph, start
connector, end connector, full advance, the flags word, and whether the
extender bit is set) into the caller's array and return the written slice and
the assembly's italics correction, a MathValueRecord stored inline and so always
present, its Device table absent when the offset is null; a caller array shorter
than the part count is `FTM13`'s `callerStorage` error. It costs O(log n + p)
for `p` parts. The library **must not** compose an assembly.

## 8. Inspection

Proposed operations, on a face or an instance: `layoutScripts(table)`,
`features(table, script, language)`, `lookup(table, index)`,
`substitutions(lookup)` and `colourCapability`.

**FTI7: Script, language and feature lists.** For `GSUB` and `GPOS`,
`layoutScripts` **must** be a random-access range of scripts, each with its
default language system and its language systems, and `features` a range of
the features one language system enables: for each, its tag, its index, its
lookup indices and whether it is the required feature. A required feature
index of `0xFFFF` **must** mean none. A feature index past the feature list,
or a lookup index past the lookup list, **must** be that entry's `badValue`
and leave the others readable; a malformed part **must not** hide the rest of
the table, unlike HarfBuzz's whole-table rejection. Finding a script or
language costs O(log n); each element O(1). `lookup(table, index)` returns
the lookup's type, flags and subtable count in O(1), or `indexOutOfRange`
for a caller index past the list.

**FTI8: Feature variations.** At an instance, a table of version 1.1 or later
**must** take the first FeatureVariations record whose condition set holds. A
condition of format 1 holds when `min ≤ coord ≤ max` on the F2Dot14
coordinate, an axis index past the instance's axes reading as 0; an empty
condition set holds. A condition of another format **must** evaluate false and
be reported as that record's `unsupportedVersion` by inspection. A
substitution whose feature index is past the feature list is that entry's
`badValue`, and the feature keeps its default lookups. `features` at an
instance **must** report the substituted lookups and the record index; on a
face it reports the default ones. Selection costs O(R · C + log S) for `R`
records, `C` conditions per record and `S` substitutions.

**FTI9: Substitutions.** `substitutions(lookup)` **must** be a forward range
of records, read lazily from the font bytes, by `GSUB` lookup type:

| Type                                          | Each record                                                                                                                        |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| 1 single, 2 multiple, 3 alternate, 4 ligature | an input glyph sequence and an output glyph sequence; one record per alternate                                                     |
| 5 context, 6 chained context                  | the lookups it invokes, with the sequence index each applies at                                                                    |
| 7 extension                                   | the records of the subtable it wraps; an extension of an extension, or subtables of differing types, is that subtable's `badValue` |
| 8 reverse chained single                      | an input and an output glyph, with its context marked                                                                              |

A glyph sequence **must** be a lazy view: an optional leading glyph (the
coverage glyph of a ligature) followed by a borrowed run of big-endian
`uint16` glyph IDs. A format-1 single substitution's output is computed as
`(g + delta) mod 65,536`. A coverage entry with no matching record, or a
record past its subtable, **must** be that record's error, and the range
continues. A whole walk **must** cost O(Σ over subtables of coverage count ×
record length), at most 65,535 subtables of 65,535 entries; offsets shared by
several records are re-read, not cached. Listing what contextual lookups
invoke **must not** follow them, so it cannot loop.

**FTI10: Colour capability.** `colourCapability` **must** report, in O(1) per
table, for each of `COLR` version 0 layers (`numBaseGlyphs` above zero),
`COLR` version 1 paint (version 1 and a non-empty BaseGlyphList), `CPAL`
(`numPalettes` above zero), `CBDT` (with a `CBLC`), `sbix` (version 1) and
`SVG ` (a document list with entries), whether the face has it, independent
of rendering (`FTI4`). A `COLR` version above 1 **must** be reported as
present but `unsupportedVersion`, and a `CBDT` without `CBLC` as present but
`missingTable` naming `CBLC`, rather than as supported.

## 9. Oracles

Each operation is checked against an independent implementation, as
[`testing.md`](./testing.md) describes. Where this page deliberately differs
from HarfBuzz, the difference is listed with the oracle that agrees with it.
Where exact integer arithmetic and HarfBuzz's floating point disagree on an
input, fontations, which computes in integers as this page does, arbitrates.

| Operations       | Oracle                                                                                                                                                                                | Known divergence, and the substitute oracle                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `FTV6`–`FTV10`   | `hb_ot_var_normalize_coords` over every axis of every variable bundled face (`FTV5`)                                                                                                  | (1) HarfBuzz pins an axis whose default lies outside its minimum or maximum, where this page reports `badValue`; substitute: fontTools, which refuses such an axis. (2) HarfBuzz applies `avar` whose axis count differs from `fvar`'s, and interpolates a map whose `fromCoordinate` values decrease; this page leaves `avar` or the map out and records `badValue`; substitute: FreeType for the count, fixtures for the map. (3) HarfBuzz sets only the first axis of a duplicated tag; fontations sets every one, as `FTV7` does. FreeType keeps 16.16 coordinates and is not an oracle for the F2Dot14 result.                                                                                                                                                                                                                                                                                          |
| `FTV12`–`FTV14`  | fontations' `ItemVariationStore::compute_delta`, exactly; `hb_font_get_glyph_h_advance` and `hb_ot_metrics_get_variation` within 0.5 unit, excluding advances HarfBuzz clamps at zero | (1) HarfBuzz rounds an advance's delta to a whole unit, and adds zero for a dangling outer or inner index or region; fontations also adds zero for a dangling outer or inner index and refuses only a dangling region. Substitute for every dangling reference: hand-built fixtures. (2) HarfBuzz falls back to `gvar` phantom points for a malformed `HVAR`, and clamps a varied advance at zero; this page reports the error and the computed value; substitute: fixtures. (3) FreeType rounds each delta to an integer and is not an oracle for fractions. (4) HarfBuzz and fontations accept a region list whose axis count differs from `fvar`'s, reading missing coordinates as 0, where this page refuses the store; HarfBuzz also gives an invalid region (`start > peak`, `peak > end` or `start < 0 < end`) factor 0 at coordinate 0, where this page and fontations give 1. Substitute: fixtures. |
| `FTM15`–`FTM17`  | FreeType's face metrics; `hb_ot_metrics_get_position` where they agree                                                                                                                | (1) HarfBuzz has no `hhea`-zero fallback, forces the ascender positive and the descender negative, decides that `OS/2` has data from its weight and character-index fields, and reports x-height and cap height absent when both are zero. FreeType and skrifa follow `FTM2`, keep signs, and key absence on the table version. Substitute: FreeType for line metrics, skrifa for decorations. (2) FreeType and skrifa apply the `hasc`, `hdsc` and `hlgp` deltas to whichever set they chose, the Windows set included, and FreeType rounds them; this page gives the Windows set `hcla` and `hcld` only, as fontTools maps them; substitute: fixtures.                                                                                                                                                                                                                                                     |
| `FTM19`          | hand-computed values for DejaVu Sans Mono and Maple Mono at 14, 16 and 18 px                                                                                                          | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `FTM20`, `FTM21` | `hb_font_get_glyph_v_advance` and `hb_font_get_glyph_v_origin` on a real vertical face, where it has `vmtx` or `VORG`                                                                 | HarfBuzz synthesizes a vertical advance without `vmtx` and an origin without `VORG`; this page reports them absent. Substitute: FreeType, which records that vertical metrics are missing, and fontTools goldens for the raw tables.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `FTM22`–`FTM24`  | fontTools goldens for `BASE` records; `hb_ot_layout_get_baseline` for format 1 and 3 values                                                                                           | HarfBuzz ignores a format-2 reference point, reports a null MinMax coordinate as zero, and synthesizes missing baselines in its fallback API; this page reports the point as data and the others absent. Substitute: fontTools, which keeps the fields as stored.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `FTP34`–`FTP38`  | `hb_ot_math_get_*` over the pinned math face for static values; fontations for variation deltas and uncovered glyphs; fontTools goldens for assemblies and raw records                | (1) HarfBuzz gives an uncovered glyph a top accent at half its advance and an italics correction and kern of zero, and selects kern steps on device-adjusted scaled heights; this page reports absence and compares design values (`FTP37`); substitute: fontations, which returns no value for an uncovered glyph and compares design units. (2) HarfBuzz resolves `MATH` VariationIndex deltas against an empty store, so every `MATH` variation delta is zero there; substitute: fontations. (3) For math-kern heights that do not ascend, HarfBuzz's binary search and this page's stored-order scan (`FTP37`) can choose different steps; substitute: fixtures.                                                                                                                                                                                                                                         |
| `FTI7`–`FTI9`    | `hb_ot_layout_table_get_script_tags`, `…_language_get_feature_indexes`, `hb_ot_layout_feature_get_lookups`, `hb_ot_layout_lookup_collect_glyphs`                                      | HarfBuzz rejects a whole `GSUB` or `GPOS` when one part fails its checks; this page reports per entry. Substitute: fontTools for the records of a table HarfBuzz rejects, and fixtures. HarfBuzz evaluates condition formats 2–5, which this page treats as false; substitute: fixtures.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `FTI10`          | `hb_ot_color_has_layers`, `…_has_paint`, `…_has_palettes`, `…_has_png`, `…_has_svg`                                                                                                   | HarfBuzz counts `CBDT` without `CBLC`, and any `COLR` version above 0 as version 1; this page reports both as present but unusable. Substitute: FreeType, which keys bitmaps on `CBLC` and refuses `COLR` versions above 1.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
