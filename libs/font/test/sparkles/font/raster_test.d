/**
M5 raster tests (FTR1, FTR2, FTR4, FTR6) over fixtures and the bundle:
exact coverage of axis-aligned shapes, overlap-union vs accumulation,
deterministic repeat renders, and caller-storage errors.
*/
module sparkles.font.raster_test;

import sparkles.font;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.fixtures;
import sparkles.test_runner.skip : skipTest;

import std.conv : text;

private struct Buffers
{
    OutlineSegment[256] segments;
    OutlinePoint[256] points;
    bool[256] onCurve;
    ushort[64] ends;
    float[65_536] accumulation;
    ubyte[65_536] supersample;
    ubyte[4096] pixels;

    RasterWorkspace workspace() scope return @safe pure nothrow @nogc
        => RasterWorkspace(segments[], points[], onCurve[], ends[],
            accumulation[], supersample[]);
}

private const(ubyte)[] glyphFont(const(ubyte)[][] glyphs) @safe pure nothrow
{
    auto tables = minimalTables(cast(uint) glyphs.length);
    uint[2][] metrics;
    foreach (_; glyphs)
        metrics ~= [500, 0];
    tables ~= TableData("hhea", hhea(cast(uint) glyphs.length));
    tables ~= TableData("hmtx", hmtx(metrics));
    tables ~= TableData("loca", locaTable(glyphs));
    tables ~= TableData("glyf", glyfTable(glyphs));
    return sfnt(tables);
}

private Instance at(const(ubyte)[] bytes) @safe pure nothrow
{
    auto face = openFace(bytes).value;
    return face.instance(InstanceSize.pixels(Ppem.fromInteger(10).value), null).value;
}

/// Renders glyph 0 of `bytes` at 10 ppem (upem 2048 in the fixtures:
/// minimalTables uses head(2048), so 100 units are 0.488 px... the
/// shapes below are sized in units of the 2048-unit em).
private RasterGlyph render(Buffers* b, const(ubyte)[] bytes, uint gid,
    OverlapMode mode = OverlapMode.perGlyphFlag, Ppem ppem = Ppem.init)
{
    auto inst = at(bytes);
    if (!ppem.valid)
        ppem = Ppem.fromInteger(10).value;
    auto ws = b.workspace();
    const size = rasterMeasure(inst, gid, ppem, ws, mode);
    assert(size.hasValue, size.hasError ? size.error.text : "");
    auto region = RasterRegion(b.pixels[], size.value.width, size.value.width,
        size.value.height);
    const r = rasterizeGlyph(inst, gid, ppem, region, ws, FlattenPolicy.standard, mode);
    assert(r.hasValue);
    return r.value;
}

@("raster.square.exactCoverage")
@system
unittest
{
    // A 1024x1024-unit square in a 2048 em at 10 ppem is exactly 5x5 px.
    const bytes = glyphFont([simpleGlyph([[0, 0, 1], [1024, 0, 1],
        [1024, 1024, 1], [0, 1024, 1]])]);
    auto b = new Buffers;
    const size = render(b, bytes, 0);
    assert(size.width == 5 && size.height == 5 && !size.empty);
    foreach (pixel; b.pixels[0 .. 25])
        assert(pixel == 255);
    assert(applyTransfer(200, 256) == 200);
    assert(applyTransfer(0, 128) == 0 && applyTransfer(255, 128) == 255);
}

@("raster.overlap.unionVsAccumulate")
@system
unittest
{
    // Two identical contours over the square (512..1536 units): the
    // interior columns are 2.5 px wide at 10 ppem (512 units = 2.5 px).
    // Accumulated, the doubled edge coverage reaches 255 where the
    // union stays partial.
    const GlyphPoint[] square = [[512, 0, 1], [1536, 0, 1], [1536, 2048, 1], [512, 2048, 1]];
    // lsb 512 == xMin, so the drawn space is the stored space.
    auto tables = minimalTables(1);
    tables ~= TableData("hhea", hhea(1));
    tables ~= TableData("hmtx", hmtx([[500, 512]]));
    const glyphs = [contourGlyph([square, square], true)];
    tables ~= TableData("loca", locaTable(glyphs));
    tables ~= TableData("glyf", glyfTable(glyphs));
    const bytes = sfnt(tables);
    auto accumulated = new Buffers;
    const a = render(accumulated, bytes, 0, OverlapMode.accumulate);
    auto united = new Buffers;
    const u = render(united, bytes, 0, OverlapMode.perGlyphFlag);
    assert(a.width == u.width && a.width == 6);
    // Column 0 holds half an edge (128) in the union; doubled it is 255.
    assert(united.pixels[0] < 200, "union keeps the half-covered edge");
    assert(accumulated.pixels[0] == 255, "accumulation doubles the edge");
}

@("raster.determinism.andEmpty")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("DejaVuSansMono.ttf");
    const face = openFace(bytes).value;
    auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
    const gid = face.charMap.value.glyph('A');
    auto first = new Buffers, second = new Buffers;
    const a = render(first, bytes, gid, OverlapMode.perGlyphFlag, Ppem.fromInteger(16).value);
    const b = render(second, bytes, gid, OverlapMode.perGlyphFlag, Ppem.fromInteger(16).value);
    assert(a.width == b.width && a.height == b.height && a.width > 8);
    const area = cast(size_t) a.width * a.height;
    assert(first.pixels[0 .. area] == second.pixels[0 .. area]);
    size_t ink;
    foreach (pixel; first.pixels[0 .. area])
        ink += pixel > 0;
    assert(ink > 50, "the A inks");
    // The space glyph renders empty.
    const space = face.charMap.value.glyph(' ');
    auto third = new Buffers;
    const e = render(third, bytes, space, OverlapMode.perGlyphFlag,
        Ppem.fromInteger(16).value);
    assert(e.empty && e.width == 0);
}

@("raster.storage.exhaustion")
@system
unittest
{
    const bytes = glyphFont([simpleGlyph([[0, 0, 1], [1024, 0, 1],
        [1024, 1024, 1], [0, 1024, 1]])]);
    auto inst = at(bytes);
    auto b = new Buffers;
    auto ws = b.workspace();
    // A 1x1 region for a 5x5 glyph.
    auto region = RasterRegion(b.pixels[], 1, 1, 1);
    const r = rasterizeGlyph(inst, 0, Ppem.fromInteger(10).value, region, ws);
    assert(r.hasError && r.error.kind == FontErrorKind.limitExceeded
        && r.error.limit == FontLimit.callerStorage);
    // No accumulation storage.
    RasterWorkspace bare;
    bare.segments = b.segments;
    bare.points = b.points;
    bare.onCurve = b.onCurve;
    bare.contourEnds = b.ends;
    auto full = RasterRegion(b.pixels[], 5, 5, 5);
    const r2 = rasterizeGlyph(inst, 0, Ppem.fromInteger(10).value, full, bare);
    assert(r2.hasError && r2.error.limit == FontLimit.callerStorage);
}

/// Invalid strides, including overflowing sizes, fail before any output is touched.
@("raster.storage.invalidStride")
@system
unittest
{
    const bytes = glyphFont([simpleGlyph([[0, 0, 1], [1024, 0, 1],
        [1024, 1024, 1], [0, 1024, 1]])]);
    auto b = new Buffers;
    auto ws = b.workspace();
    foreach (stride; [size_t(0), size_t(4), size_t.max / 5 + 1])
    {
        b.pixels[] = 73;
        auto region = RasterRegion(b.pixels[], stride, 5, 5);
        const r = rasterizeGlyph(at(bytes), 0, Ppem.fromInteger(10).value, region, ws);
        assert(r.hasError && r.error.limit == FontLimit.callerStorage);
        foreach (pixel; b.pixels)
            assert(pixel == 73);
    }
    // Padding between rows is not glyph coverage and must stay untouched.
    auto padded = RasterRegion(b.pixels[], 8, 5, 5);
    assert(rasterizeGlyph(at(bytes), 0, Ppem.fromInteger(10).value, padded, ws).hasValue);
    foreach (y; 0 .. 5)
    {
        assert(b.pixels[y * 8 .. y * 8 + 5] == [255, 255, 255, 255, 255]);
        assert(b.pixels[y * 8 + 5 .. y * 8 + 8] == [73, 73, 73]);
    }
}

// Two rectangles whose contours cross at 16 ppem (128 units a pixel): A
// spans x 0–8.375 px, y 0–6 px; B spans x 2–8.375 px, y 3–9 px. Their
// right edges share column 8 at 3/8 coverage: a full subpixel and half of
// the next at 4×4.
private immutable GlyphPoint[] rectA = [[0, 0, 1], [0, 768, 1], [1072, 768, 1], [1072, 0, 1]];
private immutable GlyphPoint[] rectB = [[256, 384, 1], [256, 1152, 1], [1072, 1152, 1], [1072, 384, 1]];

/**
Column 8 of the 9×9 crossing box: 3/8 coverage (96) where one rectangle
covers it. Where both do, accumulation doubles it to 3/4 (191); the 4×4
union keeps the full subpixel single and only the half-covered one
doubles (FTX9's approximation, as in FreeType), giving 1/2 (128).
*/
private void assertCrossing(const(ubyte)[] pixels, RasterGlyph size, bool union_) @safe
{
    assert(size.width == 9 && size.height == 9 && size.bearingX == 0 && size.bearingY == 9);
    // Rows 0–2 are y 6–9 (B alone), 3–5 are y 3–6 (both), 6–8 are y 0–3 (A alone).
    foreach (row; 0 .. 9)
    {
        const both = row >= 3 && row <= 5;
        assert(pixels[row * 9 + 8] == (!both ? 96 : union_ ? 128 : 191), text(union_, " row ", row, " ", pixels[0 .. 81]));
        assert(pixels[row * 9 + 7] == 255);
    }
    // Left of B, above A: empty; inside A alone: full.
    assert(pixels[0] == 0 && pixels[8 * 9] == 255);
}

/// FTR2: crossing contours render their union when flagged or when the
/// caller forces it, and accumulate otherwise, with partial subpixels.
@("raster.overlap.crossingContours")
@system
unittest
{
    const ppem = Ppem.fromInteger(16).value;
    foreach (flagged; [false, true])
    {
        const bytes = glyphFont([contourGlyph([rectA, rectB], flagged)]);
        foreach (mode; [OverlapMode.perGlyphFlag, OverlapMode.forceUnion, OverlapMode.accumulate])
        {
            auto b = new Buffers;
            const size = render(b, bytes, 0, mode, ppem);
            const union_ = mode == OverlapMode.forceUnion || mode == OverlapMode.perGlyphFlag && flagged;
            assert(size.overlap == flagged);
            assertCrossing(b.pixels[], size, union_);
        }
    }
}

/// FTR2 for composites: `OVERLAP_COMPOUND` (0x0400) selects the union;
/// `SCALED_COMPONENT_OFFSET` (0x0800) alone does not.
@("raster.overlap.compositeFlag")
@system
unittest
{
    const ppem = Ppem.fromInteger(16).value;
    const a = simpleGlyph(rectA), b = simpleGlyph(rectB);
    const bytes = glyphFont([a, b,
        compositeGlyph([CompositePart(0, 0x0403, 0, 0), CompositePart(1, 0x0003, 0, 0)]),
        compositeGlyph([CompositePart(0, 0x0803, 0, 0), CompositePart(1, 0x0003, 0, 0)])]);
    auto flagged = new Buffers;
    assertCrossing(flagged.pixels[], render(flagged, bytes, 2, OverlapMode.perGlyphFlag, ppem), true);
    auto plain = new Buffers;
    assertCrossing(plain.pixels[], render(plain, bytes, 3, OverlapMode.perGlyphFlag, ppem), false);
}

/// A box past `maxRasterCoordinate` is `arithmeticExhausted`, not a wrapped size (FTB2).
@("raster.measure.hugePpem")
@system
unittest
{
    // The 1024-unit square of a 2048 em is ppem / 2 pixels wide.
    const bytes = glyphFont([simpleGlyph([[0, 0, 1], [1024, 0, 1], [1024, 1024, 1], [0, 1024, 1]])]);
    auto inst = at(bytes);
    auto b = new Buffers;
    auto ws = b.workspace();
    const atLimit = rasterMeasure(inst, 0, Ppem.fromInteger(2L * maxRasterCoordinate).value, ws,
        OverlapMode.forceUnion);
    assert(atLimit.hasValue && atLimit.value.width == maxRasterCoordinate);
    assert(atLimit.value.supersampleNeeded == 16UL * maxRasterCoordinate);
    assert(atLimit.value.accumulationNeeded == (4UL * maxRasterCoordinate + 2) * (4UL * maxRasterCoordinate));
    foreach (ppem; [4L * maxRasterCoordinate, 1L << 34, long.max])
    {
        const p = Ppem.fromInteger(ppem).value;
        const m = rasterMeasure(inst, 0, p, ws, OverlapMode.forceUnion);
        assert(m.hasError && m.error.kind == FontErrorKind.arithmeticExhausted);
        auto region = RasterRegion(b.pixels[], 64, 64, 64);
        const r = rasterizeGlyph(inst, 0, p, region, ws, FlattenPolicy.standard, OverlapMode.forceUnion);
        assert(r.hasError && r.error.kind == FontErrorKind.arithmeticExhausted);
    }
}

/// A short region reports the bytes its stride and height need.
@("raster.storage.regionNeeded")
@system
unittest
{
    const bytes = glyphFont([simpleGlyph([[0, 0, 1], [1024, 0, 1], [1024, 1024, 1], [0, 1024, 1]])]);
    auto b = new Buffers;
    auto ws = b.workspace();
    auto region = RasterRegion(b.pixels[0 .. 30], 8, 5, 5);
    const r = rasterizeGlyph(at(bytes), 0, Ppem.fromInteger(10).value, region, ws);
    assert(r.hasError && r.error.limit == FontLimit.callerStorage && r.error.needed == 4 * 8 + 5);
}

/// FTR6 with a reused workspace: a render after another glyph's equals a fresh one.
@("raster.determinism.dirtyWorkspace")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("MapleMono-NF-CN-Regular.ttf");
    const face = openFace(bytes).value;
    const ppem = Ppem.fromInteger(16).value;
    auto shared_ = new Buffers, fresh = new Buffers;
    foreach (mode; [OverlapMode.perGlyphFlag, OverlapMode.forceUnion])
        foreach (c; "AW@&")
        {
            const gid = face.charMap.value.glyph(c);
            render(shared_, bytes, face.charMap.value.glyph('#'), mode, ppem);
            shared_.pixels[] = 0;
            const a = render(shared_, bytes, gid, mode, ppem);
            *fresh = Buffers.init;
            const f = render(fresh, bytes, gid, mode, ppem);
            assert(a == f);
            const area = cast(size_t) a.width * a.height;
            assert(area > 0 && shared_.pixels[0 .. area] == fresh.pixels[0 .. area]);
        }
}

/// FTR4: the transfer's exponent is `256 / gammaTimes256`.
@("raster.applyTransfer.direction")
@safe pure nothrow @nogc
unittest
{
    assert(applyTransfer(128, 256) == 128);
    // (128/255)^(1/2.2) · 255 ≈ 186.4; (128/255)^2 · 255 ≈ 64.3.
    assert(applyTransfer(128, 563) == 186);
    assert(applyTransfer(128, 128) == 64);
    assert(applyTransfer(0, 563) == 0 && applyTransfer(255, 563) == 255);
}
