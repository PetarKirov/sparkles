/**
Concurrency (FTA2): one face serves many threads.
*/
module sparkles.font.concurrency_test;

import std.parallelism : parallel;
import std.range : iota;

import sparkles.font;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.fixtures;

/// Everything one glyph contributes, compared across threads.
private struct GlyphAnswers
{
    uint mapped;
    ushort advance;
    string name;
}

private GlyphAnswers answer(const Face face, const CharMap map, uint gid) @safe
{
    GlyphAnswers a;
    a.mapped = map.glyph(cast(dchar)(0x20 + gid));
    const m = face.hmtx;
    if (m.hasValue && m.value.advance(gid).hasValue)
        a.advance = m.value.advance(gid).value;
    const n = face.glyphName(gid);
    if (n.hasValue && n.value.present)
        a.name = n.value.text.idup;
    return a;
}

@("concurrency.oneFaceManyThreads")
@system
unittest
{
    const bytes = fontsPath is null
        ? sfnt(minimalTables(400) ~ [TableData("hhea", hhea(400)), TableData("post", postTable(0x0001_0000))])
        : bundled("FiraCodeNerdFontMono-Regular.ttf");
    const face = openFace(bytes).value;
    const map = face.charMap.value;
    const n = face.numGlyphs;
    auto expected = new GlyphAnswers[n];
    foreach (gid; 0 .. n)
        expected[gid] = answer(face, map, gid);
    // FTA2: concurrent const reads of one face need no synchronization.
    foreach (round; 0 .. 4)
    {
        auto got = new GlyphAnswers[n];
        foreach (gid; parallel(iota(n), 64))
            got[gid] = answer(face, map, cast(uint) gid);
        assert(got == expected);
    }
}
