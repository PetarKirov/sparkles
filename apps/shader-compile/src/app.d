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
stamp there records the SHA-256 of the unit's modules and their packages'
recipes, so a build whose shaders are current pays a hash check and needs
neither dub nor the compiler. The stamp is a shortcut for the edit loop, not
a build system: it does not track the compiler, the tools, or a module the
unit imports without being one of its own. Output that ships is built by Nix
(`nix build .#ui-shaders`), whose inputs are all of those, and copied in
with a `prebuilt` stamp.

$(B The compiler) is `ldc2-vulkan` on `PATH` — dlang.nix's `ldc-vulkan` (LDC's
`sparkles/vulkan-shaders` branch: stock LDC has no Vulkan target and no
`@fragment`), which the dev shell and `nix run .#shader-compile` both provide
under that name — or whatever `--ldc` names.

$(B Dependency-free on purpose.) It uses Phobos and `sparkles:shaders` alone:
`sparkles:core-cli` depends on `sparkles:ui`, whose build runs this tool, so
depending on it would make the tool a prerequisite of itself.
*/
module app;

import std.algorithm : all, any, canFind, filter, find, map, sort, splitter, startsWith, uniq;
import std.ascii : isDigit;
import std.array : array, join, replace, split;
import std.conv : text, to;
import std.file : DirEntry, dirEntries, exists, FileException, isFile, mkdirRecurse, read, readText,
    remove, rmdirRecurse, SpanMode, tempDir, write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, relativePath;
import std.process : environment, execute;
import std.range : empty, front, popFront;
import std.regex : ctRegex, matchAll, replaceAll;
import std.stdio : stderr, writefln, writeln;
import std.string : chompPrefix, indexOf, lastIndexOf, lineSplitter, strip, stripRight;

import sparkles.shaders.capabilities : allProfiles, Cap, gl330, gles100, Output, Profile,
    spirvRequirements, vulkan13;
import sparkles.shaders.compute_mode : ComputeMode, computeModeOf, moduleNameOf;

/// A package's device build, as `dub describe` reports its device
/// configuration.
struct DeviceBuild
{
    string packageName;   /// the described package, e.g. `sparkles:ui`
    bool hasTarget;       /// whether dub described a target for it (none without sources, or for a `sourceLibrary`)
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
a dependency (`sparkles:shaders`'s vocabulary) belongs to the unit as much as
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
        build.hasTarget = true;
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
@("shaderCompile.unitOf.picksComputeModulesByTheirHead")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;

    // `SHP3`, without a toolchain: of the sources, the `@compute` modules,
    // and of those the device-only ones; a missing file is no member.
    const root = buildPath(tempDir, "sparkles-shader-compile-unitof-test");
    if (root.exists)
        root.rmdirRecurse;
    scope (exit) root.rmdirRecurse;
    root.mkdirRecurse;
    string mod(string name, string head)
    {
        const path = root.buildPath(name);
        path.write(head ~ "\nvoid f() {}\n");
        return path;
    }
    const entries = mod("entries.d", "@compute(CompileFor.deviceOnly) module entries;");
    const shared_ = mod("shared_.d", "@compute(CompileFor.hostAndDevice) module shared_;");
    const host = mod("host.d", "module host;");
    const unit = unitOf(DeviceBuild(sources: [entries, host, shared_, root.buildPath("gone.d")]));
    assert(unit.deviceOnly == [entries]);
    assert(unit.sources == [entries, shared_]);
}

@("shaderCompile.parseDescribe.rootSettingsAndEverySource")
@system unittest
{
    const json = `resolution chatter
    {"rootPackage": "sparkles:ui",
        "packages": [{"name": "sparkles:ui", "path": "/r/libs/ui/"},
            {"name": "sparkles:shaders", "path": "/r/libs/shaders/"}],
        "targets": [
        {"rootPackage": "sparkles:ui", "buildSettings": {
            "importPaths": ["/r/libs/ui/src/", "/r/libs/shaders/src/", "/r/libs/ui/src/"],
            "versions": ["Have_sparkles_ui"],
            "dflags": ["-preview=in", "-mdcompute-targets=vulkan-130", "-preview=in"],
            "sourceFiles": ["/r/libs/ui/shaders/effects.d", "/r/libs/ui/src/a.d"]}},
        {"rootPackage": "sparkles:shaders", "buildSettings": {
            "dflags": ["-something-else"],
            "sourceFiles": ["/r/libs/shaders/src/types.d"]}}]}`;

    const b = parseDescribe(json);
    assert(b.packageName == "sparkles:ui");
    assert(b.packageDir == "/r/libs/ui");
    assert(b.packageDirs == ["/r/libs/ui", "/r/libs/shaders"]);
    assert(b.target == "vulkan-130");
    assert(b.importPaths == ["/r/libs/ui/src/", "/r/libs/shaders/src/"]);
    assert(b.versions == ["Have_sparkles_ui"]);
    assert(b.dflags == ["-preview=in"]); // the root's, deduplicated, target split off
    assert(b.sources == ["/r/libs/ui/shaders/effects.d", "/r/libs/ui/src/a.d",
        "/r/libs/shaders/src/types.d"]);
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
        "out", "Where the generated shaders land (required): `<entry>.frag` and `<entry>.es.frag` for the OpenGL profiles, `<entry>.vert.spv` and `<entry>.frag.spv` for Vulkan.", &outDir,
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

    // Then, in this order (`SHP10`): the tools exist (3) — `dub describe`
    // itself runs the compiler; the configuration is a device build (2); the
    // unit compiles (1), or the compiler lacks the fragment stage (3, `run`).
    if (tryExecute([ldc, "--version"]).status == 127)
    {
        stderr.writefln("shader-compile: no dcompute-enabled LDC (`%s`). Enter the dev shell " ~
            "(`nix develop`), use `nix run .#shader-compile`, or pass --ldc a " ~
            "`sparkles/vulkan-shaders` build.", ldc);
        return 3;
    }
    foreach (tool; ["dub", "spirv-val", "spirv-opt", "spirv-dis", "spirv-as", "spirv-cross",
            "glslangValidator"])
        if (tryExecute([tool, "--version"]).status == 127)
        {
            stderr.writefln("shader-compile: `%s` is not on PATH. The dev shell (`nix develop`) " ~
                "and `nix run .#shader-compile` carry dub and the SPIR-V and GLSL tools.", tool);
            return 3;
        }

    // Without `$DFLAGS`: dub folds it into the dflags it reports, and it
    // tunes the host build that runs this step (`ci` adds `--threads=N`, the
    // sanitizer job `-fsanitize=address`), which the device compiler must not see.
    const described = tryExecute(["dub", "describe", "--root=" ~ packageDir,
        "--config=" ~ configuration, "--compiler=" ~ ldc], captureStderr: false,
        env: withoutHostFlags(environment.toAA));
    if (described.status != 0)
    {
        stderr.writeln(described.output);
        stderr.writefln("shader-compile: `dub describe --config=%s` failed in %s, so there is " ~
            "no device configuration to read", configuration, packageDir);
        return 2;
    }
    const build = parseDescribe(described.output);
    if (!build.hasTarget)
    {
        stderr.writefln("shader-compile: %s's configuration `%s` describes no build target: " ~
            "it has no source files, or a `targetType` that builds nothing (`sourceLibrary`)",
            build.packageName, configuration);
        return 2;
    }
    if (!build.target.length)
    {
        stderr.writefln("shader-compile: %s's configuration `%s` names no dcompute target " ~
            "(`-mdcompute-targets=`), so it is not a device build", build.packageName, configuration);
        return 2;
    }
    // The Vulkan versions dcompute accepts: one it does not would fail the
    // unit and the capability probe alike, and read as a compiler without
    // the fragment stage.
    if (!["vulkan-100", "vulkan-110", "vulkan-120", "vulkan-130", "vulkan-140"].canFind(build.target))
    {
        stderr.writefln("shader-compile: %s's configuration `%s` must name exactly one Vulkan " ~
            "target (`-mdcompute-targets=vulkan-<version>`, version 100 to 140), not `%s`",
            build.packageName, configuration, build.target);
        return 2;
    }
    const unit = unitOf(build);
    // Whether the modules declare an entry point is the manifest's to say.
    if (!unit.sources.length)
    {
        stderr.writefln("shader-compile: %s (`%s`) has no `@compute` module, so there is no " ~
            "entry point to compile", build.packageName, configuration);
        return 2;
    }
    // The stamp records the inputs as dub and the compiler read them, so one
    // edited during the run leaves a stamp that does not match it.
    return run(build, unit, hashInputs(build, unit), outDir, ldc, keep, quiet);
}

/// The outcome: 0 ok, 1 failure, 2 a unit with no entry point or an unknown
/// profile, 3 a compiler without the stages or profiles.
int run(in DeviceBuild build, in Unit unit, in string[2][] inputs, string outDir, string ldc,
    bool keep, bool quiet)
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

    const compileFlags = ["-c", "-m64", "-mdcompute-targets=" ~ build.target]
        ~ build.versions.map!(v => "-d-version=" ~ v).array
        ~ build.dflags
        ~ build.importPaths.map!(d => "-I" ~ d).array;

    // Whose failure is it? A compiler that cannot build even the smallest
    // fragment shader, or list it, for this target (a stock LDC: no Vulkan
    // target, no stages, no profiles) is a toolchain problem, whatever it said
    // about the unit.
    int failure(string what)
    {
        const probe = buildPath(scratch, "probe.d");
        probe.write(capabilityProbe);
        const manifest = buildPath(scratch, "probe.json");
        const listed = tryExecute([ldc, "-c", "-m64", "-mdcompute-targets=" ~ build.target,
            "-mdcompute-manifest=" ~ manifest, probe]);
        const probed = tryExecute([ldc, "-c", "-m64", "-mdcompute-targets=" ~ build.target,
            "-mdcompute-profile=gl330", "-mdcompute-file-prefix=probe", "-od=" ~ scratch, probe]);
        if (listed.status != 0 || probed.status != 0)
        {
            stderr.writefln("shader-compile: `%s` cannot compile a `@fragment` shader for `%s` " ~
                "by profile: it is not a dcompute-enabled LDC with the shader stages and " ~
                "profiles (`sparkles/vulkan-shaders`)", ldc, build.target);
            return 3;
        }
        stderr.writefln("shader-compile: %s: %s", build.packageName, what);
        return 1;
    }

    // 1. The manifest: every entry point, its stage and its profiles, from
    //    the declarations alone (`SHC5`).
    const manifestPath = buildPath(scratch, "manifest.json");
    const listed = tryExecute([ldc] ~ compileFlags ~ ["-mdcompute-manifest=" ~ manifestPath]
        ~ unit.sources);
    if (listed.status != 0 || !manifestPath.exists)
    {
        stderr.writeln(listed.output);
        return failure("LDC could not list the unit's entry points");
    }
    const entries = parseManifest(manifestPath.readText);
    if (!entries.length)
    {
        stderr.writefln("shader-compile: %s: the unit declares no `@fragment` or `@vertex` " ~
            "entry point", build.packageName);
        return 2;
    }
    foreach (e; entries)
        foreach (p; e.profiles)
            if (!knownProfile(p))
            {
                stderr.writefln("shader-compile: %s: entry point `%s` names the profile `%s`, " ~
                    "which is not a shader profile; the profiles are %-(`%s`%|, %)",
                    build.packageName, e.name, p, allProfiles.map!(q => q.name));
                return 2;
            }
    foreach (e; entries)
        foreach (p; e.profiles)
            if (!grantsStage(profileByName(p), e.stage))
            {
                stderr.writefln("shader-compile: %s: entry point `%s` is a %s shader, which the " ~
                    "profile `%s` does not offer", build.packageName, e.name, e.stage, p);
                return 1;
            }

    // 2. One compilation per profile, in the table's order, each compiled,
    //    validated, audited and translated before the next begins (`SHP10`);
    //    nothing is written until all of them have succeeded (`SHP8`).
    const files = moduleFiles(unit);
    string origin(in ManifestEntry e) => header(build, unit, files.get(e.module_, e.module_), e.name);
    string[string] produced; // relative file name -> contents
    foreach (profile; allProfiles)
    {
        if (profile.output == Output.host || !entries.any!(e => e.profiles.canFind(profile.name)))
            continue;
        const pname = profile.name;
        const dir = buildPath(scratch, pname);
        dir.mkdirRecurse;
        const prefix = "unit";
        const spv = buildPath(dir, prefix ~ "_" ~ build.target.replace("-", "") ~ "_64.spv");
        const compiled = tryExecute([ldc, "-O2"] ~ compileFlags
            ~ profileFlags(profile) ~ ["-mdcompute-file-prefix=" ~ prefix, "-od=" ~ dir]
            ~ unit.sources);
        if (compiled.status != 0)
        {
            stderr.writeln(compiled.output);
            return failure(format("LDC failed for the profile `%s` (%s)", pname, compiled.status));
        }
        if (!spv.exists)
        {
            stderr.writefln("shader-compile: %s: LDC produced no %s", build.packageName, spv);
            return 1;
        }

        // Validate what the compiler emitted, before anything rewrites it,
        // under the rules of what consumes it (`SHP4`): Vulkan's for a Vulkan
        // profile, the universal ones for the GL profiles' plain uniforms.
        const env = profile.output == Output.spirv ? vulkanEnv(profile) : "spv1.6";
        if (!step(["spirv-val", "--target-env", env, spv], name ~ " (" ~ pname ~ "): spirv-val"))
            return 1;

        // Optimise: folds the name-string constants and dead helpers away, so
        // the GLSL carries no `uint8_t` arrays and no Int8 extension request.
        const opt = buildPath(dir, prefix ~ ".opt.spv");
        if (!step(["spirv-opt", "-O", spv, "-o", opt], name ~ " (" ~ pname ~ "): spirv-opt"))
            return 1;
        const dis = tryExecute(["spirv-dis", opt]);
        if (dis.status != 0)
        {
            stderr.writeln(dis.output);
            return 1;
        }
        const mine = entries.filter!(e => e.profiles.canFind(pname)).array;
        if (const why = audit(dis.output, profile))
        {
            stderr.writefln("shader-compile: %s (%s): %s, in the module of %-(`%s`%|, %)",
                name, pname, why, mine.map!(e => e.name));
            // Where the module computes in 64 bits, the compiler names the D
            // lines (`SHM6`): the disassembly has none to give.
            if (why.canFind("`OpCapability Int64`"))
            {
                const lines = tryExecute([ldc] ~ compileFlags ~ profileFlags(profile)
                    ~ ["-mdcompute-report-int64", "-mdcompute-file-prefix=report",
                    "-od=" ~ buildPath(dir, "report")] ~ unit.sources);
                stderr.write(lines.output);
            }
            return 1;
        }

        foreach (e; mine)
        {
            const file = outputFile(profile, e);
            const path = buildPath(dir, file);
            if (profile.output == Output.spirv)
            {
                // One entry point per module (`SHP5`), its provenance in an
                // `OpModuleProcessed` (`SHP7`).
                const text = singleEntry(dis.output, e.name, origin(e));
                const asm_ = buildPath(dir, e.name ~ ".spvasm");
                asm_.write(text);
                const assembled = buildPath(dir, e.name ~ ".asm.spv");
                if (!step(["spirv-as", "--target-env", env, asm_, "-o", assembled],
                        name ~ "/" ~ file ~ ": spirv-as")
                    || !step(["spirv-opt", "--eliminate-dead-functions",
                        "--eliminate-dead-code-aggressive", "--remove-unused-interface-variables",
                        assembled, "-o", path], name ~ "/" ~ file ~ ": spirv-opt")
                    || !step(["spirv-val", "--target-env", env, path], name ~ "/" ~ file ~ ": spirv-val"))
                    return 1;
                const single = tryExecute(["spirv-dis", path]);
                if (const why = single.status == 0 ? audit(single.output, profile) : single.output)
                {
                    stderr.writefln("shader-compile: %s/%s: %s", name, file, why);
                    return 1;
                }
                produced[file] = cast(string) read(path);
            }
            else
            {
                // Translate to the profile's GLSL, name the sampler what raylib
                // binds, and prove the result with glslang.
                auto cross = tryExecute(["spirv-cross", "--entry", e.name, "--stage", "frag",
                    "--remove-unused-variables"] ~ glslFlags(profile) ~ [opt]);
                if (cross.status != 0)
                {
                    stderr.writeln(cross.output);
                    stderr.writefln("shader-compile: %s/%s: spirv-cross failed", name, e.name);
                    return 1;
                }
                // One trailing newline, exactly, as every text file here has.
                const glsl = origin(e)
                    ~ renameCombinedSamplers(cross.output).stripRight ~ "\n";
                path.write(glsl);
                if (!step(["glslangValidator", path], name ~ "/" ~ file ~ ": glslang"))
                    return 1;
                produced[file] = glsl;
            }
        }
    }

    // 3. Write. Each file lands by rename, so a concurrent build reading the
    //    directory sees an old file or a new one, never half of one; the
    //    stamp goes last, so it never vouches for output not yet written.
    outDir.mkdirRecurse;
    foreach (file; produced.keys.sort)
    {
        writeAtomically(buildPath(outDir, file), produced[file]);
        if (!quiet)
            writefln("shader-compile: wrote %s", buildPath(outDir, file));
    }
    // A renamed entry point leaves its old output behind; the directory is
    // this tool's, so it goes.
    foreach (pattern; ["*.frag", "*.vert", "*.spv"])
        foreach (e; dirEntries(outDir, pattern, SpanMode.shallow).filter!stillAFile.array)
            if (e.name.baseName !in produced)
                removeIfThere(e.name);
    // So does a temporary a killed run left (`<file>.tmp-<pid>`, as
    // `writeAtomically` names them): one whose process is gone. A live
    // process's is a concurrent run's file about to be renamed, and a file
    // only resembling a temporary is not this tool's.
    foreach (e; dirEntries(outDir, "*.tmp-*", SpanMode.shallow).filter!stillAFile.array)
    {
        const pid = e.name[e.name.lastIndexOf(".tmp-") + ".tmp-".length .. $];
        if (pid.length && pid.all!isDigit && !isRunning(pid))
            removeIfThere(e.name);
    }
    writeAtomically(buildPath(outDir, stampName), stampFor(inputs, produced.keys.sort.array));
    if (keep)
        writefln("shader-compile: scratch kept at %s", scratch);
    return 0;
}

// Concurrent runs share the directory (`SHB7`): between listing it and
// looking at an entry, another run may have renamed its temporary into place
// or removed the same stale file. An entry that is gone needs no cleanup.
private bool stillAFile(DirEntry e)
{
    try
        return e.isFile;
    catch (FileException)
        return false;
}

/// ditto
private void removeIfThere(string path)
{
    try
        path.remove;
    catch (FileException x)
        if (path.exists)
            throw x;
}

/// Whether `pid`, a decimal process id, names a running process in this
/// process's PID namespace. A writer in another namespace (a container
/// sharing the output directory) looks gone: concurrent runs are assumed to
/// share one (`SHP8`). Where it cannot tell (not POSIX, an id out of range),
/// it says yes, and the temporary stays.
private bool isRunning(in char[] pid)
{
    import std.conv : ConvException, to;

    version (Posix)
    {
        import core.stdc.errno : errno, ESRCH;
        import core.sys.posix.signal : kill;

        try
            return kill(pid.to!int, 0) == 0 || errno != ESRCH;
        catch (ConvException)
            return true;
    }
    else
        return true;
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
The inputs a stamp records, each as its SHA-256 and its path: the unit's
modules, and the recipe of each package that contributes one (flags,
versions and the device target live there). Paths are relative to the
package, so a checkout moved elsewhere stays fresh.
*/
string[2][] hashInputs(in DeviceBuild build, in Unit unit)
{
    string[2][] hashed;
    foreach (input; stampInputs(build, unit))
        hashed ~= [sha256Of(input), input.relativePath(build.packageDir)];
    return hashed;
}

/**
The stamp for output generated from `inputs` (`hashInputs`, taken before
compiling): those inputs, then the files produced.

A packager that supplies the output prebuilt (a Nix derivation) writes the
single line `prebuilt` instead, which is always fresh.
*/
string stampFor(in string[2][] inputs, in string[] outputs)
{
    string s = stampVersion ~ "\n";
    foreach (input; inputs)
        s ~= "input " ~ input[0] ~ " " ~ input[1] ~ "\n";
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
    auto lines = stampPath.readText.lineSplitter.array;
    while (lines.length && !lines[$ - 1].strip.length)
        lines = lines[0 .. $ - 1];
    if (lines.length == 1 && lines[0] == "prebuilt")
        return true;
    if (!lines.length || lines[0] != stampVersion)
        return false;
    const pkg = packageDir.absolutePath.buildNormalizedPath;
    size_t inputs, outputs;
    foreach (line; lines[1 .. $])
    {
        if (auto input = line.findSplit(" ")[2].findSplit(" "))
            if (line.startsWith("input "))
            {
                const path = pkg.buildPath(input[2]).buildNormalizedPath;
                if (!path.exists || sha256Of(path) != input[0])
                    return false;
                inputs++;
                continue;
            }
        if (!line.startsWith("output "))
            return false; // a line the format does not have: not a stamp this tool wrote
        if (!buildPath(outDir, line["output ".length .. $]).exists)
            return false;
        outputs++;
    }
    // A run records at least one input (a module of the unit) and one output.
    return inputs > 0 && outputs > 0;
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
    out_.buildPath(stampName).write(stampFor(hashInputs(build, unit), ["fx.frag"]));
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
    out_.buildPath(stampName).write("prebuilt\n\n");
    assert(isFresh(out_, pkg), "trailing blank lines do not change it");
    out_.buildPath(stampName).write("shader-compile stamp 0\n");
    assert(!isFresh(out_, pkg), "another tool version's stamp");
    // A stamp with a line the format does not have is not one this tool
    // wrote, and so is no evidence; nor is a version line alone with a
    // corrupted input line.
    out_.buildPath("fx.frag").write("glsl");
    out_.buildPath(stampName).write(stampFor(hashInputs(build, unit), ["fx.frag"]) ~ "garbage\n");
    assert(!isFresh(out_, pkg), "an unknown line");
    out_.buildPath(stampName).write(stampVersion ~ "\ninput deadbeef\n");
    assert(!isFresh(out_, pkg), "a malformed input line");
    out_.buildPath(stampName).write(stampVersion ~ "\n");
    assert(!isFresh(out_, pkg), "a version line alone vouches for nothing");
    out_.buildPath(stampName).write(stampVersion ~ "\noutput fx.frag\n");
    assert(!isFresh(out_, pkg), "outputs with no inputs");
    out_.buildPath(stampName).write(stampFor(hashInputs(build, unit), []));
    assert(!isFresh(out_, pkg), "inputs with no outputs");

    // A contributing dependency's recipe is an input too.
    out_.buildPath(stampName).write(stampFor(hashInputs(build, unit), ["fx.frag"]));
    assert(isFresh(out_, pkg));
    dep.buildPath("dub.sdl").write(`name "shader" // new flags`);
    assert(!isFresh(out_, pkg), "a dependency's recipe changed");
}

/**
The provenance comment of the file generated for `entry`, declared in the
module `file` (`SHP7`). GLSL allows comments before `#version`. It names the
unit's device-only modules and, if it is not one of them, the entry point's
own module, relative to the package, so the bytes do not depend on where the
tool ran from.
*/
string header(in DeviceBuild build, in Unit unit, string file, string entry)
{
    auto modules = unit.deviceOnly.dup;
    if (!modules.canFind(file))
        modules ~= file;
    const names = modules
        .map!(m => m.absolutePath.relativePath(build.packageDir.absolutePath))
        .join(", ");
    return "// Generated by shader-compile from " ~ build.packageName ~ "'s " ~ names
        ~ " (entry point `" ~ entry ~ "`).\n"
        ~ "// Do not edit: it is regenerated from the D source whenever that changes.\n";
}

/// The file of each module of `unit`, by the name its declaration gives it:
/// how an entry point the manifest lists by module is traced to its source.
string[string] moduleFiles(in Unit unit)
{
    string[string] files;
    foreach (source; unit.sources)
        if (const name = moduleNameOf(source.readText))
            files[name.idup] = source;
    return files;
}

///
@("shaderCompile.header.namesTheEntryModulesRelativeToTheirPackage")
@system unittest
{
    // The package as `dub describe --root=libs/ui` names it: by its recipe.
    const build = DeviceBuild(packageName: "ui", packageDir: "/r/libs/ui");
    const unit = Unit(deviceOnly: ["/r/libs/ui/shaders/effects.d", "/r/libs/ui/shaders/more.d"]);
    assert(header(build, unit, "/r/libs/ui/shaders/effects.d", "dim") ==
        "// Generated by shader-compile from ui's shaders/effects.d, shaders/more.d " ~
        "(entry point `dim`).\n" ~
        "// Do not edit: it is regenerated from the D source whenever that changes.\n");
    // An entry point in a host-and-device module adds its module.
    assert(header(build, Unit.init, "/r/libs/ui/src/tri.d", "tri") ==
        "// Generated by shader-compile from ui's src/tri.d (entry point `tri`).\n" ~
        "// Do not edit: it is regenerated from the D source whenever that changes.\n");
}

/// An entry point of the unit, as the compiler's manifest lists it.
struct ManifestEntry
{
    string name;       /// the D function's name
    string stage;      /// `vertex` or `fragment`
    string module_;    /// the module that declares it
    string[] profiles; /// the names of its profiles, sorted
}

/// The entry points of a manifest (`-mdcompute-manifest`).
ManifestEntry[] parseManifest(string json)
{
    import std.json : parseJSON;

    ManifestEntry[] r;
    foreach (e; parseJSON(json)["entryPoints"].array)
        r ~= ManifestEntry(e["name"].str, e["stage"].str, e["module"].str,
            e["profiles"].array.map!(p => p.str).array);
    return r;
}

///
@("shaderCompile.parseManifest.readsEntriesStagesAndProfiles")
@system unittest
{
    const m = parseManifest(`{"entryPoints":[{"name":"tri","stage":"vertex","module":"fx",` ~
        `"profiles":["vulkan1.3"]},{"name":"dim","stage":"fragment","module":"fx",` ~
        `"profiles":["gl330","gles100"]}]}`);
    assert(m == [ManifestEntry("tri", "vertex", "fx", ["vulkan1.3"]),
        ManifestEntry("dim", "fragment", "fx", ["gl330", "gles100"])]);
    assert(parseManifest(`{"entryPoints":[]}`) == []);
}

/// Whether `name` is a profile of the table.
bool knownProfile(string name) => allProfiles.any!(p => p.name == name);

/// The profile of the table named `name`, which must be one.
Profile profileByName(string name) => allProfiles.find!(p => p.name == name).front;

/// Whether `p` offers the stage a manifest names (`vertex`, `fragment`).
bool grantsStage(in Profile p, string stage)
    => p.caps.has(stage == "vertex" ? Cap.vertexStage : Cap.fragmentStage);

/// The file the build step writes for `e` under `p` (`SHC2`).
string outputFile(in Profile p, in ManifestEntry e)
{
    final switch (p.output)
    {
    case Output.glsl:
        return e.name ~ ".frag";
    case Output.glslEs:
        return e.name ~ ".es.frag";
    case Output.spirv:
        return e.name ~ (e.stage == "vertex" ? ".vert.spv" : ".frag.spv");
    case Output.host:
        assert(0, "the host profile writes no files");
    }
}

///
@("shaderCompile.outputFile.followsTheProfileTable")
@system unittest
{
    const tri = ManifestEntry("tri", "vertex"), dim = ManifestEntry("dim", "fragment");
    assert(outputFile(gl330, dim) == "dim.frag");
    assert(outputFile(gles100, dim) == "dim.es.frag");
    assert(outputFile(vulkan13, tri) == "tri.vert.spv");
    assert(outputFile(vulkan13, dim) == "dim.frag.spv");
}

private string[] glslFlags(in Profile p)
    => p.output == Output.glsl ? ["--version", p.version_.to!string]
        : ["--es", "--version", p.version_.to!string];

/**
The flags that compile the unit for `p`: the profile's name and the
capabilities it grants, closed under their implications
(`-capabilities=shader:…`, `SHC3`). The compiler knows each capability's
meaning and enforces it (the resources' lowering, the stages, integer
vertex inputs); which profile grants what is this table's.
*/
string[] profileFlags(in Profile p)
{
    string[] granted;
    static foreach (name; __traits(allMembers, Cap))
        if (p.caps.has(__traits(getMember, Cap, name)))
            granted ~= name;
    return ["-mdcompute-profile=" ~ p.name, "-capabilities=shader:" ~ granted.join(",")];
}

///
@("shaderCompile.profileFlags.passTheProfileAndWhatItGrants")
unittest
{
    assert(profileFlags(vulkan13) == ["-mdcompute-profile=vulkan1.3",
        "-capabilities=shader:shader,vertexStage,fragmentStage,uniformBlocks,pushConstants,"
        ~ "sampledImages,intVertexInputs,derivatives,derivativeControl,demote"]);
    assert(profileFlags(gl330) == ["-mdcompute-profile=gl330",
        "-capabilities=shader:shader,fragmentStage,looseUniforms,sampledImages,derivatives"]);
    assert(profileFlags(gles100) == ["-mdcompute-profile=gles100",
        "-capabilities=shader:shader,fragmentStage,looseUniforms,sampledImages"]);
}

/// spirv-val's environment for a Vulkan profile: `vulkan1.3`.
private string vulkanEnv(in Profile p) => format("vulkan%s.%s", p.version_ / 10, p.version_ % 10);

/**
Why the module `disassembly` may not be emitted for `p`, or null (`SHC9`):
every `OpCapability` and `OpExtension` it declares must belong, by the
table's mapping, to a capability `p` grants. One the mapping does not list
fails too.
*/
string audit(string disassembly, in Profile p)
{
    foreach (line; disassembly.lineSplitter)
    {
        auto words = line.strip.splitter(' ');
        if (words.empty)
            continue;
        const op = words.front;
        if (op != "OpCapability" && op != "OpExtension")
            continue;
        words.popFront;
        if (words.empty)
            continue;
        const what = words.front.strip(`"`);
        const known = spirvRequirements.find!(r => r.spirv == what);
        if (known.empty)
            return format("the module declares `%s %s`, which no shader capability maps", op, what);
        if (!p.caps.has(known.front.capability))
            return format("the module declares `%s %s`, which needs `%s`, a capability the " ~
                "profile `%s` does not grant", op, what, known.front.capability, p.name);
    }
    return null;
}

///
@("shaderCompile.audit.rejectsWhatTheProfileDoesNotGrant")
@system unittest
{
    const ok = "OpCapability Shader\nOpMemoryModel Logical GLSL450\n";
    assert(audit(ok, vulkan13) is null);
    assert(audit(ok ~ "OpCapability Int64\n", vulkan13).canFind("`int64`"));
    assert(audit("OpCapability Shader\nOpCapability Geometry\n", vulkan13)
        .canFind("no shader capability maps"));
    assert(audit("OpExtension \"SPV_KHR_physical_storage_buffer\"\n", vulkan13)
        .canFind("`bufferDeviceAddress`"));
}

/**
The module of `disassembly` with `entry` its only entry point, and `origin`
recorded as `OpModuleProcessed` lines: the other entry points and their
execution modes go, and an optimiser then drops what only they used.
*/
string singleEntry(string disassembly, string entry, string origin)
{
    string[] dropped; // the ids of the other entry points
    foreach (line; disassembly.lineSplitter)
    {
        const l = line.strip;
        if (!l.startsWith("OpEntryPoint "))
            continue;
        const words = l.split(' ');
        if (words.length >= 4 && words[3] != `"` ~ entry ~ `"`)
            dropped ~= words[2];
    }
    string r;
    bool processed;
    foreach (line; disassembly.lineSplitter)
    {
        const l = line.strip;
        if (l.startsWith("OpEntryPoint ") || l.startsWith("OpExecutionMode "))
        {
            const words = l.split(' ');
            const id = l.startsWith("OpEntryPoint ") ? words[2] : words[1];
            if (dropped.canFind(id))
                continue;
        }
        // Debug instructions end where the annotations begin.
        if (!processed && (l.startsWith("OpDecorate") || l.startsWith("OpMemberDecorate")
                || l.startsWith("OpType")))
        {
            foreach (o; origin.lineSplitter)
                r ~= `OpModuleProcessed "` ~ o.chompPrefix("// ") ~ "\"\n";
            processed = true;
        }
        r ~= line ~ "\n";
    }
    return r;
}

///
@("shaderCompile.singleEntry.keepsOneEntryPointAndRecordsItsOrigin")
@system unittest
{
    const dis = "OpCapability Shader\n" ~
        `OpEntryPoint Vertex %tri "tri" %pos` ~ "\n" ~
        `OpEntryPoint Fragment %shade "shade" %colour` ~ "\n" ~
        "OpExecutionMode %shade OriginUpperLeft\n" ~
        `OpName %tri "tri"` ~ "\n" ~
        "OpDecorate %pos Location 0\n";
    assert(singleEntry(dis, "tri", "// from fx\n// do not edit\n") ==
        "OpCapability Shader\n" ~
        `OpEntryPoint Vertex %tri "tri" %pos` ~ "\n" ~
        `OpName %tri "tri"` ~ "\n" ~
        `OpModuleProcessed "from fx"` ~ "\n" ~
        `OpModuleProcessed "do not edit"` ~ "\n" ~
        "OpDecorate %pos Location 0\n");
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

/// `env` without the variables that tune the host build — the device build
/// described from it must come from the recipe alone.
string[string] withoutHostFlags(string[string] env)
{
    env.remove("DFLAGS");
    return env;
}

///
@("shaderCompile.withoutHostFlags.dropsDflagsOnly")
@system unittest
{
    auto env = withoutHostFlags(["DFLAGS": "--threads=3", "PATH": "/bin", "HOME": "/h"]);
    assert("DFLAGS" !in env);
    assert(env == ["PATH": "/bin", "HOME": "/h"]);
}

private struct Run
{
    int status;
    string output;
}

private Run tryExecute(string[] cmd, bool captureStderr = true,
    const string[string] env = null)
{
    import std.process : Config;

    // A given environment replaces the inherited one outright (`newEnv`), so a
    // variable it leaves out is unset in the child rather than inherited.
    auto config = (captureStderr ? Config.none : Config.stderrPassThrough)
        | (env !is null ? Config.newEnv : Config.none);
    try
    {
        const r = execute(cmd, env, config);
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

/// The smallest fragment shader: what a compiler that can build the unit
/// must be able to build.
private enum capabilityProbe = `@compute(CompileFor.deviceOnly) module probe;
import ldc.dcompute;
@fragment __vector(float[4]) probe(@input __vector(float[4]) c) { return c; }
`;
