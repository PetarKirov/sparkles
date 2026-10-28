/**
The correction registry (FTD8–FTD12, FTD44–FTD46) on hand-built faces that
carry each signature byte for byte, and on near misses one byte or one unit
away. The fonts the signatures recognize may not be redistributed, so the
fixtures pad tables to the listed lengths and set the listed values;
`sparkles:font-oracle` compares the same fixtures with HarfBuzz and FreeType.
The data tables are compared with the pinned HarfBuzz source when its flake
input is exported.
*/
module sparkles.font.corrections_test;

import std.algorithm : canFind;
import std.conv : to;
import std.process : environment;
import std.regex : ctRegex, matchAll;

import sparkles.font.cmap : charMap, CmapLookup;
import sparkles.font.correction_data : arabicPuaSimplified, gdefBlocklist;
import sparkles.font.corrections;
import sparkles.font.errors : FontErrorKind;
import sparkles.font.face : Face, openFace;
import sparkles.font.fixtures;
import sparkles.font.gdef : glyphClass, inMarkGlyphSet, markAttachmentClass;
import sparkles.font.instance : instance, InstanceSize;
import sparkles.font.math_table : MathConstant, mathConstants;
import sparkles.font.raster : rasterMeasure, RasterWorkspace;
import sparkles.font.units : Ppem;

/// `data` padded with zeros to `length` bytes.
private ubyte[] padded(const(ubyte)[] data, size_t length) @safe pure nothrow
{
    auto r = data.dup;
    r.length = length;
    return r;
}

/// A face of `extra` tables beside the minimal ones.
private ubyte[] faceWith(TableData[] extra, uint sfntVersion = 0x0001_0000) @safe pure nothrow
    => sfnt(minimalTables(4) ~ extra, sfntVersion);

private Face open(const(ubyte)[] bytes, CorrectionPolicy policy = CorrectionPolicy.apply) @safe
{
    auto f = openFace(bytes, 0, policy);
    assert(f.hasValue, f.error.kind.to!string);
    return f.value;
}

// ---------------------------------------------------------------------------
// FTD9: Cambria Math's minimum heights
// ---------------------------------------------------------------------------

/// A `MATH` of `length` bytes whose MathConstants store the two minimum heights.
private ubyte[] cambriaMath(size_t length, uint delimited, uint display) @safe pure nothrow
{
    // Header (version, MathConstants at 10, no glyph info, no variants), then constants.
    auto constants = new ubyte[214];
    constants[4 .. 6] = u16(delimited);
    constants[6 .. 8] = u16(display);
    return padded(u32(0x0001_0000) ~ u16(10) ~ u16(0) ~ u16(0) ~ constants, length);
}

private long minHeight(scope const Face face, MathConstant c, out Correction correction) @safe
{
    const inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
    const v = mathConstants(inst).value[c].value;
    correction = v.correction;
    return v.value.design.raw / 65_536;
}

@("corrections.FTD9.cambriaSwap")
@safe unittest
{
    const bytes = faceWith([TableData("MATH", cambriaMath(25_722, 3_000, 2_500))]);
    auto face = open(bytes);
    assert(face.corrections.has(Correction.cambriaMathMinHeights));
    Correction c;
    assert(minHeight(face, MathConstant.delimitedSubFormulaMinHeight, c) == 2_500
        && c == Correction.cambriaMathMinHeights);
    assert(minHeight(face, MathConstant.displayOperatorMinHeight, c) == 3_000
        && c == Correction.cambriaMathMinHeights);

    // Corrections off: the stored values, no identifier.
    auto stored = open(bytes, CorrectionPolicy.off);
    assert(stored.corrections.empty);
    assert(minHeight(stored, MathConstant.delimitedSubFormulaMinHeight, c) == 3_000 && c == Correction.none);

    // One byte off the length, or one unit off either value: nothing.
    foreach (miss; [cambriaMath(25_721, 3_000, 2_500), cambriaMath(25_722, 3_001, 2_500),
            cambriaMath(25_722, 3_000, 2_499)])
        assert(!open(faceWith([TableData("MATH", miss)])).corrections.has(Correction.cambriaMathMinHeights));
}

// ---------------------------------------------------------------------------
// FTD10: GDEF tables the shaper ignores
// ---------------------------------------------------------------------------

/// A `GDEF` 1.2 of `length` bytes classing glyphs 1–3 as base, mark, ligature,
/// with mark attachment class 5 for glyph 2 and one mark glyph set holding glyph 2.
private ubyte[] gdefOf(size_t length) @safe pure nothrow
{
    // Header: version 1.2, glyph classes at 14, no attach list or carets,
    // mark attachment classes at 26, mark glyph sets at 36.
    auto header = u32(0x0001_0002) ~ u16(14) ~ u16(0) ~ u16(0) ~ u16(26) ~ u16(36);
    auto glyphClasses = u16(1) ~ u16(1) ~ u16(3) ~ u16(1) ~ u16(3) ~ u16(2); // format 1, glyphs 1..3
    auto markClasses = u16(2) ~ u16(1) ~ u16(2) ~ u16(2) ~ u16(5); // format 2, glyph 2 → 5
    auto sets = u16(1) ~ u16(1) ~ u32(8) ~ u16(1) ~ u16(1) ~ u16(2); // one set: coverage of glyph 2
    return padded(header ~ glyphClasses ~ markClasses ~ sets, length);
}

@("corrections.FTD10.gdefBlocklist")
@safe unittest
{
    // Any listed triple; the fixture's GDEF is padded to its length.
    const listed = gdefBlocklist[$ / 2];
    auto tables(uint gdef, uint gsub, uint gpos) => [TableData("GDEF", gdefOf(gdef)),
        TableData("GPOS", new ubyte[gpos]), TableData("GSUB", new ubyte[gsub])];
    auto face = open(faceWith(tables(listed.gdef, listed.gsub, listed.gpos)));
    assert(face.corrections.has(Correction.blocklistedGdef));
    foreach (gid; 0 .. 4)
    {
        const g = glyphClass(face, gid).value;
        assert(!g.present && g.correction == Correction.blocklistedGdef);
        assert(!markAttachmentClass(face, gid).value.present);
        assert(inMarkGlyphSet(face, 0, gid).value.correction == Correction.blocklistedGdef);
    }

    // The stored GDEF, with corrections off and one byte away from the triple.
    foreach (stored; [open(faceWith(tables(listed.gdef, listed.gsub, listed.gpos)), CorrectionPolicy.off),
            open(faceWith(tables(listed.gdef, listed.gsub, listed.gpos + 1)))])
    {
        assert(!stored.corrections.has(Correction.blocklistedGdef));
        assert(glyphClass(stored, 1).value == GdefClassOf(1) && glyphClass(stored, 2).value == GdefClassOf(3));
        assert(glyphClass(stored, 9).value == GdefClassOf(0));
        assert(markAttachmentClass(stored, 2).value == GdefClassOf(5));
        assert(inMarkGlyphSet(stored, 0, 2).value == GdefClassOf(1));
        assert(inMarkGlyphSet(stored, 0, 1).value == GdefClassOf(0));
        assert(inMarkGlyphSet(stored, 1, 2).error.kind == FontErrorKind.indexOutOfRange);
    }
}

private auto GdefClassOf(ushort v) @safe pure nothrow @nogc
{
    import sparkles.font.gdef : GdefClass;

    return GdefClass(true, v);
}

@("corrections.FTD10.matchesHarfBuzzSource")
@system unittest
{
    const hb = environment.get("SPARKLES_FLAKE_INPUT_HARFBUZZ_SRC");
    assert(hb !is null, "the dev shell exports SPARKLES_FLAKE_INPUT_HARFBUZZ_SRC");
    import std.file : readText;

    const source = readText(hb ~ "/src/hb-ot-layout.cc");
    size_t n;
    foreach (m; source.matchAll(ctRegex!`case HB_CODEPOINT_ENCODE3 \((\d+), (\d+), (\d+)\):`))
    {
        const t = [m[1].to!uint, m[2].to!uint, m[3].to!uint];
        assert(gdefBlocklist.canFind!(g => g.gdef == t[0] && g.gsub == t[1] && g.gpos == t[2]), m[0]);
        ++n;
    }
    assert(n == gdefBlocklist.length);

    // Every Arabic page row, the last row for a scalar winning.
    foreach (page, file; [Correction.arabicSimplifiedPage: "ArabicPUASimplified.txt",
            Correction.arabicTraditionalPage: "ArabicPUATraditional.txt"])
    {
        uint[uint] expected;
        foreach (m; readText(hb ~ "/src/" ~ file).matchAll(ctRegex!(`(?m)^0x([0-9A-F]+)\t0x([0-9A-F]+)`)))
            expected[m[2].to!uint(16)] = m[1].to!uint(16);
        assert(expected.length == arabicPuaPairs(page).length);
        foreach (scalar, pua; expected)
            assert(arabicPuaCode(page, cast(dchar) scalar) == pua);
    }
}

// ---------------------------------------------------------------------------
// FTD11: legacy Arabic code pages
// ---------------------------------------------------------------------------

/// A face with a symbol `cmap` mapping private-use `codes` to glyphs 1.., and `OS/2` `os2`.
private ubyte[] arabicFace(const(uint)[] codes, Os2Fields os2) @safe pure nothrow
{
    import std.algorithm : sort;

    Segment[] segments;
    foreach (i, code; codes)
        segments ~= Segment(code, code, cast(int)(i + 1) - cast(int) code);
    segments.sort!((a, b) => a.start < b.start);
    return sfnt([TableData("OS/2", os2Table(os2)),
        TableData("cmap", cmap([CmapRecord(3, 0, cmapFormat4(segments))])),
        TableData("head", head(2048)), TableData("maxp", maxp(cast(uint) codes.length + 1))]);
}

@("corrections.FTD11.arabicPage")
@safe unittest
{
    // ARABIC LETTER BEH, ZERO WIDTH JOINER and the private-use codes of the simplified page.
    const beh = arabicPuaCode(Correction.arabicSimplifiedPage, 'ب');
    const zwj = arabicPuaCode(Correction.arabicSimplifiedPage, '‍');
    assert(beh && zwj == 0xF10D);
    Os2Fields v0;
    v0.version_ = 0;
    v0.fsSelection = 0xB200;
    auto face = open(arabicFace([beh, zwj], v0));
    assert(face.corrections.has(Correction.arabicSimplifiedPage));
    const map = charMap(face).value;
    assert(map.lookup == CmapLookup.arabicPage);
    assert(map.lookup('ب').glyph == 1 && map.lookup('ب').correction == Correction.arabicSimplifiedPage);
    assert(map.glyph('‍') == 2);
    // The private-use code itself maps directly, without the page.
    assert(map.lookup(cast(dchar) beh).glyph == 1 && map.lookup(cast(dchar) beh).correction == Correction.none);
    // Coverage lists the mapped scalars and no U+F000 duplication.
    bool[dchar] covered;
    foreach (r; map.ranges)
        foreach (cp; r.first .. r.last + 1)
            covered[cast(dchar) cp] = true;
    assert('ب' in covered && '‍' in covered && 'A' !in covered);

    // Version 1, another high byte, or corrections off: the ordinary symbol mapping.
    Os2Fields v1 = v0;
    v1.version_ = 1;
    Os2Fields other = v0;
    other.fsSelection = 0xB100;
    foreach (f; [open(arabicFace([beh, zwj], v1)), open(arabicFace([beh, zwj], other)),
            open(arabicFace([beh, zwj], v0), CorrectionPolicy.off)])
    {
        const m = charMap(f).value;
        assert(m.lookup == CmapLookup.symbol && m.glyph('ب') == 0 && m.glyph(cast(dchar) beh) == 1);
    }
    // The traditional page.
    Os2Fields trad = v0;
    trad.fsSelection = 0xB300;
    assert(open(arabicFace([beh], trad)).corrections.has(Correction.arabicTraditionalPage));
}

// ---------------------------------------------------------------------------
// FTD12: faces that only their bytecode can draw
// ---------------------------------------------------------------------------

private ubyte[] namedFace(const(ubyte)[] family, uint sfntVersion = 0x0001_0000) @safe pure nothrow
    => faceWith([TableData("name", name([NameEntry(3, 1, 0x409, 1, family)]))], sfntVersion);

/// A table of `length` bytes whose computed checksum is `sum`.
private ubyte[] withChecksum(uint length, uint sum) @safe pure nothrow
{
    auto t = new ubyte[length];
    if (length >= 4)
        t[0 .. 4] = u32(sum);
    return t;
}

@("corrections.FTD12.trickyByName")
@safe unittest
{
    auto face = open(namedFace(utf16be("PMingLiU")));
    assert(face.requiresBytecode && face.corrections.has(Correction.requiresBytecode));
    // A subset tag is skipped, and a non-ASCII character reads as '?', as in "HuaTianKaiTi?".
    assert(open(namedFace(utf16be("ABCDEF+DFKai-SB"))).requiresBytecode);
    assert(open(namedFace(utf16be("HuaTianKaiTi") ~ u16(0x4E2D))).requiresBytecode);
    assert(!open(namedFace(utf16be("HuaTianKaiTi"))).requiresBytecode);
    assert(!open(namedFace(utf16be("Noto Sans"))).requiresBytecode);
    // Only the TrueType driver checks: a CFF face never requires bytecode.
    assert(!open(namedFace(utf16be("MingLiU"), 0x4F54_544F)).requiresBytecode);
    assert(!open(namedFace(utf16be("MingLiU")), CorrectionPolicy.off).requiresBytecode);

    // The rasterizer refuses it, naming the correction.
    const inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
    const r = rasterMeasure(inst, 1, Ppem.fromInteger(16).value, RasterWorkspace.init);
    assert(r.error.kind == FontErrorKind.unsupportedCapability && r.error.correction == Correction.requiresBytecode);
}

@("corrections.FTD12.trickyByTables")
@safe unittest
{
    // MingLiU 1995: cvt 0x2E4 / 0x05BCF058, fpgm 0x87C4 / 0x28233BF1, prep 0x1E1 / 0xA344A1EA.
    auto tables(uint prepSum) => [TableData("cvt ", withChecksum(0x2E4, 0x05BC_F058)),
        TableData("fpgm", withChecksum(0x87C4, 0x2823_3BF1)), TableData("prep", withChecksum(0x1E1, prepSum))];
    assert(open(faceWith(tables(0xA344_A1EA))).requiresBytecode);
    // MingLiU 1996 differs only in prep's checksum.
    assert(open(faceWith(tables(0xA344_A1EB))).requiresBytecode);
    assert(!open(faceWith(tables(0xA344_A1EC))).requiresBytecode);
}
