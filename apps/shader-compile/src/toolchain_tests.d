/**
The build step as its users run it: the built tool, as a process, on a copy of
`tests/fixture/` (a consumer package with a device configuration), against the
real device compiler, dub, and the SPIR-V and GLSL tools.

These are the tests a fake cannot stand in for — what the compiler puts across
the interface (`SHF1`–`SHF3`, `SHF5`–`SHF7`), and what the step does with each
outcome (`SHP1`, `SHP4`, `SHP6`, `SHP8`–`SHP10`). Each one skips where the
toolchain is absent (the Windows test leg has no device compiler, `SHT4`);
every other test leg carries it in its shell.
*/
module toolchain_tests;

version (unittest):

import std.algorithm : canFind, filter, map, sort, startsWith;
import std.range : walkLength;
import std.array : array, join, replace, split;
import std.concurrency : initOnce;
import std.conv : octal, to;
import std.file : copy, dirEntries, exists, mkdirRecurse, readText, remove, rmdirRecurse,
    setAttributes, SpanMode, tempDir, write;
import std.format : format;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, pathSeparator,
    relativePath;
import std.process : Config, environment, execute, Pid, spawnProcess, thisProcessID, wait;
import std.stdio : File;
import std.string : indexOf, lineSplitter, strip;

import sparkles.test_runner.skip : skipTest;

import app : isFresh, parseDescribe, stampName, unitOf, withoutHostFlags;

/// The tools the step runs, the device compiler first.
private immutable toolchain = ["ldc2-vulkan", "dub", "spirv-val", "spirv-opt", "spirv-dis",
    "spirv-as", "spirv-cross", "glslangValidator"];

/// Where `tool` is on `PATH`, or `null`.
private string onPath(string tool)
{
    foreach (dir; environment.get("PATH", "").split(pathSeparator))
        if (dir.length && dir.buildPath(tool).exists)
            return dir.buildPath(tool);
    return null;
}

/// The tool this environment lacks, or `null` when the whole toolchain is
/// on `PATH`.
private string missingTool()
{
    foreach (tool; toolchain)
        if (!onPath(tool))
            return tool;
    return null;
}

/// This package, and the repository its fixture depends on.
private enum here = __FILE_FULL_PATH__.dirName.buildNormalizedPath("..");
private enum repoRoot = here.buildNormalizedPath("..", "..");

/// The tool, built once per test run.
private string tool()
{
    static string build()
    {
        const r = execute(["dub", "build", "-q", "--root=" ~ here, "--config=application"]);
        assert(r.status == 0, r.output);
        return here.buildPath("build", "shader-compile");
    }

    static shared string path;
    return initOnce!path(build());
}

/**
A scratch copy of `tests/fixture/`, whose `--out` is `generated/`. Removed when
the fixture goes out of scope.
*/
private struct Fixture
{
    string root, pkg, out_;
    string[string] env; /// overrides of the tool's environment

    @disable this(this);

    static Fixture create(string stem)
    {
        Fixture f;
        f.root = buildPath(tempDir, format("sparkles-shader-compile-%s-%s", stem, thisProcessID));
        if (f.root.exists)
            f.root.rmdirRecurse;
        f.pkg = f.root.buildPath("fx");
        f.out_ = f.pkg.buildPath("generated");
        copyFixture(f.pkg);
        return f;
    }

    ~this()
    {
        if (root.length && root.exists)
            root.rmdirRecurse;
    }

    /// Replaces the device-only module's entry points with `body`.
    void entries(string body)
    {
        pkg.buildPath("shaders", "fx_entries.d").write(
            "@compute(CompileFor.deviceOnly)\nmodule fx_entries;\n\nimport sparkles.shaders;\n"
            ~ "import ldc.dcompute : ShaderStage;\n\n" ~ body ~ "\n");
    }

    /// Adds a configuration to the recipe: `name`, its `body`.
    void configuration(string name, string body)
    {
        const recipe = pkg.buildPath("dub.sdl");
        recipe.write(recipe.readText ~ format("configuration \"%s\" {\n%s\n}\n", name, body));
    }

    /// Runs the tool with `args` after `--package`/`--out`.
    Outcome run(string[] args...)
    {
        const r = execute([tool, "--package=" ~ pkg, "--out=" ~ out_, "--quiet"] ~ args, env);
        return Outcome(r.status, r.output);
    }

    /// The files in `--out`, sorted, temporaries included.
    string[] outputs()
    {
        if (!out_.exists)
            return null;
        auto names = dirEntries(out_, SpanMode.shallow).map!(e => e.name.baseName).array;
        names.sort;
        return names;
    }
}

/// Copies `tests/fixture/` to `dest`, its dependency pointed at the checkout.
private void copyFixture(string dest)
{
    const src = here.buildPath("tests", "fixture");
    foreach (e; dirEntries(src, SpanMode.depth).filter!(e => e.isFile))
    {
        const to = dest.buildPath(e.name.relativePath(src));
        to.dirName.mkdirRecurse;
        e.name.copy(to);
    }
    // The fixture's dependency, relative to where it is checked in, points
    // at the checkout instead.
    foreach (file; ["dub.sdl", "dub.selections.json"])
    {
        const path = dest.buildPath(file);
        const before = path.readText;
        const after = before.replace(`"../../../..`, `"` ~ repoRoot);
        assert(after != before, file ~ " no longer names the checkout as ../../../..");
        path.write(after);
    }
}

private struct Outcome
{
    int status;
    string diagnostics;
}

@("shaderCompile.cli.exitCodes")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // 0: generated, then fresh — and fresh needs no compiler at all (`SHB2`).
    auto f = Fixture.create("exit");
    const made = f.run();
    assert(made.status == 0, made.diagnostics);
    assert(f.outputs == [stampName, "tint.es.frag", "tint.frag"], f.outputs.to!string);
    assert(isFresh(f.out_, f.pkg));
    const fresh = f.run("--if-stale", "--ldc=/nonexistent/ldc2-vulkan");
    assert(fresh.status == 0 && fresh.diagnostics == "", fresh.diagnostics);

    // 2: a configuration that is not a device build, each saying why.
    f.configuration("twoTargets", `sourcePaths "src" "shaders"
dflags "-mdcompute-targets=vulkan-130,ocl-300"`);
    f.configuration("hostOnly", `sourcePaths "src"
dflags "-mdcompute-targets=vulkan-130"`);
    f.configuration("sourceLibrary", `targetType "sourceLibrary"
sourcePaths "src" "shaders"
dflags "-mdcompute-targets=vulkan-130"`);
    f.configuration("badVersion", `sourcePaths "src" "shaders"
dflags "-mdcompute-targets=vulkan-999"`);
    foreach (bad; [
        ["stray", "unexpected argument `stray`"],
        ["--config=badVersion", "not `vulkan-999`"],
        ["--config=nope", "failed in"],
        ["--config=library", "names no dcompute target"],
        ["--config=sourceLibrary", "describes no build target"],
        ["--config=twoTargets", "must name exactly one Vulkan target"],
        ["--config=hostOnly", "declares no `@fragment` or `@vertex` entry point"],
    ])
    {
        const r = f.run(bad[0]);
        assert(r.status == 2 && r.diagnostics.canFind(bad[1]), bad[0] ~ "\n" ~ r.diagnostics);
    }

    // 3: no compiler, and the message says where to get one (`SHP9`) — even
    // with a configuration error too, since describing needs the compiler.
    foreach (args; [["--ldc=/nonexistent/ldc2-vulkan"], ["--ldc=/nonexistent/ldc2-vulkan", "--config=nope"]])
    {
        const noLdc = f.run(args);
        assert(noLdc.status == 3 && noLdc.diagnostics.canFind("nix develop"), noLdc.diagnostics);
    }

    // 3 for each other tool the step runs, named: here `spirv-cross`, on a
    // `PATH` that holds every tool but it.
    version (Posix)
    {
        import std.file : symlink;

        const bin = f.root.buildPath("bin");
        bin.mkdirRecurse;
        foreach (t; toolchain.filter!(t => t != "spirv-cross"))
            symlink(onPath(t), bin.buildPath(t));
        f.env["PATH"] = bin;
        const noCross = f.run();
        f.env.remove("PATH");
        assert(noCross.status == 3 && noCross.diagnostics.canFind("`spirv-cross` is not on PATH")
            && noCross.diagnostics.canFind("nix develop"), noCross.diagnostics);
    }

    // 1: a compile error, reported with the compiler's own message.
    f.entries(`@fragment vec4 tint(@input vec2 uv) => undefinedThing(uv);`);
    const broken = f.run();
    assert(broken.status == 1 && broken.diagnostics.canFind("undefinedThing")
        && broken.diagnostics.canFind("LDC failed"), broken.diagnostics);
}

@("shaderCompile.cli.outputIsTheSameInAnyDirectory")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHT3`: the same package in two directories, of different lengths,
    // generates the same GLSL; only the stamp, which records paths, may differ.
    auto a = Fixture.create("dir");
    auto b = Fixture.create("a-longer-directory");
    foreach (ref fx; [&a, &b])
    {
        const r = fx.run();
        assert(r.status == 0, r.diagnostics);
    }
    assert(a.outputs == b.outputs, b.outputs.to!string);
    foreach (name; a.outputs.filter!(n => n != stampName))
        assert(a.out_.buildPath(name).readText == b.out_.buildPath(name).readText, name);
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
    // problem (3), not a broken shader (1) — `SHP10` — told by what it cannot
    // compile, not by what it says about the unit.
    auto f = Fixture.create("stock");
    const stock = f.run("--ldc=ldc2");
    assert(stock.status == 3 && stock.diagnostics.canFind("cannot compile a `@fragment` shader"),
        stock.diagnostics);
}

/// Runs a good build, breaks the input with `breakIt`, and runs again with
/// `args`: the second run must stop with `expected` and leave the good one's
/// output exactly as it was — its stamp still vouches for it.
private void assertFailureWritesNothing(ref Fixture f, string expected,
    scope void delegate() breakIt, string[] args...)
{
    assert(f.run().status == 0);
    const before = f.outputs;
    const stamp = f.out_.buildPath(stampName).readText;
    const glsl = f.out_.buildPath("tint.frag").readText;

    breakIt();
    const rejected = f.run(args);
    assert(rejected.status == 1 && rejected.diagnostics.canFind(expected), rejected.diagnostics);
    assert(f.outputs == before, f.outputs.to!string);
    assert(f.out_.buildPath(stampName).readText == stamp);
    assert(f.out_.buildPath("tint.frag").readText == glsl);
}

@("shaderCompile.cli.aFailedValidationWritesNothing")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHP4`: SPIR-V the validator rejects stops the step. The compiler is
    // wrapped to append a malformed instruction to the unit's module.
    auto f = Fixture.create("invalid");
    const wrapper = f.root.buildPath("ldc-emitting-junk");
    wrapper.write(`#!/bin/sh
ldc2-vulkan "$@" || exit $?
for a in "$@"; do case "$a" in -od=*) od="${a#-od=}";; esac; done
for m in "$od"/unit_*.spv; do [ -f "$m" ] && printf '\377\377\377\377' >> "$m"; done
exit 0
`);
    wrapper.setAttributes(octal!755);
    assertFailureWritesNothing(f, "spirv-val failed", () {}, "--ldc=" ~ wrapper);
}

@("shaderCompile.cli.aRejectedTranslationWritesNothing")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHP6`: a file glslang rejects stops the step. A stand-in for
    // `glslangValidator`, first on `PATH`, rejects every file.
    auto f = Fixture.create("glslang");
    const bin = f.root.buildPath("rejecting-glslang");
    bin.mkdirRecurse;
    bin.buildPath("glslangValidator").write("#!/bin/sh\necho 'ERROR: rejected by the test' >&2\nexit 2\n");
    bin.buildPath("glslangValidator").setAttributes(octal!755);
    assertFailureWritesNothing(f, "glslang failed",
        () { f.env["PATH"] = bin ~ pathSeparator ~ environment.get("PATH", ""); });
}

@("shaderCompile.cli.interfaceContractIsEnforced")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    auto f = Fixture.create("iface");
    // `SHF5`: what GLSL cannot declare at that end of the interface is the
    // compiler's to reject, naming the parameter and the reason.
    foreach (bad; [
        [`@fragment vec4 e(@input int n) => v4(cast(float) n);`, "parameter `n` cannot be `int`"],
        [`@fragment vec4 e(@uniform uint n) => v4(cast(float) n);`, "has no unsigned integers"],
        [`@fragment vec4 e(@input float[2] w) => v4(w[0]);`, "only a `@uniform` can be an array"],
        [`@fragment vec3 e(@input vec3 c) => c;`, "the output is a vector of four `float`s"],
        // `SHF6`: a handle never sits inside a uniform.
        [`struct Pair { Sampler2D t; }
@fragment vec4 e(@uniform Pair p) => v4(1.0f);`, "parameter `p` cannot be `Pair`"],
        // `SHF2`: exactly one marker, and a name the translation keeps.
        [`@fragment vec4 e(@input @uniform vec2 uv) => v4(uv.x);`, "marked both `@input` and `@uniform`"],
        [`@fragment vec4 e(@uniform Sampler2D t) => t.sample(v2(0.5f));`, "which takes no `@input` or `@uniform` marker"],
        [`@fragment vec4 e(@uniform float smooth) => v4(smooth);`, "`smooth` cannot keep its name in GLSL"],
        [`@fragment vec4 e(@uniform float gl_x) => v4(gl_x);`, "`gl_` prefix"],
        [`@fragment vec4 e(@uniform float spvGain) => v4(spvGain);`, "`spv` prefix"],
        [`@fragment vec4 e(@uniform float a__b) => v4(a__b);`, "run of underscores"],
        [`struct Light { float filter; }
@fragment vec4 e(@uniform Light light) => v4(light.filter);`, "uniform struct field `filter`"],
        // `SHF2`: one variable per name, so one type per name.
        [`@fragment vec4 e(@uniform float scale) => v4(scale);
@fragment vec4 g(@uniform vec2 scale) => v4(scale.x);`, "is `__vector(float[2])` in `g` but `float` in `e`"],
    ])
    {
        f.entries(bad[0]);
        const r = f.run();
        assert(r.status == 1 && r.diagnostics.canFind(bad[1]), bad[0] ~ "\n" ~ r.diagnostics);
        assert(!f.out_.exists, "nothing is written");
    }

    // `SHF2`: an interface name is one variable across the unit, so two
    // entries that give it different ordinals fail, naming both entries.
    f.entries(`@fragment vec4 first(@input vec4 fragColor, Sampler2D texB)
    => texB.sample(v2(0.5f)) * fragColor;
@fragment vec4 second(@input vec2 fragTexCoord, @input vec4 fragColor, Sampler2D texA, Sampler2D texB)
    => texA.sample(fragTexCoord) * texB.sample(fragTexCoord) * fragColor;`);
    const clash = f.run();
    assert(clash.status == 1 && clash.diagnostics.canFind(
        "shader input `fragColor` is at location 1 in `second` but location 0 in `first`"),
        clash.diagnostics);

    // `SHF1`: an entry point's name is unique across the unit, so a second
    // module defining `tint` fails, naming both definitions.
    f.entries(`@fragment vec4 tint(@input vec4 c) => c;`);
    f.pkg.buildPath("shaders", "fx_more.d").write("@compute(CompileFor.deviceOnly)\nmodule fx_more;\n\n"
        ~ "import sparkles.shaders;\n\n@fragment vec4 tint(@input vec4 c) => c;\n");
    const twice = f.run();
    assert(twice.status == 1 && twice.diagnostics.canFind("entry point `tint` is defined by both")
        && twice.diagnostics.canFind("`fx_entries.tint`") && twice.diagnostics.canFind("`fx_more.tint`"),
        twice.diagnostics);
    remove(f.pkg.buildPath("shaders", "fx_more.d"));

    // `SHF2`: an unmarked parameter is the compiler's to reject, naming it.
    f.entries(`@fragment vec4 e(vec2 plain) => v4(plain.x);`);
    const unmarked = f.run();
    assert(unmarked.status == 1 && unmarked.diagnostics.canFind("parameter `plain`"),
        unmarked.diagnostics);

    // `SHF7`: a stage other than `@fragment` and `@vertex`, named in the
    // diagnostic.
    f.entries(`@(typeof(fragment)(cast(ShaderStage) 7)) vec4 e(@input vec2 uv) => v4(uv.x);`);
    const stage = f.run();
    assert(stage.status == 1 && stage.diagnostics.canFind("unsupported shader stage 7"),
        stage.diagnostics);
}

@("shaderCompile.cli.staleOutputGoesAndConcurrentRunsAgree")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHP8`: the directory belongs to the step — a file no entry point
    // produces goes, and no temporary is left behind.
    auto f = Fixture.create("atomic");
    f.out_.mkdirRecurse;
    f.out_.buildPath("renamed.frag").write("// an entry point that no longer exists\n");
    f.out_.buildPath("renamed.es.frag").write("// likewise\n");
    // A killed run's temporary goes; a live run's is about to be renamed.
    f.out_.buildPath("tint.frag.tmp-2147483646").write("// a run that died\n");
    const live = format("tint.frag.tmp-%s", thisProcessID);
    f.out_.buildPath(live).write("// a run still writing\n");
    f.out_.buildPath("notes.tmp-old").write("// not a temporary of the step's\n");
    assert(f.run().status == 0);
    assert(f.outputs == [stampName, "notes.tmp-old", "tint.es.frag", "tint.frag", live],
        f.outputs.to!string);
    remove(f.out_.buildPath(live));
    remove(f.out_.buildPath("notes.tmp-old"));
    const expected = f.out_.buildPath("tint.frag").readText;

    // The builds of several dependents run the step at once on one directory
    // (`SHB7`), each in its own process: every run succeeds, and what is left
    // is complete — the files a single run writes, and a stamp that vouches
    // for them.
    Pid[4] runs;
    foreach (i, ref p; runs)
        p = spawnProcess([tool, "--package=" ~ f.pkg, "--out=" ~ f.out_, "--quiet"],
            File("/dev/null"), File("/dev/null", "w"),
            File(f.root.buildPath(format("concurrent-%s.txt", i)), "w"));
    foreach (i, p; runs)
        assert(p.wait == 0, f.root.buildPath(format("concurrent-%s.txt", i)).readText);
    assert(f.outputs == [stampName, "tint.es.frag", "tint.frag"], f.outputs.to!string);
    assert(f.out_.buildPath("tint.frag").readText == expected);
    assert(isFresh(f.out_, f.pkg));
}

@("shaderCompile.fragment.interfaceFromTheSignature")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHF1`–`SHF3`: an entry whose parameters interleave every kind, and a
    // `void` one, against the GLSL they must produce — entry points named
    // after the D functions, inputs and plain uniforms named after the
    // parameters, `finalColor` at location 0, and no output for `void`. After a deliberate change, regenerate with
    // `SPARKLES_UPDATE_GOLDEN=1` and review the diff.
    auto f = Fixture.create("abi");
    f.entries(`@fragment vec4 interleaved(@input vec2 first, Sampler2D texA,
    @uniform float scale, @input vec4 second, Sampler2D texB, @uniform vec2 offset)
    => texA.sample(first) * texB.sample(second.xy + offset) * scale;

@fragment void silent(@input vec2 uv) {}`);
    const made = f.run("--keep");
    assert(made.status == 0, made.diagnostics);

    const golden = here.buildPath("tests", "golden");
    foreach (file; ["interleaved.frag", "interleaved.es.frag", "silent.frag"])
    {
        const got = f.out_.buildPath(file).readText;
        if (environment.get("SPARKLES_UPDATE_GOLDEN") == "1")
            golden.buildPath(file).write(got);
        assert(got == golden.buildPath(file).readText, file ~ " differs from tests/golden:\n" ~ got);
    }

    // What GLSL 3.30 does not spell: inputs at locations in parameter order,
    // and images at bindings from 1, read through one sampler at binding 0.
    const kept = made.diagnostics.lineSplitter
        .filter!(l => l.startsWith("shader-compile: scratch kept at ")).array;
    assert(kept.length == 1, made.diagnostics);
    const scratch = kept[0]["shader-compile: scratch kept at ".length .. $].strip;
    scope (exit) scratch.rmdirRecurse;
    const dis = execute(["spirv-dis", scratch.buildPath("gl330", "unit_vulkan130_64.spv")]);
    assert(dis.status == 0, dis.output);
    foreach (decoration; ["OpDecorate %first Location 0", "OpDecorate %second Location 1",
            "OpDecorate %texA Binding 1", "OpDecorate %texB Binding 2",
            "OpDecorate %sampler Binding 0"])
        assert(dis.output.canFind(decoration), decoration ~ "\n" ~ dis.output);
}

@("shaderCompile.vertex.vulkanTriangle")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // A vertex and a fragment entry point for `vulkan1.3` (`SHF1`, `SHF3`,
    // `SHF8`, `SHC4`, `SHP5`, `SHP7`): one SPIR-V module per entry point, each
    // with that entry point alone and its provenance, valid for Vulkan 1.3,
    // and no GLSL, since no OpenGL profile lists them. The table is indexed
    // by an `int`, which declares no `Int64` (`SHM6`).
    auto f = Fixture.create("vertex");
    f.entries(q{
        struct Varyings
        {
            @builtin(Builtin.position) vec4 position;
            vec4 colour;
        }

        @profiles(vulkan13) @vertex Varyings tri(@builtin(Builtin.vertexIndex) int index)
        {
            vec2[3] corner;
            corner[0] = v2(-0.5f, 0.5f);
            corner[1] = v2(0.5f, 0.5f);
            corner[2] = v2(0.0f, -0.5f);
            Varyings v;
            v.position = v4(corner[index][0], corner[index][1], 0.0f, 1.0f);
            v.colour = v4(1.0f, cast(float) index, 0.0f, 1.0f);
            return v;
        }

        @profiles(vulkan13) @fragment vec4 shade(@input vec4 colour) => colour;

        static assert(stagesLink!(tri, shade));
    });
    const made = f.run();
    assert(made.status == 0, made.diagnostics);
    assert(f.outputs == [".stamp", "shade.frag.spv", "tri.vert.spv"], f.outputs.join(" "));
    foreach (file, stage; ["tri.vert.spv": "Vertex", "shade.frag.spv": "Fragment"])
    {
        const path = f.out_.buildPath(file);
        const val = execute(["spirv-val", "--target-env", "vulkan1.3", path]);
        assert(val.status == 0, file ~ ": " ~ val.output);
        const dis = execute(["spirv-dis", path]);
        assert(dis.status == 0, dis.output);
        assert(dis.output.lineSplitter.filter!(l => l.strip.startsWith("OpEntryPoint ")).walkLength == 1,
            file ~ " has more than one entry point:\n" ~ dis.output);
        assert(dis.output.canFind("OpEntryPoint " ~ stage ~ " "), dis.output);
        assert(dis.output.canFind(`OpModuleProcessed "Generated by shader-compile from fx's ` ~
            "shaders/fx_entries.d (entry point `" ~ file[0 .. file.indexOf('.')] ~ "`).\""),
            dis.output);
        assert(!dis.output.canFind("Int64"), file ~ " declares Int64:\n" ~ dis.output);
    }
}

@("shaderCompile.vertex.withoutAProfileFails")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // No OpenGL profile offers the vertex stage, so a vertex entry point
    // without `@profiles` has none, and fails (`SHC4`); nothing is written.
    auto f = Fixture.create("noprofile");
    f.entries(q{
        struct V { @builtin(Builtin.position) vec4 position; }
        @vertex V tri() { V v; return v; }
    });
    const made = f.run();
    assert(made.status == 1, made.diagnostics);
    assert(made.diagnostics.canFind("declares no profiles"), made.diagnostics);
    assert(f.outputs.length == 0, f.outputs.join(" "));

    // Naming one that does not offer the stage fails too, naming the entry
    // point and the profile (`SHF7`).
    auto g = Fixture.create("glvertex");
    g.entries(q{
        struct V { @builtin(Builtin.position) vec4 position; }
        @profiles(gl330) @vertex V tri() { V v; return v; }
    });
    const gl = g.run();
    assert(gl.status == 1, gl.diagnostics);
    assert(gl.diagnostics.canFind("entry point `tri` is a vertex shader, which the profile `gl330` " ~
        "does not offer"), gl.diagnostics);
    assert(g.outputs.length == 0, g.outputs.join(" "));
}

@("shaderCompile.cli.anInputEditedDuringTheRunLeavesItStale")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHB1`: the stamp records the inputs as the compiler read them, so an
    // edit landing while the run is under way leaves output its stamp does
    // not vouch for. The compiler is wrapped to make that edit right after
    // it compiles the unit.
    auto f = Fixture.create("edited");
    const module_ = f.pkg.buildPath("shaders", "fx_entries.d");
    const wrapper = f.root.buildPath("ldc-then-edit");
    wrapper.write(format(`#!/bin/sh
ldc2-vulkan "$@" || exit $?
case "$*" in *-mdcompute-file-prefix=unit*) echo '// edited during the run' >> '%s';; esac
exit 0
`, module_));
    wrapper.setAttributes(octal!755);
    const r = f.run("--ldc=" ~ wrapper);
    assert(r.status == 0, r.diagnostics);
    assert(module_.readText.canFind("edited during the run"));
    assert(!isFresh(f.out_, f.pkg), "the stamp vouches for the edit the output never saw");
}

@("shaderCompile.unitOf.repositoryUiAsDubDescribesIt")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHP3`: the unit of the repository's own consumer, as the step reads
    // it — every `@compute` module among the device configuration's sources, the
    // package's and its dependencies', and no other; one of them device-only.
    const described = execute(["dub", "describe", "--root=" ~ repoRoot.buildPath("libs", "ui"),
        "--config=shaders", "--compiler=ldc2-vulkan"], withoutHostFlags(environment.toAA),
        Config.newEnv);
    assert(described.status == 0, described.output);
    const unit = unitOf(parseDescribe(described.output));
    string rel(string p) => p.relativePath(repoRoot);
    assert(unit.deviceOnly.map!rel.array == ["libs/ui/shaders/effects.d"], unit.deviceOnly.to!string);
    auto sources = unit.sources.map!rel.array;
    sources.sort;
    assert(sources == ["libs/shaders/src/sparkles/shaders/capabilities.d",
        "libs/shaders/src/sparkles/shaders/fragment.d",
        "libs/shaders/src/sparkles/shaders/math.d",
        "libs/shaders/src/sparkles/shaders/types.d",
        "libs/ui/shaders/effects.d",
        "libs/ui/src/sparkles/ui/crt_shaders.d",
        "libs/ui/src/sparkles/ui/effect_shaders.d"], sources.to!string);
}

@("shaderCompile.fragment.whatMayCrossIsDeclared")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHF5`, the accepted side: a `vec3` input, an integer-vector uniform
    // and an array uniform reach both dialects declared as their D types say.
    auto f = Fixture.create("cross");
    f.entries(`@fragment vec4 cross(@input vec3 colour, @uniform __vector(int[2]) cell,
    @uniform float[2] weights) => v4(colour.x * weights[1] + cast(float) cell[0]);`);
    const made = f.run();
    assert(made.status == 0, made.diagnostics);
    const desktop = f.out_.buildPath("cross.frag").readText;
    foreach (decl; ["in vec3 colour;", "uniform ivec2 cell;", "uniform float weights[2];"])
        assert(desktop.canFind(decl), decl ~ "\n" ~ desktop);
    const es = f.out_.buildPath("cross.es.frag").readText;
    foreach (decl; ["varying highp vec3 colour;", "uniform ivec2 cell;", "uniform highp float weights[2];"])
        assert(es.canFind(decl), decl ~ "\n" ~ es);
}

@("shaderCompile.manifest.anEntryPointMayNotDependOnTheProfile")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // The manifest lists the entry points before any profile is active, so
    // reading `activeProfile` there fails however it is read (`SHC5`), here
    // through `.output`; nothing is written.
    auto f = Fixture.create("profiledependent");
    f.entries(q{
        static if (activeProfile.output == Output.spirv)
            @profiles(vulkan13) @fragment vec4 onlyVulkan(@input vec4 colour) => colour;

        @fragment vec4 always(@input vec4 colour) => colour;
    });
    const made = f.run();
    assert(made.status == 1, made.diagnostics);
    assert(made.diagnostics.canFind("the manifest"), made.diagnostics);
    assert(f.outputs.length == 0, f.outputs.join(" "));

    // In a function body, which the manifest does not analyse, it may.
    auto g = Fixture.create("profilebody");
    g.entries(q{
        @profiles(gl330, vulkan13) @fragment vec4 tint(@input vec4 colour)
        {
            static if (activeProfile.output == Output.spirv)
                return colour * 0.5f;
            else
                return colour;
        }
    });
    const built = g.run();
    assert(built.status == 0, built.diagnostics);
    assert(g.outputs == [".stamp", "tint.frag", "tint.frag.spv"], g.outputs.join(" "));
}

@("shaderCompile.resources.blocksOnVulkanUniformsOnOpenGL")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // One declaration, lowered per profile (`SHR3`–`SHR6`): on Vulkan a
    // uniform block of `T` itself, a push-constant block and the default
    // uniform block, laid out as `layoutOf` says; on OpenGL one uniform per
    // field, named after it.
    auto f = Fixture.create("resources");
    f.entries(q{
        struct Light
        {
            vec3 tint;
            float gain;
        }

        struct Push
        {
            float aspect;
        }

        @profiles(gl330, vulkan13) @fragment vec4 lit(@input vec4 colour, UniformBlock!Light light,
            PushConstants!Push pc, @uniform float exposure)
            => colour * (light.gain * exposure * pc.aspect) + v4(light.tint, 0.0f);

        static assert(layoutOf!(Light, Rule.std140)["gain"].offset == 12);
    });
    const made = f.run();
    assert(made.status == 0, made.diagnostics);
    assert(f.outputs == [".stamp", "lit.frag", "lit.frag.spv"], f.outputs.join(" "));

    const dis = execute(["spirv-dis", f.out_.buildPath("lit.frag.spv")]);
    assert(dis.status == 0, dis.output);
    foreach (line; [`OpName %light "light"`, `OpMemberName %Light 1 "gain"`,
            "OpMemberDecorate %Light 1 Offset 12", "OpDecorate %Light Block",
            "OpDecorate %light Binding 1", "OpDecorate %litUniforms Binding 2",
            `OpName %litUniformsBlock "litUniformsBlock"`, "PushConstant"])
        assert(dis.output.canFind(line), line ~ "\n" ~ dis.output);

    const glsl = readText(f.out_.buildPath("lit.frag"));
    foreach (line; ["uniform vec3 tint;", "uniform float gain;", "uniform float aspect;",
            "uniform float exposure;"])
        assert(glsl.canFind(line), line ~ "\n" ~ glsl);
}

@("shaderCompile.audit.int64NamesTheDLines")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // A module that computes in 64 bits fails a profile that denies `int64`
    // (`SHC9`), and the failure names the D line of each such operation
    // (`SHM6`); nothing is written.
    auto f = Fixture.create("int64");
    f.entries(q{
        size_t wrap(size_t i) => i % 3;

        @profiles(vulkan13) @fragment vec4 pick(@uniform int index)
        {
            vec4[3] t;
            t[0] = v4(1.0f);
            t[1] = v4(0.5f);
            t[2] = v4(0.0f);
            return t[wrap(index)];
        }
    });
    const made = f.run();
    assert(made.status == 1, made.diagnostics);
    assert(made.diagnostics.canFind("`OpCapability Int64`"), made.diagnostics);
    assert(made.diagnostics.canFind("fx_entries.d(") && made.diagnostics.canFind("64-bit integer operation `i % 3LU`"),
        made.diagnostics);
    assert(f.outputs.length == 0, f.outputs.join(" "));
}

@("shaderCompile.resources.aSamplerInAnInterfaceStructIsItsOwnVariable")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHF6`: a `Sampler2D` in a `@resources` struct is flattened into a
    // variable of its own before code is generated, so no module holds an
    // image in an aggregate: on OpenGL a `sampler2D` uniform named after the
    // field, on Vulkan an image at its binding beside the shared sampler.
    auto f = Fixture.create("samplerfield");
    f.entries(q{
        @resources struct Material
        {
            Sampler2D albedo;
            @uniform float gain;
        }

        @profiles(gl330, vulkan13) @fragment vec4 lit(@input vec2 uv, Material material)
            => material.albedo.sample(uv) * material.gain;
    });
    const made = f.run();
    assert(made.status == 0, made.diagnostics);
    assert(f.outputs == [".stamp", "lit.frag", "lit.frag.spv"], f.outputs.join(" "));

    const glsl = readText(f.out_.buildPath("lit.frag"));
    foreach (line; ["uniform sampler2D albedo;", "uniform float gain;"])
        assert(glsl.canFind(line), line ~ "\n" ~ glsl);

    const dis = execute(["spirv-dis", f.out_.buildPath("lit.frag.spv")]);
    assert(dis.status == 0, dis.output);
    foreach (line; [`OpName %albedo "albedo"`, "OpDecorate %albedo Binding 1",
            "OpDecorate %sampler Binding 0"])
        assert(dis.output.canFind(line), line ~ "\n" ~ dis.output);
    // That no aggregate holds the image is spirv-val's to say: the step ran
    // it for Vulkan 1.3, which rejects an image in a struct.
}

@("shaderCompile.requirements.anEntryPointMayReachOnlyWhatItsProfileGrants")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHC8`: built for its default profiles, `gl330` and `gles100`, an entry
    // point whose helper takes a derivative fails `gles100`, which denies
    // `derivatives`, with the chain of calls from the entry point; nothing
    // is written.
    auto f = Fixture.create("requires");
    f.entries(q{
        vec2 edge(vec2 uv) => fwidth(uv);

        @fragment vec4 soft(@input vec2 uv)
        {
            const w = edge(uv);
            return v4(w.x, w.y, 0, 1);
        }
    });
    const denied = f.run();
    assert(denied.status == 1, denied.diagnostics);
    foreach (line; ["entry point `soft` reaches `sparkles.shaders.fragment.fwidth!(__vector(float[2]))`, "
            ~ "which requires `derivatives`; the profile `gles100` does not grant it",
            "`fx_entries.soft` calls `fx_entries.edge`",
            "`fx_entries.edge` calls `sparkles.shaders.fragment.fwidth!(__vector(float[2]))`"])
        assert(denied.diagnostics.canFind(line), line ~ "\n" ~ denied.diagnostics);
    assert(f.outputs.length == 0, f.outputs.join(" "));

    // Coarse and fine derivatives are `derivativeControl`, which `gl330`
    // denies: an entry point built for it and `vulkan1.3` fails `gl330`
    // only. One built for `vulkan1.3` alone builds.
    f.entries(q{
        @profiles(gl330, vulkan13) @fragment vec4 sharp(@input vec2 uv)
            => v4(dpdxFine(uv.x), 0, 0, 1);
    });
    const fine = f.run();
    assert(fine.status == 1, fine.diagnostics);
    assert(fine.diagnostics.canFind("requires `derivativeControl`; the profile `gl330` does not grant it"),
        fine.diagnostics);
    assert(!fine.diagnostics.canFind("vulkan1.3` does not grant"), fine.diagnostics);

    f.entries(q{
        @profiles(vulkan13) @fragment vec4 sharp(@input vec2 uv)
            => v4(dpdxFine(uv.x), 0, 0, 1);
    });
    const built = f.run();
    assert(built.status == 0, built.diagnostics);
    assert(f.outputs == [".stamp", "sharp.frag.spv"], f.outputs.join(" "));
}

@("shaderCompile.fragment.stageOperationsInEveryOutput")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `discard` ends the invocation in every output (GLSL's `discard`,
    // SPIR-V's `OpTerminateInvocation`); `demote`, which only Vulkan grants,
    // is `OpDemoteToHelperInvocation`; derivatives are GLSL's `fwidth` and
    // SPIR-V's `OpFwidth`; `fragCoord` and `frontFacing` are the stage's
    // built-ins.
    auto f = Fixture.create("fragmentops");
    f.entries(q{
        @profiles(gl330, vulkan13) @fragment vec4 cut(@input vec2 uv,
            @builtin(Builtin.fragCoord) vec4 position, @builtin(Builtin.frontFacing) bool front)
        {
            if (uv.x < 0.25f)
                discard();
            const w = fwidth(uv);
            return v4(w.x, position.y, front ? 1 : 0, 1);
        }

        @profiles(vulkan13) @fragment vec4 fade(@input vec2 uv)
        {
            if (uv.y < 0.25f)
                demote();
            return v4(uv.x, uv.y, 0, 1);
        }
    });
    const made = f.run();
    assert(made.status == 0, made.diagnostics);
    assert(f.outputs == [".stamp", "cut.frag", "cut.frag.spv", "fade.frag.spv"], f.outputs.join(" "));

    const glsl = readText(f.out_.buildPath("cut.frag"));
    foreach (line; ["discard;", "fwidth(", "gl_FragCoord.y", "gl_FrontFacing"])
        assert(glsl.canFind(line), line ~ "\n" ~ glsl);

    const cut = execute(["spirv-dis", f.out_.buildPath("cut.frag.spv")]);
    assert(cut.status == 0, cut.output);
    foreach (line; ["OpTerminateInvocation", "OpFwidth", "BuiltIn FragCoord", "BuiltIn FrontFacing",
            "OpExecutionMode %cut OriginUpperLeft"])
        assert(cut.output.canFind(line), line ~ "\n" ~ cut.output);
    const fade = execute(["spirv-dis", f.out_.buildPath("fade.frag.spv")]);
    assert(fade.status == 0, fade.output);
    foreach (line; ["OpCapability DemoteToHelperInvocation", "OpDemoteToHelperInvocation"])
        assert(fade.output.canFind(line), line ~ "\n" ~ fade.output);
}

@("shaderCompile.capabilities.theVocabularyIsTheCompilers")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHC1`: a device compilation reads `Cap` as the compiler's
    // `ldc.dcompute.Capability`; a host compilation by the device compiler
    // asserts that the library's own copy names the same capabilities, in
    // the same order.
    const shaders = repoRoot.buildPath("libs", "shaders", "src");
    const r = execute(["ldc2-vulkan", "-o-", "-I" ~ shaders,
        shaders.buildPath("sparkles", "shaders", "capabilities.d")]);
    assert(r.status == 0, r.output);
}

@("shaderCompile.resources.samplersOfTheirOwn")
@system unittest
{
    if (const tool = missingTool())
        return skipTest("the device toolchain is not on PATH (" ~ tool ~ ")");

    // `SHR7`: a `SamplerState` parameter is a sampler of its own, at the next
    // binding in parameter order on Vulkan. On OpenGL each image is a
    // `sampler2D` per sampler it is read through: under its own name when
    // that is one, as `<image>_<sampler>` when it is several.
    auto f = Fixture.create("samplers");
    f.entries(q{
        @profiles(gl330, vulkan13) @fragment vec4 canvas(@input vec2 uv, Sampler2D atlas,
            Sampler2D photo, SamplerState nearest, SamplerState linear)
            => atlas.sample(nearest, uv) * photo.sample(linear, uv) + atlas.sample(uv);
    });
    const made = f.run();
    assert(made.status == 0, made.diagnostics);
    assert(f.outputs == [".stamp", "canvas.frag", "canvas.frag.spv"], f.outputs.join(" "));

    const glsl = readText(f.out_.buildPath("canvas.frag"));
    foreach (line; ["uniform sampler2D atlas_nearest;", "uniform sampler2D atlas_sampler;",
            "uniform sampler2D photo;"])
        assert(glsl.canFind(line), line ~ "\n" ~ glsl);
    assert(!glsl.canFind("SPIRV_Cross_Combined"), glsl);

    const dis = execute(["spirv-dis", f.out_.buildPath("canvas.frag.spv")]);
    assert(dis.status == 0, dis.output);
    foreach (line; ["OpDecorate %atlas Binding 1", "OpDecorate %photo Binding 2",
            "OpDecorate %nearest Binding 3", "OpDecorate %linear Binding 4",
            "OpDecorate %sampler Binding 0"])
        assert(dis.output.canFind(line), line ~ "\n" ~ dis.output);
}
