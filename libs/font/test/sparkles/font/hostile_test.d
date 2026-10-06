/**
Hostile input (FTB1–FTB3, testing.md § Hostile input): limits, and a seeded
mutation corpus run through every public read operation. Passing means no
assertion and no out-of-bounds read; any `FontError` is acceptable. Under
`ci --test-sanitize` the same run is checked by AddressSanitizer.
*/
module sparkles.font.hostile_test;

import sparkles.font;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.fixtures;
import sparkles.test_runner.skip : skipTest;

@("hostile.cmapRecordLimit")
@safe pure nothrow
unittest
{
    CmapRecord[] records;
    foreach (i; 0 .. 64) records ~= CmapRecord(3, 1, cmapFormat0([[0x41, 1]]));
    assert(openFace(sfnt([TableData("cmap", cmap(records)), TableData("head", head()),
        TableData("maxp", maxp(2))])).hasValue);
    records ~= CmapRecord(3, 1, cmapFormat0([[0x41, 1]]));
    const over = openFace(sfnt([TableData("cmap", cmap(records)), TableData("head", head()),
        TableData("maxp", maxp(2))]));
    assert(over.error.kind == FontErrorKind.limitExceeded && over.error.limit == FontLimit.cmapSubtables);
    assert(over.error.limitValue == 64);
}

/// A small deterministic generator (xorshift64*).
private struct Rng
{
    ulong state;
    ulong next() @safe pure nothrow @nogc
    {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        return state * 0x2545_F491_4F6C_DD1D;
    }
    size_t below(size_t n) @safe pure nothrow @nogc => cast(size_t)(next() % n);
}

/// One mutation of `bytes`: a bit flip, a truncation or an overwritten 32-bit word.
private ubyte[] mutate(const(ubyte)[] bytes, ref Rng rng) @safe pure nothrow
{
    auto m = bytes.dup;
    final switch (rng.below(3))
    {
        case 0:
            foreach (_; 0 .. 1 + rng.below(8))
                m[rng.below(m.length)] ^= cast(ubyte)(1 << rng.below(8));
            break;
        case 1:
            m.length = rng.below(m.length);
            break;
        case 2:
            // Offsets and counts sit in the directory and table headers: favour the front.
            const span = m.length < 4096 ? m.length : 4096;
            if (span >= 4)
            {
                const at = rng.below(span - 3);
                const v = cast(uint) rng.next();
                m[at .. at + 4] = [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];
            }
            break;
    }
    return m;
}

/// Every public read operation on `bytes`, discarding results.
private void exercise(const(ubyte)[] bytes, uint glyphLimit) @safe pure nothrow
{
    const coll = openCollection(bytes);
    const face = openFace(bytes);
    if (face.hasError)
        return;
    const f = face.value;
    foreach (entry; f.directory) {}
    foreach (i; 0 .. f.tableCount) cast(void) f.computedChecksum(i);
    cast(void) f.searchFields;
    cast(void) f.checksumAdjustment;
    cast(void) f.head;
    cast(void) f.hhea;
    cast(void) f.maxp;
    cast(void) f.os2;
    cast(void) f.post;
    cast(void) f.spacing;
    const metrics = f.hmtx;
    if (metrics.hasValue)
        foreach (gid; 0 .. f.numGlyphs < glyphLimit ? f.numGlyphs : glyphLimit)
            cast(void) metrics.value.metric(gid);
    const fv = f.fvar;
    if (fv.hasValue)
    {
        foreach (i; 0 .. fv.value.axisCount) cast(void) fv.value.axis(i);
        foreach (i; 0 .. fv.value.instanceCount) cast(void) fv.value.instance(i).coordinate(0 < fv.value.axisCount ? 0 : 0);
    }
    const av = f.avar;
    if (av.hasValue) foreach (map; av.value.maps) {}
    const st = f.stat;
    if (st.hasValue)
    {
        foreach (i; 0 .. st.value.designAxisCount) cast(void) st.value.designAxis(i);
        foreach (i; 0 .. st.value.axisValueCount) cast(void) st.value.axisValue(i);
    }
    const names = f.name;
    if (names.hasValue)
    {
        char[512] buffer;
        foreach (r; names.value.records)
            if (r.hasValue) cast(void) r.value.decode(buffer[]);
    }
    const cm = f.charMap;
    if (cm.hasValue)
    {
        size_t n;
        foreach (r; cm.value.ranges) if (++n > 4096) break;
        foreach (cp; 0 .. 0x300) cast(void) cm.value.glyph(cp);
        cast(void) cm.value.variant('A', 0xFE0F);
    }
    const records = f.table(Tag("cmap"));
    if (records.hasValue && records.value.length >= 4)
        foreach (i; 0 .. (records.value[2] << 8 | records.value[3]))
            cast(void) f.charMapAt(i);
    foreach (gid; 0 .. f.numGlyphs < glyphLimit ? f.numGlyphs : glyphLimit)
        cast(void) f.glyphName(gid);
    const length = f.glyphNameIndexLength;
    if (length.hasValue && length.value <= 1 << 20)
    {
        auto scratch = new uint[length.value];
        const index = f.glyphNameIndex(scratch);
        if (index.hasValue)
            foreach (gid; 0 .. f.numGlyphs < glyphLimit ? f.numGlyphs : glyphLimit)
                cast(void) index.value[gid];
    }
}

/// The committed fixtures the mutation corpus starts from.
private ubyte[][] fixtureSeeds() @safe pure nothrow
{
    const f14 = u16(14) ~ u32(21) ~ u32(1) ~ u8(0) ~ u16(0xFE0F) ~ u32(0) ~ u32(0);
    auto full = minimalTables(4) ~ [TableData("hhea", hhea(2)), TableData("hmtx", hmtx([[600, 1], [700, 2]], [3, 4])),
        TableData("name", name([NameEntry(3, 1, 0x409, 1, utf16be("Seed")), NameEntry(1, 0, 0, 2, cast(const(ubyte)[]) "Mac")])),
        TableData("post", post2([0, 258, 36, 259], ["alpha", "beta"]))];
    auto overlapping = [TableData("cmap", cmap([CmapRecord(3, 1, cmapFormat4([Segment(100, 200, 1),
        Segment(50, 300, 2, [5, 6, 7])])), CmapRecord(3, 10, cmapFormat12([[0x20, 0x30, 1]])),
        CmapRecord(0, 5, f14)])), TableData("head", head()), TableData("maxp", maxp(50))];
    return [sfnt(full), sfnt(overlapping), collection([minimalTables(2), minimalTables(3)]),
        sfnt(minimalTables(3) ~ TableData("CFF ", cffTable(["custom"], u8(1) ~ u16(391) ~ u8(1))), 0x4F54_544F)];
}

@("hostile.mutations.fixtures")
@safe pure nothrow
unittest
{
    auto rng = Rng(0x5EED_F047);
    foreach (seed; fixtureSeeds())
    {
        exercise(seed, 1024);
        foreach (_; 0 .. 400)
            exercise(mutate(seed, rng), 1024);
    }
}

@("hostile.mutations.bundled")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto rng = Rng(0xF0_A7_5EED);
    foreach (file; ["FiraCodeNerdFontMono-Regular.ttf", "NotoSans.ttf", "NotoSansAnatolianHieroglyphs-Regular.otf"])
    {
        const seed = bundled(file);
        foreach (_; 0 .. 40)
            exercise(mutate(seed, rng), 256);
    }
}
