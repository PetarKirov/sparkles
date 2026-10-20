/**
A `std140` uniform block read back from the device (`SHR6`).

`Probe`'s `std140` layout differs from D's at every turn: a `float` in a
`vec3`'s padding, a `float[3]` with a stride of 16, a nested struct aligned to
16 and a scalar after it. The host writes it with `writeLayout`; each
fragment entry point returns four of its fields as a colour, so a field read
from the wrong offset reads padding or a neighbour instead.
*/
@compute(CompileFor.hostAndDevice) @profiles(vulkan13)
module block_probe;

import sparkles.shaders;

/// A struct nested in the block.
struct Inner
{
    vec2 p; ///
    float q; ///
}

/// The block.
struct Probe
{
    vec3 a; ///
    float b; ///
    float[3] c; ///
    Inner inner; ///
    float d; ///
}

/// What the vertex stage writes: the position alone.
struct ProbeVaryings
{
    @builtin(Builtin.position) vec4 position; ///
}

/// A triangle over the whole viewport.
@vertex ProbeVaryings probeVertex(@builtin(Builtin.vertexIndex) int index)
{
    vec2[3] corner;
    corner[0] = v2(-1.0f, -1.0f);
    corner[1] = v2(3.0f, -1.0f);
    corner[2] = v2(-1.0f, 3.0f);
    const at = corner[index];
    ProbeVaryings v;
    v.position = v4(at.x, at.y, 0.0f, 1.0f);
    return v;
}

/// `a` and `b`.
@fragment vec4 probeFirst(UniformBlock!Probe probe) => v4(probe.a, probe.b);

/// `c` and `inner.q`.
@fragment vec4 probeSecond(UniformBlock!Probe probe)
    => v4(probe.c[0], probe.c[1], probe.c[2], probe.inner.q);

/// `inner.p` and `d`.
@fragment vec4 probeThird(UniformBlock!Probe probe)
    => v4(probe.inner.p.x, probe.inner.p.y, probe.d, 1.0f);
