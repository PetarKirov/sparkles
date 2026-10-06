module sparkles.font.glyph_names_test;

import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.errors : FontErrorKind;
import sparkles.font.face : Face, openFace;
import sparkles.font.fixtures;
import sparkles.font.glyph_names;
import sparkles.test_runner.skip : skipTest;

private ubyte[] fontWith(uint numGlyphs, const(TableData)[] extra, uint sfntVersion = 0x0001_0000) @safe pure nothrow
    => sfnt(minimalTables(numGlyphs) ~ extra, sfntVersion);

/// The index answers exactly as the direct lookup, for every glyph.
private void assertIndexMatches(const Face face) @safe pure nothrow
{
    const length = face.glyphNameIndexLength.value;
    auto scratch = new uint[length];
    const index = face.glyphNameIndex(scratch).value;
    foreach (gid; 0 .. face.numGlyphs)
    {
        const direct = face.glyphName(gid), fast = index[gid];
        assert(direct.hasValue == fast.hasValue);
        if (direct.hasValue)
            assert(direct.value.present == fast.value.present && direct.value.text == fast.value.text);
        else
            assert(direct.error.kind == fast.error.kind);
    }
    if (length)
        assert(face.glyphNameIndex(scratch[0 .. length - 1]).error.kind == FontErrorKind.limitExceeded);
}

@("glyphNames.post1And3")
@safe pure nothrow
unittest
{
    const v1 = openFace(fontWith(300, [TableData("post", postTable(0x0001_0000))])).value;
    assert(v1.glyphName(3).value.text == "space" && v1.glyphName(257).value.text == "dcroat");
    assert(!v1.glyphName(258).value.present);
    assert(v1.glyphName(300).error.kind == FontErrorKind.indexOutOfRange);
    assertIndexMatches(v1);
    const v3 = openFace(fontWith(4, [TableData("post", postTable(0x0003_0000))])).value;
    assert(!v3.glyphName(1).value.present);
    assert(!openFace(fontWith(4, [])).value.glyphName(1).value.present);
}

@("glyphNames.post2")
@safe pure nothrow
unittest
{
    // Glyph 0 .notdef, 1 "alpha", 2 standard "A", 3 "beta", 4 a string past the last.
    const f = openFace(fontWith(6, [TableData("post", post2([0, 258, 36, 259, 300], ["alpha", "beta"]))])).value;
    assert(f.glyphName(0).value.text == ".notdef" && f.glyphName(1).value.text == "alpha");
    assert(f.glyphName(2).value.text == "A" && f.glyphName(3).value.text == "beta");
    assert(f.glyphName(4).error.kind == FontErrorKind.badValue);
    assert(!f.glyphName(5).value.present); // past post's own glyph count
    assertIndexMatches(f);

    // Indices up to 65,535 name strings; with no such string it is badValue.
    const high = openFace(fontWith(2, [TableData("post", post2([0, 40_000], []))])).value;
    assert(high.glyphName(1).error.kind == FontErrorKind.badValue);

    // A Pascal string running past the table.
    auto cut = post2([258], ["long"]);
    cut = cut[0 .. $ - 2];
    const c = openFace(fontWith(1, [TableData("post", cut)])).value;
    assert(c.glyphName(0).error.kind == FontErrorKind.truncated);
    assertIndexMatches(c);

    // The index array itself past the table: every glyph is truncated.
    const array = openFace(fontWith(3, [TableData("post", postTable(0x0002_0000, u16(3) ~ u16(0)))])).value;
    assert(array.glyphName(0).error.kind == FontErrorKind.truncated);
}

@("glyphNames.post25")
@safe pure nothrow
unittest
{
    // Glyph i's name is standard[i + offset[i]].
    const t = postTable(0x0002_5000, u16(3) ~ u8(0) ~ u8(2) ~ u8(cast(ubyte) -5));
    const f = openFace(fontWith(3, [TableData("post", t)])).value;
    assert(f.glyphName(0).value.text == ".notdef" && f.glyphName(1).value.text == "space");
    assert(f.glyphName(2).error.kind == FontErrorKind.badValue);
    assertIndexMatches(f);
}

@("glyphNames.cffCharsets")
@safe pure nothrow
unittest
{
    // Format 0: glyph 1 → SID 391 ("custom"), glyph 2 → SID 34 ("A").
    const f0 = openFace(fontWith(3, [TableData("CFF ", cffTable(["custom"], u8(0) ~ u16(391) ~ u16(34)))],
        0x4F54_544F)).value;
    assert(f0.glyphName(0).value.text == ".notdef" && f0.glyphName(1).value.text == "custom");
    assert(f0.glyphName(2).value.text == "A");
    assertIndexMatches(f0);

    // Format 1: glyphs 1-3 from SID 34 ("A", "B", "C"); format 2: glyphs 1-2 from SID 66 ("a", "b").
    const f1 = openFace(fontWith(4, [TableData("CFF ", cffTable([], u8(1) ~ u16(34) ~ u8(2)))], 0x4F54_544F)).value;
    assert(f1.glyphName(3).value.text == "C");
    assertIndexMatches(f1);
    const f2 = openFace(fontWith(3, [TableData("CFF ", cffTable([], u8(2) ~ u16(66) ~ u16(1)))], 0x4F54_544F)).value;
    assert(f2.glyphName(2).value.text == "b");
    assertIndexMatches(f2);

    // Predefined ISOAdobe: glyph i is SID i.
    const iso = openFace(fontWith(40, [TableData("CFF ", cffTable([], null, 0))], 0x4F54_544F)).value;
    assert(iso.glyphName(34).value.text == "A");
    assertIndexMatches(iso);

    // CID-keyed: no names.
    const cid = openFace(fontWith(3, [TableData("CFF ", cffTable([], u8(0) ~ u16(1) ~ u16(2), 0, true))],
        0x4F54_544F)).value;
    assert(!cid.glyphName(1).value.present);
}

@("glyphNames.postFallsBackToCffPerGlyph")
@safe pure nothrow
unittest
{
    // post 2.0 names glyph 1 only; glyph 2 is past post's count and falls back to CFF.
    const f = openFace(fontWith(3, [TableData("CFF ", cffTable([], u8(0) ~ u16(66) ~ u16(67))),
        TableData("post", post2([0, 258], ["fromPost"]))], 0x4F54_544F)).value;
    assert(f.glyphName(1).value.text == "fromPost" && f.glyphName(2).value.text == "b");
    assertIndexMatches(f);
}

@("glyphNames.corpus.indexMatches")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    foreach (file; ["FiraCodeNerdFontMono-Regular.ttf", "NotoSansAnatolianHieroglyphs-Regular.otf"])
    {
        const face = openFace(bundled(file)).value;
        assertIndexMatches(face);
        assert(face.glyphName(1).value.present, file);
    }
}
