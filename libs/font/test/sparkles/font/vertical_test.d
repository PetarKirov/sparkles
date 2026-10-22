/**
Vertical metrics at an instance (FTV14, FTM20, FTM21) on hand-built fixtures,
and every bundled face's vertical queries.

Fixtures use 1,000 units per em and one `TEST` axis whose user values equal
their normalized values: at 1.0 a one-region store whose region peaks at 1.0
gives each item its row's delta, at 0.5 half of it.
*/
module sparkles.font.vertical_test;

import std.algorithm.searching : endsWith;
import std.file : dirEntries, SpanMode;
import std.path : baseName;

import sparkles.base.text.layout_units : LayoutUnit;
import sparkles.test_runner.skip : skipTest;

import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.errors : FontErrorKind, Tag;
import sparkles.font.face : Face, openFace;
import sparkles.font.fixtures;
import sparkles.font.instance : axes, Instance, instance, InstanceSize, UserCoordinate;
import sparkles.font.metrics : MvarTag;
import sparkles.font.tables : fvar;
import sparkles.font.units : DesignValue;
import sparkles.font.vertical;

private enum one = 65_536; // 1.0 in F16.16
private enum short f2one = 16_384; // 1.0 in F2Dot14
private enum ushort upem = 1_000;

private immutable twelvePoints = InstanceSize.physical(LayoutUnit(12 * LayoutUnit.ticksPerPoint));

/// What a fixture face holds; `null` tables are left out.
private struct Spec
{
    uint numGlyphs = 4;
    const(ubyte)[] vhea, vmtx, vorg, vvar, mvar;
    bool variable = true;
    bool glyf;
}

/// A face with `vhea` for 4 glyphs, all long metrics, and the advances 1000, 900, 800, 700.
private Spec standard() @safe pure nothrow
{
    Spec s;
    s.vhea = vheaTable(4, 880, -120, 50);
    s.vmtx = vmtxTable([[1000, 10], [900, 20], [800, 30], [700, 40]]);
    return s;
}

private ubyte[] build(Spec s) @safe pure nothrow
{
    auto tables = minimalTables(s.numGlyphs);
    tables[1] = TableData("head", head(upem));
    if (s.vhea !is null)
        tables ~= TableData("vhea", s.vhea);
    if (s.vmtx !is null)
        tables ~= TableData("vmtx", s.vmtx);
    if (s.vorg !is null)
        tables ~= TableData("VORG", s.vorg);
    if (s.vvar !is null)
        tables ~= TableData("VVAR", s.vvar);
    if (s.mvar !is null)
        tables ~= TableData("MVAR", s.mvar);
    if (s.variable)
        tables ~= TableData("fvar", fvarTable([FvarAxis("TEST", -one, 0, one)]));
    if (s.glyf)
    {
        // Glyph 1 has yMax 100; the others are single points at y 0.
        const glyphs = [simpleGlyph([[0, 0, 1]]),
            simpleGlyph([[0, 0, 1], [10, 100, 1]]),
            simpleGlyph([[0, 0, 1]]), simpleGlyph([[0, 0, 1]])];
        tables ~= TableData("loca", locaTable(glyphs));
        tables ~= TableData("glyf", glyfTable(glyphs));
    }
    return sfnt(tables);
}

/// The instance of `bytes` at `TEST` = `coord` (F16.16).
private Instance at(const(ubyte)[] bytes, int coord = 0) @safe pure nothrow
{
    const face = openFace(bytes).value;
    auto r = face.instance(twelvePoints, [UserCoordinate(Tag("TEST"), coord)]);
    assert(r.hasValue);
    return r.value;
}

/// One axis, one region peaking at 1.0, one data subtable whose item `i` has delta `deltas[i]`.
private ubyte[] store(const(int)[] deltas) @safe pure nothrow
{
    int[][] rows;
    foreach (d; deltas)
        rows ~= [d];
    return itemVariationStore(1, [[[0, f2one, f2one]]], [VarData([0], 1, false, rows)]);
}

private DesignValue du(long units) @safe pure nothrow @nogc => DesignValue(units * 65_536, upem);

// ---------------------------------------------------------------------------
// vhea and vertical line metrics (FTM20)
// ---------------------------------------------------------------------------

@("vertical.vhea.versions")
@safe pure nothrow
unittest
{
    auto s = standard();
    const v10 = vhea(openFace(build(s)).value);
    assert(v10.value.version_ == 0x0001_0000 && v10.value.ascender == 880 && v10.value.numOfLongVerMetrics == 4);
    s.vhea = vheaTable(4, 880, -120, 50, 0x0001_1000);
    assert(vhea(openFace(build(s)).value).value.descender == -120); // 1.1: vertTypo… as stored
    s.vhea = vheaTable(4, 880, -120, 50, 0x0002_0000);
    assert(vhea(openFace(build(s)).value).error.kind == FontErrorKind.unsupportedVersion);
    s.vhea = vheaTable(4)[0 .. 35];
    assert(vhea(openFace(build(s)).value).error.kind == FontErrorKind.truncated);
    s.vhea = null;
    assert(vhea(openFace(build(s)).value).error.kind == FontErrorKind.missingTable);
}

@("vertical.verticalLineMetrics.stored")
@safe pure nothrow
unittest
{
    const l = at(build(standard())).verticalLineMetrics.value;
    assert(l.present && l.ascender.design == du(880) && l.descender.design == du(-120)
        && l.lineGap.design == du(50));
}

@("vertical.verticalLineMetrics.absenceAndZero")
@safe pure nothrow
unittest
{
    auto s = standard();
    s.vhea = null;
    // Missing table: absent, not an error, and no value substituted (FTM12).
    const absent = at(build(s)).verticalLineMetrics;
    assert(absent.hasValue && !absent.value.present);
    // A stored zero is a value.
    s = standard();
    s.vhea = vheaTable(4, 0, 0, 0);
    const zero = at(build(s)).verticalLineMetrics.value;
    assert(zero.present && zero.ascender.design.raw == 0 && zero.lineGap.design.raw == 0);
    // An unreadable vhea is its error.
    s.vhea = vheaTable(4, 0, 0, 0, 0x0003_0000);
    assert(at(build(s)).verticalLineMetrics.error.kind == FontErrorKind.unsupportedVersion);
}

@("vertical.verticalLineMetrics.mvar")
@safe pure nothrow
unittest
{
    auto s = standard();
    s.mvar = mvarTable([MvarRecord("vasc", 0, 0), MvarRecord("vdsc", 0, 1), MvarRecord("vlgp", 0, 2)],
        store([20, -10, 6]));
    const full = at(build(s), one).verticalLineMetrics.value;
    assert(full.ascender.design == du(900) && full.descender.design == du(-130) && full.lineGap.design == du(56));
    const half = at(build(s), one / 2).verticalLineMetrics.value;
    assert(half.ascender.design == du(890) && half.lineGap.design == du(53));
    // FTM14: a broken MVAR is not read at the default, and fails every value elsewhere.
    s.mvar = mvarTable([MvarRecord("vasc", 0, 0)], store([20]), 8, 2);
    assert(at(build(s)).verticalLineMetrics.value.ascender.design == du(880));
    assert(at(build(s), one).verticalLineMetrics.error.kind == FontErrorKind.unsupportedVersion);
    static assert(MvarTag.verticalAscender == Tag("vasc"));
}

// ---------------------------------------------------------------------------
// vmtx with FTP24's leniency (FTM20)
// ---------------------------------------------------------------------------

@("vertical.vmtx.leniency")
@safe pure nothrow
unittest
{
    Spec s;
    // numOfLongVerMetrics 9 > numGlyphs 4: read as 4.
    s.vhea = vheaTable(9);
    s.vmtx = vmtxTable([[1000, 1], [900, 2], [800, 3], [700, 4]]);
    const wide = vmtx(openFace(build(s)).value).value;
    assert(wide.numOfLongVerMetrics == 4 && wide.advance(3).value == 700);
    // Past numOfLongVerMetrics: the last advance repeats, the bearing is the glyph's own.
    s.vhea = vheaTable(2);
    s.vmtx = vmtxTable([[1000, 1], [900, 2]], [-7, 8]);
    const short_ = vmtx(openFace(build(s)).value).value;
    assert(short_.metric(2).value == VerticalMetric(900, -7));
    assert(short_.metric(3).value == VerticalMetric(900, 8));
    // A truncated entry fails its glyph only.
    s.vmtx = vmtxTable([[1000, 1], [900, 2]], [-7]);
    const cut = vmtx(openFace(build(s)).value).value;
    assert(cut.metric(2).hasValue);
    const e = cut.metric(3).error;
    assert(e.kind == FontErrorKind.truncated && e.tag == Tag("vmtx") && e.tableOffset == 10);
    // A caller index past numGlyphs.
    assert(cut.metric(4).error.kind == FontErrorKind.indexOutOfRange);
    // No long metrics in a face with glyphs.
    s.vhea = vheaTable(0);
    assert(vmtx(openFace(build(s)).value).error.kind == FontErrorKind.badValue);
}

// ---------------------------------------------------------------------------
// verticalAdvance (FTM20, FTV14)
// ---------------------------------------------------------------------------

@("vertical.verticalAdvance.default")
@safe pure nothrow
unittest
{
    auto s = standard();
    const a = at(build(s)).verticalAdvance(1).value;
    assert(a.present && a.advance.design == du(900));
    // FTM14: at the default no VVAR is read, so a broken or missing one cannot fail it.
    s.vvar = vvarTable(store([1]), null, null, 2);
    assert(at(build(s)).verticalAdvance(1).value.advance.design == du(900));
    assert(at(build(standard())).verticalAdvance(4).error.kind == FontErrorKind.indexOutOfRange);
}

@("vertical.verticalAdvance.absent")
@safe pure nothrow
unittest
{
    auto s = standard();
    s.vmtx = null;
    const noVmtx = at(build(s), one).verticalAdvance(1);
    assert(noVmtx.hasValue && !noVmtx.value.present);
    s = standard();
    s.vhea = null;
    assert(!at(build(s)).verticalAdvance(1).value.present);
    // A zero advance is a value.
    s = standard();
    s.vmtx = vmtxTable([[0, 0], [0, 0], [0, 0], [0, 0]]);
    const zero = at(build(s)).verticalAdvance(2).value;
    assert(zero.present && zero.advance.design.raw == 0);
}

@("vertical.verticalAdvance.vvar")
@safe pure nothrow
unittest
{
    auto s = standard();
    // Identity map: glyph g takes item g.
    s.vvar = vvarTable(store([0, 40, -80, -1_000]));
    assert(at(build(s), one).verticalAdvance(1).value.advance.design == du(940));
    assert(at(build(s), one / 2).verticalAdvance(2).value.advance.design == du(760));
    // A varied advance below zero is kept.
    assert(at(build(s), one).verticalAdvance(3).value.advance.design == du(-300));
    // An advance map: glyph 1 → item 2.
    s.vvar = vvarTable(store([0, 40, -80]), deltaSetIndexMap([[0, 0], [0, 2]], 4, 1));
    assert(at(build(s), one).verticalAdvance(1).value.advance.design == du(820));
}

@("vertical.verticalAdvance.vvarErrors")
@safe pure nothrow
unittest
{
    auto s = standard();
    // No VVAR at nonzero coordinates: phantom points are M3's.
    const none = at(build(s), one).verticalAdvance(1).error;
    assert(none.kind == FontErrorKind.unsupportedCapability && none.tag == Tag("VVAR"));
    s.vvar = vvarTable(store([1]), null, null, 2);
    assert(at(build(s), one).verticalAdvance(1).error.kind == FontErrorKind.unsupportedVersion);
    s.vvar = vvarTable(null);
    assert(at(build(s), one).verticalAdvance(1).error.kind == FontErrorKind.badValue);
    s.vvar = vvarTable(store([1]))[0 .. 23];
    assert(at(build(s), one).verticalAdvance(1).error.kind == FontErrorKind.truncated);
}

// ---------------------------------------------------------------------------
// verticalOrigin (FTM21)
// ---------------------------------------------------------------------------

@("vertical.verticalOrigin.vorgBinarySearch")
@safe pure nothrow
unittest
{
    auto s = standard();
    s.vorg = vorgTable(880, [[1, 900], [3, 0]]);
    const inst = at(build(s));
    const hit = inst.verticalOrigin(1).value;
    assert(hit.source == VerticalOriginSource.vorgRecord && hit.y.design == du(900) && !hit.varied);
    const miss = inst.verticalOrigin(2).value;
    assert(miss.source == VerticalOriginSource.vorgDefault && miss.y.design == du(880));
    assert(inst.verticalOrigin(0).value.source == VerticalOriginSource.vorgDefault);
    // A record of zero is a value, not the default.
    const zero = inst.verticalOrigin(3).value;
    assert(zero.present && zero.source == VerticalOriginSource.vorgRecord && zero.y.design.raw == 0);
    assert(inst.verticalOrigin(4).error.kind == FontErrorKind.indexOutOfRange);
    // The view itself.
    const v = vorg(inst.face).value;
    assert(v.defaultVertOriginY == 880 && v.numVertOriginYMetrics == 2);
    assert(v.originY(3) == VorgValue(0, true) && v.originY(9) == VorgValue(880, false));
}

@("vertical.verticalOrigin.vorgErrors")
@safe pure nothrow
unittest
{
    auto s = standard();
    s.vorg = vorgTable(880, [[1, 900]], 1, 1);
    assert(at(build(s)).verticalOrigin(1).error.kind == FontErrorKind.unsupportedVersion);
    s.vorg = vorgTable(880, [[1, 900]], 2, 0);
    assert(at(build(s)).verticalOrigin(1).error.kind == FontErrorKind.unsupportedVersion);
    s.vorg = vorgTable(880, [[1, 900]])[0 .. 10];
    assert(at(build(s)).verticalOrigin(1).error.kind == FontErrorKind.truncated);
    s.vorg = vorgTable(880, null)[0 .. 6];
    assert(at(build(s)).verticalOrigin(1).error.kind == FontErrorKind.truncated);
}

@("vertical.verticalOrigin.noVorg")
@safe pure nothrow
unittest
{
    auto s = standard();
    // vmtx and glyf: the M3 rule — top side bearing (20) plus yMax (100).
    s.glyf = true;
    const fallback = at(build(s)).verticalOrigin(1);
    assert(fallback.hasValue && fallback.value.source == VerticalOriginSource.vmtxGlyph
        && fallback.value.y.design == du(120));
    // vmtx without glyf (a CFF face), or glyf without vmtx: absent, never synthesized.
    s.glyf = false;
    const cff = at(build(s)).verticalOrigin(1);
    assert(cff.hasValue && !cff.value.present && cff.value.source == VerticalOriginSource.none);
    s.glyf = true;
    s.vmtx = null;
    assert(!at(build(s)).verticalOrigin(1).value.present);
}

@("vertical.verticalOrigin.vvar")
@safe pure nothrow
unittest
{
    auto s = standard();
    s.vorg = vorgTable(880, [[1, 900]]);
    // Origin map: glyph g → item g of [0, 30, -50, 0].
    s.vvar = vvarTable(store([0, 30, -50, 0]), null, deltaSetIndexMap([[0, 0], [0, 1], [0, 2], [0, 3]], 4, 1));
    const rec = at(build(s), one).verticalOrigin(1).value;
    assert(rec.source == VerticalOriginSource.vorgRecord && rec.varied && rec.y.design == du(930));
    const def = at(build(s), one / 2).verticalOrigin(2).value;
    assert(def.source == VerticalOriginSource.vorgDefault && def.y.design == du(855));
    // FTM14: at the default nothing is read.
    const flat = at(build(s)).verticalOrigin(1).value;
    assert(!flat.varied && flat.y.design == du(900));
    // A VVAR without an origin map adds nothing; nor does a missing VVAR.
    s.vvar = vvarTable(store([0, 30]));
    const noMap = at(build(s), one).verticalOrigin(1).value;
    assert(!noMap.varied && noMap.y.design == du(900));
    s.vvar = null;
    assert(at(build(s), one).verticalOrigin(1).value.y.design == du(900));
    // An unreadable VVAR is its error.
    s.vvar = vvarTable(store([0]), null, null, 3);
    assert(at(build(s), one).verticalOrigin(1).error.kind == FontErrorKind.unsupportedVersion);
    s.vvar = vvarTable(null, null, deltaSetIndexMap([[0, 0]], 4, 1));
    assert(at(build(s), one).verticalOrigin(1).error.kind == FontErrorKind.badValue);
}

// ---------------------------------------------------------------------------
// Hostile input (FTB1, FTB2)
// ---------------------------------------------------------------------------

@("vertical.hostile.truncations")
@safe pure nothrow
unittest
{
    // Every prefix of every table: a value or an error, never an assertion.
    const fullVhea = vheaTable(4, 880, -120, 50);
    const fullVmtx = vmtxTable([[1000, 10], [900, 20], [800, 30], [700, 40]]);
    const fullVorg = vorgTable(880, [[1, 900], [2, 800], [3, 700]]);
    const fullVvar = vvarTable(store([0, 30, -50, 0]), deltaSetIndexMap([[0, 0], [0, 1]], 4, 1),
        deltaSetIndexMap([[0, 3], [0, 2]], 4, 1));
    const fullMvar = mvarTable([MvarRecord("vasc", 0, 0)], store([20]));
    foreach (which; 0 .. 5)
    {
        const full = [fullVhea, fullVmtx, fullVorg, fullVvar, fullMvar][which];
        foreach (n; 0 .. full.length)
        {
            Spec s = standard();
            s.vorg = fullVorg;
            s.vvar = fullVvar;
            s.mvar = fullMvar;
            const cut = full[0 .. n];
            final switch (which)
            {
                case 0: s.vhea = cut; break;
                case 1: s.vmtx = cut; break;
                case 2: s.vorg = cut; break;
                case 3: s.vvar = cut; break;
                case 4: s.mvar = cut; break;
            }
            foreach (coord; [0, one / 2, one])
            {
                const inst = at(build(s), coord);
                cast(void) inst.verticalLineMetrics;
                foreach (gid; 0 .. 5)
                {
                    cast(void) inst.verticalAdvance(gid);
                    cast(void) inst.verticalOrigin(gid);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

/**
Every bundled face's vertical queries give a defined outcome: a value, an
absence, or an error of the kinds FTM20 and FTM21 name. The bundle's vertical
faces (Noto CFF faces with `VORG`, Noto TrueType faces with `VVAR`) are
checked to report present values; a real `BASE`-and-vertical face remains an
acquisition prerequisite (`testing.md`).
*/
@("vertical.corpus.everyFace")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    size_t faces, withVhea, withVorg, varied;
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
        const lines = inst.verticalLineMetrics;
        assert(lines.hasValue && lines.value.present == face.has(Tag("vhea")), entry.name);
        const hasVertical = face.has(Tag("vhea")) && face.has(Tag("vmtx"));
        withVhea += hasVertical;
        withVorg += face.has(Tag("VORG"));
        const limit = face.numGlyphs < 300 ? face.numGlyphs : 300;
        foreach (gid; 0 .. limit)
        {
            const a = inst.verticalAdvance(gid);
            assert(a.hasValue && a.value.present == hasVertical, entry.name);
            const o = inst.verticalOrigin(gid);
            if (face.has(Tag("VORG")))
                assert(o.hasValue && o.value.present, entry.name);
            else if (face.has(Tag("vmtx")) && face.has(Tag("glyf")))
                // The M3 fallback: an origin from the outline, present
                // exactly when the glyph has points.
                assert(o.hasValue && (o.value.present
                    ? o.value.source == VerticalOriginSource.vmtxGlyph : true), entry.name);
            else
                assert(o.hasValue && !o.value.present, entry.name);
        }
        if (!face.fvar.hasValue || !face.has(Tag("VVAR")))
            continue;
        UserCoordinate[64] coords;
        size_t n;
        foreach (i; 0 .. face.axes.length)
            coords[n++] = UserCoordinate(face.axes[i].value.axisTag, face.axes[i].value.maxValue);
        const bold = face.instance(twelvePoints, coords[0 .. n]).value;
        if (bold.allZero)
            continue;
        ++varied;
        foreach (gid; 0 .. limit)
            assert(bold.verticalAdvance(gid).hasValue, entry.name);
    }
    assert(faces > 50 && withVhea > 0 && withVorg > 0 && varied > 0);
}
