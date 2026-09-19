/**
The GPU half of the built-in effects: one `@fragment` entry point per effect,
each a thin wrapper around the transform in `sparkles.ui.effect_shaders`.

Device-only, and outside `sparkles:ui`'s source paths on purpose: only
`shader-compile` ever compiles this module, with LDC's Vulkan target and
`-d-version=SparklesShaderDevice`, and what it produces is the GLSL under
`generated/` that `sparkles.ui.effect` string-imports. An ordinary build never
sees it — its `Sampler2D.sample` names a SPIR-V intrinsic no CPU has.

The interface is raylib's: `fragTexCoord`/`fragColor` are the varyings its
default vertex shader emits, `texture0` the sampler it binds, `finalColor`
the output. `uExtentCells` and the per-effect uniforms are what
`ui_raylib.effect_gpu` uploads at composite time.
*/
@compute(CompileFor.deviceOnly)
module effects;

import sparkles.shader;
static import sparkles.ui.effect_shaders;

/**
The tier-0 bracket (`EFX8` on the GPU): sample the rendered subtree, floor
the texture coordinate to the cell — the very `at` the terminal hands the
same function — and run the transform on the texel's colour, keeping its
alpha.
*/
private vec4 tier0(alias transform)(vec2 fragTexCoord, vec4 fragColor,
    Sampler2D texture0, vec2 uExtentCells) @safe pure nothrow @nogc
{
    const texel = texture0.sample(fragTexCoord) * fragColor;
    const at = floor(fragTexCoord * uExtentCells);
    return v4(transform(at, uExtentCells, texel.xyz), texel.w);
}

/// ditto
@fragment vec4 scanlines(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform vec2 uExtentCells)
    => tier0!(sparkles.ui.effect_shaders.scanlines)(fragTexCoord, fragColor, texture0, uExtentCells);

/// ditto
@fragment vec4 phosphor(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform vec2 uExtentCells)
    => tier0!(sparkles.ui.effect_shaders.phosphor)(fragTexCoord, fragColor, texture0, uExtentCells);

/// ditto
@fragment vec4 dim(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform vec2 uExtentCells)
    => tier0!(sparkles.ui.effect_shaders.dim)(fragTexCoord, fragColor, texture0, uExtentCells);

/// ditto
@fragment vec4 spectrum(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform vec2 uExtentCells)
    => tier0!(sparkles.ui.effect_shaders.spectrum)(fragTexCoord, fragColor, texture0, uExtentCells);

/**
The tier-1 bracket (`EFX11`): sample at the warped position. Outside `[0, 1]`
is off the subtree, not a clamped edge — a barrel distortion that smeared its
border pixels outward would be hiding the shape it exists to show.
Transparent is the honest answer and composites over whatever the bracket
sits on.
*/
@fragment vec4 curvature(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform float uAmount)
{
    const uv = sparkles.ui.effect_shaders.curvature(fragTexCoord, uAmount);
    if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f)
        return v4(0.0f);
    return texture0.sample(uv) * fragColor;
}
