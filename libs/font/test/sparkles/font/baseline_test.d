/**
Baselines and extents (FTM22–FTM24) on hand-built `BASE` tables, hostile
truncations and corruptions of them, and every bundled face.

Fixtures use 1,000 units per em and one `TEST` axis whose user values equal
their normalized values: at 1.0 a one-region store whose region peaks at 1.0
gives each item its row's delta, at 0.5 half of it.
*/
module sparkles.font.baseline_test;

import std.algorithm.searching : endsWith;
import std.file : dirEntries, SpanMode;
import std.path : baseName;

import sparkles.base.text.layout_units : I128, LayoutUnit, Rational, U128;
import sparkles.test_runner.skip : skipTest;

import sparkles.font.baseline;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.errors : FontErrorKind, Tag;
import sparkles.font.face : Face, openFace;
import sparkles.font.fixtures;
import sparkles.font.instance : Instance, instance, InstanceSize, UserCoordinate;
import sparkles.font.units : DesignValue, Ppem;

private enum one = 65_536; // 1.0 in F16.16
private enum short f2one = 16_384; // 1.0 in F2Dot14
private enum ushort upem = 1_000;

private immutable twelvePoints = InstanceSize.physical(LayoutUnit(12 * LayoutUnit.ticksPerPoint));

private enum horizontal = BaselineAxis.horizontal, vertical = BaselineAxis.vertical;
private enum hang = Tag("hang"), ideo = Tag("ideo"), romn = Tag("romn"), math = Tag("math");
private enum latn = Tag("latn"), cyrl = Tag("cyrl"), grek = Tag("grek"), dflt = Tag("DFLT");

private BaseCoordSpec c1(int coordinate) @safe pure nothrow @nogc => BaseCoordSpec(1, coordinate);

/// One axis, one region peaking at 1.0, one data subtable whose item `i` has delta `deltas[i]`.
private ubyte[] store(const(int)[] deltas) @safe pure nothrow
{
    int[][] rows;
    foreach (d; deltas)
        rows ~= [d];
    return itemVariationStore(1, [[[0, f2one, f2one]]], [VarData([0], 1, false, rows)]);
}

/**
The standard horizontal axis: tags `hang`, `ideo`, `romn`; scripts `DFLT`
(1400, -100, 0), `cyrl` (no BaseValues, no MinMax) and `latn` (1500, -120, 0;
default MinMax -300..1100 with feature `smcp` -310..1110 and `zzzz` with a
null minimum; languages `DEU ` -250..1050 and `TRK ` with a null MinMax).
*/
private BaseAxisSpec standardAxis() @safe pure nothrow
{
    const defaultMinMax = MinMaxSpec(MinMaxPair(true, c1(-300), true, c1(1_100)),
        [FeatMinMaxSpec("smcp", MinMaxPair(true, c1(-310), true, c1(1_110))),
            FeatMinMaxSpec("zzzz", MinMaxPair(false, BaseCoordSpec.init, true, c1(1_200)))]);
    const deu = LangSysSpec("DEU ", MinMaxSpec(MinMaxPair(true, c1(-250), true, c1(1_050))));
    const trk = LangSysSpec("TRK ", MinMaxSpec(MinMaxPair.init));
    return BaseAxisSpec(["hang", "ideo", "romn"], [
        BaseScriptSpec("DFLT", true, 2, [c1(1_400), c1(-100), c1(0)]),
        BaseScriptSpec("cyrl"),
        BaseScriptSpec("latn", true, 2, [c1(1_500), c1(-120), c1(0)], true, defaultMinMax, [deu, trk]),
    ]);
}

/// A face holding `base` (when not null) and, when `variable`, the `TEST` axis.
private ubyte[] build(const(ubyte)[] base, bool variable = true) @safe pure nothrow
{
    auto tables = minimalTables(4);
    tables[1] = TableData("head", head(upem));
    if (base !is null)
        tables ~= TableData("BASE", base);
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

/// `bytes` with the 16-bit field right after the first occurrence of `tag` (+ `skip` bytes) set to `value`.
private ubyte[] patchAfter(const(ubyte)[] bytes, string tag, uint value, size_t skip = 0) @safe pure nothrow
{
    auto r = bytes.dup;
    foreach (i; 0 .. r.length - 4)
        if (r[i .. i + 4] == cast(const(ubyte)[]) tag)
        {
            r[i + 4 + skip] = cast(ubyte)(value >> 8);
            r[i + 5 + skip] = cast(ubyte) value;
            return r;
        }
    assert(0, "tag not found");
}

// ---------------------------------------------------------------------------
// The BASE view (FTM22)
// ---------------------------------------------------------------------------

@("baseline.base.versions")
@safe pure nothrow
unittest
{
    const axis = [standardAxis()];
    const v10 = base(openFace(build(baseTable(axis, null))).value, 1).value;
    assert(v10.majorVersion == 1 && v10.minorVersion == 0 && !v10.variationStore.present);
    const v11 = base(openFace(build(baseTable(axis, null, store([5]), 1))).value, 1).value;
    assert(v11.variationStore.present && !v11.variationStore.broken);
    // A later minor is read as 1.1: the store offset is there.
    const v12 = base(openFace(build(baseTable(axis, null, store([5]), 2))).value, 1).value;
    assert(v12.minorVersion == 2 && v12.variationStore.present);
    const v2 = base(openFace(build(baseTable(axis, null, null, 0, 2))).value, 1);
    assert(v2.error.kind == FontErrorKind.unsupportedVersion);
    assert(base(openFace(build(baseTable(null, null)[0 .. 7])).value, 1).error.kind == FontErrorKind.truncated);
    assert(base(openFace(build(baseTable(null, null, null, 1)[0 .. 11])).value, 1).error.kind
        == FontErrorKind.truncated);
    assert(base(openFace(build(null)).value, 1).error.kind == FontErrorKind.missingTable);
}

@("baseline.baselineTags.range")
@safe pure nothrow
unittest
{
    const inst = at(build(baseTable([standardAxis()], null)));
    auto tags = inst.baselineTags(horizontal).value;
    assert(tags.axisPresent && tags.length == 3);
    assert(tags.front == hang && tags.back == romn && tags[1] == ideo);
    tags.popFront();
    tags.popBack();
    assert(tags.length == 1 && tags.front == ideo);
    // No such axis: absent, an empty range.
    const none = inst.baselineTags(vertical).value;
    assert(!none.axisPresent && none.empty);
    assert(at(build(null)).baselineTags(horizontal).error.kind == FontErrorKind.missingTable);
    // A tag list past the table is that list's error; the script list stays readable.
    const broken = at(build(baseTable([BaseAxisSpec(["hang", "romn"], [BaseScriptSpec("latn", true, 0,
        [c1(5), c1(6)])])], null)[0 .. 8 + 4 + 2 + 4]));
    assert(broken.baselineTags(horizontal).error.kind == FontErrorKind.truncated);
}

@("baseline.scripts.badOffsetEntry")
@safe pure nothrow
unittest
{
    // FTA11: the `cyrl` record points past the table; DFLT and latn stay readable.
    const bytes = patchAfter(baseTable([standardAxis()], null), "cyrl", 0xFFF0);
    const face = openFace(build(bytes)).value;
    const scripts = base(face, 1).value.axis(horizontal).value.scripts.value;
    assert(scripts.length == 3);
    assert(scripts[0].value == dflt && scripts[2].value == latn);
    assert(scripts[1].error.kind == FontErrorKind.badOffset);
    const inst = at(build(bytes));
    assert(inst.baseline(horizontal, cyrl, romn).error.kind == FontErrorKind.badOffset);
    assert(inst.baseline(horizontal, latn, hang).value.value.coordinate.design == du(1_500));
}

// ---------------------------------------------------------------------------
// baseline (FTM23)
// ---------------------------------------------------------------------------

@("baseline.FTM23.absences")
@safe pure nothrow
unittest
{
    assert(at(build(null)).baseline(horizontal, latn, romn).error.kind == FontErrorKind.missingTable);
    const inst = at(build(baseTable([standardAxis()], null)));
    // No such axis.
    const noAxis = inst.baseline(vertical, latn, romn).value;
    assert(!noAxis.present && noAxis.script == ScriptSource.none);
    // The script record has no BaseValues: absent, not DFLT's values.
    const noValues = inst.baseline(horizontal, cyrl, romn).value;
    assert(!noValues.present && noValues.script == ScriptSource.requested && !noValues.hasBaseValues);
    // A tag not in the tag list: absent, and defaultIndex is reported, not used.
    const noTag = inst.baseline(horizontal, latn, math).value;
    assert(!noTag.present && noTag.hasBaseValues && noTag.defaultIndex == 2);
    // Neither the script nor DFLT has a record.
    auto axis = standardAxis();
    axis.scripts = axis.scripts[1 .. $];
    const noDflt = at(build(baseTable([axis], null))).baseline(horizontal, grek, romn).value;
    assert(!noDflt.present && noDflt.script == ScriptSource.none);
}

@("baseline.FTM23.scriptAndDflt")
@safe pure nothrow
unittest
{
    const inst = at(build(baseTable([standardAxis()], null)));
    const own = inst.baseline(horizontal, latn, ideo).value;
    assert(own.present && own.script == ScriptSource.requested && own.value.format == 1);
    assert(own.value.coordinate.design == du(-120) && !own.value.unresolvedPoint && !own.value.hasDevice);
    const fallback = inst.baseline(horizontal, grek, hang).value;
    assert(fallback.present && fallback.script == ScriptSource.defaultScript);
    assert(fallback.value.coordinate.design == du(1_400));
    // A zero coordinate is a value.
    const zero = inst.baseline(horizontal, latn, romn).value;
    assert(zero.present && zero.value.coordinate.design.raw == 0);
}

@("baseline.FTM23.indexPastCoordinates")
@safe pure nothrow
unittest
{
    // FTM13: a tag index from the font past BaseValues' coordinate count.
    const axis = BaseAxisSpec(["hang", "ideo", "romn"], [BaseScriptSpec("latn", true, 0, [c1(5)])]);
    const inst = at(build(baseTable([axis], null)));
    assert(inst.baseline(horizontal, latn, hang).value.value.coordinate.design == du(5));
    const e = inst.baseline(horizontal, latn, romn).error;
    assert(e.kind == FontErrorKind.badValue && e.tag == Tag("BASE"));
}

@("baseline.FTM23.formats")
@safe pure nothrow
unittest
{
    const axis = BaseAxisSpec(["hang", "ideo", "math", "romn"], [BaseScriptSpec("DFLT", true, 3, [
        BaseCoordSpec(2, 700, 42, 3),
        BaseCoordSpec(3, -80),
        BaseCoordSpec(4, 9),
        BaseCoordSpec(3, 0, 0, 0, deviceTable(10, 12, 2, [1, -2, 3])),
    ])]);
    const bytes = build(baseTable(null, [axis]));
    const inst = at(bytes);
    const f2 = inst.baseline(vertical, latn, hang).value.value;
    assert(f2.format == 2 && f2.coordinate.design == du(700) && f2.referenceGlyph == 42 && f2.pointIndex == 3);
    assert(f2.unresolvedPoint);
    // Format 3 without a device table: the coordinate alone.
    const f3 = inst.baseline(vertical, latn, ideo).value.value;
    assert(f3.format == 3 && !f3.hasDevice && f3.coordinate.design == du(-80));
    assert(inst.baseline(vertical, latn, math).error.kind == FontErrorKind.unsupportedVersion);
    // A Device table: only at an integer ppem inside its range, and only in pixels.
    const design = inst.baseline(vertical, latn, romn).value.value;
    assert(design.hasDevice && !design.device.deviceApplied && design.coordinate.design.raw == 0);
    const at11 = at(bytes, 0, px(11)).baseline(vertical, latn, romn).value.value;
    assert(at11.device.deviceApplied && at11.device.devicePixels == -2);
    assert(at11.coordinate.design.raw == 0 && at11.pixels.value == -2.0);
    const at13 = at(bytes, 0, px(13)).baseline(vertical, latn, romn).value.value;
    assert(!at13.device.deviceApplied && at13.pixels.value == 0.0);
    const half = at(bytes, 0, InstanceSize.pixels(Ppem.fromRational(Rational(I128(U128(23, 0)), U128(2, 0))).value));
    assert(!half.baseline(vertical, latn, romn).value.value.device.deviceApplied);
}

@("baseline.FTM23.variationIndex")
@safe pure nothrow
unittest
{
    const axis = BaseAxisSpec(["romn"], [BaseScriptSpec("DFLT", true, 0,
        [BaseCoordSpec(3, 100, 0, 0, variationIndexTable(0, 1))])]);
    const bytes = build(baseTable([axis], null, store([0, 40]), 1));
    // Review trace 4: the same coordinate with and without a ppem.
    const physical = at(bytes, one).baseline(horizontal, latn, romn).value.value;
    const pixel = at(bytes, one, px(20)).baseline(horizontal, latn, romn).value.value;
    assert(physical.coordinate.design == du(140) && pixel.coordinate.design == du(140));
    assert(physical.device.variation == du(40) && !pixel.device.deviceApplied);
    assert(pixel.pixels.value == 2.8);
    assert(at(bytes, one / 2).baseline(horizontal, latn, romn).value.value.coordinate.design == du(120));
    // FTM14: at the default nothing is read.
    assert(at(bytes).baseline(horizontal, latn, romn).value.value.coordinate.design == du(100));

    // BASE 1.0 has no store: a VariationIndex there is badValue at nonzero coordinates.
    const v10 = build(baseTable([axis], null));
    assert(at(v10, one).baseline(horizontal, latn, romn).error.kind == FontErrorKind.badValue);
    assert(at(v10).baseline(horizontal, latn, romn).value.value.coordinate.design == du(100));
    // A store whose axis count is not fvar's.
    const wrongAxes = build(baseTable([axis], null, itemVariationStore(2, [[[0, f2one, f2one], [0, 0, 0]]],
        [VarData([0], 1, false, [[0], [40]])]), 1));
    assert(at(wrongAxes, one).baseline(horizontal, latn, romn).error.kind == FontErrorKind.badValue);
}

// ---------------------------------------------------------------------------
// extents (FTM24)
// ---------------------------------------------------------------------------

@("baseline.FTM24.records")
@safe pure nothrow
unittest
{
    const inst = at(build(baseTable([standardAxis()], null)));
    // The language's record.
    const deu = inst.extents(horizontal, latn, Tag("DEU "), Tag.init).value;
    assert(deu.present && deu.record == MinMaxSource.language && deu.script == ScriptSource.requested);
    assert(deu.min.value.coordinate.design == du(-250) && deu.max.value.coordinate.design == du(1_050));
    // No language record: the script's default.
    const fra = inst.extents(horizontal, latn, Tag("FRA "), Tag.init).value;
    assert(fra.record == MinMaxSource.scriptDefault && !fra.fromFeature);
    assert(fra.min.value.coordinate.design == du(-300) && fra.max.value.coordinate.design == du(1_100));
    // The feature's record within it.
    const smcp = inst.extents(horizontal, latn, Tag.init, Tag("smcp")).value;
    assert(smcp.fromFeature && smcp.min.value.coordinate.design == du(-310));
    // A feature without a record: the record's own values.
    assert(inst.extents(horizontal, latn, Tag.init, Tag("liga")).value.max.value.coordinate.design == du(1_100));
    // A null minimum: absent, never zero.
    const zzzz = inst.extents(horizontal, latn, Tag.init, Tag("zzzz")).value;
    assert(zzzz.fromFeature && zzzz.min.absent && !zzzz.min.hasValue && zzzz.max.value.coordinate.design
        == du(1_200));
    // A language whose MinMax has null offsets: both absent.
    const trk = inst.extents(horizontal, latn, Tag("TRK "), Tag.init).value;
    assert(trk.record == MinMaxSource.language && trk.min.absent && trk.max.absent);
}

@("baseline.FTM24.absences")
@safe pure nothrow
unittest
{
    assert(at(build(null)).extents(horizontal, latn, Tag.init, Tag.init).error.kind == FontErrorKind.missingTable);
    const inst = at(build(baseTable([standardAxis()], null)));
    const noAxis = inst.extents(vertical, latn, Tag.init, Tag.init).value;
    assert(!noAxis.present && noAxis.script == ScriptSource.none);
    // DFLT has no default MinMax: absent, with DFLT's provenance.
    const grk = inst.extents(horizontal, grek, Tag.init, Tag.init).value;
    assert(!grk.present && grk.script == ScriptSource.defaultScript);
    const cyr = inst.extents(horizontal, cyrl, Tag.init, Tag.init).value;
    assert(!cyr.present && cyr.script == ScriptSource.requested);
}

@("baseline.FTM24.badOffsets")
@safe pure nothrow
unittest
{
    const bytes = baseTable([standardAxis()], null);
    // The `smcp` minimum points past the table: that value only.
    const smcpMin = at(build(patchAfter(bytes, "smcp", 0xFFF0)));
    const e = smcpMin.extents(horizontal, latn, Tag.init, Tag("smcp")).value;
    assert(e.min.hasError && e.min.error.kind == FontErrorKind.badOffset);
    assert(e.max.value.coordinate.design == du(1_110));
    // The `DEU ` MinMax points past the table: the query's error.
    const deu = at(build(patchAfter(bytes, "DEU ", 0xFFF0)));
    assert(deu.extents(horizontal, latn, Tag("DEU "), Tag.init).error.kind == FontErrorKind.badOffset);
    assert(deu.extents(horizontal, latn, Tag("FRA "), Tag.init).hasValue);
    // A coordinate of another format is that value's error.
    auto axis = standardAxis();
    axis.scripts = [BaseScriptSpec("latn", false, 0, null, true,
        MinMaxSpec(MinMaxPair(true, BaseCoordSpec(7, 1), true, c1(2))))];
    const odd = at(build(baseTable([axis], null))).extents(horizontal, latn, Tag.init, Tag.init).value;
    assert(odd.min.error.kind == FontErrorKind.unsupportedVersion && odd.max.hasValue);
}

// ---------------------------------------------------------------------------
// Hostile input (FTB1, FTB2)
// ---------------------------------------------------------------------------

/// Every query on `bytes` at three coordinates and two sizes: each a value or an error.
private void exercise(const(ubyte)[] bytes) @safe pure nothrow
{
    static immutable Tag[4] scripts = [Tag("latn"), Tag("cyrl"), Tag("grek"), Tag("DFLT")];
    static immutable Tag[4] tags = [Tag("hang"), Tag("ideo"), Tag("romn"), Tag("math")];
    foreach (coord; [0, one])
        foreach (size; [twelvePoints, px(11)])
        {
            const inst = at(bytes, coord, size);
            foreach (axis; [horizontal, vertical])
            {
                const t = inst.baselineTags(axis);
                if (t.hasValue)
                {
                    BaselineTags r = t.value;
                    foreach (tag; r) {}
                }
                foreach (script; scripts)
                {
                    foreach (tag; tags)
                    {
                        const b = inst.baseline(axis, script, tag);
                        if (b.hasValue && b.value.present)
                            cast(void) b.value.value.pixels;
                    }
                    cast(void) inst.extents(axis, script, Tag("DEU "), Tag("smcp"));
                    cast(void) inst.extents(axis, script, Tag.init, Tag.init);
                }
                const view = base(inst.face, inst.axisCount);
                if (view.hasValue)
                {
                    const a = view.value.axis(axis);
                    if (a.hasValue && a.value.scripts.hasValue)
                    {
                        BaseScripts s = a.value.scripts.value;
                        foreach (entry; s)
                            cast(void) entry;
                    }
                }
            }
        }
}

/// A `BASE` 1.1 with both axes, every coordinate format and a store.
private ubyte[] hostileBase() @safe pure nothrow
{
    auto v = standardAxis();
    v.scripts = [BaseScriptSpec("DFLT", true, 0, [BaseCoordSpec(2, 700, 42, 3),
        BaseCoordSpec(3, 0, 0, 0, deviceTable(10, 12, 2, [1, -2, 3])),
        BaseCoordSpec(3, 100, 0, 0, variationIndexTable(0, 0))])];
    return baseTable([standardAxis()], [v], store([40]), 1);
}

@("baseline.hostile.truncations")
@safe pure nothrow
unittest
{
    const full = hostileBase();
    foreach (n; 0 .. full.length)
        exercise(build(full[0 .. n]));
}

@("baseline.hostile.corruptions")
@safe pure nothrow
unittest
{
    // Every byte set to 0xFF, then to 0x00, one at a time.
    const full = hostileBase();
    foreach (i; 0 .. full.length)
        foreach (ubyte v; [0xFF, 0x00])
        {
            auto bytes = full.dup;
            bytes[i] = v;
            exercise(build(bytes));
        }
}

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

/**
Every bundled face's baseline queries give a defined outcome. The bundle has
no `BASE` face, so each is `missingTable`; a verified horizontal/vertical
`BASE` face remains an acquisition prerequisite (`testing.md`).
*/
@("baseline.corpus.everyFace")
@system
unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    size_t faces, withBase;
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
        const has = face.has(Tag("BASE"));
        withBase += has;
        foreach (axis; [horizontal, vertical])
        {
            const t = inst.baselineTags(axis);
            const b = inst.baseline(axis, latn, romn);
            const e = inst.extents(axis, latn, Tag.init, Tag.init);
            if (!has)
                assert(t.error.kind == FontErrorKind.missingTable && b.error.kind == FontErrorKind.missingTable
                    && e.error.kind == FontErrorKind.missingTable, entry.name);
            else
                assert(t.hasValue && b.hasValue && e.hasValue, entry.name);
        }
    }
    assert(faces > 50);
}
