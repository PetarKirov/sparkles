#!/usr/bin/env dub
/+ dub.sdl:
    name "structured_control_flow"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * D's unstructured control flow reaches SPIR-V structured.
 *
 * Shader SPIR-V must be structured: every branch names the block where its
 * paths rejoin, and a construct may be left only through it. D code is not
 * written that way — early returns from nested conditions, `break` and
 * `continue` out of loops — and an optimiser makes it less so (it unrolls the
 * loop below into a chain where every step has two exits). This example
 * compiles such a device module with the dcompute-enabled LDC at `-O0` and
 * `-O2` and validates the result under Vulkan 1.3's rules, which reject any
 * construct left other than through its merge block.
 *
 * Companion to docs/research/shading-languages/llvm-spirv-backend.md
 * (the structurizer) and dcompute.md.
 *
 * Run with: `dub run --single structured_control_flow.d`
 * Needs `ldc2-vulkan` and `spirv-val` on PATH (the dev and CI shells); prints
 * `SKIP:` and exits 0 without them.
 */
module structured_control_flow;

import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.format : format;
import std.path : buildPath;
import std.process : Config, execute, thisProcessID;
import std.stdio : writefln, writeln;

enum source = q{
@compute(CompileFor.deviceOnly) module shapes;
import ldc.dcompute;

pragma(LDC_intrinsic, "llvm.spv.thread.id.i32")
int threadId(int dim) @safe pure nothrow @nogc;

// Early returns among short-circuit conditions.
float mask(float x, float y)
{
    if (x < 0 || y < 0) return 0;
    if (x > 1 && y > 1) return 1;
    return 0.5f;
}

// A loop that returns, breaks and continues.
float find(float x, float y)
{
    float acc = 0;
    foreach (i; 0 .. 8)
    {
        acc += x;
        if (acc > 1 && y > 0.5f) return acc;
        if (acc > 2) break;
        if (y < 0.1f) continue;
        acc *= 0.5f;
    }
    return -acc;
}

@kernel([64, 1, 1]) void run(GlobalPointer!float a, GlobalPointer!float b,
    GlobalPointer!float c) {
    const i = threadId(0);
    c[i] = mask(a[i], b[i]) + find(a[i], b[i]);
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
    const dir = buildPath(tempDir, format("sl-structured-%s", thisProcessID));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "shapes.d"), source);

    foreach (opt; ["-O0", "-O2"])
    {
        const prefix = "shapes" ~ opt;
        const compile = execute(["ldc2-vulkan", opt, "-c", "-m64",
            "-mdcompute-targets=vulkan-130", "-mdcompute-file-prefix=" ~ prefix,
            "-od=" ~ dir, buildPath(dir, "shapes.d")], null, Config.none, size_t.max, dir);
        assert(compile.status == 0, compile.output);
        const spv = buildPath(dir, prefix ~ "_vulkan130_64.spv");
        const val = execute(["spirv-val", "--target-env", "vulkan1.3", spv]);
        writefln("%s: spirv-val --target-env vulkan1.3: %s", opt,
            val.status == 0 ? "valid" : val.output);
        assert(val.status == 0, "the structured SPIR-V must validate");
    }
}
