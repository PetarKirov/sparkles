/**
FTS10 caret tests: GDEF ligature carets in all three formats over a
fixture face whose glyph 1 has an outline and caret records.
*/
module sparkles.font.carets_test;

import sparkles.base.unique : makeUnique;
import sparkles.font;
import sparkles.font.fixtures;

/// A Device table (format 3, 8-bit values for sizes 8–24): +3 px at 16.
private ubyte[] deviceTable() @safe pure nothrow
{
    ubyte[] words;
    foreach (i; 0 .. 9)
        words ~= i == 4 ? u16(0x0300) : u16(0);
    return u16(8) ~ u16(24) ~ u16(3) ~ words;
}

/**
A `GDEF` 1.0 whose LigCaretList covers glyph 1 with three carets:
format 1 at 100, format 2 at contour point 1, format 3 at 50 with a
Device table.
*/
private ubyte[] gdefTable() @safe pure nothrow
{
    const caret1 = u16(1) ~ u16(100);
    const caret2 = u16(2) ~ u16(1);
    const caret3 = u16(3) ~ u16(50) ~ u16(6); // Device table follows it
    const ligGlyph = u16(3) ~ u16(8) ~ u16(8 + 4) ~ u16(8 + 4 + 4)
        ~ caret1 ~ caret2 ~ caret3 ~ deviceTable();
    const coverage = u16(1) ~ u16(1) ~ u16(1); // format 1: glyph 1
    const ligCaretList = u16(cast(uint)(6 + ligGlyph.length)) ~ u16(1) ~ u16(6)
        ~ ligGlyph ~ coverage;
    // Header: version, glyph class, attach list, caret list (at 12), mark class.
    return u32(0x0001_0000) ~ u16(0) ~ u16(0) ~ u16(12) ~ u16(0) ~ ligCaretList;
}

private const(ubyte)[] caretFont() @safe pure nothrow
{
    const glyphs = [simpleGlyph([[0, 0, 1]]),
        simpleGlyph([[10, 20, 1], [110, 20, 1], [110, 120, 1]])];
    auto tables = minimalTables(2);
    tables ~= TableData("hhea", hhea(2));
    tables ~= TableData("hmtx", hmtx([[500, 0], [500, 0]]));
    tables ~= TableData("loca", locaTable(glyphs));
    tables ~= TableData("glyf", glyfTable(glyphs));
    tables ~= TableData("GDEF", gdefTable());
    return sfnt(tables);
}

@("carets.gdef.threeFormats")
@safe pure nothrow
unittest
{
    auto ws = makeUnique!PointWorkspace();
    const bytes = caretFont();
    const face = openFace(bytes).value;
    auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
    LigatureCaret[4] carets;
    const r = ligatureCarets(inst, 1, 0, true, carets[], *ws);
    assert(r.hasValue && r.value.present && r.value.count == 3);
    assert(carets[0].provenance == CaretProvenance.coordinate
        && carets[0].coordinate.raw == 100L << 16);
    // Point 1 of the glyph is (110, 20) stored, (100, 20) in the drawn
    // space the caret resolves in (anchor lsb − xMin = −10).
    assert(carets[1].provenance == CaretProvenance.contourPoint
        && carets[1].coordinate.raw == 100L << 16);
    assert(carets[2].provenance == CaretProvenance.deviceTable
        && carets[2].coordinate.raw == 50L << 16
        && carets[2].hasDevice && carets[2].device.deviceApplied
        && carets[2].device.devicePixels == 3);
    foreach (i; 0 .. 3)
        assert(carets[i].glyphId == 1 && carets[i].recordIndex == i);
    // A glyph without records, and capacity exhaustion.
    LigatureCaret[2] small;
    const absent = ligatureCarets(inst, 0, 0, true, small[], *ws);
    assert(absent.hasValue && !absent.value.present);
    const exhausted = ligatureCarets(inst, 1, 0, true, small[], *ws);
    assert(exhausted.hasError && exhausted.error.kind == FontErrorKind.limitExceeded);
}

/// `caretFont` with the GDEF bytes at `offset` replaced, located from the end of the table.
private const(ubyte)[] corruptedCaretFont(size_t fromEnd, const(ubyte)[] bytes_) @safe pure nothrow
{
    auto gdef = gdefTable();
    gdef[$ - fromEnd .. $ - fromEnd + bytes_.length] = bytes_;
    const glyphs = [simpleGlyph([[0, 0, 1]]),
        simpleGlyph([[10, 20, 1], [110, 20, 1], [110, 120, 1]])];
    auto tables = minimalTables(2);
    tables ~= TableData("hhea", hhea(2));
    tables ~= TableData("hmtx", hmtx([[500, 0], [500, 0]]));
    tables ~= TableData("loca", locaTable(glyphs));
    tables ~= TableData("glyf", glyfTable(glyphs));
    tables ~= TableData("GDEF", gdef);
    return sfnt(tables);
}

/// FTS10: malformed caret data is its error, distinct from absence, and publishes nothing.
@("carets.gdef.malformedPublishesNothing")
@safe pure
unittest
{
    auto ws = makeUnique!PointWorkspace();
    // The GDEF tail is: caret2 (4) caret3 (6) device (24) coverage (6).
    enum caret2FromEnd = 6 + 24 + 6 + 4, caret3FromEnd = 6 + 24 + 6, deviceFromEnd = 6 + 24;
    static struct Case
    {
        size_t fromEnd;
        immutable(ubyte)[] bytes;
        FontErrorKind kind;
    }

    const cases = [
        // Format 2 naming point 9 of a three-point glyph.
        Case(caret2FromEnd, [0, 2, 0, 9], FontErrorKind.indexOutOfRange),
        // Format 3 whose Device table offset points past the table.
        Case(caret3FromEnd, [0, 3, 0, 50, 0xFF, 0xF0], FontErrorKind.badOffset),
        // A Device table whose size range (8–255) needs more delta words than remain.
        Case(deviceFromEnd, [0, 8, 0, 0xFF], FontErrorKind.truncated),
        // An unknown caret format.
        Case(caret2FromEnd, [0, 7, 0, 1], FontErrorKind.unsupportedVersion),
    ];
    foreach (c; cases)
    {
        const bytes = corruptedCaretFont(c.fromEnd, c.bytes);
        const face = openFace(bytes).value;
        auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
        LigatureCaret[4] carets;
        foreach (ref caret; carets)
            caret.recordIndex = 77;
        const r = ligatureCarets(inst, 1, 0, true, carets[], *ws);
        assert(r.hasError && r.error.kind == c.kind, () { import std.conv : text; return text(c.kind, " got ", r.hasError ? r.error.kind : c.kind, r.hasError ? "" : " (no error)"); }());
        foreach (caret; carets)
            assert(caret.recordIndex == 77, "an error publishes no caret");
    }
}
