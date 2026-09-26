/**
`shader-compile`: the pipeline behind `EFX20`.

One D function per effect serves both the terminal (called per cell) and the
window (compiled to a fragment shader). This tool is the second half of that
claim: it compiles a package's `@compute` modules with the dcompute-enabled
LDC to SPIR-V, validates it, optimises it, cross-compiles every `@fragment`
entry point to the two GLSL dialects `sparkles:ui-raylib` loads (desktop 330,
ES 100 for Android), proves each with glslang, and writes them to `--out`.

$(B Dub is the unit table.) What gets compiled, against which import paths,
with which flags, is the package's $(I device configuration) — a dub
configuration whose dflags name a dcompute target (`-mdcompute-targets=`),
`shaders` by convention. The tool asks `dub describe` for it and compiles the
modules among its source files (the package's and its dependencies') whose
declaration carries `@compute`: that set $(I is) the unit, so there is nothing
to declare per unit and nothing to keep in step. `sparkles:dmd-lsp` analyzes
the same modules under the same configuration, so an editor sees a shader the
way this tool compiles it (`TGT6`).

$(B It runs as a build step.) `sparkles:ui`'s `gpu-effects` configuration
runs it with `--if-stale` before every build, into a git-ignored directory: a
stamp there records the SHA-256 of every input (the unit's modules and their
packages' recipes), so a build whose shaders are current pays a hash check
and needs neither dub nor the compiler. A packager that builds the output
elsewhere (Nix) writes a `prebuilt` stamp.

$(B The compiler) is `ldc2-vulkan` on `PATH` — dlang.nix's `ldc-vulkan` (LDC's
`sparkles/vulkan-shaders` branch: stock LDC has no Vulkan target and no
`@fragment`), which the dev shell and `nix run .#shader-compile` both provide
under that name — or whatever `--ldc` names.

$(B Dependency-free on purpose.) It uses Phobos and `sparkles:shader` alone:
`sparkles:core-cli` depends on `sparkles:ui`, whose build runs this tool, so
depending on it would make the tool a prerequisite of itself.
*/
module app;

import std.algorithm : canFind, filter, map, sort, startsWith, uniq;
import std.array : array, join, replace;
import std.conv : text;
import std.file : dirEntries, exists, isFile, mkdirRecurse, readText, remove, rmdirRecurse,
    SpanMode, tempDir, write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, relativePath;
import std.process : execute;
import std.regex : ctRegex, matchAll, replaceAll;
import std.stdio : stderr, writefln, writeln;
import std.string : indexOf, lineSplitter, strip, stripRight;

import sparkles.shader.compute_mode : ComputeMode, computeModeOf;

/// A package's device build, as `dub describe` reports its device
/// configuration.
struct DeviceBuild
{
    string packageName;   /// the described package, e.g. `sparkles:ui`
    string packageDir;    /// its directory (absolute)
    string target;        /// the dcompute target, e.g. `vulkan-130`
    string[] importPaths; /// `-I` roots: the package's and its dependencies'
    string[] versions;    /// version identifiers dub defines
    string[] dflags;      /// the remaining flags, target flag excluded
    string[] sources;     /// every source file of the package and its dependencies
    string[] packageDirs; /// the directories of the package and its dependencies
}

/**
Reads a `dub describe` JSON document into a `DeviceBuild`.

Settings come from the root target, which dub reports with its dependencies'
import paths and flags merged in (so flags repeat — they are deduplicated here,
first occurrence kept). Sources come from every target: a `@compute` module of
a dependency (`sparkles:shader`'s vocabulary) belongs to the unit as much as
one of the package's own, because a SPIR-V module has no linker to find it.
*/
DeviceBuild parseDescribe(string json)
{
    // dub may print resolution chatter before the JSON document.
    const at = json.indexOf('{');
    auto doc = parseJSON(at < 0 ? json : json[at .. $]);
    const rootName = doc["rootPackage"].str;

    DeviceBuild build;
    build.packageName = rootName;
    foreach (p; doc["packages"].array)
    {
        build.packageDirs ~= p["path"].str.buildNormalizedPath;
        if (p["name"].str == rootName)
            build.packageDir = p["path"].str.buildNormalizedPath;
    }

    foreach (t; doc["targets"].array)
    {
        auto bs = t["buildSettings"];
        build.sources ~= strings(bs, "sourceFiles");
        if (t["rootPackage"].str != rootName)
            continue;
        build.importPaths = strings(bs, "importPaths").dedup;
        build.versions = strings(bs, "versions").dedup;
        foreach (flag; strings(bs, "dflags").dedup)
        {
            enum targetFlag = "-mdcompute-targets=";
            if (flag.startsWith(targetFlag))
                build.target = flag[targetFlag.length .. $];
            else
                build.dflags ~= flag;
        }
    }
    build.sources = build.sources.dedup;
    return build;
}

private string[] strings(JSONValue v, string key)
{
    string[] items;
    if (auto member = key in v)
        foreach (e; member.array)
            items ~= e.str;
    return items;
}

/// `items` without repeats, in first-occurrence order.
private string[] dedup(string[] items)
{
    bool[string] seen;
    string[] result;
    foreach (item; items)
        if (item !in seen)
        {
            seen[item] = true;
            result ~= item;
        }
    return result;
}

///
@("shaderCompile.parseDescribe.rootSettingsAndEverySource")
@system unittest
{
    const json = `resolution chatter
    {"rootPackage": "sparkles:ui",
        "packages": [{"name": "sparkles:ui", "path": "/r/libs/ui/"},
            {"name": "sparkles:shader", "path": "/r/libs/shader/"}],
        "targets": [
        {"rootPackage": "sparkles:ui", "buildSettings": {
            "importPaths": ["/r/libs/ui/src/", "/r/libs/shader/src/", "/r/libs/ui/src/"],
            "versions": ["Have_sparkles_ui"],
            "dflags": ["-preview=in", "-mdcompute-targets=vulkan-130", "-preview=in"],
            "sourceFiles": ["/r/libs/ui/shaders/effects.d", "/r/libs/ui/src/a.d"]}},
        {"rootPackage": "sparkles:shader", "buildSettings": {
            "dflags": ["-something-else"],
            "sourceFiles": ["/r/libs/shader/src/types.d"]}}]}`;

    const b = parseDescribe(json);
    assert(b.packageName == "sparkles:ui");
    assert(b.packageDir == "/r/libs/ui");
    assert(b.packageDirs == ["/r/libs/ui", "/r/libs/shader"]);
    assert(b.target == "vulkan-130");
    assert(b.importPaths == ["/r/libs/ui/src/", "/r/libs/shader/src/"]);
    assert(b.versions == ["Have_sparkles_ui"]);
    assert(b.dflags == ["-preview=in"]); // the root's, deduplicated, target split off
    assert(b.sources == ["/r/libs/ui/shaders/effects.d", "/r/libs/ui/src/a.d",
        "/r/libs/shader/src/types.d"]);
}

/// The `@compute` modules among `sources`, and which of them are
/// device-only — the entry-point modules the generated files name.
struct Unit
{
    string[] sources;     ///
    string[] deviceOnly;  ///
}

/// Picks the unit out of a build's sources by reading each module's head.
Unit unitOf(in DeviceBuild build)
{
    Unit unit;
    foreach (source; build.sources)
    {
        if (!source.exists)
            continue;
        final switch (computeModeOf(source.readText))
        {
            case ComputeMode.none:
                break;
            case ComputeMode.deviceOnly:
                unit.deviceOnly ~= source;
                unit.sources ~= source;
                break;
            case ComputeMode.hostAndDevice:
                unit.sources ~= source;
                break;
        }
    }
    return unit;
}

// `dub test` builds this package as a library and takes its `main` from the
// generated `dub_test_root`, so the CLI entry point steps aside for that build.
version (unittest) {} else
int main(string[] args)
{
    import std.getopt : config, defaultGetoptPrinter, getopt;

    string packageDir = ".";
    string configuration = "shaders";
    string outDir;
    string ldc = "ldc2-vulkan";
    bool ifStale, keep, quiet;

    auto help = getopt(args, config.passThrough,
        "package", "The dub package whose device configuration to compile (default: the current directory).", &packageDir,
        "config", "Its device configuration: the one whose dflags name a dcompute target (default: shaders).", &configuration,
        "out", "Where `<entry>.frag` and `<entry>.es.frag` land (required).", &outDir,
        "ldc", "The dcompute-enabled LDC (default: `ldc2-vulkan` on PATH).", &ldc,
        "if-stale", "Do nothing while `--out`'s stamp says its inputs are unchanged — the build step's mode.", &ifStale,
        "keep", "Keep the scratch directory (SPIR-V, disassembly) and print its path.", &keep,
        "quiet", "Only report problems.", &quiet);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("shader-compile: compile a dub package's single-source D shaders " ~
            "to the GLSL sparkles:ui-raylib loads.", help.options);
        return 0;
    }
    if (args.length > 1)
    {
        stderr.writeln("shader-compile: unexpected argument `", args[1], "`; see --help");
        return 2;
    }
    if (!outDir.length)
    {
        stderr.writeln("shader-compile: --out is required; see --help");
        return 2;
    }

    // Fresh output needs neither dub nor a compiler: this is the path every
    // build of a dependent takes once the shaders exist.
    if (ifStale && isFresh(outDir, packageDir))
        return 0;

    if (tryExecute([ldc, "--version"]).status == 127)
    {
        stderr.writefln("shader-compile: no dcompute-enabled LDC (`%s`). Enter the dev shell " ~
            "(`nix develop`), use `nix run .#shader-compile`, or pass --ldc a " ~
            "`sparkles/vulkan-shaders` build.", ldc);
        return 3;
    }

    const described = tryExecute(["dub", "describe", "--root=" ~ packageDir,
        "--config=" ~ configuration, "--compiler=" ~ ldc], captureStderr: false);
    if (described.status != 0)
    {
        stderr.writeln(described.output);
        stderr.writefln("shader-compile: `dub describe --config=%s` failed in %s",
            configuration, packageDir);
        return 1;
    }
    const build = parseDescribe(described.output);
    if (!build.target.length)
    {
        stderr.writefln("shader-compile: %s's configuration `%s` names no dcompute target " ~
            "(`-mdcompute-targets=`), so it is not a device build", build.packageName, configuration);
        return 2;
    }
    const unit = unitOf(build);
    if (!unit.deviceOnly.length)
    {
        stderr.writefln("shader-compile: %s (`%s`) has no `@compute(CompileFor.deviceOnly)` " ~
            "module, so there is no entry point to compile", build.packageName, configuration);
        return 1;
    }
    return run(build, unit, outDir, ldc, keep, quiet);
}

/// The outcome: 0 ok, 1 failure, 3 toolchain unusable.
int run(in DeviceBuild build, in Unit unit, string outDir, string ldc, bool keep, bool quiet)
{
    import std.conv : to;
    import std.process : thisProcessID;

    // Per process: concurrent builds of several dependents each run this step,
    // and a shared scratch directory would be deleted under a sibling.
    const name = build.packageName.replace(":", "-");
    const scratch = buildPath(tempDir,
        "sparkles-shader-compile-" ~ name ~ "-" ~ thisProcessID.to!string);
    if (scratch.exists)
        scratch.rmdirRecurse;
    scratch.mkdirRecurse;
    scope (exit)
        if (!keep && scratch.exists)
            scratch.rmdirRecurse;

    // 1. D -> SPIR-V. One invocation for the whole unit: the device module is
    //    one SPIR-V module, and it has no linker to find an import.
    // LDC names the module `<prefix>_<target without dashes>_64.spv`.
    const prefix = "unit";
    const spv = buildPath(scratch, prefix ~ "_" ~ build.target.replace("-", "") ~ "_64.spv");
    auto cmd = [ldc, "-O2", "-c", "-m64", "-mdcompute-targets=" ~ build.target,
        "-mdcompute-file-prefix=" ~ prefix, "-od=" ~ scratch]
        ~ build.versions.map!(v => "-d-version=" ~ v).array
        ~ build.dflags
        ~ build.importPaths.map!(d => "-I" ~ d).array ~ unit.sources;
    const compiled = tryExecute(cmd);
    if (compiled.status != 0)
    {
        stderr.writeln(compiled.output);
        if (isStockLdc(compiled))
            stderr.writefln("shader-compile: `%s` is not a dcompute-enabled LDC with the " ~
                "`@fragment` stage (`sparkles/vulkan-shaders`)", ldc);
        stderr.writefln("shader-compile: %s: LDC failed (%s)", build.packageName, compiled.status);
        return isStockLdc(compiled) ? 3 : 1;
    }
    if (!spv.exists)
    {
        stderr.writefln("shader-compile: %s: LDC produced no %s", build.packageName, spv);
        return 1;
    }

    // 2. Validate what the compiler emitted, before anything rewrites it.
    //    Universal rules: the plain uniforms are GL's shape, not Vulkan's.
    if (!step(["spirv-val", "--target-env", "spv1.4", spv], name ~ ": spirv-val"))
        return 1;

    // 3. Optimise: folds the name-string constants and dead helpers away, so
    //    the GLSL carries no `uint8_t` arrays and no Int8 extension request.
    const opt = buildPath(scratch, prefix ~ ".opt.spv");
    if (!step(["spirv-opt", "-O", spv, "-o", opt], name ~ ": spirv-opt"))
        return 1;

    // 4. The entry points, from the disassembly — one shader file per entry.
    const dis = tryExecute(["spirv-dis", opt]);
    if (dis.status != 0)
    {
        stderr.writeln(dis.output);
        return 1;
    }
    const entries = entryPoints(dis.output);
    if (entries.length == 0)
    {
        stderr.writefln("shader-compile: %s: no fragment entry points in %s", name, spv);
        return 1;
    }

    // 5. Cross-compile each entry to both dialects, name the sampler what
    //    raylib binds, and prove the result with glslang.
    const origin = header(build, unit);
    string[string] produced; // relative file name -> contents
    foreach (entry; entries)
    {
        foreach (dialect; [Dialect.desktop, Dialect.es])
        {
            auto cross = tryExecute(["spirv-cross", "--entry", entry, "--stage", "frag",
                "--remove-unused-variables"] ~ dialect.flags ~ [opt]);
            if (cross.status != 0)
            {
                stderr.writeln(cross.output);
                stderr.writefln("shader-compile: %s/%s: spirv-cross failed", name, entry);
                return 1;
            }
            // One trailing newline, exactly, as every text file here has.
            const glsl = format(origin, entry)
                ~ renameCombinedSamplers(cross.output).stripRight ~ "\n";
            const file = entry ~ dialect.suffix;
            const path = buildPath(scratch, file);
            path.write(glsl);
            if (!step(["glslangValidator", path], name ~ "/" ~ file ~ ": glslang"))
                return 1;
            produced[file] = glsl;
        }
    }

    // 6. Write. Each file lands by rename, so a concurrent build reading the
    //    directory sees an old file or a new one, never half of one; the
    //    stamp goes last, so it never vouches for output not yet written.
    outDir.mkdirRecurse;
    foreach (file; produced.keys.sort)
    {
        writeAtomically(buildPath(outDir, file), produced[file]);
        if (!quiet)
            writefln("shader-compile: wrote %s", buildPath(outDir, file));
    }
    // A renamed entry point leaves its old GLSL behind; the directory is
    // this tool's, so it goes.
    foreach (e; dirEntries(outDir, "*.frag", SpanMode.shallow).filter!(e => e.isFile).array)
        if (e.name.baseName !in produced)
            e.name.remove;
    writeAtomically(buildPath(outDir, stampName), stampFor(build, unit, produced.keys.sort.array));
    if (keep)
        writefln("shader-compile: scratch kept at %s", scratch);
    return 0;
}

/// Writes `path` through a sibling temporary and a rename.
private void writeAtomically(string path, string contents)
{
    import std.conv : to;
    import std.file : rename;
    import std.process : thisProcessID;

    const tmp = path ~ ".tmp-" ~ thisProcessID.to!string;
    tmp.write(contents);
    tmp.rename(path);
}

/// The stamp file in `--out`: what the output was generated from.
enum stampName = ".stamp";

/// Bump when the output changes for a reason no input records (this tool's
/// own pipeline), so every existing stamp goes stale.
enum stampVersion = "shader-compile stamp 1";

/**
The stamp for output generated from `unit`: every input the output depends
on, with its SHA-256 — the unit's modules, and the recipe of each package
that contributes one (flags, versions and the device target live there) —
plus the files produced. Paths are relative to the package, so a checkout
moved elsewhere stays fresh.

A packager that supplies the output prebuilt (a Nix derivation) writes the
single line `prebuilt` instead, which is always fresh.
*/
string stampFor(in DeviceBuild build, in Unit unit, in string[] outputs)
{
    string s = stampVersion ~ "\n";
    foreach (input; stampInputs(build, unit))
        s ~= "input " ~ sha256Of(input) ~ " " ~ input.relativePath(build.packageDir) ~ "\n";
    foreach (output; outputs)
        s ~= "output " ~ output ~ "\n";
    return s;
}

/// The unit's modules, then the recipes of the packages they come from.
private string[] stampInputs(in DeviceBuild build, in Unit unit)
{
    string[] inputs = unit.sources.dup;
    foreach (dir; build.packageDirs)
    {
        if (!unit.sources.canFind!(s => s.startsWith(dir ~ "/")))
            continue;
        foreach (recipe; ["dub.sdl", "dub.json"])
            if (dir.buildPath(recipe).exists)
            {
                inputs ~= dir.buildPath(recipe);
                break;
            }
    }
    return inputs;
}

private string sha256Of(string path)
{
    import std.digest : toHexString;
    import std.digest.sha : sha256Of;
    import std.file : read;

    return sha256Of(cast(const(ubyte)[]) path.read).toHexString.idup;
}

/**
Whether `outDir` holds output its stamp still vouches for: every recorded
input unchanged and every recorded output present. Needs no dub and no
compiler, which is what makes the build step cheap.

A module added to the unit that no recorded input changed for is not seen
until one does — in practice the entry module that imports it.
*/
bool isFresh(string outDir, string packageDir)
{
    import std.algorithm.searching : findSplit;
    import std.path : absolutePath, buildNormalizedPath;

    const stampPath = buildPath(outDir, stampName);
    if (!stampPath.exists)
        return false;
    const lines = stampPath.readText.lineSplitter.array;
    if (lines.length == 1 && lines[0] == "prebuilt")
        return true;
    if (!lines.length || lines[0] != stampVersion)
        return false;
    const pkg = packageDir.absolutePath.buildNormalizedPath;
    foreach (line; lines[1 .. $])
    {
        if (auto input = line.findSplit(" ")[2].findSplit(" "))
            if (line.startsWith("input "))
            {
                const path = pkg.buildPath(input[2]).buildNormalizedPath;
                if (!path.exists || sha256Of(path) != input[0])
                    return false;
                continue;
            }
        if (line.startsWith("output ") && !buildPath(outDir, line["output ".length .. $]).exists)
            return false;
    }
    return true;
}

@("shaderCompile.stamp.freshUntilAnInputChanges")
@system unittest
{
    import std.file : mkdirRecurse, remove, rmdirRecurse, tempDir;
    import std.path : buildPath;

    const root = buildPath(tempDir, "sparkles-shader-compile-stamp-test");
    if (root.exists)
        root.rmdirRecurse;
    scope (exit) root.rmdirRecurse;
    const pkg = root.buildPath("ui"), out_ = pkg.buildPath("generated");
    const dep = root.buildPath("shader");
    foreach (d; [pkg.buildPath("shaders"), dep.buildPath("src"), out_])
        d.mkdirRecurse;
    pkg.buildPath("dub.sdl").write(`name "ui"`);
    dep.buildPath("dub.sdl").write(`name "shader"`);
    pkg.buildPath("shaders", "fx.d").write("@compute module fx;");
    dep.buildPath("src", "types.d").write("@compute(CompileFor.hostAndDevice) module types;");

    const build = DeviceBuild(packageName: "ui", packageDir: pkg, packageDirs: [pkg, dep, root.buildPath("other")]);
    const unit = Unit(sources: [pkg.buildPath("shaders", "fx.d"), dep.buildPath("src", "types.d")]);
    assert(!isFresh(out_, pkg), "no stamp yet");

    out_.buildPath("fx.frag").write("glsl");
    out_.buildPath(stampName).write(stampFor(build, unit, ["fx.frag"]));
    assert(isFresh(out_, pkg));

    // A dependency's module, and a contributing package's recipe, are inputs.
    dep.buildPath("src", "types.d").write("@compute(CompileFor.hostAndDevice) module types; // edit");
    assert(!isFresh(out_, pkg), "a module of the unit changed");
    dep.buildPath("src", "types.d").write("@compute(CompileFor.hostAndDevice) module types;");
    assert(isFresh(out_, pkg));
    pkg.buildPath("dub.sdl").write(`name "ui" // new flags`);
    assert(!isFresh(out_, pkg), "the recipe changed");
    pkg.buildPath("dub.sdl").write(`name "ui"`);

    out_.buildPath("fx.frag").remove;
    assert(!isFresh(out_, pkg), "an output is missing");

    // Output a packager built elsewhere is taken as it is.
    out_.buildPath(stampName).write("prebuilt\n");
    assert(isFresh(out_, pkg));
    out_.buildPath(stampName).write("shader-compile stamp 0\n");
    assert(!isFresh(out_, pkg), "another tool version's stamp");
}

private enum Dialect
{
    desktop,
    es,
}

private string[] flags(Dialect d)
    => d == Dialect.desktop ? ["--version", "330"] : ["--es", "--version", "100"];

private string suffix(Dialect d) => d == Dialect.desktop ? ".frag" : ".es.frag";

/**
The provenance comment, a format string taking the entry point. GLSL allows
comments before `#version`. It names the entry modules relative to their
package, so the bytes do not depend on where the tool ran from.
*/
string header(in DeviceBuild build, in Unit unit)
{
    const modules = unit.deviceOnly
        .map!(m => m.absolutePath.relativePath(build.packageDir.absolutePath))
        .join(", ");
    return "// Generated by shader-compile from " ~ build.packageName ~ "'s " ~ modules
        ~ " (entry point `%s`).\n"
        ~ "// Do not edit: it is regenerated from the D source whenever that changes.\n";
}

///
@("shaderCompile.header.namesTheEntryModulesRelativeToTheirPackage")
@system unittest
{
    const build = DeviceBuild(packageName: "sparkles:ui", packageDir: "/r/libs/ui");
    const unit = Unit(deviceOnly: ["/r/libs/ui/shaders/effects.d"]);
    assert(format(header(build, unit), "dim") ==
        "// Generated by shader-compile from sparkles:ui's shaders/effects.d (entry point `dim`).\n" ~
        "// Do not edit: it is regenerated from the D source whenever that changes.\n");
}

/// `OpEntryPoint Fragment %name "name"` lines, in order.
string[] entryPoints(string disassembly)
{
    string[] names;
    foreach (line; disassembly.lineSplitter)
    {
        const l = line.strip;
        if (!l.startsWith("OpEntryPoint Fragment "))
            continue;
        foreach (m; l.matchAll(ctRegex!`"([^"]+)"`))
            names ~= m[1];
    }
    return names;
}

///
@("shaderCompile.entryPoints.readsFragmentEntriesInOrder")
@system unittest
{
    const dis = "OpCapability Shader\n" ~
        `               OpEntryPoint Fragment %scanlines "scanlines" %fragTexCoord` ~ "\n" ~
        `               OpEntryPoint GLCompute %k "k"` ~ "\n" ~
        `               OpEntryPoint Fragment %dim "dim" %x` ~ "\n";
    assert(entryPoints(dis) == ["scanlines", "dim"]);
}

/**
spirv-cross fuses an image with the sampler it is read through into one
`sampler2D` named `SPIRV_Cross_Combined<image><sampler>`. The image is what
the D parameter was called and what raylib binds by name (`texture0`), so the
combined sampler takes the image's name back.
*/
string renameCombinedSamplers(string glsl)
    => glsl.replaceAll(ctRegex!`SPIRV_Cross_Combined(\w+?)sampler\b`, "$1");

///
@("shaderCompile.renameCombinedSamplers.givesTheImageItsNameBack")
@system unittest
{
    assert(renameCombinedSamplers("uniform sampler2D SPIRV_Cross_Combinedtexture0sampler;\n" ~
        "  vec4 t = texture(SPIRV_Cross_Combinedtexture0sampler, uv);")
        == "uniform sampler2D texture0;\n  vec4 t = texture(texture0, uv);");
}

private struct Run
{
    int status;
    string output;
}

private Run tryExecute(string[] cmd, bool captureStderr = true)
{
    import std.process : Config;

    try
    {
        const r = execute(cmd, null, captureStderr ? Config.none : Config.stderrPassThrough);
        return Run(r.status, r.output);
    }
    catch (Exception e)
        return Run(127, e.msg);
}

private bool step(string[] cmd, string what)
{
    const r = tryExecute(cmd);
    if (r.status == 0)
        return true;
    stderr.writeln(r.output);
    stderr.writefln("shader-compile: %s failed (%s)", what, r.status);
    return false;
}

/// A stock LDC: no Vulkan target, or no `@fragment`.
private bool isStockLdc(in Run r)
    => r.output.canFind("not built with Vulkan DCompute support")
    || r.output.canFind("Unrecognised or invalid DCompute targets")
    || r.output.canFind("undefined identifier `fragment`");

@("shaderCompile.unitOf.repositoryUi")
@system unittest
{
    import std.path : dirName;

    // The repository's own device build, as dub would describe it — the
    // sources listed by hand here are exactly what the unit must pick out:
    // every `@compute` module, of the package and of its dependencies, and no
    // other. `attributes.d` is not one: on the device it only re-exports
    // `ldc.dcompute`, so it is imported, never compiled.
    const root = __FILE_FULL_PATH__.dirName.buildPath("..", "..", "..").buildNormalizedPath;
    string p(string rel) => root.buildPath(rel);
    const build = DeviceBuild(packageName: "sparkles:ui", packageDir: p("libs/ui"),
        sources: [p("libs/ui/shaders/effects.d"), p("libs/ui/src/sparkles/ui/effect.d"),
            p("libs/ui/src/sparkles/ui/effect_shaders.d"),
            p("libs/shader/src/sparkles/shader/attributes.d"),
            p("libs/shader/src/sparkles/shader/compute_mode.d"),
            p("libs/shader/src/sparkles/shader/math.d"),
            p("libs/shader/src/sparkles/shader/testing.d"),
            p("libs/shader/src/sparkles/shader/types.d")]);
    const unit = unitOf(build);
    assert(unit.deviceOnly == [p("libs/ui/shaders/effects.d")], unit.deviceOnly.text);
    assert(unit.sources == [p("libs/ui/shaders/effects.d"),
        p("libs/ui/src/sparkles/ui/effect_shaders.d"),
        p("libs/shader/src/sparkles/shader/math.d"),
        p("libs/shader/src/sparkles/shader/types.d")], unit.sources.text);
}
