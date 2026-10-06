module sparkles.font.face_test;

import sparkles.font.errors : FontErrorKind, FontLimit, Tag;
import sparkles.font.face : openCollection, openFace, OutlineFormat;
import sparkles.font.fixtures;

/// The 422-byte fixture of testing.md: head at 60, maxp at 116, cmap at 148.
private ubyte[] traceFixture() @safe pure nothrow
{
    // Directory in tag order: cmap, head, maxp; placed head, maxp, cmap.
    auto h = head(2048), m = maxp(2), c = cmap([CmapRecord(3, 1, cmapFormat0([[0x41, 1]]))]);
    assert(h.length == 54 && m.length == 32 && c.length == 274);
    ubyte[] dir = sfntHeader(0x0001_0000, 3)
        ~ cast(ubyte[]) "cmap".dup ~ u32(checksum(c)) ~ u32(148) ~ u32(274)
        ~ cast(ubyte[]) "head".dup ~ u32(checksum(h)) ~ u32(60) ~ u32(54)
        ~ cast(ubyte[]) "maxp".dup ~ u32(checksum(m)) ~ u32(116) ~ u32(32);
    return dir ~ h ~ u16(0) ~ m ~ c;
}

@("face.open.traceSuccess")
@safe pure nothrow
unittest
{
    const bytes = traceFixture();
    assert(bytes.length == 422);
    const face = openFace(bytes);
    assert(face.hasValue);
    assert(face.value.unitsPerEm == 2048 && face.value.numGlyphs == 2);
    assert(face.value.outlines == OutlineFormat.trueType && face.value.sortedDirectory);
    const raw = face.value.table(Tag("head"));
    assert(raw.hasValue && raw.value.ptr == &bytes[60] && raw.value.length == 54);
    const name = face.value.table(Tag("name"));
    assert(name.hasError && name.error.kind == FontErrorKind.missingTable);
    const second = openFace(bytes, 1);
    assert(second.hasError && second.error.kind == FontErrorKind.indexOutOfRange);
}

@("face.open.exactEndAndOneShort")
@safe pure nothrow
unittest
{
    const bytes = traceFixture();
    const short_ = openFace(bytes[0 .. 421]);
    assert(short_.hasError);
    assert(short_.error.kind == FontErrorKind.badOffset && short_.error.tag == Tag("cmap"));
}

@("face.open.optionalTableFailureStaysLocal")
@safe pure nothrow
unittest
{
    auto bytes = sfnt(minimalTables ~ TableData("name", u16(0)));
    // Point the `name` record (last in the directory) past the end.
    const at = 12 + 16 * 3 + 8;
    bytes[at .. at + 4] = u32(cast(uint) bytes.length);
    const face = openFace(bytes);
    assert(face.hasValue);
    const name = face.value.table(Tag("name"));
    assert(name.hasError && name.error.kind == FontErrorKind.badOffset);
    bool listed;
    foreach (entry; face.value.directory)
        if (entry.tag == Tag("name"))
            listed = !entry.readable;
    assert(listed);
}

@("face.open.signatures")
@safe pure nothrow
unittest
{
    static immutable ubyte[4] woff = ['w', 'O', 'F', 'F'], woff2 = ['w', 'O', 'F', '2'],
        junk = [0x12, 0x34, 0x56, 0x78];
    assert(openFace(woff[]).error.kind == FontErrorKind.unsupportedVersion);
    assert(openFace(woff2[]).error.kind == FontErrorKind.unsupportedVersion);
    assert(openFace(junk[]).error.kind == FontErrorKind.notAFont);
    assert(openFace(junk[0 .. 3]).error.kind == FontErrorKind.truncated);
    const otto = openFace(sfnt(minimalTables, 0x4F54_544F));
    assert(otto.hasValue && otto.value.outlines == OutlineFormat.cff);
}

@("face.open.requiredTables")
@safe pure nothrow
unittest
{
    auto noHead = sfnt([TableData("cmap", minimalTables[0].data), TableData("maxp", maxp(2))]);
    assert(openFace(noHead).error.kind == FontErrorKind.missingTable);
    auto shortHead = sfnt([minimalTables[0], TableData("head", head()[0 .. 40]), minimalTables[2]]);
    const e = openFace(shortHead).error;
    assert(e.kind == FontErrorKind.truncated && e.tag == Tag("head") && e.tableOffset == 40);
    auto zeroUpem = sfnt([minimalTables[0], TableData("head", head(0)), minimalTables[2]]);
    assert(openFace(zeroUpem).error.kind == FontErrorKind.badValue);
    auto badMaxp = sfnt([minimalTables[0], minimalTables[1], TableData("maxp", u32(0x0002_0000) ~ u16(2))]);
    assert(openFace(badMaxp).error.kind == FontErrorKind.unsupportedVersion);
    auto maxp05Face = sfnt([minimalTables[0], minimalTables[1], TableData("maxp", maxp05(7))]);
    assert(openFace(maxp05Face).value.numGlyphs == 7);
}

@("face.open.directoryLimit")
@safe pure nothrow
unittest
{
    auto bytes = sfnt(minimalTables);
    bytes[4 .. 6] = u16(4_097);
    const over = openFace(bytes);
    assert(over.hasError && over.error.kind == FontErrorKind.limitExceeded);
    assert(over.error.limit == FontLimit.tableRecords && over.error.limitValue == 4_096);
    // Exactly at the limit, the records must still fit: a short buffer is truncated.
    bytes[4 .. 6] = u16(4_096);
    assert(openFace(bytes).error.kind == FontErrorKind.truncated);
}

@("face.open.offsetOverflow")
@safe pure nothrow
unittest
{
    auto bytes = sfnt(minimalTables);
    // head is record 1: offset 0xFFFF_FFF0, length 0x20 overflows 32 bits.
    const at = 12 + 16 + 8;
    bytes[at .. at + 8] = u32(0xFFFF_FFF0) ~ u32(0x20);
    const e = openFace(bytes).error;
    assert(e.kind == FontErrorKind.badOffset && e.tag == Tag("head"));
}

@("face.open.duplicateTagFirstWins")
@safe pure nothrow
unittest
{
    auto tables = minimalTables ~ TableData("head", head(1000));
    const face = openFace(sfnt(tables));
    assert(face.hasValue && face.value.unitsPerEm == 2048);
    size_t duplicates;
    foreach (entry; face.value.directory)
        duplicates += entry.duplicate;
    assert(duplicates == 1);
}

@("face.collection.faces")
@safe pure nothrow
unittest
{
    const bytes = collection([minimalTables(2), minimalTables(5)]);
    const coll = openCollection(bytes);
    assert(coll.hasValue && coll.value.count == 2);
    assert(coll.value.face(1).value.numGlyphs == 5 && coll.value.face(1).value.inCollection);
    assert(coll.value.face(2).error.kind == FontErrorKind.indexOutOfRange);
    assert(!coll.value.face(0).value.checksumAdjustment.applies);
    const single = openCollection(sfnt(minimalTables));
    assert(single.hasValue && single.value.count == 1);
}

@("face.inspection.checksums")
@safe pure nothrow
unittest
{
    auto bytes = sfnt(minimalTables);
    const face = openFace(bytes).value;
    const dir = face.directory;
    foreach (i; 0 .. dir.length)
        assert(face.computedChecksum(i) == dir[i].storedChecksum);
    assert(face.searchFields.matches);
    const adjustment = face.checksumAdjustment;
    assert(adjustment.applies && adjustment.stored == 0);
    assert(adjustment.expected == 0xB1B0_AFBA - checksum(bytes));
}
