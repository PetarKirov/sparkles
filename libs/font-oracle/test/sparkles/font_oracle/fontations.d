/**
The fontations differential (`testing.md`, the fontations oracle): the
library's variation deltas, `BASE` coordinates and `MATH` glyph values
against `read-fonts`', recorded in `test/goldens/fontations.txt` by
`tools/gen_fontations_goldens.d`.

`read-fonts` evaluates an item variation store as this library does, each
region's scalar in F16.16 and the products summed exactly, so `HVAR`,
`VVAR`, `MVAR` and `BASE` deltas must agree to the last 1/65,536 unit,
where the HarfBuzz differentials accept its whole-unit rounding. Its
`MATH` reader reports an uncovered glyph as absent and walks math-kern
heights in stored order, as `FTP36` and `FTP37` do, so the glyphs and kern
tables the HarfBuzz differential excludes are compared here.

Each golden line digests one table's values for one instance; this test
prints the same values the same way and compares the digests, so a
mismatch names the face, the instance and the table, and rerunning the
driver (`tools/fontations`) on that face shows the values themselves.
*/
module sparkles.font_oracle.fontations;

import std.algorithm : count, sort, startsWith, uniq;
import std.array : appender, array, join, split;
import std.conv : text, to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, read, readText;
import std.format : format;
import std.path : buildPath, dirName;
import std.stdio : stderr;
import std.string : indexOf, lastIndexOf, lineSplitter;

import sparkles.base.text.layout_units : LayoutUnit;
import sparkles.base.unique : makeUnique;
import sparkles.font;
import sparkles.font_oracle.corpus : fontsDir, testFontsDir;
import sparkles.font_oracle.fingerprint : shapingFingerprint;
import sparkles.test_runner.skip : skipTest;

/// The goldens' instances are 12 points; the values are in design units.
private enum size = InstanceSize.physical(LayoutUnit(12 * LayoutUnit.ticksPerPoint));

/// One font unit, as a `DesignValue.raw`.
private enum long unit = 65_536;

/// `count present digest` of space-separated values, as the generator writes it.
private string digest(string values)
{
    const items = values.split(' ');
    return format("%s %s %s", items.length, items.count!(v => v != "x"),
        toHexString!(LetterCase.lower)(sha256Of(values)));
}

/// A design value's bits, or `x` for an error.
private string bits(FontResult!DesignValue v) => v.hasError ? "x" : v.value.raw.to!string;

/// A tag's four characters.
private string name(Tag t) => t.chars.idup;

/// The path a golden's face name stands for.
private string pathOf(string name)
{
    if (name.startsWith("bundle/"))
        return buildPath(fontsDir, name["bundle/".length .. $]);
    return buildPath(testFontsDir, name["test/".length .. $]);
}

/// The instance a golden's label names: the default, one axis or every axis at an extreme.
private Instance instanceFor(const Face face, string label)
{
    UserCoordinate[] coords;
    foreach (a; face.axes)
    {
        const axis = a.value;
        const tag = name(axis.axisTag);
        if (label == "allmin" || label == "min:" ~ tag)
            coords ~= UserCoordinate(axis.axisTag, axis.minValue);
        else if (label == "allmax" || label == "max:" ~ tag)
            coords ~= UserCoordinate(axis.axisTag, axis.maxValue);
    }
    const r = face.instance(size, coords);
    assert(r.hasValue, label);
    return r.value;
}

/// The per-glyph deltas of `delta`, joined.
private string glyphRow(const Face face, scope FontResult!DesignValue delegate(uint gid) delta)
{
    auto r = appender!string;
    foreach (gid; 0 .. face.numGlyphs)
    {
        if (gid)
            r.put(' ');
        r.put(bits(delta(gid)));
    }
    return r.data;
}

/// The coordinate of every script and baseline pair of `axis`, as the driver probes them.
private string baseRow(in Instance inst, BaselineAxis axis, scope ref PointWorkspace ws)
{
    const b = base(inst.face, inst.axisCount).value.axis(axis).value;
    Tag[] scripts = [Tag("DFLT"), Tag("arab"), Tag("zzzz")], tags = [Tag("hang"), Tag("math"), Tag("zzzz")];
    if (!b.scripts.hasError)
        foreach (s; b.scripts.value)
            scripts ~= s.value;
    if (!b.tags.hasError)
        foreach (t; b.tags.value)
            tags ~= t;
    scripts = scripts.sort!((x, y) => x.value < y.value).uniq.array;
    tags = tags.sort!((x, y) => x.value < y.value).uniq.array;
    string[] pairs;
    foreach (s; scripts)
        foreach (t; tags)
        {
            const v = inst.baseline(axis, s, t, ws);
            const value = v.hasError || !v.value.present ? "x" : v.value.value.coordinate.design.raw.to!string;
            pairs ~= name(s) ~ "/" ~ name(t) ~ "=" ~ value;
        }
    return pairs.join(" ");
}

/// A MATH value in whole design units, or `x` when absent or an error.
private string units(FontResult!MathValue v)
{
    if (v.hasError || !v.value.present)
        return "x";
    const raw = v.value.value.design.raw;
    assert(raw % unit == 0, "a MATH value with a fraction at the default");
    return (raw / unit).to!string;
}

/// One corner's kern table, as the driver prints it: heights; values; kern at each probe.
private string kernToken(in Instance inst, uint gid, MathKernCorner corner, ushort unitsPerEm)
{
    const t = inst.mathKernTable(gid, corner);
    if (t.hasError || !t.value.present)
        return "x";
    const table = t.value;
    string[] heights, values, answers;
    int[] probes;
    foreach (i; 0 .. table.heightCount)
    {
        heights ~= units(table.height(i));
        const h = heights[$ - 1].to!int;
        probes ~= [h - 1, h, h + 1];
    }
    foreach (i; 0 .. table.heightCount + 1)
        values ~= units(table.value(i));
    probes ~= [-(1 << 30), 1 << 30];
    foreach (h; probes)
        answers ~= units(table.lookup(DesignValue.fromUnits(h, unitsPerEm)));
    return heights.join(":") ~ ";" ~ values.join(":") ~ ";" ~ answers.join(":");
}

/// Our values for a golden's `key rest`: `none`, or the values the golden digests (`mvar`'s literally).
private string ours(in Instance inst, string key, string rest, scope ref PointWorkspace ws)
{
    const face = inst.face;
    const coords = inst.coords;
    const upem = face.unitsPerEm;
    switch (key)
    {
        case "hadv":
            const h = hvar(face, inst.axisCount);
            if (h.hasError && h.error.kind == FontErrorKind.missingTable)
                return "none";
            return glyphRow(face, gid => h.hasError ? fontErr!DesignValue(h.error)
                : h.value.advanceDelta(gid, coords, upem));
        case "vadv", "vorg":
            const v = vvar(face, inst.axisCount);
            if (v.hasError && v.error.kind == FontErrorKind.missingTable)
                return "none";
            // Without an origin map this library's origin delta is zero, and
            // fontations has none: the same statement, spelled differently.
            if (key == "vorg" && v.hasValue && !v.value.hasOriginMap)
                return glyphRow(face, gid => fontErr!DesignValue(FontError(FontErrorKind.missingTable)));
            return glyphRow(face, gid => v.hasError ? fontErr!DesignValue(v.error)
                : key == "vadv" ? v.value.advanceDelta(gid, coords, upem) : v.value.originDelta(gid, coords, upem));
        case "mvar":
            const m = mvar(face, inst.axisCount);
            if (m.hasError && m.error.kind == FontErrorKind.missingTable)
                return "none";
            string[] pairs;
            foreach (pair; rest.split(' '))
            {
                const tag = Tag(pair[0 .. 4]);
                pairs ~= pair[0 .. 5] ~ (m.hasError ? "x" : bits(m.value.delta(tag, coords, upem)));
            }
            return pairs.join(" ");
        case "base":
            return baseRow(inst, rest[0] == 'H' ? BaselineAxis.horizontal : BaselineAxis.vertical, ws);
        default:
            assert(0, key);
    }
}

/// Our `math <kind>` line's digest at the default instance.
private string oursMath(in Instance inst, string kind)
{
    const face = inst.face;
    string[] row;
    foreach (gid; 0 .. face.numGlyphs)
    {
        if (kind == "italics")
            row ~= units(inst.italicsCorrection(gid));
        else if (kind == "accent")
            row ~= units(inst.topAccentAttachment(gid));
        else
            row ~= kernToken(inst, gid, cast(MathKernCorner)(kind[$ - 1] - '0'), face.unitsPerEm);
    }
    return digest(row.join(" "));
}

/**
Every golden line equals this library's reading: per face the
fingerprint, per instance the normalized coordinates (skrifa's
normalization, a second opinion beside HarfBuzz's), then every `HVAR`,
`VVAR`, `MVAR` and `BASE` delta and coordinate, and at the default the
`MATH` italics corrections, top accents and math-kern tables.
*/
@("oracle.fontations.agrees")
@system
unittest
{
    if (fontsDir is null || testFontsDir is null)
        skipTest("SPARKLES_FONTS_PATH or SPARKLES_FONT_TEST_CORPUS is unset");
    auto ws = makeUnique!PointWorkspace();
    const golden = readText(buildPath(__FILE_FULL_PATH__.dirName.dirName.dirName, "goldens", "fontations.txt"));
    size_t faces, instances, deltaRows, mvarRows, baseRows, mathRows, deltas, nonzero;
    const(ubyte)[] bytes;
    Face face;
    Instance inst;
    string faceName, where;
    foreach (line; golden.lineSplitter)
    {
        if (line.startsWith("#"))
            continue;
        const space = line.indexOf(' ');
        const key = line[0 .. space];
        const rest = line[space + 1 .. $];
        switch (key)
        {
            case "face":
                const parts = rest.split(' ');
                const path = pathOf(parts[0]);
                assert(path.exists, parts[0] ~ " is not in the corpus: regenerate the fontations goldens");
                bytes = cast(const(ubyte)[]) read(path);
                assert(shapingFingerprint(bytes) == parts[1],
                    parts[0] ~ " changed since the goldens were recorded: regenerate them");
                const opened = openFace(bytes);
                assert(opened.hasValue, parts[0]);
                face = opened.value;
                faceName = where = parts[0];
                ++faces;
                break;
            case "instance":
                const cut = rest.lastIndexOf(' ');
                const label = rest[0 .. cut];
                inst = instanceFor(face, label);
                const coords = rest[cut + 1 .. $];
                if (coords == "-")
                    assert(inst.allZero, faceName ~ " " ~ label);
                else
                    assert(coords.split(',').to!(short[]) == inst.coords, text(faceName, " ", label,
                        ": skrifa normalizes to ", coords, ", this library to ", inst.coords));
                where = faceName ~ " @ " ~ label;
                ++instances;
                break;
            case "hadv", "vadv", "vorg", "mvar", "base":
                const values = ours(inst, key, rest, *ws);
                const got = values == "none" || key == "mvar" ? values : digest(values);
                assert(got == (key == "base" ? rest[2 .. $] : rest),
                    text(where, ": ", key, " differs; ours begins ", values[0 .. $ < 160 ? $ : 160]));
                if (key == "mvar")
                    ++mvarRows;
                else if (key == "base")
                    ++baseRows;
                else if (values != "none")
                {
                    ++deltaRows;
                    foreach (v; values.split(' '))
                    {
                        ++deltas;
                        nonzero += v != "0" && v != "x";
                    }
                }
                break;
            case "math":
                const kind = rest[0 .. rest.indexOf(' ')];
                assert(inst.allZero);
                assert(oursMath(inst, kind) == rest[kind.length + 1 .. $], where ~ ": math " ~ kind);
                ++mathRows;
                break;
            default:
                assert(0, line);
        }
    }
    stderr.writefln("oracle.fontations.agrees: %s faces, %s instances; agree: %s HVAR/VVAR delta rows "
        ~ "(%s deltas, %s nonzero), %s MVAR rows, %s BASE axis rows, %s MATH rows", faces, instances, deltaRows,
        deltas, nonzero, mvarRows, baseRows, mathRows);
    assert(faces > 0 && deltaRows > 0 && baseRows > 0 && mathRows > 0);
}
