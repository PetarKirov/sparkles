/**
The effect chain on a real driver (`UVK15`): brackets at a frame's root run
through their records' SPIR-V passes on lavapipe, with the validation layer
listening, and the targets read back. Opt-in, as every readback is
(`SPARKLES_VULKAN_READBACK=1`).
*/
module sparkles.ui_vulkan.effect_chain_test;

version (unittest):

import std.math : abs;

import sparkles.base.term_color : RgbColor;
import sparkles.test_runner.skip : skipTest;
import sparkles.ui.crt : CrtEffect;
import sparkles.ui.effect : Builtin, dimTier0, EffectRegistry, Tier0Input;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.style : Visual;
import sparkles.ui_vulkan.canvas_test : pixel;
import sparkles.ui_vulkan.painter : Degradation, FrameMetrics, FrameReport;
import sparkles.ui_vulkan.testing;

private bool near(in ubyte[4] got, RgbColor want, int tolerance = 2) @safe pure nothrow @nogc
    => abs(got[0] - want.r) <= tolerance && abs(got[1] - want.g) <= tolerance
        && abs(got[2] - want.b) <= tolerance && got[3] == 255;

@("ui_vulkan.effect_chain.runsAOnePassEffectUpright")
@system unittest
{
    // `dim`, a tier-0 effect, run as its SPIR-V pass: every pixel of the
    // bracket is what the CPU transform makes of it, and the top half is
    // still the top — the chain keeps its images in OpenGL's orientation and
    // turns the picture back on the last pass.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-effect-dim", 40, 40);
    scope (success)
        rig.close();
    EffectRegistry reg;
    rig.canvas.effects(&reg);

    const red = RgbColor(220, 40, 30), blue = RgbColor(20, 60, 230);
    FrameReport report;
    const frame = rig.draw((ref Canvas c) {
        c.pushEffect(Rect(0, 0, 4, 4), Builtin.dim);
        c.fillRect(Rect(0, 0, 4, 2), Visual(bg: red, hasBg: true));
        c.fillRect(Rect(0, 2, 4, 2), Visual(bg: blue, hasBg: true));
        c.popEffect();
    }, FrameMetrics(cellW: 10, cellH: 10), RgbColor(0, 0, 0), report);
    assert(report[Degradation.effect] == 0, "the bracket ran");
    const dimRed = dimTier0(Tier0Input(Point(0, 0), Size(4, 4), red));
    const dimBlue = dimTier0(Tier0Input(Point(0, 0), Size(4, 4), blue));
    assert(dimRed != red, "the effect changes what it brackets");
    foreach (y; [1, 10, 18])
        assert(near(pixel(frame, 40, 20, y), dimRed), "the top half, dimmed");
    foreach (y; [21, 30, 38])
        assert(near(pixel(frame, 40, 20, y), dimBlue), "the bottom half, dimmed");
    assert(rig.canvas.effectPrograms == 1);
}

@("ui_vulkan.effect_chain.runsTheCrtsFourPasses")
@system unittest
{
    // The CRT (`EFX21`): bloom's three passes at half size, then the tube
    // onto the target — the bracket at the root of the frame, as hue
    // brackets it. A bright band along the top shows on top, the bent
    // glass's corners are dark, and the middle is the content's colour
    // through the tube's grading.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    enum w = 160, h = 120;
    auto rig = new Rig;
    rig.open("ui-vulkan-effect-crt", w, h);
    scope (success)
        rig.close();
    EffectRegistry reg;
    const id = reg.register(CrtEffect.effectRecord());
    CrtEffect crt;
    crt.enabled = true;
    crt.systemPointer = true; // no software cursor in the picture
    crt.writeParams(reg, id, w, h, w / 2, h / 2);
    rig.canvas.effects(&reg);
    rig.canvas.effectClock(1.0f);

    const grey = RgbColor(90, 90, 90), white = RgbColor(255, 255, 255);
    FrameReport report;
    const frame = rig.draw((ref Canvas c) {
        c.pushEffect(Rect(0, 0, 16, 12), id);
        c.fillRect(Rect(0, 0, 16, 12), Visual(bg: grey, hasBg: true));
        c.fillRect(Rect(0, 1, 16, 2), Visual(bg: white, hasBg: true));
        c.popEffect();
    }, FrameMetrics(cellW: 10, cellH: 10), RgbColor(0, 0, 0), report);
    assert(report[Degradation.effect] == 0, "the bracket ran");
    assert(rig.canvas.effectPrograms == 4, "three bloom passes and the tube");

    int luma(int x, int y)
    {
        const p = pixel(frame, w, x, y);
        return (p[0] + p[1] + p[2]) / 3;
    }
    // The band is near the top; the same height near the bottom is grey.
    assert(luma(w / 2, 20) > luma(w / 2, h - 20) + 60, "the band is on top");
    // The middle is the grey, graded by the tube, not black or white.
    assert(luma(w / 2, h / 2) > 40 && luma(w / 2, h / 2) < 160);
    // Outside the curved glass, at the very corners, nothing is lit.
    assert(luma(0, 0) < 20 && luma(w - 1, h - 1) < 20);
}

@("ui_vulkan.effect_chain.withoutARegistryABracketDegrades")
@system unittest
{
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = new Rig;
    rig.open("ui-vulkan-effect-none", 20, 20);
    scope (success)
        rig.close();
    const red = RgbColor(220, 40, 30);
    FrameReport report;
    const frame = rig.draw((ref Canvas c) {
        c.pushEffect(Rect(0, 0, 2, 2), Builtin.dim);
        c.fillRect(Rect(0, 0, 2, 2), Visual(bg: red, hasBg: true));
        c.popEffect();
    }, FrameMetrics(cellW: 10, cellH: 10), RgbColor(0, 0, 0), report);
    assert(report[Degradation.effect] == 1, "counted");
    assert(near(pixel(frame, 20, 10, 10), red, 0), "drawn unaffected");
}
