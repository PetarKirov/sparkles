/** Bounded frame-local geometry for the experimental coverage renderer. */
module sparkles.ui_vulkan.coverage_geometry;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.font : RasterEdge;
import sparkles.shaders : vec4, v4;

/// Explicit comparison modes; the ordinary hinted atlas remains the default.
enum CoverageMode { cpu, edges, bands }

/// Worker elapsed-time sums (including preemption), not elapsed frame time.
/// Enabled only for experiments.
struct CoverageWork
{
    ulong prepareNs, flattenNs, packNs, rasterNs;
    ulong glyphs; /// Attempted jobs, including blank/unsupported glyphs.
    ulong edges, texels, bandStrideSum;
    ulong geometryGlyphs, fallbackGlyphs, publishedGlyphs;
    ulong batchNs; /// Caller wall time, including joining and publishing.

    /// Combines completed batches without treating concurrent work as latency.
    void add(in CoverageWork other) scope @safe pure nothrow @nogc
    {
        prepareNs += other.prepareNs; flattenNs += other.flattenNs;
        packNs += other.packNs; rasterNs += other.rasterNs;
        glyphs += other.glyphs; edges += other.edges; texels += other.texels;
        bandStrideSum += other.bandStrideSum; batchNs += other.batchNs;
        geometryGlyphs += other.geometryGlyphs; fallbackGlyphs += other.fallbackGlyphs;
        publishedGlyphs += other.publishedGlyphs;
    }
}

/// Uniform list length and vertical spacing, in output pixels.
struct CoverageLayout
{
    uint stride;
    uint bandHeight;
}

/**
Packs complete directed edges in their original order. Four-pixel bands use
the maximum list length as their common stride, padded with horizontal zero
edges. Consequently texture fetches occur in uniform shader control flow.
Edges on band boundaries are included conservatively; no x culling discards
the winding contribution from edges to the left of the fragment.
Inputs exceed neither the worker's 512-edge nor 128-pixel height limit.
*/
CoverageLayout packCoverageEdges(in RasterEdge[] edges, uint height, bool banded,
    ref UniqueBuffer!vec4 output) @safe pure nothrow @nogc
in (edges.length <= 512 && height <= 128)
{
    const rows = banded ? (height + 3) / 4 : 1;
    uint[32] counts;
    uint stride;
    bool intersects(in RasterEdge e, uint row) @safe pure nothrow @nogc
    {
        const lo = e.y0 < e.y1 ? e.y0 : e.y1;
        const hi = e.y0 > e.y1 ? e.y0 : e.y1;
        return !banded || (lo <= (row + 1) * 4 && hi >= row * 4);
    }
    foreach (row; 0 .. rows)
    {
        foreach (edge; edges)
            if (intersects(edge, row)) ++counts[row];
        if (counts[row] > stride) stride = counts[row];
    }
    output.length = rows * stride;
    auto data = output[];
    data[] = v4(0);
    foreach (row; 0 .. rows)
    {
        size_t i = row * stride;
        foreach (edge; edges)
            if (intersects(edge, row))
                output[][i++] = v4(cast(float)edge.x0, cast(float)edge.y0,
                    cast(float)edge.x1, cast(float)edge.y1);
    }
    return CoverageLayout(stride, banded ? 4 : 0);
}

/// Band selection retains far-left winding, opposite directions and edges
/// exactly on a boundary, including zero-filled unused entries.
@("ui_vulkan.coverage_geometry.bandsPreserveCoverage")
@safe pure nothrow @nogc unittest
{
    import sparkles.shaders : v2;
    import sparkles.ui_vulkan.coverage_shading : CoverageAccumulator;

    RasterEdge[7] edges = [RasterEdge(-2, 0, -2, 12), RasterEdge(9, 12, 9, 0),
        RasterEdge(2, 3.75, 7, 4.25), RasterEdge(7, 4.25, 2, 3.75),
        RasterEdge(2, 10, 7, 11), RasterEdge(7, 11, 2, 10), RasterEdge(0, 8, 8, 8)];
    UniqueBuffer!vec4 plain, bands;
    const a = packCoverageEdges(edges[], 12, false, plain);
    const b = packCoverageEdges(edges[], 12, true, bands);
    assert(b.stride < a.stride);
    foreach (unionCoverage; [false, true])
        foreach (y; 0 .. 12)
            foreach (x; 0 .. 12)
            {
                CoverageAccumulator whole, band;
                whole.clear(); band.clear();
                const at = v2(cast(float)x, cast(float)y);
                foreach (edge; plain[]) whole.add(edge, at, unionCoverage);
                const first = y / b.bandHeight * b.stride;
                foreach (edge; bands[][first .. first + b.stride]) band.add(edge, at, unionCoverage);
                assert(whole.finish(unionCoverage) == band.finish(unionCoverage));
            }
}
