/**
The M4 shaping checks against the pinned HarfBuzz (testing.md § Shaping).
The FTS8 manifest is checked against the pinned HarfBuzz source: its
version, and the Unicode release each internal table was generated from.
Base's Unicode callbacks are compared with HarfBuzz's own over every
scalar, and HarfBuzz's hand-coded default ignorables with base's, by
shaping every scalar. Recorded `hb-shape` output for fixed strings
(FTS1) is a separate call path through the same engine: it checks the
wrapper, not the engine.
*/
module sparkles.font_oracle.shaping;

import std.conv : text, to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, read, readText;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.process : environment;
import std.regex : matchAll, regex;
import std.string : lineSplitter, split, startsWith, strip;

import sparkles.base.text.unicode_tables : unicodeProperty, UnicodeProperty, unicodeVersion;
import sparkles.font;
import sparkles.font_oracle;
import sparkles.font_oracle.corpus : fontsDir;
import sparkles.test_runner.skip : skipTest;

/// The internal tables of the manifest, by source path, generated from UCD files.
private immutable string[] generatedTables = [
    "src/hb-ucd-table.hh",
    "src/hb-unicode-emoji-table.hh",
    "src/hb-ot-shaper-arabic-joining-list.hh",
    "src/hb-ot-shaper-arabic-table.hh",
    "src/hb-ot-shaper-indic-table.cc",
    "src/hb-ot-shaper-use-table.hh",
    "src/hb-ot-shaper-vowel-constraints.cc",
];

/// The `Default_Ignorable_Code_Point` ranges of a `DerivedCoreProperties.txt`.
private bool[] defaultIgnorables(string text)
{
    auto set = new bool[0x110000];
    foreach (line; text.lineSplitter)
    {
        const data = line.split('#');
        const fields = data.length ? data[0].split(';') : null;
        if (fields.length != 2 || fields[1].strip != "Default_Ignorable_Code_Point")
            continue;
        const range = fields[0].strip.split("..");
        const first = range[0].to!uint(16), last = range[$ - 1].to!uint(16);
        foreach (cp; first .. last + 1)
            set[cp] = true;
    }
    return set;
}

/**
FTS8: the pinned source is the manifest's release, and every internal
table it generated from UCD files names the manifest's Unicode release
— except the USE table's `DerivedCoreProperties`, which 14.6.0 still
reads from 17.0.0. That input is compatible when its only property the
generator reads, `Default_Ignorable_Code_Point`, equals base's 18.0.0.
*/
@("oracle.shaping.FTS8.manifest")
@system
unittest
{
    const src = environment.get("SPARKLES_FLAKE_INPUT_HARFBUZZ_SRC");
    assert(src !is null && exists(src), "the dev shell exports the pinned HarfBuzz source");
    assert(readText(buildPath(src, "src/hb-version.h"))
        .canFindText(`#define HB_VERSION_STRING "` ~ pinnedEngine.harfBuzzVersion ~ `"`));
    assert(pinnedEngine.unicodeVersion == unicodeVersion, "the manifest names base's release");

    auto versions = regex(`(?:-|Unicode |Version: )(\d+\.\d+\.\d+)`);
    auto useDcp = regex(`DerivedCoreProperties-(\d+\.\d+\.\d+)\.txt`);
    string useDcpVersion;
    foreach (table; generatedTables)
    {
        // The provenance comment heads each generated file.
        string header;
        foreach (i, line; readText(buildPath(src, table)).lineSplitter.enumerateLines)
        {
            if (i == 40)
                break;
            header ~= line ~ "\n";
        }
        foreach (m; header.matchAll(useDcp))
            useDcpVersion = m[1];
        size_t named;
        foreach (m; header.matchAll(versions))
        {
            if (m.pre.length >= 21 && m.pre[$ - 21 .. $] == "DerivedCoreProperties")
                continue;
            assert(m[1] == pinnedEngine.unicodeVersion, text(table, " names Unicode ", m[1]));
            ++named;
        }
        assert(named > 0, table ~ " names no Unicode release");
    }

    assert(useDcpVersion.length, "the USE table names its DerivedCoreProperties release");
    if (useDcpVersion != pinnedEngine.unicodeVersion)
    {
        const ucd = environment.get("SPARKLES_HARFBUZZ_USE_UCD");
        assert(ucd !is null, "the dev shell exports the UCD the USE table was generated from");
        const dcp = readText(buildPath(ucd, "DerivedCoreProperties.txt"));
        assert(dcp.startsWith("# DerivedCoreProperties-" ~ useDcpVersion ~ ".txt"),
            "SPARKLES_HARFBUZZ_USE_UCD is not the USE table's release " ~ useDcpVersion);
        const older = defaultIgnorables(dcp);
        foreach (cp; 0 .. 0x110000)
            assert(older[cp] == unicodeProperty(cast(dchar) cp, UnicodeProperty.DI),
                text("Default_Ignorable_Code_Point differs at U+", cp.to!string(16), " between ",
                    useDcpVersion, " and ", unicodeVersion));
    }
}

private bool canFindText(string haystack, string needle)
{
    import std.algorithm.searching : canFind;

    return haystack.canFind(needle);
}

private auto enumerateLines(R)(R lines)
{
    import std.range : enumerate;

    return lines.enumerate;
}

/// FTS8: every callback base supplies equals HarfBuzz's own Unicode 18 one, over every scalar.
@("oracle.shaping.FTS8.callbacks")
@system
unittest
{
    auto funcs = hb_unicode_funcs_get_default();
    size_t compositions;
    foreach (uint cp; 0 .. 0x110000)
    {
        const c = cast(dchar) cp;
        const label = text("U+", cp.to!string(16));
        assert(cast(int) engineGeneralCategory(c) == cast(int) hb_unicode_general_category(funcs, cp),
            label ~ " general category");
        assert(engineCombiningClass(c) == cast(uint) hb_unicode_combining_class(funcs, cp),
            label ~ " combining class");
        assert(engineMirroring(c) == hb_unicode_mirroring(funcs, cp), label ~ " mirroring");
        assert(engineScript(c) == cast(uint) hb_unicode_script(funcs, cp), label ~ " script");
        uint a, b;
        const decomposes = hb_unicode_decompose(funcs, cp, &a, &b) != 0;
        const ours = engineDecompose(c);
        assert(decomposes == (ours[0] != 0) && (!decomposes || ours == [cast(dchar) a, cast(dchar) b]),
            text(label, " decomposition ", ours, " vs ", a, ",", b));
        if (decomposes && b != 0)
        {
            uint ab;
            const composes = hb_unicode_compose(funcs, a, b, &ab) != 0;
            const mine = engineCompose(a, b);
            assert(composes == (mine != 0) && (!composes || mine == ab), text(label, " composition of ", a, ",", b, ": hb ", composes, " ", ab, ", ours ", cast(uint) mine));
            ++compositions;
        }
    }
    assert(compositions > 1_000);
}

/**
FTS8: HarfBuzz hides default ignorables with a hand-coded list, which no
callback replaces. Shaping each scalar alone shows the list equals
base's `Default_Ignorable_Code_Point` except the two exceptions
`hb-unicode.hh` states and keeps across Unicode releases: the Hangul
fillers, which fonts draw as spacing glyphs, and the shorthand format
controls U+1BCA0–1BCA3 (HarfBuzz issue 503).
*/
@("oracle.shaping.FTS8.defaultIgnorables")
@system
unittest
{
    if (fontsDir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = cast(const(ubyte)[]) read(buildPath(fontsDir, "DejaVuSansMono.ttf"));
    const face = openFace(bytes).value;
    const map = face.charMap.value;
    const space = map.glyph(' ');
    auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
    auto s = Shaper(inst);
    ShapedGlyph[8] glyphs;
    SourceSpan[8] spans;
    size_t ignorables, others;
    foreach (uint cp; 0 .. 0x110000)
    {
        if (cp >= 0xD800 && cp <= 0xDFFF)
            continue;
        const di = unicodeProperty(cast(dchar) cp, UnicodeProperty.DI);
        // A glyph the font maps may be zero-width by design; only its absence is telling.
        if (!di && map.glyph(cast(dchar) cp) != 0)
            continue;
        char[4] utf8;
        const n = encodeUtf8(cp, utf8);
        const r = s.shape(ShapeRequest(utf8[0 .. n], 0, n,
            SegmentProperties(ShapingDirection.leftToRight, Tag("Latn")), true), glyphs[], spans[], null, null);
        assert(r.hasValue, text("U+", cp.to!string(16)));
        const hidden = r.value.glyphCount == 0
            || r.value.glyphCount == 1 && glyphs[0].glyphId == space && glyphs[0].xAdvance.raw == 0;
        const shown = cp == 0x115F || cp == 0x1160 || cp == 0x3164 || cp == 0xFFA0
            || cp >= 0x1BCA0 && cp <= 0x1BCA3;
        assert(hidden == (di && !shown), text("U+", cp.to!string(16), di ? " is" : " is not",
            " Default_Ignorable_Code_Point, and HarfBuzz ", hidden ? "hides" : "shows", " it"));
        if (di)
            ++ignorables;
        else
            ++others;
    }
    assert(ignorables > 4_000 && others > 1_000_000, text(ignorables, " ignorables, ", others, " others"));
}

private size_t encodeUtf8(uint cp, ref char[4] o) @safe pure nothrow @nogc
{
    if (cp < 0x80)
    {
        o[0] = cast(char) cp;
        return 1;
    }
    if (cp < 0x800)
    {
        o[0] = cast(char)(0xC0 | cp >> 6);
        o[1] = cast(char)(0x80 | cp & 0x3F);
        return 2;
    }
    if (cp < 0x10000)
    {
        o[0] = cast(char)(0xE0 | cp >> 12);
        o[1] = cast(char)(0x80 | cp >> 6 & 0x3F);
        o[2] = cast(char)(0x80 | cp & 0x3F);
        return 3;
    }
    o[0] = cast(char)(0xF0 | cp >> 18);
    o[1] = cast(char)(0x80 | cp >> 12 & 0x3F);
    o[2] = cast(char)(0x80 | cp >> 6 & 0x3F);
    o[3] = cast(char)(0x80 | cp & 0x3F);
    return 4;
}

/**
FTS1: the shaper's glyphs, clusters, advances and offsets equal recorded
`hb-shape` output (`test/goldens/shaping.txt`, from
`tools/gen_shaping_goldens.d`). At a static instance they are equal
exactly; at a variable one HarfBuzz rounds `HVAR` and `GPOS` deltas to
whole units where the library keeps 1/1,024, so each value is within one
unit.
*/
@("oracle.shaping.hbShapeGoldens")
@system
unittest
{
    if (fontsDir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const golden = readText(buildPath(__FILE_FULL_PATH__.dirName.dirName.dirName, "goldens", "shaping.txt"));
    string[] lines;
    foreach (line; golden.lineSplitter)
        lines ~= line;
    size_t cases, glyphsCompared;
    foreach (i, line; lines)
    {
        if (line.startsWith("# engine "))
            assert(line == "# engine hb-shape (HarfBuzz) " ~ pinnedEngine.harfBuzzVersion,
                "the goldens were recorded with another engine: regenerate them");
        if (line.startsWith("# face "))
        {
            const f = line.split(' ');
            const digest = sha256Of(cast(const(ubyte)[]) read(buildPath(fontsDir, f[2])));
            assert(toHexString!(LetterCase.lower)(digest)[] == f[4],
                f[2] ~ " changed since the goldens were recorded: regenerate them");
        }
        if (!line.startsWith("case\t"))
            continue;
        const c = line.split('\t');
        const faceName = c[1], variations = c[2], direction = c[3], script = c[4], language = c[5], source = c[6];
        const bytes = cast(const(ubyte)[]) read(buildPath(fontsDir, faceName));
        const face = openFace(bytes).value;
        UserCoordinate[] coords;
        if (variations != "-")
        {
            const kv = variations.split('=');
            coords ~= UserCoordinate(Tag(kv[0]), kv[1].to!int << 16);
        }
        auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), coords).value;
        auto s = Shaper(inst);
        const props = SegmentProperties(direction == "rtl" ? ShapingDirection.rightToLeft
            : ShapingDirection.leftToRight, Tag(script == "latn" ? "Latn" : script == "arab" ? "Arab" : "Deva"),
            language);
        auto glyphs = new ShapedGlyph[256];
        auto spans = new SourceSpan[256];
        const r = s.shape(ShapeRequest(source, 0, source.length, props, true, null, true, true), glyphs, spans,
            null, null);
        assert(r.hasValue, line);
        const expected = parseJSON(lines[i + 1]).array;
        assert(r.value.glyphCount == expected.length, text(line, ": ", r.value.glyphCount, " glyphs, hb-shape ",
            expected.length));
        const variable = coords.length != 0;
        void near(DesignValue ours, long units, string what, size_t k)
        {
            const want = units * designSubunits;
            const diff = ours.raw > want ? ours.raw - want : want - ours.raw;
            assert(variable ? diff <= designSubunits : diff == 0, text(line, " glyph ", k, " ", what, ": ",
                ours.raw / cast(double) designSubunits, " vs hb-shape ", units));
        }
        foreach (k, g; expected)
        {
            assert(glyphs[k].glyphId == g["g"].integer && glyphs[k].cluster == g["cl"].integer,
                text(line, " glyph ", k, ": ", glyphs[k].glyphId, "@", glyphs[k].cluster, " vs ", g));
            near(glyphs[k].xAdvance, g["ax"].integer, "ax", k);
            near(glyphs[k].yAdvance, g["ay"].integer, "ay", k);
            near(glyphs[k].xOffset, g["dx"].integer, "dx", k);
            near(glyphs[k].yOffset, g["dy"].integer, "dy", k);
            ++glyphsCompared;
        }
        ++cases;
    }
    assert(cases == 5 && glyphsCompared > 50, text(cases, " cases, ", glyphsCompared, " glyphs"));
}
