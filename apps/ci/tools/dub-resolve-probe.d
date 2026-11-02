#!/usr/bin/env dub
/+ dub.sdl:
    name "dub_resolve_probe"
    targetPath "build"
    dflags "-i" "-I$SPARKLES_FLAKE_INPUT_DUB_SDL_SRC/source"
    // dub needs an HTTP client to compile; std.net.curl loads libcurl only
    // when used, and resolution here never downloads.
    versions "DubUseCurl"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * dub's side of the build graph's oracle 1 (`resolve-oracle.d`): resolves
 * packages of this repository with the pinned dub, linked as a library, and
 * prints, for each request, every binary target's settings as dub hands them
 * to a generator (what `dub describe` shows), and what dub's library
 * resolution (`resolveLibs`, part of the compiler's `prepareBuildSettings`)
 * then makes of them, which `dub describe` does not show (decision D20).
 *
 * It depends on nothing of this repository: sparkles' `-preview=dip1000`
 * would reach dub's own modules through `-i`.
 *
 * The dub sources are the flake's `dub-sdl-src` input, the revision the dev
 * shell's `dub` is built from, so run it inside the dev shell. Resolution is
 * offline: it skips every package supplier, so registry dependencies must be
 * in the DUB cache the shell seeds.
 *
 * Usage (from the repository root), one `--request` per request, as
 * `<package>,<configuration>,<build type>,<test root>`:
 *
 *   dub run --single apps/ci/tools/dub-resolve-probe.d -- \
 *       [--compiler=ldc2] --out=probe.json --request=:base,,unittest,true --request=:ui,gui,checked,false
 *
 * Writes a JSON array with one object per request to `--out=<file>`.
 */
module dub_resolve_probe;

import std.algorithm : map, splitter;
import std.array : array;
import std.conv : to;
import std.file : getcwd, tempDir, write;
import std.getopt : getopt;
import std.json : JSONValue;
import std.path : buildPath;

import dub.compilers.buildsettings : BuildOption, BuildRequirement, BuildSettings;
import dub.compilers.compiler : getCompiler;
import dub.compilers.utils : resolveLibs;
import dub.dub : Dub, SkipPackageSuppliers;
import dub.generators.generator : GeneratorSettings, ProjectGenerator;
import dub.internal.logging : LogLevel, setLogLevel;
import dub.internal.vibecompat.inet.path : NativePath;
import dub.platform : BuildPlatform;
import dub.project : Project;

/// Records each target's settings as dub hands them to a generator.
final class ProbeGenerator : ProjectGenerator
{
    JSONValue targets;

    this(Project project)
    {
        super(project);
        targets = JSONValue(string[string].init);
    }

    protected override void generateTargets(GeneratorSettings settings, in TargetInfo[string] targetInfos)
    {
        foreach (name, ti; targetInfos)
        {
            BuildSettings bs = ti.buildSettings.dup;
            JSONValue target = describeFields(bs);
            target["configuration"] = ti.config;
            target["packages"] = ti.packages.map!(p => p.name).array;
            target["dependencies"] = ti.dependencies.dup;
            target["linkDependencies"] = ti.linkDependencies.dup;
            // What `dub describe` does not show: library resolution.
            auto resolved = bs.dup;
            resolveLibs(resolved, settings.platform);
            target["resolvedLibs"] = resolved.libs.dup;
            target["resolvedLflags"] = resolved.lflags.dup;
            target["resolvedDflags"] = resolved.dflags.dup;
            targets[name] = target;
        }
    }
}

JSONValue describeFields(in BuildSettings bs)
{
    JSONValue j;
    j["targetType"] = bs.targetType.to!string;
    j["targetName"] = bs.targetName;
    j["sourceFiles"] = bs.sourceFiles.dup;
    j["importPaths"] = bs.importPaths.dup;
    j["cImportPaths"] = bs.cImportPaths.dup;
    j["stringImportPaths"] = bs.stringImportPaths.dup;
    j["versions"] = bs.versions.dup;
    j["debugVersions"] = bs.debugVersions.dup;
    j["dflags"] = bs.dflags.dup;
    j["lflags"] = bs.lflags.dup;
    j["libs"] = bs.libs.dup;
    j["options"] = setMembers!BuildOption(bs.options);
    j["requirements"] = setMembers!BuildRequirement(bs.requirements);
    return j;
}

JSONValue platformJson(in BuildPlatform p)
{
    JSONValue j;
    j["platform"] = p.platform.dup;
    j["architecture"] = p.architecture.dup;
    j["compiler"] = p.compiler;
    j["compilerBinary"] = p.compilerBinary;
    j["frontendVersion"] = p.frontendVersion;
    j["compilerVersion"] = p.compilerVersion;
    return j;
}

/// Resolves one request; its result, or its error.
JSONValue probe(string package_, string config, string buildType, bool testRoot, string compilerName)
{
    JSONValue result;
    result["package"] = package_;
    result["buildType"] = buildType;
    result["testRoot"] = testRoot;
    // The test main file is only named, never written; dub keeps the real
    // cache path to itself (`Dub.cachePathDontUse` is package-private).
    const cache = buildPath(tempDir, "dub-resolve-probe-cache");
    result["cache"] = cache;
    try
    {
        auto dub = new Dub(getcwd, null, SkipPackageSuppliers.all);
        dub.loadPackage();
        if (package_.length > 1 && package_[0] == ':')
            dub.loadPackage(dub.packageManager.getSubPackage(dub.project.rootPackage, package_[1 .. $], false));

        GeneratorSettings gs;
        gs.compiler = getCompiler(compilerName);
        gs.platform = gs.compiler.determinePlatform(gs.buildSettings, compilerName, null);
        gs.buildType = buildType;
        gs.config = config;
        gs.cache = NativePath(cache);
        result["platform"] = platformJson(gs.platform);
        // As `dub test` does; no main file is written.
        if (testRoot)
            gs.config = dub.project.addTestRunnerConfiguration(gs, false);
        if (gs.config.length == 0)
            gs.config = dub.project.getDefaultConfiguration(gs.platform);
        result["configuration"] = gs.config;

        auto generator = new ProbeGenerator(dub.project);
        generator.generate(gs);
        result["targets"] = generator.targets;
    }
    // dub reports some recipe errors as assertion failures: they are
    // results here too, and the resolver must fail on them as well.
    catch (Throwable e)
        result["error"] = e.msg;
    return result;
}

int main(string[] args)
{
    string[] requests;
    string compilerName = "ldc2";
    string output;
    getopt(args, "request", &requests, "compiler", &compilerName, "out", &output);

    setLogLevel(LogLevel.error);
    JSONValue[] results;
    foreach (request; requests)
    {
        auto parts = request.splitter(',').array;
        if (parts.length != 4)
            throw new Exception("a request is <package>,<configuration>,<build type>,<test root>: " ~ request);
        results ~= probe(parts[0], parts[1], parts[2], parts[3] == "true", compilerName);
    }
    // To a file: a `preGenerateCommands` entry may print to standard output.
    write(output, JSONValue(results).toString);
    return 0;
}

/// The names of the members set in a dub `Flags!E`.
string[] setMembers(E, F)(in F flags)
{
    import std.traits : EnumMembers;

    string[] names;
    static foreach (member; EnumMembers!E)
        static if (member != 0)
            if (flags & member)
                names ~= member.to!string;
    return names;
}
