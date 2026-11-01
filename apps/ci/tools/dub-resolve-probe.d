#!/usr/bin/env dub
/+ dub.sdl:
    name "dub_resolve_probe"
    dflags "-i" "-I$SPARKLES_FLAKE_INPUT_DUB_SDL_SRC/source"
    // dub needs an HTTP client to compile; std.net.curl loads libcurl only
    // when used, and resolution here never downloads.
    versions "DubUseCurl"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Resolves a package of this repository with the pinned dub, linked as a
 * library, and prints what `dub describe` does not: each target's compiler
 * and linker arguments after dub's own final step (`setTarget` and the
 * compiler's `prepareBuildSettings`), which turns build options into flags,
 * runs `pkg-config`, and adds the target flags.
 *
 * The dub sources are the flake's `dub-sdl-src` input, the revision the dev
 * shell's `dub` is built from, so run it inside the dev shell. Resolution is
 * offline: it skips every package supplier, so registry dependencies must be
 * in the DUB cache the shell seeds.
 *
 * Usage (from the repository root):
 *
 *   dub run --single apps/ci/tools/dub-resolve-probe.d -- \
 *       [--package=:base] [--config=unittest] [--build=unittest] [--compiler=ldc2]
 */
module dub_resolve_probe;

import std.algorithm : canFind, filter, map, startsWith;
import std.array : array;
import std.conv : to;
import std.getopt : getopt;
import std.json : JSONValue;
import std.file : tempDir;
import std.path : buildPath;
import std.stdio : writeln;

import dub.compilers.buildsettings : BuildOption, BuildRequirement, BuildSetting, BuildSettings,
    TargetType;
import dub.compilers.compiler : getCompiler;
import dub.compilers.utils : isLinkerFile;
import dub.dub : Dub, SkipPackageSuppliers;
import dub.generators.generator : GeneratorSettings, ProjectGenerator;
import dub.internal.logging : LogLevel, setLogLevel;
import dub.internal.vibecompat.inet.path : NativePath;
import dub.project : Project;

/// Records each target's settings at the two stages dub reaches.
final class ProbeGenerator : ProjectGenerator
{
    JSONValue[] targets;

    this(Project project)
    {
        super(project);
    }

    protected override void generateTargets(GeneratorSettings settings, in TargetInfo[string] targetInfos)
    {
        foreach (name, ti; targetInfos)
        {
            BuildSettings bs = ti.buildSettings.dup;
            JSONValue target;
            target["package"] = name;
            target["configuration"] = ti.config;
            target["packages"] = ti.packages.map!(p => p.name).array;
            target["linkDependencies"] = ti.linkDependencies.dup;
            target["targetType"] = bs.targetType.to!string;
            // What `dub describe` shows (TargetDescription.buildSettings).
            target["describe"] = describeFields(bs);
            // What it does not: the arguments of the build generator's step.
            target["final"] = finalArguments(bs, settings);
            targets ~= target;
        }
    }
}

JSONValue describeFields(in BuildSettings bs)
{
    JSONValue j;
    j["dflags"] = bs.dflags.dup;
    j["lflags"] = bs.lflags.dup;
    j["libs"] = bs.libs.dup;
    j["versions"] = bs.versions.dup;
    j["debugVersions"] = bs.debugVersions.dup;
    j["importPaths"] = bs.importPaths.dup;
    j["cImportPaths"] = bs.cImportPaths.dup;
    j["stringImportPaths"] = bs.stringImportPaths.dup;
    j["sourceFiles"] = bs.sourceFiles.length;
    j["options"] = setMembers!BuildOption(bs.options);
    j["requirements"] = setMembers!BuildRequirement(bs.requirements);
    return j;
}

/* Mirrors dub.generators.build.BuildGenerator.buildWithCompiler: a library is
    compiled and archived in one invocation; an executable is compiled to an
    object, with the `-P` flags of `pkg-config --cflags`, and linked apart.
 */
JSONValue finalArguments(BuildSettings bs, GeneratorSettings gs)
{
    const isLibrary = bs.targetType == TargetType.library || bs.targetType == TargetType.staticLibrary;
    JSONValue j;
    if (isLibrary)
    {
        bs.sourceFiles = bs.sourceFiles.filter!(f => !isLinkerFile(gs.platform, f)).array;
        gs.compiler.setTarget(bs, gs.platform);
        gs.compiler.prepareBuildSettings(bs, gs.platform, BuildSetting.commandLine);
        j["compile"] = withoutSources(bs.dflags);
        return j;
    }

    auto link = bs;
    link.sourceFiles = link.sourceFiles.filter!(f => isLinkerFile(gs.platform, f)).array;
    gs.compiler.setTarget(link, gs.platform);
    gs.compiler.prepareBuildSettings(link, gs.platform, BuildSetting.commandLineSeparate | BuildSetting.sourceFiles);
    foreach (flag; link.dflags.filter!(f => f.startsWith("-P")))
        bs.addDFlags(flag);
    bs.libs = null;
    bs.frameworks = null;
    bs.lflags = null;
    bs.addDFlags("-c", "-of" ~ bs.targetName ~ ".o");
    bs.sourceFiles = bs.sourceFiles.filter!(f => !isLinkerFile(gs.platform, f)).array;
    gs.compiler.prepareBuildSettings(bs, gs.platform, BuildSetting.commandLine);
    j["compile"] = withoutSources(bs.dflags);
    j["link"] = link.lflags.dup;
    j["linkDflags"] = link.dflags.dup;
    return j;
}

/// The source files are many and `dub describe` lists them already.
string[] withoutSources(string[] args)
{
    import std.path : extension;

    return args.filter!(a => ![".d", ".di", ".c", ".i"].canFind(a.extension) || a.startsWith("-")).array;
}


int main(string[] args)
{
    string packageName = ":base";
    string config = "unittest";
    string buildType = "unittest";
    string compilerName = "ldc2";
    getopt(args, "package", &packageName, "config", &config, "build", &buildType,
        "compiler", &compilerName);

    setLogLevel(LogLevel.warn);
    auto dub = new Dub(".", null, SkipPackageSuppliers.all);
    dub.loadPackage();
    if (packageName.startsWith(":"))
        dub.loadPackage(dub.packageManager.getSubPackage(dub.project.rootPackage, packageName[1 .. $], false));

    GeneratorSettings gs;
    gs.compiler = getCompiler(compilerName);
    gs.platform = gs.compiler.determinePlatform(gs.buildSettings, compilerName, null);
    gs.buildType = buildType;
    gs.config = config;
    // Only names the test main file, which is not written; dub keeps the real
    // cache path to itself (`Dub.cachePathDontUse` is package-private).
    gs.cache = NativePath(buildPath(tempDir, "dub-resolve-probe-cache"));
    if (config == "unittest")
    {
        // As `dub test` and `dub describe --config=unittest` do; no main file
        // is written.
        if (const testConfig = dub.project.addTestRunnerConfiguration(gs, false))
            gs.config = testConfig;
    }

    auto generator = new ProbeGenerator(dub.project);
    generator.generate(gs);

    JSONValue result;
    result["package"] = packageName;
    result["configuration"] = gs.config;
    result["buildType"] = buildType;
    result["targets"] = generator.targets;
    writeln(result.toPrettyString);
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
