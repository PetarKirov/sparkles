/**
The one GLSL prologue per dialect, shared by every shader this backend builds.

A fragment shader here is written once and compiled as `#version 330` on the
desktop or `#version 100` on Android. The differences are all spellings the
GLSL preprocessor can absorb — the sampler function's name, the output
variable's, and whether varyings are `in` or `varying` — so they live in a
prologue and every shader body is written once.

The CRT's two variants used to be a 330-line verbatim copy differing in
seventeen lines, only one of which any given build compiles: a typo in the
Android half was discoverable only by building an APK and running it on a
device. This module is what stops that from being re-invented per shader.
*/
module sparkles.ui_raylib.glsl;

// Plain WYSIWYG strings, not `q{}` token strings: `#define` is not a D token,
// and a token string holding one is a deprecation on every build.

/// The desktop dialect.
enum string glslPrologue = `
#version 330

in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;

#define SAMPLE texture
#define OUT_COLOR finalColor
`;

/// The OpenGL ES dialect, for the Android build.
enum string glslPrologueEs = `
#version 100
precision mediump float;

varying vec2 fragTexCoord;
varying vec4 fragColor;

#define SAMPLE texture2D
#define OUT_COLOR gl_FragColor
`;

/// The dialect this build compiles for.
version (Android)
    enum string activePrologue = glslPrologueEs;
else
    enum string activePrologue = glslPrologue;
