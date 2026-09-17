/**
One place the CRT's configuration reaches the effect (`CFG3`).

Three sites used to set it: two blocks of twenty verbatim-identical lines (the
startup path and the settings pane's live re-apply), plus a third partial that
set three of the twenty-one fields, one-way, after the first had already set
them all — dead in effect, and the site a maintainer grepping for `crt.enabled`
found first.

Twenty-one fields set from two places is a twenty-second knob waiting to be
added to one of them and not the other, with nothing to catch it. So: one
function, and `applyCrtConfig` is where a new knob goes.

Templated on the effect rather than naming `CrtEffect`, for two reasons: it
keeps this module out of the raylib closure, so hue's `unittest` configuration
— which excludes the GUI — compiles and therefore $(B tests) it; and the stub
that makes that test possible is the same shape the real effect is.
*/
module crt_config;

import gui_state : GuiCapture;
import settings : CrtConfig, PointerConfig, PointerMode;

/++
Applies the resolved configuration, with the capture hooks' overrides on top.

The hooks are deliberately one-way for the three booleans: `HUE_GUI_CRT` forces
the effect $(B on) for a golden capture and never off, so a capture cannot
silently disable what the config asked for. `HUE_GUI_POINTER_MODE` is the
exception and replaces the setting outright, because there is no "on" to force
— the two modes are peers.
+/
void applyCrtConfig(Effect)(ref Effect crt, in CrtConfig c, in PointerConfig p,
    in GuiCapture capture)
{
    crt.enabled = c.enabled || capture.crt;
    crt.tilt = c.tilt || capture.crtTilt;
    crt.magnify = c.magnify || capture.crtMagnify;

    crt.curvature = cast(float) c.curvature;
    crt.scanlines = cast(float) c.scanlines;
    crt.mask = cast(float) c.mask;
    crt.chromaticAberration = cast(float) c.chromaticAberration;
    crt.vignette = cast(float) c.vignette;
    crt.flicker = cast(float) c.flicker;
    crt.brightness = cast(float) c.brightness;
    crt.bloomIntensity = cast(float) c.bloomIntensity;
    crt.bloomThreshold = cast(float) c.bloomThreshold;
    crt.bloomRadius = cast(float) c.bloomRadius;
    crt.lensRadius = cast(float) c.lensRadius;
    crt.lensPower = cast(float) c.lensPower;

    crt.uiReactive = c.uiReactive;
    crt.focusHalo = cast(float) c.focusHalo;
    crt.hoverGlow = cast(float) c.hoverGlow;
    crt.selectionBloom = cast(float) c.selectionBloom;
    crt.dividerTension = cast(float) c.dividerTension;

    crt.systemPointer = capture.pointerMode.length
        ? capture.pointerMode == "system"
        : p.mode == PointerMode.system;
}

/// ditto — the capture-only path, for a run with no config layer at all.
void applyCrtCapture(Effect)(ref Effect crt, in GuiCapture capture)
{
    crt.enabled = capture.crt;
    crt.tilt = capture.crtTilt;
    crt.magnify = capture.crtMagnify;
    crt.systemPointer = capture.pointerMode == "system";
}

@("crt_config.applyCrtConfig.setsEveryKnobAndLetsCapturesForceOn")
@safe
unittest
{
    // The stub is the contract: every setter the real effect has, recorded.
    static struct FakeEffect
    {
        bool enabled, tilt, magnify, uiReactive, systemPointer;
        float curvature, scanlines, mask, chromaticAberration, vignette;
        float flicker, brightness, bloomIntensity, bloomThreshold, bloomRadius;
        float lensRadius, lensPower, focusHalo, hoverGlow, selectionBloom;
        float dividerTension;
    }

    CrtConfig c;
    c.curvature = 0.42;
    c.bloomIntensity = 0.9;
    c.uiReactive = false;
    PointerConfig p;
    GuiCapture capture;

    FakeEffect e;
    applyCrtConfig(e, c, p, capture);
    assert(e.curvature == 0.42f, "a plain value reaches the effect");
    assert(e.bloomIntensity == 0.9f, "including the ones added last");
    assert(!e.uiReactive, "a false is applied, not skipped");
    assert(!e.enabled && !e.systemPointer);

    // The capture hooks force ON and never off — a golden capture must not be
    // able to silently disable what the config asked for.
    c.enabled = true;
    capture.crt = false;
    applyCrtConfig(e, c, p, capture);
    assert(e.enabled, "config on, capture silent");

    c.enabled = false;
    capture.crt = true;
    applyCrtConfig(e, c, p, capture);
    assert(e.enabled, "config off, capture forces on");

    // Pointer mode is the exception: the two modes are peers, so the hook
    // replaces rather than forces.
    p.mode = PointerMode.system;
    capture.pointerMode = "";
    applyCrtConfig(e, c, p, capture);
    assert(e.systemPointer);

    capture.pointerMode = "software";
    applyCrtConfig(e, c, p, capture);
    assert(!e.systemPointer, "the hook overrides the setting outright");
}

@("crt_config.applyCrtCapture.isTheNoConfigPath")
@safe
unittest
{
    static struct FakeEffect { bool enabled, tilt, magnify, systemPointer; }

    GuiCapture capture;
    capture.crt = true;
    capture.crtTilt = true;
    capture.pointerMode = "system";

    FakeEffect e;
    applyCrtCapture(e, capture);
    assert(e.enabled && e.tilt && !e.magnify && e.systemPointer);
}
