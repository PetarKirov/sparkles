/**
A byte builder for test fonts: well-formed tables and deliberately broken
ones, assembled into sfnt and collection files. Test-only; it allocates.
*/
module sparkles.font.fixtures;

@safe pure nothrow:

/// Big-endian encoders.
ubyte[] u8(uint v) => [cast(ubyte) v];
/// ditto
ubyte[] u16(uint v) => [cast(ubyte)(v >> 8), cast(ubyte) v];
/// ditto
ubyte[] u32(uint v) => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

/// A table to place in a font.
struct TableData
{
    string tag;
    const(ubyte)[] data;
}

/// The OpenType checksum of `data`, padded to four bytes.
uint checksum(scope const(ubyte)[] data)
{
    uint sum;
    for (size_t i = 0; i < data.length; i += 4)
    {
        uint word;
        foreach (k; 0 .. 4)
            word = (word << 8) | (i + k < data.length ? data[i + k] : 0);
        sum += word;
    }
    return sum;
}

/// The 12-byte sfnt header for `count` tables, with correct search fields.
ubyte[] sfntHeader(uint sfntVersion, size_t count)
{
    uint power = 1, log = 0;
    while (power * 2 <= count) { power *= 2; ++log; }
    return u32(sfntVersion) ~ u16(cast(uint) count) ~ u16(power * 16) ~ u16(log)
        ~ u16(cast(uint)(count * 16 - power * 16));
}

/**
An sfnt file holding `tables` in the given order, each 4-byte aligned, with
correct checksums. `base` is where the file starts inside a collection.
*/
ubyte[] sfnt(const(TableData)[] tables, uint sfntVersion = 0x0001_0000, size_t base = 0)
{
    auto header = sfntHeader(sfntVersion, tables.length);
    size_t offset = base + 12 + 16 * tables.length;
    ubyte[] directory, body;
    foreach (t; tables)
    {
        directory ~= cast(const(ubyte)[]) t.tag ~ u32(checksum(t.data)) ~ u32(cast(uint) offset)
            ~ u32(cast(uint) t.data.length);
        body ~= t.data;
        while (body.length % 4) body ~= 0;
        offset = base + 12 + 16 * tables.length + body.length;
    }
    return header ~ directory ~ body;
}

/// A collection of `fonts`, each a list of tables, with header version 1.0.
ubyte[] collection(const(TableData[])[] fonts)
{
    const headerSize = 12 + 4 * fonts.length;
    ubyte[] files;
    uint[] offsets;
    foreach (tables; fonts)
    {
        offsets ~= cast(uint)(headerSize + files.length);
        files ~= sfnt(tables, 0x0001_0000, headerSize + files.length);
    }
    ubyte[] header = cast(ubyte[]) "ttcf".dup ~ u16(1) ~ u16(0) ~ u32(cast(uint) fonts.length);
    foreach (o; offsets) header ~= u32(o);
    return header ~ files;
}

/// A version-1 `head` with the given units per em.
ubyte[] head(uint unitsPerEm = 1000, uint indexToLocFormat = 0)
    => u16(1) ~ u16(0) ~ u32(0x0001_0000) ~ u32(0) ~ u32(0x5F0F_3CF5) ~ u16(0)
        ~ u16(unitsPerEm) ~ u32(0) ~ u32(0) ~ u32(0) ~ u32(0)
        ~ u16(0) ~ u16(0) ~ u16(unitsPerEm) ~ u16(unitsPerEm)
        ~ u16(0) ~ u16(8) ~ u16(2) ~ u16(indexToLocFormat) ~ u16(0);

/// A version-1.0 `maxp` (32 bytes).
ubyte[] maxp(uint numGlyphs)
{
    auto t = u32(0x0001_0000) ~ u16(numGlyphs);
    t.length = 32;
    return t;
}

/// A version-0.5 `maxp` (6 bytes).
ubyte[] maxp05(uint numGlyphs) => u32(0x0000_5000) ~ u16(numGlyphs);

/// A version-1 `hhea`.
ubyte[] hhea(uint numberOfHMetrics, int ascender = 800, int descender = -200)
{
    auto t = u32(0x0001_0000) ~ u16(cast(uint) ascender) ~ u16(cast(uint) descender);
    t.length = 34;
    return t ~ u16(numberOfHMetrics);
}

/// `hmtx` with long metrics `(advance, lsb)` then trailing left side bearings.
ubyte[] hmtx(const(uint[2])[] longMetrics, const(int)[] trailingLsb = null)
{
    ubyte[] t;
    foreach (m; longMetrics) t ~= u16(m[0]) ~ u16(m[1]);
    foreach (lsb; trailingLsb) t ~= u16(cast(uint) lsb);
    return t;
}

/// A `cmap` subtable record.
struct CmapRecord
{
    uint platform;
    uint encoding;
    const(ubyte)[] subtable;
}

/// A version-0 `cmap` holding `records`; subtables are placed in order.
ubyte[] cmap(const(CmapRecord)[] records)
{
    ubyte[] header = u16(0) ~ u16(cast(uint) records.length);
    ubyte[] body;
    const start = 4 + 8 * records.length;
    foreach (r; records)
    {
        header ~= u16(r.platform) ~ u16(r.encoding) ~ u32(cast(uint)(start + body.length));
        body ~= r.subtable;
    }
    return header ~ body;
}

/// A format-0 subtable mapping each `[codepoint, glyph]` pair.
ubyte[] cmapFormat0(const(uint[2])[] map)
{
    ubyte[256] glyphs;
    foreach (m; map) glyphs[m[0]] = cast(ubyte) m[1];
    return u16(0) ~ u16(262) ~ u16(0) ~ glyphs[].dup;
}

/// A format-4 segment: `[start, end]` with `idDelta`, or a glyph array.
struct Segment
{
    uint start;
    uint end;
    int delta;
    const(uint)[] glyphs; // non-null: idRangeOffset into this array
}

/// A format-4 subtable; the 0xFFFF sentinel segment is appended.
ubyte[] cmapFormat4(const(Segment)[] segments)
{
    auto all = segments.dup ~ Segment(0xFFFF, 0xFFFF, 1);
    const n = all.length;
    ubyte[] ends, starts, deltas, offsets, glyphArray;
    foreach (i, s; all)
    {
        ends ~= u16(s.end);
        starts ~= u16(s.start);
        deltas ~= u16(cast(uint) s.delta);
        if (s.glyphs.length)
        {
            // From this idRangeOffset word to its first glyph-array entry.
            const fromHere = 2 * (n - i) + glyphArray.length;
            offsets ~= u16(cast(uint) fromHere);
            foreach (g; s.glyphs) glyphArray ~= u16(g);
        }
        else
            offsets ~= u16(0);
    }
    const length = 16 + 8 * n + glyphArray.length;
    return u16(4) ~ u16(cast(uint) length) ~ u16(0) ~ u16(cast(uint)(2 * n)) ~ u16(0) ~ u16(0)
        ~ u16(0) ~ ends ~ u16(0) ~ starts ~ deltas ~ offsets ~ glyphArray;
}

/// A format-12 (or 13) subtable of `[start, end, glyph]` groups.
ubyte[] cmapFormat12(const(uint[3])[] groups, uint format = 12)
{
    ubyte[] t = u16(format) ~ u16(0) ~ u32(cast(uint)(16 + 12 * groups.length)) ~ u32(0)
        ~ u32(cast(uint) groups.length);
    foreach (g; groups) t ~= u32(g[0]) ~ u32(g[1]) ~ u32(g[2]);
    return t;
}

/// A `name` record: platform, encoding, language, name ID and raw string bytes.
struct NameEntry
{
    uint platform;
    uint encoding;
    uint language;
    uint nameId;
    const(ubyte)[] text;
}

/// A version-0 `name` table.
ubyte[] name(const(NameEntry)[] entries)
{
    const storage = 6 + 12 * entries.length;
    ubyte[] header = u16(0) ~ u16(cast(uint) entries.length) ~ u16(cast(uint) storage);
    ubyte[] strings;
    foreach (e; entries)
    {
        header ~= u16(e.platform) ~ u16(e.encoding) ~ u16(e.language) ~ u16(e.nameId)
            ~ u16(cast(uint) e.text.length) ~ u16(cast(uint) strings.length);
        strings ~= e.text;
    }
    return header ~ strings;
}

/// UTF-16BE bytes of an ASCII string.
ubyte[] utf16be(string ascii)
{
    ubyte[] r;
    foreach (c; ascii) r ~= u16(c);
    return r;
}

/// The smallest well-formed font: `head`, `maxp` and a format-0 `cmap`.
TableData[] minimalTables(uint numGlyphs = 2, const(uint[2])[] map = [[0x41, 1]])
    => [TableData("cmap", cmap([CmapRecord(3, 1, cmapFormat0(map))])),
        TableData("head", head(2048)), TableData("maxp", maxp(numGlyphs))];
