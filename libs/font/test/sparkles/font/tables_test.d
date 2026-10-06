module sparkles.font.tables_test;

import sparkles.font.corpus : bundled;
import sparkles.font.errors : FontErrorKind, Tag;
import sparkles.font.face : openFace;
import sparkles.font.fixtures;
import sparkles.font.tables;
import sparkles.test_runner.skip : skipTest;

@("tables.head.hhea.maxp")
@safe pure nothrow
unittest
{
    const bytes = sfnt(minimalTables ~ TableData("hhea", hhea(2, 900, -300)));
    const face = openFace(bytes).value;
    const h = face.head.value;
    assert(h.unitsPerEm == 2048 && h.magicNumber == 0x5F0F_3CF5 && h.majorVersion == 1);
    const hh = face.hhea.value;
    assert(hh.ascender == 900 && hh.descender == -300 && hh.numberOfHMetrics == 2);
    const m = face.maxp.value;
    assert(m.numGlyphs == 2 && m.hasVersion1Fields);
    assert(openFace(sfnt([minimalTables[0], minimalTables[1], TableData("maxp", maxp05(3))]))
        .value.maxp.value.hasVersion1Fields == false);
    assert(face.os2.error.kind == FontErrorKind.missingTable);
}

private ubyte[] os2Table(uint version_, size_t length) @safe pure nothrow
{
    auto t = u16(version_) ~ u16(500) ~ u16(400);
    t.length = length;
    if (length >= 88) t[86 .. 88] = u16(520); // sxHeight
    return t;
}

@("tables.os2.versionsAndLengths")
@safe pure nothrow
unittest
{
    foreach (v, len; [0: 78, 1: 86, 2: 96, 4: 96, 5: 100, 6: 100])
    {
        const face = openFace(sfnt(minimalTables ~ TableData("OS/2", os2Table(v, len)))).value;
        const o = face.os2;
        assert(o.hasValue && o.value.version_ == v && o.value.usWeightClass == 400);
        assert(o.value.hasCodePageRanges == (v >= 1) && o.value.hasXHeight == (v >= 2));
        assert(o.value.hasOpticalSizes == (v >= 5));
        if (v >= 2) assert(o.value.sxHeight == 520);
        // One byte shorter than its version needs is truncated.
        const short_ = openFace(sfnt(minimalTables ~ TableData("OS/2", os2Table(v, len - 1)))).value;
        assert(short_.os2.error.kind == FontErrorKind.truncated);
    }
}

@("tables.post.header")
@safe pure nothrow
unittest
{
    auto p = u32(0x0003_0000) ~ u32(cast(uint)(-12 << 16)) ~ u16(cast(uint) -100) ~ u16(50) ~ u32(1);
    p.length = 32;
    const face = openFace(sfnt(minimalTables ~ TableData("post", p))).value;
    const post_ = face.post.value;
    assert(post_.version_ == 0x0003_0000 && post_.italicAngle == -12 << 16);
    assert(post_.underlinePosition == -100 && post_.isFixedPitch == 1);
    assert(openFace(sfnt(minimalTables ~ TableData("post", p[0 .. 31]))).value.post.error.kind
        == FontErrorKind.truncated);
}

@("tables.hmtx.lenient")
@safe pure nothrow
unittest
{
    // 4 glyphs, 2 long metrics, 2 trailing lsbs.
    auto tables = minimalTables(4) ~ TableData("hhea", hhea(2)) ~ TableData("hmtx",
        hmtx([[600, 10], [700, 20]], [30, 40]));
    const face = openFace(sfnt(tables)).value;
    const m = face.hmtx.value;
    assert(m.advance(0).value == 600 && m.lsb(1).value == 20);
    assert(m.advance(3).value == 700 && m.lsb(3).value == 40);
    assert(m.advance(4).error.kind == FontErrorKind.indexOutOfRange);

    // numberOfHMetrics past numGlyphs reads as numGlyphs.
    auto many = minimalTables(2) ~ TableData("hhea", hhea(9)) ~ TableData("hmtx", hmtx([[1, 0], [2, 0]]));
    assert(openFace(sfnt(many)).value.hmtx.value.numberOfHMetrics == 2);

    // A glyph whose entry lies past the table is truncated; others still read.
    auto cut = minimalTables(4) ~ TableData("hhea", hhea(2)) ~ TableData("hmtx", hmtx([[600, 10], [700, 20]], [30]));
    const c = openFace(sfnt(cut)).value.hmtx.value;
    assert(c.lsb(2).value == 30 && c.lsb(3).error.kind == FontErrorKind.truncated);

    // numberOfHMetrics 0 with glyphs makes hmtx unreadable.
    auto zero = minimalTables(2) ~ TableData("hhea", hhea(0)) ~ TableData("hmtx", hmtx([[1, 0]]));
    assert(openFace(sfnt(zero)).value.hmtx.error.kind == FontErrorKind.badValue);
}

@("tables.spacing.classify")
@safe pure nothrow
unittest
{
    Spacing classify(const(uint[2])[] metrics)
    {
        auto t = minimalTables(cast(uint) metrics.length) ~ TableData("hhea", hhea(cast(uint) metrics.length))
            ~ TableData("hmtx", hmtx(metrics));
        return openFace(sfnt(t)).value.spacing.value.spacing;
    }
    assert(classify([[0, 0], [600, 0], [600, 0]]) == Spacing.mono);
    assert(classify([[600, 0], [1200, 0], [0, 0]]) == Spacing.dual);
    assert(classify([[600, 0], [1000, 0]]) == Spacing.proportional);
    assert(classify([[500, 0], [600, 0], [700, 0]]) == Spacing.proportional);
}

@("tables.fvar.avar.stat")
@safe pure nothrow
unittest
{
    // fvar: wght 100..400..900, and one disordered axis; one instance with a PostScript name.
    auto f = u16(1) ~ u16(0) ~ u16(16) ~ u16(2) ~ u16(2) ~ u16(20) ~ u16(1) ~ u16(14)
        ~ cast(ubyte[]) "wght".dup ~ u32(100 << 16) ~ u32(400 << 16) ~ u32(900 << 16) ~ u16(0) ~ u16(256)
        ~ cast(ubyte[]) "wdth".dup ~ u32(200 << 16) ~ u32(100 << 16) ~ u32(150 << 16) ~ u16(0) ~ u16(257)
        ~ u16(258) ~ u16(0) ~ u32(700 << 16) ~ u32(100 << 16) ~ u16(300);
    // avar: two maps, the second decreasing.
    auto a = u16(1) ~ u16(0) ~ u16(0) ~ u16(2)
        ~ u16(3) ~ u16(0xC000) ~ u16(0xC000) ~ u16(0) ~ u16(0) ~ u16(0x4000) ~ u16(0x4000)
        ~ u16(2) ~ u16(0x4000) ~ u16(0) ~ u16(0) ~ u16(0);
    // STAT 1.1: one design axis, a format-1 and a format-9 value.
    auto s = u16(1) ~ u16(1) ~ u16(8) ~ u16(1) ~ u32(20) ~ u16(2) ~ u32(28) ~ u16(2)
        ~ cast(ubyte[]) "wght".dup ~ u16(256) ~ u16(0)
        ~ u16(4) ~ u16(16)
        ~ u16(1) ~ u16(0) ~ u16(0) ~ u16(300) ~ u32(400 << 16)
        ~ u16(9);
    const face = openFace(sfnt(minimalTables ~ [TableData("STAT", s), TableData("avar", a),
        TableData("fvar", f)])).value;

    const fv = face.fvar.value;
    assert(fv.axisCount == 2 && fv.axis(0).value.axisTag == Tag("wght"));
    assert(fv.axis(1).error.kind == FontErrorKind.badValue);
    const inst = fv.instance(0);
    assert(inst.subfamilyNameID == 258 && inst.coordinate(0) == 700 << 16);
    assert(inst.hasPostScriptNameID && inst.postScriptNameID == 300);

    const av = face.avar.value;
    assert(av.axisCount == 2);
    size_t n;
    foreach (map; av.maps)
    {
        if (n == 0) assert(map.hasValue && map.value.length == 3 && map.value.map(2) == [0x4000, 0x4000]);
        else assert(map.error.kind == FontErrorKind.badValue);
        ++n;
    }
    assert(n == 2);

    const st = face.stat.value;
    assert(st.hasElidedFallbackNameID && st.elidedFallbackNameID == 2);
    assert(st.designAxis(0).axisTag == Tag("wght"));
    assert(st.axisValue(0).value.value == 400 << 16 && st.axisValue(0).value.valueNameID == 300);
    assert(st.axisValue(1).error.kind == FontErrorKind.unsupportedVersion);
}

@("tables.spacing.corpus")
@system
unittest
{
    const maple = bundled("MapleMono-NF-CN-Regular.ttf");
    if (maple is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    assert(openFace(maple).value.spacing.value.spacing == Spacing.dual);
    assert(openFace(bundled("DejaVuSansMono.ttf")).value.spacing.value.spacing == Spacing.mono);
    assert(openFace(bundled("NotoSans.ttf")).value.spacing.value.spacing == Spacing.proportional);
}
