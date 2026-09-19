/**
The built-in effects, written once (`EFX20`).

Each transform here is $(B the) implementation: `ui-tui` calls it per cell
through the adapters in $(MREF sparkles,ui,effect), and `libs/ui/shaders/effects.d`
wraps it in a `@fragment` entry point that `shader-compile` turns into the
GLSL `ui-raylib` loads. There is no second, hand-written GPU copy to drift.

$(B Cell coordinates, float colours.) `at` is the cell relative to the
bracket's origin and `extent` the bracket's size in cells — on the GPU the
fragment shader floors `fragTexCoord * uExtentCells` to get the same `at` —
and `color` is the cell's resolved colour in `[0, 1]`, which is what a
sampler returns and what the CPU adapter converts a byte colour to.

The module is `@compute(CompileFor.hostAndDevice)`: plain D in an ordinary
build (the attribute is inert without `-d-version=SparklesShaderDevice`),
device code when the shader pipeline compiles it. That is also why it
carries no tests — a device module may not hold a string literal, and a
test's name is one. Its tests live beside the adapters in
$(MREF sparkles,ui,effect).
*/
@compute(CompileFor.hostAndDevice)
module sparkles.ui.effect_shaders;

import sparkles.shader;

/// Every other row darkened — the raster a CRT's beam skips.
vec3 scanlines(in vec2 at, in vec2 extent, in vec3 color) @safe pure nothrow @nogc
    => mod(at.y, 2.0f) >= 1.0f ? color * 0.62f : color;

/**
Tinted toward a green phosphor, keeping each cell's own luminance.

Luminance rather than a flat green, so text stays readable and the tint reads
as a display characteristic rather than as a colour wash: a bright cell is
bright green and a dim one is dim green, which is what a monochrome tube does.
Rec. 601 luma, because a naive average makes blue text vanish.
*/
vec3 phosphor(in vec2 at, in vec2 extent, in vec3 color) @safe pure nothrow @nogc
{
    const l = luma(color);
    return v3(l * 0.30f, l, l * 0.45f);
}

/// Uniformly darkened — an inactive pane, without the view knowing it is one.
vec3 dim(in vec2 at, in vec2 extent, in vec3 color) @safe pure nothrow @nogc
    => color * 0.55f;

/**
A hue sweep across the bracket's columns, at each cell's own luminance.

$(B Why a column-wise built-in exists.) `scanlines` varies down the rows, so
it needs height before it reads as anything: in a four-row panel only one or
two lines are ever darkened and the effect looks like noise. Position is two
axes, and a specimen that only exercises one of them under-demonstrates the
tier. This varies along `at.x`, which every bracket has plenty of, and lands a
different truecolor value in each cell.

Luminance is kept, as in $(LREF phosphor): the hue says where the cell is,
the brightness still says what it is, and text stays readable.
*/
vec3 spectrum(in vec2 at, in vec2 extent, in vec3 color) @safe pure nothrow @nogc
{
    const w = max(extent.x, 1.0f);
    const h = floor(at.x) / w * 6.0f;
    const t = mod(v3(h) + v3(0, 4, 2), v3(6));
    const hue = clamp(abs(t - v3(3)) - v3(1), v3(0), v3(1));
    return hue * luma(color);
}

/**
Barrel distortion — the tier-1 warp: rewrites a normalised position, and so
has no per-cell form (`EFX12`). The backend samples the subtree at what this
returns and treats anything outside `[0, 1]` as off the tube.

The screen fit keeps the midpoint of each edge on the edge whatever the
amount, which is the same `1 / (1 + k/4)` the CRT's own projection derives.
*/
vec2 curvature(in vec2 uv, float amount) @safe pure nothrow @nogc
{
    const c = uv - v2(0.5f);
    const d = dot(c, c);
    const warped = uv + c * (d * amount);
    const fit = 1.0f / (1.0f + amount * 0.25f);
    return (warped - v2(0.5f)) * fit + v2(0.5f);
}
