/**
The fragment stage on the device (`SHF8`, M7): its window position, facing,
`discard`, derivatives and `demote`, each read back from an 8×8 target.

Two vertex entry points cover the target with one triangle, its clip-space
corners counter-clockwise with y up, or the reverse; each fragment entry
point returns what it reads as a colour.
*/
@compute(CompileFor.hostAndDevice) @profiles(vulkan13)
module fragment_probe;

import sparkles.shaders;

/// The probes' target is `stageSize`×`stageSize`.
enum stageSize = 8;

/// What the vertex stage writes: the position alone.
struct StageVaryings
{
    @builtin(Builtin.position) vec4 position; ///
}

private StageVaryings corner(vec2 at) => StageVaryings(v4(at.x, at.y, 0.0f, 1.0f));

/// The target's triangle, counter-clockwise in clip space with y up.
@vertex StageVaryings stageVertex(@builtin(Builtin.vertexIndex) int index)
{
    vec2[3] at;
    at[0] = v2(-1.0f, -1.0f);
    at[1] = v2(3.0f, -1.0f);
    at[2] = v2(-1.0f, 3.0f);
    return corner(at[index]);
}

/// The same triangle, clockwise.
@vertex StageVaryings stageVertexReversed(@builtin(Builtin.vertexIndex) int index)
{
    vec2[3] at;
    at[0] = v2(-1.0f, -1.0f);
    at[1] = v2(-1.0f, 3.0f);
    at[2] = v2(3.0f, -1.0f);
    return corner(at[index]);
}

/// The window position over the target's size, and the facing.
@fragment vec4 stageFragCoord(@builtin(Builtin.fragCoord) vec4 position,
    @builtin(Builtin.frontFacing) bool front)
    => v4(position.x / stageSize, position.y / stageSize, front ? 1.0f : 0.0f, 1.0f);

/// The left half discarded, the right half white.
@fragment vec4 stageDiscard(@builtin(Builtin.fragCoord) vec4 position)
{
    if (position.x < stageSize / 2)
        discard();
    return v4(1.0f);
}

/// Derivatives of the window position, plain, coarse and fine.
@fragment vec4 stageDerivatives(@builtin(Builtin.fragCoord) vec4 position)
    => v4(dpdx(position.x) / 2, dpdyCoarse(position.y) / 4,
        fwidthFine(position.x / 8 + position.y / 16), 1.0f);

/// Every odd column demoted. A demoted invocation keeps running as a helper,
/// so an even column's fine derivative, taken from its odd neighbour in the
/// quad, is still one per pixel.
@fragment vec4 stageDemote(@builtin(Builtin.fragCoord) vec4 position)
{
    if ((cast(int) position.x & 1) == 1)
        demote();
    return v4(dpdxFine(position.x) / 2, 0.0f, 0.0f, 1.0f);
}
