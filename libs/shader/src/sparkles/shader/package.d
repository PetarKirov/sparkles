/**
Single-source shaders (`SHD`): one D function that runs per cell on the CPU
and, compiled by LDC's Vulkan target, per fragment on the GPU.

$(B The vocabulary is GLSL's, spelled in D.) `vec2`/`vec3`/`vec4` are the
compiler's own vector types where it has them (LDC, every size) and a
lookalike struct where it does not (DMD below 16 bytes), the built-ins
(`floor`, `mod`, `dot`, `clamp`, `mix`, …) are the GLSL set over both, and
the constructors are `v2`/`v3`/`v4` because a `__vector` alias cannot be
called. A function written against this module reads like the shader it
becomes, and the CPU path calls the very same function.

$(B Device compilation is opt-in by target.) Under `-mdcompute-targets=…`
(which predefines `LDC_DCompute`) the module attributes ($(REF compute, sparkles,shader,attributes),
$(REF fragment, sparkles,shader,attributes), `@input`, `@uniform`,
`Sampler2D`) are LDC's real `ldc.dcompute` symbols, and every module marked
`@compute` is subject to LDC's device rules and emitted to SPIR-V. Without
it they are inert stand-ins, so an ordinary `dub build` sees plain D — no
device rules, no SPIR-V, no LDC dependency.

The pipeline that turns a `@fragment` function into the GLSL `sparkles:ui-raylib`
loads is `apps/shader-compile`; the spec is `docs/specs/ui/effects.md` (`EFX20`).
*/
module sparkles.shader;

public import sparkles.shader.attributes;
public import sparkles.shader.math;
public import sparkles.shader.types;
