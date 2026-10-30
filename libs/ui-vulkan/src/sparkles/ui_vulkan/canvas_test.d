/**
The canvas on a real driver: `testing.md`'s canvas scenarios, drawn on
lavapipe with the validation layer listening, each target read back and
judged by an oracle that shares no arithmetic with the canvas — exact pixel
sets from integer rectangles and the shared geometry functions, coverage
integrated at 16×16 samples, the premultiplied-over formula on the host.

Opt-in (`SPARKLES_VULKAN_READBACK=1`): they need a driver and the layer, and
opted in they fail rather than skip when they cannot run.
*/
module sparkles.ui_vulkan.canvas_test;

version (unittest):

import std.format : format, text = format;
import std.math : abs, fabs, lround;

import sparkles.base.term_color : RgbColor;
import sparkles.test_runner.skip : skipTest;
import sparkles.ui.canvas : LineStyle, RuleEdge, Scrollbar;
import sparkles.ui.geometry : Insets, Point, Rect, Size;
import sparkles.ui.image : ImageData, ImageFit, ImageHandle, ImageRegistry;
import sparkles.ui.pixel_geometry;
import sparkles.ui.style : BorderStyle, BoxBorder, FontRole, Shadow, Visual;
import sparkles.ui_vulkan.canvas;
import sparkles.ui_vulkan.painter : Degradation, FrameMetrics, FrameReport;
import sparkles.ui_vulkan.pipelines : DeviceFacts;
import sparkles.ui_vulkan.resources : GpuBuffer, GpuImage;
import sparkles.ui_vulkan.upload : transition;
import sparkles.vulkan;
import sparkles.ui_vulkan.testing;
import sparkles.vulkan_wsi.testing : HeadlessSession, readbackEnabled, readbackSkipReason,
    succeeded;

/// The RGBA bytes of pixel `(x, y)` of a `width`-pixel-wide frame.
package ubyte[4] pixel(const(ubyte)[] frame, uint width, int x, int y)
{
    const at = (y * width + x) * 4;
    return frame[at .. at + 4][0 .. 4];
}

/// `src` at `alpha` over `dst`, in 8-bit units, as the premultiplied-over
/// formula gives it before rounding.
package double[3] over(RgbColor src, double alpha, in ubyte[4] dst)
    => [src.r * alpha + dst[0] * (1 - alpha), src.g * alpha + dst[1] * (1 - alpha),
        src.b * alpha + dst[2] * (1 - alpha)];

/// Whether `got` is `want` within `tolerance` in every colour channel.
package bool near(in ubyte[4] got, in double[3] want, double tolerance)
    => fabs(got[0] - want[0]) <= tolerance && fabs(got[1] - want[1]) <= tolerance
        && fabs(got[2] - want[2]) <= tolerance;

/// A filled box of `bg` at `alpha`.
package Visual filled(RgbColor bg, ubyte alpha = 0xFF)
    => Visual(bg: bg, bgAlpha: alpha, hasBg: true);

private enum RgbColor ground = RgbColor(20, 40, 60);

/// The two cell sizes and two densities every scenario runs at.
package immutable FrameMetrics[4] metricsUnderTest = [
    FrameMetrics(cellW: 10, cellH: 20, originX: 3, originY: 2, density: 1),
    FrameMetrics(cellW: 9, cellH: 17, originX: 0, originY: 5, density: 1),
    FrameMetrics(cellW: 10, cellH: 20, originX: 3, originY: 2, density: 2),
    FrameMetrics(cellW: 9, cellH: 17, originX: 0, originY: 5, density: 2.75f),
];

@("ui_vulkan.canvas.plainFillChangesExactlyItsPixels")
@system unittest
{
    // Canvas scenario 1 (`UVK9`, `UVK6`): every pixel inside the fill is
    // composited, every pixel outside is the ground, at both alphas.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-plain-fill", 160, 120);
    scope (success)
        rig.close();

    const colour = RgbColor(200, 100, 50);
    foreach (m; metricsUnderTest)
        foreach (alpha; [ubyte(255), ubyte(128)])
        {
            const cells = Rect(2, 1, 5, 3);
            const frame = rig.draw((ref Canvas c) { c.fillRect(cells, filled(colour, alpha)); },
                m, ground);
            const box = Rect(m.originX + cells.x * m.cellW, m.originY + cells.y * m.cellH,
                cells.width * m.cellW, cells.height * m.cellH);
            const ubyte[4] g = [ground.r, ground.g, ground.b, 255];
            foreach (y; 0 .. 120)
                foreach (x; 0 .. 160)
                {
                    const got = pixel(frame, 160, x, y);
                    if (box.contains(Point(x, y)))
                        assert(near(got, over(colour, alpha / 255.0, g), alpha == 255 ? 0 : 1),
                            format("(%s, %s) inside at %s: %s", x, y, alpha, got));
                    else
                        assert(got == g, format("(%s, %s) outside: %s", x, y, got));
                }
        }
}

@("ui_vulkan.canvas.aPixelFillIsNotScaledByTheCell")
@system unittest
{
    // `UVK35`: a 4×3 pixel fill at (10, 20) covers those pixels and no
    // others, whatever the cell size is.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-pixel-fill", 80, 40);
    scope (success)
        rig.close();

    import sparkles.ui_vulkan.painter : rgba;

    const colour = RgbColor(200, 100, 50);
    const m = metricsUnderTest[0];
    const box = Rect(m.originX + 10, m.originY + 20, 4, 3);
    const frame = rig.draw((ref Canvas c) {
        c.fillPx(10, 20, box.width, box.height, rgba(colour, 255));
    }, m, ground);
    const ubyte[4] g = [ground.r, ground.g, ground.b, 255];
    foreach (y; 0 .. 40)
        foreach (x; 0 .. 80)
        {
            const got = pixel(frame, 80, x, y);
            if (box.contains(Point(x, y)))
                assert(got[0] == colour.r && got[1] == colour.g && got[2] == colour.b,
                    format("(%s, %s) inside: %s", x, y, got));
            else
                assert(got == g, format("(%s, %s) outside: %s", x, y, got));
        }
}

@("ui_vulkan.canvas.aPixelCircleIsARoundedBox")
@system unittest
{
    // `UVK35`: a rounded pixel box whose radius is half its side is a disc,
    // within the rounded boxes' tolerance, wherever the cells are.
    import sparkles.ui_vulkan.painter : rgba;
    import sparkles.ui_vulkan.shading_test : inRoundedBox;

    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-pixel-circle", 80, 40);
    scope (success)
        rig.close();

    foreach (m; metricsUnderTest[0 .. 2])
    {
        const frame = rig.draw((ref Canvas c) {
            c.roundedPx(10, 6, 20, 20, 10, rgba(white, 255));
        }, m, black);
        const double bx = m.originX + 10, by = m.originY + 6;
        const e = coverageErrors(frame, 80, 40,
            (px, py) => inRoundedBox(px, py, bx, by, 20, 20, 10));
        assert(e[0] <= 16.0 / 255 && e[1] <= 2.0 / 255,
            format("worst %.1f/255, mean %.2f/255", e[0] * 255, e[1] * 255));
    }
}

@("ui_vulkan.canvas.aTurnedTargetIsDrawnPreRotated")
@system unittest
{
    // `UVK39`: an 80×40 display on a 40×80 target the presentation engine
    // turns a quarter turn clockwise. A fill lands, clipped, where that turn
    // brings it back to its display pixels, and a disc is shaded where it
    // shows: display (x, y) is target (40 - 1 - y, x).
    import sparkles.ui_vulkan.painter : rgba;
    import sparkles.ui_vulkan.shading_test : inRoundedBox;

    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-turned", 40, 80);
    scope (success)
        rig.close();
    rig.turn = 1;

    const colour = RgbColor(200, 100, 50);
    const m = FrameMetrics(cellW: 10, cellH: 20);
    const frame = rig.draw((ref Canvas c) {
        c.clipPx(0, 0, 12, 40);
        c.fillPx(10, 20, 4, 3, rgba(colour, 255)); // display x 10–11 survive the clip
        c.unclipPx();
    }, m, black);
    foreach (v; 0 .. 80)
        foreach (u; 0 .. 40)
        {
            const got = pixel(frame, 40, u, v);
            // The display pixel this target pixel shows.
            const x = v, y = 40 - 1 - u;
            const inside = x >= 10 && x < 12 && y >= 20 && y < 23;
            assert(inside ? got[0] == colour.r && got[1] == colour.g && got[2] == colour.b
                : got[0 .. 3] == [0, 0, 0], format("target (%s, %s), display (%s, %s): %s",
                    u, v, x, y, got));
        }

    const disc = rig.draw((ref Canvas c) {
        c.roundedPx(50, 8, 20, 20, 10, rgba(white, 255));
    }, m, black);
    // Back to display order, then against the disc's coverage there.
    auto upright = new ubyte[80 * 40 * 4];
    foreach (y; 0 .. 40)
        foreach (x; 0 .. 80)
            upright[(y * 80 + x) * 4 .. (y * 80 + x) * 4 + 4] = pixel(disc, 40, 40 - 1 - y, x);
    const e = coverageErrors(upright, 80, 40, (px, py) => inRoundedBox(px, py, 50, 8, 20, 20, 10));
    assert(e[0] <= 16.0 / 255 && e[1] <= 2.0 / 255,
        format("worst %.1f/255, mean %.2f/255", e[0] * 255, e[1] * 255));
}

// ── helpers for the scenarios ──

private enum RgbColor white = RgbColor(255, 255, 255);
private enum RgbColor black = RgbColor(0, 0, 0);

/// The device pixels of cell rect `r` under `m`.
private Rect pixelsOf(in Rect r, in FrameMetrics m)
    => Rect(m.originX + r.x * m.cellW, m.originY + r.y * m.cellH, r.width * m.cellW,
        r.height * m.cellH);

/// Asserts that exactly the pixels of `set` are white and the rest black.
private void assertExactly(const(ubyte)[] frame, uint width, uint height, const(Rect)[] set,
    string what)
{
    foreach (y; 0 .. height)
        foreach (x; 0 .. width)
        {
            bool inside;
            foreach (r; set)
                inside |= r.contains(Point(x, y));
            const got = pixel(frame, width, x, y);
            assert(got[0 .. 3] == (inside ? [ubyte(255), 255, 255] : [ubyte(0), 0, 0]),
                format("%s: (%s, %s) is %s, expected %s", what, x, y, got,
                    inside ? "drawn" : "untouched"));
        }
}

/// The coverage a white-on-black frame shows at each pixel, against the
/// region `inside`: the worst error and the mean over partly covered pixels.
private double[2] coverageErrors(const(ubyte)[] frame, uint width, uint height,
    scope bool delegate(double, double) @safe pure nothrow @nogc inside)
{
    import sparkles.ui_vulkan.shading_test : exactCoverage;

    double worst = 0, sum = 0;
    int edges;
    foreach (y; 0 .. height)
        foreach (x; 0 .. width)
        {
            const want = exactCoverage(inside, x, y);
            const err = fabs(pixel(frame, width, x, y)[0] / 255.0 - want);
            worst = err > worst ? err : worst;
            if (want > 0 && want < 1)
            {
                sum += err;
                ++edges;
            }
        }
    return [worst, edges ? sum / edges : 0];
}

/// A solid `width`×`height` RGBA image of `c` at `alpha`.
private ubyte[] solidImage(uint width, uint height, RgbColor c, ubyte alpha = 255)
{
    auto rgba = new ubyte[width * height * 4];
    foreach (i; 0 .. width * height)
        rgba[i * 4 .. i * 4 + 4] = [c.r, c.g, c.b, alpha];
    return rgba;
}

// ── the scenarios ──

@("ui_vulkan.canvas.roundedBoxesWithinTolerance")
@system unittest
{
    // Canvas scenario 2 (`UVK11`, `UVK8`): radii 0, 3 and 12 CSS px, with
    // and without a border, against coverage integrated at 16×16 samples.
    import sparkles.ui_vulkan.shading_test : inRoundedBox;

    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-rounded", 160, 120);
    scope (success)
        rig.close();

    foreach (m; metricsUnderTest)
        foreach (css; [0, 3, 12])
            foreach (bordered; [false, true])
            {
                const cells = Rect(2, 1, 6, 3);
                const box = pixelsOf(cells, m);
                const radius = cornerRadiusPx(densityPx(css, m.density), box.width, box.height);
                auto v = bordered
                    ? Visual(border: BoxBorder(width: Insets.all(1), style: BorderStyle.solid,
                        color: white), borderRadius: css)
                    : Visual(bg: white, hasBg: true, borderRadius: css);
                const frame = rig.draw((ref Canvas c) { c.fillRect(cells, v); }, m, black);
                if (css == 0)
                {
                    // A square box is scenario 1's fill, or the shared
                    // geometry's border: exact.
                    Rect[8] set;
                    size_t n;
                    if (bordered)
                        borderRects(box, Insets.all(1), BorderStyle.solid, m.cellW, m.cellH,
                            (Rect r) { set[n++] = r; });
                    else
                        set[n++] = box;
                    assertExactly(frame, 160, 120, set[0 .. n], "a square box");
                    continue;
                }
                const t = roundedBorderPx(Insets.all(1), m.density);
                const double bx = box.x, by = box.y, bw = box.width, bh = box.height;
                const e = bordered
                    ? coverageErrors(frame, 160, 120, (px, py) => inRoundedBox(px, py, bx - t,
                        by - t, bw + 2 * t, bh + 2 * t, radius + t)
                        && !inRoundedBox(px, py, bx, by, bw, bh, radius))
                    : coverageErrors(frame, 160, 120,
                        (px, py) => inRoundedBox(px, py, bx, by, bw, bh, radius));
                assert(e[0] <= 16.0 / 255 && e[1] <= 2.0 / 255,
                    format("radius %s css at density %s%s: worst %.1f/255, mean %.2f/255", css,
                        m.density, bordered ? " (border)" : "", e[0] * 255, e[1] * 255));
            }
}

@("ui_vulkan.canvas.sharedGeometryChangesExactlyItsPixels")
@system unittest
{
    // Canvas scenario 3 (`UVK10`, `UVK12`): each piece of chrome changes
    // exactly the pixels its function in `sparkles.ui.pixel_geometry` names.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-geometry", 160, 120);
    scope (success)
        rig.close();

    foreach (m; metricsUnderTest)
    {
        const cells = Rect(2, 1, 6, 3);
        const box = pixelsOf(cells, m);
        Rect[256] set;
        size_t n;
        void collect(Rect r) { if (!r.empty) set[n++] = r; }

        foreach (style; [BorderStyle.dashed, BorderStyle.dotted, BorderStyle.double_,
                BorderStyle.solid])
        {
            n = 0;
            borderRects(box, Insets(1, 2, 1, 1), style, m.cellW, m.cellH, &collect);
            const frame = rig.draw((ref Canvas c) {
                c.fillRect(cells, Visual(border: BoxBorder(width: Insets(1, 2, 1, 1),
                    style: style, color: white)));
            }, m, black);
            assertExactly(frame, 160, 120, set[0 .. n], format("a %s border", style));
        }

        n = 0;
        lineRects(box.x, box.y, box.x + box.width, true, m.cellH, &collect);
        auto frame = rig.draw((ref Canvas c) {
            c.line(cells.origin, Point(cells.x + cells.width, cells.y), Visual(fg: white),
                LineStyle.wavy);
        }, m, black);
        assertExactly(frame, 160, 120, set[0 .. n], "a wavy line");

        foreach (edge; [RuleEdge.top, RuleEdge.bottom, RuleEdge.left, RuleEdge.right,
                RuleEdge.centerX, RuleEdge.centerY])
        {
            frame = rig.draw((ref Canvas c) { c.rule(cells, edge, Visual(fg: white)); }, m, black);
            assertExactly(frame, 160, 120, [ruleRect(box, edge)], format("a %s rule", edge));
        }

        // A scrollbar: its lit track in grey, its thumb in white.
        Scrollbar bar = {
            rect: cells, content: 400, viewport: 100, offset: 120, edge: RuleEdge.right,
            fg: white, trackColor: RgbColor(100, 100, 100), trackLit: true, expandPercent: 60,
        };
        const rail = scrollbarRail(bar, m.cellW, m.cellH, m.originX, m.originY);
        assert(rail.live);
        frame = rig.draw((ref Canvas c) { c.scrollbar(bar); }, m, black);
        foreach (y; 0 .. 120)
            foreach (x; 0 .. 160)
            {
                const p = Point(x, y);
                const ubyte want = rail.thumb.contains(p) ? 255 : rail.track.contains(p) ? 100 : 0;
                assert(pixel(frame, 160, x, y)[0] == want, format("scrollbar at (%s, %s)", x, y));
            }

        // A square shadow, and a box drawn smaller than its rect.
        const shadow = Shadow(dx: 3, dy: 2, blur: 5, color: white, alpha: 255);
        const scaled = Shadow(dx: densityPx(3, m.density), dy: densityPx(2, m.density),
            blur: densityPx(5, m.density));
        frame = rig.draw((ref Canvas c) { c.fillRect(cells, Visual(shadow: shadow)); }, m, black);
        assertExactly(frame, 160, 120, [shadowRect(box, scaled)], "a shadow");

        int x = box.x, w = box.width, y = box.y, h = box.height;
        centredSpan(x, w, densityPx(20, m.density));
        centredSpan(y, h, densityPx(14, m.density));
        frame = rig.draw((ref Canvas c) {
            c.fillRect(cells, Visual(bg: white, hasBg: true, drawWidth: 20, drawHeight: 14));
        }, m, black);
        assertExactly(frame, 160, 120, [Rect(x, y, w, h)], "a drawn size");
    }
}

@("ui_vulkan.canvas.nestedClipsUnderAShift")
@system unittest
{
    // Canvas scenario 4 (`UVK13`): three nested clips, the inner two pushed
    // under a half-row shift, and a fill larger than all of them. Only the
    // intersection changes, each inner clip moved with the content.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-clips", 160, 120);
    scope (success)
        rig.close();

    const m = FrameMetrics(cellW: 10, cellH: 20, originX: 3, originY: 2);
    const frame = rig.draw((ref Canvas c) {
        c.pushClip(Rect(1, 1, 10, 5));      // x [13, 113), y [22, 122)
        c.pushShift(0, -0.5f);              // −10 px
        c.pushClip(Rect(0, 2, 8, 3));       // x [3, 83), y [32, 92)
        c.pushClip(Rect(2, 0, 20, 20));     // x [23, 223), y [−8, 392)
        c.fillRect(Rect(-5, -5, 50, 50), Visual(bg: white, hasBg: true));
        c.popClip();
        c.popClip();
        c.popShift();
        c.popClip();
    }, m, black);
    assertExactly(frame, 160, 120, [Rect(23, 32, 60, 60)], "nested clips");
}

@("ui_vulkan.canvas.shiftsRoundHalfAwayFromZero")
@system unittest
{
    // Canvas scenario 5 (`UVK14`): an odd cell width, so half a cell is 4.5
    // pixels: a shift of half a cell moves 5, and two nested shifts add.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-shifts", 160, 120);
    scope (success)
        rig.close();

    const m = FrameMetrics(cellW: 9, cellH: 17);
    auto frame = rig.draw((ref Canvas c) {
        c.pushShift(0.5f, 0);
        c.fillRect(Rect(1, 1, 1, 1), Visual(bg: white, hasBg: true));
        c.pushShift(0.5f, -0.5f);
        c.fillRect(Rect(4, 3, 1, 1), Visual(bg: white, hasBg: true));
        c.popShift();
        c.popShift();
        c.pushShift(-0.5f, 0);
        c.fillRect(Rect(8, 5, 1, 1), Visual(bg: white, hasBg: true));
        c.popShift();
    }, m, black);
    assertExactly(frame, 160, 120, [Rect(9 + 5, 17, 9, 17), Rect(36 + 10, 51 - 9, 9, 17),
        Rect(72 - 5, 85, 9, 17)], "shifted fills");
}

@("ui_vulkan.canvas.paintersOrderSurvivesBatching")
@system unittest
{
    // Canvas scenario 6 (`UVK5`): image A, then a fill, then image A again,
    // overlapping. A batcher that grouped by bound image would draw the fill
    // over the second image.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-order", 160, 120);
    scope (success)
        rig.close();

    const red = RgbColor(255, 0, 0), blue = RgbColor(0, 0, 255);
    const a = rig.images.register(solidImage(8, 8, red), Size(8, 8));
    const m = FrameMetrics(cellW: 10, cellH: 20);
    const frame = rig.draw((ref Canvas c) {
        c.image(Rect(0, 0, 4, 2), a, ImageFit.fill, null, Visual.init);
        c.fillRect(Rect(2, 0, 4, 2), Visual(bg: blue, hasBg: true));
        c.image(Rect(4, 0, 4, 2), a, ImageFit.fill, null, Visual.init);
    }, m, black);
    assert(pixel(frame, 160, 15, 10)[0 .. 3] == [255, 0, 0], "the first image alone");
    assert(pixel(frame, 160, 35, 10)[0 .. 3] == [0, 0, 255], "the fill over the first image");
    assert(pixel(frame, 160, 55, 10)[0 .. 3] == [255, 0, 0], "the second image over the fill");
    assert(pixel(frame, 160, 75, 10)[0 .. 3] == [255, 0, 0], "the second image alone");
}

@("ui_vulkan.canvas.blendsPremultipliedOver")
@system unittest
{
    // Canvas scenario 7 (`UVK6`): a translucent fill and a translucent image
    // over a known ground match the premultiplied-over formula within 1/255
    // per channel. (Colour glyphs join with glyphs, in plan slice V3.)
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-blend", 160, 120);
    scope (success)
        rig.close();

    const fill = RgbColor(250, 120, 10), tint = RgbColor(30, 200, 90);
    const img = rig.images.register(solidImage(4, 4, tint, 128), Size(4, 4));
    const m = FrameMetrics(cellW: 10, cellH: 20);
    const frame = rig.draw((ref Canvas c) {
        c.fillRect(Rect(0, 0, 4, 2), Visual(bg: fill, bgAlpha: 100, hasBg: true));
        c.image(Rect(6, 0, 4, 2), img, ImageFit.fill, null, Visual(fgAlpha: 200));
    }, m, ground);
    const ubyte[4] g = [ground.r, ground.g, ground.b, 255];
    assert(near(pixel(frame, 160, 15, 15), over(fill, 100 / 255.0, g), 1));
    const imageAlpha = (128 / 255.0) * (200 / 255.0);
    assert(near(pixel(frame, 160, 75, 15), over(tint, imageAlpha, g), 1),
        format("%s", pixel(frame, 160, 75, 15)));
}

@("ui_vulkan.canvas.srgbTargetsStoreWhatUnormTargetsStore")
@system unittest
{
    // Canvas scenario 8 (`UVK7`): an opaque fill stores the same value on an
    // sRGB and a `UNORM` target, and the sRGB frame reports `srgbBlending`.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    ubyte[4][2] stored;
    uint[2] reported;
    foreach (i, format_; [VkFormat.VK_FORMAT_R8G8B8A8_UNORM, VkFormat.VK_FORMAT_R8G8B8A8_SRGB])
    {
        auto rig = new Rig;
        rig.open("ui-vulkan-srgb", 64, 64, RigOptions(format: format_));
        FrameReport report;
        const frame = rig.draw((ref Canvas c) {
            c.fillRect(Rect(1, 1, 2, 1), Visual(bg: RgbColor(200, 120, 33), hasBg: true));
        }, FrameMetrics(cellW: 10, cellH: 20), ground, report);
        stored[i] = pixel(frame, 64, 15, 25);
        reported[i] = report[Degradation.srgbBlending];
        assert(pixel(frame, 64, 60, 60)[0 .. 3] == [ground.r, ground.g, ground.b],
            "the ground, too");
        rig.close();
    }
    assert(stored[0] == stored[1], format("UNORM %s, sRGB %s", stored[0], stored[1]));
    assert(reported == [0, 1]);
}

@("ui_vulkan.canvas.anImageUploadsOncePerResidency")
@system unittest
{
    // Canvas scenario 10 (`UVK23`, `UVK32`): one handle drawn in three
    // frames uploads once; a new generation uploads once more; after
    // `releaseCaches` it uploads again.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-residency", 64, 64);
    scope (success)
        rig.close();

    const h = rig.images.register(solidImage(4, 4, RgbColor(255, 0, 0)), Size(4, 4));
    const m = FrameMetrics(cellW: 10, cellH: 20);
    ubyte[] frame;
    void drawIt()
    {
        frame = rig.draw((ref Canvas c) { c.image(Rect(0, 0, 2, 1), h, ImageFit.fill, null,
            Visual.init); }, m, black);
    }
    foreach (_; 0 .. 3)
        drawIt();
    assert(rig.canvas.imageUploads == 1 && rig.canvas.cachedImages == 1);
    rig.images.replace(h, ImageData(rgba: solidImage(4, 4, RgbColor(0, 255, 0)), size: Size(4, 4)));
    drawIt();
    drawIt();
    assert(rig.canvas.imageUploads == 2);
    assert(pixel(frame, 64, 5, 5)[0 .. 3] == [0, 255, 0], "the new generation's pixels");
    rig.canvas.releaseCaches();
    assert(rig.canvas.cachedImages == 0);
    drawIt();
    assert(rig.canvas.imageUploads == 3 && rig.canvas.cachedImages == 1);
}

@("ui_vulkan.canvas.aRemovedImageLeavesTheDevice")
@system unittest
{
    // `UVK23`: an image its registry removed is evicted as the next frame
    // begins, so a stream of images (a terminal's kitty graphics) keeps a
    // bounded cache however long it runs.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-evict", 32, 32);
    scope (success)
        rig.close();

    const kept = rig.images.register(solidImage(2, 2, RgbColor(0, 0, 255)), Size(2, 2));
    foreach (i; 0 .. 200)
    {
        const shown = rig.images.register(solidImage(2, 2, RgbColor(cast(ubyte) i, 0, 0)),
            Size(2, 2));
        cast(void) rig.draw((ref Canvas c) {
            c.image(Rect(0, 0, 1, 1), kept, ImageFit.fill, null, Visual.init);
            c.image(Rect(1, 0, 1, 1), shown, ImageFit.fill, null, Visual.init);
        }, FrameMetrics(cellW: 10, cellH: 20), black);
        rig.images.remove(shown);
    }
    cast(void) rig.draw((ref Canvas c) {}, FrameMetrics(cellW: 10, cellH: 20), black);
    assert(rig.canvas.cachedImages == 1,
        format("only the image still registered stays: %s cached", rig.canvas.cachedImages));
    assert(rig.canvas.imageUploads == 201, "and the kept one was never uploaded again");
}

@("ui_vulkan.canvas.aReusedSlotDrawsItsNewImage")
@system unittest
{
    // `IMG3`: the registry reuses a removed image's slot under a new
    // generation. The canvas must draw the new image there, never the upload
    // it holds for the old one — even when the slot is reused mid-frame,
    // before the next frame's sweep could evict that upload.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-reused-slot", 32, 32);
    scope (success)
        rig.close();

    const red = rig.images.register(solidImage(2, 2, RgbColor(255, 0, 0)), Size(2, 2));
    ImageHandle green;
    const frame = rig.draw((ref Canvas c) {
        c.image(Rect(0, 0, 1, 1), red, ImageFit.fill, null, Visual.init);
        rig.images.remove(red);
        green = rig.images.register(solidImage(2, 2, RgbColor(0, 255, 0)), Size(2, 2));
        c.image(Rect(1, 0, 1, 1), green, ImageFit.fill, null, Visual.init);
        c.image(Rect(2, 0, 1, 1), red, ImageFit.fill, null, Visual.init); // stale
    }, FrameMetrics(cellW: 10, cellH: 20), black);
    assert(green.index == red.index && green != red, "the slot is reused under a new generation");
    assert(pixel(frame, 32, 5, 5)[0 .. 3] == [255, 0, 0], "drawn before the removal");
    assert(pixel(frame, 32, 15, 5)[0 .. 3] == [0, 255, 0], "the new image, not the old upload");
    assert(pixel(frame, 32, 25, 5)[0 .. 3] == [0, 0, 0], "the stale handle draws nothing");
}

@("ui_vulkan.canvas.registrySwitchKeepsDrawnImagesDistinct")
@system unittest
{
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-registries", 64, 64);
    scope (success)
        rig.close();

    ImageRegistry other;
    const red = rig.images.register(solidImage(4, 4, RgbColor(255, 0, 0)), Size(4, 4));
    const green = other.register(solidImage(4, 4, RgbColor(0, 255, 0)), Size(4, 4));
    assert(red == green, "handles are local to their registries");
    foreach (_; 0 .. 2)
    {
        const frame = rig.draw((ref Canvas c) {
            c.images(&rig.images);
            c.image(Rect(0, 0, 2, 1), red, ImageFit.fill, null, Visual.init);
            c.images(&other);
            c.image(Rect(2, 0, 2, 1), green, ImageFit.fill, null, Visual.init);
            c.images(&rig.images);
        }, FrameMetrics(cellW: 10, cellH: 20), black);
        assert(pixel(frame, 64, 5, 5)[0 .. 3] == [255, 0, 0]);
        assert(pixel(frame, 64, 25, 5)[0 .. 3] == [0, 255, 0]);
    }
    assert(rig.canvas.imageUploads == 2, "switching registries preserves residency");
}

@("ui_vulkan.canvas.imagesOverTheLimitsDegrade")
@system unittest
{
    // Canvas scenario 11 (`UVK25`, `UVK29`): an image over the largest extent
    // draws the placeholder and counts `imageTooLarge`; three images over the
    // upload budget upload across frames, each frame counting the rest as
    // `imageDeferred` and asking for another.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    CanvasConfig config;
    config.uploadBudget = 64 * 64 * 4;
    rig.open("ui-vulkan-limits", 160, 120, RigOptions(config: config));
    scope (success)
        rig.close();

    const m = FrameMetrics(cellW: 10, cellH: 20);
    const wide = rig.facts.maxImageExtent + 1;
    const huge = rig.images.register(solidImage(wide, 1, white), Size(wide, 1), "huge");
    FrameReport report;
    auto frame = rig.draw((ref Canvas c) {
        c.image(Rect(0, 0, 4, 2), huge, ImageFit.fill, null, Visual(bg: RgbColor(9, 9, 9),
            hasBg: true));
    }, m, black, report);
    assert(report[Degradation.imageTooLarge] == 1 && rig.canvas.imageUploads == 0);
    assert(pixel(frame, 160, 5, 5)[0 .. 3] == [9, 9, 9], "the placeholder's box");

    ImageHandle[3] three;
    foreach (i, ref h; three)
        h = rig.images.register(solidImage(64, 64, RgbColor(cast(ubyte)(50 * i), 0, 0)),
            Size(64, 64));
    foreach (deferred; [2, 1, 0])
    {
        rig.draw((ref Canvas c) {
            foreach (i, h; three)
                c.image(Rect(cast(int) i * 4, 2, 4, 2), h, ImageFit.fill, null, Visual.init);
        }, m, black, report);
        assert(report[Degradation.imageDeferred] == deferred);
        assert(report.anotherFrame == (deferred > 0));
    }
    assert(rig.canvas.imageUploads == 3);
}

@("ui_vulkan.canvas.imagesPlaceByFitRect")
@system unittest
{
    // Canvas scenario 12 (`UVK24`): each `ImageFit` lands where `fitRect`
    // puts it, `cover` clipped to its rect, and half the foreground alpha
    // halves the image's contribution.
    import sparkles.ui.image : fitRect;

    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-placement", 160, 120);
    scope (success)
        rig.close();

    const h = rig.images.register(solidImage(40, 20, white), Size(40, 20));
    const m = FrameMetrics(cellW: 10, cellH: 20, originX: 3, originY: 2);
    const cells = Rect(1, 1, 6, 3);
    const dest = pixelsOf(cells, m);
    foreach (fit; [ImageFit.fill, ImageFit.contain, ImageFit.cover])
    {
        const frame = rig.draw((ref Canvas c) { c.image(cells, h, fit, null, Visual.init); }, m,
            black);
        const placed = fitRect(dest, Size(40, 20), fit).intersection(dest);
        assertExactly(frame, 160, 120, [placed], format("%s", fit));
    }
    const half = rig.draw((ref Canvas c) { c.image(cells, h, ImageFit.fill, null,
        Visual(fgAlpha: 128)); }, m, black);
    assert(abs(pixel(half, 160, 30, 50)[0] - 128) <= 1);
}

@("ui_vulkan.canvas.degradesEffectsAndFacesVisibly")
@system unittest
{
    // Canvas scenario 14 (`UVK15`–`UVK17`): an effect bracket draws its fill
    // and counts `effect`; an interface run without a face counts
    // `missingFace`.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-degrade", 64, 64);
    scope (success)
        rig.close();

    import sparkles.ui.effect : EffectId;

    FrameReport report;
    const frame = rig.draw((ref Canvas c) {
        c.pushEffect(Rect(0, 0, 4, 2), EffectId.init);
        c.fillRect(Rect(0, 0, 1, 1), Visual(bg: white, hasBg: true));
        c.popEffect();
        c.textRunIn(Rect(0, 1, 4, 1), "Logs", Visual(fontRole: FontRole.ui));
    }, FrameMetrics(cellW: 10, cellH: 20), black, report);
    assertExactly(frame, 64, 64, [Rect(0, 0, 10, 20)], "the bracket's fill");
    assert(report[Degradation.effect] == 1 && report[Degradation.missingFace] == 1);
}

/// A frame with something of every kind the canvas draws in V2: fills,
/// translucency, a rounded box with a ring, a dashed border, a shadow, the
/// arrow, a rule, a wavy line, a clip and an image.
private void everything(ref Canvas c, ImageHandle image)
{
    c.fillRect(Rect(1, 1, 8, 3), Visual(bg: RgbColor(40, 90, 200), hasBg: true));
    c.fillRect(Rect(3, 2, 6, 3), Visual(bg: RgbColor(240, 200, 0), bgAlpha: 140, hasBg: true,
        borderRadius: 6, border: BoxBorder(width: Insets.all(1), style: BorderStyle.solid,
            color: white), shadow: Shadow(dx: 2, dy: 3, blur: 4, color: black, alpha: 90),
        arrow: true, arrowOffset: 2));
    c.fillRect(Rect(1, 5, 6, 2), Visual(border: BoxBorder(width: Insets.all(1),
        style: BorderStyle.dashed, color: RgbColor(255, 0, 255))));
    c.rule(Rect(0, 0, 14, 1), RuleEdge.bottom, Visual(fg: RgbColor(0, 255, 0)));
    c.line(Point(8, 5), Point(13, 5), Visual(fg: RgbColor(255, 0, 0)), LineStyle.wavy);
    c.pushClip(Rect(9, 1, 3, 2));
    c.image(Rect(8, 0, 6, 4), image, ImageFit.cover, null, Visual(fgAlpha: 220));
    c.popClip();
}

/// A 16×8 image of two colours, so a misplaced sample shows.
private ubyte[] twoColourImage()
{
    auto rgba = solidImage(16, 8, RgbColor(255, 128, 0));
    foreach (y; 0 .. 8)
        foreach (x; 8 .. 16)
            rgba[(y * 16 + x) * 4 .. (y * 16 + x) * 4 + 4] = [0, 128, 255, 200];
    return rgba;
}

@("ui_vulkan.canvas.framesRecordInTheOrderTheSpecificationGives")
@system unittest
{
    // Canvas scenario 9 (`UVK2`–`UVK4`, `UVK30`): uploads and their barriers,
    // then the target's transition from the colour-attachment output stage,
    // one pass, the final transition — on both the dynamic-rendering and the
    // render-pass path.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    foreach (dynamic; [true, false])
    {
        auto rig = new Rig;
        rig.open("ui-vulkan-recording", 160, 120, RigOptions(spy: true,
            adjust: (ref DeviceFacts f) { f.dynamicRendering &= dynamic; }));
        const image = rig.images.register(twoColourImage, Size(16, 8));
        rig.draw((ref Canvas c) { everything(c, image); }, FrameMetrics(cellW: 10, cellH: 20));

        const log = &spyLog;
        const begin = log.find(dynamic ? "beginRendering" : "beginRenderPass");
        const end = log.find(dynamic ? "endRendering" : "endRenderPass");
        assert(begin > 0 && end > begin, "one pass");
        assert(log.find(dynamic ? "beginRendering" : "beginRenderPass", begin + 1) < 0,
            "and only one");
        // Two uploads — the placeholder and the image — each its barrier,
        // its copy and its barrier to the fragment shader, before the pass.
        size_t copies;
        foreach (i; 0 .. begin)
            copies += log.calls[i] == "copy";
        assert(copies == 2);
        const draws = log.find("draw");
        assert(draws > begin && draws < end && log.find("copy", begin) < 0,
            "every draw inside the pass, and no upload after it starts");

        // Of the barriers: the uploads' come first, then the target's into
        // the attachment layout, waiting on the colour-attachment output
        // stage, then the final one, after the pass.
        const n = log.barrierCount;
        assert(n == 6);
        foreach (b; log.barriers[0 .. 4])
            assert(b.to == VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
                || b.to == VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        const into = log.barriers[4], out_ = log.barriers[5];
        assert(into.to == VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            && into.src == VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);
        assert(out_.from == VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            && out_.to == VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
        ptrdiff_t lastBarrierBefore = -1, firstBarrierAfter = -1;
        foreach (i; 0 .. log.count)
            if (log.calls[i] == "barrier")
            {
                if (i < begin)
                    lastBarrierBefore = i;
                else if (firstBarrierAfter < 0)
                    firstBarrierAfter = i;
            }
        assert(lastBarrierBefore < begin && firstBarrierAfter > end);
        rig.close();
    }
}

@("ui_vulkan.canvas.aReleasedImageOutlivesTheFramesThatReadIt")
@system unittest
{
    // Canvas scenario 13 (`UVK31`): an image released while the previous
    // slot's frame may still sample it is destroyed only once that slot is
    // begun again — which a host does only after its fence has signalled.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-deferred", 64, 64, RigOptions(spy: true));
    scope (success)
        rig.close();

    const h = rig.images.register(solidImage(4, 4, white), Size(4, 4));
    const m = FrameMetrics(cellW: 10, cellH: 20);
    rig.draw((ref Canvas c) { c.image(Rect(0, 0, 2, 1), h, ImageFit.fill, null, Visual.init); },
        m); // slot 0
    rig.canvas.releaseCaches();
    const before = spyLog.imagesDestroyed;
    rig.draw((ref Canvas c) {}, m); // slot 1: slot 0 is still in flight to the canvas
    assert(spyLog.imagesDestroyed == before, "destroyed under a frame that may read it");
    rig.draw((ref Canvas c) {}, m); // slot 0 again: its frame has completed
    assert(spyLog.imagesDestroyed == before + 1);
}

@("ui_vulkan.canvas.aNewTargetRebuildsOnlyWhatIsTheTargets")
@system unittest
{
    // Canvas scenario 15 (`UVK26`): drawing, dropping the target, and drawing
    // on a new target of another extent makes no pipeline and uploads no
    // image again; on the render-pass path only a framebuffer is new.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    foreach (dynamic; [true, false])
    {
        auto rig = new Rig;
        rig.open("ui-vulkan-surface-loss", 160, 120, RigOptions(spy: true,
            adjust: (ref DeviceFacts f) { f.dynamicRendering &= dynamic; }));
        const image = rig.images.register(twoColourImage, Size(16, 8));
        const m = FrameMetrics(cellW: 10, cellH: 20);
        rig.draw((ref Canvas c) { everything(c, image); }, m);
        const pipelines = spyLog.pipelines, images = spyLog.images;
        const framebuffers = spyLog.framebuffers, uploads = rig.canvas.imageUploads;

        rig.resize(200, 90);
        rig.draw((ref Canvas c) { everything(c, image); }, m);
        assert(spyLog.pipelines == pipelines && rig.canvas.pipelineCount == 1);
        assert(spyLog.images == images && rig.canvas.imageUploads == uploads);
        assert(spyLog.framebuffers == framebuffers + (dynamic ? 0 : 1));
        rig.close();
    }
}

@("ui_vulkan.canvas.aRebuiltDeviceDrawsTheSameFrame")
@system unittest
{
    // Canvas scenario 16 (`UVK33`): a frame drawn, the device destroyed and
    // rebuilt, the same frame drawn again: byte-identical targets.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    ubyte[][2] frames;
    foreach (ref frame; frames)
    {
        auto rig = new Rig;
        rig.open("ui-vulkan-rebuild", 160, 120);
        const image = rig.images.register(twoColourImage, Size(16, 8));
        frame = rig.draw((ref Canvas c) { everything(c, image); }, FrameMetrics(cellW: 10,
            cellH: 20), ground);
        rig.close();
    }
    assert(frames[0] == frames[1]);
}

@("ui_vulkan.canvas.exhaustedMemoryAbandonsTheFrame")
@system unittest
{
    // Canvas scenario 17 (`UVK34`): with the allocator failing mid-frame,
    // `endFrame` reports `outOfDeviceMemory` and releases the caches, and the
    // next frame draws.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-exhaustion", 64, 64, RigOptions(spy: true));
    scope (success)
        rig.close();

    const small = rig.images.register(solidImage(4, 4, white), Size(4, 4));
    // 64 MiB: larger than a whole block of the allocator's, so it needs an
    // allocation of its own, which fails.
    const large = rig.images.register(solidImage(4096, 4096, white), Size(4096, 4096));
    const m = FrameMetrics(cellW: 10, cellH: 20);
    rig.draw((ref Canvas c) { c.image(Rect(0, 0, 2, 1), small, ImageFit.fill, null,
        Visual.init); }, m);
    assert(rig.canvas.cachedImages == 1);

    spyLog.failAllocations = true;
    FrameReport report;
    VkResult failure;
    const abandoned = rig.draw((ref Canvas c) {
        c.image(Rect(0, 0, 2, 1), small, ImageFit.fill, null, Visual.init);
        c.image(Rect(2, 0, 2, 1), large, ImageFit.fill, null, Visual.init);
    }, m, black, report, failure);
    assert(abandoned is null && failure == VkResult.VK_ERROR_OUT_OF_DEVICE_MEMORY,
        format("abandoned %s, failure %s, cached %s, uploads %s", abandoned is null, failure,
            rig.canvas.cachedImages, rig.canvas.imageUploads));
    assert(rig.canvas.cachedImages == 0, "the caches were released");

    // The next frame starts from the released state: the small image
    // uploads again, and the large one, over the budget beside it, waits a
    // frame more.
    spyLog.failAllocations = false;
    void both(ref Canvas c)
    {
        c.image(Rect(0, 0, 2, 1), small, ImageFit.fill, null, Visual.init);
        c.image(Rect(2, 0, 2, 1), large, ImageFit.fill, null, Visual.init);
    }
    auto frame = rig.draw(&both, m, black, report);
    assert(pixel(frame, 64, 5, 5)[0 .. 3] == [255, 255, 255]);
    assert(report[Degradation.imageDeferred] == 1);
    frame = rig.draw(&both, m, black, report);
    assert(pixel(frame, 64, 5, 5)[0 .. 3] == [255, 255, 255]
        && pixel(frame, 64, 25, 5)[0 .. 3] == [255, 255, 255]);
    assert(report.empty);
}

@("ui_vulkan.canvas.onlyTheGammaBlendSpaceIsImplemented")
@system unittest
{
    // Canvas scenario 19 (`UVK6`): creating a canvas in the `gamma` space
    // succeeds; any other space fails with `unsupported`.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto session = new HeadlessSession;
    session.open("ui-vulkan-blend-space");
    scope (success)
        session.close();
    auto memory = DeviceMemory!DeviceMemoryBackend(DeviceMemoryBackend(session.device.instance,
        session.device.physicalDevice, session.device.device));
    scope (exit)
        memory.destroy();
    foreach (space; [BlendSpace.gamma, BlendSpace.linear])
    {
        auto canvas = new Canvas;
        CanvasConfig config;
        config.blendSpace = space;
        const made = Canvas.create(*canvas, session.device.device, memory,
            DeviceFacts.of(session.device), config);
        assert(made.hasError == (space != BlendSpace.gamma));
        if (made.hasError)
            assert(made.error == VkResult.VK_ERROR_FEATURE_NOT_PRESENT);
        canvas.destroy();
    }
}

@("ui_vulkan.canvas.everyRenderingPathDrawsTheSameFrame")
@system unittest
{
    // Canvas scenario 20 (`UVK2`): Vulkan 1.3 renders with dynamic rendering;
    // a 1.1 device with `VK_KHR_dynamic_rendering` does too, through the
    // extension, on the 1.1 shader profile; a device without it renders
    // through the canvas's render pass, with imageless framebuffers where
    // offered and one per view otherwise. Every path draws the same pixels.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    static struct Path
    {
        string name;
        uint apiVersion;
        bool dynamic, imageless;
        string begins;
    }
    static immutable Path[4] paths = [
        Path("1.3 core", apiVersion13, true, true, "beginRendering"),
        Path("1.1 extension", apiVersion11, true, true, "beginRenderingKHR"),
        Path("imageless render pass", apiVersion13, false, true, "beginRenderPass"),
        Path("per-view render pass", apiVersion13, false, false, "beginRenderPass"),
    ];
    const(ubyte)[] reference;
    foreach (path; paths)
    {
        auto rig = new Rig;
        rig.open("ui-vulkan-paths", 160, 120, RigOptions(apiVersion: path.apiVersion, spy: true,
            adjust: (ref DeviceFacts f) {
                f.dynamicRendering &= path.dynamic;
                f.imagelessFramebuffer &= path.imageless;
            }));
        assert(rig.facts.dynamicRendering == path.dynamic, path.name);
        assert(rig.facts.imagelessFramebuffer == path.imageless,
            path.name ~ ": lavapipe offers imageless framebuffers");
        assert(rig.facts.spirv16 == (path.apiVersion == apiVersion13), path.name);
        const image = rig.images.register(twoColourImage, Size(16, 8));
        const frame = rig.draw((ref Canvas c) { everything(c, image); },
            FrameMetrics(cellW: 10, cellH: 20), ground);
        assert(spyLog.find(path.begins) >= 0, path.name);
        if (!path.dynamic)
            assert(spyLog.imagelessFramebuffers == (path.imageless ? 1 : 0)
                && spyLog.framebuffers == 1, path.name);
        if (reference is null)
            reference = frame;
        else
            assert(frame == reference, path.name ~ " drew different pixels");
        rig.close();
    }
}

@("ui_vulkan.canvas.aGlyphReadsBackAsTheFontRasterizesIt")
@system unittest
{
    // Canvas scenario 21 (`UVK18`, `UVK21`): a glyph drawn at a whole-pixel
    // position through the atlas reads back exactly as `sparkles:font`
    // rasterizes it — the oracle is the library's own `rasterizeGlyph`, called
    // here, not the atlas — placed by its bearings from the cell's baseline.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.font : charMap, instance, InstanceSize, openFace, Ppem, RasterRegion,
        RasterWorkspace, rasterizeGlyph, rasterMeasure;
    import sparkles.font : OutlinePoint, OutlineSegment;
    import sparkles.ui_vulkan.painter : TextMetrics;

    const dir = environment.get("SPARKLES_FONTS_PATH");
    assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
    const bytes = cast(const(ubyte)[]) read(dir.buildPath("DejaVuSansMono.ttf"));

    enum ppem = 24, ascent = 22;
    auto rig = new Rig;
    rig.open("ui-vulkan-glyph", 80, 60);
    scope (success)
        rig.close();
    assert(rig.canvas.cellFont(bytes, ppem, TextMetrics(ascent: ascent, underlineY: 24,
        underlineHeight: 1, strikeY: 14)));

    // The oracle: glyph 'A' at 24 ppem, from the library.
    auto face = openFace(bytes).value;
    const size = Ppem.fromInteger(ppem).value;
    auto inst = instance(face, InstanceSize.pixels(size), null).value;
    const gid = charMap(face).value.glyph('A');
    auto segments = new OutlineSegment[4096];
    auto points = new OutlinePoint[4096];
    auto onCurve = new bool[4096];
    auto ends = new ushort[1024];
    auto ws = RasterWorkspace(segments, points, onCurve, ends, new float[1 << 16],
        new ubyte[1 << 16]);
    // Light-hinted, as the canvas draws by default.
    import sparkles.font : FlattenPolicy, lightHints, OutlineWorkspace, OverlapMode;

    const hints = lightHints(inst, charMap(face).value, size, new OutlineSegment[4096],
        OutlineWorkspace(new OutlinePoint[4096], new bool[4096], new ushort[1024], new uint[4096],
            new int[4096], new int[4096], new int[2][4096]));
    const m = rasterMeasure(inst, gid, size, ws, OverlapMode.perGlyphFlag, &hints).value;
    auto coverage = new ubyte[m.width * m.height];
    cast(void) rasterizeGlyph(inst, gid, size, RasterRegion(coverage, m.width, m.width, m.height), ws,
        FlattenPolicy.standard, OverlapMode.perGlyphFlag, &hints);

    const metrics = FrameMetrics(cellW: 14, cellH: 28);
    const frame = rig.draw((ref Canvas c) {
        c.glyph(Point(1, 1), 'A', Visual(fg: white, fgAlpha: 255));
    }, metrics, black);
    // Pen at cell (1, 1)'s left edge; the box's top at the baseline less the bearing.
    const left = metrics.cellW + m.bearingX, top = metrics.cellH + ascent - m.bearingY;
    foreach (y; 0 .. 60)
        foreach (x; 0 .. 80)
        {
            const inBox = x >= left && x < left + m.width && y >= top && y < top + m.height;
            const want = inBox ? coverage[(y - top) * m.width + (x - left)] : 0;
            const got = pixel(frame, 80, x, y)[0];
            assert(got == want, format("(%s, %s): %s, the rasterizer has %s", x, y, got, want));
        }
}

@("ui_vulkan.canvas.textOnAKnownBackgroundBlendsAsItsCompositingSays")
@system unittest
{
    // `UVK36` through the device: a glyph over a background it paints is
    // composited by its mode — the default, `linearCorrected`, and `gamma`
    // — and reads back as the host's evaluation of the same `glyphColour`
    // over that background, at the coverage `sparkles:font` rasterizes.
    // The colours differ in luminance, so the modes disagree: each frame
    // also fails the other mode's oracle.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.font : charMap, FlattenPolicy, instance, InstanceSize, lightHints, openFace,
        OutlinePoint, OutlineSegment, OutlineWorkspace, OverlapMode, Ppem, RasterRegion,
        RasterWorkspace, rasterizeGlyph, rasterMeasure;
    import sparkles.ui_vulkan.painter : rgba, TextMetrics;
    import sparkles.shaders : vec4;
    import sparkles.ui_vulkan.shading : glyphColour;
    import sparkles.ui_vulkan.text_rendering : Compositing, TextRendering;

    const dir = environment.get("SPARKLES_FONTS_PATH");
    assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
    const bytes = cast(const(ubyte)[]) read(dir.buildPath("DejaVuSansMono.ttf"));

    enum ppem = 24, ascent = 22;
    auto rig = new Rig;
    rig.open("ui-vulkan-composited-glyph", 80, 60);
    scope (success)
        rig.close();
    assert(rig.canvas.cellFont(bytes, ppem, TextMetrics(ascent: ascent, underlineY: 24,
        underlineHeight: 1, strikeY: 14)));

    auto face = openFace(bytes).value;
    const size = Ppem.fromInteger(ppem).value;
    auto inst = instance(face, InstanceSize.pixels(size), null).value;
    const gid = charMap(face).value.glyph('A');
    auto ws = RasterWorkspace(new OutlineSegment[4096], new OutlinePoint[4096], new bool[4096],
        new ushort[1024], new float[1 << 16], new ubyte[1 << 16]);
    const hints = lightHints(inst, charMap(face).value, size, new OutlineSegment[4096],
        OutlineWorkspace(new OutlinePoint[4096], new bool[4096], new ushort[1024], new uint[4096],
            new int[4096], new int[4096], new int[2][4096]));
    const m = rasterMeasure(inst, gid, size, ws, OverlapMode.perGlyphFlag, &hints).value;
    auto coverage = new ubyte[m.width * m.height];
    cast(void) rasterizeGlyph(inst, gid, size, RasterRegion(coverage, m.width, m.width, m.height), ws,
        FlattenPolicy.standard, OverlapMode.perGlyphFlag, &hints);

    const ink = RgbColor(235, 220, 190), paper = RgbColor(30, 50, 90);
    const fill = rgba(ink, 255), under = rgba(paper, 255);
    const metrics = FrameMetrics(cellW: 14, cellH: 28);
    const left = metrics.cellW + m.bearingX, top = metrics.cellH + ascent - m.bearingY;
    TextRendering settings;
    assert(settings.compositing == Compositing.linearCorrected, "the default is the one tested first");

    // What `mode` leaves at coverage `c`, as 8-bit channels.
    static int[3] oracle(vec4 fill, vec4 under, ubyte c, float mode, float contrast)
    {
        const g = glyphColour(fill, under, c / 255.0f, mode, contrast, 0);
        const keep = 1 - g.w;
        return [cast(int) lround((g.x + under.x * keep) * 255),
            cast(int) lround((g.y + under.y * keep) * 255),
            cast(int) lround((g.z + under.z * keep) * 255)];
    }

    foreach (mode; [Compositing.linearCorrected, Compositing.gamma])
    {
        settings.compositing = mode;
        rig.canvas.textRendering(settings);
        const frame = rig.draw((ref Canvas c) {
            c.glyph(Point(1, 1), 'A', Visual(fg: ink, fgAlpha: 255, bg: paper, hasBg: true));
        }, metrics, paper);
        const other = mode == Compositing.gamma ? Compositing.linearCorrected : Compositing.gamma;
        size_t apart;
        foreach (y; top .. top + m.height)
            foreach (x; left .. left + m.width)
            {
                const c = coverage[(y - top) * m.width + (x - left)];
                const want = oracle(fill, under, c, mode, settings.contrast);
                const notWant = oracle(fill, under, c, other, settings.contrast);
                const got = pixel(frame, 80, x, y);
                foreach (k; 0 .. 3)
                    assert(abs(got[k] - want[k]) <= 1, format("%s at (%s, %s) channel %s: %s, the host has %s",
                        mode, x, y, k, got[k], want[k]));
                if (abs(got[0] - notWant[0]) > 4)
                    ++apart;
            }
        assert(apart > m.width * m.height / 10, format("%s: only %s pixels tell it from %s", mode,
            apart, other));
    }
}

@("ui_vulkan.canvas.anEmojiReadsBackInItsOwnColours")
@system unittest
{
    // A colour glyph from a fallback face (`UVX12`): an emoji the cell font
    // lacks draws from the colour emoji face, through the colour sheet, as
    // `sparkles:font` draws its colour form — the oracle is the library's own
    // `rasterizeColourGlyph` — composited over black, whatever the text colour.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    import std.file : read;
    import std.math : abs;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.font : charMap, Colour, ColourRegion, ColourWorkspace, colourMeasure, instance,
        InstanceSize, openFace, OutlinePoint, OutlineSegment, Ppem, RasterWorkspace, rasterizeColourGlyph;
    import sparkles.ui_vulkan.canvas : FallbackFace;
    import sparkles.ui_vulkan.painter : Degradation, TextMetrics;

    const dir = environment.get("SPARKLES_FONTS_PATH");
    assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
    const mono = cast(const(ubyte)[]) read(dir.buildPath("DejaVuSansMono.ttf"));
    const emoji = cast(const(ubyte)[]) read(dir.buildPath("NotoColorEmoji.ttf"));

    enum ascent = 22;
    const size = Ppem.fromInteger(20).value; // about 25 × 24: within two 16 × 28 cells
    auto rig = new Rig;
    rig.open("ui-vulkan-emoji", 80, 60);
    scope (success)
        rig.close();
    const(ubyte)[][4] faces;
    faces[0] = mono;
    assert(rig.canvas.cellFont(faces, size, TextMetrics(ascent: ascent, underlineY: 24,
        underlineHeight: 1, strikeY: 14), [FallbackFace(emoji, size)]));

    // The oracle: U+1F600 at 20 ppem, from the library.
    auto face = openFace(emoji).value;
    auto inst = instance(face, InstanceSize.pixels(size), null).value;
    const gid = charMap(face).value.glyph('\U0001F600');
    auto ws = ColourWorkspace(RasterWorkspace(new OutlineSegment[4096], new OutlinePoint[4096],
        new bool[4096], new ushort[1024], new float[1 << 16], new ubyte[1 << 16]), new ubyte[1 << 16],
        new ubyte[1 << 22], new ubyte[1 << 22], new ubyte[1 << 16]);
    const m = colourMeasure(inst, gid, size, ws).value;
    auto rgba = new ubyte[4 * m.width * m.height];
    assert(rasterizeColourGlyph(inst, gid, size, 0, Colour(255, 255, 255, 255),
        ColourRegion(rgba, 4 * m.width, m.width, m.height), ws).hasValue);

    const metrics = FrameMetrics(cellW: 16, cellH: 28);
    FrameReport report;
    const frame = rig.draw((ref Canvas c) {
        c.glyph(Point(1, 1), '\U0001F600', Visual(fg: RgbColor(0, 200, 0), fgAlpha: 255));
    }, metrics, black, report);
    assert(report[Degradation.noGlyph] == 0);
    assert(rig.canvas.atlasPages(true) == 1, "one colour page on the device");
    // It fits its two cells, so it draws at its size, centred in the cell's height.
    assert(m.bearingX + m.width <= 2 * metrics.cellW && m.height <= metrics.cellH,
        format("bearing %s, box %s × %s", m.bearingX, m.width, m.height));
    const left = metrics.cellW + m.bearingX, top = metrics.cellH + (metrics.cellH - m.height) / 2;
    foreach (y; 0 .. 60)
        foreach (x; 0 .. 80)
        {
            const inBox = x >= left && x < left + m.width && y >= top && y < top + m.height;
            foreach (ch; 0 .. 3)
            {
                const want = inBox ? rgba[4 * ((y - top) * m.width + (x - left)) + ch] : 0;
                const got = pixel(frame, 80, x, y)[ch];
                assert(abs(int(got) - want) <= 1,
                    format("(%s, %s) channel %s: %s, the rasterizer has %s", x, y, ch, got, want));
            }
        }
}

@("ui_vulkan.canvas.textCountsWhatItCannotDraw")
@system unittest
{
    // A codepoint no face has is `noGlyph`. A cluster of several codepoints
    // is shaped by HarfBuzz — `e` and a combining acute become the base and a
    // positioned mark, two glyphs — and with shaping off draws its first and
    // counts `unshapedCluster` (`UVK19`, T3).
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.ui_vulkan.painter : Degradation, TextMetrics;

    const bytes = cast(const(ubyte)[]) read(
        environment.get("SPARKLES_FONTS_PATH").buildPath("DejaVuSansMono.ttf"));
    auto rig = new Rig;
    rig.open("ui-vulkan-text-counts", 64, 32);
    scope (success)
        rig.close();
    assert(rig.canvas.cellFont(bytes, 18, TextMetrics(ascent: 14, underlineY: 16,
        underlineHeight: 1, strikeY: 10)));
    import sparkles.ui_vulkan.text_rendering : TextRendering;

    // The ink in the `e` cell's top rows, which the accent adds to.
    static size_t accentInk(in ubyte[] frame)
    {
        size_t ink;
        foreach (y; 0 .. 8)
            foreach (x; 30 .. 40)
                ink += pixel(frame, 64, x, y)[0];
        return ink;
    }

    FrameReport report;
    const shaped = rig.draw((ref Canvas c) {
        c.textRun(Point(0, 0), "a一é", Visual(fg: white, fgAlpha: 255));
    }, FrameMetrics(cellW: 10, cellH: 20), black, report);
    assert(report[Degradation.noGlyph] == 1, "DejaVu has no CJK");
    assert(report[Degradation.unshapedCluster] == 0, "e + combining acute, shaped");
    assert(report[Degradation.glyphMiss] == 0);

    TextRendering unshapedText;
    unshapedText.shaping = false;
    rig.canvas.textRendering(unshapedText);
    const unshaped = rig.draw((ref Canvas c) {
        c.textRun(Point(0, 0), "a一é", Visual(fg: white, fgAlpha: 255));
    }, FrameMetrics(cellW: 10, cellH: 20), black, report);
    assert(report[Degradation.unshapedCluster] == 1, "e + combining acute, unshaped");
    assert(accentInk(shaped) > accentInk(unshaped) + 255 * 3, format("the accent adds ink only shaped: %s unshaped, %s shaped", accentInk(unshaped), accentInk(shaped)));
}

@("ui_vulkan.canvas.aHintingChangeMidFrameKeepsWhatItDrew")
@system unittest
{
    // Text drawn before a hinting change in the same frame keeps its glyphs:
    // the atlas starts over at the next frame, not under quads already
    // recorded (which once scrambled the text lab's header).
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.ui_vulkan.painter : TextMetrics;
    import sparkles.ui_vulkan.text_rendering : Hinting, TextRendering;

    const bytes = cast(const(ubyte)[]) read(
        environment.get("SPARKLES_FONTS_PATH").buildPath("DejaVuSansMono.ttf"));
    auto rig = new Rig;
    rig.open("ui-vulkan-hinting-mid-frame", 80, 40);
    scope (success)
        rig.close();
    assert(rig.canvas.cellFont(bytes, 13, TextMetrics(ascent: 12, underlineY: 14,
        underlineHeight: 1, strikeY: 8)));
    const metrics = FrameMetrics(cellW: 8, cellH: 20);
    TextRendering light, none;
    light.hinting = Hinting.light;
    none.hinting = Hinting.none;
    const ink = Visual(fg: white, fgAlpha: 255);

    rig.canvas.textRendering(light);
    const hinted = rig.draw((ref Canvas c) { c.textRun(Point(0, 0), "zHTEaxe", ink); }, metrics, black);
    rig.canvas.textRendering(none);
    const unhinted = rig.draw((ref Canvas c) {
        c.textRun(Point(0, 0), "zHTEaxe", ink);
        c.textRun(Point(0, 1), "zHTEaxe", ink);
    }, metrics, black);
    rig.canvas.textRendering(light);
    const mixed = rig.draw((ref Canvas c) {
        c.textRun(Point(0, 0), "zHTEaxe", ink);
        c.textRendering(none);
        c.textRun(Point(0, 1), "zHTEaxe", ink);
    }, metrics, black);
    enum row = 80 * 20 * 4;
    assert(hinted[0 .. row] != unhinted[0 .. row], "hinting changes these glyphs at 13 px");
    assert(mixed[0 .. row] == hinted[0 .. row], "the row drawn before the change");
    assert(mixed[row .. $] == unhinted[row .. $], "the row drawn after it");
}

@("ui_vulkan.canvas.aLoupeRedrawsItsSourceAsBlocks")
@system unittest
{
    // `UVK38`: a loupe redraws a region of the frame `scale` times larger,
    // after everything else, each pixel a block of its exact colour; its
    // source is left as drawn.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    import sparkles.ui_vulkan.text_rendering : Loupe;

    auto rig = new Rig;
    rig.open("ui-vulkan-loupe", 48, 48);
    scope (success)
        rig.close();
    rig.canvas.loupe(Loupe(shown: true, sourceX: 4, sourceY: 4, sourceWidth: 4, sourceHeight: 4,
        x: 20, y: 20, scale: 3));
    const frame = rig.draw((ref Canvas c) {
        c.fillRect(Rect(1, 1, 1, 1), filled(RgbColor(255, 0, 0)));
    }, FrameMetrics(cellW: 4, cellH: 4), black);
    foreach (y; 0 .. 48)
        foreach (x; 0 .. 48)
        {
            const inCell = x >= 4 && x < 8 && y >= 4 && y < 8;
            const inLoupe = x >= 20 && x < 32 && y >= 20 && y < 32;
            const want = inCell || inLoupe ? 255 : 0;
            assert(pixel(frame, 48, x, y)[0] == want, format("(%s, %s) is %s, wanted %s", x, y,
                pixel(frame, 48, x, y)[0], want));
        }
}
