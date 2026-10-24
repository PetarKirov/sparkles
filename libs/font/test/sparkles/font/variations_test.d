/**
Item variation stores, delta-set index maps and Device tables (FTV12, FTV13,
FTM11, FTM13, FTM14) on hand-built fixtures, each delta traced by hand through
fontations' `compute_scalar` (`Fixed::mul_div`: `(s·n + d/2) / d` on F16.16
operands, F2Dot14 values times 4).
*/
module sparkles.font.variations_test;

import sparkles.base.text.layout_units : I128, Rational, U128;

import sparkles.font.errors : FontErrorKind, Tag;
import sparkles.font.fixtures;
import sparkles.font.units : DesignValue, Ppem;
import sparkles.font.variations;

private enum ushort upem = 1_000;
private enum short one = 16_384; // 1.0 in F2Dot14

/// A store of one region over `axes.length` axes and one item whose delta is `delta`.
private ubyte[] oneRegionStore(const(RegionAxis)[] axes, int delta)
    @safe pure nothrow
    => itemVariationStore(cast(uint) axes.length, [axes], [VarData([0], 1, false, [[delta]])]);

/// The raw delta (1/65,536 units) of `oneRegionStore(axes, delta)` at `coords`.
private long oneRegion(const(RegionAxis)[] axes, const(short)[] coords, int delta = 1)
    @safe pure nothrow
{
    const bytes = oneRegionStore(axes, delta);
    const r = ItemVariationStore.read(bytes, Tag("HVAR"), 0, 0, cast(ushort) axes.length)
        .delta(DeltaSetIndex(0, 0), coords, upem);
    assert(r.hasValue);
    assert(r.value.unitsPerEm == upem);
    return r.value.raw;
}

/// The store `bytes` (axes `axisCount`) read whole from a table.
private ItemVariationStore storeOf(return scope const(ubyte)[] bytes, ushort axisCount, ulong offset = 0)
    @safe pure nothrow @nogc
    => ItemVariationStore.read(bytes, Tag("HVAR"), 0, offset, axisCount);

// ---------------------------------------------------------------------------
// FTV12: the per-axis rows, in order
// ---------------------------------------------------------------------------

@("variations.FTV12.peakZeroIsFactorOne")
@safe pure nothrow
unittest
{
    // peak = 0 decides factor 1 before the range rows: coord 0.5 lies past end 0.25.
    assert(oneRegion([[-one, 0, one / 4]], [one / 2]) == 65_536);
    assert(oneRegion([[0, 0, 0]], [-one]) == 65_536);
}

@("variations.FTV12.coordAtPeakIsFactorOne")
@safe pure nothrow
unittest
{
    assert(oneRegion([[0, one / 2, one]], [one / 2], 7) == 7 * 65_536);
    // At the peak even where the peak sits on the region's edge.
    assert(oneRegion([[one, one, one]], [one], 3) == 3 * 65_536);
}

@("variations.FTV12.invalidAxisIsIgnored")
@safe pure nothrow
unittest
{
    // start > peak: coord 4000 ≤ start would be factor 0, but the axis is ignored.
    assert(oneRegion([[12_000, one / 2, one]], [4_000]) == 65_536);
    // peak > end.
    assert(oneRegion([[0, one, one / 2]], [12_000]) == 65_536);
    // start < 0 < end, coexisting with coord ≤ start and coord ≥ end: the row order
    // makes it factor 1, not 0.
    assert(oneRegion([[-one / 2, one / 2, one]], [-one]) == 65_536);
    assert(oneRegion([[-one / 2, one / 2, one]], [-one / 2]) == 65_536);
    assert(oneRegion([[-one / 2, one / 2, one]], [one]) == 65_536);
    // …and where it would otherwise interpolate.
    assert(oneRegion([[-one / 2, one / 2, one]], [one / 4]) == 65_536);
}

@("variations.FTV12.outsideRangeIsFactorZero")
@safe pure nothrow
unittest
{
    assert(oneRegion([[one / 4, one / 2, one]], [one / 4], 100) == 0); // coord = start
    assert(oneRegion([[one / 4, one / 2, one]], [100], 100) == 0); // below start
    assert(oneRegion([[0, one / 2, 3 * one / 4]], [3 * one / 4], 100) == 0); // coord = end
    assert(oneRegion([[0, one / 2, 3 * one / 4]], [one], 100) == 0); // above end
    assert(oneRegion([[0, one, one]], [-one], 100) == 0); // the other side of zero
    // One axis at factor 0 zeroes a region whose other axis is at its peak.
    assert(oneRegion([[0, one, one], [0, one, one]], [one, 0], 100) == 0);
}

@("variations.FTV12.interpolation")
@safe pure nothrow
unittest
{
    // Below the peak: (coord − start)/(peak − start) = 0.5.
    assert(oneRegion([[0, one, one]], [one / 2], 100) == 50 * 65_536);
    // Above: (end − coord)/(end − peak) = 4096/8192.
    assert(oneRegion([[0, one / 2, one]], [3 * one / 4], 100) == 50 * 65_536);
    // Negative regions: below the peak and above it.
    assert(oneRegion([[-one, -one / 2, 0]], [-3 * one / 4], 100) == 50 * 65_536);
    assert(oneRegion([[-one, -one / 2, 0]], [-one / 4], 100) == 50 * 65_536);
    // 1/16384 of a scalar step: 65,536 · 1/16,384 = 4 exactly.
    assert(oneRegion([[0, one, one]], [1]) == 4);
    // 65,536 · 1/3 = 21,845.33…: (65,536·4 + 6)/12 = 21,845.
    assert(oneRegion([[0, 3, 3]], [1]) == 21_845);
    // A negative delta: the scalar rounds, then multiplies exactly.
    assert(oneRegion([[0, 3, 3]], [1], -5) == -5 * 21_845);
}

@("variations.FTV12.tieRoundsAwayFromZero")
@safe pure nothrow
unittest
{
    // Axis 1, ratio 1/3: (65,536·4 + 6)/12 = 21,845. Axis 2, ratio 1/2:
    // (21,845·4 + 4)/8 = 10,923 — the tie 10,922.5 rounds away from zero
    // (ties to even would give 10,922, truncation 10,922).
    assert(oneRegion([[0, 3, 3], [0, 2, 2]], [1, 1]) == 10_923);
    assert(oneRegion([[0, 3, 3], [0, 2, 2]], [1, 1], -1) == -10_923);
}

@("variations.FTV12.perAxisRounding")
@safe pure nothrow
unittest
{
    // Ratios 2/3 then 1/2. Per axis (fontations): (65,536·8 + 6)/12 = 43,691,
    // then (43,691·4 + 4)/8 = 21,846. Multiplying first, 65,536 · 1/3 =
    // 21,845.33… would round to 21,845.
    assert(oneRegion([[0, 3, 3], [0, 2, 2]], [2, 1]) == 21_846);
    assert(oneRegion([[0, 3, 3], [0, 2, 2]], [2, 1], 1_000) == 21_846_000);
    // Axis order matters: 1/2 gives 32,768, then (32,768·8 + 6)/12 = 21,845.
    assert(oneRegion([[0, 2, 2], [0, 3, 3]], [1, 2]) == 21_845);
}

@("variations.FTV12.missingCoordinatesReadAsZero")
@safe pure nothrow
unittest
{
    // A coordinate past the slice is 0: factor 0 for an axis peaking at 1.
    assert(oneRegion([[0, one, one], [0, one, one]], [one], 100) == 0);
    assert(oneRegion([[0, one, one], [0, 0, 0]], [one], 100) == 100 * 65_536);
}

// ---------------------------------------------------------------------------
// FTV12: rows, words and indices
// ---------------------------------------------------------------------------

private const(RegionAxis[])[] twoRegions() @safe pure nothrow
    => [[[0, one, one]], [[0, one / 2, one]]];

@("variations.FTV12.deltaWidths")
@safe pure nothrow
unittest
{
    static immutable short[1] at = [one / 2]; // region 0 at 0.5, region 1 at its peak
    // Normal: one 16-bit, then 8-bit deltas.
    const normal = itemVariationStore(1, twoRegions, [VarData([0, 1], 1, false, [[-300, -100], [1_000, 127]])]);
    assert(storeOf(normal, 1).delta(DeltaSetIndex(0, 0), at[], upem).value.raw == (-150 - 100) * 65_536L);
    assert(storeOf(normal, 1).delta(DeltaSetIndex(0, 1), at[], upem).value.raw == (500 + 127) * 65_536L);
    // LONG_WORDS: one 32-bit, then 16-bit deltas.
    const long_ = itemVariationStore(1, twoRegions, [VarData([0, 1], 1, true, [[100_000, -30_000], [-2, 3]])]);
    assert(storeOf(long_, 1).delta(DeltaSetIndex(0, 0), at[], upem).value.raw == (50_000 - 30_000) * 65_536L);
    assert(storeOf(long_, 1).delta(DeltaSetIndex(0, 1), at[], upem).value.raw == (-1 + 3) * 65_536L);
    // All words, and no words.
    const words = itemVariationStore(1, twoRegions, [VarData([1, 0], 2, false, [[-32_768, 32_767]])]);
    assert(storeOf(words, 1).delta(DeltaSetIndex(0, 0), at[], upem).value.raw
        == -32_768 * 65_536L + 32_767 * 32_768L);
    const bytes = itemVariationStore(1, twoRegions, [VarData([1, 0], 0, false, [[-128, 3]])]);
    assert(storeOf(bytes, 1).delta(DeltaSetIndex(0, 0), at[], upem).value.raw == -128 * 65_536L + 3 * 32_768L);
    // Long words at the 32-bit extreme are summed in 64 bits without overflow.
    const extreme = itemVariationStore(1, twoRegions, [VarData([1, 1], 2, true, [[int.min, int.min]])]);
    assert(storeOf(extreme, 1).delta(DeltaSetIndex(0, 0), at[], upem).value.raw == 2L * int.min * 65_536);
}

@("variations.FTV12.outerAndInner")
@safe pure nothrow
unittest
{
    static immutable short[1] at = [one];
    const ivs = itemVariationStore(1, twoRegions, [
        VarData([0], 1, false, [[10], [20]]),
        VarData([1], 0, false, [[-3], [4], [5]]),
    ]);
    const s = storeOf(ivs, 1);
    assert(s.dataCount == 2 && s.regionCount == 2 && s.axisCount == 1 && s.present && !s.broken);
    assert(s.delta(DeltaSetIndex(0, 1), at[], upem).value.raw == 20 * 65_536L);
    // Region 1 is (0, 0.5, 1): at 1.0 it is coord ≥ end, factor 0.
    assert(s.delta(DeltaSetIndex(1, 2), at[], upem).value.raw == 0);
    static immutable short[1] mid = [one / 2];
    assert(s.delta(DeltaSetIndex(1, 2), mid[], upem).value.raw == 5 * 65_536L);
}

@("variations.FTV12.noVariationIndex")
@safe pure nothrow
unittest
{
    static immutable short[1] at = [one];
    const empty = itemVariationStore(1, twoRegions, []);
    assert(storeOf(empty, 1).delta(DeltaSetIndex.noVariation, at[], upem).value == DesignValue(0, upem));
    // A broken store is its error first (row 1 precedes row 2).
    const r = storeOf(empty, 2).delta(DeltaSetIndex.noVariation, at[], upem);
    assert(r.error.kind == FontErrorKind.badValue);
    // Only the pair (0xFFFF, 0xFFFF): (0xFFFF, 0) is a dangling outer index.
    assert(storeOf(empty, 1).delta(DeltaSetIndex(0xFFFF, 0), at[], upem).error.kind == FontErrorKind.badValue);
}

@("variations.FTV12.danglingIndices")
@safe pure nothrow
unittest
{
    static immutable short[1] at = [one];
    // Header 12, region list 12 (+4, two 6-byte regions), data at 28.
    const ivs = itemVariationStore(1, twoRegions, [VarData([0, 2], 0, false, [[1, 1]])]);
    const s = ItemVariationStore.read(ivs, Tag("GDEF"), 500, 0, 1);
    const outer = s.delta(DeltaSetIndex(1, 0), at[], upem).error;
    assert(outer.kind == FontErrorKind.badValue && outer.tag == Tag("GDEF") && outer.tableOffset == 6);
    assert(outer.offset == 506);
    const inner = s.delta(DeltaSetIndex(0, 1), at[], upem).error;
    assert(inner.kind == FontErrorKind.badValue && inner.tableOffset == 28);
    // Region index 2 of 2, at the data's second region index.
    const region = s.delta(DeltaSetIndex(0, 0), at[], upem).error;
    assert(region.kind == FontErrorKind.badValue && region.tableOffset == 28 + 6 + 2);
    // wordCount 3 > regionIndexCount 2: the item data is badValue.
    const wide = itemVariationStore(1, twoRegions, [VarData([0, 1], 3, false, [[1, 1, 1]])]);
    const w = storeOf(wide, 1).delta(DeltaSetIndex(0, 0), at[], upem).error;
    assert(w.kind == FontErrorKind.badValue && w.tableOffset == 28 + 2);
    // A data offset of 0.
    auto nullData = itemVariationStore(1, twoRegions, [VarData([0], 0, false, [[1]])]);
    nullData[8 .. 12] = 0;
    assert(storeOf(nullData, 1).delta(DeltaSetIndex(0, 0), at[], upem).error.kind == FontErrorKind.badOffset);
}

@("variations.FTV12.regionAxisCountMismatch")
@safe pure nothrow
unittest
{
    static immutable short[2] at = [one, one];
    const ivs = oneRegionStore([[0, one, one]], 5);
    const s = storeOf(ivs, 2);
    assert(s.present && s.broken);
    assert(s.error.kind == FontErrorKind.badValue && s.error.tableOffset == 12);
    assert(s.delta(DeltaSetIndex(0, 0), at[], upem).error == s.error);
    // A face without fvar (0 axes) refuses a one-axis store too.
    assert(storeOf(ivs, 0).broken);
}

@("variations.FTM14.defaultCoordinatesReadNothing")
@safe pure nothrow
unittest
{
    static immutable short[2] origin = [0, 0];
    static immutable ubyte[8] garbage = [0, 7, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
    const broken = storeOf(garbage[], 2);
    assert(broken.broken && broken.error.kind == FontErrorKind.unsupportedVersion);
    assert(broken.delta(DeltaSetIndex(3, 9), origin[], upem).value == DesignValue(0, upem));
    assert(broken.delta(DeltaSetIndex(3, 9), null, upem).value == DesignValue(0, upem));
    static immutable short[2] moved = [0, 1];
    assert(broken.delta(DeltaSetIndex(3, 9), moved[], upem).error.kind == FontErrorKind.unsupportedVersion);
    // No store at all.
    const absent = ItemVariationStore.init;
    assert(!absent.present && absent.delta(DeltaSetIndex(0, 0), origin[], upem).hasValue);
    assert(absent.delta(DeltaSetIndex(0, 0), moved[], upem).error.kind == FontErrorKind.badValue);
}

// ---------------------------------------------------------------------------
// FTB1/FTB2: truncated and misplaced stores
// ---------------------------------------------------------------------------

@("variations.FTV12.hostileStructure")
@safe pure nothrow
unittest
{
    static immutable short[1] at = [one];
    // Store: header 8+4, region list at 12 (4 + 12), data at 28 (6 + 4 + 2 rows of 1+1 bytes).
    const good = itemVariationStore(1, twoRegions, [VarData([0, 1], 1, false, [[1, 2], [3, 4]])]);
    assert(good.length == 28 + 6 + 4 + 3 + 3);
    assert(storeOf(good, 1).delta(DeltaSetIndex(0, 1), at[], upem).value.raw == 3 * 65_536L);

    FontErrorKind kindAt(const(ubyte)[] bytes, ulong offset = 0, DeltaSetIndex i = DeltaSetIndex(0, 1))
        => storeOf(bytes, 1, offset).delta(i, at[], upem).error.kind;

    // The store past the table, its header cut.
    assert(kindAt(good, good.length) == FontErrorKind.badOffset);
    assert(kindAt(good[0 .. 5]) == FontErrorKind.truncated);
    // The data offsets array cut (dataCount 1 needs bytes 8–11).
    assert(kindAt(good[0 .. 10]) == FontErrorKind.truncated);
    // The region list past the table, its header cut, its regions cut.
    assert(kindAt(good[0 .. 12]) == FontErrorKind.badOffset);
    assert(kindAt(good[0 .. 14]) == FontErrorKind.truncated);
    assert(kindAt(good[0 .. 22]) == FontErrorKind.truncated);
    // The data past the table, its header, region indices and rows cut.
    assert(kindAt(good[0 .. 28]) == FontErrorKind.badOffset);
    assert(kindAt(good[0 .. 31]) == FontErrorKind.truncated);
    assert(kindAt(good[0 .. 36]) == FontErrorKind.truncated);
    assert(kindAt(good[0 .. 40], 0, DeltaSetIndex(0, 0)) == FontErrorKind.truncated);
    // Row 1 cut while row 0 still fits.
    assert(kindAt(good[0 .. 43]) == FontErrorKind.truncated);
    assert(storeOf(good[0 .. 43], 1).delta(DeltaSetIndex(0, 0), at[], upem).value.raw == 1 * 65_536L);
    // A huge region list offset and a huge data offset.
    auto far = good.dup;
    far[2 .. 6] = 0xFF;
    assert(kindAt(far) == FontErrorKind.badOffset);
    far = good.dup;
    far[8 .. 12] = 0xFF;
    assert(kindAt(far) == FontErrorKind.badOffset);
    // A store embedded at an offset reports offsets from the containing table.
    const embedded = new ubyte[10] ~ good[0 .. 22];
    const e = ItemVariationStore.read(embedded, Tag("MVAR"), 2_000, 10, 1);
    assert(e.error.kind == FontErrorKind.truncated && e.error.tag == Tag("MVAR"));
    assert(e.error.tableOffset == 10 + 16 && e.error.offset == 2_026);
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

@("variations.hostile.mutatedStoresAndMaps")
@safe pure nothrow
unittest
{
    // Mutated stores, maps and Device tables: any result is fine, an assertion is not.
    const store = itemVariationStore(2, [[[0, one, one], [-one, -one, 0]], [[-one / 2, one / 2, one], [0, 0, 0]]],
        [VarData([0, 1], 1, true, [[1_000, -7], [70_000, 2]]), VarData([1], 0, false, [[5]])]);
    const map = deltaSetIndexMap([[0, 1], [1, 0]], 4, 3, 1);
    const device = deviceTable(9, 20, 2, [1, -2, 3, -4, 5, -6, 7]);
    static immutable short[2][4] coords = [[one, 0], [-one / 3, one / 2], [0, 0], [1, -1]];
    auto rng = Rng(0x5EED_F0E7);
    foreach (round; 0 .. 2_000)
    {
        foreach (base; [store, map, device])
        {
            auto m = base.dup;
            final switch (rng.below(3))
            {
                case 0:
                    foreach (_; 0 .. 1 + rng.below(4))
                        m[rng.below(m.length)] ^= cast(ubyte)(1 << rng.below(8));
                    break;
                case 1:
                    m.length = rng.below(m.length);
                    break;
                case 2:
                    if (m.length >= 2)
                        m[rng.below(m.length - 1)] = 0xFF;
                    break;
            }
            const s = ItemVariationStore.read(m, Tag("GDEF"), 0, rng.below(4) == 0 ? rng.below(64) : 0, 2);
            const d = DeltaSetIndexMap.read(m, Tag("HVAR"), 0, 0);
            foreach (c; coords)
                foreach (outer; 0 .. 3)
                    foreach (inner; 0 .. 3)
                        cast(void) s.delta(DeltaSetIndex(cast(ushort) outer, cast(ushort) inner), c[], upem);
            foreach (i; 0 .. 4)
                cast(void) d.map(i);
            foreach (ppem; [0, 9, 12, 20, 30])
                cast(void) deviceDelta(m, Tag("GPOS"), 0, rng.below(4), s, coords[1][], upem,
                    ppem ? Ppem.fromInteger(ppem).value : Ppem.init);
        }
    }
}

// ---------------------------------------------------------------------------
// FTV13: delta-set index maps
// ---------------------------------------------------------------------------

@("variations.FTV13.entryFormats")
@safe pure nothrow
unittest
{
    // Every entry size, with inner bit counts at both ends.
    static immutable uint[2][4] shapes = [[1, 1], [8, 2], [12, 3], [16, 4]];
    foreach (shape; shapes)
        foreach (format; 0 .. 2)
        {
            const innerBits = shape[0], size = shape[1];
            const maxOuter = size * 8 - innerBits >= 16 ? 0xFFFF : (1u << (size * 8 - innerBits)) - 1;
            const maxInner = (1u << innerBits) - 1;
            const uint[2][3] entries = [[0u, 0u], [maxOuter, maxInner], [1u, maxInner / 2]];
            const bytes = deltaSetIndexMap(entries[], innerBits, size, format);
            assert(bytes.length == (format == 0 ? 4 : 6) + 3 * size);
            const m = DeltaSetIndexMap.read(bytes, Tag("HVAR"), 0, 0);
            assert(m.count == 3);
            assert(m.map(0).value == DeltaSetIndex(0, 0));
            assert(m.map(1).value == DeltaSetIndex(cast(ushort) maxOuter, cast(ushort) maxInner));
            assert(m.map(2).value == DeltaSetIndex(1, cast(ushort)(maxInner / 2)));
            // At or past the count: the last entry.
            assert(m.map(3).value == m.map(2).value);
            assert(m.map(uint.max).value == m.map(2).value);
        }
}

@("variations.FTV13.countZeroIsIdentity")
@safe pure nothrow
unittest
{
    foreach (format; 0 .. 2)
    {
        const m = DeltaSetIndexMap.read(deltaSetIndexMap([], 16, 4, format), Tag("VVAR"), 0, 0);
        assert(m.map(0x0003_0005).value == DeltaSetIndex(3, 5));
        assert(m.map(7).value == DeltaSetIndex(0, 7));
        assert(m.map(uint.max).value == DeltaSetIndex.noVariation);
    }
}

@("variations.FTV13.malformed")
@safe pure nothrow
unittest
{
    // Format 2: every lookup is unsupportedVersion, even an empty map.
    auto other = deltaSetIndexMap([], 1, 1);
    other[0] = 2;
    const e = DeltaSetIndexMap.read(other, Tag("HVAR"), 100, 0).map(0).error;
    assert(e.kind == FontErrorKind.unsupportedVersion && e.tableOffset == 0 && e.offset == 100);
    // A header, or the entries, past the table.
    const map = deltaSetIndexMap([[1, 2], [3, 4]], 8, 2, 1);
    assert(DeltaSetIndexMap.read(map[0 .. 5], Tag("HVAR"), 0, 0).map(0).error.kind == FontErrorKind.truncated);
    const cut = DeltaSetIndexMap.read(map[0 .. $ - 1], Tag("HVAR"), 0, 0).map(0).error;
    assert(cut.kind == FontErrorKind.truncated && cut.tableOffset == 6);
    assert(DeltaSetIndexMap.read(map, Tag("HVAR"), 0, map.length).map(0).error.kind == FontErrorKind.badOffset);
    // Embedded at an offset.
    const embedded = new ubyte[3] ~ map;
    assert(DeltaSetIndexMap.read(embedded, Tag("HVAR"), 0, 3).map(1).value == DeltaSetIndex(3, 4));
}

// ---------------------------------------------------------------------------
// FTM11: Device and VariationIndex tables
// ---------------------------------------------------------------------------

private DeviceDelta pixelDelta(const(ubyte)[] table, Ppem ppem) @safe pure nothrow
{
    const none = ItemVariationStore.init;
    const r = deviceDelta(table, Tag("GPOS"), 0, 0, none, null, upem, ppem);
    assert(r.hasValue);
    assert(r.value.variation == DesignValue(0, upem));
    return r.value;
}

private Ppem px(long n) @safe pure nothrow @nogc => Ppem.fromInteger(n).value;

@("variations.FTM11.deviceFormats")
@safe pure nothrow
unittest
{
    // Format 1: 2-bit values, 8 per word; format 2: 4-bit, 4 per word; format 3: 8-bit, 2 per word.
    static immutable int[] f1 = [1, -2, 0, -1, 1, 1, -2, 0, -1, 1];
    static immutable int[] f2 = [7, -8, 0, -1, 3, 5];
    static immutable int[] f3 = [127, -128, -1, 42, 0];
    foreach (format, values; [f1, f2, f3])
    {
        const table = deviceTable(10, cast(uint)(10 + values.length - 1), cast(uint) format + 1, values);
        foreach (i, v; values)
        {
            const d = pixelDelta(table, px(10 + i));
            assert(d.deviceApplied && d.devicePixels == v);
        }
    }
    // The hand-packed bytes of format 1's first word: 01 10 00 11 01 01 10 00.
    assert(deviceTable(10, 19, 1, f1)[6 .. 8] == [0x63, 0x58]);
}

@("variations.FTM11.deviceNotApplied")
@safe pure nothrow
unittest
{
    const table = deviceTable(12, 14, 3, [5, 6, 7]);
    // Out of range on either side.
    assert(!pixelDelta(table, px(11)).deviceApplied && pixelDelta(table, px(11)).devicePixels == 0);
    assert(!pixelDelta(table, px(15)).deviceApplied);
    // A fractional ppem inside the range (25/2 = 12.5).
    const half = Ppem.fromRational(Rational(I128(U128(25, 0)), U128(2, 0))).value;
    assert(!pixelDelta(table, half).deviceApplied);
    // No ppem: a design or physical query.
    assert(!pixelDelta(table, Ppem.init).deviceApplied);
    // startSize > endSize applies nowhere.
    assert(!pixelDelta(deviceTable(14, 12, 3, [5, 6, 7]), px(13)).deviceApplied);
    // The edges apply.
    assert(pixelDelta(table, px(12)).devicePixels == 5 && pixelDelta(table, px(14)).devicePixels == 7);
}

@("variations.FTM11.variationIndex")
@safe pure nothrow
unittest
{
    static immutable short[1] at = [one / 2];
    const ivs = itemVariationStore(1, twoRegions, [VarData([0, 1], 0, false, [[0, 0], [10, -4]])]);
    const store = storeOf(ivs, 1);
    const table = new ubyte[4] ~ variationIndexTable(0, 1);
    // 10 · 0.5 − 4 · 1, a design delta for every query, with or without a ppem.
    foreach (ppem; [Ppem.init, px(12)])
    {
        const r = deviceDelta(table, Tag("GPOS"), 0, 4, store, at[], upem, ppem).value;
        assert(r.variation == DesignValue.fromUnits(1, upem) && !r.deviceApplied && r.devicePixels == 0);
    }
    // No store to read: badValue at the delta format.
    const none = ItemVariationStore.init;
    const missing = deviceDelta(table, Tag("GPOS"), 50, 4, none, at[], upem).error;
    assert(missing.kind == FontErrorKind.badValue && missing.tableOffset == 8 && missing.offset == 58);
    // At the default, nothing is read (FTM14): zero, with or without a store.
    static immutable short[1] origin = [0];
    assert(deviceDelta(table, Tag("GPOS"), 0, 4, none, origin[], upem).value.variation.raw == 0);
    // The store's own errors come through.
    const dangling = new ubyte[4] ~ variationIndexTable(3, 0);
    assert(deviceDelta(dangling, Tag("GPOS"), 0, 4, store, at[], upem).error.kind == FontErrorKind.badValue);
    assert(deviceDelta(table, Tag("GPOS"), 0, 4, store, at[], upem, px(1)).hasValue);
}

@("variations.FTM11.otherFormatsAndHostile")
@safe pure nothrow
unittest
{
    const none = ItemVariationStore.init;
    foreach (format; [0, 4, 0x7FFF, 0x8001, 0xFFFF])
    {
        const table = u16(1) ~ u16(100) ~ u16(format) ~ u16(0);
        const e = deviceDelta(table, Tag("BASE"), 0, 0, none, null, upem, px(10)).error;
        assert(e.kind == FontErrorKind.unsupportedVersion && e.tableOffset == 4);
    }
    // An empty table holds no Device table, even at offset 0.
    const empty = deviceDelta(null, Tag("BASE"), 0, 0, none, null, upem, px(10)).error;
    assert(empty.kind == FontErrorKind.badOffset && empty.tableOffset == 0);
    const table = deviceTable(10, 30, 3, [1, 2]);
    // A Device table past its containing table, its header cut, its values cut.
    const padded = new ubyte[2] ~ table;
    assert(deviceDelta(padded, Tag("BASE"), 0, padded.length, none, null, upem).error.kind
        == FontErrorKind.badOffset);
    assert(deviceDelta(padded[0 .. 6], Tag("BASE"), 0, 2, none, null, upem).error.kind == FontErrorKind.truncated);
    // Sizes 10–30 at 8 bits need 11 words and only 1 is stored: malformed
    // at every size (FTM12), including those whose value is stored.
    foreach (size; [10, 11, 12, 40])
    {
        const past = deviceDelta(padded, Tag("BASE"), 0, 2, none, null, upem, px(size)).error;
        assert(past.kind == FontErrorKind.truncated && past.tableOffset == 2);
    }
    assert(deviceDelta(padded, Tag("BASE"), 0, 2, none, null, upem).error.kind == FontErrorKind.truncated);
    // A table holding its whole range applies.
    const whole = new ubyte[2] ~ deviceTable(10, 11, 3, [1, 2]);
    assert(deviceDelta(whole, Tag("BASE"), 0, 2, none, null, upem, px(11)).value.devicePixels == 2);
}
