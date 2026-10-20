/**
The triangle's shaders, in D, for the host and the device.

There is no vertex buffer: `vertexIndex` indexes a table of corners, so the
example allocates no device memory, which keeps it a test of the swapchain
and the synchronisation rather than of an allocator. One push constant, the
drawable's aspect ratio, keeps the triangle's shape at any window size.

The device build (`shader-compile`, the package's `shaders` configuration)
compiles both entry points to SPIR-V for `vulkan1.3`; the host build compiles
the same functions as ordinary D, which is what a readback compares the
rendered triangle against.
*/
@compute(CompileFor.hostAndDevice) @profiles(vulkan13)
module sparkles.vulkan_wsi.triangle_shader;

import sparkles.shaders;

/// The triangle's push-constant block.
struct TriangleView
{
    /// The drawable's width over its height.
    float aspect = 1.0f;
}

/// What the vertex stage hands the fragment stage.
struct TriangleVaryings
{
    @builtin(Builtin.position) vec4 position; ///
    vec3 colour; /// the corner's colour, interpolated across the face
}

/**
The corner `index` of the triangle, in clip space. The corners are those of a
triangle in a square drawable, scaled along the longer axis by the aspect
ratio, so the triangle keeps its shape and fits in any drawable.
*/
@vertex TriangleVaryings triangleVertex(@builtin(Builtin.vertexIndex) int index,
    PushConstants!TriangleView view)
{
    vec2[3] corner;
    corner[0] = v2(0.0f, -0.6f);
    corner[1] = v2(0.6f, 0.6f);
    corner[2] = v2(-0.6f, 0.6f);
    vec3[3] colour;
    colour[0] = v3(0.98f, 0.24f, 0.36f);
    colour[1] = v3(0.30f, 0.82f, 0.44f);
    colour[2] = v3(0.29f, 0.56f, 0.95f);

    const wide = view.aspect > 1.0f;
    const scale = v2(wide ? 1.0f / view.aspect : 1.0f, wide ? 1.0f : view.aspect);
    TriangleVaryings v;
    const at = corner[index] * scale;
    v.position = v4(at.x, at.y, 0.0f, 1.0f);
    v.colour = colour[index];
    return v;
}

/// The interpolated colour, opaque: the swapchain is created with
/// `COMPOSITE_ALPHA_OPAQUE`.
@fragment vec4 triangleFragment(@input vec3 colour) => v4(colour, 1.0f);

static assert(stagesLink!(triangleVertex, triangleFragment));
