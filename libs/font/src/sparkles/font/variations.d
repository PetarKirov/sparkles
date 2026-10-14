/**
Variation deltas (`docs/specs/font/variation-metrics.md`, FTV12, FTV13, FTM11,
FTM14).

An `ItemVariationStore` computes the delta of one item at normalized
coordinates exactly, in 1/65,536 font units, with fontations' per-axis
rounding. A `DeltaSetIndexMap` maps an item (a glyph, an axis) to its
`DeltaSetIndex`. `deviceDelta` resolves a Device or VariationIndex table,
keeping the design-unit variation delta and the whole-pixel device delta
apart.

Every view borrows the bytes of the table that contains it and reports errors
with that table's tag and offsets (FTP14). Constructing a view only records
what is wrong with it: a malformed store or map is reported by the lookups
that read it, so at the default coordinates, where nothing is read (FTM14), it
cannot fail a query. Nothing here allocates.
*/
module sparkles.font.variations;

import sparkles.font.bytes : be16, be24, be32, bes16, bes32, fits;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.units : DesignValue, Ppem;

@safe pure nothrow @nogc:

/**
Normalized variation coordinates: one F2Dot14 per `fvar` axis, in axis order.
An instance hands out a slice of its coordinates; a face without `fvar` has
none. A coordinate past the end of the slice reads as 0.
*/
alias NormalizedCoords = const(short)[];

/// Whether every coordinate is 0, the default instance (FTM14); true for none.
bool allZero(scope NormalizedCoords coords)
{
    foreach (c; coords)
        if (c != 0)
            return false;
    return true;
}

///
@("variations.allZero")
unittest
{
    static immutable short[3] origin = [0, 0, 0], bold = [0, 16_384, 0];
    assert(allZero(origin[]) && allZero(null) && !allZero(bold[]));
}

/// An item's address in an item variation store: outer (data) and inner (row) index.
struct DeltaSetIndex
{
    @safe pure nothrow @nogc:

    ushort outer;
    ushort inner;

    /// `NO_VARIATION_INDEX`: the item has no variation, its delta is zero.
    enum DeltaSetIndex noVariation = DeltaSetIndex(0xFFFF, 0xFFFF);
}

// ---------------------------------------------------------------------------
// Item variation store (FTV12)
// ---------------------------------------------------------------------------

/**
An item variation store inside some table: `GDEF`, `HVAR`, `VVAR`, `MVAR`,
`BASE`, `avar` 2. `ItemVariationStore.init` is no store (`present` is false).
*/
struct ItemVariationStore
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] table_;
    private Tag tag_;
    private ulong tableStart_;
    private ulong at_; // the store, from the table start
    private ulong regionsAt_; // the first region, from the table start
    private ushort axisCount_, regionCount_, dataCount_;
    private bool present_;
    private bool broken_;
    private FontError error_;

    /**
    The store at `offset` inside `table`, which is the table `tag` starting at
    absolute `tableStart`; `fvarAxisCount` is `fvar`'s axis count (0 without
    `fvar`). Checks the header, the format (1), the region list and its axis
    count, and that the data offsets array and the region array lie inside
    the table; a failure is recorded, not returned, and every delta at
    nonzero coordinates is that error (FTV12's first row). Costs O(1).
    */
    static ItemVariationStore read(return scope const(ubyte)[] table, Tag tag, ulong tableStart,
        ulong offset, ushort fvarAxisCount)
    {
        ItemVariationStore s;
        s.table_ = table;
        s.tag_ = tag;
        s.tableStart_ = tableStart;
        s.at_ = offset;
        s.present_ = true;
        if (offset >= table.length)
            return s.fail(FontErrorKind.badOffset, offset);
        if (!fits(table.length, offset, 8))
            return s.fail(FontErrorKind.truncated, offset);
        const p = cast(size_t) offset;
        if (be16(table, p) != 1)
            return s.fail(FontErrorKind.unsupportedVersion, offset);
        const regionListAt = offset + be32(table, p + 2);
        s.dataCount_ = be16(table, p + 6);
        if (!fits(table.length, offset + 8, 4UL * s.dataCount_))
            return s.fail(FontErrorKind.truncated, offset + 8);
        if (regionListAt == offset || regionListAt >= table.length)
            return s.fail(FontErrorKind.badOffset, offset + 2);
        if (!fits(table.length, regionListAt, 4))
            return s.fail(FontErrorKind.truncated, regionListAt);
        s.axisCount_ = be16(table, cast(size_t) regionListAt);
        s.regionCount_ = be16(table, cast(size_t) regionListAt + 2);
        if (s.axisCount_ != fvarAxisCount)
            return s.fail(FontErrorKind.badValue, regionListAt);
        s.regionsAt_ = regionListAt + 4;
        if (!fits(table.length, s.regionsAt_, 6UL * s.axisCount_ * s.regionCount_))
            return s.fail(FontErrorKind.truncated, s.regionsAt_);
        return s;
    }

    /**
    A store whose containing table could not be read: `present` and
    `broken`, so every delta at nonzero coordinates is `error` (`GDEF`'s
    header problem for `MATH` and `GPOS`).
    */
    package static ItemVariationStore failed(FontError error)
    {
        ItemVariationStore s;
        s.present_ = true;
        s.broken_ = true;
        s.error_ = error;
        return s;
    }

    private ItemVariationStore fail(FontErrorKind kind, ulong relative) return scope
    {
        broken_ = true;
        error_ = tableError(kind, tag_, tableStart_, relative);
        return this;
    }

    private FontError errorAt(FontErrorKind kind, ulong relative) const scope
        => tableError(kind, tag_, tableStart_, relative);

    /// Whether this is a store at all, rather than `ItemVariationStore.init`.
    bool present() const scope => present_;

    /// Whether the store's header is malformed; every delta at nonzero coordinates is then `error`.
    bool broken() const scope => broken_;

    /// What is wrong with the header, when `broken`.
    FontError error() const scope
    in (broken_)
        => error_;

    /// The region list's axis count, the number of variation regions, and of item variation data.
    ushort axisCount() const scope => axisCount_;
    /// ditto
    ushort regionCount() const scope => regionCount_;
    /// ditto
    ushort dataCount() const scope => dataCount_;

    /**
    The delta of item `index` at `coords` (FTV12), in 1/65,536 font units of
    a face with `unitsPerEm`. At all-zero coordinates the delta is zero and
    nothing is read (FTM14). Otherwise FTV12's rows apply in order: a broken
    store is its error; `NO_VARIATION_INDEX` is zero; an outer or inner index
    past its array, a `wordCount` past the region index count, or a region
    index past the region count is `badValue`. Each region's scalar starts at
    1 (F16.16) and every axis that does not decide a factor of 1 multiplies it
    by its ratio, rounded to F16.16 once per axis, ties away from zero; the
    delta is the exact sum of `scalar · delta`. Costs O(r · a) for the item's
    `r` regions and `a` axes; never allocates. An absent store is `badValue`
    at nonzero coordinates.
    */
    FontResult!DesignValue delta(DeltaSetIndex index, scope NormalizedCoords coords, ushort unitsPerEm)
        const scope
    in (unitsPerEm != 0)
    {
        if (allZero(coords))
            return fontOk(DesignValue(0, unitsPerEm));
        if (!present_)
            return fontErr!DesignValue(FontError(FontErrorKind.badValue));
        if (broken_)
            return fontErr!DesignValue(error_);
        if (index == DeltaSetIndex.noVariation)
            return fontOk(DesignValue(0, unitsPerEm));

        const t = table_;
        if (index.outer >= dataCount_)
            return fontErr!DesignValue(errorAt(FontErrorKind.badValue, at_ + 6));
        const offsetAt = at_ + 8 + 4UL * index.outer;
        const dataOffset = be32(t, cast(size_t) offsetAt);
        const dataAt = at_ + dataOffset;
        if (dataOffset == 0 || dataAt >= t.length)
            return fontErr!DesignValue(errorAt(FontErrorKind.badOffset, offsetAt));
        if (!fits(t.length, dataAt, 6))
            return fontErr!DesignValue(errorAt(FontErrorKind.truncated, dataAt));
        const d = cast(size_t) dataAt;
        const itemCount = be16(t, d);
        const wordField = be16(t, d + 2);
        const regionIndexCount = be16(t, d + 4);
        if (index.inner >= itemCount)
            return fontErr!DesignValue(errorAt(FontErrorKind.badValue, dataAt));
        const longWords = (wordField & 0x8000) != 0;
        const wordCount = wordField & 0x7FFF;
        if (wordCount > regionIndexCount)
            return fontErr!DesignValue(errorAt(FontErrorKind.badValue, dataAt + 2));
        const indicesAt = dataAt + 6;
        if (!fits(t.length, indicesAt, 2UL * regionIndexCount))
            return fontErr!DesignValue(errorAt(FontErrorKind.truncated, indicesAt));
        const wordSize = longWords ? 4 : 2;
        const rowLength = ulong(wordCount) * wordSize + ulong(regionIndexCount - wordCount) * (wordSize / 2);
        const rowAt = indicesAt + 2UL * regionIndexCount + rowLength * index.inner;
        if (!fits(t.length, rowAt, rowLength))
            return fontErr!DesignValue(errorAt(FontErrorKind.truncated, rowAt));

        long sum;
        size_t at = cast(size_t) rowAt;
        foreach (j; 0 .. regionIndexCount)
        {
            const regionIndexAt = cast(size_t) indicesAt + 2 * j;
            const region = be16(t, regionIndexAt);
            if (region >= regionCount_)
                return fontErr!DesignValue(errorAt(FontErrorKind.badValue, regionIndexAt));
            int value;
            if (j < wordCount)
            {
                value = longWords ? bes32(t, at) : bes16(t, at);
                at += wordSize;
            }
            else
            {
                value = longWords ? bes16(t, at) : cast(byte) t[at];
                at += wordSize / 2;
            }
            // |scalar| ≤ 2^16 and |value| < 2^31: each term is under 2^47, and
            // at most 2^16 terms keep the sum under 2^63.
            sum += long(regionScalar(region, coords)) * value;
        }
        return fontOk(DesignValue(sum, unitsPerEm));
    }

    /// The F16.16 scalar of region `region` at `coords` (FTV12's per-axis rows).
    private int regionScalar(ushort region, scope NormalizedCoords coords) const scope
    {
        const t = table_;
        const base = cast(size_t)(regionsAt_ + 6UL * axisCount_ * region);
        int scalar = 0x1_0000;
        foreach (i; 0 .. axisCount_)
        {
            const p = base + 6 * i;
            const start = bes16(t, p), peak = bes16(t, p + 2), end = bes16(t, p + 4);
            const coord = i < coords.length ? coords[i] : short(0);
            if (peak == 0 || coord == peak)
                continue;
            if (start > peak || peak > end || (start < 0 && end > 0))
                continue;
            if (coord <= start || coord >= end)
                return 0;
            // fontations' Fixed::mul_div on F16.16 operands (F2Dot14 · 4): the
            // ratio is in (0, 1), so every operand is positive and adding half
            // the divisor rounds to nearest, ties away from zero.
            const numerator = 4L * (coord < peak ? coord - start : end - coord);
            const denominator = 4L * (coord < peak ? peak - start : end - peak);
            scalar = cast(int)((long(scalar) * numerator + (denominator >> 1)) / denominator);
        }
        return scalar;
    }
}

///
@("variations.ItemVariationStore.delta")
@safe pure nothrow @nogc
unittest
{
    // One axis; one region peaking at 1.0; one item whose delta is 100 units.
    static immutable ubyte[] store = [
        0, 1, 0, 0, 0, 12, 0, 1, 0, 0, 0, 22, // format 1, regionList @12, 1 data @22
        0, 1, 0, 1, 0, 0, 0x40, 0, 0x40, 0, // 1 axis, 1 region: (0, 1, 1)
        0, 1, 0, 1, 0, 1, 0, 0, 0, 100, // 1 item, 1 word delta, region 0: 100
    ];
    const ivs = ItemVariationStore.read(store, Tag("HVAR"), 0, 0, 1);
    static immutable short[1] half = [0x2000];
    assert(ivs.delta(DeltaSetIndex(0, 0), half[], 1_000).value == DesignValue.fromUnits(50, 1_000));
    assert(ivs.delta(DeltaSetIndex(0, 1), half[], 1_000).error.kind == FontErrorKind.badValue);
    assert(ivs.delta(DeltaSetIndex(0, 1), null, 1_000).value.raw == 0); // FTM14
}

// ---------------------------------------------------------------------------
// Delta-set index maps (FTV13)
// ---------------------------------------------------------------------------

/**
A DeltaSetIndexMap inside some table (`HVAR`, `VVAR`, `avar` 2). Like the
store, its header problems are recorded and returned by `map`.
*/
struct DeltaSetIndexMap
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] table_;
    private Tag tag_;
    private ulong tableStart_;
    private ulong entriesAt_;
    private uint count_;
    private ubyte entrySize_, innerBits_;
    private bool broken_;
    private FontError error_;

    /**
    The map at `offset` inside `table`, the table `tag` at absolute
    `tableStart`. A format other than 0 or 1 is `unsupportedVersion`; a header
    or entry array past the table is `truncated` (`badOffset` when the map
    starts past it). Costs O(1).
    */
    static DeltaSetIndexMap read(return scope const(ubyte)[] table, Tag tag, ulong tableStart, ulong offset)
    {
        DeltaSetIndexMap m;
        m.table_ = table;
        m.tag_ = tag;
        m.tableStart_ = tableStart;
        if (offset >= table.length)
            return m.fail(FontErrorKind.badOffset, offset);
        const p = cast(size_t) offset;
        const format = table[p];
        if (format > 1)
            return m.fail(FontErrorKind.unsupportedVersion, offset);
        const headerLength = format == 0 ? 4 : 6;
        if (!fits(table.length, offset, headerLength))
            return m.fail(FontErrorKind.truncated, offset);
        const entryFormat = table[p + 1];
        m.innerBits_ = cast(ubyte)((entryFormat & 0x0F) + 1);
        m.entrySize_ = cast(ubyte)(((entryFormat >> 4) & 0x03) + 1);
        m.count_ = format == 0 ? be16(table, p + 2) : be32(table, p + 2);
        m.entriesAt_ = offset + headerLength;
        if (!fits(table.length, m.entriesAt_, ulong(m.entrySize_) * m.count_))
            return m.fail(FontErrorKind.truncated, m.entriesAt_);
        return m;
    }

    private DeltaSetIndexMap fail(FontErrorKind kind, ulong relative) return scope
    {
        broken_ = true;
        error_ = tableError(kind, tag_, tableStart_, relative);
        return this;
    }

    /// The number of entries.
    uint count() const scope => count_;

    /**
    The index `index` maps to (FTV13): an index at or past `count` uses the
    last entry; a map of count 0 is the identity, outer `index >> 16` and
    inner `index & 0xFFFF`. A malformed map is its error. Costs O(1).
    */
    FontResult!DeltaSetIndex map(uint index) const scope
    {
        if (broken_)
            return fontErr!DeltaSetIndex(error_);
        if (count_ == 0)
            return fontOk(DeltaSetIndex(cast(ushort)(index >> 16), cast(ushort) index));
        const i = index < count_ ? index : count_ - 1;
        const at = cast(size_t)(entriesAt_ + ulong(entrySize_) * i);
        uint entry;
        final switch (entrySize_)
        {
            case 1: entry = table_[at]; break;
            case 2: entry = be16(table_, at); break;
            case 3: entry = be24(table_, at); break;
            case 4: entry = be32(table_, at); break;
        }
        return fontOk(DeltaSetIndex(cast(ushort)(entry >> innerBits_),
            cast(ushort)(entry & ((1u << innerBits_) - 1))));
    }
}

///
@("variations.DeltaSetIndexMap.map")
@safe pure nothrow @nogc
unittest
{
    // Format 0, 1-byte entries with 4 inner bits: 0x12 → (1, 2), 0x34 → (3, 4).
    static immutable ubyte[] bytes = [0, 0x03, 0, 2, 0x12, 0x34];
    const m = DeltaSetIndexMap.read(bytes, Tag("HVAR"), 0, 0);
    assert(m.map(0).value == DeltaSetIndex(1, 2));
    assert(m.map(9).value == DeltaSetIndex(3, 4)); // past the count: the last entry
}

// ---------------------------------------------------------------------------
// Device and VariationIndex tables (FTM11)
// ---------------------------------------------------------------------------

/**
The adjustment a Device or VariationIndex table makes (FTM11). The two kinds
stay apart: `variation` is a design-unit delta that every query adds, and
`devicePixels` a whole-pixel hint that only a pixel query at an integer ppem
inside the table's range applies, as `deviceApplied` records.
*/
struct DeviceDelta
{
    /// The VariationIndex delta; zero for a Device table.
    DesignValue variation;
    /// The Device table's delta in whole pixels; zero unless `deviceApplied`.
    int devicePixels;
    /// Whether a Device table's delta applies at the query's ppem.
    bool deviceApplied;
}

/**
The Device or VariationIndex table at `offset` inside `table` (the table
`tag` at absolute `tableStart`), resolved for one query (FTM11). `offset` is
from the start of `table`; a null offset field means no table, which the
caller checks before calling.

A Device table (delta format 1, 2 or 3) contributes only when `ppem` is a
valid integer ppem inside `[startSize, endSize]`; design and physical queries
pass no ppem (`Ppem.init`) and never apply one. A VariationIndex table (format
`0x8000`) contributes `store`'s delta (FTV12) at `coords`: zero at all-zero
coordinates (FTM14), `badValue` when `store` is not `present`. Another delta
format is `unsupportedVersion`. Costs O(1) for a Device table and O(r · a) for
a VariationIndex.
*/
FontResult!DeviceDelta deviceDelta(scope const(ubyte)[] table, Tag tag, ulong tableStart, ulong offset,
    scope const ref ItemVariationStore store, scope NormalizedCoords coords, ushort unitsPerEm,
    Ppem ppem = Ppem.init)
in (unitsPerEm != 0)
{
    auto result = DeviceDelta(DesignValue(0, unitsPerEm));
    if (offset >= table.length)
        return fontErr!DeviceDelta(tableError(FontErrorKind.badOffset, tag, tableStart, offset));
    if (!fits(table.length, offset, 6))
        return fontErr!DeviceDelta(tableError(FontErrorKind.truncated, tag, tableStart, offset));
    const p = cast(size_t) offset;
    const format = be16(table, p + 4);
    if (format == 0x8000)
    {
        if (allZero(coords))
            return fontOk(result);
        if (!store.present)
            return fontErr!DeviceDelta(tableError(FontErrorKind.badValue, tag, tableStart, offset + 4));
        const d = store.delta(DeltaSetIndex(be16(table, p), be16(table, p + 2)), coords, unitsPerEm);
        if (d.hasError)
            return fontErr!DeviceDelta(d.error);
        result.variation = d.value;
        return fontOk(result);
    }
    if (format < 1 || format > 3)
        return fontErr!DeviceDelta(tableError(FontErrorKind.unsupportedVersion, tag, tableStart, offset + 4));
    const startSize = be16(table, p), endSize = be16(table, p + 2);
    if (!ppem.valid || !ppem.isInteger || ppem.numerator < startSize || ppem.numerator > endSize)
        return fontOk(result);
    // Format f packs 2^f-bit signed values, 2^(4-f) to a big-endian word.
    const s = cast(uint)(ppem.numerator - startSize);
    const wordAt = offset + 6 + 2UL * (s >> (4 - format));
    if (!fits(table.length, wordAt, 2))
        return fontErr!DeviceDelta(tableError(FontErrorKind.truncated, tag, tableStart, wordAt));
    const word = be16(table, cast(size_t) wordAt);
    const bits = 1u << format;
    const slot = s & ((1u << (4 - format)) - 1);
    const mask = (1u << bits) - 1;
    int value = (word >> (16 - (slot + 1) * bits)) & mask;
    if (value >= (mask + 1) >> 1)
        value -= mask + 1;
    result.devicePixels = value;
    result.deviceApplied = true;
    return fontOk(result);
}

///
@("variations.deviceDelta.format2")
@safe pure nothrow @nogc
unittest
{
    // Sizes 12–13, format 2 (4-bit values): +1 at 12, -2 at 13.
    static immutable ubyte[] device = [0, 12, 0, 13, 0, 2, 0x1E, 0x00];
    const none = ItemVariationStore.init;
    const at13 = deviceDelta(device, Tag("GPOS"), 0, 0, none, null, 1_000, Ppem.fromInteger(13).value);
    assert(at13.value.deviceApplied && at13.value.devicePixels == -2);
    const design = deviceDelta(device, Tag("GPOS"), 0, 0, none, null, 1_000);
    assert(!design.value.deviceApplied && design.value.devicePixels == 0);
}
