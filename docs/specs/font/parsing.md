---
status: draft
owner: sparkles:font
reviewed:
---

# `sparkles:font` — Parsing operations (M1)

## Abstract

This page states, operation by operation, what milestone M1 of
[`sparkles:font`](./SPEC.md) delivers: opening a face from borrowed bytes,
finding its tables, reading the typed tables, mapping characters to glyphs,
decoding names, naming glyphs and classifying spacing. For each operation it
fixes the accepted inputs, the result, how long results borrow the font bytes,
every error and when it is raised, and the work and allocation bounds. None of
these operations allocates or asserts on font data. Structural damage to
`head`, `maxp` or `cmap` refuses the face; damage anywhere else is reported
where it is read, and the rest of the face stays usable.

## Introduction

[`SPEC.md`](./SPEC.md) § 7 states what parsing must achieve, in requirements
`FTP1`–`FTP12`. That level is enough to agree on scope but not to write code
or tests against: it does not say whether a lookup validates a `cmap`
subtable on every call, what happens to a `cmap` entry that names a glyph the
font does not have, or how a glyph name is found in `post` without scanning
the whole table. Each such choice changes a cost bound or an error, so each is
made here.

The operations share three rules. A face is an immutable value over borrowed
bytes. Anything that needs validation proportional to a table's size, such as
a character map, is a separate value built once by an explicit call, never a
cache hidden in the face ([`FTA5`](./SPEC.md#_5-objects-and-ownership)). Any
storage an operation needs beyond its result value comes from the caller.

This page covers the M1 obligations in [`PLAN.md`](./PLAN.md#m1-parse).
Variation, metrics and outlines are later milestones; where M1 only parses a
table that a later milestone applies, such as `fvar` and `avar`, the
application rules are not stated here. Operation names are proposed, not
delivered symbols.

## Contract at a glance

1. **A face is a borrowed, immutable value.** Copying it copies a slice and a
   few integers; every slice it returns borrows the caller's buffer.
2. **Open is cheap and strict only where it must be.** Opening reads the
   directory, `head`, `maxp` and the `cmap` header, and fails only when one of
   those cannot be read.
3. **Validation happens once, in a value.** A character map or glyph-name
   index is validated when it is built, then answers lookups without
   revalidating.
4. **Errors name a place.** Every error carries a kind, a table tag where one
   applies, and an offset.
5. **Nothing allocates.** Results are values or borrowed slices; text and
   indexes go into caller storage, sized by a measuring call first.

## 1. Common rules

**FTP14: Error location.** A `FontError` **must** carry its kind, the tag of
the table being read or none, and a byte offset. The offset is relative to the
start of that table when a tag is present, and to the start of the buffer
otherwise. For a collection, buffer offsets are relative to the whole file.

**FTP15: Caller arguments versus data.** A glyph ID, record index, codepoint
or tag supplied by the caller is data, not a precondition: an out-of-range
value **must** return `indexOutOfRange` (glyph IDs, record indices) or a
documented absence (codepoints, tags), never an assertion. Preconditions
**may** apply only to arguments no font can produce, such as a destination
slice aliasing the font buffer, and each is documented on its operation.

**FTP16: Borrowing.** Every slice an operation returns **must** be a subslice
of the buffer the face was opened from, or of caller storage passed to that
call, and is typed `return scope` so that `-preview=dip1000` ties its lifetime
to that buffer. No operation **may** return a slice of a temporary.

**FTP17: Integer reads.** All reads **must** go through bounds-checked
big-endian accessors that return an error rather than read past the slice.
Offset arithmetic **must** be done in 64-bit integers or checked, so that an
offset plus a length that overflows 32 bits is `badOffset`, not a wrapped
value.

## 2. Opening

Proposed operations: `openFace(bytes, index = 0)` returns a `Face`;
`openCollection(bytes)` returns a `Collection`, whose `count` is the number of
faces and whose `face(i)` returns a `Face`.

**FTP18: What opening checks.** `openFace` **must**, in this order: detect the
container (`FTP1`); for a collection, read the header and select face `index`
(`FTP2`); read the table directory (`FTP3`); then read `head`, `maxp` and the
`cmap` header. It **must** fail with the first error from those steps, and
**must not** read any other table.

| Step              | Accepted                                                                 | Refused                                                                                                                            |
| ----------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Signature         | `0x00010000`, `true`, `OTTO`, `ttcf`                                     | `wOFF`, `wOF2`: `unsupportedVersion`; fewer than 4 bytes: `truncated`; anything else: `notAFont`                                   |
| Collection header | version 1.0 or 2.0, at most 65,535 faces, offset array inside the buffer | other major versions: `unsupportedVersion`; more faces: `badValue`; array outside: `truncated`; `index ≥ count`: `indexOutOfRange` |
| Directory         | at most 4,096 records, all inside the buffer                             | more records: `limitExceeded`; records outside: `truncated`                                                                        |
| A table record    | offset plus length inside the buffer, tag not seen before                | that table only becomes unreadable, `badOffset`; a later duplicate tag is ignored and reported (`FTP21`)                           |
| `head`            | at least 54 bytes, `unitsPerEm` not zero, `indexToLocFormat` 0 or 1      | missing: `missingTable`; short: `truncated`; zero `unitsPerEm` or another `indexToLocFormat`: `badValue`                           |
| `maxp`            | version 0.5 with at least 6 bytes, or 1.0 with at least 32               | missing: `missingTable`; short: `truncated`; other versions: `unsupportedVersion`                                                  |
| `cmap` header     | version 0, at most 64 encoding records, all inside the table             | missing: `missingTable`; more records: `limitExceeded`; records outside: `truncated`                                               |

A `head`, `maxp` or `cmap` record that is itself unreadable under the table
record rule fails the open with that record's `badOffset`. The directory's
`searchRange`, `entrySelector` and `rangeShift` fields, and `head`'s magic
number, are not checked at open; inspection reports them (`FTP33`).

_Rationale:_ These are the values every later operation needs: the glyph count
bounds every glyph ID, `unitsPerEm` every scale, `indexToLocFormat` every
`glyf` lookup, and `cmap` every text operation. A font without them cannot be
shown at all; a font with a broken `kern` or `GPOS` can still be inspected.

**FTP19: Directory limit.** A directory **must not** be read beyond 4,096
records. This is a limit under [`FTB3`](./SPEC.md#_4-trust-boundary).

_Rationale:_ Detecting duplicate tags in an unsorted directory without
allocating is quadratic; 4,096 records bound it at about eight million
comparisons, and no surveyed font has more than a few dozen tables.

**FTP20: Opening cost.** `openFace` **must** run in O(r) time for a sorted
directory of `r` records, and O(r²) for an unsorted one, plus constant work
for `head`, `maxp` and the `cmap` header. It **must not** allocate. The
returned `Face` **must** record whether the directory is sorted by tag, so that
table lookup (`FTP22`) can choose binary search.

**FTP21: Duplicate tags.** When two records share a tag, the first in
directory order **must** be the table, and each later one **must** be reported
by directory enumeration (`FTP33`) as a duplicate. A duplicated `head`, `maxp`
or `cmap` does not fail the open.

## 3. Tables

**FTP22: Table lookup.** `face.table(tag)` **must** return the table's bytes
as a borrowed slice, `missingTable` when no record has the tag, or the
record's `badOffset` when it is unreadable. It **must** cost O(log r) on a
sorted directory and O(r) otherwise, and **must not** allocate.

**FTP23: Typed table views.** `face.head`, `hhea`, `maxp`, `os2`, `post`,
`name`, `hmtx`, `cmap`, `fvar`, `avar` and `STAT` **must** each return a plain
struct, or an error from this table:

| Table  | Readable when                                                                                                 | Versions                                                         | Notes                                                                                                                                     |
| ------ | ------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `head` | checked at open                                                                                               | 1.0                                                              | Fields as stored, including the magic number.                                                                                             |
| `hhea` | at least 36 bytes                                                                                             | 1.0                                                              | `numberOfHMetrics` of 0 with a nonzero glyph count makes `hmtx` unreadable, not `hhea`.                                                   |
| `maxp` | checked at open                                                                                               | 0.5, 1.0                                                         | Version 0.5 reports only `numGlyphs`; the other fields are absent.                                                                        |
| `OS/2` | at least 78 bytes, plus 8 for version 1, 18 for versions 2–4, 22 for version 5                                | 0–5; a later version is read as version 5 and reports its number | A version shorter than its own fields is `truncated`, as in HarfBuzz.                                                                     |
| `post` | at least 32 bytes                                                                                             | 1.0, 2.0, 2.5, 3.0                                               | Other versions: header readable, names `unsupportedVersion`.                                                                              |
| `name` | header and record array inside the table                                                                      | 0, 1                                                             | Records are read under `FTP26`.                                                                                                           |
| `hmtx` | `4·numberOfHMetrics + 2·(numGlyphs − numberOfHMetrics)` bytes, `numberOfHMetrics` between 1 and `numGlyphs`   | —                                                                | A view with `advance(gid)` and `lsb(gid)`.                                                                                                |
| `cmap` | checked at open                                                                                               | 0                                                                | A view of encoding records; mapping is `FTP24`.                                                                                           |
| `fvar` | header inside the table, version 1.0, `axisSize` 20, `instanceSize` `4·axisCount + 4` or `+ 6`, arrays inside | 1.0                                                              | An axis whose minimum, default and maximum are out of order is a `badValue` entry; other axes stay readable (`FTA11`).                    |
| `avar` | version 1.0, one segment map per `fvar` axis, every map inside the table                                      | 1.0; version 2 is `unsupportedVersion` in M1                     | A map whose `fromCoordinate` values decrease is a `badValue` entry.                                                                       |
| `STAT` | header, design-axis array and axis-value offset array inside the table                                        | 1.0, 1.1, 1.2                                                    | Axis value tables of formats 1–4 are entries; another format or one outside the table is an error entry. `elidedFallbackNameID` from 1.1. |

Each view **must** cost constant time to obtain, except that `fvar`, `avar`
and `STAT` **may** walk their arrays once, in time linear in the table's
length. Fields a version lacks hold the defaults that OpenType documents, and
the view reports which version supplied them.

**FTP24: Character map value.** `face.charMap()` **must** select a subtable by
the order of `FTP9`, validate it, and return a `CharMap` value or an error.
Validation **must** cost time linear in the subtable's length and **must not**
allocate. Lookups on the value **must** then cost O(log n) in its segment or
group count, without validating again.

| Format | Validated at `charMap()`                                                                                                                                                         |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0      | 262 bytes inside the table.                                                                                                                                                      |
| 4      | `segCountX2` even and nonzero; all four arrays inside the subtable; `endCode` ascending; each segment's `startCode ≤ endCode`; every `idRangeOffset` target inside the subtable. |
| 6      | `entryCount` entries inside the subtable.                                                                                                                                        |
| 12, 13 | groups inside the subtable, each with `start ≤ end ≤ 0x10FFFF`, ascending and not overlapping.                                                                                   |
| 14     | validated by `charMap()` when present, separately: variation-selector records ascending, their default and non-default tables inside the subtable and ascending.                 |

If the preferred subtable fails validation, `charMap()` **must** return that
subtable's error; it **must not** fall back silently to the next candidate.
The `CharMap` **must** report the platform, encoding and format it chose.

_Rationale:_ Falling back would show a different repertoire without telling
the user why. A face whose preferred `cmap` subtable is broken is exactly the
case an inspector must surface; a renderer that prefers to degrade can ask for
a specific subtable by index (`FTP25`).

**FTP25: Lookups.** `charMap.glyph(cp)` **must** return the glyph ID for a
codepoint, or 0 when unmapped. A mapping to a glyph ID not below `numGlyphs`
**must** be treated as unmapped, and `charMap()` **must** count such mappings
and report the count with the value. `charMap.variant(cp, selector)` **must**
return `glyph(g)`, `useDefault` or `none` from format 14.
`face.charMapAt(i)` **must** build a `CharMap` from encoding record `i` for an
inspector or a degrading renderer, with the same validation.

**FTP26: Coverage ranges.** `charMap.ranges()` **must** be a forward range of
sorted, merged, non-overlapping codepoint ranges whose every codepoint has a
glyph other than 0 below `numGlyphs`. It **must** cost time linear in the
subtable's length in total and **must not** allocate. A format-4 segment with
`idRangeOffset` 0 contributes at most two ranges: its glyph IDs run
consecutively modulo 65536, so the codepoints that land on glyphs 1 to
`numGlyphs − 1` form at most two intervals.

## 4. Names and text

**FTP27: Name records.** `name.records` **must** be a random-access range of
`Expected!NameRecord`, one per stored record. A record whose string lies outside
the storage area **must** be a `badOffset` entry; the other records stay
readable (`FTA11`). A `NameRecord` carries its platform, encoding, language,
name ID and raw bytes. In version 1, a language ID of `0x8000` or above
**must** resolve to the language-tag record it indexes, or be an
`indexOutOfRange` entry.

**FTP28: Measured decoding.** `record.decodedLength()` **must** return the
UTF-8 length of the decoded text, and `record.decode(char[] dest)` **must**
write it into `dest` and return the written slice. Decoding **must** validate
the whole record before writing anything; on any error, `dest` **must** be
left unchanged. A destination shorter than the decoded length **must** return
`limitExceeded`. UTF-16BE records **must** decode through base's strict
codec (`FTA15`): an odd byte count or an unpaired surrogate is
`invalidEncoding` with the offset of the offending code unit. Mac Roman
records map each byte through a fixed 128-entry table to a scalar and encode it
with base's UTF-8 encoder. Any other encoding **must** return
`unsupportedCapability`, leaving the raw bytes available.

_Rationale:_ The Mac Roman table is a legacy character set, not a Unicode
algorithm, so it does not compete with base's ownership of UTF; base still
does the encoding.

**FTP29: Glyph names from `post`.** `face.glyphName(gid)` **must** return the
name of a glyph from `post` version 1.0, 2.0 or 2.5 as a borrowed slice: a
standard Macintosh name from a static table, or a Pascal string in `post`.
For version 2.0 it **may** scan the string data, costing time linear in the
table's length. `face.glyphNameIndex(uint[] scratch)` **must** build, in the
caller's `scratch`, an index of the string offsets that makes each later
lookup constant time; it **must** return `limitExceeded` when `scratch` holds
fewer entries than there are strings, and report how many it needs. A
`glyphNameIndex` value borrows both the face's buffer and `scratch`.

| Situation                                          | Result                                        |
| -------------------------------------------------- | --------------------------------------------- |
| `post` 3.0, or no `post`, and no `CFF` charset     | absent, not an error                          |
| `post` 2.0 whose `numGlyphs` differs from `maxp`'s | names read for the smaller count; reported    |
| a name index pointing past the stored strings      | `badOffset` for that glyph only               |
| a Pascal string running past the table             | `truncated` for that glyph and those after it |
| `gid ≥ numGlyphs`                                  | `indexOutOfRange`                             |

**FTP30: Glyph names from `CFF`.** For a face with `CFF` outlines and no usable
`post` names, `face.glyphName(gid)` **must** read the name from the `CFF`
charset: the header, the Name, Top DICT and String INDEXes, and charset
formats 0, 1 and 2, resolving each SID through the 391 standard strings or the
String INDEX. A CID-keyed `CFF` (its Top DICT has `ROS`) and a `CFF2` font
**must** report no names. Reading **must** cost time linear in the `CFF`
header, the INDEXes it walks and the charset, and **must not** allocate.

## 5. Classification and inspection

**FTP31: Spacing classification.** `face.spacing()` **must** walk `hmtx`
once and classify the face under `FTP12` as `mono`, `dual` or
`proportional`, together with the distinct nonzero advances found when there
are at most two. An unreadable `hmtx` **must** return its error, not a
classification.

**FTP32: Reflectable tables.** Every view of `FTP23` **must** be a plain
struct whose fields carry the OpenType names, so a `sparkles:reflection` walk
lists them (`FTI1`). Fields absent in the stored version **must** be
distinguishable from fields that hold zero.

**FTP33: Directory inspection.** `face.directory` **must** be a random-access
range with one entry per stored record, in directory order, carrying the tag,
offset, length, stored checksum, whether the record is readable and whether it
is a duplicate (`FTI5`). `entry.computedChecksum()` **must** compute the
checksum on request, in time linear in the table's length, treating `head`'s
`checkSumAdjustment` as zero. `face.checkSumAdjustment()` **must** compare the
stored value with the value computed over the whole face. The directory search
fields and `head`'s magic number **must** be reported with their expected
values. A mismatch in any of these **must not** affect any other operation
(`FTP4`).

## 6. Oracles

| Operations               | Oracle                                                                                                                      |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| `FTP18`–`FTP23`, `FTP33` | HarfBuzz's table sanitizers and `hb_face_get_upem`/`hb_face_get_glyph_count`; hostile-input fixtures for every refusal row. |
| `FTP24`–`FTP26`          | `hb_font_get_nominal_glyph`, `hb_font_get_variation_glyph` and `hb_face_collect_unicodes` over every bundled face.          |
| `FTP27`, `FTP28`         | `hb_ot_name_get_utf8` for well-formed records; hand-built malformed UTF-16 fixtures.                                        |
| `FTP29`, `FTP30`         | `hb_font_get_glyph_name` over every glyph of every bundled face.                                                            |
| `FTP31`                  | Hand-derived from `hmtx` dumps of the bundled faces.                                                                        |

The oracles and fixtures are described in [`testing.md`](./testing.md).
