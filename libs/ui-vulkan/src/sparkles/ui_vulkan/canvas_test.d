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
    assert(red.value == green.value, "handles are local to their registries");
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
