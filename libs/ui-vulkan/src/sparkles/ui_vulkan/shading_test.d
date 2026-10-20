/**
The canvas's shading, tested on the host against oracles that share none of
its arithmetic (`testing.md`): coverage integrated at 16×16 samples per
pixel, and the clip-space corners a viewport transform must land on whole
pixels. Host-only: a `@compute` module holds no string literals, and a test
name is one.
*/
module sparkles.ui_vulkan.shading_test;

version (unittest):

import std.math : fabs;

import sparkles.shaders : PushConstants, v2, v4, vec2, vec4;
import sparkles.ui_vulkan.shading;

/// The supersampled oracle's resolution per axis.
private enum samples = 16;

/// The fraction of pixel `(x, y)` inside `inside`, at `samples`² points.
private double exactCoverage(scope bool delegate(double, double) @safe pure nothrow @nogc inside,
    int x, int y) @safe pure nothrow @nogc
{
    int hits;
    foreach (j; 0 .. samples)
        foreach (i; 0 .. samples)
            hits += inside(x + (i + 0.5) / samples, y + (j + 0.5) / samples);
    return cast(double) hits / (samples * samples);
}

/// The alpha `shade` leaves at pixel `(x, y)` for a record of `shape` over
/// `box`, a white fill of `fillAlpha` and a black edge of `edgeAlpha`.
private float shadedAlpha(vec4 box, vec4 shape, int x, int y, float fillAlpha = 1,
    float edgeAlpha = 0) @safe pure nothrow @nogc
    => shade(v2(x + 0.5f, y + 0.5f), box, v4(1, 1, 1, fillAlpha), v4(0, 0, 0, edgeAlpha), shape,
        v4(0), v4(0), v4(0), 0).array[3];

/// The worst and the mean error over the pixels of `[x0, x1) × [y0, y1)`
/// partly covered by the oracle's region.
private struct Errors
{
    double worst = 0, sum = 0;
    int edgePixels;

    double mean() const @safe pure nothrow @nogc => edgePixels ? sum / edgePixels : 0;
}

private Errors compare(scope bool delegate(double, double) @safe pure nothrow @nogc inside,
    scope float delegate(int, int) @safe pure nothrow @nogc rendered,
    int x0, int y0, int x1, int y1) @safe pure nothrow @nogc
{
    Errors e;
    foreach (y; y0 .. y1)
        foreach (x; x0 .. x1)
        {
            const want = exactCoverage(inside, x, y);
            const err = fabs(rendered(x, y) - want);
            if (err > e.worst)
                e.worst = err;
            if (want > 0 && want < 1)
            {
                e.sum += err;
                ++e.edgePixels;
            }
        }
    return e;
}

/// Inside the box `(bx, by, bw, bh)` with corners of radius `r`.
private bool inRoundedBox(double px, double py, double bx, double by, double bw, double bh,
    double r) @safe pure nothrow @nogc
{
    if (px < bx || px > bx + bw || py < by || py > by + bh)
        return false;
    const cx = px < bx + r ? bx + r : px > bx + bw - r ? bx + bw - r : px;
    const cy = py < by + r ? by + r : py > by + bh - r ? by + bh - r : py;
    return (px - cx) ^^ 2 + (py - cy) ^^ 2 <= r * r;
}

@("ui_vulkan.shading.roundedBoxCoverageWithinTolerance")
@safe pure nothrow @nogc
unittest
{
    // `UVK11`: radii 0, 3 and 12 CSS px at densities 1 and 2.75, on boxes of
    // whole and fractional sizes.
    static immutable float[2][3] sizes = [[40, 24], [17, 9.5f], [64, 64]];
    foreach (density; [1.0f, 2.75f])
        foreach (css; [0, 3, 12])
            foreach (size; sizes)
            {
                const r = css * density;
                const box = v4(5, 7, size[0], size[1]);
                const radius = r < size[0] / 2 && r < size[1] / 2 ? r
                    : (size[0] < size[1] ? size[0] : size[1]) / 2;
                const shape = v4(QuadKind.roundedBox, radius, 0, 1);
                const e = compare((px, py) => inRoundedBox(px, py, 5, 7, size[0], size[1], radius),
                    (x, y) => shadedAlpha(box, shape, x, y), 0, 0, 80, 80);
                assert(e.worst <= 16.0 / 255, "worst");
                assert(e.mean <= 2.0 / 255, "mean");
            }
}

@("ui_vulkan.shading.roundedBorderRingWithinTolerance")
@safe pure nothrow @nogc
unittest
{
    // The ring outside a rounded box: between its edge and the edge grown by
    // the border's thickness, radius grown with it, as the reference draws it.
    foreach (t; [1.0f, 2.0f, 2.75f])
        foreach (r; [3.0f, 12.0f])
        {
            const box = v4(10, 10, 40, 30);
            const shape = v4(QuadKind.roundedBox, r, t, t + 1);
            const e = compare((px, py) => inRoundedBox(px, py, 10 - t, 10 - t, 40 + 2 * t,
                    30 + 2 * t, r + t) && !inRoundedBox(px, py, 10, 10, 40, 30, r),
                (x, y) => shadedAlpha(box, shape, x, y, 0, 1), 0, 0, 64, 64);
            assert(e.worst <= 16.0 / 255, "worst");
            assert(e.mean <= 2.0 / 255, "mean");
        }
}

@("ui_vulkan.shading.aSolidQuadCoversEveryPixelFully")
@safe pure nothrow @nogc
unittest
{
    // `UVK9`: the quad is the box; the shading adds no coverage of its own.
    const box = v4(3, 4, 5, 6);
    foreach (y; 4 .. 10)
        foreach (x; 3 .. 8)
            assert(shadedAlpha(box, v4(QuadKind.solid, 0, 0, 0), x, y, 0.5f) == 0.5f);
}

/// Inside the arrow's triangle: apex at the top's middle, base along the
/// bottom of `(bx, by, bw, bh)`.
private bool inArrow(double px, double py, double bx, double by, double bw, double bh)
    @safe pure nothrow @nogc
{
    if (py > by + bh || py < by)
        return false;
    const half = bw / 2 * (py - by) / bh;
    return fabs(px - (bx + bw / 2)) <= half;
}

@("ui_vulkan.shading.arrowEdgesWithinTolerance")
@safe pure nothrow @nogc
unittest
{
    // `UVK11`'s tolerance on the arrow's edges: the triangle of
    // `arrowTriangle` for cells 16 and 42 px tall.
    foreach (size; [5.0f, 14.0f])
    {
        const box = v4(20.5f, 10, 2 * size, size + 1);
        const shape = v4(QuadKind.arrow, 0, 0, 1);
        const e = compare((px, py) => inArrow(px, py, 20.5, 10, 2 * size, size + 1),
            (x, y) => shadedAlpha(box, shape, x, y), 0, 0, 64, 40);
        assert(e.worst <= 16.0 / 255, "worst");
        assert(e.mean <= 2.0 / 255, "mean");
    }
}

@("ui_vulkan.shading.premultipliesAndDecodesForSrgb")
@safe pure nothrow @nogc
unittest
{
    // `UVK6`: straight colour in, premultiplied out.
    const p = premultiplied(v4(0.8f, 0.4f, 0.2f, 0.5f), 1, 0);
    assert(p.array == [0.4f, 0.2f, 0.1f, 0.5f]);
    // `UVK7`: on an sRGB target an opaque colour is decoded, so the target's
    // encoding stores the value a `UNORM` target stores.
    const s = premultiplied(v4(0.5f, 1, 0, 1), 1, 1);
    assert(fabs(s.array[0] - 0.21404f) < 1e-4 && s.array[1] == 1 && s.array[2] == 0);
    // A colour glyph arrives premultiplied and keeps its colour.
    const g = shade(v2(0.5f, 0.5f), v4(0, 0, 1, 1), v4(1, 1, 1, 1), v4(0), v4(QuadKind.colourGlyph, 0, 0, 0),
        v4(0), v4(0.25f, 0, 0, 0.5f), v4(0), 0);
    assert(g.array == [0.25f, 0, 0, 0.5f]);
    // An image's texels are straight, and the foreground alpha scales them.
    const i = shade(v2(0.5f, 0.5f), v4(0, 0, 1, 1), v4(1, 1, 1, 0.5f), v4(0), v4(QuadKind.image, 0, 0, 0),
        v4(0), v4(0), v4(1, 0.5f, 0, 1), 0);
    assert(i.array == [0.5f, 0.25f, 0, 0.5f]);
}

@("ui_vulkan.shading.cornersLandOnWholePixels")
@safe pure nothrow @nogc
unittest
{
    // The viewport transform of each corner's clip position must give back
    // the box's integer corners, or a plain fill would miss its last pixel
    // row (`UVK9`).
    const view = PushConstants!CanvasView(CanvasView(extent: v2(800, 600)));
    const box = v4(13, 7, 120, 31);
    const float[2][4] want = [[13, 7], [133, 7], [13, 38], [133, 38]];
    foreach (i; 0 .. 4)
    {
        const v = canvasVertex(i, box, v4(0), v4(0), v4(0), v4(0, 0, 1, 1), view);
        const x = (v.position.array[0] + 1) / 2 * 800;
        const y = (v.position.array[1] + 1) / 2 * 600;
        assert(fabs(x - want[i][0]) < 1e-3 && fabs(y - want[i][1]) < 1e-3);
    }
    const t = canvasVertex(3, box, v4(0), v4(0), v4(0), v4(0.25f, 0.5f, 0.75f, 1), view);
    assert(t.vTexCoord.array == [0.75f, 1]);
}

@("ui_vulkan.shading.anInstanceIsFiveVectors")
@safe pure nothrow @nogc
unittest
{
    // The vertex input attributes are declared from these offsets.
    static assert(Instance.sizeof == 80);
    static assert(Instance.box.offsetof == 0 && Instance.texRect.offsetof == 64);
}
