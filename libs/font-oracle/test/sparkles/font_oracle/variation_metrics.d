/**
The M2 variation and metrics differentials (`variation-metrics.md` § 9): for
every bundled face, normalized coordinates (FTV5), advances (FTV12–FTV14,
FTM18), line metrics and decorations (FTM15–FTM17), vertical advances and
origins (FTM20, FTM21), `MATH` values (FTP34–FTP38) and the absence of
`BASE`, against HarfBuzz at a scale of one unit per font unit. Only cases
where the contract and HarfBuzz agree are compared; each listed divergence is
excluded where it arises and counted, and each test prints its counts.

The fontations-exact comparison of variation deltas (`testing.md`'s
fontations oracle) needs a Rust tool and committed goldens and is not here.
*/
module sparkles.font_oracle.variation_metrics;

import std.conv : text;
import std.file : read;
import std.math : lround;
import std.path : baseName;
import std.stdio : stderr;

import sparkles.base.text.layout_units : LayoutUnit;
import sparkles.base.unique : makeUnique;
import sparkles.font;
import sparkles.font_oracle.corpus : corpus, fontsDir, Oracle, testCorpus, testFontsDir;
import sparkles.font_oracle;
import sparkles.font_oracle.harfbuzz_c : hb_direction_t;
import sparkles.test_runner.skip : skipTest;

/// Every instance here is 12 points; the comparisons are in design units.
private enum size = InstanceSize.physical(LayoutUnit(12 * LayoutUnit.ticksPerPoint));

/// One font unit, as a `DesignValue.raw`.
private enum long unit = 65_536;

/// HarfBuzz's tolerance off the default: half a unit for its whole-unit
/// rounding of a delta, plus 1/1024 unit for its single-precision arithmetic.
private enum long halfUnit = unit / 2 + unit / 1024;

/// A tag as HarfBuzz spells it, typed as the enum the call takes.
private T hbTag(T = hb_tag_t)(string s) => cast(T) Tag(s).value;

/**
The F16.16 value nearest `u` that a `float` holds exactly, so that both
implementations normalize the same user value. Every `u / 65,536` below 2²⁴
is exact; a larger one rounds to a multiple of a power of two that is still a
whole number of 1/65,536 units.
*/
private int floatExact(long u) => cast(int) lround(cast(double) cast(float)(u / 65_536.0) * 65_536.0);

/**
The bundled faces with HarfBuzz scaled to font units, then, `withTestCorpus`,
the test corpus's (a collection's first face); `skipTest` when the bundle is
unset.
*/
private void eachFace(scope void delegate(string file, const Face face, ref Oracle hb) @system body_,
    bool withTestCorpus = false)
{
    if (fontsDir is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    foreach (path; withTestCorpus ? corpus ~ testCorpus : corpus)
    {
        const bytes = cast(const(ubyte)[]) read(path);
        auto hb = Oracle(bytes, 0);
        const opened = openFace(bytes);
        assert(opened.hasValue, path.baseName);
        const face = opened.value;
        hb_font_set_scale(hb.font, face.unitsPerEm, face.unitsPerEm);
        body_(path.baseName, face, hb);
    }
}

/// The face's axes, all readable (callers exclude a face whose axes are not).
private VariationAxis[] axisRecords(const Face face)
{
    VariationAxis[] r;
    foreach (a; face.axes)
        r ~= a.hasValue ? a.value : VariationAxis.init;
    return r;
}

/// Whether some tag names two axes (`§ 9` FTV divergence 3).
private bool duplicatedTags(const VariationAxis[] axes)
{
    foreach (i, a; axes)
        foreach (b; axes[i + 1 .. $])
            if (a.axisTag == b.axisTag)
                return true;
    return false;
}

/// The instance at `coordinates`, which must build.
private Instance at(const Face face, const(UserCoordinate)[] coordinates, string file)
{
    const r = face.instance(size, coordinates);
    assert(r.hasValue, file);
    return r.value;
}

/// Points HarfBuzz's font at `inst`'s normalized coordinates.
private void setCoords(ref Oracle hb, in Instance inst)
{
    int[64] c;
    foreach (i, v; inst.coords)
        c[i] = v;
    hb_font_set_var_coords_normalized(hb.font, c.ptr, inst.axisCount);
}

/// The default, each axis at its minimum and its maximum, all minima and all maxima.
private Instance[] extremes(const Face face, const VariationAxis[] axes, string file)
{
    Instance[] r = [at(face, null, file)];
    UserCoordinate[] lows, highs;
    foreach (a; axes)
    {
        r ~= at(face, [UserCoordinate(a.axisTag, a.minValue)], file);
        r ~= at(face, [UserCoordinate(a.axisTag, a.maxValue)], file);
        lows ~= UserCoordinate(a.axisTag, a.minValue);
        highs ~= UserCoordinate(a.axisTag, a.maxValue);
    }
    if (axes.length > 1)
        r ~= [at(face, lows, file), at(face, highs, file)];
    return r;
}

/// Whether `face` is variable, with a readable `fvar`.
private bool variable(const Face face)
{
    const axes = face.axes;
    return !axes.hasError && axes.length > 0;
}

@("oracle.variations.normalize")
@system
unittest
{
    size_t faces, axesCompared, values, defaultOutside, avarCount, avarMap, avarOther, duplicated;
    eachFace((file, face, ref hb) {
        if (!variable(face))
            return;
        foreach (a; face.axes)
            assert(a.hasValue || a.error.kind == FontErrorKind.badValue, file);
        const axes = axisRecords(face);
        // § 9 (1) and (2): an axis whose default lies outside its range, an
        // `avar` whose axis count differs, or a decreasing map is recorded on
        // the default instance, where HarfBuzz pins or applies instead.
        const base = at(face, null, file);
        if (base.recordedErrors > 0)
        {
            const e = base.firstRecordedError;
            if (e.tag == Tag("fvar"))
                ++defaultOutside;
            else if (face.avar.hasValue && face.avar.value.axisCount != axes.length)
                ++avarCount;
            else if (e.tag == Tag("avar"))
                ++avarMap;
            else
                ++avarOther;
            return;
        }
        // § 9 (3): HarfBuzz sets only the first axis of a duplicated tag.
        if (duplicatedTags(axes))
        {
            ++duplicated;
            return;
        }
        assert(hb_ot_var_get_axis_count(hb.face) == axes.length, file);
        ++faces;
        auto design = new float[axes.length];
        auto expected = new int[axes.length];
        foreach (i, a; axes)
        {
            ++axesCompared;
            long[] users = [a.minValue, a.defaultValue, a.maxValue, long(a.minValue) - unit,
                long(a.maxValue) + unit];
            foreach (k; 0 .. 17)
                users ~= a.minValue + (long(a.maxValue) - a.minValue) * k / 16;
            foreach (u; users)
            {
                const user = floatExact(u);
                const inst = at(face, [UserCoordinate(a.axisTag, user)], file);
                foreach (j, b; axes)
                    design[j] = j == i ? user / 65_536.0f : b.defaultValue / 65_536.0f;
                hb_ot_var_normalize_coords(hb.face, cast(uint) axes.length, design.ptr, expected.ptr);
                foreach (j; 0 .. axes.length)
                    assert(inst.coords[j] == expected[j], file);
                ++values;
            }
        }
    });
    stderr.writefln("oracle.variations.normalize: %s faces, %s axes, %s coordinate vectors equal; "
        ~ "excluded faces: %s default outside range, %s avar axis count, %s decreasing avar map, "
        ~ "%s other avar, %s duplicated tags",
        faces, axesCompared, values, defaultOutside, avarCount, avarMap, avarOther, duplicated);
    assert(faces > 0 && values > 0);
}

@("oracle.metrics.advances")
@system
unittest
{
    auto ws = makeUnique!PointWorkspace();
    size_t faces, variableFaces, instances, exact, near, varied, clamped, unsupported, otherErrors;
    eachFace((file, face, ref hb) {
        ++faces;
        Instance[] insts;
        const stored = face.hmtx.value;
        if (variable(face) && at(face, null, file).recordedErrors == 0)
        {
            ++variableFaces;
            insts = extremes(face, axisRecords(face), file);
        }
        else
            insts = [at(face, null, file)];
        foreach (inst; insts)
        {
            ++instances;
            setCoords(hb, inst);
            foreach (gid; 0 .. face.numGlyphs)
            {
                const ours = inst.advance(gid, *ws);
                const theirs = hb_font_get_glyph_h_advance(hb.font, gid);
                if (inst.allZero)
                {
                    // FTM14: at the default the stored advance, exactly.
                    assert(ours.hasValue, file);
                    assert(ours.value.design.raw == theirs * unit, file);
                    ++exact;
                    continue;
                }
                // § 9 (2): HarfBuzz falls back to phantom points without (or for
                // a malformed) HVAR; this page reports the error.
                if (ours.hasError)
                {
                    if (ours.error.kind == FontErrorKind.unsupportedCapability)
                        ++unsupported;
                    else
                        ++otherErrors;
                    continue;
                }
                const raw = ours.value.design.raw;
                // § 9 (2): HarfBuzz clamps a varied advance at zero.
                if (theirs == 0 && raw < -unit / 2)
                {
                    ++clamped;
                    continue;
                }
                const diff = raw - long(theirs) * unit;
                assert(-halfUnit <= diff && diff <= halfUnit, file);
                varied += theirs != stored.advance(gid).value;
                ++near;
            }
        }
    });
    stderr.writefln("oracle.metrics.advances: %s faces (%s variable), %s instances; %s advances exact "
        ~ "at the default, %s within 0.5 unit off it (%s of them varied); excluded: %s clamped at zero, "
        ~ "%s without HVAR "
        ~ "(phantom points), %s other HVAR errors",
        faces, variableFaces, instances, exact, near, varied, clamped, unsupported, otherErrors);
    assert(exact > 100_000 && varied > 10_000);
}

/// `OS/2` has data in HarfBuzz's sense: a weight, width or character index.
private bool hbOs2HasData(in Os2 o)
    => o.usWeightClass || o.usWidthClass || o.usFirstCharIndex || o.usLastCharIndex;

/// HarfBuzz's value for `tag`, or `long.min` when it reports none.
private long hbMetric(ref Oracle hb, string tag)
{
    hb_position_t p;
    return hb_ot_metrics_get_position(hb.font, hbTag!hb_ot_metrics_tag_t(tag), &p) ? long(p) * unit : long.min;
}

/// Whether `ours` (design) and HarfBuzz's whole-unit `theirs` agree: exactly at
/// the default, within half a unit off it.
private bool agrees(long ours, long theirs, bool exactly)
{
    if (theirs == long.min)
        return false;
    const diff = ours - theirs;
    return exactly ? diff == 0 : -halfUnit <= diff && diff <= halfUnit;
}

@("oracle.metrics.lineMetricsAndDecorations")
@system
unittest
{
    size_t faces, instances, lines, decorations;
    size_t typoNoData, hheaZeroFallback, windowsSet, forcedSigns, absentLines;
    size_t xBothZero, xAbsent, strikeNoData, zeroDecorations;
    eachFace((file, face, ref hb) {
        ++faces;
        Instance[] insts = [at(face, null, file)];
        if (variable(face) && insts[0].recordedErrors == 0)
            insts ~= extremes(face, axisRecords(face), file)[$ - 1 .. $]; // all maxima
        const o = face.os2;
        foreach (inst; insts)
        {
            ++instances;
            setCoords(hb, inst);
            const exactly = inst.allZero;

            // FTM15, FTM16: compared where HarfBuzz picks the same set and
            // its forced signs change nothing (§ 9 FTM divergence 1).
            const lm = inst.lineMetrics;
            assert(lm.hasValue, file);
            const l = lm.value;
            const flagged = o.hasValue && (o.value.fsSelection & 0x80) != 0;
            bool compare;
            final switch (l.source)
            {
                case LineMetricsSource.none:
                    ++absentLines;
                    break;
                case LineMetricsSource.typographic:
                    if (!flagged)
                        ++hheaZeroFallback;
                    else if (!hbOs2HasData(o.value))
                        ++typoNoData;
                    else
                        compare = true;
                    break;
                case LineMetricsSource.hhea:
                    compare = true;
                    break;
                case LineMetricsSource.windows:
                    ++windowsSet;
                    break;
            }
            if (compare && (l.ascender.design.raw < 0 || l.descender.design.raw > 0))
            {
                ++forcedSigns;
                compare = false;
            }
            if (compare)
            {
                assert(agrees(l.ascender.design.raw, hbMetric(hb, "hasc"), exactly), file);
                assert(agrees(l.descender.design.raw, hbMetric(hb, "hdsc"), exactly), file);
                assert(agrees(l.lineGap.design.raw, hbMetric(hb, "hlgp"), exactly), file);
                lines += 3;
            }

            // FTM17: x-height and cap height from OS/2 v2+, absent in HarfBuzz
            // when both are zero; underline and strikeout where nonzero.
            const dr = inst.decorations;
            assert(dr.hasValue, file);
            const d = dr.value;
            if (!d.hasXHeight)
            {
                assert(hbMetric(hb, "xhgt") == long.min && hbMetric(hb, "cpht") == long.min, file);
                ++xAbsent;
            }
            else if (o.value.sxHeight == 0 && o.value.sCapHeight == 0)
                ++xBothZero;
            else
            {
                assert(agrees(d.xHeight.design.raw, hbMetric(hb, "xhgt"), exactly), file);
                assert(agrees(d.capHeight.design.raw, hbMetric(hb, "cpht"), exactly), file);
                decorations += 2;
            }
            void nonzero(bool has, in Measurement m, string tag)
            {
                if (!has)
                    return;
                if (m.design.raw == 0)
                {
                    ++zeroDecorations;
                    return;
                }
                assert(agrees(m.design.raw, hbMetric(hb, tag), exactly), file);
                ++decorations;
            }
            nonzero(d.hasUnderline, d.underlinePosition, "undo");
            nonzero(d.hasUnderline, d.underlineThickness, "unds");
            if (d.hasStrikeout && !hbOs2HasData(o.value))
                ++strikeNoData;
            else
            {
                nonzero(d.hasStrikeout, d.strikeoutPosition, "stro");
                nonzero(d.hasStrikeout, d.strikeoutSize, "strs");
            }
        }
    });
    stderr.writefln("oracle.metrics.lineMetricsAndDecorations: %s faces, %s instances; %s line "
        ~ "values, %s decoration values agree; excluded instances: %s typographic set without "
        ~ "OS/2 data, %s hhea-zero fallback, %s Windows set, %s forced signs, %s no set; "
        ~ "decorations: %s x-height absent (both sides), %s x/cap both zero, %s strikeout without "
        ~ "OS/2 data, %s stored zeros",
        faces, instances, lines, decorations, typoNoData, hheaZeroFallback, windowsSet, forcedSigns,
        absentLines, xAbsent, xBothZero, strikeNoData, zeroDecorations);
    assert(lines > 100 && decorations > 100);
}

/**
FTM20, FTM21. HarfBuzz's vertical advance is the pen movement in its y-up
space, so it is the negated `vmtx` advance (`hb_font_get_glyph_v_advance`
returns `em_scale_y(-advance)`). Its vertical origin is the offset from the
horizontal origin to the vertical one in the same y-up space: `y` is
`VORG`'s `vertOriginY` as stored (plus the `VVAR` origin delta), or in a
`glyf` face without `VORG` its top phantom point, the same sign as ours, and
`x` is half the horizontal advance, which this page does not report. A face
without `VVAR` varies its advances by the `gvar` phantom points on both
sides; HarfBuzz rounds every varied advance to a whole unit.

The bundle's variable faces vary no vertical advance, so the test corpus's
faces join them: Adobe Blank VF, whose `HGHT` axis takes every advance from
0 to 1,000 units (fractional ones at a third of the axis) in a `CFF2` face
with `VORG` and a `glyf` face with `gvar`, and Source Han Sans VF, whose
`VVAR` varies vertical origins. Each variable face is read at the default,
with every axis at its maximum, and with every axis a third of the way up.
*/
@("oracle.vertical.advancesAndOrigins")
@system
unittest
{
    auto ws = makeUnique!PointWorkspace();
    size_t vmtxFaces, vorgFaces, advances, origins, phantomOrigins, clamped, otherErrors;
    size_t variedAdvances, fractionalAdvances, variedOrigins;
    eachFace((file, face, ref hb) {
        const hasVmtx = face.has(Tag("vhea")) && face.has(Tag("vmtx"));
        const hasVorg = face.has(Tag("VORG"));
        const hasPhantomOrigin = !hasVorg && hasVmtx && face.has(Tag("glyf"));
        if (!hasVmtx && !hasVorg)
            return;
        Instance[] insts = [at(face, null, file)];
        if (variable(face) && insts[0].recordedErrors == 0)
        {
            const axes = axisRecords(face);
            insts ~= extremes(face, axes, file)[$ - 1 .. $];
            UserCoordinate[] third;
            foreach (a; axes)
                third ~= UserCoordinate(a.axisTag, cast(int)(a.minValue + (long(a.maxValue) - a.minValue) / 3));
            insts ~= at(face, third, file);
        }
        vmtxFaces += hasVmtx;
        vorgFaces += hasVorg;
        // The default instance's values, which a varied one is counted against.
        auto defaultAdvance = new long[face.numGlyphs];
        auto defaultOrigin = new long[face.numGlyphs];
        foreach (inst; insts)
        {
            setCoords(hb, inst);
            foreach (gid; 0 .. face.numGlyphs)
            {
                if (hasVmtx)
                {
                    const ours = inst.verticalAdvance(gid, *ws);
                    const theirs = -long(hb_font_get_glyph_v_advance(hb.font, gid)) * unit;
                    if (inst.allZero)
                    {
                        assert(ours.hasValue && ours.value.present, file);
                        assert(ours.value.advance.design.raw == theirs, file);
                        defaultAdvance[gid] = theirs;
                        ++advances;
                    }
                    else if (ours.hasError)
                        ++otherErrors;
                    else if (theirs == 0 && ours.value.advance.design.raw < -unit / 2)
                        ++clamped;
                    else
                    {
                        const raw = ours.value.advance.design.raw;
                        assert(agrees(raw, theirs, false), file);
                        variedAdvances += raw != defaultAdvance[gid];
                        fractionalAdvances += raw % unit != 0;
                        ++advances;
                    }
                }
                if (hasVorg || hasPhantomOrigin)
                {
                    const ours = inst.verticalOrigin(gid, *ws);
                    assert(ours.hasValue && ours.value.present, file);
                    hb_position_t x, y;
                    assert(hb_font_get_glyph_v_origin(hb.font, gid, &x, &y), file);
                    const raw = ours.value.y.design.raw;
                    assert(agrees(raw, long(y) * unit, inst.allZero), file);
                    if (inst.allZero)
                        defaultOrigin[gid] = raw;
                    else
                        variedOrigins += raw != defaultOrigin[gid];
                    if (hasVorg)
                        ++origins;
                    else
                        ++phantomOrigins;
                }
            }
        }
    }, withTestCorpus: true);
    stderr.writefln("oracle.vertical.advancesAndOrigins: %s faces with vhea+vmtx, %s with VORG; "
        ~ "%s advances (%s varied, %s fractional), %s VORG and %s phantom-point origins (%s varied) "
        ~ "agree; excluded: %s clamped at zero, %s other VVAR errors",
        vmtxFaces, vorgFaces, advances, variedAdvances, fractionalAdvances, origins, phantomOrigins,
        variedOrigins, clamped, otherErrors);
    assert(otherErrors == 0);
    if (testFontsDir !is null)
    {
        // Adobe Blank VF's 2,048 spacing glyphs, in both faces, at both nondefault instances.
        assert(variedAdvances >= 2 * 2 * 2_048 && fractionalAdvances >= 2 * 2_048,
            text(variedAdvances, " varied and ", fractionalAdvances, " fractional advances"));
        // Source Han Sans VF's 248 at both nondefault instances.
        assert(variedOrigins >= 2 * 248, text(variedOrigins, " varied origins"));
    }
    if (vmtxFaces == 0)
        skipTest("no bundled face has vhea and vmtx");
}

/// The `MATH` constants and kern corners, as HarfBuzz numbers them; both follow
/// OpenType's order, as `MathConstant` and `MathKernCorner` do.
private enum hbMathConstantCount = cast(hb_ot_math_constant_t) mathConstantCount;
private enum hbMathKernEnd = cast(hb_ot_math_kern_t)(HB_OT_MATH_KERN_BOTTOM_LEFT + 1);

/// HarfBuzz's direction for `d`; only horizontal or not matters to it.
private hb_direction_t hbDirection(MathDirection d)
    => d == MathDirection.vertical ? hb_direction_t.HB_DIRECTION_TTB : hb_direction_t.HB_DIRECTION_LTR;

/**
FTP34–FTP38 against `hb_ot_math_get_*` at the default instance and a scale
of one unit per font unit, where no Device table applies. Every face's
absence agrees; on a `MATH` face every constant, and per glyph the italics
correction, top accent, extended shape, kerns at each corner, variants and
assembly in both directions. Excluded (§ 9 FTP divergence 1): an uncovered
glyph, which HarfBuzz gives a top accent of half its advance and an italics
correction and kern of 0 where this page reports absence; and a kern whose
heights do not strictly ascend, where HarfBuzz's binary search and this
page's stored-order scan (FTP37) may pick different steps.
*/
@("oracle.math.values")
@system
unittest
{
    size_t faces, mathFaces, constants, italics, accents, shapes, kernTables, kerns, variants,
        assemblies, overlaps;
    size_t uncoveredItalics, uncoveredAccents, absentKerns, unsortedKerns;
    eachFace((file, face, ref hb) {
        ++faces;
        const ours = face.mathTable;
        const theirs = hb_ot_math_has_data(hb.face) != 0;
        // Absent here is missingTable; HarfBuzz has no data for it.
        if (ours.hasError && ours.error.kind == FontErrorKind.missingTable)
            assert(!theirs, file);
        if (!theirs)
            return;
        assert(ours.hasValue, file);
        ++mathFaces;
        const inst = at(face, null, file);

        const cs = inst.mathConstants;
        assert(cs.hasValue && cs.value.present, file);
        foreach (c; HB_OT_MATH_CONSTANT_SCRIPT_PERCENT_SCALE_DOWN .. hbMathConstantCount)
        {
            const v = cs.value[cast(MathConstant) c];
            assert(v.hasValue && v.value.present, file);
            const h = hb_ot_math_get_constant(hb.font, c);
            if (v.value.kind == MathValueKind.percentage)
                assert(v.value.percentage == h, file);
            else
                assert(v.value.value.design.raw == long(h) * unit, file);
            ++constants;
        }
        foreach (direction; [MathDirection.vertical, MathDirection.horizontal])
        {
            const v = inst.mathVariants(0, direction);
            assert(v.hasValue, file);
            if (v.value.variantsPresent)
            {
                assert(v.value.minConnectorOverlap.design.raw
                    == long(hb_ot_math_get_min_connector_overlap(hb.font, hbDirection(direction))) * unit, file);
                ++overlaps;
            }
        }

        foreach (gid; 0 .. face.numGlyphs)
        {
            const ic = inst.italicsCorrection(gid);
            assert(ic.hasValue, file);
            if (ic.value.present)
            {
                assert(ic.value.value.design.raw
                    == long(hb_ot_math_get_glyph_italics_correction(hb.font, gid)) * unit, file);
                ++italics;
            }
            else
                ++uncoveredItalics;
            const ta = inst.topAccentAttachment(gid);
            assert(ta.hasValue, file);
            if (ta.value.present)
            {
                assert(ta.value.value.design.raw
                    == long(hb_ot_math_get_glyph_top_accent_attachment(hb.font, gid)) * unit, file);
                ++accents;
            }
            else
                ++uncoveredAccents;
            const es = inst.isExtendedShape(gid);
            assert(es.hasValue && es.value == (hb_ot_math_is_glyph_extended_shape(hb.face, gid) != 0), file);
            ++shapes;

            foreach (corner; HB_OT_MATH_KERN_TOP_RIGHT .. hbMathKernEnd)
            {
                const t = inst.mathKernTable(gid, cast(MathKernCorner) corner);
                assert(t.hasValue, file);
                const table = t.value;
                hb_ot_math_kern_entry_t[64] entries;
                uint count = entries.length;
                const total = hb_ot_math_get_glyph_kernings(hb.font, gid, corner, 0, &count, entries.ptr);
                if (!table.present)
                {
                    assert(total == 0, file);
                    ++absentKerns;
                    continue;
                }
                // The entries: the value below each height, then the last value.
                assert(total == table.heightCount + 1 && count == total, file);
                long previous = long.min;
                bool ascending = true;
                foreach (i; 0 .. table.heightCount)
                {
                    const height = table.height(i).value.value.design.raw;
                    ascending = ascending && height > previous;
                    previous = height;
                    assert(entries[i].max_correction_height * unit == height, file);
                }
                foreach (i; 0 .. table.heightCount + 1)
                    assert(entries[i].kern_value * unit == table.value(i).value.value.design.raw, file);
                ++kernTables;
                if (!ascending)
                {
                    ++unsortedKerns;
                    continue;
                }
                // Below, at and above each height, and past the extremes.
                int[] probes = [int.min / 2, int.max / 2];
                foreach (i; 0 .. table.heightCount)
                {
                    const h = cast(int)(table.height(i).value.value.design.raw / unit);
                    probes ~= [h - 1, h, h + 1];
                }
                foreach (h; probes)
                {
                    const k = table.lookup(DesignValue.fromUnits(h, face.unitsPerEm));
                    assert(k.hasValue && k.value.present, file);
                    assert(k.value.value.design.raw
                        == long(hb_ot_math_get_glyph_kerning(hb.font, gid, corner, h)) * unit, file);
                    ++kerns;
                }
            }

            foreach (direction; [MathDirection.vertical, MathDirection.horizontal])
            {
                const hd = hbDirection(direction);
                const v = inst.mathVariants(gid, direction);
                assert(v.hasValue, file);
                hb_ot_math_glyph_variant_t[256] hv;
                uint count = hv.length;
                const total = hb_ot_math_get_glyph_variants(hb.font, gid, hd, 0, &count, hv.ptr);
                assert(v.value.length == total && count == total, file);
                foreach (i; 0 .. v.value.length)
                {
                    assert(v.value[i].glyph == hv[i].glyph, file);
                    assert(v.value[i].advance.design.raw == long(hv[i].advance) * unit, file);
                    ++variants;
                }

                const n = inst.mathAssemblyLength(gid, direction);
                assert(n.hasValue, file);
                hb_ot_math_glyph_part_t[256] hp;
                uint partCount = hp.length;
                hb_position_t hbItalics;
                const parts = hb_ot_math_get_glyph_assembly(hb.font, gid, hd, 0, &partCount, hp.ptr, &hbItalics);
                if (!n.value.present)
                {
                    assert(parts == 0, file);
                    continue;
                }
                auto storage = new GlyphPart[n.value.partCount];
                const a = inst.mathAssembly(gid, direction, storage);
                assert(a.hasValue && a.value.present, file);
                assert(a.value.parts.length == parts && partCount == parts, file);
                foreach (i, p; a.value.parts)
                {
                    assert(p.glyph == hp[i].glyph, file);
                    assert(p.startConnectorLength.design.raw == long(hp[i].start_connector_length) * unit, file);
                    assert(p.endConnectorLength.design.raw == long(hp[i].end_connector_length) * unit, file);
                    assert(p.fullAdvance.design.raw == long(hp[i].full_advance) * unit, file);
                    assert(p.extender == ((hp[i].flags & 1) != 0), file);
                }
                assert(a.value.italicsCorrection.value.design.raw == long(hbItalics) * unit, file);
                ++assemblies;
            }
        }
    });
    stderr.writefln("oracle.math.values: %s faces, %s with MATH; agree: %s constants, %s italics "
        ~ "corrections, %s top accents, %s extended-shape flags, %s kern tables (%s kern lookups), "
        ~ "%s variants, %s assemblies, %s connector overlaps; excluded: %s uncovered italics, "
        ~ "%s uncovered top accents, %s absent kern corners, %s kern tables not strictly ascending",
        faces, mathFaces, constants, italics, accents, shapes, kernTables, kerns, variants, assemblies,
        overlaps, uncoveredItalics, uncoveredAccents, absentKerns, unsortedKerns);
    if (mathFaces == 0)
        skipTest("no bundled face has MATH: the value differential needs a math face such as "
            ~ "STIX Two Math or Noto Sans Math in the bundle (absence agreed on every face)");
}

@("oracle.baseline.absenceAgrees")
@system
unittest
{
    auto ws = makeUnique!PointWorkspace();
    size_t faces, baseFaces, queries;
    eachFace((file, face, ref hb) {
        ++faces;
        const ours = face.base(0);
        if (ours.hasValue || ours.error.kind != FontErrorKind.missingTable)
        {
            ++baseFaces;
            return;
        }
        const inst = at(face, null, file);
        static immutable cases = [
            ["romn", "latn"], ["hang", "deva"], ["ideo", "hani"], ["icft", "hani"], ["idtp", "kana"]];
        foreach (c; cases)
            foreach (axis; [BaselineAxis.horizontal, BaselineAxis.vertical])
            {
                const b = inst.baseline(axis, Tag(c[1]), Tag(c[0]), *ws);
                assert(b.hasError && b.error.kind == FontErrorKind.missingTable, file);
                const direction = axis == BaselineAxis.horizontal
                    ? hb_direction_t.HB_DIRECTION_LTR : hb_direction_t.HB_DIRECTION_TTB;
                hb_position_t coord;
                assert(!hb_ot_layout_get_baseline(hb.font, hbTag!hb_ot_layout_baseline_tag_t(c[0]), direction,
                    hbTag(c[1]), 0, &coord),
                    file);
                ++queries;
            }
    });
    stderr.writefln("oracle.baseline.absenceAgrees: %s faces, %s with BASE, %s absent baselines agree",
        faces, baseFaces, queries);
    if (baseFaces == 0)
        skipTest("no bundled face has BASE: the FTM22–FTM24 value differential needs a verified BASE "
            ~ "face acquired into the bundle (absence agreed on every face)");
    assert(false, "a BASE face is bundled: write the FTM22–FTM24 hb_ot_layout_get_baseline differential");
}
