/**
Device code: which modules are dcompute code, and the configuration their
device side is analyzed under (spec `TGT5`–`TGT8`).

A module whose declaration carries `@compute(...)` is compiled for a GPU by
the dcompute LDC — `@compute(CompileFor.deviceOnly)` only there,
`@compute(CompileFor.hostAndDevice)` there $(I and) on the host. The device
build is not a dub build: it is one LDC invocation per shader unit, with its
own import roots and version identifiers. Those facts live in a checked-in
manifest, `shader-units.json`, which the build (`apps/shader-compile`) reads
too — so the analysis stands in for the compile that actually happens, not
for a guess at it.

```json
{
    "target": "vulkan-130",
    "dflags": ["-preview=in", "-preview=dip1000"],
    "units": [{
        "name": "effects",
        "sources": ["libs/ui/shaders/effects.d"],
        "importPaths": ["libs/shader/src", "libs/ui/src"],
        "outDir": "libs/ui/src/sparkles/ui/shaders"
    }]
}
```

Paths are relative to the manifest's directory.
*/
module sparkles.dmd_lsp.device;

import sparkles.dmd_lsp.options : AnalyzerConfig, TargetProfile;

// The `@compute` scanner is shared with `shader-compile`, which picks a
// package's device unit with it; it lives in the dependency-free vocabulary.
public import sparkles.shader.compute_mode : ComputeMode, computeModeOf;

/// A shader unit: sources compiled together into one SPIR-V module.
struct ShaderUnit
{
    string name;          /// how the build's command line names it
    string[] sources;     /// the D modules, manifest-relative
    string[] importPaths; /// `-I` roots, manifest-relative
    string outDir;        /// where the build writes its output
}

/// The parsed `shader-units.json` (see the module documentation).
struct ShaderManifest
{
    string dir;              /// absolute directory the manifest's paths are relative to
    string target;           /// the `-mdcompute-targets=` value
    string[] deviceVersions; /// `-d-version=` identifiers every device build sets
    string[] dflags;         /// further flags every device build passes
    ShaderUnit[] units;      ///

    /// The index of the unit that compiles `file` (an absolute or
    /// manifest-relative path), or -1.
    ptrdiff_t unitIndexOf(string file) const @safe
    {
        import std.path : absolutePath, buildNormalizedPath;

        const wanted = file.absolutePath(dir).buildNormalizedPath;
        foreach (i, ref unit; units)
            foreach (source; unit.sources)
                if (source.absolutePath(dir).buildNormalizedPath == wanted)
                    return i;
        return -1;
    }
}

/// The file name the manifest is looked up by.
enum shaderManifestName = "shader-units.json";

/// The nearest `shader-units.json` at or above `startPath`'s directory, or
/// null.
string findShaderManifest(string startPath) @safe
{
    import std.file : exists, isDir;
    import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;

    auto dir = startPath.absolutePath.buildNormalizedPath;
    if (!(dir.exists && dir.isDir))
        dir = dir.dirName;
    for (;;)
    {
        const candidate = dir.buildPath(shaderManifestName);
        if (candidate.exists)
            return candidate;
        const parent = dir.dirName;
        if (parent == dir)
            return null;
        dir = parent;
    }
}

/// Parses the manifest at `path`. Throws on a malformed document: a manifest
/// that silently decodes to nothing would analyze every shader as host code.
ShaderManifest loadShaderManifest(string path) @safe
{
    import std.file : readText;
    import std.json : JSONValue, parseJSON;
    import std.path : absolutePath, buildNormalizedPath, dirName;

    static string[] strings(JSONValue v, string key) @safe
    {
        string[] items;
        if (auto member = key in v)
            foreach (e; (() @trusted => member.array)())
                items ~= e.str;
        return items;
    }

    auto doc = parseJSON(path.readText);
    auto manifest = ShaderManifest(
        dir: path.absolutePath.buildNormalizedPath.dirName,
        target: doc["target"].str,
        deviceVersions: strings(doc, "deviceVersions"),
        dflags: strings(doc, "dflags"));
    foreach (u; (() @trusted => doc["units"].array)())
        manifest.units ~= ShaderUnit(
            name: u["name"].str,
            sources: strings(u, "sources"),
            importPaths: strings(u, "importPaths"),
            outDir: u["outDir"].str);
    return manifest;
}

/**
The configuration `file`'s device side is analyzed under (`TGT6`), $(I without)
the runtime import paths — append `runtimeImportPaths(profile)` as for any
other configuration.

$(LIST
    * A file one of the manifest's units compiles gets exactly that
        compile's settings: the unit's import roots, the device versions, the
        manifest's flags and its dcompute target. `host` is ignored — the
        device build is not the dub build.
    * Any other `@compute` module (or one with no manifest above it) gets
        `host` — its dub project's paths — retargeted: device versions added,
        `-unittest` dropped (a device build never compiles tests), and the
        device profile.
)
*/
AnalyzerConfig deviceConfigFor(string file, const AnalyzerConfig host) @safe
{
    import std.algorithm.iteration : filter, map;
    import std.array : array;
    import std.path : absolutePath, buildNormalizedPath;

    ShaderManifest manifest;
    if (const path = findShaderManifest(file))
        manifest = loadShaderManifest(path);

    string[] targetFlag = manifest.target.length
        ? ["-mdcompute-targets=" ~ manifest.target] : null;

    if (const i = manifest.unitIndexOf(file) + 1)
    {
        const unit = manifest.units[i - 1];
        return AnalyzerConfig(
            importPaths: unit.importPaths
                .map!(p => p.absolutePath(manifest.dir).buildNormalizedPath).array,
            versionIds: manifest.deviceVersions.dup,
            dflags: manifest.dflags ~ targetFlag,
            profile: TargetProfile.ldcDevice);
    }

    return AnalyzerConfig(
        importPaths: host.importPaths.dup,
        stringImportPaths: host.stringImportPaths.dup,
        versionIds: host.versionIds ~ manifest.deviceVersions,
        debugIds: host.debugIds.dup,
        dflags: host.dflags.filter!(f => f != "-unittest").array ~ targetFlag,
        profile: TargetProfile.ldcDevice);
}

@("dmd_lsp.device.deviceConfigFor")
@system unittest
{
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;

    auto tmp = TmpFS.create("sparkles-dmd-lsp");
    tmp.writeFileAt(shaderManifestName, `{
        "target": "vulkan-130",
        "deviceVersions": ["Device"],
        "dflags": ["-preview=in"],
        "units": [{
            "name": "fx",
            "sources": ["lib/src/fx.d", "shaders/entry.d"],
            "importPaths": ["lib/src"],
            "outDir": "out"
        }]
    }`);
    tmp.writeFileAt("shaders/entry.d", "@compute module entry;");
    tmp.writeFileAt("lib/src/other.d", "@compute module other;");

    const entry = tmp.dir.buildPath("shaders", "entry.d");
    assert(findShaderManifest(entry) == tmp.dir.buildPath(shaderManifestName));

    // In a unit: the unit's compile, whatever the host says.
    const host = AnalyzerConfig(importPaths: ["/dub/src"], versionIds: ["Host"],
        dflags: ["-unittest", "-preview=dip1000"]);
    const unitConfig = deviceConfigFor(entry, host);
    assert(unitConfig.importPaths == [tmp.dir.buildPath("lib", "src")]);
    assert(unitConfig.versionIds == ["Device"]);
    assert(unitConfig.dflags == ["-preview=in", "-mdcompute-targets=vulkan-130"]);
    assert(unitConfig.effectiveProfile == TargetProfile.ldcDevice);

    // Not in a unit: the host project, retargeted.
    const other = deviceConfigFor(tmp.dir.buildPath("lib", "src", "other.d"), host);
    assert(other.importPaths == ["/dub/src"]);
    assert(other.versionIds == ["Host", "Device"]);
    assert(other.dflags == ["-preview=dip1000", "-mdcompute-targets=vulkan-130"]);
    assert(other.profile == TargetProfile.ldcDevice);
}
