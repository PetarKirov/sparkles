/**
The M3 outline differential: for every glyph of one `glyf` face, of
every `CFF` face of the bundle and of the variable `CFF2` test faces, the segment sequence and coordinates of
`sparkles.font.outlines` equal `hb_font_draw_glyph`'s within 1/64 font
unit (testing.md § Outlines). HarfBuzz shares no code with the decoder.
*/
module sparkles.font_oracle.outlines;

import std.algorithm.searching : endsWith;
import std.file : read;
import std.conv : text;
import std.math : fabs;
import std.path : baseName;

import sparkles.base.unique : makeUnique;
import sparkles.font;
import sparkles.font_oracle.corpus : corpus, fontsDir, Oracle, testCorpus, testFontsDir;
import sparkles.font_oracle;
import sparkles.test_runner.skip : skipTest;

private struct HbSegment
{
    SegmentKind kind;
    double x1, y1, x2, y2, x3, y3;
}

private struct Collector
{
    HbSegment[16_384] segments;
    size_t count;
    bool overflow;

    void put(HbSegment s) @safe pure nothrow @nogc
    {
        if (count < segments.length)
            segments[count] = s;
        else
            overflow = true;
        ++count;
    }
}

private extern (C) nothrow @nogc
{
    void collectMove(hb_draw_funcs_t*, void* drawData, hb_draw_state_t*, float x, float y, void*)
    {
        auto c = cast(Collector*) drawData;
        c.put(HbSegment(SegmentKind.moveTo, x, y));
    }

    void collectLine(hb_draw_funcs_t*, void* drawData, hb_draw_state_t*, float x, float y, void*)
    {
        auto c = cast(Collector*) drawData;
        c.put(HbSegment(SegmentKind.lineTo, x, y));
    }

    void collectQuad(hb_draw_funcs_t*, void* drawData, hb_draw_state_t*, float cx, float cy,
        float x, float y, void*)
    {
        auto c = cast(Collector*) drawData;
        c.put(HbSegment(SegmentKind.quadTo, x, y, cx, cy));
    }

    void collectCubic(hb_draw_funcs_t*, void* drawData, hb_draw_state_t*, float c1x, float c1y,
        float c2x, float c2y, float x, float y, void*)
    {
        auto c = cast(Collector*) drawData;
        c.put(HbSegment(SegmentKind.cubicTo, x, y, c1x, c1y, c2x, c2y));
    }

    void collectClose(hb_draw_funcs_t*, void* drawData, hb_draw_state_t*, void*)
    {
        auto c = cast(Collector*) drawData;
        c.put(HbSegment(SegmentKind.close));
    }
}

/**
Asserts that `ours` equals HarfBuzz's `hb` within 1/64 font unit. A
zero-length closing line, which the decoder keeps so the segment kinds
never depend on coordinates (FTO4) and HarfBuzz omits, is skipped.
*/
private void assertMatches(scope const(OutlineSegment)[] ours, scope const(HbSegment)[] hb, string label)
{
    bool near(double a, double b) => fabs(a - b) <= 1.0 / 64;
    size_t j;
    OutlinePoint current;
    foreach (i, expected; hb)
    {
        if (expected.kind == SegmentKind.close && j + 1 < ours.length && ours[j].kind == SegmentKind.lineTo
            && ours[j].end == current && ours[j + 1].kind == SegmentKind.close)
            ++j;
        assert(j < ours.length, text(label, ": ", ours.length, " segments, HarfBuzz more"));
        const actual = ours[j++];
        assert(actual.kind == expected.kind, text(label, " segment=", i, " ", actual.kind, ", HarfBuzz ",
            expected.kind));
        if (expected.kind != SegmentKind.close)
            assert(near(actual.end.xUnits, expected.x1) && near(actual.end.yUnits, expected.y1),
                text(label, " segment=", i, " actual=", actual.end.xUnits, ",", actual.end.yUnits,
                    " expected=", expected.x1, ",", expected.y1));
        if (expected.kind == SegmentKind.quadTo || expected.kind == SegmentKind.cubicTo)
            assert(near(actual.control1.xUnits, expected.x2) && near(actual.control1.yUnits, expected.y2),
                text(label, " segment=", i));
        if (expected.kind == SegmentKind.cubicTo)
            assert(near(actual.control2.xUnits, expected.x3) && near(actual.control2.yUnits, expected.y3),
                text(label, " segment=", i));
        if (actual.kind != SegmentKind.close)
            current = actual.end;
    }
    assert(j == ours.length, text(label, ": ", ours.length - j, " segments past HarfBuzz's"));
}

/// A sink recording what `drawGlyph` drives, as segments, and the contour count `begin` announces.
private struct RecordingSink
{
    OutlineSegment[] segments;
    size_t count;
    size_t announced = size_t.max;

    void begin(size_t contourCount) { announced = contourCount; }
    void moveTo(OutlinePoint p) { add(OutlineSegment(SegmentKind.moveTo, p)); }
    void lineTo(OutlinePoint p) { add(OutlineSegment(SegmentKind.lineTo, p)); }
    void quadTo(OutlinePoint c, OutlinePoint p) { add(OutlineSegment(SegmentKind.quadTo, p, c)); }
    void cubicTo(OutlinePoint c1, OutlinePoint c2, OutlinePoint p)
        => add(OutlineSegment(SegmentKind.cubicTo, p, c1, c2));
    void close() { add(OutlineSegment(SegmentKind.close)); }

    private void add(OutlineSegment s)
    {
        if (count < segments.length)
            segments[count] = s;
        ++count;
    }
}

@("oracle.outlines.glyfAndCff")
@system
unittest
{
    if (fontsDir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    string[] paths;
    foreach (path; corpus)
        if (path.baseName == "DejaVuSansMono.ttf" || path.endsWith(".otf"))
            paths ~= path;
    assert(paths.length > 100, "the glyf face and the CFF faces are bundled");

    size_t glyphsChecked;
    foreach (path; paths)
    {
        const bytes = cast(const(ubyte)[]) read(path);
        const file = path.baseName;
        auto hb = Oracle(bytes, 0);
        hb_font_set_scale(hb.font, cast(int) hb_face_get_upem(hb.face),
            cast(int) hb_face_get_upem(hb.face));
        auto funcs = hb_draw_funcs_create();
        scope (exit) hb_draw_funcs_destroy(funcs);
        hb_draw_funcs_set_move_to_func(funcs, &collectMove, null, null);
        hb_draw_funcs_set_line_to_func(funcs, &collectLine, null, null);
        hb_draw_funcs_set_quadratic_to_func(funcs, &collectQuad, null, null);
        hb_draw_funcs_set_cubic_to_func(funcs, &collectCubic, null, null);
        hb_draw_funcs_set_close_path_func(funcs, &collectClose, null, null);
        hb_draw_funcs_make_immutable(funcs);
        // Heap-owned: the test workers have small stacks.
        auto points = new OutlinePoint[8192];
        auto pws = makeUnique!PointWorkspace();
        auto onCurve = new bool[8192];
        auto ends = new ushort[1024];
        auto segments = new OutlineSegment[16_384];
        auto drawn = new OutlineSegment[16_384];
        auto collector = new Collector;
        const face = openFace(bytes).value;
        auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
        foreach (gid; 0 .. face.numGlyphs)
        {
            collector.count = 0;
            collector.overflow = false;
            hb_font_draw_glyph(hb.font, gid, funcs, collector);
            assert(!collector.overflow, file);
            auto ws = pws.get.outline;
            const ours = glyphOutline(inst, gid, segments[], ws);
            const label = text(file, " gid=", gid);
            assert(ours.hasValue, text(label, ": ", ours.hasError ? ours.error.text : ""));
            const n = ours.value.segmentCount;
            assertMatches(segments[0 .. n], collector.segments[0 .. collector.count], label);
            // FTO1 and FTO2 agree: drawGlyph drives a sink with the same segments.
            auto sink = RecordingSink(drawn);
            assert(drawGlyph(inst, gid, ws, sink).hasValue, label);
            assert(sink.count == n && sink.segments[0 .. n] == segments[0 .. n], text(label, " drawGlyph"));
            size_t moves;
            foreach (s; segments[0 .. n])
                moves += s.kind == SegmentKind.moveTo;
            assert(sink.announced == moves, text(label, " begin(", sink.announced, "), ", moves, " contours"));
            ++glyphsChecked;
        }
    }
    assert(glyphsChecked > 50_000);
}

/// Nondefault instances exercise real sparse, shared and composite variation data.
@("oracle.outlines.variableGlyf")
@system
unittest
{
    if (fontsDir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    string path;
    foreach (p; corpus)
        if (p.baseName == "NotoSansArabic.ttf")
            path = p;
    assert(path !is null, "the variable oracle face is bundled");
    const bytes = cast(const(ubyte)[]) read(path);
    const face = openFace(bytes).value;
    auto hb = Oracle(bytes, 0);
    hb_font_set_scale(hb.font, face.unitsPerEm, face.unitsPerEm);
    auto funcs = hb_draw_funcs_create();
    scope (exit) hb_draw_funcs_destroy(funcs);
    hb_draw_funcs_set_move_to_func(funcs, &collectMove, null, null);
    hb_draw_funcs_set_line_to_func(funcs, &collectLine, null, null);
    hb_draw_funcs_set_quadratic_to_func(funcs, &collectQuad, null, null);
    hb_draw_funcs_set_cubic_to_func(funcs, &collectCubic, null, null);
    hb_draw_funcs_set_close_path_func(funcs, &collectClose, null, null);
    hb_draw_funcs_make_immutable(funcs);
    auto collector = new Collector;
    auto points = new OutlinePoint[8192];
    auto pws = makeUnique!PointWorkspace();
    auto on = new bool[8192];
    auto ends = new ushort[1024];
    auto segments = new OutlineSegment[16_384];
    foreach (weight; [100, 250, 650, 900])
    {
        const inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value),
            [UserCoordinate(Tag("wght"), weight << 16)]).value;
        int[64] coords;
        foreach (i, c; inst.coords)
            coords[i] = c;
        hb_font_set_var_coords_normalized(hb.font, coords.ptr, inst.axisCount);
        foreach (gid; 0 .. face.numGlyphs)
        {
            const label = text("NotoSansArabic wght=", weight, " gid=", gid);
            collector.count = 0;
            collector.overflow = false;
            hb_font_draw_glyph(hb.font, gid, funcs, collector);
            assert(!collector.overflow, label);
            const ours = glyphOutline(inst, gid, segments[], pws.get.outline);
            assert(ours.hasValue, text(label, " ", ours.hasError ? ours.error : FontError.init));
            assertMatches(segments[0 .. ours.value.segmentCount],
                collector.segments[0 .. collector.count], label);
        }
    }
}

/// FTO4 across the bundle: every glyph of every variable face keeps its default segment kinds at each axis extreme.
@("oracle.outlines.variationKeepsTopology")
@system
unittest
{
    if (fontsDir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto points = new OutlinePoint[65_536];
    auto pws = makeUnique!PointWorkspace();
    auto onCurve = new bool[65_536];
    auto ends = new ushort[8192];
    auto atDefault = new OutlineSegment[65_536];
    auto varied = new OutlineSegment[65_536];
    const size = InstanceSize.pixels(Ppem.fromInteger(16).value);
    size_t faces, glyphs;
    foreach (path; corpus ~ testCorpus)
    {
        const bytes = cast(const(ubyte)[]) read(path);
        const opened = openFace(bytes);
        if (opened.hasError)
            continue;
        const face = opened.value;
        auto axisList = axes(face);
        if (axisList.empty)
            continue;
        ++faces;
        // Each axis alone at its minimum and its maximum, then all at once.
        Instance[] instances;
        UserCoordinate[] allMin, allMax;
        foreach (a; axisList)
        {
            const axis = a.value;
            foreach (value; [axis.minValue, axis.maxValue])
                instances ~= face.instance(size, [UserCoordinate(axis.axisTag, value)]).value;
            allMin ~= UserCoordinate(axis.axisTag, axis.minValue);
            allMax ~= UserCoordinate(axis.axisTag, axis.maxValue);
        }
        instances ~= face.instance(size, allMin).value;
        instances ~= face.instance(size, allMax).value;
        const base = face.instance(size, null).value;
        auto ws = pws.get.outline;
        foreach (gid; 0 .. face.numGlyphs)
        {
            const label = text(path.baseName, " gid=", gid);
            const expected = glyphOutline(base, gid, atDefault, ws);
            assert(expected.hasValue, text(label, ": ", expected.hasError ? expected.error.text : ""));
            const count = expected.value.segmentCount;
            foreach (k, inst; instances)
            {
                const actual = glyphOutline(inst, gid, varied, ws);
                assert(actual.hasValue && actual.value.segmentCount == count,
                    text(label, " instance=", k, ": ", actual.hasValue ? actual.value.segmentCount : 0,
                        " segments, default ", count));
                foreach (i; 0 .. count)
                    assert(varied[i].kind == atDefault[i].kind, text(label, " instance=", k, " segment=", i));
            }
            ++glyphs;
        }
    }
    assert(faces >= 50 && glyphs > 25_000, text(faces, " variable faces, ", glyphs, " glyphs"));
}

/// CFF2 blending (`vsindex`, `blend`) against HarfBuzz at the default and at each axis extreme.
@("oracle.outlines.cff2Variable")
@system
unittest
{
    if (testFontsDir is null)
        return skipTest("SPARKLES_FONT_TEST_CORPUS is unset");
    auto funcs = hb_draw_funcs_create();
    scope (exit) hb_draw_funcs_destroy(funcs);
    hb_draw_funcs_set_move_to_func(funcs, &collectMove, null, null);
    hb_draw_funcs_set_line_to_func(funcs, &collectLine, null, null);
    hb_draw_funcs_set_quadratic_to_func(funcs, &collectQuad, null, null);
    hb_draw_funcs_set_cubic_to_func(funcs, &collectCubic, null, null);
    hb_draw_funcs_set_close_path_func(funcs, &collectClose, null, null);
    hb_draw_funcs_make_immutable(funcs);
    auto collector = new Collector;
    auto points = new OutlinePoint[8192];
    auto pws = makeUnique!PointWorkspace();
    auto on = new bool[8192];
    auto ends = new ushort[1024];
    auto segments = new OutlineSegment[16_384];
    const size = InstanceSize.pixels(Ppem.fromInteger(16).value);
    size_t faces, glyphsChecked;
    foreach (path; testCorpus)
    {
        const bytes = cast(const(ubyte)[]) read(path);
        const face = openFace(bytes).value;
        if (!face.has(Tag("CFF2")))
            continue;
        ++faces;
        auto hb = Oracle(bytes, 0);
        hb_font_set_scale(hb.font, face.unitsPerEm, face.unitsPerEm);
        UserCoordinate[][] settings = [null];
        foreach (a; axes(face))
        {
            const axis = a.value;
            settings ~= [UserCoordinate(axis.axisTag, axis.minValue)];
            settings ~= [UserCoordinate(axis.axisTag, axis.maxValue)];
        }
        foreach (k, setting; settings)
        {
            const inst = face.instance(size, setting).value;
            int[64] coords;
            foreach (i, c; inst.coords)
                coords[i] = c;
            hb_font_set_var_coords_normalized(hb.font, coords.ptr, inst.axisCount);
            foreach (gid; 0 .. face.numGlyphs)
            {
                const label = text(path.baseName, " instance=", k, " gid=", gid);
                collector.count = 0;
                collector.overflow = false;
                hb_font_draw_glyph(hb.font, gid, funcs, collector);
                assert(!collector.overflow, label);
                const ours = glyphOutline(inst, gid, segments[], pws.get.outline);
                assert(ours.hasValue, text(label, " ", ours.hasError ? ours.error : FontError.init));
                assertMatches(segments[0 .. ours.value.segmentCount],
                    collector.segments[0 .. collector.count], label);
                ++glyphsChecked;
            }
        }
    }
    assert(faces == 4, text(faces, " variable CFF2 faces in the test corpus"));
    assert(glyphsChecked > 10_000, text(glyphsChecked, " CFF2 glyph instances"));
}
