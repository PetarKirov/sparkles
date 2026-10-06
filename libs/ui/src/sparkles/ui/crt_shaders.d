/**
The CRT's geometry, written once (`CRT8`, `CRT10`): where a screen position
reads from on the tube. The tube's fragment shader (`libs/ui/shaders/effects.d`)
samples at what these return, and `sparkles.ui_raylib.crt_projection` maps
the pointer and the displayed pixel through the very same functions — so
the cursor drawn on the GPU and the point input lands on cannot drift apart.

They used to be a pair, a GLSL `curve()` and a hand twin on the CPU, that no
compiler could hold together; two bugs of exactly that shape — a lens applied
in the wrong space, a screen fit hardcoded to one curvature — were found by
eye.

All positions are normalized and y-flipped: the texture coordinate a
fragment shader is handed, with `(0, 0)` at the bottom left.

The module is `@compute(CompileFor.hostAndDevice)`, like
$(MREF sparkles,ui,effect_shaders), and for the same reason carries no tests:
they live in `sparkles.ui_raylib.crt_projection`, beside the maps that use it.
*/
@compute(CompileFor.hostAndDevice)
module sparkles.ui.crt_shaders;

import sparkles.shaders;

/**
The barrel bend, fitted to the screen (`CRT10`).

`apex` is the point the bend is centred on when `tilt` is above one half —
the pointer, so the surface is flat directly under it and the far side curves
away — and the screen's middle otherwise. Tilting softens the bend to five
eighths.

The bend pushes a point at radius r out by `1 + k r²`, so an edge midpoint,
at r = 1/2, lands at `1 + k/4`; scaling by the reciprocal seats it back on
the screen edge at any curvature, and leaves a flat screen (k = 0) a 1:1
blit. The corners overhang and are cut: that is the rounded tube face. Exact
with tilt off — an apex that is not the centre deforms the four edges by
different amounts, and one scalar cannot seat all four.
*/
vec2 crtCurve(in vec2 coord, in vec2 apex, float tilt, float curvature)
    @safe pure nothrow @nogc
{
    const centre = tilt > 0.5f ? apex : v2(0.5f);
    const k = tilt > 0.5f ? curvature * 0.625f : curvature;
    const cc = coord - centre;
    const dist = dot(cc, cc);
    const uv = coord + cc * (dist * k);
    const fit = 1.0f / (1.0f + k * 0.25f);
    return (uv - v2(0.5f)) * fit + v2(0.5f);
}

/**
How far `uv` is from the lens centre `centre`, as a fraction of the lens
`radius` — `aspect` (width over height) makes the lens round on screen. One
or more is outside the lens.
*/
float crtLensDistance(in vec2 uv, in vec2 centre, float aspect, float radius)
    @safe pure nothrow @nogc
{
    const delta = uv - centre;
    return length(v2(delta.x * aspect, delta.y)) / radius;
}

/**
The magnifier lens (`CRT6`), applied in texture space after the bend: inside
the lens, `uv` is pulled toward `centre` by a dome profile of strength
`power`; outside it is untouched. `centre` itself stays fixed, which is why
the lens is centred on the pointer's own UI position — the cursor drawn there
is the point the lens does not move.
*/
vec2 crtLens(in vec2 uv, in vec2 centre, float aspect, float radius, float power)
    @safe pure nothrow @nogc
{
    const n = crtLensDistance(uv, centre, aspect, radius);
    if (n >= 1.0f)
        return uv;
    const z = sqrt(max(0.0f, 1.0f - n * n));
    const factor = 1.0f - power * pow(z, 1.4f);
    return centre + (uv - centre) * factor;
}

/// The lens rim's brightness at lens distance `n` (from $(LREF crtLensDistance)):
/// a thin ring just inside the edge, zero elsewhere.
float crtLensRim(float n) @safe pure nothrow @nogc
    => n >= 1.0f ? 0.0f : smoothstep(0.90f, 0.97f, n) * smoothstep(1.0f, 0.97f, n);
