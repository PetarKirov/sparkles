#version 450
//
// One triangle that covers the whole framebuffer: the test pattern is
// computed per pixel in `test_pattern.frag`, so the geometry only has to
// reach every pixel. Its corners lie at (-1,-1), (3,-1) and (-1,3) in clip
// space, which the viewport clips to the framebuffer.
//
// Regenerate the SPIR-V beside this file after any edit:
//
//     glslangValidator -V -g0 test_pattern.vert -o test_pattern.vert.spv

void main()
{
    const vec2 corner = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
}
