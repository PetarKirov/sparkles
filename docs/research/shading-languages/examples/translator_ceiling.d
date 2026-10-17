#!/usr/bin/env dub
/+ dub.sdl:
    name "translator_ceiling"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * A translator's targets set the ceiling of a generate-SPIR-V-then-translate
 * design.
 *
 * The same SPIR-V module translates to some targets and not to others. Here a
 * fragment shader stops contributing with `llvm.spv.discard`, which the LLVM
 * SPIR-V backend lowers at SPIR-V 1.6 to `OpDemoteToHelperInvocation`: the
 * invocation keeps running as a helper. SPIRV-Cross can express that in
 * Vulkan GLSL and HLSL Shader Model 6, but not in GLSL 3.30 or GLSL ES 3.00,
 * which only know `discard` (terminate), and not in MSL before 2.3. The
 * terminating form, `llvm.spv.terminate.invocation`
 * (`OpTerminateInvocation`), translates to all of them.
 *
 * Companion to docs/research/shading-languages/spirv-cross.md and
 * concepts.md § "Discard, demote and terminate".
 *
 * Run with: `dub run --single translator_ceiling.d`
 * Needs `ldc2-vulkan` and `spirv-cross` on PATH; prints `SKIP:` without them.
 */
module translator_ceiling;

import std.array : replace;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.format : format;
import std.path : buildPath;
import std.process : Config, execute, thisProcessID;
import std.stdio : writefln, writeln;

enum source = q{
@compute(CompileFor.deviceOnly) module stop;
import ldc.dcompute;

pragma(LDC_intrinsic, "INTRINSIC")
void stop() nothrow @nogc;

@fragment __vector(float[4]) cutout(@input __vector(float[2]) fragTexCoord)
{
    if (fragTexCoord[0] < 0.5f)
        stop();
    __vector(float[4]) c = 1;
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
    if (!onPath("ldc2-vulkan") || !onPath("spirv-cross"))
    {
        writeln("SKIP: needs ldc2-vulkan and spirv-cross on PATH");
        return;
    }
    const dir = buildPath(tempDir, format("sl-ceiling-%s", thisProcessID));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    const targets = [
        ["GLSL 3.30", "--version", "330"],
        ["GLSL ES 3.00", "--es", "--version", "300"],
        ["Vulkan GLSL 4.50", "--version", "450", "--vulkan-semantics"],
        ["HLSL SM 6.0", "--hlsl", "--shader-model", "60"],
        ["MSL 2.0", "--msl", "--msl-version", "20000"],
    ];
    foreach (intrinsic; ["llvm.spv.discard", "llvm.spv.terminate.invocation"])
    {
        const name = intrinsic == "llvm.spv.discard" ? "demote" : "terminate";
        write(buildPath(dir, name ~ ".d"), source.replace("INTRINSIC", intrinsic));
        const compile = execute(["ldc2-vulkan", "-c", "-m64", "-mdcompute-targets=vulkan-130",
            "-mdcompute-file-prefix=" ~ name, "-od=" ~ dir, buildPath(dir, name ~ ".d")],
            null, Config.none, size_t.max, dir);
        assert(compile.status == 0, compile.output);
        const spv = buildPath(dir, name ~ "_vulkan130_64.spv");
        writefln("%s (%s):", name, intrinsic);
        foreach (t; targets)
        {
            const r = execute(["spirv-cross", "--entry", "cutout", "--stage", "frag"] ~ t[1 .. $] ~ [spv]);
            writefln("  %-17s %s", t[0], r.status == 0 ? "translates" : "rejected");
            const expected = name == "terminate" || t[0] == "Vulkan GLSL 4.50" || t[0] == "HLSL SM 6.0";
            assert((r.status == 0) == expected, t[0] ~ ": " ~ r.output);
        }
    }
}
