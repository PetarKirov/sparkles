#version 450
//
// Interpolate the per-corner colour across the triangle. Opaque alpha,
// because the swapchain is created with `COMPOSITE_ALPHA_OPAQUE`.
//
// Regenerate the SPIR-V beside this file after any edit:
//
//     glslangValidator -V -g0 triangle.frag -o triangle.frag.spv

layout(location = 0) in vec3 fragColor;
layout(location = 0) out vec4 outColor;

void main()
{
    outColor = vec4(fragColor, 1.0);
}
