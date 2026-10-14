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
ubyte[] hhea(uint numberOfHMetrics, int ascender = 800, int descender = -200, int lineGap = 0)
{
    auto t = u32(0x0001_0000) ~ u16(cast(uint) ascender) ~ u16(cast(uint) descender)
        ~ u16(cast(uint) lineGap);
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

/// A `post` header of `version_` (16.16), followed by `tail`.
ubyte[] postTable(uint version_, const(ubyte)[] tail = null)
{
    auto t = u32(version_);
    t.length = 32;
    return t ~ tail;
}

/// A `post` 2.0 body: glyph name indices then Pascal strings.
ubyte[] post2(const(uint)[] indices, const(string)[] strings)
{
    ubyte[] t = u16(cast(uint) indices.length);
    foreach (i; indices) t ~= u16(i);
    foreach (s; strings) t ~= u8(cast(uint) s.length) ~ cast(const(ubyte)[]) s;
    return postTable(0x0002_0000, t);
}

/// A CFF INDEX of `objects`, with 1- or 2-byte offsets.
ubyte[] cffIndex(const(ubyte[])[] objects)
{
    if (!objects.length) return u16(0);
    size_t total = 1;
    foreach (o; objects) total += o.length;
    const offSize = total <= 255 ? 1 : 2;
    ubyte[] t = u16(cast(uint) objects.length) ~ u8(offSize);
    size_t at = 1;
    foreach (o; objects ~ []) { t ~= offSize == 1 ? u8(cast(uint) at) : u16(cast(uint) at); at += o.length; }
    t ~= offSize == 1 ? u8(cast(uint) at) : u16(cast(uint) at);
    foreach (o; objects) t ~= o;
    return t;
}

/// A `CFF ` table with custom `strings` and a charset: a predefined id (0, 1, 2)
/// when `charset` is null, else these bytes, placed after the INDEXes.
ubyte[] cffTable(const(string)[] strings, const(ubyte)[] charset, uint predefined = 0, bool cidKeyed = false)
{
    ubyte[][] stringObjects;
    foreach (s; strings) stringObjects ~= cast(ubyte[]) s.dup;
    const header = u8(1) ~ u8(0) ~ u8(4) ~ u8(1);
    const names = cffIndex([cast(ubyte[]) "Test".dup]);
    const stringIndex = cffIndex(stringObjects);
    const globalSubrs = u16(0);
    // Top DICT: [ROS: 3 operands, 12 30] charset (int32) 15.
    const rosOps = cidKeyed ? u8(139) ~ u8(139) ~ u8(139) ~ u8(12) ~ u8(30) : null;
    const dictLength = rosOps.length + 6;
    const topIndexLength = 2 + 1 + 2 + dictLength;
    const charsetAt = charset is null ? predefined
        : cast(uint)(header.length + names.length + topIndexLength + stringIndex.length + globalSubrs.length);
    const dict = rosOps ~ u8(29) ~ u32(charsetAt) ~ u8(15);
    const top = cffIndex([dict.dup]);
    assert(top.length == topIndexLength);
    return (header ~ names ~ top ~ stringIndex ~ globalSubrs ~ charset).dup;
}

/// One variation region axis: F2Dot14 `[start, peak, end]`.
alias RegionAxis = int[3];

/// An ItemVariationData subtable: its region indices, word-delta count and rows.
struct VarData
{
    const(uint)[] regionIndexes;
    uint wordCount;
    bool longWords;
    const(int[])[] rows;
    /// Overrides the stored item count when not `uint.max`.
    uint itemCount = uint.max;
}

/// The bytes of one ItemVariationData subtable.
ubyte[] itemVariationData(const VarData d)
{
    ubyte[] t = u16(d.itemCount == uint.max ? cast(uint) d.rows.length : d.itemCount)
        ~ u16(d.wordCount | (d.longWords ? 0x8000 : 0)) ~ u16(cast(uint) d.regionIndexes.length);
    foreach (r; d.regionIndexes) t ~= u16(r);
    foreach (row; d.rows)
        foreach (j, v; row)
        {
            const word = j < (d.wordCount & 0x7FFF);
            t ~= d.longWords ? (word ? u32(v) : u16(v)) : (word ? u16(v) : u8(v));
        }
    return t;
}

/**
An item variation store: header, region list of `axisCount` axes, then the
data subtables in order, every offset from the store's start.
*/
ubyte[] itemVariationStore(uint axisCount, const(RegionAxis[])[] regions, const(VarData)[] data,
    uint format = 1)
{
    const headerLength = 8 + 4 * data.length;
    ubyte[] regionList = u16(axisCount) ~ u16(cast(uint) regions.length);
    foreach (region; regions)
        foreach (a; region) regionList ~= u16(a[0]) ~ u16(a[1]) ~ u16(a[2]);
    ubyte[] header = u16(format) ~ u32(cast(uint) headerLength) ~ u16(cast(uint) data.length);
    ubyte[] body;
    foreach (d; data)
    {
        header ~= u32(cast(uint)(headerLength + regionList.length + body.length));
        body ~= itemVariationData(d);
    }
    return header ~ regionList ~ body;
}

/**
A DeltaSetIndexMap of `format` (0 or 1) mapping each item to `[outer, inner]`,
with `innerBits` (1–16) inner bits in `entrySize`-byte (1–4) entries.
*/
ubyte[] deltaSetIndexMap(const(uint[2])[] map, uint innerBits, uint entrySize, uint format = 0)
{
    ubyte[] t = u8(format) ~ u8(((entrySize - 1) << 4) | (innerBits - 1))
        ~ (format == 0 ? u16(cast(uint) map.length) : u32(cast(uint) map.length));
    foreach (m; map)
    {
        const entry = (m[0] << innerBits) | m[1];
        t ~= entrySize == 1 ? u8(entry) : entrySize == 2 ? u16(entry)
            : entrySize == 3 ? u32(entry)[1 .. $] : u32(entry);
    }
    return t;
}

/// A Device table of delta `format` 1–3 for sizes `start` to `end`, packing `values`.
ubyte[] deviceTable(uint start, uint end, uint format, const(int)[] values)
{
    ubyte[] t = u16(start) ~ u16(end) ~ u16(format);
    const bits = 1u << format, perWord = 16 / bits;
    for (size_t i = 0; i < values.length; i += perWord)
    {
        uint word;
        foreach (k; 0 .. perWord)
            word |= (i + k < values.length ? values[i + k] & ((1u << bits) - 1) : 0)
                << (16 - (k + 1) * bits);
        t ~= u16(word);
    }
    return t;
}

/// A VariationIndex table (delta format 0x8000) naming `[outer, inner]`.
ubyte[] variationIndexTable(uint outer, uint inner) => u16(outer) ~ u16(inner) ~ u16(0x8000);

/// One `fvar` axis: tag and F16.16 minimum, default and maximum.
struct FvarAxis
{
    string tag;
    int minValue, defaultValue, maxValue;
    uint flags;
    uint nameID = 256;
}

/// An `fvar` 1.0 table of `axes` and named instances of F16.16 `instances` coordinates.
ubyte[] fvarTable(const(FvarAxis)[] axes, const(int[])[] instances = null)
{
    const axisCount = cast(uint) axes.length;
    ubyte[] t = u16(1) ~ u16(0) ~ u16(16) ~ u16(2) ~ u16(axisCount) ~ u16(20)
        ~ u16(cast(uint) instances.length) ~ u16(4 * axisCount + 4);
    foreach (a; axes)
        t ~= cast(const(ubyte)[]) a.tag ~ u32(a.minValue) ~ u32(a.defaultValue) ~ u32(a.maxValue)
            ~ u16(a.flags) ~ u16(a.nameID);
    foreach (i, coords; instances)
    {
        t ~= u16(cast(uint)(258 + i)) ~ u16(0);
        foreach (c; coords) t ~= u32(c);
    }
    return t;
}

/**
An `avar` table of F2Dot14 `[from, to]` segment maps, one per axis. With
`version2`, the axis index map and item variation store follow, each at a
nonzero offset when given.
*/
ubyte[] avarTable(const(int[2][])[] maps, bool version2 = false, const(ubyte)[] axisIndexMap = null,
    const(ubyte)[] varStore = null)
{
    ubyte[] t = u16(version2 ? 2 : 1) ~ u16(0) ~ u16(0) ~ u16(cast(uint) maps.length);
    foreach (map; maps)
    {
        t ~= u16(cast(uint) map.length);
        foreach (pair; map) t ~= u16(pair[0]) ~ u16(pair[1]);
    }
    if (!version2)
        return t;
    const tail = t.length + 8;
    t ~= u32(axisIndexMap is null ? 0 : cast(uint) tail)
        ~ u32(varStore is null ? 0 : cast(uint)(tail + axisIndexMap.length));
    return t ~ axisIndexMap ~ varStore;
}

/// The `OS/2` fields metrics read; the rest stay zero.
struct Os2Fields
{
    uint version_ = 4;
    int xAvgCharWidth = 500;
    int yStrikeoutSize = 50, yStrikeoutPosition = 250;
    uint fsSelection;
    int sTypoAscender = 750, sTypoDescender = -250, sTypoLineGap = 100;
    uint usWinAscent = 900, usWinDescent = 300;
    int sxHeight = 450, sCapHeight = 650;
}

/// An `OS/2` table of `f.version_`, as long as that version needs.
ubyte[] os2Table(const Os2Fields f)
{
    auto t = new ubyte[](f.version_ >= 5 ? 100 : f.version_ >= 2 ? 96 : f.version_ == 1 ? 86 : 78);
    void put(size_t at, uint v) { t[at] = cast(ubyte)(v >> 8); t[at + 1] = cast(ubyte) v; }
    put(0, f.version_);
    put(2, f.xAvgCharWidth);
    put(26, f.yStrikeoutSize);
    put(28, f.yStrikeoutPosition);
    put(62, f.fsSelection);
    put(68, f.sTypoAscender);
    put(70, f.sTypoDescender);
    put(72, f.sTypoLineGap);
    put(74, f.usWinAscent);
    put(76, f.usWinDescent);
    if (f.version_ >= 2)
    {
        put(86, f.sxHeight);
        put(88, f.sCapHeight);
    }
    return t;
}

/// A version-3 `post` header with the underline position and thickness.
ubyte[] postHeader(int underlinePosition, int underlineThickness)
{
    auto t = postTable(0x0003_0000);
    t[8 .. 10] = u16(underlinePosition);
    t[10 .. 12] = u16(underlineThickness);
    return t;
}

/**
An `HVAR` table of major version `major` holding `store` and, when given, the
advance map `advanceMap` (offsets 0 when null); no side-bearing maps.
*/
ubyte[] hvarTable(const(ubyte)[] store, const(ubyte)[] advanceMap = null, uint major = 1)
{
    const storeAt = store is null ? 0 : 20;
    const mapAt = advanceMap is null ? 0 : 20 + store.length;
    return u16(major) ~ u16(0) ~ u32(storeAt) ~ u32(cast(uint) mapAt) ~ u32(0) ~ u32(0) ~ store ~ advanceMap;
}

/// One `MVAR` value record: a tag and its `[outer, inner]` delta-set index.
struct MvarRecord
{
    string tag;
    uint outer, inner;
}

/**
An `MVAR` table of major version `major` with `records` (in the given order,
each padded to `recordSize` bytes) and `store` after them (offset 0 when null).
*/
ubyte[] mvarTable(const(MvarRecord)[] records, const(ubyte)[] store, uint recordSize = 8, uint major = 1)
{
    const storeAt = store is null ? 0 : 12 + recordSize * records.length;
    ubyte[] t = u16(major) ~ u16(0) ~ u16(0) ~ u16(recordSize) ~ u16(cast(uint) records.length)
        ~ u16(cast(uint) storeAt);
    foreach (r; records)
    {
        auto record = cast(const(ubyte)[]) r.tag ~ u16(r.outer) ~ u16(r.inner);
        record.length = recordSize;
        t ~= record;
    }
    return t ~ store;
}

/// A `vhea` of 16.16 `version_` (36 bytes), with `numOfLongVerMetrics` last.
ubyte[] vheaTable(uint numOfLongVerMetrics, int ascender = 500, int descender = -500, int lineGap = 0,
    uint version_ = 0x0001_0000)
{
    auto t = u32(version_) ~ u16(cast(uint) ascender) ~ u16(cast(uint) descender) ~ u16(cast(uint) lineGap);
    t.length = 34;
    return t ~ u16(numOfLongVerMetrics);
}

/// `vmtx` with long metrics `(advanceHeight, tsb)` then trailing top side bearings.
ubyte[] vmtxTable(const(uint[2])[] longMetrics, const(int)[] trailingTsb = null)
    => hmtx(longMetrics, trailingTsb);

/// A `VORG` of `major.minor` with `defaultY` and `[glyph, vertOriginY]` records in the given order.
ubyte[] vorgTable(int defaultY, const(int[2])[] records, uint major = 1, uint minor = 0)
{
    ubyte[] t = u16(major) ~ u16(minor) ~ u16(cast(uint) defaultY) ~ u16(cast(uint) records.length);
    foreach (r; records) t ~= u16(r[0]) ~ u16(cast(uint) r[1]);
    return t;
}

/**
A `VVAR` table of major version `major` holding `store`, the advance-height
map `advanceMap` and the vertical-origin map `originMap` (offsets 0 when
null); no side-bearing maps.
*/
ubyte[] vvarTable(const(ubyte)[] store, const(ubyte)[] advanceMap = null, const(ubyte)[] originMap = null,
    uint major = 1)
{
    const storeAt = store is null ? 0 : 24;
    const mapAt = advanceMap is null ? 0 : 24 + store.length;
    const originAt = originMap is null ? 0 : 24 + store.length + advanceMap.length;
    return u16(major) ~ u16(0) ~ u32(storeAt) ~ u32(cast(uint) mapAt) ~ u32(0) ~ u32(0)
        ~ u32(cast(uint) originAt) ~ store ~ advanceMap ~ originMap;
}

/**
A BaseCoord: format 1 (`coordinate`), 2 (plus `glyph` and `point`) or 3
(plus `device`, a Device or VariationIndex table placed after it, offset 0
when null). Any other format is written as format and coordinate only.
*/
struct BaseCoordSpec
{
    uint format = 1;
    int coordinate;
    uint glyph, point;
    const(ubyte)[] device;
}

/// The bytes of a BaseCoord.
ubyte[] baseCoord(const BaseCoordSpec c)
{
    auto t = u16(c.format) ~ u16(cast(uint) c.coordinate);
    if (c.format == 2)
        return t ~ u16(c.glyph) ~ u16(c.point);
    if (c.format == 3)
        return t ~ u16(c.device is null ? 0 : 6) ~ c.device;
    return t;
}

/// A minimum and maximum, each optional (a null offset when `has…` is false).
struct MinMaxPair
{
    bool hasMin;
    BaseCoordSpec min;
    bool hasMax;
    BaseCoordSpec max;
}

/// A FeatMinMaxRecord.
struct FeatMinMaxSpec
{
    string tag;
    MinMaxPair values;
}

/// A MinMax table: its own minimum and maximum, then feature records in the given order.
struct MinMaxSpec
{
    MinMaxPair values;
    const(FeatMinMaxSpec)[] features;
}

/// The bytes of a MinMax table; children follow the header in order.
ubyte[] minMaxTable(const MinMaxSpec m)
{
    const headerLength = 6 + 8 * m.features.length;
    ubyte[] body;
    uint place(bool has, const BaseCoordSpec c)
    {
        if (!has)
            return 0;
        const at = cast(uint)(headerLength + body.length);
        body ~= baseCoord(c);
        return at;
    }
    const minAt = place(m.values.hasMin, m.values.min), maxAt = place(m.values.hasMax, m.values.max);
    ubyte[] t = u16(minAt) ~ u16(maxAt) ~ u16(cast(uint) m.features.length);
    foreach (f; m.features)
    {
        const fMin = place(f.values.hasMin, f.values.min), fMax = place(f.values.hasMax, f.values.max);
        t ~= cast(const(ubyte)[]) f.tag ~ u16(fMin) ~ u16(fMax);
    }
    return t ~ body;
}

/// A BaseLangSysRecord: a language tag and its MinMax.
struct LangSysSpec
{
    string tag;
    MinMaxSpec minMax;
}

/// A BaseScript: optional BaseValues and default MinMax, and language records in the given order.
struct BaseScriptSpec
{
    string tag;
    bool hasValues;
    uint defaultIndex;
    const(BaseCoordSpec)[] coords;
    bool hasDefaultMinMax;
    MinMaxSpec defaultMinMax;
    const(LangSysSpec)[] langSys;
}

/// The bytes of a BaseScript table.
ubyte[] baseScriptTable(const BaseScriptSpec s)
{
    const headerLength = 6 + 6 * s.langSys.length;
    ubyte[] body;
    uint valuesAt, defaultAt;
    if (s.hasValues)
    {
        valuesAt = cast(uint) headerLength;
        ubyte[] values = u16(s.defaultIndex) ~ u16(cast(uint) s.coords.length);
        ubyte[] coords;
        foreach (c; s.coords)
        {
            values ~= u16(cast(uint)(4 + 2 * s.coords.length + coords.length));
            coords ~= baseCoord(c);
        }
        body ~= values ~ coords;
    }
    if (s.hasDefaultMinMax)
    {
        defaultAt = cast(uint)(headerLength + body.length);
        body ~= minMaxTable(s.defaultMinMax);
    }
    ubyte[] t = u16(valuesAt) ~ u16(defaultAt) ~ u16(cast(uint) s.langSys.length);
    foreach (l; s.langSys)
    {
        t ~= cast(const(ubyte)[]) l.tag ~ u16(cast(uint)(headerLength + body.length));
        body ~= minMaxTable(l.minMax);
    }
    return t ~ body;
}

/// A `BASE` axis: baseline tags and scripts, each in the given order.
struct BaseAxisSpec
{
    const(string)[] tags;
    const(BaseScriptSpec)[] scripts;
}

/// The bytes of an Axis table with its tag list and script list.
ubyte[] baseAxisTable(const BaseAxisSpec a)
{
    ubyte[] tagList = u16(cast(uint) a.tags.length);
    foreach (tag; a.tags) tagList ~= cast(const(ubyte)[]) tag;
    ubyte[] scriptList = u16(cast(uint) a.scripts.length), scripts;
    foreach (s; a.scripts)
    {
        scriptList ~= cast(const(ubyte)[]) s.tag ~ u16(cast(uint)(2 + 6 * a.scripts.length + scripts.length));
        scripts ~= baseScriptTable(s);
    }
    return u16(4) ~ u16(cast(uint)(4 + tagList.length)) ~ tagList ~ scriptList ~ scripts;
}

/**
A `BASE` table of `major.minor` with optional axes and, from minor 1, an item
variation store after them (offset 0 when null).
*/
ubyte[] baseTable(const(BaseAxisSpec)[] horizontal, const(BaseAxisSpec)[] vertical,
    const(ubyte)[] store = null, uint minor = 0, uint major = 1)
{
    const headerLength = minor >= 1 ? 12 : 8;
    ubyte[] body;
    uint hAt, vAt, storeAt;
    if (horizontal.length)
    {
        hAt = cast(uint)(headerLength + body.length);
        body ~= baseAxisTable(horizontal[0]);
    }
    if (vertical.length)
    {
        vAt = cast(uint)(headerLength + body.length);
        body ~= baseAxisTable(vertical[0]);
    }
    if (store !is null)
    {
        storeAt = cast(uint)(headerLength + body.length);
        body ~= store;
    }
    auto t = u16(major) ~ u16(minor) ~ u16(hAt) ~ u16(vAt);
    if (minor >= 1)
        t ~= u32(storeAt);
    return t ~ body;
}

// ---------------------------------------------------------------------------
// Coverage, GDEF and MATH
// ---------------------------------------------------------------------------

/// A format-1 Coverage of `glyphs`, in the given order.
ubyte[] coverage1(const(uint)[] glyphs)
{
    ubyte[] t = u16(1) ~ u16(cast(uint) glyphs.length);
    foreach (g; glyphs) t ~= u16(g);
    return t;
}

/// A format-2 Coverage of `[start, end, startCoverageIndex]` ranges, in the given order.
ubyte[] coverage2(const(uint[3])[] ranges)
{
    ubyte[] t = u16(2) ~ u16(cast(uint) ranges.length);
    foreach (r; ranges) t ~= u16(r[0]) ~ u16(r[1]) ~ u16(r[2]);
    return t;
}

/**
A `GDEF` header of `major.minor` (12 bytes; 14 from 1.2; 18 from 1.3) with
every subtable offset null except, from 1.3, the item variation store, placed
after the header (offset 0 when null).
*/
ubyte[] gdefTable(const(ubyte)[] store, uint minor = 3, uint major = 1)
{
    const headerLength = minor >= 3 ? 18 : minor == 2 ? 14 : 12;
    ubyte[] t = u16(major) ~ u16(minor) ~ u16(0) ~ u16(0) ~ u16(0) ~ u16(0);
    if (minor >= 2)
        t ~= u16(0);
    if (minor >= 3)
        t ~= u32(store is null ? 0 : headerLength);
    return t ~ (minor >= 3 ? store : null);
}

/// A MathValueRecord: a value and a Device or VariationIndex table (offset 0 when null).
struct MathValueSpec
{
    int value;
    const(ubyte)[] device;
}

/**
`records` laid out at `recordsAt` inside a parent whose fixed part is
`fixedLength` bytes; their device tables are appended to `tail`, which
starts at `fixedLength` from the parent.
*/
ubyte[] mathValueRecords(const(MathValueSpec)[] records, size_t fixedLength, ref ubyte[] tail)
{
    ubyte[] t;
    foreach (r; records)
    {
        uint deviceAt;
        if (r.device !is null)
        {
            deviceAt = cast(uint)(fixedLength + tail.length);
            tail ~= r.device;
        }
        t ~= u16(cast(uint) r.value) ~ u16(deviceAt);
    }
    return t;
}

/// The MathConstants fields, in table order.
struct MathConstantsSpec
{
    int[2] percentScaleDown;
    uint[2] minHeight;
    MathValueSpec[51] records;
    int radicalDegreeBottomRaisePercent;
}

/// The bytes of a MathConstants table (214 bytes, then device tables).
ubyte[] mathConstantsTable(const MathConstantsSpec c)
{
    ubyte[] tail;
    auto t = u16(cast(uint) c.percentScaleDown[0]) ~ u16(cast(uint) c.percentScaleDown[1])
        ~ u16(c.minHeight[0]) ~ u16(c.minHeight[1]) ~ mathValueRecords(c.records.dup, 214, tail)
        ~ u16(cast(uint) c.radicalDegreeBottomRaisePercent);
    return t ~ tail;
}

/// A coverage and its MathValueRecords (MathItalicsCorrectionInfo, MathTopAccentAttachment).
struct MathValueTableSpec
{
    const(ubyte)[] coverage;
    const(MathValueSpec)[] values;
    /// Overrides the stored value count when not `uint.max`.
    uint count = uint.max;
}

/// The bytes of a MathItalicsCorrectionInfo or MathTopAccentAttachment.
ubyte[] mathValueTable(const MathValueTableSpec s)
{
    const fixedLength = 4 + 4 * s.values.length;
    ubyte[] tail;
    const records = mathValueRecords(s.values, fixedLength, tail);
    const covAt = s.coverage is null ? 0 : cast(uint)(fixedLength + tail.length);
    return u16(covAt) ~ u16(s.count == uint.max ? cast(uint) s.values.length : s.count) ~ records ~ tail
        ~ s.coverage;
}

/// A MathKern: correction heights and kern values (normally one more).
struct MathKernSpec
{
    bool present;
    const(MathValueSpec)[] heights;
    const(MathValueSpec)[] values;
}

/// The bytes of a MathKern; the stored height count is `heights.length`.
ubyte[] mathKernData(const MathKernSpec k)
{
    const fixedLength = 2 + 4 * (k.heights.length + k.values.length);
    ubyte[] tail;
    auto t = u16(cast(uint) k.heights.length) ~ mathValueRecords(k.heights, fixedLength, tail);
    t ~= mathValueRecords(k.values, fixedLength, tail);
    return t ~ tail;
}

/// A MathKernInfo: a coverage and, per record, the four corners (top right, top left, bottom right, bottom left).
struct MathKernInfoSpec
{
    const(ubyte)[] coverage;
    const(MathKernSpec[4])[] records;
    /// Overrides the stored record count when not `uint.max`.
    uint count = uint.max;
}

/// The bytes of a MathKernInfo.
ubyte[] mathKernInfoTable(const MathKernInfoSpec s)
{
    const fixedLength = 4 + 8 * s.records.length;
    ubyte[] body, t;
    foreach (r; s.records)
        foreach (k; r)
        {
            if (!k.present)
            {
                t ~= u16(0);
                continue;
            }
            t ~= u16(cast(uint)(fixedLength + body.length));
            body ~= mathKernData(k);
        }
    const covAt = s.coverage is null ? 0 : cast(uint)(fixedLength + body.length);
    return u16(covAt) ~ u16(s.count == uint.max ? cast(uint) s.records.length : s.count) ~ t ~ body
        ~ s.coverage;
}

/// MathGlyphInfo's four subtables, each null when its bytes are.
struct MathGlyphInfoSpec
{
    const(ubyte)[] italics;
    const(ubyte)[] topAccent;
    const(ubyte)[] extendedShapes;
    const(ubyte)[] kernInfo;
}

/// The bytes of a MathGlyphInfo; subtables follow in field order.
ubyte[] mathGlyphInfoTable(const MathGlyphInfoSpec s)
{
    ubyte[] t, body;
    foreach (sub; [s.italics, s.topAccent, s.extendedShapes, s.kernInfo])
    {
        t ~= u16(sub is null ? 0 : cast(uint)(8 + body.length));
        body ~= sub;
    }
    return t ~ body;
}

/// A GlyphPart.
struct GlyphPartSpec
{
    uint glyph, startConnector, endConnector, fullAdvance, flags;
}

/// A MathGlyphConstruction: an optional assembly (italics correction and parts) and `[glyph, advance]` variants.
struct ConstructionSpec
{
    bool hasAssembly;
    MathValueSpec italics;
    const(GlyphPartSpec)[] parts;
    const(uint[2])[] variants;
    /// Write a null offset for this construction.
    bool isNull;
}

/// The bytes of a GlyphAssembly.
ubyte[] glyphAssemblyTable(MathValueSpec italics, const(GlyphPartSpec)[] parts)
{
    const fixedLength = 6 + 10 * parts.length;
    ubyte[] tail;
    auto t = mathValueRecords([italics], fixedLength, tail) ~ u16(cast(uint) parts.length);
    foreach (p; parts)
        t ~= u16(p.glyph) ~ u16(p.startConnector) ~ u16(p.endConnector) ~ u16(p.fullAdvance) ~ u16(p.flags);
    return t ~ tail;
}

/// The bytes of a MathGlyphConstruction; the assembly follows the variant records.
ubyte[] constructionTable(const ConstructionSpec c)
{
    const fixedLength = 4 + 4 * c.variants.length;
    ubyte[] t = u16(c.hasAssembly ? cast(uint) fixedLength : 0) ~ u16(cast(uint) c.variants.length);
    foreach (v; c.variants) t ~= u16(v[0]) ~ u16(v[1]);
    return t ~ (c.hasAssembly ? glyphAssemblyTable(c.italics, c.parts) : null);
}

/// MathVariants: the overlap, a coverage and constructions per direction.
struct MathVariantsSpec
{
    uint minConnectorOverlap;
    const(ubyte)[] vertCoverage;
    const(ConstructionSpec)[] vertical;
    const(ubyte)[] horizCoverage;
    const(ConstructionSpec)[] horizontal;
}

/// The bytes of a MathVariants table: header, offsets, constructions, then coverages.
ubyte[] mathVariantsTable(const MathVariantsSpec s)
{
    const fixedLength = 10 + 2 * (s.vertical.length + s.horizontal.length);
    ubyte[] offsets, body;
    foreach (c; s.vertical ~ s.horizontal)
    {
        offsets ~= u16(c.isNull ? 0 : cast(uint)(fixedLength + body.length));
        if (!c.isNull)
            body ~= constructionTable(c);
    }
    uint place(const(ubyte)[] coverage)
    {
        if (coverage is null)
            return 0;
        const at = cast(uint)(fixedLength + body.length);
        body ~= coverage;
        return at;
    }
    const vAt = place(s.vertCoverage), hAt = place(s.horizCoverage);
    return u16(s.minConnectorOverlap) ~ u16(vAt) ~ u16(hAt) ~ u16(cast(uint) s.vertical.length)
        ~ u16(cast(uint) s.horizontal.length) ~ offsets ~ body;
}

/// A `MATH` table of `major.minor` with its three subtables after the header (offset 0 when null).
ubyte[] mathTableData(const(ubyte)[] constants, const(ubyte)[] glyphInfo, const(ubyte)[] variants,
    uint major = 1, uint minor = 0)
{
    ubyte[] t = u16(major) ~ u16(minor), body;
    foreach (sub; [constants, glyphInfo, variants])
    {
        t ~= u16(sub is null ? 0 : cast(uint)(10 + body.length));
        body ~= sub;
    }
    return t ~ body;
}
