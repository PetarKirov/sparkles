#version 450
//
// The triangle, with no vertex buffer.
//
// `gl_VertexIndex` indexes constant arrays instead, so the example allocates
// no device memory at all — which keeps it a test of the swapchain and the
// synchronisation rather than of an allocator this binding deliberately does
// not have yet (VMA is the field's settled answer and is orthogonal).
//
// Regenerate the SPIR-V beside this file after any edit:
//
//     glslangValidator -V -g0 triangle.vert -o triangle.vert.spv
//
// `glslangValidator` is in the dev shell. It is deliberately not in the CI
// tier: the compiled output is committed, so no CI job needs a shader
// compiler to build this example.

vec2 positions[3] = vec2[](
    vec2( 0.0, -0.6),
    vec2( 0.6,  0.6),
    vec2(-0.6,  0.6)
);

vec3 colors[3] = vec3[](
    vec3(0.98, 0.24, 0.36),
    vec3(0.30, 0.82, 0.44),
    vec3(0.29, 0.56, 0.95)
);

layout(location = 0) out vec3 fragColor;

void main()
{
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
    fragColor = colors[gl_VertexIndex];
}
