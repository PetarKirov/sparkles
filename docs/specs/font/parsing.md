---
status: accepted
owner: sparkles:font
reviewed: 2026-10-06
---

# `sparkles:font` — Parsing operations (M1)

## Abstract

This page states, operation by operation, what milestone M1 of
[`sparkles:font`](./SPEC.md) delivers: opening a face from borrowed bytes,
finding its tables, reading the typed tables, mapping characters to glyphs,
decoding names, naming glyphs and classifying spacing. For each operation it
fixes the accepted inputs, the result, how long results borrow the font bytes,
every error and its trigger, and the work and allocation bounds. None of these
operations allocates or asserts on font data. Structural damage to `head`,
`maxp` or `cmap` refuses the face; damage anywhere else is reported where it
is read, and the rest of the face stays usable.

## Introduction

[`SPEC.md`](./SPEC.md) § 7 states what parsing must achieve, in requirements
`FTP1`–`FTP12`. That level is enough to agree on scope but not to write code
or tests against: it does not say whether a lookup validates a `cmap`
subtable on every call, what happens to a `cmap` entry that names a glyph the
font does not have, or how a glyph name is found in `post` without scanning
the whole table. Each such choice changes a cost bound or an error, so each is
made here.

Real fonts are often slightly wrong, and the two engines this library is
tested against tolerate the common mistakes: a `cmap` subtable whose `length`
field is too large, format-4 segments that overlap, an unsorted table
directory. Where this page is lenient it says so and follows those engines;
where it is stricter, § 6 lists the difference so that a differential test
does not fail by design.

The operations share three rules. A face is an immutable value over borrowed
bytes. Anything that needs validation proportional to a table's size, such as
a character map, is a separate value built once by an explicit call, never a
cache hidden in the face ([`FTA5`](./SPEC.md#_5-objects-and-ownership)). Any
storage an operation needs beyond its result value comes from the caller.

This page covers the M1 obligations in [`PLAN.md`](./PLAN.md#m1-parse).
`FTP13` (`MATH`) is an M2 obligation and is not refined here. Where M1 only
parses a table that a later milestone applies, such as `fvar` and `avar`, the
application rules are not stated. Operation names are proposed, not delivered
symbols.

## Contract at a glance

1. **A face is a borrowed, immutable value.** Copying it copies a slice and a
   few integers; every slice it returns borrows the caller's buffer or
   immutable static data.
2. **Open is cheap and strict only where it must be.** Opening reads the
   directory, `head`, `maxp` and the `cmap` header in time linear in the
   number of tables, and fails only when one of those cannot be read.
3. **Validation happens once, in a value.** A character map or glyph-name
   index is validated when it is built, then answers lookups without
   revalidating.
4. **Lenient where real fonts are wrong, and never silent about it.** A
   rejected `cmap` subtable or a mapping to a missing glyph is counted and
   reported, not hidden.
5. **Nothing allocates.** Results are values or borrowed slices; text and
   indexes go into caller storage, sized by a measuring call first.

## 1. Common rules

**FTP14: Error location.** A `FontError` **must** carry its kind, the tag of
the table being read or none, and the absolute byte offset in the buffer
where the problem was found. An error inside a readable table **must** also
carry the offset relative to that table's start. A `limitExceeded` error
**must** identify which limit of [`FTB3`](./SPEC.md#_4-trust-boundary) was
exceeded and its value.

**FTP15: Caller arguments versus data.** A glyph ID, record index, codepoint
or tag supplied by the caller is data, not a precondition: an out-of-range
glyph ID or record index **must** return `indexOutOfRange`, and an unknown
codepoint or tag its documented absence, never an assertion. Preconditions
**may** apply only to arguments no font can produce, such as a destination
slice that overlaps the font buffer, and each is documented on its operation.

**FTP16: Borrowing.** Every slice an operation returns **must** be a subslice
of the buffer the face was opened from, of caller storage passed to that call,
or of immutable static data such as the standard glyph-name tables. Slices of
the first two kinds are typed `return scope`, so `-preview=dip1000` ties their
lifetime to the storage. No operation **may** return a slice of a temporary.

**FTP17: Integer reads.** All reads **must** go through bounds-checked
big-endian accessors that return an error rather than read past the slice.
Offset arithmetic **must** be done in 64-bit integers or checked, so that an
offset plus a length that overflows 32 bits is `badOffset`, not a wrapped
value. Glyph-ID arithmetic, such as a format-12 group's start glyph plus a
codepoint's distance from the group start, **must** be checked the same way;
a result past 32 bits is a glyph ID not below `numGlyphs`.

## 2. Opening

Proposed operations: `openFace(bytes, index = 0)` returns a `Face`;
`openCollection(bytes)` returns a `Collection`, whose `count` is the number of
faces and whose `face(i)` returns a `Face`.

**FTP18: What opening checks.** `openFace` **must**, in this order: detect the
container (`FTP1`); for a collection, read the header and select face `index`
(`FTP2`); read the table directory (`FTP3`); then read `head`, `maxp` and the
`cmap` header. It **must** fail with the first error from those steps, and
**must not** read any other table.

| Step              | Accepted                                                                   | Refused                                                                                                                                         |
| ----------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Signature         | `0x00010000`, `true`, `OTTO`, `ttcf`                                       | `wOFF`, `wOF2`: `unsupportedVersion`; fewer than 4 bytes: `truncated`; anything else: `notAFont`                                                |
| Face index        | a collection: `index < count`; any other file: `index` 0                   | `indexOutOfRange`                                                                                                                               |
| Collection header | major version 1 or 2, at most 65,535 faces, offset array inside the buffer | other major versions: `unsupportedVersion`; more faces: `badValue`; array outside: `truncated`                                                  |
| Directory         | at most 4,096 records, all inside the buffer                               | more records: `limitExceeded`; records outside: `truncated`                                                                                     |
| A table record    | offset plus length inside the buffer                                       | that table only becomes unreadable, `badOffset`                                                                                                 |
| `head`            | at least 54 bytes, major version 1, `unitsPerEm` not zero                  | missing: `missingTable`; short: `truncated`; other major version: `unsupportedVersion`; zero `unitsPerEm`: `badValue`                           |
| `maxp`            | version 0.5 with at least 6 bytes, or 1.0 with at least 32                 | missing: `missingTable`; short: `truncated`; other versions: `unsupportedVersion`                                                               |
| `cmap` header     | version 0, at most 64 encoding records, the record array inside the table  | missing: `missingTable`; more records: `limitExceeded`; record array outside the table: `truncated`. A subtable offset is not followed at open. |

A `head`, `maxp` or `cmap` record that is unreadable under the table-record
rule fails the open with that record's `badOffset`. Nothing else is checked at
open: the directory's search fields, `head`'s magic number and
`indexToLocFormat` are reported by inspection (`FTP33`) and checked by the
operations that use them.

_Rationale:_ These are the values every later operation needs: the glyph count
bounds every glyph ID, `unitsPerEm` every scale, and `cmap` every text
operation. A font without them cannot be shown at all; a font with a broken
`kern` or `GPOS` can still be inspected. `indexToLocFormat` matters only to
`glyf`, which a `CFF` face never reads.

**FTP19: Directory limit.** A directory **must not** be read beyond 4,096
records. This is a limit under [`FTB3`](./SPEC.md#_4-trust-boundary).

_Rationale:_ The limit bounds the quadratic duplicate check of directory
inspection (`FTP33`) at about eight million comparisons. Of 2,402 faces
measured on 2026-10-05 (every font fontconfig lists on a Linux desktop, plus
the bundle), none has more than 23 tables.

**FTP20: Opening cost.** `openFace` **must** run in O(r) time for `r`
directory records, plus constant work for `head`, `maxp` and the `cmap`
header, and **must not** allocate (`FTP5`). The returned `Face` **must**
record whether the directory is sorted by tag.

**FTP21: Duplicate tags.** When two records share a tag, the first in
directory order **must** be the table every operation reads. Later records
with that tag are reported by inspection (`FTP33`) and are otherwise ignored;
a duplicated `head`, `maxp` or `cmap` does not fail the open.

## 3. Tables

**FTP22: Table lookup.** `face.table(tag)` **must** return the first record's
table as a borrowed slice, `missingTable` when no record has the tag, or that
record's `badOffset` when it is unreadable. On a sorted directory it **must**
binary-search and then step back to the first record with that tag, costing
O(log r) plus the number of duplicates; otherwise it **must** scan linearly,
costing O(r). It **must not** allocate.

**FTP23: Typed table views.** `face.head`, `hhea`, `maxp`, `os2`, `post`,
`name`, `hmtx`, `cmap`, `fvar`, `avar` and `STAT` **must** each return a plain
struct, or an error from this table:

| Table  | Readable when                                                                                                          | Versions                                                         | Notes                                                                                                                                                                                  |
| ------ | ---------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `head` | checked at open                                                                                                        | 1.x                                                              | Fields as stored, including the magic number and `indexToLocFormat`.                                                                                                                   |
| `hhea` | at least 36 bytes                                                                                                      | 1.0                                                              |                                                                                                                                                                                        |
| `maxp` | checked at open                                                                                                        | 0.5, 1.0                                                         | Version 0.5 reports only `numGlyphs`; the other fields are absent.                                                                                                                     |
| `OS/2` | at least 78 bytes, plus 8 for version 1, 18 for versions 2–4, 22 for version 5                                         | 0–5; a later version is read as version 5 and reports its number | A version shorter than its own fields is `truncated`, as in HarfBuzz.                                                                                                                  |
| `post` | at least 32 bytes                                                                                                      | 1.0, 2.0, 2.5, 3.0                                               | Other versions: header readable, names `unsupportedVersion`.                                                                                                                           |
| `name` | header and record array inside the table                                                                               | 0, 1                                                             | Records are read under `FTP28`.                                                                                                                                                        |
| `hmtx` | `hhea` readable and `numberOfHMetrics` at least 1                                                                      | —                                                                | A view with `advance(gid)` and `lsb(gid)` under `FTP24`.                                                                                                                               |
| `cmap` | checked at open                                                                                                        | 0                                                                | A view of encoding records; mapping is `FTP25`.                                                                                                                                        |
| `fvar` | header inside the table, major version 1, `axisSize` 20, `instanceSize` at least `4·axisCount + 4`, both arrays inside | 1.x                                                              | An instance carries `postScriptNameID` when `instanceSize` is at least `4·axisCount + 6`. An axis whose minimum, default and maximum are out of order is a `badValue` entry (`FTA11`). |
| `avar` | major version 1, its own axis count, every segment map inside the table                                                | 1.0; version 2 is `unsupportedVersion` in M1                     | A map whose `fromCoordinate` values decrease is a `badValue` entry. Matching maps to `fvar` axes is M2's.                                                                              |
| `STAT` | header, design-axis array and axis-value offset array inside the table                                                 | 1.0, 1.1, 1.2                                                    | Axis value tables of formats 1–4 are entries; another format or one outside the table is an error entry. `elidedFallbackNameID` from 1.1.                                              |

Each view **must** cost constant time to obtain, except that `fvar`, `avar`
and `STAT` **may** walk their arrays once, in time linear in the table's
length. Fields a version lacks hold the defaults that OpenType documents, and
the view reports which version supplied them.

**FTP24: Horizontal metrics.** `hmtx.advance(gid)` and `hmtx.lsb(gid)`
**must** return `indexOutOfRange` for `gid ≥ numGlyphs`. A `numberOfHMetrics`
larger than `numGlyphs` **must** be read as `numGlyphs`. A glyph at or beyond
`numberOfHMetrics` **must** take the advance of the last long metric and its
own left side bearing. A glyph whose entry lies past the end of the table
**must** return `truncated` for that glyph only.

## 4. Character mapping

**FTP25: Subtable choice.** `face.charMap()` **must** try the `cmap` encoding
records in this order and return a `CharMap` value for the first whose
subtable passes the checks of `FTP26`:

| Order | Platform and encoding        | How codepoints are looked up                                                                                    |
| ----- | ---------------------------- | --------------------------------------------------------------------------------------------------------------- |
| 1     | 3/0 (symbol)                 | directly; a codepoint up to U+00FF that is not mapped directly is looked up again at U+F000 plus the codepoint  |
| 2     | 3/10, then 0/6, then 0/4     | directly                                                                                                        |
| 3     | 3/1, then 0/3, 0/2, 0/1, 0/0 | directly                                                                                                        |
| 4     | 1/0 (Macintosh Roman)        | the codepoint is converted to its Mac Roman byte, which is looked up; codepoints outside Mac Roman are unmapped |
| 5     | any other platform-1 record  | codepoints up to U+007F only                                                                                    |

When a record fails its checks, `charMap()` **must** move to the next and
record the failure: the value carries the number of rejected records and the
first rejection's error. When no record qualifies, `charMap()` **must**
return `unsupportedCapability` naming `cmap`; each record's own error is
then available from `charMapAt`. The `CharMap` reports the platform, encoding and
format it chose. `face.charMapAt(i)` **must** build a `CharMap` from encoding
record `i` alone, with the same checks and no fallback, for an inspector.
This order replaces the one in `FTP9` and is HarfBuzz's.

_Rationale:_ HarfBuzz and FreeType both skip a broken subtable for the next
one, and a renderer that refused the face would show nothing where both
engines show text. Counting and keeping the rejection is what makes the
fallback visible to an inspector. Symbol fonts put their glyphs at
U+F000–U+F0FF; Windows also reaches them at U+0000–U+00FF, which is why
HarfBuzz does.

**FTP26: Subtable checks.** Building a `CharMap` **must** check its subtable
as follows and **must not** allocate. A subtable's `length` field **must** be
replaced by the distance to the end of `cmap` when that is shorter or longer,
as in FreeType.

| Format              | Checked                                                                                                                      | Refused with                                                    |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| 0                   | 262 bytes inside `cmap`                                                                                                      | `truncated`                                                     |
| 4                   | `segCountX2` even and nonzero; the four arrays inside `cmap`; `endCode` non-decreasing; each segment's `startCode ≤ endCode` | `badValue` for the counts and order, `truncated` for the arrays |
| 6                   | `entryCount` entries inside `cmap`; `firstCode + entryCount` at most 65,536                                                  | `truncated`, `badValue`                                         |
| 12, 13              | groups inside `cmap`, each with `start ≤ end`; starts ascending and ends non-decreasing                                      | `badValue`, `truncated`                                         |
| 2, 8, 10 and others | —                                                                                                                            | `unsupportedVersion`                                            |

Format-4 segments may overlap, as some CJK fonts' do: a segment's effective
span **must** be `[max(startCode, previous endCode + 1), endCode]`, which
gives sorted, disjoint spans and matches what a binary search on `endCode`
finds. A format-12 or format-13 group ending past U+10FFFF **must** be
clamped to U+10FFFF. Overlapping groups take the same effective spans, which
stay disjoint because their ends never decrease. A
format-4 `idRangeOffset` whose target lies outside `cmap`, including the
sentinel segment's, **must** make the codepoints it covers unmapped rather
than refuse the subtable. Building the value **must** count every mapping to
a glyph ID not below `numGlyphs`, and every codepoint made unmapped by an
out-of-range target, and report both counts. It **must** cost O(L + 65,536)
for a subtable of `L` bytes, since effective spans are disjoint.

**FTP27: Lookups and coverage.** On a `CharMap`, `glyph(cp)` **must** return
the glyph ID for a codepoint, or 0 when unmapped, and a mapping to a glyph ID
not below `numGlyphs` **must** read as unmapped. It **must** cost O(log n) in
the segment or group count. `ranges()` **must** be a forward range of sorted,
merged, disjoint codepoint ranges, exactly the codepoints for which
`glyph(cp)` is not 0, costing O(L + 65,536) in total and not allocating.
`variant(cp, selector)` **must** return `glyph(g)`, `useDefault` or `none`
from format 14, when the face has a 0/5 record; a non-default mapping to a
glyph not below `numGlyphs` reads as `none`. A
format-14 subtable whose records or tables lie outside `cmap` (`truncated`),
or whose selectors or ranges do not ascend (`badValue`), **must** make
`variant` return that error while `glyph` and `ranges` keep working.

## 5. Names and text

**FTP28: Name records.** `name.records` **must** be a random-access range of
`Expected!NameRecord`, one per stored record. A record whose string lies
outside the storage area **must** be a `badOffset` entry; the other records
stay readable (`FTA11`). A `NameRecord` carries its platform, encoding,
language, name ID and raw bytes. In a version-1 table, a language ID of
`0x8000` or above **must** resolve to the language-tag record it indexes, or
be an `indexOutOfRange` entry; in a version-0 table it is reported as a
number.

**FTP29: Measured decoding.** `record.decodedLength()` **must** return the
UTF-8 length of the decoded text or the error decoding would return, and
`record.decode(char[] dest)` **must** write the text into `dest` and return
the written slice. Decoding **must** validate the whole record before writing
anything; on any error, `dest` **must** be left unchanged. A destination
shorter than the decoded length **must** return `limitExceeded`.

| Encoding                                                                                                            | Decoding                                                                                                                                     |
| ------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| UTF-16BE: platform 0, and platform 3 encodings 0, 1 and 10                                                          | base's strict codec (`FTA15`); an odd byte count or an unpaired surrogate is `invalidEncoding` at the byte offset of the offending code unit |
| Mac Roman: platform 1 encoding 0, any language except 15, 17, 18 and 37                                             | a fixed 128-entry table to scalars, encoded by base's UTF-8 encoder                                                                          |
| Mac Roman's Icelandic, Turkish, Croatian and Romanian variants (languages 15, 17, 18, 37), and every other encoding | `unsupportedCapability`; the raw bytes stay available                                                                                        |

_Rationale:_ The Mac Roman table is a legacy character set, not a Unicode
algorithm, so it does not compete with base's ownership of UTF; base still
does the encoding. The four language variants change a handful of code
points, and decoding them with the plain table would be silently wrong.

**FTP30: Glyph names from `post`.** `face.glyphName(gid)` **must** return a
glyph's name as a borrowed slice: a standard Macintosh name from a static
table, or a Pascal string in `post`. For version 2.0 it **may** scan the
string data, costing time linear in the table's length.
`face.glyphNameIndex(uint[] scratch)` **must** build, in the caller's
`scratch`, an index that makes each later lookup constant time; it **must**
return `limitExceeded` when `scratch` is too short, reporting the length it
needs. The value borrows both the face's buffer and `scratch`.

| Situation                                                                          | Result                                     |
| ---------------------------------------------------------------------------------- | ------------------------------------------ |
| `gid ≥ numGlyphs` of `maxp`                                                        | `indexOutOfRange`                          |
| version 1.0, `gid < 258`                                                           | the standard name                          |
| version 1.0, `gid ≥ 258`; version 3.0; no `post`                                   | no name from `post` (`FTP31` applies)      |
| version 2.0, `gid` at or past `post`'s own glyph count                             | no name from `post`                        |
| version 2.0, index below 258                                                       | the standard name                          |
| version 2.0, index from 258 to 65,535, naming a stored string                      | that string                                |
| version 2.0, index naming a string past the last one stored                        | `badValue` for that glyph                  |
| version 2.0, the string an index names runs past the table                         | `truncated` for that glyph                 |
| version 2.0, the glyph-index array itself runs past the table                      | `truncated` for every glyph                |
| version 2.5, `gid + offset[gid]` from 0 to 257                                     | that standard name                         |
| version 2.5, `gid + offset[gid]` outside 0–257, or the offset array past the table | `badValue`, or `truncated`, for that glyph |

**FTP31: Glyph names from `CFF`.** For a face with `CFF` outlines, a glyph
whose `post` lookup gives no name, an empty name or an error **must** take its
name from the
`CFF` charset: the header, the Name, Top DICT and String INDEXes, and a
charset of format 0, 1 or 2, or one of the predefined ISOAdobe, Expert and
ExpertSubset charsets (charset offsets 0, 1 and 2), resolving each SID
through the 391 standard strings or the String INDEX.

| Situation                                                    | Result                                               |
| ------------------------------------------------------------ | ---------------------------------------------------- |
| a CID-keyed `CFF` (its Top DICT has `ROS`), or `CFF2`        | no name                                              |
| a Name INDEX whose count is not 1                            | `badValue`; no `CFF` names                           |
| an INDEX `offSize` outside 1–4, or offsets outside the table | `badValue` or `truncated`; no `CFF` names            |
| a SID past the String INDEX                                  | `badValue` for that glyph                            |
| a format-0 charset array running past the table              | `truncated` for the glyphs whose entries lie past it |

A glyph whose `post` lookup failed and which has no `CFF` name **must** return
the `post` error. One lookup **must** cost time linear in the `CFF` header, the
INDEX headers, the Top DICT and the charset. `glyphNameIndex` (`FTP30`)
**must** resolve every glyph from whichever source names it, `post` or `CFF`,
in one pass over the `post` strings and one walk of the charset.
`glyphNameIndexLength` reports the `scratch` it needs: one entry per glyph,
plus one per stored `post` 2.0 string, whose offset a constant-time lookup
needs. Lookups through the index are then constant time. Neither operation
**may** allocate.

## 6. Classification and inspection

**FTP32: Spacing classification.** `face.spacing()` **must** walk `hmtx`
once and classify the face under `FTP12` as `mono`, `dual` or
`proportional`, together with the distinct nonzero advances found when there
are at most two. Glyphs whose `hmtx` entry is `truncated` (`FTP24`) are left
out of the classification and counted in its result. An unreadable `hmtx`
**must** return its error, not a classification.

**FTP33: Inspection.** Every view of `FTP23` **must** be a plain struct whose
fields carry the OpenType names, so a `sparkles:reflection` walk lists them
(`FTI1`); fields absent in the stored version **must** be distinguishable
from fields that hold zero. `face.directory` **must** be a random-access range
with one entry per stored record, in directory order, carrying the tag,
offset, length, stored checksum, whether the record is readable and whether
an earlier record has the same tag (`FTI5`). Computing the duplicate flags for
the whole directory costs O(r²), bounded by `FTP19`.
`entry.computedChecksum()` **must** compute a checksum on request, in time
linear in that table's length, treating `head`'s `checkSumAdjustment` as
zero. For a single-font file, `face.checkSumAdjustment()` **must** compare
the stored value with the value computed over the whole buffer, in time
linear in its length; for a face of a collection it **must** report that the
check does not apply. The directory search fields and `head`'s magic number
**must** be reported with their expected values. A mismatch in any of these
**must not** affect any other operation (`FTP4`).

## 7. Oracles

Each operation is checked against an independent implementation, described
in [`testing.md`](./testing.md). Where this page deliberately differs from an
oracle, the difference is listed and checked against another source.

| Operations               | Oracle                                                                                                             | Known divergence, and the substitute oracle                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FTP18`–`FTP23`, `FTP33` | HarfBuzz's sanitizers, `hb_face_get_upem`, `hb_face_get_glyph_count`; hostile-input fixtures for every refusal row | HarfBuzz reports 1,000 for a `unitsPerEm` outside 16–16,384 and treats `head` with a wrong magic number as empty; this page keeps the stored value. HarfBuzz binary-searches unsorted directories of 16 or more records. Substitute: FreeType for directories, hand-built fixtures for `head`.                                                                                                                                                                                                                                                                                                                                                                                                      |
| `FTP24`                  | `hb_font_get_glyph_h_advance` at `upem` scale                                                                      | HarfBuzz gives a glyph whose entry is past the table the last stored advance, and every glyph a default advance when `numberOfHMetrics` is 0; this page returns `truncated` and an unreadable `hmtx`. Substitute: hand-built fixtures for both.                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `FTP25`–`FTP27`          | `hb_font_get_nominal_glyph`, `hb_font_get_variation_glyph`, `hb_face_collect_unicodes` over every bundled face     | (1) HarfBuzz's collected codepoints include mappings to glyphs past `numGlyphs`, and omit the symbol remap and the Mac Roman inverse, which `ranges()` includes; the test compares `ranges()` with per-codepoint `hb_font_get_nominal_glyph` instead. (2) For overlapping format-4 segments HarfBuzz may resolve a codepoint to a later segment; FreeType resolves to the earliest, as `FTP26` does, and is the substitute where starts ascend. (3) FreeType accepts a decreasing format-4 `endCode` and refuses overlapping format-12 groups, the reverse of `FTP26`; hand-built fixtures check both. (4) HarfBuzz's legacy Arabic remap for symbol fonts with an `OS/2` code page is not adopted. |
| `FTP28`, `FTP29`         | `hb_ot_name_get_utf8` for UTF-16 records; hand-built malformed UTF-16 fixtures                                     | HarfBuzz decodes Mac Roman records as ASCII. Substitute: a hand-derived table check of all 128 non-ASCII bytes.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `FTP30`, `FTP31`         | `hb_font_get_glyph_name` over every glyph of every bundled face                                                    | HarfBuzz rejects `post` 2.5. Substitute: FreeType's `ttpost.c` through `FT_Get_Glyph_Name`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `FTP32`                  | hand-derived from `hmtx` dumps of the bundled faces                                                                | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
