/**
The correction registry (FTD9–FTD12, FTD44–FTD46) against the engines it
follows, as `testing.md` § Compatibility quirks lays out. The fonts most
entries recognize may not be redistributed, so each signature is rebuilt by
`sparkles.font.fixtures` from the registry's own lists
(`sparkles.font.oracle_registry`), beside near misses one byte or one unit
away, and every fixture is read by both sides:

$(UL
    $(LI FTD9: Cambria Math's minimum heights, on HarfBuzz's own
        `MathTestFontPretendToBeCambria.ttf` and on fixtures, against
        `hb_ot_math_get_constant`.)
    $(LI FTD10: every blocklisted `GDEF`/`GSUB`/`GPOS` length triple and a
        near miss per triple, each glyph's class and carets against
        `hb_ot_layout_get_glyph_class` and `hb_ot_layout_get_ligature_carets`.)
    $(LI FTD11: symbol `cmap`s over each legacy Arabic page's private-use
        codes, under every `OS/2` version and `fsSelection` high byte that
        selects or misses a page, against `hb_font_get_nominal_glyph`.)
    $(LI FTD12: faces named after each tricky family and faces whose
        `cvt `, `fpgm` and `prep` match each tricky face, against FreeType's
        `FT_IS_TRICKY`.)
)
*/
module sparkles.font_oracle.corrections;

import std.algorithm : canFind, sort;
import std.conv : text, to;
import std.file : exists, read;
import std.path : buildPath;
import std.process : environment;
import std.stdio : stderr;

import sparkles.base.unique : makeUnique;
import sparkles.font;
import fx = sparkles.font.fixtures;
import sparkles.font.oracle_registry;
import sparkles.font_oracle;
import sparkles.font_oracle.corpus : Oracle, testFontsDir, withEmptyCmap;
import sparkles.font_oracle.freetype_c : FT_Done_Face, FT_Done_FreeType, FT_Face, FT_FACE_FLAG_TRICKY,
    FT_Init_FreeType, FT_Int, FT_Library, FT_Library_Version, FT_Long, FT_New_Memory_Face;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// `data` padded with zeros to `length` bytes.
private ubyte[] padded(const(ubyte)[] data, size_t length) @safe pure nothrow
in (data.length <= length)
{
    auto r = data.dup;
    r.length = length;
    return r;
}

/// A face of `tables` beside `base`, its directory in tag order (HarfBuzz binary-searches it).
private ubyte[] fixtureFace(const(fx.TableData)[] tables, const(fx.TableData)[] base = fx.minimalTables(5))
    @safe pure nothrow
{
    fx.TableData[] all;
    all ~= base;
    all ~= tables;
    all.sort!((a, b) => a.tag < b.tag);
    return fx.sfnt(all);
}

/// Face 0 of `bytes` under `policy`, with an empty `cmap` added when that alone is missing.
private Face open(ref const(ubyte)[] bytes, CorrectionPolicy policy = CorrectionPolicy.apply) @safe
{
    auto f = openFace(bytes, 0, policy);
    if (f.hasError && f.error.kind == FontErrorKind.missingTable && f.error.tag == Tag("cmap"))
    {
        bytes = withEmptyCmap(bytes);
        f = openFace(bytes, 0, policy);
    }
    assert(f.hasValue, text(f.error));
    return f.value;
}

private uint be16(scope const(ubyte)[] d, size_t at) @safe pure nothrow @nogc => (uint(d[at]) << 8) | d[at + 1];

// ---------------------------------------------------------------------------
// FTD9: Cambria Math's minimum heights
// ---------------------------------------------------------------------------

/// A `MATH` of `length` bytes whose MathConstants store the two minimum heights (cf. corrections_test.d).
private ubyte[] cambriaMath(size_t length, uint delimited, uint display) @safe pure nothrow
{
    // Header (version 1.0, MathConstants at 10, no glyph info, no variants), then the 214-byte constants.
    auto constants = new ubyte[214];
    constants[4 .. 6] = fx.u16(delimited);
    constants[6 .. 8] = fx.u16(display);
    return padded(fx.u32(0x0001_0000) ~ fx.u16(10) ~ fx.u16(0) ~ fx.u16(0) ~ constants, length);
}

/**
Checks the two minimum heights of `bytes` with HarfBuzz: under
`CorrectionPolicy.apply` ours equal `hb_ot_math_get_constant`'s and carry
`cambriaMathMinHeights` exactly when `swapped`; under `off` they are the
stored values, with no identifier. Returns whether HarfBuzz swapped them.
*/
private bool checkMinHeights(string label, const(ubyte)[] bytes, bool swapped) @system
{
    auto face = open(bytes);
    auto stored = open(bytes, CorrectionPolicy.off);
    auto hb = Oracle(bytes, 0);
    hb_font_set_scale(hb.font, face.unitsPerEm, face.unitsPerEm);
    const math = face.table(Tag("MATH")).value;
    const constantsAt = be16(math, 4);
    // minHeight[0] is delimitedSubFormulaMinHeight, minHeight[1] displayOperatorMinHeight.
    const short[2] raw = [cast(short) be16(math, constantsAt + 4), cast(short) be16(math, constantsAt + 6)];
    const MathConstant[2] ours = [MathConstant.delimitedSubFormulaMinHeight, MathConstant.displayOperatorMinHeight];
    const hb_ot_math_constant_t[2] theirs = [HB_OT_MATH_CONSTANT_DELIMITED_SUB_FORMULA_MIN_HEIGHT,
        HB_OT_MATH_CONSTANT_DISPLAY_OPERATOR_MIN_HEIGHT];
    bool hbSwapped = true;
    foreach (k; 0 .. 2)
    {
        const at16 = InstanceSize.pixels(Ppem.fromInteger(16).value);
        const applied = mathConstants(face.instance(at16, null).value).value[ours[k]].value;
        const plain = mathConstants(stored.instance(at16, null).value).value[ours[k]].value;
        const expected = hb_ot_math_get_constant(hb.font, theirs[k]);
        assert(applied.value.design.raw == expected * 65_536L, text(label, " ", ours[k], ": ",
            applied.value.design.raw / 65_536.0, " vs HarfBuzz ", expected));
        assert(applied.correction == (swapped ? Correction.cambriaMathMinHeights : Correction.none),
            text(label, " ", ours[k], ": ", applied.correction));
        assert(plain.value.design.raw == raw[k] * 65_536L && plain.correction == Correction.none,
            text(label, " ", ours[k], " with corrections off"));
        hbSwapped &= expected == raw[1 - k] && raw[0] != raw[1];
    }
    assert(face.corrections.has(Correction.cambriaMathMinHeights) == swapped, label);
    assert(stored.corrections.empty, label);
    return hbSwapped;
}

@("oracle.corrections.cambriaMath")
@system
unittest
{
    // HarfBuzz's own test font is part of the pinned corpus: its absence is a failure, not a skip.
    assert(testFontsDir !is null, "SPARKLES_FONT_TEST_CORPUS is unset; the dev shell exports the pinned corpus");
    const path = buildPath(testFontsDir, "harfbuzz", "MathTestFontPretendToBeCambria.ttf");
    assert(path.exists, path ~ " is missing from the pinned corpus");
    size_t faces;
    assert(checkMinHeights("MathTestFontPretendToBeCambria.ttf", cast(const(ubyte)[]) read(path), true));
    ++faces;

    // Fixtures: the signature, then one byte off the length or one unit off either value.
    assert(checkMinHeights("fixture", fixtureFace([fx.TableData("MATH", cambriaMath(25_722, 3_000, 2_500))]), true));
    foreach (miss; [cambriaMath(25_721, 3_000, 2_500), cambriaMath(25_723, 3_000, 2_500),
            cambriaMath(25_722, 3_001, 2_500), cambriaMath(25_722, 3_000, 2_499), cambriaMath(25_722, 2_500, 3_000)])
    {
        assert(!checkMinHeights(text("near miss ", ++faces), fixtureFace([fx.TableData("MATH", miss)]), false));
    }
    stderr.writefln("oracle.corrections.cambriaMath: HarfBuzz's MathTestFontPretendToBeCambria.ttf, the fixture "
        ~ "and %s near misses agree with hb_ot_math_get_constant (applied and off)", faces - 1);
}

// ---------------------------------------------------------------------------
// FTD10: GDEF tables the shaper ignores
// ---------------------------------------------------------------------------

/**
A `GDEF` 1.2 of `length` bytes: glyphs 1–3 classed base, mark and ligature;
mark attachment class 5 for glyph 2; one mark glyph set holding glyph 2;
and two format-1 carets, at 300 and 600 units, for the ligature, glyph 3.
*/
private ubyte[] gdefOf(size_t length) @safe pure nothrow
{
    // Header: version 1.2, glyph classes at 14, no attach list, carets at 50,
    // mark attachment classes at 26, mark glyph sets at 36.
    auto header = fx.u32(0x0001_0002) ~ fx.u16(14) ~ fx.u16(0) ~ fx.u16(50) ~ fx.u16(26) ~ fx.u16(36);
    auto glyphClasses = fx.u16(1) ~ fx.u16(1) ~ fx.u16(3) ~ fx.u16(1) ~ fx.u16(3) ~ fx.u16(2);
    auto markClasses = fx.u16(2) ~ fx.u16(1) ~ fx.u16(2) ~ fx.u16(2) ~ fx.u16(5);
    auto sets = fx.u16(1) ~ fx.u16(1) ~ fx.u32(8) ~ fx.u16(1) ~ fx.u16(1) ~ fx.u16(2);
    // LigCaretList: coverage at +6, one LigGlyph at +12; the LigGlyph's two CaretValues at +6 and +10.
    auto carets = fx.u16(6) ~ fx.u16(1) ~ fx.u16(12) ~ fx.u16(1) ~ fx.u16(1) ~ fx.u16(3)
        ~ fx.u16(2) ~ fx.u16(6) ~ fx.u16(10) ~ fx.u16(1) ~ fx.u16(300) ~ fx.u16(1) ~ fx.u16(600);
    auto bytes = header ~ glyphClasses ~ markClasses ~ sets ~ carets;
    assert(bytes.length == 76);
    return padded(bytes, length);
}

/**
A `GSUB` or `GPOS` 1.0 of `length` bytes HarfBuzz's sanitizer accepts: empty
script, feature and lookup lists, then zeros. A zero-filled table fails it,
and HarfBuzz then reads the table's length as 0.
*/
private ubyte[] layoutOf(size_t length) @safe pure nothrow
    => padded(fx.u32(0x0001_0000) ~ fx.u16(10) ~ fx.u16(12) ~ fx.u16(14) ~ fx.u16(0) ~ fx.u16(0) ~ fx.u16(0), length);

private ubyte[] blocklistFixture(uint gdef, uint gsub, uint gpos, bool sanitizable = true) @safe pure nothrow
    => fixtureFace([fx.TableData("GDEF", gdefOf(gdef)),
        fx.TableData("GPOS", sanitizable ? layoutOf(gpos) : new ubyte[gpos]),
        fx.TableData("GSUB", sanitizable ? layoutOf(gsub) : new ubyte[gsub])]);

/// What `gdefOf` stores for each glyph's class, `[0, 4]`.
private immutable ushort[5] storedClass = [0, 1, 3, 2, 0];

/**
Compares every glyph's class and carets of `bytes` with HarfBuzz; `hidden`
says whether the registry (and HarfBuzz) ignore its `GDEF`. Returns the
glyphs compared.
*/
private size_t checkGdef(string label, const(ubyte)[] bytes, bool hidden) @system
{
    auto face = open(bytes);
    auto hb = Oracle(bytes, 0);
    hb_font_set_scale(hb.font, face.unitsPerEm, face.unitsPerEm);
    const inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
    auto ws = makeUnique!PointWorkspace();
    assert(face.corrections.has(Correction.blocklistedGdef) == hidden, label);
    size_t glyphs;
    foreach (gid; 0 .. face.numGlyphs)
    {
        const at = text(label, " glyph ", gid);
        const theirs = cast(uint) hb_ot_layout_get_glyph_class(hb.face, gid);
        const ours = glyphClass(face, gid).value;
        if (hidden)
            assert(theirs == 0 && !ours.present && ours.correction == Correction.blocklistedGdef, at);
        else
            assert(ours.present && ours.value == theirs && theirs == storedClass[gid]
                && ours.correction == Correction.none, text(at, ": ", ours, " vs HarfBuzz ", theirs));

        int[8] hbCarets;
        uint count = hbCarets.length;
        const total = hb_ot_layout_get_ligature_carets(hb.font, HB_DIRECTION_LTR, gid, 0, &count, hbCarets.ptr);
        LigatureCaret[8] carets;
        const r = ligatureCarets(inst, gid, 0, true, carets[], *ws).value;
        assert(r.present == (total != 0) && (!r.present || r.count == total), at);
        assert(r.correction == (hidden ? Correction.blocklistedGdef : Correction.none), text(at, ": ", r));
        foreach (k; 0 .. count)
            assert(carets[k].coordinate.raw == hbCarets[k] * 65_536L, text(at, " caret ", k));
        assert(total == (!hidden && gid == 3 ? 2 : 0), at);
        ++glyphs;
    }
    return glyphs;
}

@("oracle.corrections.gdefBlocklist")
@system
unittest
{
    const listed = registryGdefBlocklist();
    assert(listed.length == 40);
    bool isListed(uint gdef, uint gsub, uint gpos)
        => listed.canFind!(t => t.gdef == gdef && t.gsub == gsub && t.gpos == gpos);
    size_t triples, nearMisses, glyphs, unsanitized;
    foreach (t; listed)
    {
        const label = text("(", t.gdef, ", ", t.gsub, ", ", t.gpos, ")");
        glyphs += checkGdef(label, blocklistFixture(t.gdef, t.gsub, t.gpos), true);
        ++triples;
        // One byte off GPOS, then off GSUB and off GDEF: the stored GDEF.
        foreach (miss; [[t.gdef, t.gsub, t.gpos + 1], [t.gdef, t.gsub + 1, t.gpos], [t.gdef + 1, t.gsub, t.gpos]])
        {
            assert(!isListed(miss[0], miss[1], miss[2]), label);
            glyphs += checkGdef(text(label, " near miss ", miss), blocklistFixture(miss[0], miss[1], miss[2]),
                false);
            ++nearMisses;
        }

        // Known divergence: HarfBuzz keys the blocklist on its sanitized blobs,
        // and a GSUB and GPOS its sanitizer rejects read as length 0, so it
        // keeps this GDEF; the registry reads the table directory's lengths.
        const zeroFilled = blocklistFixture(t.gdef, t.gsub, t.gpos, sanitizable: false);
        auto hb = Oracle(zeroFilled, 0);
        const(ubyte)[] bytes = zeroFilled;
        assert(open(bytes).corrections.has(Correction.blocklistedGdef), label);
        assert(cast(uint) hb_ot_layout_get_glyph_class(hb.face, 2) == storedClass[2], label);
        ++unsanitized;
    }
    stderr.writefln("oracle.corrections.gdefBlocklist: %s listed triples and %s near misses, %s glyphs' classes "
        ~ "and carets agree with HarfBuzz; %s zero-filled GSUB/GPOS fixtures diverge as listed (HarfBuzz "
        ~ "sanitizes them to length 0 and keeps GDEF)", triples, nearMisses, glyphs, unsanitized);
    assert(triples == 40 && nearMisses == 120);
}

@("oracle.corrections.gdefBlocklistUnfree")
@system
unittest
{
    // FTD10's Microsoft faces: classes and carets of every glyph, whether or not a listed version.
    import std.algorithm : endsWith, filter, map;
    import std.array : array;
    import std.file : dirEntries, SpanMode;
    import std.path : baseName;
    import sparkles.test_runner.skip : skipTest;

    const corpus = environment.get("SPARKLES_FONT_UNFREE_CORPUS");
    if (corpus is null)
        return skipTest("SPARKLES_FONT_UNFREE_CORPUS is unset: build .#sparkles-font-unfree-corpus");
    size_t faces, listedFaces, glyphs;
    foreach (path; dirEntries(corpus, SpanMode.depth).filter!(e => e.name.endsWith(".ttf")).map!(e => e.name).array.sort)
    {
        const(ubyte)[] bytes = cast(const(ubyte)[]) read(path);
        auto face = open(bytes);
        auto hb = Oracle(bytes, 0);
        const hidden = face.corrections.has(Correction.blocklistedGdef);
        foreach (gid; 0 .. face.numGlyphs)
        {
            const ours = glyphClass(face, gid);
            const theirs = cast(uint) hb_ot_layout_get_glyph_class(hb.face, gid);
            const v = ours.hasValue && ours.value.present ? ours.value.value : 0;
            assert(v == theirs, text(path.baseName, " glyph ", gid, ": ", v, " vs HarfBuzz ", theirs));
            ++glyphs;
        }
        ++faces;
        listedFaces += hidden;
    }
    stderr.writefln("oracle.corrections.gdefBlocklistUnfree: %s faces (%s on the blocklist), %s glyph classes agree "
        ~ "with HarfBuzz", faces, listedFaces, glyphs);
}

// ---------------------------------------------------------------------------
// FTD11: legacy Arabic code pages
// ---------------------------------------------------------------------------

/// A face with a symbol `cmap` mapping `codes` to glyphs 1.., and `OS/2` `os2`.
private ubyte[] arabicFixture(const(uint)[] codes, fx.Os2Fields os2) @safe pure nothrow
{
    fx.Segment[] segments;
    foreach (i, code; codes)
        segments ~= fx.Segment(code, code, cast(int)(i + 1) - cast(int) code);
    segments.sort!((a, b) => a.start < b.start);
    return fixtureFace([fx.TableData("OS/2", fx.os2Table(os2)),
        fx.TableData("cmap", fx.cmap([fx.CmapRecord(3, 0, fx.cmapFormat4(segments))])),
        fx.TableData("head", fx.head(2048)), fx.TableData("maxp", fx.maxp(cast(uint) codes.length + 1))], null);
}

@("oracle.corrections.arabicPage")
@system
unittest
{
    // Every scalar of both pages, the Latin-1 range symbol fonts duplicate at
    // U+F000, the Arabic blocks, and every private-use code a fixture maps.
    bool[dchar] probeSet;
    foreach (traditional; [false, true])
        foreach (p; registryArabicPage(traditional))
            probeSet[p.unicode] = probeSet[p.pua] = true;
    foreach (cp; 0 .. 0x100)
        probeSet[cp] = probeSet[0xF000 + cp] = true;
    foreach (cp; 0x0600 .. 0x0700)
        probeSet[cp] = true;
    foreach (cp; 0xFB50 .. 0xFF00)
        probeSet[cp] = true;
    auto probes = probeSet.keys;
    probes.sort;

    struct Variant
    {
        uint version_, fsSelection;
    }
    // Each page, the page with other low bits, OS/2 version 1, no page, and other high bytes.
    static immutable Variant[] variants = [Variant(0, 0xB200), Variant(0, 0xB300), Variant(0, 0xB240),
        Variant(0, 0xB301), Variant(1, 0xB200), Variant(1, 0xB300), Variant(0, 0x0000), Variant(0, 0x0040),
        Variant(0, 0xB100), Variant(0, 0xB400), Variant(0, 0xB500)];

    size_t faces, lookups, viaPage;
    foreach (traditional; [false, true])
    {
        // The page's private-use codes, and two U+F0xx codes for the symbol duplication.
        bool[uint] codeSet = [0xF041: true, 0xF0E9: true];
        foreach (p; registryArabicPage(traditional))
            codeSet[p.pua] = true;
        auto codes = codeSet.keys;
        codes.sort;
        foreach (v; variants)
        {
            fx.Os2Fields os2;
            os2.version_ = v.version_;
            os2.fsSelection = v.fsSelection;
            const(ubyte)[] bytes = arabicFixture(codes, os2);
            auto face = open(bytes);
            auto hb = Oracle(bytes, 0);
            const map = charMap(face).value;
            const label = text(traditional ? "traditional" : "simplified", " codes, OS/2 ", v.version_,
                " fsSelection 0x", v.fsSelection.to!string(16));
            const page = v.version_ == 0 && (v.fsSelection >> 8) == 0xB2 ? Correction.arabicSimplifiedPage
                : v.version_ == 0 && (v.fsSelection >> 8) == 0xB3 ? Correction.arabicTraditionalPage
                : Correction.none;
            assert(face.corrections.has(page) || page == Correction.none, label);
            assert((map.lookup == CmapLookup.arabicPage) == (page != Correction.none), label);
            bool[dchar] covered;
            foreach (r; map.ranges)
                foreach (cp; r.first .. r.last + 1)
                    covered[cast(dchar) cp] = true;
            foreach (cp; probes)
            {
                const ours = map.lookup(cp);
                uint theirs;
                if (!hb_font_get_nominal_glyph(hb.font, cp, &theirs))
                    theirs = 0;
                ++lookups;
                assert(ours.glyph == theirs, text(label, ": U+", (cast(uint) cp).to!string(16), " ", ours.glyph,
                    " vs HarfBuzz ", theirs));
                // A glyph the page found names it; the coverage lists every scalar the page maps.
                assert(ours.correction == Correction.none || ours.correction == page, label);
                viaPage += ours.correction != Correction.none;
                if (page != Correction.none)
                    assert(((cp in covered) !is null) == (ours.glyph != 0), text(label, ": U+",
                        (cast(uint) cp).to!string(16), " coverage"));
            }
            ++faces;
        }
    }
    stderr.writefln("oracle.corrections.arabicPage: %s fixtures, %s lookups (%s through a page) agree with "
        ~ "hb_font_get_nominal_glyph", faces, lookups, viaPage);
    assert(viaPage > 400);
}

// ---------------------------------------------------------------------------
// FTD12: faces that only their bytecode can draw
// ---------------------------------------------------------------------------

/// A FreeType library for the fixtures, released with the value.
private struct FreeType
{
    FT_Library library;

    @disable this(this);

    static FreeType open() @trusted
    {
        FreeType r;
        assert(FT_Init_FreeType(&r.library) == 0);
        return r;
    }

    ~this() @trusted
    {
        if (library)
            FT_Done_FreeType(library);
    }

    /// `FT_IS_TRICKY` of face 0 of `bytes`, which FreeType's TrueType driver must open.
    bool tricky(const(ubyte)[] bytes, string label) @trusted
    {
        FT_Face face;
        const error = FT_New_Memory_Face(library, bytes.ptr, cast(FT_Long) bytes.length, 0, &face);
        assert(error == 0, text(label, ": FreeType error ", error));
        scope (exit)
            FT_Done_Face(face);
        return (face.face_flags & FT_FACE_FLAG_TRICKY) != 0;
    }
}

/**
The tables every FTD12 fixture has: FreeType's TrueType driver needs `hhea`,
`hmtx` and `loca` beside the minimal ones; `glyf` is empty.
*/
private fx.TableData[] trueTypeBase() @safe pure nothrow
    => fx.minimalTables(4) ~ [fx.TableData("hhea", fx.hhea(4)),
        fx.TableData("hmtx", fx.hmtx([[500, 0], [500, 0], [500, 0], [500, 0]])),
        fx.TableData("loca", new ubyte[10]), fx.TableData("glyf", null)];

/**
A table of `length` bytes holding a pattern, its first word set so that
the table's checksum, the trailing partial word padded with zeros, is `sum`.
*/
private ubyte[] withChecksum(uint length, uint sum) @safe pure nothrow
in (length >= 4)
{
    auto t = new ubyte[length];
    foreach (i, ref b; t[4 .. $])
        b = cast(ubyte)(i * 31 + 7);
    t[0 .. 4] = fx.u32(sum - fx.checksum(t));
    assert(fx.checksum(t) == sum);
    return t;
}

/// The family name bytes of a tricky name: a trailing `?` stands for a character FreeType reads as `?` (U+4E2D).
private ubyte[] familyBytes(string name) @safe pure nothrow
    => name[$ - 1] == '?' ? fx.utf16be(name[0 .. $ - 1]) ~ fx.u16(0x4E2D) : fx.utf16be(name);

@("oracle.corrections.trickyFaces")
@system
unittest
{
    auto ft = FreeType.open();
    FT_Int major, minor, patch;
    FT_Library_Version(ft.library, &major, &minor, &patch);
    assert(major == 2 && minor == 14 && patch == 3, text("FreeType ", major, ".", minor, ".", patch,
        "; the registry follows 2.14.3"));

    size_t fixtures, tricky;
    void check(string label, const(fx.TableData)[] tables)
    {
        const(ubyte)[] bytes = fixtureFace(tables, trueTypeBase());
        const ours = open(bytes).requiresBytecode;
        const theirs = ft.tricky(bytes, label);
        assert(ours == theirs, text(label, ": requiresBytecode ", ours, ", FT_IS_TRICKY ", theirs));
        assert(open(bytes, CorrectionPolicy.off).corrections.empty, label);
        ++fixtures;
        tricky += theirs;
    }
    fx.TableData nameTable(const(fx.NameEntry)[] entries) => fx.TableData("name", fx.name(entries));
    fx.NameEntry win(uint id, const(ubyte)[] s, uint language = 0x409) => fx.NameEntry(3, 1, language, id, s);

    // By name: each family, behind a subset tag, inside a longer name, and one character short.
    const names = registryTrickyNames();
    assert(names.length == 20);
    size_t namesTricky;
    foreach (n; names)
    {
        const family = familyBytes(n);
        foreach (spelling; [family, fx.utf16be("ABCDEF+") ~ family, fx.utf16be("Old ") ~ family ~ fx.utf16be(" Bold")])
            check(text("name ", n), [nameTable([win(1, spelling)])]);
        namesTricky += 3;
        check(text("name ", n, " one short"), [nameTable([win(1, family[0 .. $ - 2])])]);
    }
    // The literal '?' is the conversion's result, so it matches too.
    check("name HuaTianKaiTi? in ASCII", [nameTable([win(1, fx.utf16be("HuaTianKaiTi?"))])]);
    // Which record FreeType reads the family from: ID 16 when OS/2's fsSelection has bit 8, else ID 21 first.
    const pml = fx.utf16be("PMingLiU"), other = fx.utf16be("Other");
    fx.Os2Fields wws;
    wws.fsSelection = 0x100;
    check("ID 21 other, ID 16 tricky, no OS/2", [nameTable([win(1, other), win(16, pml), win(21, other)])]);
    check("ID 21 other, ID 16 tricky, OS/2 bit 8", [nameTable([win(1, other), win(16, pml), win(21, other)]),
        fx.TableData("OS/2", fx.os2Table(wws))]);
    check("ID 16 other, ID 1 tricky", [nameTable([win(1, pml), win(16, other)])]);
    // Macintosh records, and a non-English Windows record beside them.
    const macPml = cast(const(ubyte)[]) "PMingLiU";
    check("Macintosh record", [nameTable([fx.NameEntry(1, 0, 0, 1, macPml)])]);
    check("Japanese Windows record, English Macintosh",
        [nameTable([fx.NameEntry(1, 0, 0, 1, cast(const(ubyte)[]) "Other"), win(1, pml, 0x411)])]);
    check("Japanese Windows record, no Macintosh", [nameTable([win(1, pml, 0x411)])]);
    check("Unicode-platform record", [nameTable([fx.NameEntry(0, 3, 0, 1, pml)])]);
    check("a NUL ends the name", [nameTable([win(1, fx.utf16be("Ming") ~ fx.u16(0) ~ fx.utf16be("LiU"))])]);

    // By cvt, fpgm and prep: each listed face, and near misses one unit or one byte away.
    const faces = registryTrickyTables();
    assert(faces.length == 31);
    static immutable string[3] tags = ["cvt ", "fpgm", "prep"];
    fx.TableData[] tablesOf(const(uint[2])[3] entry)
    {
        fx.TableData[] r;
        foreach (k; 0 .. 3)
            if (entry[k][1])
                r ~= fx.TableData(tags[k], withChecksum(entry[k][1], entry[k][0]));
        return r;
    }
    foreach (i, f; faces)
    {
        uint[2][3] entry;
        foreach (k; 0 .. 3)
            entry[k] = [f[k].checksum, f[k].length];
        check(text("tables of face ", i), tablesOf(entry));
        foreach (k; 0 .. 3)
        {
            if (!entry[k][1])
            {
                // A listed absence: the table present with a stray length, then present but empty.
                check(text("face ", i, " with a ", tags[k]), tablesOf(entry)
                    ~ fx.TableData(tags[k], withChecksum(8, 0)));
                check(text("face ", i, " with an empty ", tags[k]), tablesOf(entry) ~ fx.TableData(tags[k], null));
                continue;
            }
            auto sum = entry, length = entry;
            sum[k][0] += 0x0100_0000;
            length[k][1] += 1;
            check(text("face ", i, " ", tags[k], " checksum off"), tablesOf(sum));
            check(text("face ", i, " ", tags[k], " one byte longer"), tablesOf(length));
        }
    }
    stderr.writefln("oracle.corrections.trickyFaces: FreeType %s.%s.%s; %s fixtures (%s by name; %s tricky in all) "
        ~ "agree with FT_IS_TRICKY", major, minor, patch, fixtures, namesTricky, tricky);
    assert(tricky >= namesTricky + faces.length);
}
