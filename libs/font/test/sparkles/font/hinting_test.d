/**
Light hinting (FTR9) on the bundled DejaVu Sans Mono: the zones it
measures, the x-height on a whole pixel, crisp horizontal edges, and
nothing horizontal moved. The comparison with FreeType's light auto-hinter
is `sparkles.font_oracle.hinting`.
*/
module sparkles.font.hinting_test;

import sparkles.base.unique : makeUnique;
import sparkles.font;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.test_runner.skip : skipTest;

private struct Rig
{
    const(ubyte)[] bytes;
    Face face;
    CharMap map;
    Instance inst;
    Ppem ppem;
    LightHints hints;
    RasterWorkspace ws;

    static Rig at(int px) @system
    {
        Rig r;
        r.bytes = bundled("DejaVuSansMono.ttf");
        r.face = openFace(r.bytes).value;
        r.map = charMap(r.face).value;
        r.ppem = Ppem.fromInteger(px).value;
        r.inst = r.face.instance(InstanceSize.pixels(r.ppem), null).value;
        r.ws.segments = new OutlineSegment[4096];
        r.ws.points = new OutlinePoint[4096];
        r.ws.onCurve = new bool[4096];
        r.ws.contourEnds = new ushort[512];
        r.ws.accumulation = new float[1 << 16];
        r.ws.supersample = new ubyte[1 << 14];
        r.ws.pointNumbers = new uint[4096];
        r.ws.deltaX = new int[4096];
        r.ws.deltaY = new int[4096];
        r.ws.referenced = new int[2][4096];
        r.hints = lightHints(r.inst, r.map, r.ppem, new OutlineSegment[4096], r.ws.outline);
        return r;
    }

    // Glyph `c` rasterized, hinted or not: its box and coverage.
    ubyte[] draw(dchar c, bool hinted, out RasterGlyph box) @system
    {
        const gid = map.glyph(c);
        const h = hinted ? &hints : null;
        box = rasterMeasure(inst, gid, ppem, ws, OverlapMode.perGlyphFlag, h).value;
        auto pixels = new ubyte[box.width * box.height];
        cast(void) rasterizeGlyph(inst, gid, ppem, RasterRegion(pixels, box.width, box.width, box.height),
            ws, FlattenPolicy.standard, OverlapMode.perGlyphFlag, h);
        return pixels;
    }
}

@("hinting.lightHints.zonesAndAWholePixelXHeight")
@system unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    foreach (px; 10 .. 25)
    {
        const r = Rig.at(px);
        assert(r.hints.valid && r.hints.zoneCount == 5, "baseline, x-height, cap height, ascender, descender");
        foreach (z; r.hints.zones[0 .. r.hints.zoneCount])
            assert(z.referencePx == cast(long) z.referencePx && z.overshootPx == cast(long) z.overshootPx,
                "every zone on a whole pixel row");
        // The x-height zone (its overshoot) is a whole pixel at the fitted scale.
        const x = r.hints.zones[1];
        assert(x.top && x.overshootPx >= 1);
        const fitted = x.overshoot * r.hints.yScale;
        import std.math : abs, round;

        assert(abs(fitted - round(fitted)) < 1e-6, "the x-height overshoot sits on a pixel boundary");
        assert(abs(r.hints.yScale / r.hints.scale - 1) < 0.1, "fitting changes the size by under a tenth");
    }
}

@("hinting.hintSegments.horizontalEdgesAreCrisp")
@system unittest
{
    if (fontsPath is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    auto r = Rig.at(13);
    // `z`, `H`, `T` and `E` end in straight horizontal edges at zone
    // heights: hinted, their top and bottom rows are as dark as the rows
    // inside them, rather than the faint smear of an edge between two
    // rows — which is what some of them are unhinted at this size.
    static int rowPeak(in ubyte[] pixels, in RasterGlyph box, int row)
    {
        int peak;
        foreach (x; 0 .. box.width)
            peak = pixels[row * box.width + x] > peak ? pixels[row * box.width + x] : peak;
        return peak;
    }

    int smeared;
    foreach (dchar c; "zHTE")
    {
        RasterGlyph box;
        const hinted = r.draw(c, true, box);
        static bool crisp(in ubyte[] pixels, in RasterGlyph b)
            => rowPeak(pixels, b, 0) * 10 >= rowPeak(pixels, b, 1) * 9
                && rowPeak(pixels, b, b.height - 1) * 10 >= rowPeak(pixels, b, b.height - 2) * 9;

        assert(crisp(hinted, box), "the top and bottom rows are as dark as the rows inside");
        RasterGlyph unhintedBox;
        const unhinted = r.draw(c, false, unhintedBox);
        smeared += !crisp(unhinted, unhintedBox);
        assert(box.width == unhintedBox.width && box.bearingX == unhintedBox.bearingX, "nothing horizontal moves");
    }
    assert(smeared, "unhinted, some of them smear at 13 px: the test would catch a no-op");
}

@("hinting.hintSegments.leavesXAndInvalidHintsAlone")
@safe pure nothrow unittest
{
    auto segments = [
        OutlineSegment(SegmentKind.moveTo, OutlinePoint.fromUnits(0, 0)),
        OutlineSegment(SegmentKind.lineTo, OutlinePoint.fromUnits(100, 0)),
        OutlineSegment(SegmentKind.quadTo, OutlinePoint.fromUnits(100, 520), OutlinePoint.fromUnits(130, 260)),
        OutlineSegment(SegmentKind.lineTo, OutlinePoint.fromUnits(0, 520)),
        OutlineSegment(SegmentKind.close),
    ];
    const before = segments.dup;
    hintSegments(segments, LightHints.init);
    assert(segments == before, "invalid hints change nothing");

    LightHints h;
    h.scale = h.yScale = 12.0 / 1000 / 65_536;
    h.flatness = 4L << 16;
    h.stemMax = 200L << 16;
    hintSegments(segments, h);
    foreach (i, s; segments)
        assert(s.end.x == before[i].end.x && s.control1.x == before[i].control1.x, "x is never touched");
    // The top edge, 6.24 px up unhinted, is now on a row; the bottom stays on 0.
    import std.math : abs, round;

    foreach (y; [segments[1].end.y, segments[3].end.y])
    {
        const px = y * h.yScale;
        assert(abs(px - round(px)) < 1e-3);
    }
}
