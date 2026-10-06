# Reference

Import everything with `import sparkles.font;`. Fallible operations return
`FontResult!T`, an `Expected` holding a value or a `FontError`. Operations on
a face are free functions callable as methods (`face.charMap`).

## Errors — `sparkles.font.errors`

| Symbol          | Meaning                                                                                                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `FontError`     | `kind`, `tag` (or none), `offset` (absolute), `tableOffset` (inside `tag`, when readable), `limit` and `limitValue`                                                                                    |
| `FontErrorKind` | `notAFont`, `truncated`, `badOffset`, `badValue`, `unsupportedVersion`, `missingTable`, `limitExceeded`, `indexOutOfRange`, `invalidEncoding`, `unsupportedCapability`, and kinds later milestones use |
| `FontLimit`     | the limits of `FTB3`: `tableRecords` (4,096), `cmapSubtables` (64), and the outline and colour limits; `none` for caller storage                                                                       |
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
