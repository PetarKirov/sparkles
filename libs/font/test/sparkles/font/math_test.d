/**
Math data (FTP34–FTP38, FTM11, FTM14) on hand-built `MATH` and `GDEF`
tables, hostile truncations and corruptions of them, and every bundled face.

Fixtures use 1,000 units per em and one `TEST` axis whose user values equal
their normalized values; `GDEF`'s store has one region peaking at 1.0, so at
1.0 item `i` has its row's delta and at 0.5 half of it.
*/
module sparkles.font.math_test;

import std.algorithm.searching : endsWith;
import std.file : dirEntries, SpanMode;
import std.path : baseName;

import sparkles.base.text.layout_units : I128, LayoutUnit, Rational, U128;
import sparkles.test_runner.skip : skipTest;

import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.errors : FontErrorKind, FontLimit, Tag;
import sparkles.font.face : openFace;
import sparkles.font.fixtures;
import sparkles.font.instance : Instance, instance, InstanceSize, UserCoordinate;
import sparkles.font.math_table;
import sparkles.font.units : DesignValue, Ppem;

private enum one = 65_536; // 1.0 in F16.16
private enum short f2one = 16_384; // 1.0 in F2Dot14
private enum ushort upem = 1_000;

private immutable twelvePoints = InstanceSize.physical(LayoutUnit(12 * LayoutUnit.ticksPerPoint));

private enum vertical = MathDirection.vertical, horizontal = MathDirection.horizontal;
private enum topRight = MathKernCorner.topRight, topLeft = MathKernCorner.topLeft,
    bottomLeft = MathKernCorner.bottomLeft;

/// One axis, one region peaking at 1.0, one data subtable whose item `i` has delta `deltas[i]`.
private ubyte[] store(const(int)[] deltas) @safe pure nothrow
{
    int[][] rows;
    foreach (d; deltas)
        rows ~= [d];
    return itemVariationStore(1, [[[0, f2one, f2one]]], [VarData([0], 1, false, rows)]);
}

/// A face holding `math` and `gdef` (each when not null) and, when `variable`, the `TEST` axis.
private ubyte[] build(const(ubyte)[] math, const(ubyte)[] gdef = null, bool variable = true) @safe pure nothrow
{
    auto tables = minimalTables(100);
    tables[1] = TableData("head", head(upem));
    if (gdef !is null)
        tables ~= TableData("GDEF", gdef);
    if (math !is null)
        tables ~= TableData("MATH", math);
    if (variable)
        tables ~= TableData("fvar", fvarTable([FvarAxis("TEST", -one, 0, one)]));
    return sfnt(tables);
}

/// The instance of `bytes` at `TEST` = `coord` (F16.16), sized `size`.
private Instance at(const(ubyte)[] bytes, int coord = 0, InstanceSize size = twelvePoints) @safe pure nothrow
{
    const face = openFace(bytes).value;
    auto r = face.instance(size, [UserCoordinate(Tag("TEST"), coord)]);
    assert(r.hasValue);
    return r.value;
}

private InstanceSize px(long ppem) @safe pure nothrow @nogc => InstanceSize.pixels(Ppem.fromInteger(ppem).value);

private DesignValue du(long units) @safe pure nothrow @nogc => DesignValue(units * 65_536, upem);

private MathValueSpec v(int value, const(ubyte)[] device = null) @safe pure nothrow @nogc
    => MathValueSpec(value, device);

// ---------------------------------------------------------------------------
// Structure (FTP34)
// ---------------------------------------------------------------------------

/// Every query on `inst`; each must fail with `kind`.
private void allFail(in Instance inst, FontErrorKind kind) @safe pure nothrow
{
    GlyphPart[4] parts;
    assert(inst.face.mathTable.error.kind == kind);
    assert(inst.mathConstants.error.kind == kind);
    assert(inst.italicsCorrection(5).error.kind == kind);
    assert(inst.topAccentAttachment(5).error.kind == kind);
    assert(inst.isExtendedShape(5).error.kind == kind);
    assert(inst.mathKernTable(5, topRight).error.kind == kind);
    assert(inst.mathKern(5, topRight, du(0)).error.kind == kind);
    assert(inst.mathVariants(5, vertical).error.kind == kind);
    assert(inst.mathAssemblyLength(5, vertical).error.kind == kind);
    assert(inst.mathAssembly(5, vertical, parts[]).error.kind == kind);
}

@("math.FTP34.missingTable")
@safe pure nothrow
unittest
{
    allFail(at(build(null)), FontErrorKind.missingTable);
    allFail(at(build(null, gdefTable(store([5]))), one), FontErrorKind.missingTable);
}

@("math.FTP34.versions")
@safe pure nothrow
unittest
{
    allFail(at(build(mathTableData(null, null, null, 2))), FontErrorKind.unsupportedVersion);
    allFail(at(build(mathTableData(null, null, null, 0))), FontErrorKind.unsupportedVersion);
    // A later minor is read as 1.0.
    const later = at(build(mathTableData(null, null, null, 1, 7))).face.mathTable.value;
    assert(later.majorVersion == 1 && later.minorVersion == 7);
    allFail(at(build(mathTableData(null, null, null)[0 .. 9])), FontErrorKind.truncated);
}

@("math.FTP34.emptyTable")
@safe pure nothrow
unittest
{
    // No subtables: every query is absent.
    const inst = at(build(mathTableData(null, null, null)));
    GlyphPart[1] parts;
    const constants = inst.mathConstants.value;
    assert(!constants.present && !constants[MathConstant.axisHeight].value.present);
    assert(!inst.italicsCorrection(5).value.present && !inst.topAccentAttachment(5).value.present);
    assert(!inst.isExtendedShape(5).value);
    assert(!inst.mathKernTable(5, topRight).value.present && !inst.mathKern(5, topRight, du(0)).value.present);
    const variants = inst.mathVariants(5, vertical).value;
    assert(!variants.variantsPresent && variants.empty);
    assert(!inst.mathAssemblyLength(5, vertical).value.present);
    assert(!inst.mathAssembly(5, vertical, parts[]).value.present);
}

// ---------------------------------------------------------------------------
// Constants (FTP35)
// ---------------------------------------------------------------------------

/// Constants with distinct values: record `i` holds `100 + i`.
private MathConstantsSpec constantsSpec() @safe pure nothrow @nogc
{
    MathConstantsSpec c;
    c.percentScaleDown = [-5, 60];
    c.minHeight = [1_500, 65_000];
    foreach (i, ref r; c.records)
        r = v(cast(int)(100 + i));
    c.radicalDegreeBottomRaisePercent = -30;
    return c;
}

@("math.FTP35.kinds")
@safe pure nothrow
unittest
{
    const inst = at(build(mathTableData(mathConstantsTable(constantsSpec()), null, null)));
    const constants = inst.mathConstants.value;
    assert(constants.present);
    // Percentages are signed integers, never scaled.
    const percent = constants[MathConstant.scriptPercentScaleDown].value;
    assert(percent.present && percent.kind == MathValueKind.percentage && percent.percentage == -5);
    assert(percent.pixels.error.kind == FontErrorKind.unsupportedCapability);
    assert(constants[MathConstant.scriptScriptPercentScaleDown].value.percentage == 60);
    assert(constants[MathConstant.radicalDegreeBottomRaisePercent].value.percentage == -30);
    // The minimum heights are unsigned design values with no device.
    const minHeight = constants[MathConstant.delimitedSubFormulaMinHeight].value;
    assert(minHeight.kind == MathValueKind.length && minHeight.value.design == du(1_500) && !minHeight.hasDevice);
    assert(constants[MathConstant.displayOperatorMinHeight].value.value.design == du(65_000));
    // The 51 records, in table order.
    foreach (c; MathConstant.mathLeading .. MathConstant.radicalDegreeBottomRaisePercent)
    {
        const r = constants[c].value;
        assert(r.present && r.kind == MathValueKind.record && !r.hasDevice);
        assert(r.value.design == du(100 + c - MathConstant.mathLeading));
        assert(r.value.physical.hasValue);
    }
    assert(constants[MathConstant.radicalKernAfterDegree].value.value.design == du(150));
}

@("math.FTP35.variationIndex")
@safe pure nothrow
unittest
{
    auto spec = constantsSpec();
    spec.records[MathConstant.axisHeight - MathConstant.mathLeading] = v(250, variationIndexTable(0, 1));
    const math = mathTableData(mathConstantsTable(spec), null, null);
    const withStore = build(math, gdefTable(store([7, 40])));
    // GDEF's store, at the instance.
    const full = at(withStore, one).mathConstants.value[MathConstant.axisHeight].value;
    assert(full.value.design == du(290) && full.hasDevice && full.device.variation == du(40));
    assert(!full.device.deviceApplied);
    assert(at(withStore, one / 2).mathConstants.value[MathConstant.axisHeight].value.value.design == du(270));
    // At the default no store is read (FTM14), not even a broken one.
    assert(at(withStore).mathConstants.value[MathConstant.axisHeight].value.value.design == du(250));
    const brokenGdef = build(math, gdefTable(store([7, 40]), 3, 2));
    assert(at(brokenGdef).mathConstants.value[MathConstant.axisHeight].value.value.design == du(250));
    assert(at(brokenGdef, one).mathConstants.value[MathConstant.axisHeight].error.kind
        == FontErrorKind.unsupportedVersion);
    // No store to read: badValue for that value only (FTM11).
    foreach (gdef; [null, gdefTable(null), gdefTable(null, 2)])
    {
        const constants = at(build(math, gdef), one).mathConstants.value;
        assert(constants[MathConstant.axisHeight].error.kind == FontErrorKind.badValue);
        assert(constants[MathConstant.mathLeading].value.value.design == du(100));
        assert(at(build(math, gdef)).mathConstants.value[MathConstant.axisHeight].value.value.design == du(250));
    }
}

@("math.FTP35.device")
@safe pure nothrow
unittest
{
    auto spec = constantsSpec();
    // Sizes 10–12, format 2: +1 at 10, -2 at 11, +3 at 12.
    spec.records[0] = v(500, deviceTable(10, 12, 2, [1, -2, 3]));
    const bytes = build(mathTableData(mathConstantsTable(spec), null, null), null, false);
    const at11 = at(bytes, 0, px(11)).mathConstants.value[MathConstant.mathLeading].value;
    assert(at11.value.design == du(500) && at11.hasDevice && at11.device.deviceApplied);
    assert(at11.device.devicePixels == -2 && at11.pixels.value == 5.5 - 2);
    const at13 = at(bytes, 0, px(13)).mathConstants.value[MathConstant.mathLeading].value;
    assert(!at13.device.deviceApplied && at13.pixels.value == 6.5);
    // A fractional ppem and a physical size never apply a Device table.
    const half = InstanceSize.pixels(Ppem.fromRational(Rational(I128(U128(23, 0)), U128(2, 0))).value);
    assert(!at(bytes, 0, half).mathConstants.value[MathConstant.mathLeading].value.device.deviceApplied);
    const physical = at(bytes).mathConstants.value[MathConstant.mathLeading].value;
    assert(!physical.device.deviceApplied && physical.value.design == du(500));
}

@("math.FTP35.deltaFormats")
@safe pure nothrow
unittest
{
    auto spec = constantsSpec();
    spec.records[1] = v(1, u16(0) ~ u16(0) ~ u16(0x7FFF));
    auto bytes = mathConstantsTable(spec);
    // A device offset past the table.
    bytes[8 + 4 * 2 + 2] = 0xFF;
    bytes[8 + 4 * 2 + 3] = 0xF0;
    const constants = at(build(mathTableData(bytes, null, null))).mathConstants.value;
    assert(constants[MathConstant.axisHeight].error.kind == FontErrorKind.unsupportedVersion);
    assert(constants[MathConstant.accentBaseHeight].error.kind == FontErrorKind.badOffset);
    assert(constants[MathConstant.mathLeading].value.value.design == du(100));
    assert(constants[MathConstant.flattenedAccentBaseHeight].value.value.design == du(103));
}

@("math.FTP35.truncated")
@safe pure nothrow
unittest
{
    // MathConstants is the last subtable: cut it at 100 bytes.
    const full = mathTableData(mathConstantsTable(constantsSpec()), null, null);
    const constants = at(build(full[0 .. 10 + 100])).mathConstants.value;
    foreach (c; MathConstant.min .. MathConstant.max + 1)
    {
        const end = c < MathConstant.mathLeading ? 2 * c + 2
            : c == MathConstant.radicalDegreeBottomRaisePercent ? 214 : 8 + 4 * (c - MathConstant.mathLeading) + 4;
        const r = constants[cast(MathConstant) c];
        if (end <= 100)
            assert(r.hasValue && r.value.present);
        else
            assert(r.error.kind == FontErrorKind.truncated);
    }
    // An offset past the table.
    auto bad = full.dup;
    bad[4] = 0xFF;
    assert(at(build(bad)).mathConstants.error.kind == FontErrorKind.badOffset);
}

// ---------------------------------------------------------------------------
// Glyph information (FTP36)
// ---------------------------------------------------------------------------

/// Kerns of glyph 5: top right heights 100, 200, 300 with values 1–4; top left null.
private MathKernSpec[4] kernsOf5() @safe pure nothrow
{
    MathKernSpec[4] k;
    k[0] = MathKernSpec(true, [v(100), v(200), v(300)], [v(1), v(2), v(3), v(4)]);
    k[2] = MathKernSpec(true, null, [v(-9)]);
    k[3] = MathKernSpec(true, [v(300), v(100), v(200)], [v(1), v(2), v(3), v(4)]); // unsorted
    return k;
}

/// MathGlyphInfo: italics of 5 (100) and 7 (0); top accents of 5 (250); extended shape 9; kerns of 5 and 7.
private ubyte[] glyphInfo(uint italicsCount = uint.max, uint kernCount = uint.max) @safe pure nothrow
{
    MathKernSpec[4] kernsOf7;
    kernsOf7[0] = MathKernSpec(true, [v(0)], [v(10), v(20)]);
    return mathGlyphInfoTable(MathGlyphInfoSpec(
        mathValueTable(MathValueTableSpec(coverage1([5, 7]), [v(100), v(0)], italicsCount)),
        mathValueTable(MathValueTableSpec(coverage2([[5, 5, 0]]), [v(250)])),
        coverage1([9]),
        mathKernInfoTable(MathKernInfoSpec(coverage1([5, 7]), [kernsOf5(), kernsOf7], kernCount))));
}

@("math.FTP36.rows")
@safe pure nothrow
unittest
{
    const inst = at(build(mathTableData(null, glyphInfo(), null)));
    // Covered: its MathValueRecord; a stored zero is a value.
    assert(inst.italicsCorrection(5).value.value.design == du(100));
    const zero = inst.italicsCorrection(7).value;
    assert(zero.present && zero.value.design == du(0));
    assert(inst.topAccentAttachment(5).value.value.design == du(250));
    // Not covered: absent, never invented.
    assert(!inst.italicsCorrection(6).value.present && !inst.topAccentAttachment(7).value.present);
    assert(inst.isExtendedShape(9).value && !inst.isExtendedShape(5).value);
    assert(inst.mathKern(5, topRight, du(150)).value.value.design == du(2));
    assert(!inst.mathKern(6, topRight, du(150)).value.present);
    // A null corner is absent.
    assert(!inst.mathKernTable(5, topLeft).value.present && !inst.mathKern(5, topLeft, du(0)).value.present);
    // Covered, index past the value array: badValue.
    const shortArrays = at(build(mathTableData(null, glyphInfo(1, 1), null)));
    assert(shortArrays.italicsCorrection(7).error.kind == FontErrorKind.badValue);
    assert(shortArrays.italicsCorrection(5).value.value.design == du(100));
    assert(shortArrays.mathKern(7, topRight, du(0)).error.kind == FontErrorKind.badValue);
    assert(shortArrays.mathKernTable(7, topRight).error.kind == FontErrorKind.badValue);
}

@("math.FTP36.missingSubtables")
@safe pure nothrow
unittest
{
    // No MathGlyphInfo: absent for every glyph, isExtendedShape false.
    const none = at(build(mathTableData(mathConstantsTable(constantsSpec()), null, null)));
    foreach (gid; [5u, 7, 9])
    {
        assert(!none.italicsCorrection(gid).value.present && !none.topAccentAttachment(gid).value.present);
        assert(!none.isExtendedShape(gid).value && !none.mathKern(gid, topRight, du(0)).value.present);
    }
    // A MathGlyphInfo with every subtable null.
    const empty = at(build(mathTableData(null, mathGlyphInfoTable(MathGlyphInfoSpec.init), null)));
    assert(!empty.italicsCorrection(5).value.present && !empty.topAccentAttachment(5).value.present);
    assert(!empty.isExtendedShape(9).value && !empty.mathKernTable(5, topRight).value.present);
    // A subtable with a null coverage covers nothing.
    const noCoverage = at(build(mathTableData(null, mathGlyphInfoTable(MathGlyphInfoSpec(
        mathValueTable(MathValueTableSpec(null, [v(1)])))), null)));
    assert(!noCoverage.italicsCorrection(0).value.present);
}

@("math.FTP36.variationIndex")
@safe pure nothrow
unittest
{
    const info = mathGlyphInfoTable(MathGlyphInfoSpec(
        mathValueTable(MathValueTableSpec(coverage1([5]), [v(100, variationIndexTable(0, 0))]))));
    const bytes = build(mathTableData(null, info, null), gdefTable(store([-40])));
    assert(at(bytes, one).italicsCorrection(5).value.value.design == du(60));
    assert(at(bytes).italicsCorrection(5).value.value.design == du(100));
    assert(at(build(mathTableData(null, info, null)), one).italicsCorrection(5).error.kind
        == FontErrorKind.badValue);
}

@("math.FTP36.coverageFormats")
@safe pure nothrow
unittest
{
    // A coverage of an unknown format is unsupportedVersion for the queries that use it.
    const info = mathGlyphInfoTable(MathGlyphInfoSpec(
        mathValueTable(MathValueTableSpec(u16(3) ~ u16(0), [v(1)])), null, u16(9) ~ u16(0)));
    const inst = at(build(mathTableData(null, info, null)));
    assert(inst.italicsCorrection(0).error.kind == FontErrorKind.unsupportedVersion);
    assert(inst.isExtendedShape(0).error.kind == FontErrorKind.unsupportedVersion);
    assert(!inst.topAccentAttachment(0).value.present);
}

// ---------------------------------------------------------------------------
// The kern step rule (FTP37)
// ---------------------------------------------------------------------------

@("math.FTP37.steps")
@safe pure nothrow
unittest
{
    const inst = at(build(mathTableData(null, glyphInfo(), null)));
    // Heights 100, 200, 300; values 1, 2, 3, 4.
    static immutable long[2][] trace = [
        [-1_000, 1], [99, 1], [100, 2], [150, 2], [200, 3], [299, 3], [300, 4], [10_000, 4],
    ];
    foreach (t; trace)
        assert(inst.mathKern(5, topRight, du(t[0])).value.value.design == du(t[1]));
    // Exactly at a correction height selects the value above; just below it, the value below.
    assert(inst.mathKern(5, topRight, DesignValue(100 * 65_536 - 1, upem)).value.value.design == du(1));
    assert(inst.mathKern(5, topRight, DesignValue(100 * 65_536 + 1, upem)).value.value.design == du(2));
    // No heights: the one value.
    assert(inst.mathKern(5, MathKernCorner.bottomRight, du(-50)).value.value.design == du(-9));
    // The table, for inspection.
    const t = inst.mathKernTable(5, topRight).value;
    assert(t.present && t.heightCount == 3 && t.heightsAscending.value);
    assert(t.height(2).value.value.design == du(300) && t.value(3).value.value.design == du(4));
    // A height in another em is the caller's mistake.
    assert(inst.mathKern(5, topRight, DesignValue(0, 2_048)).error.kind == FontErrorKind.badValue);
}

@("math.FTP37.unsorted")
@safe pure nothrow
unittest
{
    // Heights 300, 100, 200 in stored order, never reordered.
    const inst = at(build(mathTableData(null, glyphInfo(), null)));
    const t = inst.mathKernTable(5, bottomLeft).value;
    assert(!t.heightsAscending.value);
    assert(inst.mathKern(5, bottomLeft, du(150)).value.value.design == du(1)); // 300 > 150 first
    assert(inst.mathKern(5, bottomLeft, du(300)).value.value.design == du(4)); // none greater
    assert(inst.mathKern(5, bottomLeft, du(250)).value.value.design == du(1));
}

@("math.FTP37.variationAndDevice")
@safe pure nothrow
unittest
{
    MathKernSpec[4] kerns;
    // Height 100 (+200 at TEST = 1), height 200 with a Device table of +7 at 11 ppem.
    kerns[0] = MathKernSpec(true, [v(100, variationIndexTable(0, 0)), v(200, deviceTable(11, 11, 3, [7]))],
        [v(1), v(2), v(3, deviceTable(11, 11, 3, [5]))]);
    const info = mathGlyphInfoTable(MathGlyphInfoSpec(null, null, null,
        mathKernInfoTable(MathKernInfoSpec(coverage1([5]), [kerns]))));
    const bytes = build(mathTableData(null, info, null), gdefTable(store([200])));
    // The variation delta moves the step: 150 is below 300 at 1.0, above 100 at the default.
    assert(at(bytes, one).mathKern(5, topRight, du(150)).value.value.design == du(1));
    assert(at(bytes).mathKern(5, topRight, du(150)).value.value.design == du(2));
    // A device delta never does: at 11 ppem 200 still selects the value above it.
    const at11 = at(bytes, 0, px(11));
    const kern = at11.mathKern(5, topRight, du(200)).value;
    assert(kern.value.design == du(3) && kern.device.deviceApplied && kern.device.devicePixels == 5);
    assert(at11.mathKernTable(5, topRight).value.height(1).value.device.devicePixels == 7);
    assert(at(bytes, 0, px(12)).mathKern(5, topRight, du(200)).value.value.design == du(3));
}

@("math.FTP37.firstError")
@safe pure nothrow
unittest
{
    MathKernSpec[4] kerns;
    // Height 0 has no row in the store (inner 5): its delta is badValue at nonzero coordinates.
    kerns[0] = MathKernSpec(true, [v(100), v(200, variationIndexTable(0, 5)), v(300)],
        [v(1), v(2), v(3), v(4)]);
    const info = mathGlyphInfoTable(MathGlyphInfoSpec(null, null, null,
        mathKernInfoTable(MathKernInfoSpec(coverage1([5]), [kerns]))));
    const bytes = build(mathTableData(null, info, null), gdefTable(store([10])));
    const inst = at(bytes, one);
    // k is found before the malformed height: no error.
    assert(inst.mathKern(5, topRight, du(50)).value.value.design == du(1));
    // The malformed height is met before k: it is the query's error.
    assert(inst.mathKern(5, topRight, du(150)).error.kind == FontErrorKind.badValue);
    assert(inst.mathKern(5, topRight, du(250)).error.kind == FontErrorKind.badValue);
    assert(inst.mathKernTable(5, topRight).value.heightsAscending.error.kind == FontErrorKind.badValue);
    // At the default nothing is read.
    assert(at(bytes).mathKern(5, topRight, du(250)).value.value.design == du(3));
}

// ---------------------------------------------------------------------------
// Variants and assemblies (FTP38)
// ---------------------------------------------------------------------------

private immutable GlyphPartSpec[3] partSpecs = [
    GlyphPartSpec(30, 0, 50, 300, 0),
    GlyphPartSpec(31, 50, 50, 200, 1),
    GlyphPartSpec(32, 50, 0, 300, 0x8002),
];

/// Vertical: 10 has three variants, 11 an assembly, 12 a null construction; horizontal: 10 one variant.
private ubyte[] variants(const(ubyte)[] vertCoverage = coverage1([10, 11, 12]),
    MathValueSpec italics = MathValueSpec(15)) @safe pure nothrow
{
    return mathVariantsTable(MathVariantsSpec(25, vertCoverage, [
        ConstructionSpec(false, MathValueSpec.init, null, [[10, 500], [20, 800], [21, 1_200]]),
        ConstructionSpec(true, italics, partSpecs[], [[11, 400]]),
        ConstructionSpec(false, MathValueSpec.init, null, null, true),
    ], coverage2([[10, 10, 0]]), [ConstructionSpec(false, MathValueSpec.init, null, [[40, 600]])]));
}

@("math.FTP38.variants")
@safe pure nothrow
unittest
{
    const inst = at(build(mathTableData(null, null, variants())));
    auto r = inst.mathVariants(10, vertical).value;
    assert(r.variantsPresent && r.minConnectorOverlap.design == du(25));
    assert(r.length == 3 && r[0].glyph == 10 && r[1].glyph == 20 && r.back.glyph == 21);
    assert(r[2].advance.design == du(1_200) && r[1].advance.physical.hasValue);
    r.popFront();
    r.popBack();
    assert(r.length == 1 && r.front.glyph == 20);
    const h = inst.mathVariants(10, horizontal).value;
    assert(h.length == 1 && h.front == MathVariant(40, h.front.advance) && h.front.advance.design == du(600));
    // No construction: an empty range.
    assert(inst.mathVariants(11, horizontal).value.empty && inst.mathVariants(99, vertical).value.empty);
    assert(inst.mathVariants(12, vertical).value.empty);
    // A construction index past the array: badValue.
    const past = at(build(mathTableData(null, null, variants(coverage1([10, 11, 12, 13])))));
    assert(past.mathVariants(13, vertical).error.kind == FontErrorKind.badValue);
    assert(past.mathVariants(10, vertical).value.length == 3);
}

@("math.FTP38.assemblyLength")
@safe pure nothrow
unittest
{
    const inst = at(build(mathTableData(null, null, variants())));
    assert(inst.mathAssemblyLength(11, vertical).value == MathAssemblyLength(true, 3));
    foreach (gid; [10u, 12, 99])
        assert(!inst.mathAssemblyLength(gid, vertical).value.present);
    assert(!inst.mathAssemblyLength(10, horizontal).value.present);
    GlyphPart[3] parts;
    assert(!inst.mathAssembly(10, vertical, parts[]).value.present);
    assert(!inst.mathAssembly(12, vertical, parts[]).value.present);
}

@("math.FTP38.assembly")
@safe pure nothrow
unittest
{
    const inst = at(build(mathTableData(null, null, variants())));
    GlyphPart[5] parts;
    const a = inst.mathAssembly(11, vertical, parts[]).value;
    assert(a.present && a.parts.length == 3 && a.parts.ptr is parts.ptr);
    assert(a.italicsCorrection.present && a.italicsCorrection.value.design == du(15));
    assert(!a.italicsCorrection.hasDevice);
    foreach (i, p; a.parts)
    {
        const s = partSpecs[i];
        assert(p.glyph == s.glyph && p.flags == s.flags);
        assert(p.startConnectorLength.design == du(s.startConnector));
        assert(p.endConnectorLength.design == du(s.endConnector) && p.fullAdvance.design == du(s.fullAdvance));
    }
    assert(!a.parts[0].extender && a.parts[1].extender);
    // Reserved bits are reported in the flags word; the extender bit is bit 0 only.
    assert(a.parts[2].flags == 0x8002 && !a.parts[2].extender);
    assert(parts[3] == GlyphPart.init);
}

@("math.FTP38.callerStorage")
@safe pure nothrow
unittest
{
    const inst = at(build(mathTableData(null, null, variants())));
    // Exactly sufficient.
    GlyphPart[3] exact;
    assert(inst.mathAssembly(11, vertical, exact[]).value.parts.length == 3 && exact[2].glyph == 32);
    // One short: callerStorage with the length needed, the array unchanged.
    GlyphPart[2] short_;
    short_[0].glyph = 777;
    const e = inst.mathAssembly(11, vertical, short_[]).error;
    assert(e.kind == FontErrorKind.limitExceeded && e.limit == FontLimit.callerStorage && e.needed == 3);
    assert(e.tag == Tag("MATH"));
    assert(short_[0].glyph == 777 && short_[1] == GlyphPart.init);
    assert(inst.mathAssembly(11, vertical, null).error.needed == 3);
}

@("math.FTP38.italicsCorrection")
@safe pure nothrow
unittest
{
    const math = mathTableData(null, null, variants(coverage1([10, 11, 12]), v(15, variationIndexTable(0, 0))));
    const bytes = build(math, gdefTable(store([10])));
    GlyphPart[3] parts;
    const a = at(bytes, one).mathAssembly(11, vertical, parts[]).value;
    assert(a.italicsCorrection.value.design == du(25) && a.italicsCorrection.hasDevice);
    // Its error leaves the caller's array unchanged.
    GlyphPart[3] untouched;
    assert(at(build(math), one).mathAssembly(11, vertical, untouched[]).error.kind == FontErrorKind.badValue);
    assert(untouched[0] == GlyphPart.init);
}

// ---------------------------------------------------------------------------
// Hostile input (FTB1, FTB2)
// ---------------------------------------------------------------------------

/// Every query on `bytes` at two coordinates and two sizes: each a value or an error.
private void exercise(const(ubyte)[] bytes) @safe pure nothrow
{
    GlyphPart[4] parts;
    foreach (coord; [0, one])
        foreach (size; [twelvePoints, px(11)])
        {
            const inst = at(bytes, coord, size);
            const constants = inst.mathConstants;
            if (constants.hasValue)
                foreach (c; MathConstant.min .. MathConstant.max + 1)
                {
                    const r = constants.value[cast(MathConstant) c];
                    if (r.hasValue)
                        cast(void) r.value.pixels;
                }
            foreach (gid; [5u, 7, 9, 10, 11, 12])
            {
                cast(void) inst.italicsCorrection(gid);
                cast(void) inst.topAccentAttachment(gid);
                cast(void) inst.isExtendedShape(gid);
                foreach (corner; MathKernCorner.min .. MathKernCorner.max + 1)
                {
                    cast(void) inst.mathKern(gid, cast(MathKernCorner) corner, du(150));
                    const t = inst.mathKernTable(gid, cast(MathKernCorner) corner);
                    if (t.hasValue && t.value.present)
                    {
                        cast(void) t.value.heightsAscending;
                        foreach (i; 0 .. t.value.heightCount)
                            cast(void) t.value.height(i);
                    }
                }
                foreach (direction; [vertical, horizontal])
                {
                    const r = inst.mathVariants(gid, direction);
                    if (r.hasValue)
                    {
                        MathVariants all = r.value;
                        foreach (variant; all) {}
                    }
                    cast(void) inst.mathAssemblyLength(gid, direction);
                    cast(void) inst.mathAssembly(gid, direction, parts[]);
                }
            }
        }
}

/// A `MATH` table with every subtable, Device and VariationIndex tables.
private ubyte[] hostileMath() @safe pure nothrow
{
    auto spec = constantsSpec();
    spec.records[0] = v(500, deviceTable(10, 12, 2, [1, -2, 3]));
    spec.records[1] = v(250, variationIndexTable(0, 0));
    return mathTableData(mathConstantsTable(spec), glyphInfo(),
        variants(coverage1([10, 11, 12]), v(15, deviceTable(11, 11, 1, [1]))));
}

@("math.hostile.truncations")
@safe pure nothrow
unittest
{
    const full = hostileMath();
    const gdef = gdefTable(store([40]));
    foreach (n; 0 .. full.length)
        exercise(build(full[0 .. n], gdef));
    foreach (n; 0 .. gdef.length)
        exercise(build(full, gdef[0 .. n]));
}

@("math.hostile.corruptions")
@safe pure nothrow
unittest
{
    // Every byte set to 0xFF, then to 0x00, one at a time.
    const full = hostileMath();
    const gdef = gdefTable(store([40]));
    foreach (i; 0 .. full.length)
        foreach (ubyte value; [0xFF, 0x00])
        {
            auto bytes = full.dup;
            bytes[i] = value;
            exercise(build(bytes, gdef));
        }
}

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

/**
Every bundled face's math queries give a defined outcome. The bundle has no
math face, so each is `missingTable`; a real math face (STIX Two Math is the
candidate) remains an acquisition prerequisite (`testing.md`).
*/
@("math.corpus.everyFace")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    size_t faces;
    GlyphPart[64] parts;
    foreach (entry; dirEntries(fontsPath, SpanMode.shallow))
    {
        if (!entry.name.endsWith(".ttf") && !entry.name.endsWith(".otf"))
            continue;
        const opened = openFace(bundled(baseName(entry.name)));
        if (!opened.hasValue)
            continue;
        const face = opened.value;
        const inst = face.instance(twelvePoints, null).value;
        ++faces;
        if (!face.has(Tag("MATH")))
        {
            allFail(inst, FontErrorKind.missingTable);
            continue;
        }
        const constants = inst.mathConstants;
        assert(constants.hasValue, entry.name);
        foreach (c; MathConstant.min .. MathConstant.max + 1)
            cast(void) constants.value[cast(MathConstant) c];
        foreach (gid; 0 .. face.numGlyphs)
        {
            cast(void) inst.italicsCorrection(gid);
            cast(void) inst.mathKern(gid, topRight, DesignValue(0, face.unitsPerEm));
            cast(void) inst.mathAssembly(gid, vertical, parts[]);
        }
    }
    assert(faces > 50);
}

// ---------------------------------------------------------------------------
// GDEF's item variation store (FTM11)
// ---------------------------------------------------------------------------

@("math.gdef.versions")
@safe pure nothrow
unittest
{
    import sparkles.font.gdef : gdef, gdefVariationStore;

    const face13 = openFace(build(null, gdefTable(store([5])))).value;
    const g = gdef(face13, 1).value;
    assert(g.majorVersion == 1 && g.minorVersion == 3 && g.variationStore.present);
    assert(gdefVariationStore(face13, 1).present && !gdefVariationStore(face13, 1).broken);
    // Before 1.3, or a null offset: no store.
    foreach (bytes; [gdefTable(null, 0), gdefTable(null, 2), gdefTable(null, 3)])
    {
        const face = openFace(build(null, bytes)).value;
        assert(gdef(face, 1).hasValue && !gdefVariationStore(face, 1).present);
    }
    // No GDEF: missingTable from the header, no store.
    const bare = openFace(build(null)).value;
    assert(gdef(bare, 1).error.kind == FontErrorKind.missingTable && !gdefVariationStore(bare, 1).present);
    // Another major version, or a short header: the error, recorded in a broken store.
    const v2 = openFace(build(null, gdefTable(store([5]), 3, 2))).value;
    assert(gdef(v2, 1).error.kind == FontErrorKind.unsupportedVersion);
    assert(gdefVariationStore(v2, 1).broken && gdefVariationStore(v2, 1).error.kind
        == FontErrorKind.unsupportedVersion);
    foreach (n; [0, 3, 11])
        assert(gdef(openFace(build(null, gdefTable(null, 0)[0 .. n])).value, 1).error.kind
            == FontErrorKind.truncated);
    assert(gdef(openFace(build(null, gdefTable(store([5]))[0 .. 17])).value, 1).error.kind
        == FontErrorKind.truncated);
    // A store whose axis count differs from fvar's is broken, not fatal.
    assert(gdef(face13, 2).value.variationStore.broken);
}
