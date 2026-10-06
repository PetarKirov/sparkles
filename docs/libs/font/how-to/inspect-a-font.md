# Inspect a damaged font

A font that a renderer would refuse is often the one you need to look at.
`sparkles:font` refuses a face only when `head`, `maxp` or the `cmap` header
cannot be read; damage anywhere else is reported where it is read.

## When the face does not open

```d
const opened = openFace(bytes);
if (opened.hasError)
{
    const e = opened.error;
    // e.kind: notAFont, truncated, badOffset, unsupportedVersion, ...
    // e.tag: the table, or none (e.tag.isNone)
    // e.offset: absolute byte offset; e.tableOffset: offset inside e.tag
}
```

WOFF and WOFF2 files are `unsupportedVersion`, not `notAFont`. A directory
of more than 4,096 records is `limitExceeded`, with `e.limit` naming the
limit.

## Walk the table directory

```d
foreach (entry; face.directory)
{
    // entry.tag, entry.offset, entry.length, entry.storedChecksum
    // entry.readable: false when offset + length leaves the file
    // entry.duplicate: an earlier record has this tag; this one is ignored
}
foreach (i; 0 .. face.tableCount)
{
    const computed = face.computedChecksum(i);
}
const fields = face.searchFields;          // .matches, and the expected values
const adjustment = face.checksumAdjustment; // .applies is false in a collection
```

None of these mismatches affects any other operation.

## Find out why a `cmap` subtable was skipped

`charMap` skips a subtable that fails its checks and uses the next candidate.
It keeps a record of what it skipped:

```d
const map = face.charMap.value;
if (map.rejectedRecords > 0)
{
    const first = map.firstRejection; // the first skipped record's error
}
// Each encoding record alone, with no fallback:
const one = face.charMapAt(0); // record 0 alone: its CharMap, or its error
```

`map.outOfRangeMappings` counts mappings to glyphs the font does not have;
those read as unmapped. `map.unmappedByTarget` counts codepoints whose format-4
glyph-array entry lies outside `cmap`.

## Read a broken list without losing the rest

Lists report a broken entry as an error and keep the others readable:

```d
foreach (record; face.name.value.records)
{
    if (record.hasError)
        continue; // e.g. badOffset: its string lies outside the storage area
}
```

The same holds for `fvar` axes, `avar` segment maps, `STAT` axis values and
`hmtx` entries past the end of the table.
