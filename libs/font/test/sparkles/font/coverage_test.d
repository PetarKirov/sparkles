/**
Coverage tables (FTP34): both formats, hits, misses and edges, unknown
formats, truncation and iteration order.
*/
module sparkles.font.coverage_test;

import sparkles.font.coverage;
import sparkles.font.errors : FontErrorKind, Tag;
import sparkles.font.fixtures : coverage1, coverage2, u16;

private enum tag = Tag("GSUB");

private Coverage at(const(ubyte)[] bytes, ulong offset = 0) @safe pure nothrow @nogc
    => Coverage.read(bytes, tag, 100, offset);

private CoveredGlyph[] all(const Coverage c) @safe pure nothrow
{
    CoveredGlyph[] r;
    foreach (g; c.glyphs.value)
        r ~= g;
    return r;
}

@("coverage.format1.hitsAndMisses")
@safe pure nothrow
unittest
{
    const c = at(coverage1([3, 7, 9, 200, 0xFFFF]));
    assert(c.format == 1 && c.count == 5 && !c.broken);
    assert(c.index(3).value == CoverageIndex(true, 0));
    assert(c.index(9).value == CoverageIndex(true, 2));
    assert(c.index(0xFFFF).value == CoverageIndex(true, 4));
    foreach (gid; [0u, 2, 4, 8, 10, 199, 201, 0xFFFE, 0x1_0000, uint.max])
        assert(!c.index(gid).value.covered);
    assert(all(c) == [CoveredGlyph(3, 0), CoveredGlyph(7, 1), CoveredGlyph(9, 2), CoveredGlyph(200, 3),
        CoveredGlyph(0xFFFF, 4)]);
}

@("coverage.format2.hitsAndMisses")
@safe pure nothrow
unittest
{
    const c = at(coverage2([[5, 7, 0], [10, 10, 3], [20, 0xFFFF, 4]]));
    assert(c.format == 2 && c.count == 3);
    assert(c.index(5).value == CoverageIndex(true, 0));
    assert(c.index(7).value == CoverageIndex(true, 2));
    assert(c.index(10).value == CoverageIndex(true, 3));
    assert(c.index(20).value == CoverageIndex(true, 4));
    assert(c.index(0xFFFF).value == CoverageIndex(true, 4 + 0xFFFF - 20));
    foreach (gid; [0u, 4, 8, 9, 11, 19, 0x1_0000])
        assert(!c.index(gid).value.covered);
    // The index is startCoverageIndex + gid − start, whatever the stored start index says.
    assert(at(coverage2([[100, 101, 0xFFFF]])).index(101).value == CoverageIndex(true, 0x1_0000));
}

@("coverage.format2.iteration")
@safe pure nothrow
unittest
{
    // A range whose end precedes its start covers nothing and is skipped.
    const c = at(coverage2([[1, 2, 0], [9, 8, 2], [0xFFFF, 0xFFFF, 2]]));
    assert(all(c) == [CoveredGlyph(1, 0), CoveredGlyph(2, 1), CoveredGlyph(0xFFFF, 2)]);
    assert(!c.index(8).value.covered && !c.index(9).value.covered);
    auto g = c.glyphs.value;
    auto copy = g.save;
    g.popFront();
    assert(copy.front == CoveredGlyph(1, 0) && g.front == CoveredGlyph(2, 1));
}

@("coverage.empty")
@safe pure nothrow
unittest
{
    foreach (bytes; [coverage1(null), coverage2(null)])
    {
        const c = at(bytes);
        assert(!c.broken && !c.index(0).value.covered && c.glyphs.value.empty);
    }
    assert(!Coverage.init.index(1).value.covered && Coverage.init.glyphs.value.empty);
}

@("coverage.unknownFormat")
@safe pure nothrow
unittest
{
    foreach (format; [0u, 3, 0xFFFF])
    {
        const c = at(u16(format) ~ u16(0));
        assert(c.broken && c.index(1).error.kind == FontErrorKind.unsupportedVersion);
        assert(c.glyphs.error.kind == FontErrorKind.unsupportedVersion);
        assert(c.error.tag == tag && c.error.offset == 100 && c.error.tableOffset == 0);
    }
}

@("coverage.truncation")
@safe pure nothrow
unittest
{
    foreach (full; [coverage1([1, 2, 3]), coverage2([[1, 2, 0], [5, 6, 2]])])
    {
        foreach (n; 0 .. full.length)
        {
            const c = at(full[0 .. n]);
            assert(c.broken, "every prefix is malformed");
            const kind = c.index(1).error.kind;
            assert(n == 0 ? kind == FontErrorKind.badOffset : kind == FontErrorKind.truncated);
        }
        assert(!at(full).broken);
    }
    // An offset past the table is badOffset at the coverage.
    const past = at(coverage1([1]), 6);
    assert(past.index(1).error.kind == FontErrorKind.badOffset && past.error.tableOffset == 6);
}

@("coverage.offsetInsideTable")
@safe pure nothrow
unittest
{
    const bytes = cast(const(ubyte)[]) [0xAA, 0xBB] ~ coverage1([4]);
    const c = at(bytes, 2);
    assert(c.index(4).value == CoverageIndex(true, 0));
}
