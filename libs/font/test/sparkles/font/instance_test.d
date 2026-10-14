/**
Instances (FTA3, FTV6–FTV11, FTM13, FTM14) on hand-built fixtures, every
normalized value traced by hand through FTV8's integer steps, HarfBuzz's
`SegmentMaps::map_float` rules and `avar::map_coords_16_16`.
*/
module sparkles.font.instance_test;

import std.algorithm.searching : endsWith;
import std.file : dirEntries, SpanMode;
import std.path : baseName;

import sparkles.base.text.layout_units : LayoutUnit;
import sparkles.test_runner.skip : skipTest;

import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.errors : FontErrorKind, FontLimit, Tag;
import sparkles.font.face : Face, openFace;
import sparkles.font.fixtures;
import sparkles.font.instance;
import sparkles.font.tables : avar, fvar, VariationAxis;
import sparkles.font.units : Ppem;

private enum one = 65_536; // 1.0 in F16.16
private enum f2one = 16_384; // 1.0 in F2Dot14

private immutable twelvePoints = InstanceSize.physical(LayoutUnit(12 * LayoutUnit.ticksPerPoint));

/// A face of `fvar` `axes`, with `avar` bytes when given.
private Face variableFace(const(FvarAxis)[] axes, const(ubyte)[] avarBytes = null,
    const(int[])[] instances = null) @safe pure nothrow
{
    auto tables = minimalTables;
    if (avarBytes !is null)
        tables ~= TableData("avar", avarBytes);
    tables ~= TableData("fvar", fvarTable(axes, instances));
    return openFace(sfnt(tables)).value;
}

/// One axis whose user values equal their normalized F16.16 values.
private immutable FvarAxis unit = FvarAxis("TEST", -one, 0, one);

/// `wght` 100..400..900.
private immutable FvarAxis wght = FvarAxis("wght", 100 << 16, 400 << 16, 900 << 16);

/// The F2Dot14 coordinates of `face` at `coordinates`, which must build.
private short[] coordsAt(in Face face, const(UserCoordinate)[] coordinates) @safe pure nothrow
{
    const r = face.instance(twelvePoints, coordinates);
    assert(r.hasValue);
    return r.value.coords.dup;
}

/// `mapCoordinate` with the single segment map `pairs` (F2Dot14) at F16.16 `v`.
private int mapped(const(int[2])[] pairs, int v) @safe pure nothrow
{
    const face = openFace(sfnt(minimalTables ~ [TableData("avar", avarTable([pairs]))])).value;
    return mapCoordinate(face.avar.value.maps.front.value, v);
}

// ---------------------------------------------------------------------------
// FTV8: normalization
// ---------------------------------------------------------------------------

@("instance.FTV8.reviewTrace1")
@safe pure nothrow
unittest
{
    // wght 250 → −0.5 exactly; avar maps −0.5 to −0.7, stored as −11469 F2Dot14
    // (−11468.8 rounded), −45876 in F16.16; (−45876 + 2) >> 2 = −11469.
    const face = variableFace([wght], avarTable([[[-f2one, -f2one], [-8_192, -11_469], [0, 0], [f2one, f2one]]]));
    assert(coordsAt(face, [UserCoordinate(Tag("wght"), 250 << 16)]) == [-11_469]);
}

@("instance.FTV8.minDefaultMax")
@safe pure nothrow
unittest
{
    const face = variableFace([wght]);
    assert(coordsAt(face, [UserCoordinate(Tag("wght"), 100 << 16)]) == [-f2one]);
    assert(coordsAt(face, [UserCoordinate(Tag("wght"), 400 << 16)]) == [0]);
    assert(coordsAt(face, null) == [0]);
    assert(coordsAt(face, [UserCoordinate(Tag("wght"), 900 << 16)]) == [f2one]);
    // Clamped to [min, max] first.
    assert(coordsAt(face, [UserCoordinate(Tag("wght"), 1 << 16)]) == [-f2one]);
    assert(coordsAt(face, [UserCoordinate(Tag("wght"), 1_000 << 16)]) == [f2one]);
    // 650 → 0.5.
    assert(coordsAt(face, [UserCoordinate(Tag("wght"), 650 << 16)]) == [8_192]);
}

@("instance.FTV8.defaultEqualsMinimum")
@safe pure nothrow
unittest
{
    // Below the default clamps to it, so the zero divisor (def − min) is never reached.
    const face = variableFace([FvarAxis("wdth", 100 << 16, 100 << 16, 200 << 16)]);
    assert(coordsAt(face, [UserCoordinate(Tag("wdth"), 50 << 16)]) == [0]);
    assert(coordsAt(face, [UserCoordinate(Tag("wdth"), 150 << 16)]) == [8_192]);
}

@("instance.FTV8.roundings")
@safe pure nothrow
unittest
{
    // Step 2: 1 / 2.0 = 0.5 raw rounds away from zero to ±1.
    const two = VariationAxis(Tag("TEST"), -2 * one, 0, 2 * one);
    assert(normalizeAxisValue(two, 1) == 1 && normalizeAxisValue(two, -1) == -1);
    // Step 4: (x + 2) >> 2 rounds ties toward +∞: 2 → 1, −2 → 0, 6 → 2.
    const face = variableFace([unit]);
    assert(coordsAt(face, [UserCoordinate(Tag("TEST"), 2)]) == [1]);
    assert(coordsAt(face, [UserCoordinate(Tag("TEST"), -2)]) == [0]);
    assert(coordsAt(face, [UserCoordinate(Tag("TEST"), -6)]) == [-1]);
}

// ---------------------------------------------------------------------------
// FTV9: avar version 1
// ---------------------------------------------------------------------------

@("instance.FTV9.noPairsAndOnePair")
@safe pure nothrow
unittest
{
    assert(mapped([], 12_345) == 12_345);
    assert(mapped([[0, 4_096]], 8_192) == 8_192 + 16_384);
}

@("instance.FTV9.exactMatches")
@safe pure nothrow
unittest
{
    enum m1 = -f2one, p1 = f2one;
    // Exactly one match: its `to`.
    assert(mapped([[m1, m1], [0, 0], [8_192, 4_096], [p1, p1]], 32_768) == 4 * 4_096);
    // Exactly three: the middle one.
    assert(mapped([[m1, m1], [8_192, 1_000], [8_192, 2_000], [8_192, 3_000], [p1, p1]], 32_768) == 4 * 2_000);
    // Two (an even count) below zero: the last; above zero: the first.
    assert(mapped([[m1, m1], [-8_192, -1_000], [-8_192, -2_000], [0, 0], [p1, p1]], -32_768) == 4 * -2_000);
    assert(mapped([[m1, m1], [0, 0], [8_192, 1_000], [8_192, 2_000], [p1, p1]], 32_768) == 4 * 1_000);
    // Four: still the last below zero and the first above.
    assert(mapped([[m1, m1], [-8_192, -1], [-8_192, -2], [-8_192, -3], [-8_192, -4], [0, 0]], -32_768) == 4 * -4);
    assert(mapped([[0, 0], [8_192, 1], [8_192, 2], [8_192, 3], [8_192, 4], [p1, p1]], 32_768) == 4 * 1);
    // At zero: of the first and last match, the smaller |to|, the last on a tie.
    assert(mapped([[m1, m1], [0, 1_000], [0, -500], [p1, p1]], 0) == 4 * -500);
    assert(mapped([[m1, m1], [0, -500], [0, 1_000], [p1, p1]], 0) == 4 * -500);
    assert(mapped([[m1, m1], [0, 500], [0, -500], [p1, p1]], 0) == 4 * -500);
    assert(mapped([[m1, m1], [0, -500], [0, 500], [p1, p1]], 0) == 4 * 500);
}

@("instance.FTV9.endCapTrim")
@safe pure nothrow
unittest
{
    enum m1 = -f2one, p1 = f2one;
    // (−1, −1) is dropped because the next `from` is also −1: two matches remain, v < 0 → the last.
    assert(mapped([[m1, m1], [m1, -12_000], [m1, -8_000], [0, 0], [p1, p1]], -one) == 4 * -8_000);
    // Without the cap, three matches would give the middle one.
    assert(mapped([[m1, -16_000], [m1, -12_000], [m1, -8_000], [0, 0], [p1, p1]], -one) == 4 * -12_000);
    // The trailing (+1, +1) likewise: v > 0 → the first of the two left.
    assert(mapped([[m1, m1], [0, 0], [p1, 8_000], [p1, 12_000], [p1, p1]], one) == 4 * 8_000);
}

@("instance.FTV9.outsideShifts")
@safe pure nothrow
unittest
{
    const int[2][] pairs = [[-8_192, -4_096], [0, 0], [8_192, 4_096]];
    assert(mapped(pairs, -one) == -one + 32_768 - 16_384);
    assert(mapped(pairs, one) == one - 32_768 + 16_384);
}

@("instance.FTV9.interpolationRoundsTheQuotient")
@safe pure nothrow
unittest
{
    // −4 + 4 · 57,344 / 65,536 = −4 + 3.5: the quotient rounds away to 4, giving 0
    // (rounding the whole −0.5 would give −1).
    assert(mapped([[-f2one, -1], [0, 0]], -8_192) == 0);
    assert(mapped([[0, 0], [f2one, 1]], 8_192) == 1); // 0.5 → 1
    assert(mapped([[0, 0], [f2one, -1]], 8_192) == -1); // −0.5 → −1
    // A plain interpolation: halfway between (0, 0) and (1, 0.5).
    assert(mapped([[-f2one, -f2one], [0, 0], [f2one, 8_192]], 32_768) == 16_384);
}

@("instance.FTV9.decreasingMapLeavesItsAxisUnmapped")
@safe pure nothrow
unittest
{
    // Axis 0's map decreases; axis 1's halves positive values.
    const face = variableFace([unit, FvarAxis("TST2", -one, 0, one)],
        avarTable([[[0, 0], [-f2one, -f2one]], [[-f2one, -f2one], [0, 0], [f2one, 8_192]]]));
    const inst = face.instance(twelvePoints, [UserCoordinate(Tag("TEST"), one / 2),
        UserCoordinate(Tag("TST2"), one / 2)]).value;
    assert(inst.coords == [8_192, 4_096]);
    assert(inst.avarApplied && inst.recordedErrors == 1);
    assert(inst.firstRecordedError.kind == FontErrorKind.badValue && inst.firstRecordedError.tag == Tag("avar"));
}

@("instance.FTV9.axisCountMismatch")
@safe pure nothrow
unittest
{
    // avar has two maps, fvar one axis: avar is left out, as FreeType does.
    int[2][][] maps = [[[0, 0], [f2one, 8_192]]];
    maps ~= null;
    const face = variableFace([unit], avarTable(maps));
    const inst = face.instance(twelvePoints, [UserCoordinate(Tag("TEST"), one)]).value;
    assert(inst.coords == [f2one] && !inst.avarApplied && inst.recordedErrors == 1);
    assert(inst.firstRecordedError.kind == FontErrorKind.badValue && inst.firstRecordedError.tag == Tag("avar"));
    assert(inst.firstRecordedError.tableOffset == 6);
}

@("instance.FTV9.unreadableAvar")
@safe pure nothrow
unittest
{
    // A map whose pairs run past the table: avar is unreadable, so not applied.
    auto bytes = avarTable([[[0, 0], [f2one, 8_192]]]);
    const face = variableFace([unit], bytes[0 .. $ - 2]);
    const inst = face.instance(twelvePoints, [UserCoordinate(Tag("TEST"), one)]).value;
    assert(inst.coords == [f2one] && !inst.avarApplied);
    assert(inst.firstRecordedError.kind == FontErrorKind.truncated);
}

// ---------------------------------------------------------------------------
// FTV10: avar version 2
// ---------------------------------------------------------------------------

/// A one-axis avar 2 whose store has one region `region` and items of `deltas`.
private ubyte[] avar2(const(int[2])[] map, RegionAxis region, const(int)[] deltas,
    const(ubyte)[] indexMap = null, bool longWords = false) @safe pure nothrow
{
    const(int[])[] rows;
    foreach (d; deltas) rows ~= [d];
    return avarTable([map], true, indexMap,
        itemVariationStore(1, [[region]], [VarData([0], 1, longWords, rows)]));
}

@("instance.FTV10.vectorRoundsTiesAway")
@safe pure nothrow
unittest
{
    // x = 2 (F16.16): the vector is round(0.5) = 1, not 0, so the store is read;
    // at its peak the delta is 2, 4δ = 8, x = 10, and (10 + 2) >> 2 = 3.
    const face = variableFace([unit], avar2([], [0, 1, f2one], [2]));
    assert(coordsAt(face, [UserCoordinate(Tag("TEST"), 2)]) == [3]);
}

@("instance.FTV10.deltaRoundsTiesAway")
@safe pure nothrow
unittest
{
    // x = 8193: vector 2048; scalar 2048 / 16384 = 0.125, so δ = 0.125 F2Dot14
    // units and 4δ = 0.5 rounds to 1: x = 8194, (8196) >> 2 = 2049.
    const face = variableFace([unit], avar2([], [0, f2one, f2one], [1]));
    assert(coordsAt(face, [UserCoordinate(Tag("TEST"), 8_193)]) == [2_049]);
}

@("instance.FTV10.reviewExample")
@safe pure nothrow
unittest
{
    // The review's example: x = 1 (F16.16) and δ = 0.4. Axis 0 at 0.5 makes the
    // shared vector nonzero (8192, 0); the region peaks at 1.25 on axis 0, so the
    // scalar is 0.4 (26,214) and axis 1's item, delta 1, gives δ = 0.4. 4δ = 1.6
    // rounds to 2 and is added to the unrounded x: 3, and (3 + 2) >> 2 = 1.
    // Rounding δ to F2Dot14 first would add nothing and give 0.
    const int[2][][] maps = [[], []];
    const store = itemVariationStore(2, [[[0, 20_480, 20_480], [0, 0, 0]]],
        [VarData([0], 1, false, [[0], [1]])]);
    const face = variableFace([unit, FvarAxis("TST2", -one, 0, one)],
        avarTable(maps, true, deltaSetIndexMap([[0, 0], [0, 1]], 1, 1), store));
    assert(coordsAt(face, [UserCoordinate(Tag("TEST"), one / 2), UserCoordinate(Tag("TST2"), 1)])
        == [8_192, 1]);
}

@("instance.FTV10.deltaClamp")
@safe pure nothrow
unittest
{
    // A one-pair map shifts −1 to −1.5; the store at its peak gives δ = 49,152,
    // 4δ = 196,608, clamped to 131,072: −98,304 + 131,072 = 32,768 → 8,192.
    // Unclamped it would reach 1.5 and the final clamp 16,384.
    const face = variableFace([unit], avar2([[0, -8_192]], [-32_768, -24_576, 0], [49_152], null, true));
    assert(coordsAt(face, [UserCoordinate(Tag("TEST"), -one)]) == [8_192]);
}

@("instance.FTV10.finalClamp")
@safe pure nothrow
unittest
{
    // x = 1, δ = 100: 65,536 + 400 clamps to 65,536 → 16,384; and symmetrically.
    const face = variableFace([unit], avar2([], [0, f2one, f2one], [100]));
    assert(coordsAt(face, [UserCoordinate(Tag("TEST"), one)]) == [f2one]);
    const below = variableFace([unit], avar2([], [-f2one, -f2one, 0], [-100]));
    assert(coordsAt(below, [UserCoordinate(Tag("TEST"), -one)]) == [-f2one]);
}

@("instance.FTV10.axisIndexMap")
@safe pure nothrow
unittest
{
    // At x = 0.5 the region peaks: item 0 has delta 0, item 1 delta 8 (4δ = 32).
    const half = UserCoordinate(Tag("TEST"), one / 2);
    // Without a map, axis 0 takes item (0, 0): nothing changes.
    assert(coordsAt(variableFace([unit], avar2([], [0, 8_192, f2one], [0, 8])), [half]) == [8_192]);
    // A map sending axis 0 to (0, 1): +32 F16.16, +8 F2Dot14.
    const indexMap = deltaSetIndexMap([[0, 1]], 1, 1);
    assert(coordsAt(variableFace([unit], avar2([], [0, 8_192, f2one], [0, 8], indexMap)), [half]) == [8_200]);
}

@("instance.FTV10.withoutStoreStillClamps")
@safe pure nothrow
unittest
{
    // The map shifts 1 to 1.5. Version 1 keeps it (24,576); version 2 without a
    // store adds nothing but clamps to 1, as HarfBuzz does.
    const v1 = variableFace([unit], avarTable([[[0, 8_192]]]));
    assert(coordsAt(v1, [UserCoordinate(Tag("TEST"), one)]) == [24_576]);
    const v2 = variableFace([unit], avarTable([[[0, 8_192]]], true));
    assert(coordsAt(v2, [UserCoordinate(Tag("TEST"), one)]) == [f2one]);
}

@("instance.FTV10.brokenStoreLeavesAvarOut")
@safe pure nothrow
unittest
{
    // A store whose region list has two axes against fvar's one: avar is not
    // applied, its map included, and the store's badValue is recorded.
    auto store = itemVariationStore(2, [[[0, f2one, f2one], [0, 0, 0]]], [VarData([0], 1, false, [[8]])]);
    const face = variableFace([unit], avarTable([[[0, 0], [f2one, 8_192]]], true, null, store));
    const inst = face.instance(twelvePoints, [UserCoordinate(Tag("TEST"), one)]).value;
    assert(inst.coords == [f2one] && !inst.avarApplied && inst.recordedErrors == 1);
    assert(inst.firstRecordedError.kind == FontErrorKind.badValue);
    // At the default nothing reads the store (FTM14).
    const origin = face.instance(twelvePoints, null).value;
    assert(origin.allZero && origin.avarApplied && origin.recordedErrors == 0);
}

@("instance.FTV10.view")
@safe pure nothrow
unittest
{
    // The version-2 offsets are read after the maps; a table cut before them is truncated.
    auto bytes = avarTable([[[0, 0]]], true, deltaSetIndexMap([[0, 0]], 1, 1),
        itemVariationStore(1, [[[0, f2one, f2one]]], [VarData([0], 1, false, [[1]])]));
    const face = openFace(sfnt(minimalTables ~ [TableData("avar", bytes)])).value;
    const a = face.avar.value;
    assert(a.majorVersion == 2 && a.axisIndexMapOffset == 22 && a.varStoreOffset == 27);
    const cut = openFace(sfnt(minimalTables ~ [TableData("avar", bytes[0 .. 14])])).value;
    assert(cut.avar.error.kind == FontErrorKind.truncated);
    auto v3 = bytes.dup;
    v3[1] = 3;
    assert(openFace(sfnt(minimalTables ~ [TableData("avar", v3)])).value.avar.error.kind
        == FontErrorKind.unsupportedVersion);
}

// ---------------------------------------------------------------------------
// FTV7: building an instance
// ---------------------------------------------------------------------------

@("instance.FTV7.duplicateTagLastWins")
@safe pure nothrow
unittest
{
    const face = variableFace([wght]);
    const inst = face.instance(twelvePoints, [UserCoordinate(Tag("wght"), 900 << 16),
        UserCoordinate(Tag("wght"), 650 << 16)]).value;
    assert(inst.coords == [8_192] && inst.userValue(0) == 650 << 16 && inst.ignoredCoordinates == 0);
}

@("instance.FTV7.sharedTagSetsEveryAxis")
@safe pure nothrow
unittest
{
    const face = variableFace([wght, FvarAxis("wdth", 50 << 16, 100 << 16, 200 << 16), wght]);
    const inst = face.instance(twelvePoints, [UserCoordinate(Tag("wght"), 650 << 16)]).value;
    assert(inst.coords == [8_192, 0, 8_192]);
    assert(inst.userValue(0) == 650 << 16 && inst.userValue(1) == 100 << 16 && inst.userValue(2) == 650 << 16);
}

@("instance.FTV7.unknownTagsCounted")
@safe pure nothrow
unittest
{
    const face = variableFace([wght]);
    const inst = face.instance(twelvePoints, [UserCoordinate(Tag("ital"), one),
        UserCoordinate(Tag("wght"), 900 << 16), UserCoordinate(Tag("opsz"), 12 << 16)]).value;
    assert(inst.coords == [f2one] && inst.ignoredCoordinates == 2 && inst.recordedErrors == 0);
}

@("instance.FTV7.badValueAxes")
@safe pure nothrow
unittest
{
    // wdth's default lies above its maximum.
    const face = variableFace([wght, FvarAxis("wdth", 50 << 16, 300 << 16, 200 << 16)]);
    const given = face.instance(twelvePoints, [UserCoordinate(Tag("wdth"), 100 << 16)]);
    assert(given.error.kind == FontErrorKind.badValue && given.error.tag == Tag("fvar"));
    const unspecified = face.instance(twelvePoints, [UserCoordinate(Tag("wght"), 900 << 16)]).value;
    assert(unspecified.coords == [f2one, 0] && unspecified.userValue(1) == 300 << 16);
    assert(unspecified.recordedErrors == 1 && unspecified.firstRecordedError.kind == FontErrorKind.badValue);
}

@("instance.FTV7.axisLimit")
@safe pure nothrow
unittest
{
    FvarAxis[] axes;
    foreach (i; 0 .. 65)
        axes ~= FvarAxis("ax00", -one, 0, one);
    const sixtyFour = variableFace(axes[0 .. 64]).instance(twelvePoints, [UserCoordinate(Tag("ax00"), one)]);
    assert(sixtyFour.hasValue && sixtyFour.value.axisCount == 64 && sixtyFour.value.coords[63] == f2one);
    const sixtyFive = variableFace(axes).instance(twelvePoints, null);
    assert(sixtyFive.error.kind == FontErrorKind.limitExceeded);
    assert(sixtyFive.error.limit == FontLimit.variationAxes && sixtyFive.error.limitValue == 64);
}

@("instance.FTV7.sizes")
@safe pure nothrow
unittest
{
    const face = variableFace([wght]);
    assert(face.instance(InstanceSize.physical(LayoutUnit(0)), null).error.kind == FontErrorKind.badValue);
    assert(face.instance(InstanceSize.physical(LayoutUnit(-1)), null).error.kind == FontErrorKind.badValue);
    assert(face.instance(InstanceSize.pixels(Ppem.init), null).error.kind == FontErrorKind.badValue);
    assert(face.instance(InstanceSize.init, null).error.kind == FontErrorKind.badValue);
    const px = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
    assert(px.size.unit == InstanceSize.Unit.pixels && px.size.ppem.numerator == 16);
}

@("instance.FTV7.withoutFvar")
@safe pure nothrow
unittest
{
    const face = openFace(sfnt(minimalTables)).value;
    const inst = face.instance(twelvePoints, [UserCoordinate(Tag("wght"), 700 << 16),
        UserCoordinate(Tag("wdth"), 75 << 16)]).value;
    assert(inst.axisCount == 0 && inst.coords.length == 0 && inst.allZero);
    assert(inst.ignoredCoordinates == 2 && inst.recordedErrors == 0);
    assert(face.axes.empty && !face.axes.hasError && face.namedInstances.empty);
}

@("instance.FTV7.unreadableFvar")
@safe pure nothrow
unittest
{
    auto bytes = fvarTable([wght]);
    bytes[1] = 2; // major version 2
    const face = openFace(sfnt(minimalTables ~ [TableData("fvar", bytes)])).value;
    assert(face.instance(twelvePoints, null).error.kind == FontErrorKind.unsupportedVersion);
    assert(face.axes.empty && face.axes.hasError && face.axes.error.kind == FontErrorKind.unsupportedVersion);
    assert(face.namedInstances.hasError && face.namedInstances.error.tag == Tag("fvar"));
}

// ---------------------------------------------------------------------------
// FTA3, FTV6, FTV11, FTM14
// ---------------------------------------------------------------------------

@("instance.FTA3.copyableValue")
@safe pure nothrow
unittest
{
    const face = variableFace([wght]);
    const synthesis = Synthesis(one / 2, 12 << 16);
    const a = face.instance(twelvePoints, [UserCoordinate(Tag("wght"), 650 << 16)], synthesis).value;
    Instance b = a; // a copy shares nothing mutable
    assert(b.coords == a.coords && b.coords.ptr !is a.coords.ptr);
    assert(b.synthesis == synthesis && b.unitsPerEm == 2_048 && b.face.bytes is face.bytes);
    assert(b.size.em == LayoutUnit(12 * LayoutUnit.ticksPerPoint));
    assert(face.instance(twelvePoints, null).value.synthesis == Synthesis.init);
}

@("instance.FTM14.defaultIsAllZero")
@safe pure nothrow
unittest
{
    const face = variableFace([wght, unit]);
    assert(face.instance(twelvePoints, null).value.allZero);
    assert(!face.instance(twelvePoints, [UserCoordinate(Tag("TEST"), 4)]).value.allZero);
}

@("instance.FTV6.ranges")
@safe pure nothrow
unittest
{
    const face = variableFace([wght, FvarAxis("wdth", 50 << 16, 300 << 16, 200 << 16)], null,
        [[700 << 16, 100 << 16], [400 << 16, 50 << 16]]);
    auto axes = face.axes;
    assert(axes.length == 2 && axes[0].value.axisTag == Tag("wght"));
    assert(axes[1].error.kind == FontErrorKind.badValue && axes.back.hasError);
    auto rest = axes.save;
    rest.popFront();
    assert(rest.length == 1 && axes.length == 2 && rest.front.hasError);
    auto named = face.namedInstances;
    assert(named.length == 2 && named[$ - 1].coordinate(1) == 50 << 16);
    assert(named.front.subfamilyNameID == 258 && named.front.coordinate(0) == 700 << 16);
    named.popBack();
    assert(named.back.subfamilyNameID == 258);
}

// ---------------------------------------------------------------------------
// Corpus
// ---------------------------------------------------------------------------

@("instance.corpus.minDefaultMax")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    size_t variable;
    foreach (entry; dirEntries(fontsPath, SpanMode.shallow))
    {
        if (!entry.name.endsWith(".ttf") && !entry.name.endsWith(".otf"))
            continue;
        const bytes = bundled(baseName(entry.name));
        const opened = openFace(bytes);
        if (!opened.hasValue || !opened.value.fvar.hasValue)
            continue;
        const face = opened.value;
        const withAvar = face.avar.hasValue;
        ++variable;
        foreach (i; 0 .. face.axes.length)
        {
            const axis = face.axes[i];
            assert(axis.hasValue, entry.name);
            const a = axis.value;
            foreach (value; [a.minValue, a.defaultValue, a.maxValue])
            {
                const inst = face.instance(twelvePoints, [UserCoordinate(a.axisTag, value)]);
                assert(inst.hasValue, entry.name);
                assert(inst.value.recordedErrors == 0, entry.name);
                assert(inst.value.avarApplied == withAvar, entry.name);
                if (withAvar)
                    continue;
                // Without avar the extremes are exactly ±1 and the default 0.
                const expected = value == a.defaultValue ? 0 : value == a.minValue ? -f2one : f2one;
                assert(inst.value.coords[i] == expected, entry.name);
            }
        }
    }
    assert(variable > 0, "no variable face in the corpus");
}
