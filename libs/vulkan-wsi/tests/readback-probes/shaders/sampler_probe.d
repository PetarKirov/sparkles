/**
Samplers of their own (`SHR7`): one 2×1 image, black then white, read through
a nearest and a linear sampler across an 8×1 target. It samples, so it is
device-only; the readback numbers its bindings as `SHR7` does: the image at
1, `nearest` at 2 and `linear` at 3.
*/
@compute(CompileFor.deviceOnly) @profiles(vulkan13)
module sampler_probe;

import sparkles.shaders;

/// Each column's texel through `nearest`, and through `linear`.
@fragment vec4 stageSamplers(@builtin(Builtin.fragCoord) vec4 position, Sampler2D ramp,
    SamplerState nearest, SamplerState linear)
{
    const uv = v2(position.x / 8, 0.5f);
    return v4(ramp.sample(nearest, uv).x, ramp.sample(linear, uv).x, 0.0f, 1.0f);
}
