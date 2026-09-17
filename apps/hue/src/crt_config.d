/**
One place the CRT's configuration reaches the effect (`CFG3`).

Three sites used to set it: two blocks of twenty verbatim-identical lines (the
startup path and the settings pane's live re-apply), plus a third partial that
set three of the twenty-one fields, one-way, after the first had already set
them all — dead in effect, and the site a maintainer grepping for `crt.enabled`
found first.

Twenty-one fields set from two places is a nineteenth knob waiting to be added
to one of them and not the other, with nothing to catch it. So: one function,
and `applyCrtConfig` is where a new knob goes.
*/
module crt_config;

import sparkles.ui_raylib : CrtEffect;

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
void applyCrtConfig(ref CrtEffect crt, in CrtConfig c, in PointerConfig p,
    in GuiCapture capture) @system
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
void applyCrtCapture(ref CrtEffect crt, in GuiCapture capture) @system
{
    crt.enabled = capture.crt;
    crt.tilt = capture.crtTilt;
    crt.magnify = capture.crtMagnify;
    crt.systemPointer = capture.pointerMode == "system";
}
