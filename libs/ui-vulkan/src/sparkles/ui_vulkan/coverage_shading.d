/** Analytic coverage over the font rasterizer's directed flattened edges. */
@compute(CompileFor.hostAndDevice) @profiles(vulkan13, vulkan11)
module sparkles.ui_vulkan.coverage_shading;

import sparkles.shaders;

/// One glyph's bounded fragment input; larger outlines use the CPU path.
struct CoverageGlyph
{
    vec4 info; // edge count, overlap-union flag, reserved, reserved
    vec4[512] edges;
}

private float primitive(float x) @safe pure nothrow @nogc
    => x <= 0 ? x : x < 1 ? x - x * x * 0.5f : 0.5f;

// Keep the array index independent of LLVM's widened pointer induction.
// SPIR-V profiles here deliberately do not require 64-bit integer arithmetic.
pragma(inline, false)
private uint edgeIndex(uint value) @safe pure nothrow @nogc => value & 511u;

/// Signed area deposited to the left of one output pixel by a directed edge.
float edgeArea(vec4 edge, vec2 at) @safe pure nothrow @nogc
{
    float sign = 1;
    if (edge.y > edge.w)
    {
        sign = -1;
        edge = v4(edge.z, edge.w, edge.x, edge.y);
    }
    const lo = max(edge.y, at.y), hi = min(edge.w, at.y + 1);
    if (hi <= lo) return 0;
    const slope = (edge.z - edge.x) / (edge.w - edge.y);
    const a = edge.x + (lo - edge.y) * slope - at.x;
    const b = edge.x + (hi - edge.y) * slope - at.x;
    if (a <= 0 && b <= 0) return sign * (hi - lo);
    if (a >= 1 && b >= 1) return 0;
    const average = abs(b - a) < 0.000001f ? clamp(1 - (a + b) * 0.5f, 0.0f, 1.0f)
        : (primitive(b) - primitive(a)) / (b - a);
    return sign * (hi - lo) * average;
}

private vec4 primitive4(vec4 x) @safe pure nothrow @nogc
{
    const t = clamp(x, 0.0f, 1.0f);
    return min(x, v4(0)) + t - t * t * 0.5f;
}

// Adjacent subpixels share clipping/interpolation. Vector arithmetic serves
// the CPU oracle and device code; edge data is fetched once for all 16 samples.
private vec4 edgeAreaRow(vec4 edge, vec2 at) @safe pure nothrow @nogc
{
    float sign = 1;
    if (edge.y > edge.w) { sign = -1; edge = v4(edge.z, edge.w, edge.x, edge.y); }
    const lo = max(edge.y, at.y), hi = min(edge.w, at.y + 1);
    if (hi <= lo) return v4(0);
    const slope = (edge.z - edge.x) / (edge.w - edge.y);
    const xa = edge.x + (lo - edge.y) * slope;
    const xb = edge.x + (hi - edge.y) * slope;
    const positions = v4(at.x, at.x + 1, at.x + 2, at.x + 3);
    const a = v4(xa) - positions, b = v4(xb) - positions;
    auto average = abs(xb - xa) < 0.000001f ? clamp(v4(1) - (a + b) * 0.5f, 0.0f, 1.0f)
        : (primitive4(b) - primitive4(a)) / (xb - xa);
    const left = step(v4(0), -a) * step(v4(0), -b);
    const right = step(v4(1), a) * step(v4(1), b);
    return mix(average, v4(1), left) * (v4(1) - right) * (sign * (hi - lo));
}

/// Small per-pixel state shared by the host and fragment implementation.
struct CoverageAccumulator
{
    private float single;
    private vec4 row0, row1, row2, row3;

    /// Starts a pixel without allocating or retaining geometry.
    void clear() scope @safe pure nothrow @nogc
    {
        single = 0;
        row0 = row1 = row2 = row3 = v4(0);
    }

    /// Adds one directed edge, optionally with 4×4 union sampling.
    void add(vec4 edge, vec2 at, bool unionCoverage) scope @safe pure nothrow @nogc
    {
        if (!unionCoverage) { single += edgeArea(edge, at); return; }
        edge *= 4;
        const base = at * 4;
        row0 += edgeAreaRow(edge, base);
        row1 += edgeAreaRow(edge, base + v2(0, 1));
        row2 += edgeAreaRow(edge, base + v2(0, 2));
        row3 += edgeAreaRow(edge, base + v2(0, 3));
    }

    /// Quantized coverage using the CPU rasterizer's subpixel rounding.
    float finish(bool unionCoverage) const scope @safe pure nothrow @nogc
    {
        if (!unionCoverage) return floor(clamp(abs(single), 0.0f, 1.0f) * 255 + 0.5f) / 255;
        const a = floor(clamp(abs(row0), 0.0f, 1.0f) * 255 + v4(0.5f));
        const b = floor(clamp(abs(row1), 0.0f, 1.0f) * 255 + v4(0.5f));
        const c = floor(clamp(abs(row2), 0.0f, 1.0f) * 255 + v4(0.5f));
        const d = floor(clamp(abs(row3), 0.0f, 1.0f) * 255 + v4(0.5f));
        return floor(dot(a + b + c + d, v4(1)) / 16 + 0.5f) / 255;
    }
}

/// Linear 8-bit coverage, including the CPU oracle's per-subpixel rounding.
float coveragePixel(ref const CoverageGlyph glyph, vec2 at) @safe pure nothrow @nogc
{
    const declared = cast(int)glyph.info.x;
    const count = declared < 512 ? declared : 512;
    const unionCoverage = glyph.info.y > 0.5f;
    CoverageAccumulator accumulator;
    accumulator.clear();
    for (int i = 0; i < count; ++i)
        accumulator.add(glyph.edges[edgeIndex(cast(uint)i)], at, unionCoverage);
    return accumulator.finish(unionCoverage);
}
