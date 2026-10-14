# Reference

Import everything with `import sparkles.font;`. Fallible operations return
`FontResult!T`, an `Expected` holding a value or a `FontError`. Operations on
a face are free functions callable as methods (`face.charMap`).

## Errors — `sparkles.font.errors`

| Symbol          | Meaning                                                                                                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `FontError`     | `kind`, `tag` (or none), `offset` (absolute), `tableOffset` (inside `tag`, when readable), `limit`, `limitValue` and `needed`                                                                          |
| `FontErrorKind` | `notAFont`, `truncated`, `badOffset`, `badValue`, `unsupportedVersion`, `missingTable`, `limitExceeded`, `indexOutOfRange`, `invalidEncoding`, `unsupportedCapability`, and kinds later milestones use |
| `FontLimit`     | the limits of `FTB3`: `tableRecords` (4,096), `cmapSubtables` (64), `variationAxes` (64), and the outline and colour limits; `callerStorage` with `needed`                                             |
| `Tag`           | a four-byte table tag: `Tag("head")`, `.chars`                                                                                                                                                         |

## Faces — `sparkles.font.face`

| Operation                                 | Result                                                                                     |
| ----------------------------------------- | ------------------------------------------------------------------------------------------ |
| `openFace(bytes, index = 0)`              | a `Face`; checks the container, directory, `head`, `maxp` and the `cmap` header; O(tables) |
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
| `inst.advance(gid)`                            | the `hmtx` advance plus the `HVAR` delta; `unsupportedCapability` at nonzero coordinates without `HVAR`; negative results kept                   |
| `inst.measureRun(gids)`                        | the checked design-value sum of the run's advances, converted once by the caller; the first error, `arithmeticExhausted` on overflow             |
| `inst.cellMetrics(cmap, ppem)`                 | `CellMetrics` in whole pixels: width (and `widthSource`), ascent, descent, line gap, height, baseline, underline                                 |
| `face.hvar(axes)`, `hvar.advanceDelta(gid, …)` | the `HVAR` view (major 1; a null advance map is the identity on the glyph ID) and one advance delta                                              |
| `face.mvar(axes)`, `mvar.delta(tag, …)`        | the `MVAR` view (major 1, `valueRecordSize` ≥ 8) and one value's delta by binary search; a tag with no record is zero                            |

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

| Operation                                        | Result                                                                                                                                                                    |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `face.vhea`                                      | `Vhea`, version 1.0 or 1.1 (fields as stored), at least 36 bytes; another version `unsupportedVersion`                                                                    |
| `face.vmtx`, `vmtx.metric(gid)`                  | `VerticalMetric` (advance height, top side bearing) with `hmtx`'s leniency: `numOfLongVerMetrics` capped at `numGlyphs`, the last advance repeated, `truncated` per glyph |
| `face.vorg`, `vorg.originY(gid)`                 | `VORG` 1.0; a glyph's record by binary search, else `defaultVertOriginY`, with `fromRecord`                                                                               |
| `face.vvar(axes)`, `advanceDelta`, `originDelta` | the `VVAR` view (major 1): advance-height map (null is the identity) and vertical-origin map; side-bearing maps are not read                                              |
| `inst.verticalLineMetrics`                       | `vhea` ascender, descender and line gap plus the `vasc`, `vdsc`, `vlgp` deltas; absent without `vhea`                                                                     |
| `inst.verticalAdvance(gid)`                      | the `vmtx` advance plus the `VVAR` delta; absent without `vhea` or `vmtx`; `unsupportedCapability` at nonzero coordinates without `VVAR`                                  |
| `inst.verticalOrigin(gid)`                       | `VerticalOrigin`: `y`, its `source` (`vorgRecord`, `vorgDefault`, or `none` when absent) and whether a `VVAR` origin delta was added (`varied`)                           |

`verticalOrigin` follows the specification's table: `VORG` 1.0 answers, plus
the `VVAR` origin delta when `VVAR` has an origin map; another `VORG` version
is `unsupportedVersion`; a face without `VORG` but with `vmtx` and `glyf` is
`unsupportedCapability` until outlines give each glyph's `yMax`; any other
face has no origin, and a layout that needs one chooses its own fallback. A
caller's glyph ID past `numGlyphs` is `indexOutOfRange` for both glyph
queries. At all-zero coordinates neither `VVAR` nor `MVAR` is read.
