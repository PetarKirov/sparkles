/**
The shader readback's probe unit (`sparkles.ui_raylib.shader_readback`): each
entry reads its arguments `a` from `texture0` and returns four results, which
the test compares with the host's evaluation of the same functions.
*/
@compute(CompileFor.deviceOnly)
module probe;

import sparkles.shaders;

@fragment vec4 probeSample(@input vec2 fragTexCoord, Sampler2D texture0)
    => texture0.sample(fragTexCoord);

@fragment vec4 probeTranscendental(@input vec2 fragTexCoord, Sampler2D texture0)
{
    const a = texture0.sample(fragTexCoord);
    return v4(sin(a.x), cos(a.x), exp(a.y), sqrt(a.z));
}

@fragment vec4 probePow(@input vec2 fragTexCoord, Sampler2D texture0)
{
    const a = texture0.sample(fragTexCoord);
    return v4(pow(a.x, a.y), pow(a.z, a.w), 0.0f, 1.0f);
}

@fragment vec4 probeRounding(@input vec2 fragTexCoord, Sampler2D texture0)
{
    const a = texture0.sample(fragTexCoord);
    return v4(floor(a.x), fract(a.x), abs(a.x), mod(a.x, a.y));
}

@fragment vec4 probeSelect(@input vec2 fragTexCoord, Sampler2D texture0)
{
    const a = texture0.sample(fragTexCoord);
    return v4(min(a.x, a.y), max(a.x, a.y), clamp(a.x, -1.0f, 1.0f), step(a.y, a.x));
}

@fragment vec4 probeCompound(@input vec2 fragTexCoord, Sampler2D texture0)
{
    const a = texture0.sample(fragTexCoord);
    return v4(mix(a.x, a.y, a.z), smoothstep(-1.0f, 1.0f, a.x),
        dot(v2(a.x, a.y), v2(a.z, a.w)), length(v2(a.x, a.y)));
}

@fragment vec4 probeLuma(@input vec2 fragTexCoord, Sampler2D texture0)
{
    const a = texture0.sample(fragTexCoord);
    return v4(luma(a.xyz), 0.0f, 0.0f, 1.0f);
}

struct Light
{
    float gain;
    int bias;
    vec3 tint;
}

@fragment vec4 probeUniforms(@input vec2 fragTexCoord, Sampler2D texture0, @uniform int count,
    @uniform Light light)
{
    const a = texture0.sample(fragTexCoord);
    return v4(a.x * light.gain + cast(float) (count + light.bias), a.y * light.tint.y,
        light.tint.z, 1.0f);
}
