/**
The build step against the real toolchain: the device compiler, dub, and the
SPIR-V and GLSL tools, on fixture packages written to a scratch directory.

These are the tests a fake cannot stand in for — what the compiler puts in
the module (`SHF1`–`SHF3`, `SHF5`–`SHF7`), and what the step does with each
outcome (`SHP1`, `SHP4`, `SHP8`–`SHP10`). Each one skips where the toolchain
is absent (the Windows test leg has no device compiler, `SHT4`); every other
test leg carries it in its shell.
*/
module toolchain_tests;

version (unittest):

import std.algorithm : canFind, filter, map, startsWith;
import std.array : array, split;
import std.conv : to;
import std.file : dirEntries, exists, mkdirRecurse, readText, remove, rmdirRecurse, SpanMode,
    tempDir, write;
import std.format : format;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, pathSeparator;
import std.process : environment, execute;
import std.stdio : File;
import std.string : lineSplitter, strip;

import sparkles.test_runner.skip : skipTest;

import app : cli, isFresh, stampName;

/// The tool this environment lacks, or `null` when the whole toolchain is
/// on `PATH`.
private string missingTool()
{
    foreach (tool; ["ldc2-vulkan", "dub", "spirv-val", "spirv-opt", "spirv-dis",
            "spirv-cross", "glslangValidator"])
        if (!environment.get("PATH", "").split(pathSeparator)
                .canFind!(dir => dir.length && dir.buildPath(tool).exists))
            return tool;
    return null;
}

/// The repository, for the fixtures' path dependency on `sparkles:shaders`.
private enum repoRoot = __FILE_FULL_PATH__.dirName.buildNormalizedPath("..", "..", "..");

/**
A scratch dub package with a device configuration, as a consumer has one:
`shaders/` holds the device-only entry modules, and `--out` is `generated/`.
Removed when the fixture goes out of scope.
*/
private struct Fixture
{
    string root, pkg, out_;

    @disable this(this);

    static Fixture create(string stem)
    {
        import std.process : thisProcessID, thisThreadID;

        Fixture f;
        f.root = buildPath(tempDir, format("sparkles-shader-compile-%s-%s-%s", stem,
            thisProcessID, cast(ulong) thisThreadID));
        if (f.root.exists)
            f.root.rmdirRecurse;
        f.pkg = f.root.buildPath("fx");
        f.out_ = f.pkg.buildPath("generated");
        f.pkg.buildPath("src", "fx").mkdirRecurse;
        f.pkg.buildPath("shaders").mkdirRecurse;
        f.pkg.buildPath("dub.sdl").write(format(`name "fx"
dependency "sparkles:shaders" path="%s"
configuration "library" {
    targetType "library"
}
configuration "shaders" {
    targetType "library"
    sourcePaths "src" "shaders"
    dflags "-mdcompute-targets=vulkan-130"
}
`, repoRoot));
        f.pkg.buildPath("src", "fx", "host.d").write("module fx.host;\n");
        return f;
    }

    ~this()
    {
        if (root.length && root.exists)
            root.rmdirRecurse;
    }

    /// Writes `shaders/<name>.d`, a device-only module importing the vocabulary.
    void entries(string name, string body)
    {
        pkg.buildPath("shaders", name ~ ".d").write(
            "@compute(CompileFor.deviceOnly)\nmodule " ~ name ~ ";\n\nimport sparkles.shaders;\n"
            ~ "import ldc.dcompute : ShaderStage;\n\n" ~ body ~ "\n");
    }

    /// Runs the step with `args` after `--package`/`--out`; the exit status
    /// and everything it printed as a diagnostic.
    Outcome run(string[] args...)
    {
        const log = root.buildPath(format("err-%s.txt", logs++));
        auto err = File(log, "w");
        const status = cli(["shader-compile", "--package=" ~ pkg, "--out=" ~ out_, "--quiet"]
            ~ args, err);
        err.close();
        return Outcome(status, log.readText);
    }

    /// The files in `--out`, sorted, temporaries included.
    string[] outputs()
    {
        import std.algorithm : sort;

        if (!out_.exists)
            return null;
        auto names = dirEntries(out_, SpanMode.shallow).map!(e => e.name.baseName).array;
        names.sort;
        return names;
    }

    private size_t logs;
}

private struct Outcome
{
    int status;
    string diagnostics;
}

/// A minimal valid entry point.
private enum tint = `@fragment vec4 tint(@input vec2 uv, Sampler2D texture0, @uniform float amount)
    => texture0.sample(uv) * amount;`;

@("shaderCompile.cli.exitCodes")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // 0: generated, then fresh — and fresh needs no compiler at all (`SHB2`).
    auto f = Fixture.create("exit");
    f.entries("fx_entries", tint);
    const made = f.run();
    assert(made.status == 0, made.diagnostics);
    assert(f.outputs == [stampName, "tint.es.frag", "tint.frag"], f.outputs.to!string);
    assert(isFresh(f.out_, f.pkg));
    const fresh = f.run("--if-stale", "--ldc=/nonexistent/ldc2-vulkan");
    assert(fresh.status == 0 && fresh.diagnostics == "", fresh.diagnostics);

    // 2: usage and configuration errors, each saying what is wrong.
    auto noOut = File(f.root.buildPath("noout.txt"), "w");
    assert(cli(["shader-compile", "--package=" ~ f.pkg], noOut) == 2);
    noOut.close();
    assert(f.root.buildPath("noout.txt").readText.canFind("--out is required"));
    const extra = f.run("stray");
    assert(extra.status == 2 && extra.diagnostics.canFind("unexpected argument `stray`"),
        extra.diagnostics);
    const hostConfig = f.run("--config=library");
    assert(hostConfig.status == 2 && hostConfig.diagnostics.canFind("names no dcompute target"),
        hostConfig.diagnostics);

    // 3: no compiler, and the message says where to get one (`SHP9`).
    const noLdc = f.run("--ldc=/nonexistent/ldc2-vulkan");
    assert(noLdc.status == 3 && noLdc.diagnostics.canFind("nix develop"), noLdc.diagnostics);

    // 1: a compile error, reported with the compiler's own message.
    f.entries("fx_entries", `@fragment vec4 tint(@input vec2 uv) => undefinedThing(uv);`);
    const broken = f.run();
    assert(broken.status == 1 && broken.diagnostics.canFind("undefinedThing")
        && broken.diagnostics.canFind("LDC failed"), broken.diagnostics);

    // 1: a package with no device-only module has no entry point to compile.
    f.pkg.buildPath("shaders", "fx_entries.d").remove;
    const none = f.run();
    assert(none.status == 1 && none.diagnostics.canFind("CompileFor.deviceOnly"),
        none.diagnostics);
}

@("shaderCompile.cli.stockCompilerIsAToolchainError")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");
    if (!environment.get("PATH", "").split(pathSeparator)
            .canFind!(dir => dir.length && dir.buildPath("ldc2").exists))
        return skipTest("no stock `ldc2` on PATH to stand in for a wrong compiler");

    // An LDC without the Vulkan target or the fragment stage is a toolchain
    // problem (3), not a broken shader (1) — `SHP10`.
    auto f = Fixture.create("stock");
    f.entries("fx_entries", tint);
    const stock = f.run("--ldc=ldc2");
    assert(stock.status == 3 && stock.diagnostics.canFind("not a dcompute-enabled LDC"),
        stock.diagnostics);
}

@("shaderCompile.cli.aFailedValidationWritesNothing")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHP4`: SPIR-V the validator rejects stops the step, and the output a
    // previous run left stays exactly as it was — its stamp still vouches for
    // it. The shape below is one the pinned SPIR-V backend structures wrongly
    // (#618); once a compiler fix lands, it needs another invalid input.
    auto f = Fixture.create("invalid");
    f.entries("fx_entries", tint);
    assert(f.run().status == 0);
    const before = f.outputs;
    const stamp = f.out_.buildPath(stampName).readText;

    f.entries("fx_entries", `@fragment vec4 seam(@input vec2 uv, @uniform float a, @uniform float b)
{
    float c = 1.0f;
    if (a > 0.0f)
    {
        if (uv.y < 2.5f)
            c = c * a;
        else if (uv.y >= 3.0f && uv.y < 6.0f)
            c = c + b;
    }
    return v4(c);
}`);
    const rejected = f.run();
    assert(rejected.status == 1 && rejected.diagnostics.canFind("spirv-val failed"),
        rejected.diagnostics);
    assert(f.outputs == before, f.outputs.to!string);
    assert(f.out_.buildPath(stampName).readText == stamp);
}

@("shaderCompile.cli.interfaceContractIsEnforced")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    auto f = Fixture.create("iface");
    // `SHF5`: the compiler accepts each of these; the step must not.
    foreach (bad; [
        `@fragment vec4 e(@input vec3 colour) => v4(colour.x);`,
        `@fragment vec3 e(@input vec2 uv) => v3(uv.x);`,
        `struct Pair { float a, b; }
@fragment vec4 e(@uniform Pair pair) => v4(pair.a);`,
        `@fragment vec4 e(@uniform float[2] weights) => v4(weights[0]);`,
    ])
    {
        f.entries("fx_entries", bad);
        const r = f.run();
        assert(r.status == 1 && r.diagnostics.canFind("(SHF5)"), bad ~ "\n" ~ r.diagnostics);
    }
    // The diagnostic names the parameter.
    f.entries("fx_entries", `@fragment vec4 e(@input vec3 colour) => v4(colour.x);`);
    assert(f.run().diagnostics.canFind("`colour` crosses the shader interface as vec3"));

    // `SHF2`: an unmarked parameter is the compiler's to reject, naming it.
    f.entries("fx_entries", `@fragment vec4 e(vec2 plain) => v4(plain.x);`);
    const unmarked = f.run();
    assert(unmarked.status == 1 && unmarked.diagnostics.canFind("parameter `plain`"),
        unmarked.diagnostics);

    // `SHF7`: a stage other than `@fragment`, named in the diagnostic.
    f.entries("fx_entries",
        `@(typeof(fragment)(cast(ShaderStage) 1)) vec4 e(@input vec2 uv) => v4(uv.x);`);
    const stage = f.run();
    assert(stage.status == 1 && stage.diagnostics.canFind("unsupported shader stage 1"),
        stage.diagnostics);
}

@("shaderCompile.cli.staleOutputGoesAndConcurrentRunsAgree")
@system unittest
{
    import core.thread : Thread;

    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHP8`: the directory belongs to the step — a file no entry point
    // produces goes, and no temporary is left behind.
    auto f = Fixture.create("atomic");
    f.entries("fx_entries", tint);
    f.out_.mkdirRecurse;
    f.out_.buildPath("renamed.frag").write("// an entry point that no longer exists\n");
    f.out_.buildPath("renamed.es.frag").write("// likewise\n");
    assert(f.run().status == 0);
    assert(f.outputs == [stampName, "tint.es.frag", "tint.frag"], f.outputs.to!string);
    const expected = f.out_.buildPath("tint.frag").readText;

    // Several builds of dependents run the step at once on one directory
    // (`SHB7`): every run succeeds, and what is left is complete — the files
    // a single run writes, and a stamp that vouches for them.
    int[4] status;
    Thread[4] threads;
    foreach (i; 0 .. threads.length)
    {
        const n = i;
        threads[n] = new Thread(() {
            auto err = File(f.root.buildPath(format("concurrent-%s.txt", n)), "w");
            status[n] = cli(["shader-compile", "--package=" ~ f.pkg, "--out=" ~ f.out_,
                "--quiet"], err);
        });
        threads[n].start();
    }
    foreach (t; threads)
        t.join();
    foreach (i, s; status)
        assert(s == 0, f.root.buildPath(format("concurrent-%s.txt", i)).readText);
    assert(f.outputs == [stampName, "tint.es.frag", "tint.frag"], f.outputs.to!string);
    assert(f.out_.buildPath("tint.frag").readText == expected);
    assert(isFresh(f.out_, f.pkg));
}

/// The compiler's module for `body`, disassembled (`spirv-dis`, friendly names).
private string disassemble(ref Fixture f, string body)
{
    f.entries("probe", body);
    const dir = f.root.buildPath("spv");
    dir.mkdirRecurse;
    const compiled = execute(["ldc2-vulkan", "-O2", "-c", "-m64", "-mdcompute-targets=vulkan-130",
        "-mdcompute-file-prefix=probe", "-od=" ~ dir, "-I" ~ repoRoot.buildPath("libs", "shaders", "src"),
        f.pkg.buildPath("shaders", "probe.d")]);
    assert(compiled.status == 0, compiled.output);
    const dis = execute(["spirv-dis", dir.buildPath("probe_vulkan130_64.spv")]);
    assert(dis.status == 0, dis.output);
    return dis.output;
}

/// `OpDecorate %<name> <decoration> <value>` → value, keyed "name decoration".
private string[string] decorations(string dis)
{
    string[string] d;
    foreach (line; dis.lineSplitter)
    {
        const w = line.strip.split;
        if (w.length == 4 && w[0] == "OpDecorate")
            d[w[1][1 .. $] ~ " " ~ w[2]] = w[3];
    }
    return d;
}

/// The storage class and pointee type of the variable `%name`.
private string[2] variable(string dis, string name)
{
    string[string] types;
    string[2] v;
    string ptrType;
    foreach (line; dis.lineSplitter)
    {
        const w = line.strip.split;
        if (w.length >= 4 && w[1] == "=" && w[2] == "OpTypePointer")
            types[w[0]] = w[4];
        if (w.length >= 5 && w[0] == "%" ~ name && w[2] == "OpVariable")
        {
            ptrType = w[3];
            v[0] = w[4];
        }
    }
    v[1] = types.get(ptrType, null);
    return v;
}

/// The instructions of the function `%name`, from `OpFunction` to `OpFunctionEnd`.
private string functionBody(string dis, string name)
{
    string body;
    bool inside;
    foreach (line; dis.lineSplitter)
    {
        const l = line.strip;
        if (l.startsWith("%" ~ name ~ " = OpFunction "))
            inside = true;
        if (inside)
            body ~= l ~ "\n";
        if (inside && l == "OpFunctionEnd")
            break;
    }
    return body;
}

@("shaderCompile.fragment.interfaceFromTheSignature")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHF1`–`SHF3`, `SHF6`, read off the module the compiler emits for an
    // entry whose parameters interleave every kind.
    auto f = Fixture.create("abi");
    const dis = disassemble(f, `@fragment vec4 interleaved(@input vec2 first, Sampler2D texA,
    @uniform float scale, @input vec4 second, Sampler2D texB, @uniform vec2 offset)
    => texA.sample(first) * texB.sample(second.xy + offset) * scale;

@fragment void silent(@input vec2 uv) {}`);
    const d = decorations(dis);

    // SHF1: an entry point named after the D function, in the fragment stage.
    assert(dis.canFind(`OpEntryPoint Fragment %interleaved "interleaved"`), dis);
    assert(dis.canFind(`OpEntryPoint Fragment %silent "silent"`), dis);

    // SHF2: inputs at locations in the order the @input parameters appear…
    assert(d.get("first Location", null) == "0" && d.get("second Location", null) == "1", d.to!string);
    assert(variable(dis, "first")[0] == "Input" && variable(dis, "second")[0] == "Input");
    // …images at bindings from 1 in parameter order, in set 0, read through
    // one sampler at binding 0…
    assert(d.get("texA Binding", null) == "1" && d.get("texB Binding", null) == "2", d.to!string);
    assert(d.get("texA DescriptorSet", null) == "0" && d.get("texB DescriptorSet", null) == "0");
    const samplers = dis.lineSplitter.filter!(l => l.canFind("OpTypeSampler")).array;
    assert(samplers.length == 1, samplers.to!string);
    const samplerVar = dis.lineSplitter
        .filter!(l => l.canFind("= OpVariable") && l.canFind("_ptr_UniformConstant_") && l.canFind("ampler"))
        .map!(l => l.strip.split[0][1 .. $]).array;
    assert(samplerVar.length == 1, samplerVar.to!string);
    assert(d.get(samplerVar[0] ~ " Binding", null) == "0"
        && d.get(samplerVar[0] ~ " DescriptorSet", null) == "0", d.to!string);
    // …and plain uniforms named after the parameter, outside any block.
    assert(variable(dis, "scale") == ["UniformConstant", "%float"], variable(dis, "scale").to!string);
    assert(variable(dis, "offset") == ["UniformConstant", "%v2float"], variable(dis, "offset").to!string);

    // SHF3: the return value goes to `finalColor` at location 0; a void
    // entry point writes none. (Every entry lists every interface variable,
    // which SPIR-V allows, so what tells is the stores in each function.)
    assert(d.get("finalColor Location", null) == "0", d.to!string);
    assert(variable(dis, "finalColor") == ["Output", "%v4float"]);
    assert(functionBody(dis, "interleaved").canFind("OpStore %finalColor"),
        functionBody(dis, "interleaved"));
    assert(!functionBody(dis, "silent").canFind("%finalColor"), functionBody(dis, "silent"));

    // SHF6: no handle inside an aggregate or function-local memory.
    import app : interfaceViolations;

    assert(interfaceViolations(dis) == [], interfaceViolations(dis).to!string);
}
