/**
Metrics at an instance (FTV14, FTM15–FTM19) on hand-built fixtures, and the
cell metrics of two bundled monospace faces checked against values derived by
hand from their stored fields.

Fixtures use 1,000 units per em, so at ppem 10 one unit is 0.01 px, and one
`TEST` axis whose user values equal their normalized values: at 1.0 a
one-region store whose region peaks at 1.0 gives each item its row's delta,
at 0.5 half of it.
*/
module sparkles.font.metrics_test;

import std.algorithm.searching : endsWith;
import std.file : dirEntries, SpanMode;
import std.path : baseName;

import sparkles.base.text.layout_units : LayoutUnit;
import sparkles.test_runner.skip : skipTest;

import sparkles.font.cmap : charMap, CharMap;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.errors : FontErrorKind, Tag;
import sparkles.font.face : Face, openFace;
import sparkles.font.fixtures;
import sparkles.font.instance : axes, Instance, instance, InstanceSize, UserCoordinate;
import sparkles.font.tables : fvar;
import sparkles.font.metrics;
import sparkles.font.units : DesignValue, Ppem;

private enum one = 65_536; // 1.0 in F16.16
private enum short f2one = 16_384; // 1.0 in F2Dot14
private enum ushort upem = 1_000;

private immutable twelvePoints = InstanceSize.physical(LayoutUnit(12 * LayoutUnit.ticksPerPoint));

/// What a fixture face holds; every table is optional.
private struct Spec
{
    bool withHhea = true;
    int hheaAscender = 800, hheaDescender = -200, hheaLineGap = 90;
    uint numberOfHMetrics = uint.max; // all of `advances`
    bool withOs2 = true;
    Os2Fields os2;
    bool withPost = true;
    int underlinePosition = -100, underlineThickness = 50;
    /// Glyph advances; glyph 1 is what U+0030 maps to unless `digitZero` is 0.
    const(uint)[] advances = [0, 600, 500, 650];
    uint digitZero = 1;
    bool variable;
    const(ubyte)[] hvar, mvar;
}

/// The bytes of the face `s` describes.
private ubyte[] build(Spec s) @safe pure nothrow
{
    const n = cast(uint) s.advances.length;
    const longCount = s.numberOfHMetrics == uint.max ? n : s.numberOfHMetrics;
    uint[2][] metrics;
    foreach (a; s.advances[0 .. longCount])
        metrics ~= [a, 0];
    const(uint[2])[] map = s.digitZero ? [[0x30u, s.digitZero]] : [[0x41u, 1u]];
    auto tables = [TableData("cmap", cmap([CmapRecord(3, 1, cmapFormat0(map))])),
        TableData("head", head(upem)), TableData("maxp", maxp(n))];
    if (s.withHhea)
        tables ~= [TableData("hhea", hhea(longCount, s.hheaAscender, s.hheaDescender, s.hheaLineGap)),
            TableData("hmtx", hmtx(metrics))];
    if (s.withOs2)
        tables ~= TableData("OS/2", os2Table(s.os2));
    if (s.withPost)
        tables ~= TableData("post", postHeader(s.underlinePosition, s.underlineThickness));
    if (s.variable)
        tables ~= TableData("fvar", fvarTable([FvarAxis("TEST", -one, 0, one)]));
    if (s.hvar !is null)
        tables ~= TableData("HVAR", s.hvar);
    if (s.mvar !is null)
        tables ~= TableData("MVAR", s.mvar);
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

/// One axis, one region peaking at 1.0, one data subtable whose item `i` has delta `deltas[i]`.
private ubyte[] store(const(int)[] deltas, bool longWords = false) @safe pure nothrow
{
    int[][] rows;
    foreach (d; deltas)
        rows ~= [d];
    return itemVariationStore(1, [[[0, f2one, f2one]]], [VarData([0], 1, longWords, rows)]);
}

/// The design value of `units` font units.
private DesignValue du(long units) @safe pure nothrow @nogc => DesignValue(units * 65_536, upem);

/// The design value of a measurement result, which must hold one.
private long raw(R)(R r) => r.value.design.raw;

// ---------------------------------------------------------------------------
// FTM16: the line-metric order
// ---------------------------------------------------------------------------

@("metrics.FTM16.typoFlagWins")
@safe pure nothrow
unittest
{
    Spec s;
    s.os2.fsSelection = 0x80;
    const l = at(build(s)).lineMetrics.value;
    assert(l.source == LineMetricsSource.typographic);
    assert(l.ascender.design == du(750) && l.descender.design == du(-250) && l.lineGap.design == du(100));
}

@("metrics.FTM16.hheaNonzero")
@safe pure nothrow
unittest
{
    Spec s;
    const l = at(build(s)).lineMetrics.value;
    assert(l.source == LineMetricsSource.hhea);
    assert(l.ascender.design == du(800) && l.descender.design == du(-200) && l.lineGap.design == du(90));
    // A descender alone is enough.
    s.hheaAscender = 0;
    assert(at(build(s)).lineMetrics.value.source == LineMetricsSource.hhea);
}

@("metrics.FTM16.hheaZeroThenTypographic")
@safe pure nothrow
unittest
{
    Spec s;
    s.hheaAscender = s.hheaDescender = 0;
    const l = at(build(s)).lineMetrics.value;
    assert(l.source == LineMetricsSource.typographic && l.ascender.design == du(750));
}

@("metrics.FTM16.thenWindows")
@safe pure nothrow
unittest
{
    Spec s;
    s.hheaAscender = s.hheaDescender = 0;
    s.os2.sTypoAscender = s.os2.sTypoDescender = 0;
    const l = at(build(s)).lineMetrics.value;
    assert(l.source == LineMetricsSource.windows);
    assert(l.ascender.design == du(900) && l.descender.design == du(-300) && l.lineGap.design == du(0));
}

@("metrics.FTM16.absentSets")
@safe pure nothrow
unittest
{
    // No OS/2: hhea when nonzero, else absent.
    Spec s;
    s.withOs2 = false;
    assert(at(build(s)).lineMetrics.value.source == LineMetricsSource.hhea);
    s.hheaAscender = s.hheaDescender = 0;
    assert(!at(build(s)).lineMetrics.value.present);
    // No hhea: the typographic set; with it zero, the Windows set.
    Spec t;
    t.withHhea = false;
    assert(at(build(t)).lineMetrics.value.source == LineMetricsSource.typographic);
    t.os2.sTypoAscender = t.os2.sTypoDescender = 0;
    assert(at(build(t)).lineMetrics.value.source == LineMetricsSource.windows);
    // Neither table.
    t.withOs2 = false;
    const none = at(build(t)).lineMetrics;
    assert(none.hasValue && !none.value.present);
    const sets = at(build(t)).verticalSets.value;
    assert(!sets.hasHhea && !sets.hasOs2 && !sets.useTypoMetrics);
}

@("metrics.FTM16.signsKept")
@safe pure nothrow
unittest
{
    Spec s;
    s.hheaAscender = -100;
    s.hheaDescender = 200;
    s.hheaLineGap = -30;
    const l = at(build(s)).lineMetrics.value;
    assert(l.ascender.design == du(-100) && l.descender.design == du(200) && l.lineGap.design == du(-30));
}

@("metrics.FTM16.chosenOnStoredValues")
@safe pure nothrow
unittest
{
    // hhea is stored zero; MVAR's hasc delta would make it nonzero, yet the
    // typographic set is chosen, and the delta is then added to it.
    Spec s;
    s.variable = true;
    s.hheaAscender = s.hheaDescender = 0;
    s.mvar = mvarTable([MvarRecord("hasc", 0, 0)], store([500]));
    const bytes = build(s);
    const l = at(bytes, one).lineMetrics.value;
    assert(l.source == LineMetricsSource.typographic && l.ascender.design == du(1_250));
    const sets = at(bytes, one).verticalSets.value;
    assert(sets.hhea.ascender.design == du(500));
    // At the default nothing is added.
    assert(at(bytes).lineMetrics.value.ascender.design == du(750));
}

@("metrics.FTM16.unreadableTable")
@safe pure nothrow
unittest
{
    auto bytes = sfnt([TableData("cmap", cmap([CmapRecord(3, 1, cmapFormat0([[0x30, 1]]))])),
        TableData("head", head(upem)), TableData("maxp", maxp(2)), TableData("hhea", hhea(2)[0 .. 20])]);
    assert(at(bytes).lineMetrics.error.kind == FontErrorKind.truncated);
    assert(at(bytes).verticalSets.error.tag == Tag("hhea"));
}

// ---------------------------------------------------------------------------
// FTM15 and FTV14: the sets and their MVAR tags
// ---------------------------------------------------------------------------

/// MVAR records for the five set tags, items 0–4 of `store([1, 2, 3, 4, 5])`; sorted by tag.
private immutable MvarRecord[] setRecords = [MvarRecord("hasc", 0, 0), MvarRecord("hcla", 0, 1),
    MvarRecord("hcld", 0, 2), MvarRecord("hdsc", 0, 3), MvarRecord("hlgp", 0, 4)];

@("metrics.FTM15.tagMappingPerSet")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.os2.fsSelection = 0x80;
    s.mvar = mvarTable(setRecords, store([10, 20, 30, 40, 50]));
    const v = at(build(s), one).verticalSets.value;
    assert(v.useTypoMetrics && v.hasHhea && v.hasOs2);
    // hhea and the typographic set take hasc, hdsc, hlgp.
    assert(v.hhea.ascender.design == du(810) && v.hhea.descender.design == du(-160)
        && v.hhea.lineGap.design == du(140));
    assert(v.typographic.ascender.design == du(760) && v.typographic.descender.design == du(-210)
        && v.typographic.lineGap.design == du(150));
    // The Windows set takes hcla and hcld only, as stored (positive descent).
    assert(v.windows.ascent.design == du(920) && v.windows.descent.design == du(330));
}

@("metrics.FTM15.windowsIgnoresHasc")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.hheaAscender = s.hheaDescender = 0;
    s.os2.sTypoAscender = s.os2.sTypoDescender = 0;
    s.mvar = mvarTable([MvarRecord("hasc", 0, 0), MvarRecord("hcld", 0, 1)], store([100, 7]));
    const l = at(build(s), one).lineMetrics.value;
    assert(l.source == LineMetricsSource.windows);
    assert(l.ascender.design == du(900) && l.descender.design == du(-307) && l.lineGap.design == du(0));
}

@("metrics.FTV14.fractionalDelta")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.mvar = mvarTable([MvarRecord("hasc", 0, 0)], store([1]));
    // At 0.5 the delta is half a unit, kept exactly.
    const l = at(build(s), one / 2).lineMetrics.value;
    assert(l.ascender.design.raw == 800 * 65_536 + 32_768);
}

@("metrics.FTV14.mvarMissingTagIsZero")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.mvar = mvarTable([MvarRecord("xhgt", 0, 0)], store([40]));
    const bytes = build(s);
    assert(at(bytes, one).lineMetrics.value.ascender.design == du(800));
    assert(at(bytes, one).decorations.value.xHeight.design == du(490));
}

@("metrics.FTV14.mvarRecordStride")
@safe pure nothrow
unittest
{
    // Records 12 bytes apart: the search steps by valueRecordSize.
    Spec s;
    s.variable = true;
    s.mvar = mvarTable(setRecords, store([1, 2, 3, 4, 5]), 12);
    const v = at(build(s), one).verticalSets.value;
    assert(v.hhea.lineGap.design == du(95) && v.windows.descent.design == du(303));
    const face = openFace(build(s)).value;
    assert(face.mvar(1).value.valueRecordSize == 12 && face.mvar(1).value.valueRecordCount == 5);
}

@("metrics.FTV14.mvarShortRecordSize")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.mvar = mvarTable([MvarRecord("hasc", 0, 0)], store([1]), 6);
    const bytes = build(s);
    // At nonzero coordinates every metric taking an MVAR delta is badValue.
    const e = at(bytes, one).lineMetrics.error;
    assert(e.kind == FontErrorKind.badValue && e.tag == Tag("MVAR") && e.tableOffset == 6);
    assert(at(bytes, one).decorations.error.kind == FontErrorKind.badValue);
    assert(at(bytes, one).verticalSets.error.kind == FontErrorKind.badValue);
    // At the default MVAR is not read.
    assert(at(bytes).lineMetrics.value.ascender.design == du(800));
}

@("metrics.FTV14.mvarMajor2")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.mvar = mvarTable([MvarRecord("hasc", 0, 0)], store([1]), 8, 2);
    const bytes = build(s);
    assert(at(bytes, one).lineMetrics.error.kind == FontErrorKind.unsupportedVersion);
    assert(at(bytes).decorations.value.xHeight.design == du(450));
}

@("metrics.FTV14.mvarRecordWithoutStore")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.mvar = mvarTable([MvarRecord("hasc", 0, 0)], null);
    assert(at(build(s), one).lineMetrics.error.kind == FontErrorKind.badValue);
}

// ---------------------------------------------------------------------------
// FTM17: decorations
// ---------------------------------------------------------------------------

@("metrics.FTM17.presencePerVersion")
@safe pure nothrow
unittest
{
    Spec s;
    s.os2.version_ = 1;
    auto d = at(build(s)).decorations.value;
    assert(!d.hasXHeight && !d.hasCapHeight && d.hasStrikeout && d.hasUnderline);
    assert(d.strikeoutPosition.design == du(250) && d.strikeoutSize.design == du(50));
    assert(d.underlinePosition.design == du(-100) && d.underlineThickness.design == du(50));
    s.os2.version_ = 2;
    d = at(build(s)).decorations.value;
    assert(d.hasXHeight && d.xHeight.design == du(450) && d.capHeight.design == du(650));
    // Without OS/2 or post their values are absent, not errors.
    s.withOs2 = false;
    s.withPost = false;
    d = at(build(s)).decorations.value;
    assert(!d.hasXHeight && !d.hasStrikeout && !d.hasUnderline);
}

@("metrics.FTM17.zeroIsAValue")
@safe pure nothrow
unittest
{
    Spec s;
    s.os2.sxHeight = s.os2.sCapHeight = 0;
    s.underlinePosition = s.underlineThickness = 0;
    const d = at(build(s)).decorations.value;
    assert(d.hasXHeight && d.xHeight.design == du(0) && d.hasCapHeight && d.capHeight.design == du(0));
    assert(d.hasUnderline && d.underlineThickness.design == du(0));
}

@("metrics.FTM17.mvarTags")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.mvar = mvarTable([MvarRecord("cpht", 0, 0), MvarRecord("stro", 0, 1), MvarRecord("strs", 0, 2),
        MvarRecord("undo", 0, 3), MvarRecord("unds", 0, 4), MvarRecord("xhgt", 0, 5)],
        store([1, 2, 3, 4, 5, 6]));
    const d = at(build(s), one).decorations.value;
    assert(d.capHeight.design == du(651) && d.strikeoutPosition.design == du(252)
        && d.strikeoutSize.design == du(53) && d.underlinePosition.design == du(-96)
        && d.underlineThickness.design == du(55) && d.xHeight.design == du(456));
}

// ---------------------------------------------------------------------------
// FTM18 and FTV14: advances
// ---------------------------------------------------------------------------

@("metrics.FTM18.staticAdvance")
@safe pure nothrow
unittest
{
    Spec s;
    const bytes = build(s);
    assert(raw(at(bytes).advance(1)) == du(600).raw);
    assert(at(bytes).advance(9).error.kind == FontErrorKind.indexOutOfRange);
    // No fvar: the instance is the default, so HVAR is never needed.
    assert(at(bytes, one).advance(1).value.design == du(600));
}

@("metrics.FTV14.hvarIdentityMap")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.hvar = hvarTable(store([0, 10, 20, -30]));
    const bytes = build(s);
    assert(at(bytes, one).advance(2).value.design == du(520));
    assert(at(bytes, one).advance(3).value.design == du(620));
    assert(at(bytes, one / 2).advance(1).value.design == du(605));
    assert(at(bytes).advance(2).value.design == du(500));
}

@("metrics.FTV14.hvarExplicitMap")
@safe pure nothrow
unittest
{
    // Glyphs 0–3 map to items 3, 2, 1, 0; a glyph past the map uses its last entry.
    foreach (format; [0, 1])
    {
        Spec s;
        s.variable = true;
        s.advances = [0, 600, 500, 650, 700];
        s.hvar = hvarTable(store([1, 2, 3, 4]), deltaSetIndexMap([[0, 3], [0, 2], [0, 1], [0, 0]], 4, 1, format));
        const bytes = build(s);
        assert(at(bytes, one).advance(1).value.design == du(603));
        assert(at(bytes, one).advance(3).value.design == du(651));
        assert(at(bytes, one).advance(4).value.design == du(701));
    }
}

@("metrics.FTV14.hvarMajor2")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.hvar = hvarTable(store([0, 10]), null, 2);
    const bytes = build(s);
    assert(at(bytes, one).advance(1).error.kind == FontErrorKind.unsupportedVersion);
    assert(at(bytes).advance(1).value.design == du(600));
}

@("metrics.FTV14.hvarUnreadable")
@safe pure nothrow
unittest
{
    // A store of the wrong format: every varied advance is its error, with no fallback.
    Spec s;
    s.variable = true;
    s.hvar = hvarTable(itemVariationStore(1, [[[0, f2one, f2one]]], [VarData([0], 1, false, [[1], [2]])], 2));
    const bytes = build(s);
    const e = at(bytes, one).advance(1).error;
    assert(e.kind == FontErrorKind.unsupportedVersion && e.tag == Tag("HVAR") && e.tableOffset == 20);
    assert(at(bytes).advance(1).value.design == du(600));
    // A truncated header.
    s.hvar = hvarTable(store([0]))[0 .. 12];
    assert(at(build(s), one).advance(1).error.kind == FontErrorKind.truncated);
    // A null store offset.
    s.hvar = hvarTable(null);
    assert(at(build(s), one).advance(1).error.kind == FontErrorKind.badValue);
}

@("metrics.FTV14.noHvar")
@safe pure nothrow
unittest
{
    // Without HVAR (and without gvar) the advance at nonzero coordinates
    // is the stored hmtx advance: the phantom span (FTO5).
    Spec s;
    s.variable = true;
    const bytes = build(s);
    assert(at(bytes, one).advance(1).value.design == du(600));
    assert(at(bytes).advance(1).value.design == du(600));
}

@("metrics.FTV14.negativeAdvanceNotClamped")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.hvar = hvarTable(store([0, -700]));
    const a = at(build(s), one).advance(1).value;
    assert(a.design == du(-100));
    assert(a.physical.value.raw < 0);
}

@("metrics.FTM18.physicalAndPixelForms")
@safe pure nothrow
unittest
{
    Spec s;
    const bytes = build(s);
    // 600 units at 12 pt and upem 1000: 7.2 pt.
    const physical = at(bytes).advance(1).value;
    assert(physical.physical.value == LayoutUnit(cast(long)(7.2 * 65_536 + 0.5)));
    assert(physical.pixels.error.kind == FontErrorKind.unsupportedCapability);
    // The device scale changes pixels, never the physical value.
    assert(physical.pixels(96).value == 9.6 && physical.pixels(192).value == 19.2);
    assert(physical.pixels(0).error.kind == FontErrorKind.badValue);
    const pixel = at(bytes, 0, InstanceSize.pixels(Ppem.fromInteger(20).value)).advance(1).value;
    assert(pixel.pixels.value == 12.0);
    assert(pixel.physical.error.kind == FontErrorKind.unsupportedCapability);
    assert(pixel.pixels(96).error.kind == FontErrorKind.unsupportedCapability);
    assert(pixel.pixelsAt(Ppem.fromInteger(10).value) == 6.0);
}

@("metrics.FTM18.measureRunConvertsOnce")
@safe pure nothrow
unittest
{
    Spec s;
    // At a 1-tick em, a 500-unit advance is half a tick: alone it rounds to 0 (ties to even).
    const inst = at(build(s), 0, InstanceSize.physical(LayoutUnit(1)));
    assert(inst.advance(2).value.physical.value == LayoutUnit(0));
    const run = inst.measureRun([2, 2]).value;
    assert(run.design == du(1_000) && run.physical.value == LayoutUnit(1));
    assert(inst.measureRun(null).value.design == du(0));
}

@("metrics.FTM18.measureRunFirstErrorWins")
@safe pure nothrow
unittest
{
    // Glyph 3 maps to an inner index past the data's items: badValue.
    Spec s;
    s.variable = true;
    s.hvar = hvarTable(store([0, 1, 2]), deltaSetIndexMap([[0, 0], [0, 1], [0, 2], [0, 9]], 4, 1));
    const inst = at(build(s), one);
    assert(inst.measureRun([1, 3, 99]).error.kind == FontErrorKind.badValue);
    assert(inst.measureRun([1, 99, 3]).error.kind == FontErrorKind.indexOutOfRange);
    assert(inst.measureRun([1, 2]).value.design == du(1_103));
}

@("metrics.FTM18.measureRunOverflow")
@safe pure nothrow
unittest
{
    // 2^31 − 1 units a glyph is about 2^47 raw; 2^16 + 1 of them pass 2^63.
    Spec s;
    s.variable = true;
    s.hvar = hvarTable(store([0, int.max], true));
    const inst = at(build(s), one);
    auto gids = new uint[](65_537);
    gids[] = 1;
    assert(inst.measureRun(gids[0 .. 4]).hasValue);
    assert(inst.measureRun(gids).error.kind == FontErrorKind.arithmeticExhausted);
}

// ---------------------------------------------------------------------------
// FTM19: cell metrics
// ---------------------------------------------------------------------------

/// The cell metrics of `bytes` at `ppem`, at `TEST` = `coord`.
private auto cell(const(ubyte)[] bytes, uint ppem = 10, int coord = 0) @safe pure nothrow
{
    const inst = at(bytes, coord);
    const cm = inst.face.charMap.value;
    return inst.cellMetrics(cm, ppem);
}

@("metrics.FTM19.roundingTable")
@safe pure nothrow
unittest
{
    // At ppem 10: ascender 8.12 px, descender −2.13, gap 1.5, underline at −1.25, 0.45 thick.
    Spec s;
    s.hheaAscender = 812;
    s.hheaDescender = -213;
    s.hheaLineGap = 150;
    s.underlinePosition = -125;
    s.underlineThickness = 45;
    s.advances = [0, 650];
    const c = cell(build(s)).value;
    assert(c.ppem == 10 && c.lineSource == LineMetricsSource.hhea);
    assert(c.width == 6 && c.widthSource == CellMetrics.WidthSource.digitZero); // 6.5 → 6
    assert(c.ascent == 9 && c.descent == 3 && c.lineGap == 2); // ceil, ceil, 1.5 → 2
    assert(c.height == 14 && c.baseline == 10); // 9 + ⌊2 / 2⌋
    assert(c.hasUnderline && c.underlinePosition == 11 && c.underlineThickness == 1); // 11.25; 0.45 → 0 → 1
}

@("metrics.FTM19.tiesToEven")
@safe pure nothrow
unittest
{
    Spec s;
    s.advances = [0, 750];
    s.hheaLineGap = 250;
    s.underlineThickness = 250;
    s.underlinePosition = -50; // baseline + 0.5
    const c = cell(build(s)).value;
    assert(c.width == 8); // 7.5 → 8
    assert(c.lineGap == 2 && c.baseline == 8 + 1); // 2.5 → 2
    assert(c.underlineThickness == 2); // 2.5 → 2
    assert(c.underlinePosition == 10); // 9.5 → 10
    s.hheaLineGap = 350;
    s.underlinePosition = -150; // baseline + 1.5
    const d = cell(build(s)).value;
    assert(d.lineGap == 4 && d.baseline == 8 + 2 && d.underlinePosition == 12); // 3.5 → 4; 11.5 → 12
}

@("metrics.FTM19.clamps")
@safe pure nothrow
unittest
{
    Spec s;
    s.advances = [0, 20]; // 0.2 px → 0 → 1
    s.hheaDescender = 100; // above the baseline: ceil(−1) → 0
    s.hheaLineGap = -150; // −1.5 → −2 → 0
    s.underlineThickness = 0;
    const c = cell(build(s)).value;
    assert(c.width == 1 && c.descent == 0 && c.lineGap == 0 && c.underlineThickness == 1);
    assert(c.height == c.ascent && c.baseline == c.ascent);
}

@("metrics.FTM19.widthSource")
@safe pure nothrow
unittest
{
    // U+0030 unmapped: OS/2.xAvgCharWidth (500 → 5 px).
    Spec s;
    s.digitZero = 0;
    const c = cell(build(s)).value;
    assert(c.width == 5 && c.widthSource == CellMetrics.WidthSource.averageCharWidth);
    // Mapped: its advance, even when xAvgCharWidth differs.
    Spec t;
    assert(cell(build(t)).value.widthSource == CellMetrics.WidthSource.digitZero);
    assert(cell(build(t)).value.width == 6);
}

@("metrics.FTM19.digitZeroErrorReturned")
@safe pure nothrow
unittest
{
    // Glyph 3's hmtx entry is cut off: the error is returned, not replaced by xAvgCharWidth.
    Spec s;
    s.digitZero = 3;
    s.numberOfHMetrics = 2;
    const e = cell(build(s)).error;
    assert(e.kind == FontErrorKind.truncated && e.tag == Tag("hmtx"));
    // A variable face without HVAR, at nonzero coordinates: the advance
    // is the phantom span (the stored advance here), so the cell is
    // measured, not refused (FTO5).
    Spec v;
    v.variable = true;
    assert(cell(build(v), 10, one).value.width == 6);
}

@("metrics.FTM19.unsupported")
@safe pure nothrow
unittest
{
    // No U+0030 and no OS/2.
    Spec s;
    s.digitZero = 0;
    s.withOs2 = false;
    assert(cell(build(s)).error.kind == FontErrorKind.unsupportedCapability);
    // Absent line metrics: no OS/2 and a zero hhea.
    Spec t;
    t.withOs2 = false;
    t.hheaAscender = t.hheaDescender = 0;
    assert(cell(build(t)).error.kind == FontErrorKind.unsupportedCapability);
    // No post: no underline.
    Spec u;
    u.withPost = false;
    const c = cell(build(u)).value;
    assert(!c.hasUnderline && c.underlinePosition == 0);
    assert(cell(build(u), 0).error.kind == FontErrorKind.badValue);
}

@("metrics.FTM19.variedValues")
@safe pure nothrow
unittest
{
    Spec s;
    s.variable = true;
    s.hvar = hvarTable(store([0, 100]));
    s.mvar = mvarTable([MvarRecord("hasc", 0, 0), MvarRecord("undo", 0, 1)], store([100, -50]));
    // Advance 600 + 100, ascender 800 + 100, gap 0.9 px → 1, baseline 9 + ⌊1 / 2⌋;
    // underline −100 − 50: 9 + 1.5 = 10.5 → 10.
    const c = cell(build(s), 10, one).value;
    assert(c.width == 7 && c.ascent == 9 && c.descent == 2 && c.lineGap == 1 && c.height == 12);
    assert(c.baseline == 9 && c.underlinePosition == 10);
    // At the default, the stored values: 6 px, ascent 8, underline 8 + 1 = 9.
    const d = cell(build(s)).value;
    assert(d.width == 6 && d.ascent == 8 && d.underlinePosition == 9);
}

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

@("metrics.corpus.everyFace")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    size_t faces, varied;
    foreach (entry; dirEntries(fontsPath, SpanMode.shallow))
    {
        if (!entry.name.endsWith(".ttf") && !entry.name.endsWith(".otf"))
            continue;
        const bytes = bundled(baseName(entry.name));
        const opened = openFace(bytes);
        if (!opened.hasValue)
            continue;
        const face = opened.value;
        const inst = face.instance(twelvePoints, null).value;
        ++faces;
        assert(inst.lineMetrics.hasValue && inst.lineMetrics.value.present, entry.name);
        assert(inst.verticalSets.hasValue, entry.name);
        assert(inst.decorations.hasValue, entry.name);
        const cm = face.charMap;
        if (cm.hasValue)
            foreach (ppem; [14, 16, 18])
                assert(inst.cellMetrics(cm.value, ppem).hasValue, entry.name);
        if (!face.fvar.hasValue || !face.has(Tag("HVAR")))
            continue;
        // At every axis maximum, varied metrics and advances read without error.
        UserCoordinate[64] coords;
        size_t n;
        foreach (i; 0 .. face.axes.length)
            coords[n++] = UserCoordinate(face.axes[i].value.axisTag, face.axes[i].value.maxValue);
        const bold = face.instance(twelvePoints, coords[0 .. n]).value;
        if (bold.allZero)
            continue; // every maximum is its default
        ++varied;
        assert(bold.lineMetrics.hasValue && bold.decorations.hasValue, entry.name);
        uint[] gids;
        foreach (gid; 0 .. face.numGlyphs < 200 ? face.numGlyphs : 200)
            gids ~= gid;
        assert(bold.measureRun(gids).hasValue, entry.name);
    }
    assert(faces > 50 && varied > 0);
}

/**
Cell metrics of DejaVu Sans Mono and Maple Mono at 14, 16 and 18 px, derived
by hand from their stored fields:

DejaVu Sans Mono: upem 2048; `fsSelection` 0x40 (no `USE_TYPO_METRICS`),
`hhea` 1901 / −483 / 0 is nonzero, so the `hhea` set; U+0030 → glyph 19,
advance 1233; `post` underline −40, thickness 90.

| px | width 1233·px/2048 | ascent 1901·px/2048 | descent 483·px/2048 | underline px·40/2048 | thickness 90·px/2048 |
| -- | ------------------ | ------------------- | ------------------- | -------------------- | -------------------- |
| 14 | 8.43 → 8           | 12.99 → 13          | 3.30 → 4            | 13 + 0.27 → 13       | 0.62 → 1             |
| 16 | 9.63 → 10          | 14.85 → 15          | 3.77 → 4            | 15 + 0.31 → 15       | 0.70 → 1             |
| 18 | 10.84 → 11         | 16.71 → 17          | 4.25 → 5            | 17 + 0.35 → 17       | 0.79 → 1             |

Gap 0, so height = ascent + descent (17, 19, 22) and baseline = ascent.

Maple Mono NF CN: upem 1000; `fsSelection` 0xC0 sets `USE_TYPO_METRICS`, so
the typographic set 1020 / −300 / 0; U+0030 → glyph 19, advance 600; `post`
underline −155, thickness 50.

| px | width 600·px/1000 | ascent 1020·px/1000 | descent 300·px/1000 | underline px·155/1000 | thickness 50·px/1000 |
| -- | ----------------- | ------------------- | ------------------- | --------------------- | -------------------- |
| 14 | 8.4 → 8           | 14.28 → 15          | 4.2 → 5             | 15 + 2.17 → 17        | 0.7 → 1              |
| 16 | 9.6 → 10          | 16.32 → 17          | 4.8 → 5             | 17 + 2.48 → 19        | 0.8 → 1              |
| 18 | 10.8 → 11         | 18.36 → 19          | 5.4 → 6             | 19 + 2.79 → 22        | 0.9 → 1              |

Heights 20, 22, 25; baseline = ascent.
*/
@("metrics.corpus.handCheckedCells")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    static struct Expected
    {
        uint ppem;
        long width, ascent, descent, height, underline;
    }

    void check(string name, LineMetricsSource source, const(Expected)[] rows)
    {
        const face = openFace(bundled(name)).value;
        const inst = face.instance(twelvePoints, null).value;
        const cm = face.charMap.value;
        foreach (row; rows)
        {
            const c = inst.cellMetrics(cm, row.ppem).value;
            assert(c.lineSource == source && c.widthSource == CellMetrics.WidthSource.digitZero, name);
            assert(c.width == row.width && c.ascent == row.ascent && c.descent == row.descent, name);
            assert(c.lineGap == 0 && c.height == row.height && c.baseline == row.ascent, name);
            assert(c.hasUnderline && c.underlinePosition == row.underline && c.underlineThickness == 1, name);
        }
    }

    check("DejaVuSansMono.ttf", LineMetricsSource.hhea,
        [Expected(14, 8, 13, 4, 17, 13), Expected(16, 10, 15, 4, 19, 15), Expected(18, 11, 17, 5, 22, 17)]);
    check("MapleMono-NF-CN-Regular.ttf", LineMetricsSource.typographic,
        [Expected(14, 8, 15, 5, 20, 17), Expected(16, 10, 17, 5, 22, 19), Expected(18, 11, 19, 6, 25, 22)]);
}
