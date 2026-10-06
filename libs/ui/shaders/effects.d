/**
The GPU half of the built-in effects: one `@fragment` entry point per effect,
each a thin wrapper around the transform in `sparkles.ui.effect_shaders`.

Device-only, and outside `sparkles:ui`'s source paths on purpose: only
`shader-compile` ever compiles this module, with LDC's Vulkan target (which
predefines `LDC_DCompute`), and what it produces is the GLSL under
`generated/` that `sparkles.ui.effect` string-imports. An ordinary build never
sees it — its `Sampler2D.sample` names a SPIR-V intrinsic no CPU has.

The interface is raylib's: `fragTexCoord`/`fragColor` are the varyings its
default vertex shader emits, `texture0` the sampler it binds, `finalColor`
the output. `uExtentCells` and the per-effect uniforms are what
`ui_raylib.effect_gpu` uploads at composite time.
*/
@compute(CompileFor.deviceOnly)
module effects;

import sparkles.shaders;
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

// ── bloom: four passes (tier 2) ─────────────────────────────────────────────
// Extract the bright part at half size, blur it horizontally, then vertically,
// then add it back over the bracket. `ui_raylib.effect_gpu` chains them: each
// pass draws the previous one's image as `texture0`, and the composite also
// reads the blurred glow as `texture1`. `uResolution` is the size of the image
// a pass writes.

/// ditto
@fragment vec4 bloomExtract(@input vec2 fragTexCoord, Sampler2D texture0,
    @uniform float uBloomThreshold)
    => v4(sparkles.ui.effect_shaders.bloomBright(texture0.sample(fragTexCoord).xyz,
        uBloomThreshold), 1.0f);

/**
A nine-tap Gaussian along `dir`, `uBloomRadius` output pixels per tap. Each
tap is weighted and added on its own, in the order the hand-written pass
used, so the float rounding matches it.
*/
private vec3 bloomBlur(Sampler2D texture0, vec2 uv, vec2 dir, vec2 uResolution,
    float uBloomRadius) @safe pure nothrow @nogc
{
    enum float w0 = 0.2270270270f, w1 = 0.1945945946f, w2 = 0.1216216216f,
        w3 = 0.0540540541f, w4 = 0.0162162162f;
    const s = dir * uBloomRadius / uResolution;
    vec3 sum = texture0.sample(uv).xyz * w0;
    sum = sum + texture0.sample(uv + s * 1.0f).xyz * w1;
    sum = sum + texture0.sample(uv - s * 1.0f).xyz * w1;
    sum = sum + texture0.sample(uv + s * 2.0f).xyz * w2;
    sum = sum + texture0.sample(uv - s * 2.0f).xyz * w2;
    sum = sum + texture0.sample(uv + s * 3.0f).xyz * w3;
    sum = sum + texture0.sample(uv - s * 3.0f).xyz * w3;
    sum = sum + texture0.sample(uv + s * 4.0f).xyz * w4;
    sum = sum + texture0.sample(uv - s * 4.0f).xyz * w4;
    return sum;
}

/// ditto
@fragment vec4 bloomBlurH(@input vec2 fragTexCoord, Sampler2D texture0,
    @uniform vec2 uResolution, @uniform float uBloomRadius)
    => v4(bloomBlur(texture0, fragTexCoord, v2(1.0f, 0.0f), uResolution, uBloomRadius), 1.0f);

/// ditto
@fragment vec4 bloomBlurV(@input vec2 fragTexCoord, Sampler2D texture0,
    @uniform vec2 uResolution, @uniform float uBloomRadius)
    => v4(bloomBlur(texture0, fragTexCoord, v2(0.0f, 1.0f), uResolution, uBloomRadius), 1.0f);

/// ditto — `texture0` is the bracket, `texture1` the blurred glow.
@fragment vec4 bloomComposite(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, Sampler2D texture1, @uniform vec4 colDiffuse,
    @uniform float uBloomIntensity)
    => sparkles.ui.effect_shaders.bloomOver(
        texture0.sample(fragTexCoord) * colDiffuse * fragColor,
        texture1.sample(fragTexCoord).xyz * uBloomIntensity);
