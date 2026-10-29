# Reference

Import everything with `import sparkles.font;`. Fallible operations return
`FontResult!T`, an `Expected` holding a value or a `FontError`. Operations on
a face are free functions callable as methods (`face.charMap`).

## Errors — `sparkles.font.errors`

| Symbol          | Meaning                                                                                                                                                                                                                                            |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FontError`     | `kind`, `tag` (or none), `offset` (absolute), `tableOffset` (inside `tag`, when readable), `limit`, `limitValue`, `needed` and the `correction` behind it                                                                                          |
| `FontErrorKind` | `notAFont`, `truncated`, `badOffset`, `badValue`, `unsupportedVersion`, `missingTable`, `limitExceeded`, `indexOutOfRange`, `invalidEncoding`, `unsupportedCapability`, and kinds later milestones use                                             |
| `FontLimit`     | the limits of `FTB3`: `tableRecords` (4,096), `cmapSubtables` (64), `variationAxes` (64), `shapingFeatures` (512), and the outline and colour limits; `callerStorage` with `needed`; `engineBuffer` when the shaping engine cannot grow its buffer |
| `Tag`           | a four-byte table tag: `Tag("head")`, `.chars`                                                                                                                                                                                                     |

## Faces — `sparkles.font.face`

| Operation                                 | Result                                                                                     |
| ----------------------------------------- | ------------------------------------------------------------------------------------------ |
| `openFace(bytes, index = 0, policy)`      | a `Face`; checks the container, directory, `head`, `maxp` and the `cmap` header; O(tables) |
| `face.corrections`, `requiresBytecode`    | the correction registry's entries the face triggers                                        |
| `openCollection(bytes)`                   | a `Collection`: `count`, `face(i)`; a single font is a collection of one                   |
| `face.table(tag)`                         | the table's bytes, borrowed; `missingTable` or `badOffset`                                 |
| `face.unitsPerEm`, `numGlyphs`            | from `head` and `maxp`                                                                     |
| `face.outlines`                           | `trueType` or `cff`, from the signature                                                    |
| `face.directory`                          | `DirectoryEntry` per record: tag, offset, length, stored checksum, `readable`, `duplicate` |
| `face.computedChecksum(i)`                | the checksum of record `i`'s table                                                         |
| `face.searchFields`, `checksumAdjustment` | stored and expected values                                                                 |

## Tables — `sparkles.font.tables`

`face.head`, `hhea`, `maxp`, `os2`, `post` return structs whose fields carry
OpenType's names; `has…` flags mark fields the stored version lacks.
`face.hmtx` returns a view with `advance(gid)`, `lsb(gid)` and `metric(gid)`.
`face.fvar`, `avar` and `stat` return views whose entries are results.
`face.spacing` classifies the face as `mono`, `dual` or `proportional`.

## Character maps — `sparkles.font.cmap`

| Operation                                                                         | Result                                                                                                |
| --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `face.charMap`                                                                    | the first qualifying subtable, in HarfBuzz's order, as a `CharMap`; `unsupportedCapability` when none |
| `face.charMapAt(i)`                                                               | encoding record `i` alone, without fallback                                                           |
| `map.glyph(cp)`                                                                   | the glyph, or 0; O(log n)                                                                             |
| `map.ranges`                                                                      | sorted, merged `CodepointRange`s of mapped codepoints                                                 |
| `map.variant(cp, selector)`                                                       | `Variant`: `none`, `useDefault` or `glyph`, from format 14                                            |
| `map.platform`, `encoding`, `format`, `lookup`                                    | the chosen record and how codepoints become keys                                                      |
| `map.rejectedRecords`, `firstRejection`, `outOfRangeMappings`, `unmappedByTarget` | what was skipped or dropped                                                                           |

## Names — `sparkles.font.names`

`face.name` returns a `NameTable` whose `records` are `FontResult!NameRecord`.
A `NameRecord` has `platformID`, `encodingID`, `languageID`, `nameID`, raw
`bytes`, an optional `languageTag`, `encoding`, `decodedLength()` and
`decode(char[] destination)`.

## Glyph names

`face.glyphName(gid)` returns a `GlyphName` (`present`, `text`) from `post` or
the `CFF` charset. To name many glyphs, size and build an index:

```d
auto scratch = new uint[face.glyphNameIndexLength.value];
const index = face.glyphNameIndex(scratch).value;
const name = index[gid]; // constant time
```

The index borrows the face's bytes and `scratch`.

## Units — `sparkles.font.units`

A `DesignValue` is a signed count of 1/65,536 font units with the face's
`unitsPerEm`; `DesignValue.fromUnits(n, upem)` holds a stored field exactly.

| Operation                                      | Result                                                                                              |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `checkedAdd(a, b)`, `checkedSum(values, upem)` | the exact sum; `arithmeticExhausted` on 64-bit overflow                                             |
| `toLayoutUnit(d, em)`                          | `d · em / (upem · 65,536)` rounded once to a tick, ties to even; `arithmeticExhausted` out of range |
| `Ppem.fromInteger(n)`, `fromRational(r)`       | a positive rational ppem; `badValue` when not positive                                              |
| `Ppem.fromPhysical(em, dpi)`                   | `em · dpi / 72` for `em` in points, exactly; `ppem.isInteger` for Device tables                     |
| `toPixels(d, ppem)`                            | the exact `d · ppem / (upem · 65,536)` rounded once to the nearest `double`                         |

Sum a run's design values before converting it, so the run rounds once.

## Variations — `sparkles.font.variations`

`NormalizedCoords` is a slice of F2Dot14 coordinates, one per `fvar` axis;
`allZero(coords)` is the default instance, where no store is read and every
delta is zero. Views borrow the containing table's bytes and report errors
with its tag; a malformed header is recorded at `read` and returned by every
lookup at nonzero coordinates.

| Operation                                                                | Result                                                                                                                                |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| `ItemVariationStore.read(table, tag, tableStart, offset, fvarAxes)`      | the store view; `broken` and `error` when its header, format or region axis count is wrong                                            |
| `store.delta(DeltaSetIndex(outer, inner), coords, upem)`                 | the exact `DesignValue` delta, scalars rounded per axis as fontations does; `badValue` for a dangling outer, inner or region index    |
| `DeltaSetIndexMap.read(table, tag, tableStart, offset)`, `map.map(i)`    | the `DeltaSetIndex` of item `i`: past the count the last entry, count 0 the identity; another format `unsupportedVersion`             |
| `deviceDelta(table, tag, tableStart, offset, store, coords, upem, ppem)` | a `DeviceDelta`: the VariationIndex `variation`, and `devicePixels` with `deviceApplied` only at an integer ppem in the table's range |

`DeltaSetIndex.noVariation` (`0xFFFF`, `0xFFFF`) has delta zero. Design and
physical queries pass no ppem, so a Device table never applies to them.

## Instances — `sparkles.font.instance`

An `Instance` is a copyable value: the face, a unit-tagged `InstanceSize`, a
`Synthesis`, and per `fvar` axis the F16.16 user value and the normalized
F2Dot14 coordinate. It holds at most 64 axes and allocates nothing.

| Operation                                                  | Result                                                                                                                                    |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `face.axes`, `face.namedInstances`                         | random-access ranges of `FontResult!VariationAxis` and `NamedInstance`; empty without `fvar`, empty with `hasError` when it is unreadable |
| `InstanceSize.physical(em)`, `InstanceSize.pixels(ppem)`   | a size in `LayoutUnit` or `Ppem`; `unit`, `em`, `ppem`                                                                                    |
| `Synthesis(emboldenStrength, obliqueSlant)`                | F16.16, zero by default; stored, not applied                                                                                              |
| `face.instance(size, [UserCoordinate(tag, value)], synth)` | an `Instance`; `badValue` for a size that is not positive or a value for a `badValue` axis, `limitExceeded` past 64 axes                  |
| `inst.coords`, `userValue(i)`, `axisCount`, `allZero`      | the F2Dot14 coordinates (a `NormalizedCoords` slice), the user value given or the default                                                 |
| `inst.ignoredCoordinates`                                  | coordinates whose tag no axis has, or all of them for a face without `fvar`                                                               |
| `inst.avarApplied`, `recordedErrors`, `firstRecordedError` | whether `avar` was used, and the problems the instance was built around                                                                   |
| `normalizeAxisValue(axis, user)`, `mapCoordinate(map, v)`  | the F16.16 steps: clamp and divide, ties away from zero; one `avar` segment map with HarfBuzz's rules                                     |
| `toF2Dot14(x)`                                             | `(x + 2) >> 2`, saturated                                                                                                                 |

Of a tag given twice the last value wins; a tag several axes share sets each
of them. An `avar` whose axis count differs from `fvar`'s, or that is
unreadable, is left out and recorded; a decreasing segment map leaves only its
axis unmapped. Version 2 evaluates its item variation store on the mapped
coordinates and clamps each result to ±1.

## Metrics — `sparkles.font.metrics`

Every value is a `Measurement`: the exact `design` value and the instance's
size. `m.physical` is a `LayoutUnit` at a physically sized instance;
`m.pixels` is fractional pixels at a pixel-sized one, and `m.pixels(dpi)` at a
physically sized one on a device of `dpi` (`ppem = em · dpi / 72`), so the
device scale never changes the physical value. A query in a form the instance
cannot give is `unsupportedCapability`. `m.pixelsAt(ppem)` takes an explicit
ppem.

| Operation                                      | Result                                                                                                                                           |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `inst.verticalSets`                            | the `hhea`, typographic and Windows sets as stored plus `MVAR` deltas, and `useTypoMetrics`; a missing table's sets absent (`hasHhea`, `hasOs2`) |
| `inst.lineMetrics`                             | ascender, descender, line gap and the `source` set, chosen on stored values in FTM2's order; `present` is false when no set remains              |
| `inst.decorations`                             | x-height and cap height (`OS/2` v2+), underline (`post`), strikeout (`OS/2`), each with a `has…` flag; a stored zero is a value                  |
| `inst.advance(gid, ws)`                        | the `hmtx` advance plus the `HVAR` delta, or the `gvar` phantom-point span in a face without `HVAR`; negative results kept                       |
| `inst.measureRun(gids, ws)`                    | the checked design-value sum of the run's advances, converted once by the caller; the first error, `arithmeticExhausted` on overflow             |
| `inst.cellMetrics(cmap, ppem, ws)`             | `CellMetrics` in whole pixels: width (and `widthSource`), ascent, descent, line gap, height, baseline, underline                                 |
| `face.hvar(axes)`, `hvar.advanceDelta(gid, …)` | the `HVAR` view (major 1; a null advance map is the identity on the glyph ID) and one advance delta                                              |
| `face.mvar(axes)`, `mvar.delta(tag, …)`        | the `MVAR` view (major 1, `valueRecordSize` ≥ 8) and one value's delta by binary search; a tag with no record is zero                            |

`ws` is the caller's `PointWorkspace` (see Outlines): the phantom points of a
face without `HVAR` decode into it, and nothing allocates.

The `hhea` and typographic sets take the `hasc`, `hdsc` and `hlgp` deltas;
the Windows set takes `hcla` and `hcld` only. At all-zero coordinates neither
`HVAR` nor `MVAR` is read, so a malformed one cannot fail a query there; at
nonzero coordinates an unreadable `MVAR` fails every value that takes a delta,
and an unreadable `HVAR` every varied advance.

`cellMetrics` takes the face's `CharMap`, built once by the caller, in
addition to the integer ppem of the specification's `cellMetrics(ppem)`: the
library keeps no hidden cache, and building a character map is not O(1). It
rounds by FTM19's table: width (U+0030's advance, else `OS/2.xAvgCharWidth`)
to nearest with ties to even and at least 1; ascent up; descent (the negated
descender) up and at least 0; line gap to nearest even and at least 0; the
baseline at ascent + ⌊gap / 2⌋; the underline at `baseline − position`
rounded to nearest even, its thickness at least 1.

## Vertical metrics — `sparkles.font.vertical`

Vertical queries take an `Instance` and return `Measurement`s, like the
horizontal ones. Without the tables a result is absent (`present` false), not
an error and never a synthesized value; a stored zero is a value.

| Operation                                        | Result                                                                                                                                                                                  |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `face.vhea`                                      | `Vhea`, version 1.0 or 1.1 (fields as stored), at least 36 bytes; another version `unsupportedVersion`                                                                                  |
| `face.vmtx`, `vmtx.metric(gid)`                  | `VerticalMetric` (advance height, top side bearing) with `hmtx`'s leniency: `numOfLongVerMetrics` capped at `numGlyphs`, the last advance repeated, `truncated` per glyph               |
| `face.vorg`, `vorg.originY(gid)`                 | `VORG` 1.0; a glyph's record by binary search, else `defaultVertOriginY`, with `fromRecord`                                                                                             |
| `face.vvar(axes)`, `advanceDelta`, `originDelta` | the `VVAR` view (major 1): advance-height map (null is the identity) and vertical-origin map; side-bearing maps are not read                                                            |
| `inst.verticalLineMetrics`                       | `vhea` ascender, descender and line gap plus the `vasc`, `vdsc`, `vlgp` deltas; absent without `vhea`                                                                                   |
| `inst.verticalAdvance(gid, ws)`                  | the `vmtx` advance plus the `VVAR` delta, or without `VVAR` the `gvar` phantom-point span (the stored advance without `gvar`); absent without `vhea` or `vmtx`                          |
| `inst.verticalOrigin(gid, ws)`                   | `VerticalOrigin`: `y`, its `source` (`vorgRecord`, `vorgDefault`, `vmtxGlyph` for the no-`VORG` fallback, or `none` when absent) and whether a `VVAR` origin delta was added (`varied`) |

`verticalOrigin` follows the specification's table: `VORG` 1.0 answers, plus
the `VVAR` origin delta when `VVAR` has an origin map; another `VORG` version
is `unsupportedVersion`; a face without `VORG` but with `vmtx` and `glyf`
takes the glyph's top phantom point — its stored `yMax` (0 without points)
plus the top side bearing, moved by `gvar` — which is HarfBuzz's origin;
any other face has no origin, and a layout that needs one chooses its own
fallback. Phantom points decode into `ws`. A caller's glyph ID past
`numGlyphs` is `indexOutOfRange` for both glyph queries. At all-zero
coordinates neither `VVAR` nor `MVAR` is read.

## Baselines — `sparkles.font.baseline`

`BASE` major version 1 is read; minor 0 or 1, a later minor as 1, with the item
variation store from 1.1. Each axis (`BaselineAxis.horizontal`, `vertical`) is
optional. A coordinate is a `BaseCoord`: its `format`, its `coordinate` as a
`Measurement` (VariationIndex delta included), a format-2 `referenceGlyph` and
`pointIndex` whose outline point the coordinate resolves against at the
instance (`unresolvedPoint` set, with the stored coordinate kept, only when
the glyph has no resolvable outline), and a format-3 `device` adjustment whose
whole-pixel delta only `BaseCoord.pixels` adds, at an instance sized in pixels
at an integer ppem inside the table's range.

| Operation                                           | Result                                                                                                                                                        |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `face.base(axes)`, `base.axis(which)`               | the `BASE` view and one `BaseAxis` (`present` false when its offset is null)                                                                                  |
| `axis.tags`, `axis.scripts`                         | the tag list as `BaselineTags`; the script records as `FontResult!Tag` entries, `badOffset` for a record pointing outside the table                           |
| `inst.baselineTags(axis)`                           | `BaselineTags`, a random-access range of `Tag`; empty with `axisPresent` false without the axis                                                               |
| `inst.baseline(axis, script, tag, ws)`              | `Baseline`: which `script` record answered (`requested` or `defaultScript`), `defaultIndex`, and `present` with the `BaseCoord` when one is found             |
| `inst.extents(axis, script, language, feature, ws)` | `Extents`: the script, the MinMax `record` (`language` or `scriptDefault`), `fromFeature`, and a `min` and `max` `Extent`, each `absent`, a value or an error |

`baseline` follows the specification's table: no `BASE` is `missingTable`; no
axis, no script or `DFLT` record, no BaseValues, or a tag outside the tag list
is absent; a tag index past the coordinates is `badValue`; a coordinate format
other than 1–3 is `unsupportedVersion`. `defaultIndex` is reported but never
answers another tag, and a zero coordinate is a value. `extents` takes the
language's MinMax record, else the script's default, then the feature's record
within it, else the record's own values; a null minimum or maximum is absent,
and an offset outside the table is that value's `badOffset`. Pass `Tag.init`
for no language or feature. A format-2 coordinate's glyph decodes into `ws`.
At all-zero coordinates the store is not read.

## Coverage — `sparkles.font.coverage`

`Coverage.read(table, tag, tableStart, offset)` views a Coverage table inside
`MATH`, `GDEF`, `GSUB` or `GPOS`. Format 1 (a sorted glyph array) and format 2
(sorted glyph ranges) are read; another format is `unsupportedVersion`, an
array past the table `truncated`, and an offset past it `badOffset`. These are
recorded at `read` (`broken`, `error`) and returned by the lookups.

| Operation             | Result                                                                                                                                         |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `coverage.index(gid)` | a `CoverageIndex`: `covered`, and the format-1 position or format-2 `startCoverageIndex + gid − start`; binary search, O(log n)                |
| `coverage.glyphs`     | `CoveredGlyphs`, a forward range of `CoveredGlyph` (glyph and coverage index) in coverage order; a range whose end precedes its start is empty |

## GDEF — `sparkles.font.gdef`

`face.gdef(fvarAxes)` reads the `GDEF` header (major version 1; the item
variation store from 1.3). `face.gdefVariationStore(fvarAxes)` is the store
`MATH` and `GPOS` VariationIndex tables resolve against: not `present` without
`GDEF`, before 1.3, or with a null offset; any other `GDEF` problem is recorded
as a `broken` store, so only a delta that reads it at nonzero coordinates
reports it. `face.glyphClass(gid)`, `markAttachmentClass(gid)` and
`inMarkGlyphSet(set, gid)` read the class definitions; for a face whose
`GDEF` HarfBuzz ignores, every reading is absent and names the correction.

## Math — `sparkles.font.math_table`

The module is `math_table` so that it never reads as `std.math`. `MATH` major
version 1 is read, any minor; another major is `unsupportedVersion`, and
without the table every query is `missingTable`. Values are `MathValue`s:
`present` false when the font has no record (a stored zero is present), a
`kind` of `percentage` (signed, never scaled), `length` (a design value with no
device: the two minimum heights) or `record` (a MathValueRecord). A record's
`value` is a `Measurement` including its VariationIndex delta from `GDEF`'s
store (`badValue` without one, at nonzero coordinates); a Device table's
whole-pixel delta stays in `device` and only `MathValue.pixels` adds it, at an
instance sized in pixels at an integer ppem inside the table's range.

| Operation                                    | Result                                                                                                                                                                                                         |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `face.mathTable`                             | the `MATH` header, with `majorVersion` and `minorVersion`                                                                                                                                                      |
| `inst.mathConstants`                         | `MathConstants`, indexed by `MathConstant` (56, in table order); each constant its own `FontResult!MathValue`, `truncated` past a short table; `present` false without a MathConstants table                   |
| `inst.italicsCorrection(gid)`                | the glyph's MathValueRecord; absent when not covered, `badValue` when its coverage index is past the value array                                                                                               |
| `inst.topAccentAttachment(gid)`              | as `italicsCorrection`; an uncovered glyph is absent, never half its advance                                                                                                                                   |
| `inst.isExtendedShape(gid)`                  | whether the extended-shape coverage holds the glyph; `false` without one                                                                                                                                       |
| `inst.mathKernTable(gid, corner)`            | `MathKernTable` for a `MathKernCorner`: `heightCount`, `height(i)`, `value(i)`, `heightsAscending` and `lookup(h)`; `present` false when not covered or the corner is null, `badValue` past the record array   |
| `inst.mathKern(gid, corner, h)`              | the kern value at index `k`, the first height (stored order) greater than `h`, else `heightCount`                                                                                                              |
| `inst.mathVariants(gid, direction)`          | `MathVariants`, a random-access range of `MathVariant` (glyph and advance) for a `MathDirection`, with `minConnectorOverlap`; empty without a construction, `badValue` for a construction index past its array |
| `inst.mathAssemblyLength(gid, direction)`    | `MathAssemblyLength`: `present` and `partCount`                                                                                                                                                                |
| `inst.mathAssembly(gid, direction, parts[])` | `MathAssembly`: `present`, the written slice of `GlyphPart`s (glyph, connector lengths, full advance, `flags`, `extender`) and the assembly's `italicsCorrection`                                              |

`mathKern` resolves heights with their variation deltas and no device delta,
in stored order, until one is greater than `h`; a height equal to `h` selects
the value above it, a ppem never changes the step, and the first error met is
the result. Unsorted heights are not reordered; `heightsAscending` reports
them. `h` is a `DesignValue` in the face's units per em, else `badValue`. A
`parts` array shorter than the part count is `limitExceeded` naming
`callerStorage` with the count as `needed`, and is left unchanged, as on every
other error. `flags` keeps reserved bits as stored. No assembly is composed.
At all-zero coordinates the store is not read.

## Layout — `sparkles.font.layout`

`GSUB` and `GPOS` (a `LayoutTable`, `gsub` or `gpos`) major version 1 are read,
any minor; the FeatureVariations table from 1.1. Another major is
`unsupportedVersion`, and without the table every query is `missingTable`. A
null script, feature or lookup list is empty. Every list reports a malformed
entry as that entry's error and keeps the others readable, rather than
rejecting the whole table as HarfBuzz does: an index read from the font past
the array it indexes is `badValue`, an offset outside the table `badOffset`,
and a caller's index past a list `indexOutOfRange`.

| Operation                                              | Result                                                                                                                                                                                                                      |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `face.layout(table)`                                   | the header: `majorVersion`, `minorVersion`, `scriptCount`, `featureCount`, `lookupCount`, `hasFeatureVariations`                                                                                                            |
| `face.layoutScripts(table)`                            | `LayoutScripts`, a random-access range of `FontResult!LayoutScript` with `tag(i)` readable even for a broken entry                                                                                                          |
| `script.defaultLanguage`, `languages`, `language(tag)` | a `LangSys` (`present` false when absent; `Tag.init` names the default), the language systems as a random-access range, and a binary search by tag                                                                          |
| `langSys.featureIndices`                               | `LayoutIndices`: each feature index, `badValue` past the feature list; `hasRequiredFeature` and `requiredFeatureIndex` (`0xFFFF` is none)                                                                                   |
| `face.features(table, script, language)`               | `Features`, a random-access range of `FontResult!Feature` (tag, index, `required`, `substituted`, `lookups` as `LayoutIndices`), the required feature first; `found` false when the script or language system is not listed |
| `inst.features(table, script, language)`               | as on the face, with the first FeatureVariations record whose condition set holds applied; `variation` names it as a `VariationChoice`                                                                                      |
| `face.featureVariationCount(table)`                    | the number of FeatureVariations records; 0 before 1.1 or for a null offset                                                                                                                                                  |
| `inst.featureVariation(table, r)`                      | `FeatureVariationRecord`: whether record `r`'s condition set `holds`; `unsupportedVersion` for a condition of a format other than 1                                                                                         |
| `face.featureSubstitutions(table, r)`                  | `FeatureSubstitutions`, a random-access range of `FontResult!FeatureSubstitution` (feature index and alternate lookups); `badValue` for a feature index past the list                                                       |
| `face.lookup(table, index)`                            | `Lookup`: `type`, `flag`, `subtableCount`, and `markFilteringSet` when the flag has `useMarkFilteringSet`; O(1)                                                                                                             |
| `face.substitutions(lookupIndex)`                      | `Substitutions`, a lazy forward range of `FontResult!Substitution` for a `GSUB` lookup                                                                                                                                      |

A format-1 condition holds when `min ≤ coord ≤ max` on the F2Dot14
coordinate, an axis past the instance's reading 0; an empty or null condition
set holds; any other format never holds. A substitution naming a feature past
the list leaves that feature its default lookups. When the FeatureVariations
table, or the chosen record's substitution table, cannot be read, every
feature at the instance returns that error.

A `Substitution` has the effective `lookupType` (never 7; `extension` says it
was wrapped), `format`, `subtable`, and `input` and `output` as
`GlyphSequence`s: an optional leading glyph followed by a borrowed run of
big-endian glyph IDs (`UInt16Run`). Types 1–3 give one glyph in, and its
substitute (format 1 as `(g + delta) mod 65,536`), sequence, or one alternate
(`alternateIndex`) out; type 4 the coverage glyph and its components in, the
ligature out. Types 5 and 6 give `lookups`, the `SequenceLookup`s the rule
invokes, never followed, with `contextInput` saying whether the input holds
glyphs (format 1), classes led by the rule set's class (format 2) or only its
count (format 3, coverages); type 6 adds `backtrack` and `lookahead`. Type 8
gives one glyph in and out with `backtrackCount` and `lookaheadCount`. A
malformed subtable, a coverage index past its subtable's array, or a record
past the table is one error element, and the walk continues; an extension of
an extension, or of a type differing from the lookup's first extension, is
its subtable's `badValue`.

## Colour — `sparkles.font.colour`

`face.colourCapability` reports which colour formats a face holds,
independent of which the library renders, reading each table's header in
O(1). The result has one `ColourSupport` per format: `present` when the face
has the table, and `has`, a `FontResult!bool` that is `false` for a table
holding no data for the format and the table's error when its header cannot
be verified (`usable` is `has` being `true`). Support is never claimed for
data that was not checked.

| Entry        | `has` is true for                                                                     |
| ------------ | ------------------------------------------------------------------------------------- |
| `colrLayers` | `COLR` version 0 or 1 with base glyph records, whose base glyph and layer arrays fit  |
| `colrPaint`  | `COLR` version 1 with a non-empty BaseGlyphList (offset at byte 14) whose records fit |
| `cpal`       | `CPAL` version 0 or 1 with palettes, whose index array and colour records fit         |
| `cbdt`       | `CBDT` with a `CBLC` holding at least one bitmap size, both of major version 2 or 3   |
| `sbix`       | `sbix` version 1 with strikes                                                         |
| `svg`        | `SVG ` version 0 with a non-empty document list                                       |

A `COLR` version above 1 is `unsupportedVersion` for both `COLR` entries,
where HarfBuzz reads it as version 1; a `CBDT` without `CBLC` is
`missingTable` naming `CBLC`, where HarfBuzz counts it. A truncated header,
or an offset outside its table, is that entry's error.

## Outlines — `sparkles.font.outlines`

Coordinates are font units, y-up, unscaled, in counts of 1/65,536 unit,
translated so the glyph's left phantom point sits at the origin — the
space `hb_font_draw_glyph` and FreeType draw in. Decoding writes into an
`OutlineWorkspace` the caller owns and never allocates; composite depth
is at most 8 with 512 components, `CFF` subroutine depth 10 with 65,536
operations (FTB3), and a composite or subroutine that refers back to itself
is a `cycle` error (FTB5). `CFF2` blends are weighed by the `vstore` item
variation store, and a `seac`-style `endchar` draws its base and accent
glyphs.

| Operation                              | Result                                                                                                                                |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `inst.glyphOutline(gid, segments, ws)` | the glyph as `OutlineSegment`s (move/line/quad/cubic/close) in the caller's array; its count, points, phantom points and overlap flag |
| `inst.drawGlyph(gid, ws, sink)`        | the same outline into any sink with `moveTo`, `lineTo`, `quadTo`, `close` (and `cubicTo`, else quadratics within 1/16 unit)           |
| `inst.glyphPoint(gid, i, ws)`          | decoded outline point `i` in glyph order                                                                                              |
| `inst.glyphBounds(gid, ws)`            | the control-point bounds, or `present` false for a point-less glyph                                                                   |
| `inst.phantomAdvance(gid, ws)`         | the horizontal advance from the varied phantom points (the no-`HVAR` advance of FTO5)                                                 |
| `inst.phantomVerticalAdvance(gid, ws)` | the vertical advance from the varied phantom points (the no-`VVAR` advance)                                                           |
| `inst.phantomTop(gid, ws)`             | the top phantom point's y: the stored `yMax` plus the top side bearing, varied (the no-`VORG` origin)                                 |
| `face.glyphOverlaps(gid)`              | whether the outline data flags `OVERLAP_SIMPLE`/`OVERLAP_COMPOUND` (FTI6)                                                             |

The point lookups decode into a `PointWorkspace`: every point of a
well-formed glyph (`maxWorkspacePoints`, 65,536) and the `gvar` scratch,
about 2.6 MiB. Make one where the caller sets up, in a
`sparkles.base.unique.Unique`, and pass it by reference; the metrics,
baseline and caret queries built on these lookups take it too. An
`OutlineWorkspace` (and a `RasterWorkspace`) carries the same `gvar`
scratch as caller arrays (`pointNumbers`, `deltaX`, `deltaY`,
`referenced`), one entry per point a sparse tuple lists;
`PointWorkspace.outline` lends its own.

A segment array that is too small fails with `limitExceeded` naming
`callerStorage` and the needed count, and so does `gvar` scratch shorter
than the points a tuple lists. At nonzero coordinates `gvar`
deltas apply to the points and the four phantom points. The segment kinds
never depend on coordinates (FTO4): every contour closes with a line back to
its start, even a zero-length one where `hb_font_draw_glyph` emits none,
unless its last segment is a `glyf` curve that ends there by construction;
a subpath that draws nothing emits nothing.

Sparse tuples infer untouched points contour by contour from the stored
coordinates, independently for each tuple. Composite tuples adjust component
placements; each child's own variation is evaluated before scaling and placement.
`USE_MY_METRICS` inherits the child's varied phantom points before that placement.

## Raster — `sparkles.font.raster`

| Operation                                                     | Result                                                                                                                 |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `inst.rasterMeasure(gid, ppem, ws, overlap)`                  | the glyph's pixel size and bearings, and the accumulation and supersample storage the workspace needs                  |
| `inst.rasterizeGlyph(gid, ppem, region, ws, policy, overlap)` | linear 8-bit coverage written into the caller's `RasterRegion` (its own stride); the same size and bearings            |
| `applyTransfer(coverage, gammaTimes256)`                      | linear coverage encoded for a display of gamma `gammaTimes256 / 256`: the power `256 / gammaTimes256`, identity at 256 |

Coverage follows the nonzero winding rule; glyphs flagged for overlap —
or every glyph under `OverlapMode.forceUnion` — approximate the union
of their contours by 4×4 supersampling (FTX9), where only a subpixel two
contours both partly cover still doubles. `FlattenPolicy.standard` subdivides
curves to 0.02 px, `freeType` reproduces FreeType's `ftgrays.c`
subdivision, and `fine` is the 0.001 px reference of FTR8. Equal glyph
keys produce byte-identical output.

The region stride must cover the glyph's row width, and the byte slice must hold
every row. Invalid or overflowing row layouts return a caller-storage error before
writing coverage, whose `needed` is the stride-aware byte count; padding between
rows is left untouched. A box reaching more than `maxRasterCoordinate` (2^27)
pixels from the pen — an extreme ppem or outline — is `arithmeticExhausted`.
`rasterizeGlyph` decodes the outline once and documents its worst-case cost
(FTB3) in terms of the box, which the caller's storage bounds.

## Colour glyphs — `sparkles.font.colour_raster`, `colr`, `bitmap`, `png`

| Operation                                                               | Result                                                                                                            |
| ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `inst.colourMeasure(gid, ppem, ws)`                                     | the glyph's `ColourGlyph`: its source (layers, `CBDT`, `sbix` or none), box, bearings and storage needs           |
| `inst.rasterizeColourGlyph(gid, ppem, palette, foreground, region, ws)` | premultiplied RGBA written into the caller's `ColourRegion`, four bytes a pixel; the same `ColourGlyph`           |
| `face.colrLayers(gid, layers)`                                          | the glyph's `COLR` version 0 layers, bottom first, into the caller's array; their count                           |
| `face.paletteCount`, `face.paletteColour(palette, entry)`               | `CPAL`'s palettes and one straight-alpha sRGB `Colour`                                                            |
| `face.bitmapGlyph(gid, ppem)`                                           | the glyph's PNG in the strike FTR7 chooses, borrowed from the face, with its strike ppem and box in strike pixels |
| `pngHeader(png)`, `decodePng(png, rgba, inflated, zlibScratch)`         | a PNG's form and storage needs; its pixels as premultiplied RGBA                                                  |

A glyph with `COLR` layers renders from them: each layer's outline is
rasterized in grayscale and composited source-over in its palette colour,
or in the caller's foreground for entry `0xFFFF`. Otherwise a `CBDT` or
`sbix` glyph renders from the smallest strike at least the requested size,
else the largest, each output pixel the area-weighted mean of the image
pixels it covers; at the strike's own size that is an exact copy. A glyph
with neither reports `ColourSource.none`, and the caller renders its
outline in grayscale.

The decoder is [`sparkles:image`](../../image/index.md)'s, with its refusals
mapped to `FontError`s: every colour type and bit depth, all five filters,
`tRNS` and Adam7; a form the format does not define is `unsupportedVersion`.
Inflation is Phobos's zlib over the caller's `pngZlibScratch` bytes, so
nothing allocates. A glyph
has at most 1,024 layers (FTB3).

## Carets — `sparkles.font.carets`

`inst.ligatureCarets(gid, cluster, horizontal, out, ws)` returns the `GDEF`
ligature carets of a glyph in record order: each with its coordinate in
design units and its `CaretProvenance` (`coordinate`, `contourPoint`
resolved through the outline, or `deviceTable` with its Device or
VariationIndex delta kept in `device`). No records is `present` false; an
unknown caret format is `unsupportedVersion`; nothing is synthesized. On
any error, including a short `out`, nothing is written. Contour points decode
into `ws`.

## Justification tables — `sparkles.font.jstf`

`JSTF` is enumerated, never executed: `face.hasJstf` (an unreadable table
is its error), `face.jstfScripts(out)`, `face.jstfScript(script)` (whether it
has extenders and a default language system, and how many of each it lists),
`face.jstfLanguages(script, out)` (the tagged language systems),
`face.jstfExtenderGlyphs(script, out)` through the script's `ExtenderGlyph`
table, and, for the default (or a named)
language system, `face.jstfPriorityCount(script, language)` priority
records. `face.jstfPriority(script, language, index)` reports a record's
eight `JstfList` lengths and whether shrinkage or extension maximum records
are attached; `face.jstfPriorityLookups(script, language, index, list, out)`
copies one list whole into caller storage. Absence is `present` false or a
count of zero; a list or record that does not fit is `truncated`. A maximum
record's lookups are `JSTF`'s own, which the engine cannot apply.

## Corrections — `sparkles.font.corrections`

`openFace(bytes, index, policy)` takes a `CorrectionPolicy`, `off` by
default: corrections are opt-in here, and the GUI stack asks for them
(FTX15). Under `apply` a face records the registry entries its signature
matches, from its directory and table headers (FTD44); under `off` every
result is the stored value. A result an entry changes carries its
`Correction`, as do the `FontError` of a table it hides.

| Entry                                           | Follows                        | Effect                                                                                |
| ----------------------------------------------- | ------------------------------ | ------------------------------------------------------------------------------------- |
| `cambriaMathMinHeights`                         | HarfBuzz `is_bad_cambria`      | `MATH`'s two minimum heights reported swapped (`MathValue.correction`)                |
| `blocklistedGdef`                               | HarfBuzz `GDEF` blocklist      | `GDEF` read as absent: classes, mark sets and carets carry the correction             |
| `arabicSimplifiedPage`, `arabicTraditionalPage` | HarfBuzz's Arabic PUA maps     | a symbol `cmap` maps Arabic scalars through the code page (`CharMap.lookup`)          |
| `requiresBytecode`                              | FreeType `tt_check_trickyness` | `face.requiresBytecode`; the rasterizer refuses the face with `unsupportedCapability` |

`correctionInfo(c)` gives an entry's identifier, engine, signature and
effect; `face.corrections` lists a face's. The data is generated from the
pinned HarfBuzz and FreeType sources by `libs/font/tools/gen_correction_data.d`.

## The catalog — `sparkles.font.catalog`, `face_record`, `catalog_cache`, `platform_fonts`

| Operation                                                         | Result                                                                                                                       |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `buildCatalog(vfs, sources, options, authority, catalog, report)` | records of every face of every listed file, over any capability VFS backend; problems as outcomes in the `BuildReport`       |
| `FontSource.files`, `directory`, `bundle`, `memory`, `platform`   | the sources; each has a unique label, and `map` or `read` access (`map` for bundle and platform files by default)            |
| `catalog.records`, `catalog.pools`, `catalog.text(s)`             | the `FaceRecord`s in source, identity and index order, and the strings, aliases, coverage and axes they refer into           |
| `catalog.family(name, into)`                                      | the records having `name` among their aliases, ignoring ASCII case                                                           |
| `describeFace(face, pools, record)`                               | one face's record: names, weight, width and style ranges, spacing, coverage, colour formats, axes, corrections, field errors |
| `listPlatformFonts(options)`                                      | the files fontconfig or Core Text lists, loaded at run time, or the Windows and Android font directories                     |

`BuildOptions.workers` sets the parsing threads (0: one per processor);
the result does not depend on it. With `cacheDirectory` set, a build reuses
the records of every file whose label, identity, size and modification time
are unchanged, and rewrites the cache atomically when anything changed; a
cache of another version, policy, length, hash or structure is discarded
whole (FTD22–FTD24). Symbolic links are followed under the authority the
build is given, at most 40.

## Matching — `sparkles.font.matching`

`matchFont(catalog, request)` implements CSS Fonts Level 4 §5.2 step 4: the
first requested family a record answers to, then width, style and weight,
each searched phase by phase over the values the records support (a
variable face supports its whole ranges). A `MatchRequest` holds family
names, weight (1–1,000), width (50–200 %), `normal`, `italic` or `oblique`
at an angle, and whether to synthesize; values are F16.16. The `Match`
carries the record, the values found, the `wdth`, `wght`, `slnt` and `ital`
coordinates, a `MatchScore` of (phase, distance) per step, and the
`Synthesis` still needed (emboldening at 1/24 em from weight 600 on a face
below 600; a slant for an italic or oblique request an upright face
answers). `found` is false when no family matches.

## Fallback chains — `sparkles.font.fallback`, `box_face`

| Operation                                             | Result                                                                                                                 |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `buildChain(catalog, primary, items, chain)`          | entries from `ChainItem.route`s, `primary`, then `family`, `boxDrawing` and `everything`; `badValue` for another order |
| `chain.characterEntry(cp, presentation)`              | the first entry covering `cp` (a route: in its ranges), preferring coloured faces for emoji presentation; or `noEntry` |
| `chain.routeEntry(cp)`                                | the route that claims `cp`: its ranges hold it and its face covers it; layout splits spans at routes (FTX16)           |
| `chain.identity`                                      | 128 bits of BLAKE3 over the catalog's keys and policy, the requests, the items and the entries                         |
| `CharacterCache!N.characterEntry(chain, cp, p)`       | the same, memoized under the chain's identity                                                                          |
| `FaceStore!V(vfs, chain, authority).face(i, outcome)` | entry `i`'s face, opened on first use; `stale` when its file changed since the build                                   |
| `store.boxFace(ppem)`                                 | the generated box-drawing face at that ppem, built from the primary's cell metrics and kept for the store's life       |
| `boxFaceMeasure(cell)`, `buildBoxFace(cell, storage)` | a TrueType font of U+0020 and U+2500–U+259F drawn on whole pixels of the cell, into caller storage                     |

A record appears once per coordinates and synthesis, so faces whose coverage
repeats an earlier one's stay in the chain for shaping. A catalog and a chain
may be read from any thread; a store and a cache belong to one.

## Whole-span trials — `sparkles.font.fallback_trial` (the `engine` configuration)

`trySpan(chain, store, request, size, policy, attempts, glyphs, spans,
boundaries, language)` shapes the run of an `FTS7` request whole, with its
context, through the chain's candidates in order, and returns the first that
gives no `.notdef` and, by default, shapes each RGI emoji sequence to one
visible glyph; otherwise an unresolved outcome with the exact run. Each
`Attempt` says why a candidate failed: `outsideRoute`, `pruned` (with the
scalar that proves `.notdef`), `bytecodeRequired`, `unopened`, `notdef` or
`unligated`. `pruningScalar` and `provesNotdef` are the pruning rule;
`trialKey` is the 128-bit key an outcome may be cached under.

## Shaping — `sparkles.font.shaping` (the `engine` configuration)

The `engine` configuration links HarfBuzz (hand-declared in
`sparkles.font.harfbuzz`, layout-checked in `sparkles:font-oracle`) and
adds shaping; the `library` configuration never sees it. A `Shaper`
owns one instance's HarfBuzz objects and releases them when destroyed.
It borrows the instance's face bytes: dip1000 keeps it from outliving
them in `@safe` code. It receives the instance's normalized coordinates
unchanged. Its horizontal and vertical advances and its vertical origins are
the library's own (`advance`, `verticalAdvance`, `verticalOrigin`), so
variation deltas are not rounded to whole units; a face with no vertical
metrics takes HarfBuzz's synthesized ones, the engine's fallback. Building a
shaper allocates its callback state, workspace included, once, in a `Unique`.

| Operation                                                         | Result                                                                                                                                                                                         |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Shaper(inst)`                                                    | a shaper; its `status` is `unsupportedEngine` or `unsupportedUnicodeVersion` when the running engine is not `pinnedEngine` (checked by `engineProfile()`), and `shape` then returns that error |
| `shaper.shape(request, glyphs, spans, boundaries, languageOut)`   | glyph IDs and `DesignValue` advances and offsets; `SourceSpan`s partitioning the run in both directions; `BoundarySafety` per span start                                                       |
| `shapeText(inst, source, glyphs, spans, boundaries, languageOut)` | the standalone form: direction, script and language guessed and reported in the `ShapeInfo`                                                                                                    |
| `measureJustificationCandidate(shaper, request, mode, …)`         | the exact re-shaped candidate for `featureSettings`; `unsupportedCapability` for the insertion modes font never performs and for `JSTF` maximum lookups                                        |
| `checkEngineProfile(manifest, version, unicode)`                  | the FTS8 check itself, for any engine version and base release                                                                                                                                 |

`sparkles.font.cluster_shaping` shapes one grapheme cluster behind a narrow
interface: `openClusterShaper(&inst)` (null when the engine cannot shape),
`shapeCluster(shaper, text, ppemNumerator, ppemDenominator, glyphs)` writing
glyph ids with their advance and offsets in pixels — at most
`maxClusterGlyphs` of them, a cluster needing more refused whole — and
`closeClusterShaper(shaper)`. The module imports the engine only inside its
function bodies, so a renderer naming these functions does not analyse the
engine's modules in its own build — which, beside ImportC modules, tripped
the frontend into naming a `ModuleInfo` those never have.

`pinnedEngine` is the FTS8 manifest: HarfBuzz 14.6.0, its source revision,
and the Unicode release of its internal tables (18.0.0, base's). Advances
and offsets are multiples of 1/1,024 font unit; `ShapeInfo.measured(value)`
gives their pixel and physical forms (FTM4, FTM6).

A `ShapeRequest` carries the whole source as context with a run range
at scalar boundaries, explicit `SegmentProperties` (a script is required)
or guessing for the standalone form, ranged `ShapingFeature`s, and
beginning/end-of-text flags. Base validates and decodes the source;
HarfBuzz receives scalars with their absolute byte offsets and five
scalars of context either side. Invalid UTF-8 is `invalidEncoding`, a
split scalar `splitScalar` at the offending edge, a bad range
`invalidRange`, a bad feature range `invalidFeatureRange`, explicit
properties without a script `badValue`, more than 512 features
`limitExceeded` naming `shapingFeatures`, and an engine allocation failure,
buffer-length limit or spent operation budget `limitExceeded` naming
`engineBuffer` — the pinned build is patched so the budget never ends a run
silently. Short glyph,
span, boundary and language arrays are `callerStorage` errors. Every
error leaves the outputs as they were.

Every Unicode callback HarfBuzz accepts is supplied from
`sparkles:base`'s tables: decomposition is one step (`canonicalMapping`).
Default ignorables are hidden, as HarfBuzz hides them. Unsafe-to-break
and unsafe-to-concat are the union of a span's glyph flags; the tatweel
hint is known only when its glyphs agree; run edges and glyphless spans
are unknown. HarfBuzz stops applying lookups silently after
max(65,536, 4,096 × scalars) operations; no API reports it.
