/** CPU-oracle checks for the GPU coverage prototype's shared arithmetic. */
module sparkles.ui_vulkan.coverage_shading_test;

import sparkles.font;
import sparkles.shaders : v2, v4;
import sparkles.ui_vulkan.coverage_shading : CoverageAccumulator, CoverageGlyph, coveragePixel;
import sparkles.ui_vulkan.coverage_geometry : packCoverageEdges;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.shaders : vec4;

/// Flattened directed edges must preserve hinted variable coverage to one
/// 8-bit level, including the oracle's overlap-union sampling and rounding.
@("ui_vulkan.coverage_shading.matchesCpuRasterizer")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import std.conv : text;

    struct Buffers
    {
        OutlineSegment[4096] segments;
        OutlinePoint[4096] points;
        bool[4096] onCurve;
        ushort[1024] ends;
        uint[4096] numbers;
        int[4096] dx, dy;
        int[2][4096] referenced;
        float[262_144] accumulation;
        ubyte[16_384] supersample, pixels;
        RasterEdge[512] edges;
        RasterWorkspace workspace() return @safe pure nothrow @nogc
            => RasterWorkspace(segments[], points[], onCurve[], ends[], accumulation[], supersample[],
                numbers[], dx[], dy[], referenced[]);
    }
    auto buffers = new Buffers;
    const path = environment.get("SPARKLES_FONTS_PATH");
    assert(path.length, "SPARKLES_FONTS_PATH is required");
    const bytes = cast(const(ubyte)[])read(buildPath(path, "NotoSans.ttf"));
    const face = openFace(bytes).value;
    const map = charMap(face).value;
    foreach (weight; [100, 900])
        foreach (hinted; [false, true])
        foreach (size; [9, 12, 28, 48])
        {
            const ppem = Ppem.fromInteger(size).value;
            auto inst = face.instance(InstanceSize.pixels(ppem),
                [UserCoordinate(Tag("wght"), weight << 16)]).value;
            auto ws = buffers.workspace;
            const hints = lightHints(inst, map, ppem, ws.segments, ws.outline);
            foreach (cp; ['A', 'g', 'o', 'ß', 'é', 'Ω', 'Ж'])
            {
                const prepared = prepareRaster(inst, map.glyph(cp), ppem, ws,
                    OverlapMode.perGlyphFlag, hinted ? &hints : null).value;
                const m = prepared.metrics;
                assert(prepared.rasterize(RasterRegion(buffers.pixels[], m.width, m.width, m.height), ws).hasValue);
                const count = prepared.edges(buffers.edges[]).value;
                UniqueBuffer!vec4 banded;
                const layout = packCoverageEdges(buffers.edges[0 .. count], cast(uint)m.height, true, banded);
                CoverageGlyph glyph;
                glyph.info = v4(cast(float)count, prepared.unionCoverage ? 1 : 0, 0, 0);
                foreach (i, edge; buffers.edges[0 .. count])
                    glyph.edges[i] = v4(cast(float)edge.x0, cast(float)edge.y0,
                        cast(float)edge.x1, cast(float)edge.y1);
                foreach (y; 0 .. m.height)
                    foreach (x; 0 .. m.width)
                    {
                        const actual = cast(int)(coveragePixel(glyph, v2(cast(float)x, cast(float)y)) * 255 + 0.5f);
                        const expected = buffers.pixels[y * m.width + x];
                        assert(actual >= expected - 1 && actual <= expected + 1,
                            text(cp, " w", weight, " hints=", hinted, " at ", x, ',', y,
                                ": ", actual, " vs ", expected));
                        CoverageAccumulator accumulator;
                        accumulator.clear();
                        const first = cast(size_t)y / layout.bandHeight * layout.stride;
                        foreach (edge; banded[][first .. first + layout.stride])
                            accumulator.add(edge, v2(cast(float)x, cast(float)y), prepared.unionCoverage);
                        assert(cast(int)(accumulator.finish(prepared.unionCoverage) * 255 + 0.5f) == actual,
                            "banding must preserve the complete edge shader exactly");
                    }
            }
        }
}
