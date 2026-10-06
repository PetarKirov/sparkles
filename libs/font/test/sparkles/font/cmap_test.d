module sparkles.font.cmap_test;

import sparkles.font.cmap;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.errors : FontErrorKind, Tag;
import sparkles.font.face : Face, openFace;
import sparkles.font.fixtures;
import sparkles.test_runner.skip : skipTest;

private ubyte[] fontWith(const(CmapRecord)[] records, uint numGlyphs = 100) @safe pure nothrow
    => sfnt([TableData("cmap", cmap(records)), TableData("head", head(1000)), TableData("maxp", maxp(numGlyphs))]);

/// Every codepoint `glyph` maps lies in `ranges`, and nothing else does.
private void assertRangesMatch(const CharMap m, dchar top) @safe pure nothrow
{
    dchar next = 0;
    foreach (r; m.ranges)
    {
        assert(r.first <= r.last && r.first >= next);
        foreach (cp; next .. r.first) assert(m.glyph(cp) == 0);
        foreach (cp; r.first .. r.last + 1) assert(m.glyph(cp) != 0);
        // Merged: the codepoint after a range is unmapped.
        assert(m.glyph(r.last + 1) == 0);
        next = r.last + 1;
    }
    foreach (cp; next .. top + 1) assert(m.glyph(cp) == 0);
}

@("cmap.format0.trace")
@safe pure nothrow
unittest
{
    const m = openFace(fontWith([CmapRecord(3, 1, cmapFormat0([[0x41, 1]]))], 2)).value.charMap.value;
    assert(m.format == 0 && m.glyph('A') == 1 && m.glyph('B') == 0);
    assertRangesMatch(m, 0x1FF);
}

@("cmap.format4.deltaArrayAndCounts")
@safe pure nothrow
unittest
{
    // 'a'..'c' by delta to 10..12; 'x'..'z' through an array [20, 0, 500].
    const sub = cmapFormat4([Segment('a', 'c', 10 - 'a'), Segment('x', 'z', 0, [20, 0, 500])]);
    const m = openFace(fontWith([CmapRecord(3, 1, sub)], 100)).value.charMap.value;
    assert(m.glyph('a') == 10 && m.glyph('c') == 12 && m.glyph('d') == 0);
    assert(m.glyph('x') == 20 && m.glyph('y') == 0);
    assert(m.glyph('z') == 0 && m.outOfRangeMappings == 1); // glyph 500 ≥ numGlyphs
    assertRangesMatch(m, 0xFFFF);
}

@("cmap.format4.overlapTakesEffectiveSpans")
@safe pure nothrow
unittest
{
    // [100, 200] then [50, 300]: the second segment's effective span is [201, 300].
    const sub = cmapFormat4([Segment(100, 200, 1), Segment(50, 300, 2)]);
    const m = openFace(fontWith([CmapRecord(3, 1, sub)], 1000)).value.charMap.value;
    assert(m.glyph(60) == 0 && m.glyph(150) == 151 && m.glyph(250) == 252);
    assertRangesMatch(m, 0xFFFF);
}

@("cmap.format4.targetOutsideCmapIsUnmapped")
@safe pure nothrow
unittest
{
    auto sub = cmapFormat4([Segment('a', 'b', 0, [5, 6])]);
    // Point the first segment's idRangeOffset far past the table.
    const segCount = 2, rangeAt = 16 + 6 * segCount;
    sub[rangeAt .. rangeAt + 2] = u16(0x7000);
    const m = openFace(fontWith([CmapRecord(3, 1, sub)])).value.charMap.value;
    assert(m.glyph('a') == 0 && m.unmappedByTarget == 2);
}

@("cmap.choice.format12OverFormat4")
@safe pure nothrow
unittest
{
    const f4 = cmapFormat4([Segment('A', 'A', 5 - 'A')]);
    const f12 = cmapFormat12([[0x41, 0x41, 9]]);
    const m = openFace(fontWith([CmapRecord(3, 1, f4), CmapRecord(3, 10, f12)])).value.charMap.value;
    assert(m.format == 12 && m.platform == 3 && m.encoding == 10 && m.glyph('A') == 9);
}

@("cmap.choice.brokenSubtableFallsBackAndCounts")
@safe pure nothrow
unittest
{
    // A format-12 subtable whose group ends decrease, then a good format 4.
    const bad = cmapFormat12([[0x41, 0x50, 1], [0x51, 0x45, 2]]);
    const good = cmapFormat4([Segment('A', 'A', 7 - 'A')]);
    const face = openFace(fontWith([CmapRecord(3, 10, bad), CmapRecord(3, 1, good)])).value;
    const m = face.charMap.value;
    assert(m.format == 4 && m.glyph('A') == 7);
    assert(m.rejectedRecords == 1 && m.firstRejection.kind == FontErrorKind.badValue);
    // The inspector sees the broken record's own error.
    assert(face.charMapAt(0).error.kind == FontErrorKind.badValue);
    assert(face.charMapAt(5).error.kind == FontErrorKind.indexOutOfRange);
}

@("cmap.choice.noUsableSubtable")
@safe pure nothrow
unittest
{
    const format2 = u16(2) ~ u16(6) ~ u16(0);
    const r = openFace(fontWith([CmapRecord(3, 1, format2)])).value.charMap;
    assert(r.hasError && r.error.kind == FontErrorKind.unsupportedCapability && r.error.tag == Tag("cmap"));
}

@("cmap.format12.clampAndRanges")
@safe pure nothrow
unittest
{
    // A group ending past U+10FFFF is clamped; a format-13 group maps to one glyph.
    const m = openFace(fontWith([CmapRecord(3, 10, cmapFormat12([[0x20, 0x22, 1], [0x23, 0x25, 4],
        [0x10FFF0, 0x200000, 10]]))], 20)).value.charMap.value;
    assert(m.glyph(0x20) == 1 && m.glyph(0x25) == 6);
    assert(m.glyph(0x10FFF0) == 10 && m.glyph(0x10FFFF) == 0);
    // Glyphs 20 and above are out of range: U+10FFF0 + 10 onward.
    assert(m.glyph(cast(dchar)(0x10FFF0 + 9)) == 19 && m.glyph(cast(dchar)(0x10FFF0 + 10)) == 0);
    auto r = m.ranges;
    assert(r.front == CodepointRange(0x20, 0x25)); // merged across the two groups
    r.popFront;
    assert(r.front == CodepointRange(0x10FFF0, cast(dchar)(0x10FFF0 + 9)));
    assert(m.outOfRangeMappings == 6);
    r.popFront;
    assert(r.empty);
    const m13 = openFace(fontWith([CmapRecord(3, 10, cmapFormat12([[0x100, 0x1FF, 3]], 13))])).value.charMap.value;
    assert(m13.glyph(0x100) == 3 && m13.glyph(0x1FF) == 3 && m13.glyph(0x200) == 0);
}

@("cmap.format6")
@safe pure nothrow
unittest
{
    const sub = u16(6) ~ u16(16) ~ u16(0) ~ u16('a') ~ u16(3) ~ u16(4) ~ u16(5) ~ u16(0);
    const m = openFace(fontWith([CmapRecord(0, 3, sub)])).value.charMap.value;
    assert(m.glyph('a') == 4 && m.glyph('b') == 5 && m.glyph('c') == 0 && m.glyph('d') == 0);
    assertRangesMatch(m, 0xFFFF);
    const tooLong = u16(6) ~ u16(10) ~ u16(0) ~ u16(0xFFFF) ~ u16(2) ~ u16(1) ~ u16(1);
    assert(openFace(fontWith([CmapRecord(0, 3, tooLong)])).value.charMap.error.kind == FontErrorKind.unsupportedCapability);
}

@("cmap.symbolRemap")
@safe pure nothrow
unittest
{
    // A symbol font maps U+F041 only; 'A' reaches it through U+F000 + 0x41.
    const sub = cmapFormat4([Segment(0xF041, 0xF041, 3 - 0xF041)]);
    const m = openFace(fontWith([CmapRecord(3, 0, sub)])).value.charMap.value;
    assert(m.lookup == CmapLookup.symbol && m.glyph(0xF041) == 3 && m.glyph('A') == 3);
    assert(m.glyph(0x141) == 0);
    assertRangesMatch(m, 0xFFFF);
}

@("cmap.macRomanAndAscii")
@safe pure nothrow
unittest
{
    // Mac Roman byte 0xDB is U+20AC; 0x41 is 'A'.
    const mac = openFace(fontWith([CmapRecord(1, 0, cmapFormat0([[0xDB, 7], [0x41, 2]]))])).value.charMap.value;
    assert(mac.lookup == CmapLookup.macRoman && mac.glyph('€') == 7 && mac.glyph('A') == 2);
    assert(mac.glyph(0xDB) == 0);
    auto r = mac.ranges;
    assert(r.front == CodepointRange('A', 'A'));
    r.popFront;
    assert(r.front == CodepointRange('€', '€'));
    const other = openFace(fontWith([CmapRecord(1, 1, cmapFormat0([[0x41, 2], [0xC0, 3]]))])).value.charMap.value;
    assert(other.lookup == CmapLookup.ascii && other.glyph('A') == 2 && other.glyph(0xC0) == 0);
}

@("cmap.format14.variants")
@safe pure nothrow
unittest
{
    // Selector U+FE0F: default for U+2600..U+2601, U+263A non-default glyph 9.
    const dflt = u32(1) ~ u8(0) ~ u16(0x2600) ~ u8(1);
    const nondflt = u32(1) ~ u8(0) ~ u16(0x263A) ~ u16(9);
    const recordsEnd = 10 + 11;
    const f14 = u16(14) ~ u32(cast(uint)(recordsEnd + dflt.length + nondflt.length)) ~ u32(1)
        ~ u8(0) ~ u16(0xFE0F) ~ u32(recordsEnd) ~ u32(cast(uint)(recordsEnd + dflt.length)) ~ dflt ~ nondflt;
    const m = openFace(fontWith([CmapRecord(0, 5, f14), CmapRecord(3, 1, cmapFormat4([Segment(0x2600, 0x2601, 1)]))]
        )).value.charMap.value;
    assert(m.variant(0x2601, 0xFE0F).value.kind == VariantKind.useDefault);
    const v = m.variant(0x263A, 0xFE0F).value;
    assert(v.kind == VariantKind.glyph && v.glyph == 9);
    assert(m.variant(0x263A, 0xFE0E).value.kind == VariantKind.none);
    // A broken format 14 fails variant lookups only.
    const broken = u16(14) ~ u32(10) ~ u32(5);
    const b = openFace(fontWith([CmapRecord(0, 5, broken), CmapRecord(3, 1, cmapFormat0([[0x41, 1]]))])).value.charMap.value;
    assert(b.variant('A', 0xFE0F).error.kind == FontErrorKind.truncated && b.glyph('A') == 1);
}

@("cmap.corpus.rangesMatchLookups")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    foreach (name; ["MapleMono-NF-CN-Regular.ttf", "FiraCodeNerdFontMono-Regular.ttf", "NotoSans.ttf",
        "DejaVuSansMono.ttf", "NotoSansAnatolianHieroglyphs-Regular.otf"])
    {
        const bytes = bundled(name);
        const m = openFace(bytes).value.charMap.value;
        assert(m.rejectedRecords == 0, name);
        size_t mapped;
        foreach (r; m.ranges)
            foreach (cp; r.first .. r.last + 1)
                if (m.glyph(cp)) ++mapped;
        assert(mapped > 0, name);
        assertRangesMatch(m, 0x10FFFF);
    }
}
