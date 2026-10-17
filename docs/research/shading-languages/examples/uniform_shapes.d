#!/usr/bin/env dub
/+ dub.sdl:
    name "uniform_shapes"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * One uniform, two environments: OpenGL's loose uniform is valid SPIR-V that
 * Vulkan forbids.
 *
 * sparkles' fragment shaders take their uniforms as loose, named values, the
 * shape an OpenGL host sets with `glUniform*` and the shape the GLSL 3.30 and
 * ES outputs need. In SPIR-V that is a non-opaque `UniformConstant` variable,
 * which the universal rules accept and Vulkan's reject
 * (VUID-StandaloneSpirv-UniformConstant-04655): a Vulkan host needs the same
 * value inside a uniform block or a push-constant block. This example compiles
 * one fragment shader with a loose uniform and validates it both ways.
 *
 * Companion to docs/research/shading-languages/concepts.md § "Uniform,
 * uniform block and push constant" and dcompute.md.
 *
 * Run with: `dub run --single uniform_shapes.d`
 * Needs `ldc2-vulkan` and `spirv-val` on PATH; prints `SKIP:` without them.
 */
module uniform_shapes;

import std.algorithm : canFind;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.format : format;
import std.path : buildPath;
import std.process : Config, execute, thisProcessID;
import std.stdio : writeln;

enum source = q{
@compute(CompileFor.deviceOnly) module tint;
import ldc.dcompute;

@fragment __vector(float[4]) tint(@input __vector(float[2]) fragTexCoord,
    @uniform float gain)
{
    __vector(float[4]) c = gain;
    c[3] = 1;
    return c;
}
};

bool onPath(string tool)
{
    try
        return execute(["sh", "-c", "command -v " ~ tool]).status == 0;
    catch (Exception)
        return false;
}

void main()
{
    if (!onPath("ldc2-vulkan") || !onPath("spirv-val"))
    {
        writeln("SKIP: needs ldc2-vulkan and spirv-val on PATH");
        return;
    }
    const dir = buildPath(tempDir, format("sl-uniform-%s", thisProcessID));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "tint.d"), source);
    const compile = execute(["ldc2-vulkan", "-c", "-m64", "-mdcompute-targets=vulkan-130",
        "-mdcompute-file-prefix=tint", "-od=" ~ dir, buildPath(dir, "tint.d")],
        null, Config.none, size_t.max, dir);
    assert(compile.status == 0, compile.output);
    const spv = buildPath(dir, "tint_vulkan130_64.spv");

    const universal = execute(["spirv-val", "--target-env", "spv1.6", spv]);
    assert(universal.status == 0, universal.output);
    writeln("spirv-val --target-env spv1.6:    valid");

    const vulkan = execute(["spirv-val", "--target-env", "vulkan1.3", spv]);
    assert(vulkan.status != 0, "a loose uniform must be rejected for Vulkan");
    assert(vulkan.output.canFind("VUID-StandaloneSpirv-UniformConstant-04655"), vulkan.output);
    writeln("spirv-val --target-env vulkan1.3: rejected (VUID-StandaloneSpirv-UniformConstant-04655)");
}
