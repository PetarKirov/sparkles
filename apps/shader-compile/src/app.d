/**
`shader-compile`: the pipeline behind `EFX20`.

One D function per effect serves both the terminal (called per cell) and the
window (compiled to a fragment shader). This tool is the second half of that
claim: it compiles the repository's `@fragment` modules with the
dcompute-enabled LDC to SPIR-V, validates it, optimises it, cross-compiles
every entry point to the two GLSL dialects `sparkles:ui-raylib` loads
(desktop 330, ES 100 for Android), proves each with glslang, and writes them
where `sparkles.ui.effect` string-imports them.

$(B The output is committed.) A build of `sparkles:ui` needs only the GLSL,
never the custom compiler; `--verify` re-derives it and diffs, and skips —
loudly, exit 0 — when that compiler is not on the machine. The compiler is
dlang.nix's `ldc-vulkan` (LDC's `sparkles/vulkan-shaders` branch: stock LDC has
no Vulkan target and no `@fragment`), and `nix run .#shader-compile` is this
tool wrapped with it and the SPIR-V tools — the one command to run. A caller
who built that LDC some other way points `$SPARKLES_SHADER_LDC` (or `--ldc`)
at it and runs `dub run :shader-compile` instead.

$(B Why a manifest of units rather than arguments.) The shader sources, their
import roots, their output directory and the flags the device build passes
are facts about this repository, and a generator that had to be told them on
every run would be told wrong eventually. They live in `shader-units.json` at
the repository root, which `sparkles:dmd-lsp` also reads, so an editor
analyzes a shader the way this tool compiles it (`TGT6`). Run it from the
repository root.
*/
module app;

import std.algorithm : canFind, filter, map, sort, startsWith, uniq;
import std.array : array, join, replace;
import std.conv : text;
import std.file : dirEntries, exists, isFile, mkdirRecurse, readText, rmdirRecurse,
    SpanMode, tempDir, write;
import std.format : format;
import std.path : baseName, buildPath, stripExtension;
import std.process : environment, execute;
import std.regex : ctRegex, matchAll, replaceAll;
import std.stdio : stderr, writefln, writeln;
import std.string : lineSplitter, strip, stripRight;

import sparkles.core_cli.args : Argument, HelpInfo, Option, parseCli, reportCliError;

/// One set of shader sources and where their GLSL goes.
struct Unit
{
    string name;          /// how the command line names it
    string[] sources;     /// D modules, compiled together (a device module is self-contained)
    string[] importPaths; /// `-I` roots
    string outDir;        /// where `<entry>.frag` and `<entry>.es.frag` land
}

/// `shader-units.json`: the repository's shader units and the device build's
/// flags. Paths are repository-relative.
struct Manifest
{
    string target;           /// `-mdcompute-targets=`
    string[] deviceVersions; /// `-d-version=`, on every unit
    string[] dflags;         /// further flags, on every unit
    Unit[] units;            ///
}

/// Parses the manifest at `path`.
Manifest loadManifest(string path = "shader-units.json")
{
    import std.json : JSONValue, parseJSON;

    static string[] strings(JSONValue v, string key)
    {
        string[] items;
        if (auto member = key in v)
            foreach (e; member.array)
                items ~= e.str;
        return items;
    }

    auto doc = parseJSON(path.readText);
    auto manifest = Manifest(doc["target"].str, strings(doc, "deviceVersions"),
        strings(doc, "dflags"));
    foreach (u; doc["units"].array)
        manifest.units ~= Unit(u["name"].str, strings(u, "sources"),
            strings(u, "importPaths"), u["outDir"].str);
    return manifest;
}

struct CliParams
{
    @(Argument("unit", description: "Which units to build (default: all). Known: effects.", optional: true))
    string[] unitNames;

    @(Option("ldc", description: "The dcompute-enabled LDC (`sparkles/vulkan-shaders`); default `$SPARKLES_SHADER_LDC`, else `ldc2` on PATH."))
    string ldc;

    @(Option("verify", description: "Regenerate into a scratch directory and diff against the committed GLSL; exit 1 on drift. Exits 0 with a notice when the compiler is unavailable, so a CI job without it neither fails nor pretends."))
    bool verify;

    @(Option("keep", description: "Keep the scratch directory (SPIR-V, disassembly) and print its path."))
    bool keep;

    @(Option("quiet", description: "Only report problems."))
    bool quiet;
}

// `dub test` builds this package as a library and takes its `main` from the
// generated `dub_test_root`, so the CLI entry point steps aside for that build.
version (unittest) {} else
int main(string[] args)
{
    auto parsed = parseCli!CliParams(args, HelpInfo("shader-compile",
        "Compile the repository's single-source D shaders to the GLSL sparkles:ui-raylib loads.", null));
    if (!parsed)
        return reportCliError(parsed.error);
    const cli = parsed.value;

    const ldc = cli.ldc.length ? cli.ldc : environment.get("SPARKLES_SHADER_LDC", "ldc2");
    if (!"shader-units.json".exists)
    {
        stderr.writeln("shader-compile: no shader-units.json here; run it from the repository root");
        return 2;
    }
    const manifest = loadManifest();
    const units = manifest.units;
    const(Unit)[] selected = cli.unitNames.length
        ? units.filter!(u => cli.unitNames.canFind(u.name)).array
        : units[];
    if (selected.length != (cli.unitNames.length ? cli.unitNames.length : units.length))
    {
        stderr.writeln("shader-compile: unknown unit; known: ", units.map!(u => u.name).join(", "));
        return 2;
    }

    int worst = 0;
    foreach (unit; selected)
    {
        const r = run(unit, manifest, ldc, cli.verify, cli.keep, cli.quiet);
        if (r > worst)
            worst = r;
    }
    return worst;
}

/// The outcome of one unit: 0 ok, 1 drift or failure, 3 toolchain absent.
int run(in Unit unit, in Manifest manifest, string ldc, bool verify, bool keep, bool quiet)
{
    const scratch = buildPath(tempDir, "sparkles-shader-compile-" ~ unit.name);
    if (scratch.exists)
        scratch.rmdirRecurse;
    scratch.mkdirRecurse;
    scope (exit)
        if (!keep && scratch.exists)
            scratch.rmdirRecurse;

    // 1. D -> SPIR-V. One invocation for the whole unit: the device module is
    //    one SPIR-V module, and it has no linker to find an import.
    // LDC names the module `<prefix>_<target without dashes>_64.spv`.
    const spv = buildPath(scratch, unit.name ~ "_" ~ manifest.target.replace("-", "") ~ "_64.spv");
    auto cmd = [ldc, "-O2", "-c", "-m64", "-mdcompute-targets=" ~ manifest.target,
        "-mdcompute-file-prefix=" ~ unit.name, "-od=" ~ scratch]
        ~ manifest.deviceVersions.map!(v => "-d-version=" ~ v).array
        ~ manifest.dflags
        ~ unit.importPaths.map!(d => "-I" ~ d).array ~ unit.sources;
    const compiled = tryExecute(cmd);
    if (compiled.status != 0)
    {
        if (isToolchainAbsent(compiled))
        {
            stderr.writefln("shader-compile: %s: skipped — no dcompute-enabled LDC (`%s`); " ~
                "use `nix run .#shader-compile`, or set $SPARKLES_SHADER_LDC to a " ~
                "`sparkles/vulkan-shaders` build. %s",
                unit.name, ldc, verify ? "The committed GLSL stands unverified." : "");
            return verify ? 0 : 3;
        }
        stderr.writeln(compiled.output);
        stderr.writefln("shader-compile: %s: LDC failed (%s)", unit.name, compiled.status);
        return 1;
    }
    if (!spv.exists)
    {
        stderr.writefln("shader-compile: %s: LDC produced no %s", unit.name, spv);
        return 1;
    }

    // 2. Validate what the compiler emitted, before anything rewrites it.
    //    Universal rules: the plain uniforms are GL's shape, not Vulkan's.
    if (!step(["spirv-val", "--target-env", "spv1.4", spv], unit.name ~ ": spirv-val"))
        return 1;

    // 3. Optimise: folds the name-string constants and dead helpers away, so
    //    the GLSL carries no `uint8_t` arrays and no Int8 extension request.
    const opt = buildPath(scratch, unit.name ~ ".opt.spv");
    if (!step(["spirv-opt", "-O", spv, "-o", opt], unit.name ~ ": spirv-opt"))
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
        stderr.writefln("shader-compile: %s: no fragment entry points in %s", unit.name, spv);
        return 1;
    }

    // 5. Cross-compile each entry to both dialects, name the sampler what
    //    raylib binds, and prove the result with glslang.
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
                stderr.writefln("shader-compile: %s/%s: spirv-cross failed", unit.name, entry);
                return 1;
            }
            // One trailing newline, exactly: the repository's end-of-file
            // hook would otherwise rewrite the file and `--verify` would
            // call its own output drift.
            const glsl = header(unit, entry)
                ~ renameCombinedSamplers(cross.output).stripRight ~ "\n";
            const name = entry ~ dialect.suffix;
            const path = buildPath(scratch, name);
            path.write(glsl);
            if (!step(["glslangValidator", path], unit.name ~ "/" ~ name ~ ": glslang"))
                return 1;
            produced[name] = glsl;
        }
    }

    // 6. Write, or compare.
    int drift = 0;
    foreach (name; produced.keys.sort)
    {
        const target = buildPath(unit.outDir, name);
        if (verify)
        {
            if (!target.exists)
            {
                stderr.writefln("shader-compile: %s: missing (not generated yet)", target);
                drift = 1;
            }
            else if (target.readText != produced[name])
            {
                stderr.writefln("shader-compile: %s: DRIFT — regenerate with `nix run .#shader-compile`", target);
                drift = 1;
            }
        }
        else
        {
            unit.outDir.mkdirRecurse;
            target.write(produced[name]);
            if (!quiet)
                writefln("shader-compile: wrote %s", target);
        }
    }
    if (verify)
    {
        // Stale files: a renamed entry point leaves its old GLSL behind.
        foreach (e; dirEntries(unit.outDir, "*.frag", SpanMode.shallow).filter!(e => e.isFile))
            if (e.name.baseName !in produced)
            {
                stderr.writefln("shader-compile: %s: stale — no entry point produces it", e.name);
                drift = 1;
            }
        if (!drift && !quiet)
            writefln("shader-compile: %s: %s entry points verified", unit.name, entries.length);
    }
    if (keep)
        writefln("shader-compile: scratch kept at %s", scratch);
    return drift;
}

private enum Dialect
{
    desktop,
    es,
}

private string[] flags(Dialect d)
    => d == Dialect.desktop ? ["--version", "330"] : ["--es", "--version", "100"];

private string suffix(Dialect d) => d == Dialect.desktop ? ".frag" : ".es.frag";

/// The provenance comment. GLSL allows comments before `#version`.
private string header(in Unit unit, string entry)
    => format("// Generated by `nix run .#shader-compile` from %s (entry point `%s`).\n" ~
            "// Do not edit: change the D source and regenerate; `--verify` guards this file.\n",
        unit.sources[$ - 1], entry);

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

private Run tryExecute(string[] cmd)
{
    try
    {
        const r = execute(cmd);
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

/// A missing binary, or a stock LDC (no Vulkan target, no `@fragment`).
private bool isToolchainAbsent(in Run r)
    => r.status == 127
    || r.output.canFind("not built with Vulkan DCompute support")
    || r.output.canFind("Unrecognised or invalid DCompute targets")
    || r.output.canFind("undefined identifier `fragment`");

@("shader-compile.manifest.repository")
@system unittest
{
    import std.path : dirName;

    // The repository's own manifest, whichever directory `dub test` runs in:
    // every path it names must exist.
    const root = __FILE_FULL_PATH__.dirName.buildPath("..", "..", "..");
    const manifest = loadManifest(root.buildPath("shader-units.json"));
    assert(manifest.target == "vulkan-130");
    assert(manifest.units.length);
    foreach (unit; manifest.units)
        foreach (path; unit.sources ~ unit.importPaths ~ [unit.outDir])
            assert(root.buildPath(path).exists, path);
}
