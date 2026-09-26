/**
Device code: which modules are dcompute code, and the configuration their
device side is analyzed under (spec `TGT5`–`TGT8`).

A module whose declaration carries `@compute(...)` is compiled for a GPU by
the dcompute LDC — `@compute(CompileFor.deviceOnly)` only there,
`@compute(CompileFor.hostAndDevice)` there $(I and) on the host. What that
device build is, the package states in its own recipe: a $(B device
configuration), a dub configuration whose dflags name a dcompute target.

```sdl
configuration "shaders" {
    targetType "library"
    sourcePaths "src" "shaders"
    dflags "-mdcompute-targets=vulkan-130"
}
```

`shader-compile` compiles the `@compute` modules of exactly that
configuration, so describing it here makes the analysis stand in for the
compile that actually happens, not for a guess at it. It is recognized by its
flag, never by its name.
*/
module sparkles.dmd_lsp.device;

import sparkles.dmd_lsp.options : AnalyzerConfig, TargetProfile;

// The `@compute` scanner is shared with `shader-compile`, which picks a
// package's device unit with it; it lives in the dependency-free vocabulary.
public import sparkles.shader.compute_mode : ComputeMode, computeModeOf;

/// The flag that makes a configuration a device build.
enum dcomputeTargetFlag = "-mdcompute-targets=";

/// The target a `@compute` module is analyzed for when no device
/// configuration names one: the only one the repository's pipeline compiles.
enum defaultDcomputeTarget = "vulkan-130";

/**
The names of the device configurations `recipePath` declares — those whose
`dflags` carry `-mdcompute-targets=` — in declaration order. Every recipe
form is read (100 1 17 62 67 100 131 974 979 986 987 989 990 994 995 997 998MREF sparkles,dmd_lsp,recipe)); an unreadable recipe declares
none.

The recipe is read, not described: finding the configuration is what decides
which `dub describe` to run, and asking dub for every configuration to learn
which one it is would cost a describe each.
*/
string[] deviceConfigurations(string recipePath) @safe
{
    import std.algorithm.iteration : filter, map;
    import std.algorithm.searching : any, startsWith;
    import std.array : array;
    import sparkles.dmd_lsp.recipe : readDubRecipe;

    return readDubRecipe(recipePath).configurations
        .filter!(c => c.dflags.any!(f => f.startsWith(dcomputeTargetFlag)))
        .map!(c => c.name)
        .array;
}

@("dmd_lsp.device.deviceConfigurations.bothRecipeFormats")
@system unittest
{
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;

    auto tmp = TmpFS.create("sparkles-dmd-lsp-device-configs");
    tmp.writeFileAt("sdl/dub.sdl", `name "p"
// A comment, and a continued line.
dflags "-preview=in" \
    "-preview=dip1000"
configuration "library" {
    targetType "library"
}
configuration "gpu" {
    targetType "library"
    dflags "-O" "-mdcompute-targets=vulkan-130" platform="ldc"
}
configuration "also" {
    dflags "-mdcompute-targets=ocl-300"
}
`);
    tmp.writeFileAt("json/dub.json", `{"name": "p", "configurations": [
        {"name": "library"},
        {"name": "kernels", "dflags": ["-mdcompute-targets=cuda-800"]}]}`);
    tmp.writeFileAt("bad/dub.sdl", `configuration "x" {`);

    assert(deviceConfigurations(tmp.dir.buildPath("sdl", "dub.sdl")) == ["gpu", "also"]);
    assert(deviceConfigurations(tmp.dir.buildPath("json", "dub.json")) == ["kernels"]);
    assert(deviceConfigurations(tmp.dir.buildPath("bad", "dub.sdl")) is null);
    assert(deviceConfigurations(tmp.dir.buildPath("absent", "dub.sdl")) is null);
}

/**
The configuration `file`'s device side is analyzed under (`TGT6`), $(I without)
the runtime import paths — append `runtimeImportPaths(profile)` as for any
other configuration.

$(LIST
    * When the recipe governing `file` declares a device configuration, the
        answer is what `dub describe` reports for it (memoized with every
        other project context, `PRJ8`) — the settings `shader-compile`
        compiles the module with. `host` is ignored.
    * Otherwise (no recipe, no device configuration, or a describe that
        fails) `host` — its dub project's paths — is retargeted: `-unittest`
        dropped (a device build never compiles tests), the default dcompute
        target added, and the device profile.
)
*/
AnalyzerConfig deviceConfigFor(string file, const AnalyzerConfig host) @safe
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import sparkles.dmd_lsp.project : DubQuery, dubProjectFor, dubRecipeFor;

    if (const recipe = dubRecipeFor(file))
        foreach (config; deviceConfigurations(recipe))
        {
            const proj = dubProjectFor(file, DubQuery(config: config));
            if (!proj.usable)
                continue;
            return AnalyzerConfig(
                importPaths: proj.analyzer.importPaths.dup,
                stringImportPaths: proj.analyzer.stringImportPaths.dup,
                versionIds: proj.analyzer.versionIds.dup,
                debugIds: proj.analyzer.debugIds.dup,
                dflags: proj.analyzer.dflags.dup,
                profile: TargetProfile.ldcDevice);
        }

    return AnalyzerConfig(
        importPaths: host.importPaths.dup,
        stringImportPaths: host.stringImportPaths.dup,
        versionIds: host.versionIds.dup,
        debugIds: host.debugIds.dup,
        dflags: host.dflags.filter!(f => f != "-unittest").array.dup
            ~ (dcomputeTargetFlag ~ defaultDcomputeTarget),
        profile: TargetProfile.ldcDevice);
}

@("dmd_lsp.device.deviceConfigFor.retargetsTheHostWithoutADeviceConfiguration")
@system unittest
{
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;

    auto tmp = TmpFS.create("sparkles-dmd-lsp-device-retarget");
    tmp.writeFileAt("dub.sdl", "name \"p\"\n");
    tmp.writeFileAt("src/other.d", "@compute(CompileFor.hostAndDevice) module other;");

    const host = AnalyzerConfig(importPaths: ["/dub/src"], versionIds: ["Host"],
        dflags: ["-unittest", "-preview=dip1000"]);
    const other = deviceConfigFor(tmp.dir.buildPath("src", "other.d"), host);
    assert(other.importPaths == ["/dub/src"]);
    assert(other.versionIds == ["Host"]);
    assert(other.dflags == ["-preview=dip1000", "-mdcompute-targets=vulkan-130"]);
    assert(other.effectiveProfile == TargetProfile.ldcDevice);
}

@("dmd_lsp.device.deviceConfigFor.describesTheDeviceConfiguration")
@system unittest
{
    import std.algorithm.searching : any, canFind, endsWith;
    import std.file : exists;
    import std.path : buildNormalizedPath, dirName;
    import sparkles.dmd_lsp.project : clearDubProjectCache, dubTestSync;

    // The repository's own device-only module, under `sparkles:ui`'s
    // `shaders` configuration: its entry-point directory joins the sources,
    // and the target flag is what selects the device profile.
    const root = __FILE_FULL_PATH__.dirName.buildNormalizedPath("..", "..", "..", "..", "..");
    const effects = root.buildNormalizedPath("libs", "ui", "shaders", "effects.d");
    assert(effects.exists, effects);
    AnalyzerConfig cfg;
    synchronized (dubTestSync)
    {
        clearDubProjectCache();
        scope (exit) clearDubProjectCache();
        cfg = deviceConfigFor(effects, AnalyzerConfig(versionIds: ["HostOnly"]));
    }
    assert(cfg.dflags.canFind("-mdcompute-targets=vulkan-130"), cfg.dflags.toText);
    assert(!cfg.versionIds.canFind("HostOnly"));
    assert(cfg.importPaths.any!(p => p.buildNormalizedPath.endsWith("libs/shader/src")),
        cfg.importPaths.toText);
    assert(cfg.effectiveProfile == TargetProfile.ldcDevice);
}

version (unittest) private string toText(const string[] values) @safe
{
    import std.conv : to;

    return values.to!string;
}
