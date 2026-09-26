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

/// Where a module's code runs, from its `@compute` attribute (`TGT5`).
enum ComputeMode
{
    /// Not a `@compute` module: ordinary host code.
    none,
    /// `@compute` / `@compute(CompileFor.deviceOnly)`: compiled for the device only.
    deviceOnly,
    /// `@compute(CompileFor.hostAndDevice)`: compiled for both.
    hostAndDevice,
}

/**
The `ComputeMode` a module's declaration states.

A token-level read of the attributes before `module` — the only place D
allows them to appear there are `deprecated` and user-defined attributes — so
it needs no frontend, no globals and no lock, and costs a scan of the file's
head. A file without a module declaration is host code: `@compute` cannot
apply to it.
*/
ComputeMode computeModeOf(const(char)[] source) @safe pure nothrow @nogc
{
    auto lex = HeadLexer(source);
    auto mode = ComputeMode.none;

    for (;;)
    {
        const tok = lex.next();
        if (tok == "@")
        {
            // The attribute's name: a dotted chain whose last link names it
            // (`@compute`, `@ldc.dcompute.compute`).
            const(char)[] name;
            while (isIdentifier(lex.peek()))
            {
                name = lex.next();
                if (lex.peek() != ".")
                    break;
                lex.next();
            }
            const isCompute = name == "compute";
            if (isCompute)
                mode = ComputeMode.deviceOnly;
            if (lex.peek() == "(" && lex.skipParenthesized("hostAndDevice") && isCompute)
                mode = ComputeMode.hostAndDevice;
        }
        else if (tok == "deprecated")
        {
            if (lex.peek() == "(")
                lex.skipParenthesized(null);
        }
        else if (tok == "module")
            return mode;
        else
            return ComputeMode.none; // a declaration, or the end: no module statement
    }
}

@("dmd_lsp.device.computeModeOf")
@safe pure nothrow @nogc unittest
{
    assert(computeModeOf("module a;") == ComputeMode.none);
    assert(computeModeOf("import std.stdio; void main() {}") == ComputeMode.none);
    assert(computeModeOf("") == ComputeMode.none);

    assert(computeModeOf("@compute module a;") == ComputeMode.deviceOnly);
    assert(computeModeOf("@compute(CompileFor.deviceOnly)\nmodule effects;")
        == ComputeMode.deviceOnly);
    assert(computeModeOf("@compute(CompileFor.hostAndDevice) module a.b;")
        == ComputeMode.hostAndDevice);
    assert(computeModeOf("@ldc.dcompute.compute(ldc.dcompute.CompileFor.hostAndDevice) module a;")
        == ComputeMode.hostAndDevice);

    // Doc comments, other attributes and a shebang before the declaration.
    assert(computeModeOf(q{#!/usr/bin/env dub
        /++ The shaders. (with a /+ nested +/ comment) +/
        // @compute(CompileFor.hostAndDevice) — commented out
        deprecated("old") @("tag") @compute(CompileFor.deviceOnly) module a;
    }) == ComputeMode.deviceOnly);

    // `hostAndDevice` counts only inside `@compute`'s own arguments.
    assert(computeModeOf("@compute @Tag(hostAndDevice) module a;") == ComputeMode.deviceOnly);
    // A string argument cannot fake it either.
    assert(computeModeOf(`@("hostAndDevice") module a;`) == ComputeMode.none);
    // `@compute` on a declaration below the module is not the module's.
    assert(computeModeOf("module a; @compute void f();") == ComputeMode.none);
}

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

// A lexer over just enough of D to read the attributes before `module`:
// identifiers, punctuation, and string/character literals and comments to
// skip. Anything it does not understand ends the head.
private struct HeadLexer
{
    const(char)[] src;
    size_t pos;

    this(const(char)[] source) @safe pure nothrow @nogc
    {
        src = source;
        if (src.length >= 2 && src[0 .. 2] == "#!")
            while (pos < src.length && src[pos] != '\n')
                pos++;
    }

    const(char)[] peek() @safe pure nothrow @nogc
    {
        const saved = pos;
        const tok = next();
        pos = saved;
        return tok;
    }

    /// Skips a `(` (the next token) through its matching `)`; returns
    /// whether the identifier `needle` occurred in between.
    bool skipParenthesized(scope const(char)[] needle) @safe pure nothrow @nogc
    {
        next(); // the "("
        bool found;
        for (int depth = 1; depth > 0;)
        {
            const tok = next();
            if (!tok.length)
                break;
            if (tok == "(")
                depth++;
            else if (tok == ")")
                depth--;
            else if (needle.length && tok == needle)
                found = true;
        }
        return found;
    }

    const(char)[] next() @safe pure nothrow @nogc
    {
        skipTrivia();
        if (pos >= src.length)
            return null;

        const start = pos;
        const c = src[pos];
        if (isIdentStart(c))
        {
            // `r"…"`, `q"…"` and `x"…"` are strings, not identifiers.
            if ((c == 'r' || c == 'q' || c == 'x') && pos + 1 < src.length && src[pos + 1] == '"')
            {
                pos++;
                skipQuoted('"', c != 'r');
                return src[start .. pos];
            }
            while (pos < src.length && isIdentPart(src[pos]))
                pos++;
            return src[start .. pos];
        }
        if (c == '"' || c == '\'' || c == '`')
        {
            skipQuoted(c, c != '`');
            return src[start .. pos];
        }
        pos++;
        return src[start .. pos];
    }

    private void skipQuoted(char quote, bool escapes) @safe pure nothrow @nogc
    {
        pos++; // the opening quote
        while (pos < src.length && src[pos] != quote)
            pos += escapes && src[pos] == '\\' ? 2 : 1;
        pos++; // the closing quote
        if (pos > src.length)
            pos = src.length;
    }

    private void skipTrivia() @safe pure nothrow @nogc
    {
        while (pos < src.length)
        {
            const c = src[pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v')
                pos++;
            else if (startsAt("//"))
                while (pos < src.length && src[pos] != '\n')
                    pos++;
            else if (startsAt("/*"))
            {
                pos += 2;
                while (pos < src.length && !startsAt("*/"))
                    pos++;
                pos = pos + 2 > src.length ? src.length : pos + 2;
            }
            else if (startsAt("/+"))
            {
                pos += 2;
                for (int depth = 1; depth > 0 && pos < src.length;)
                {
                    if (startsAt("/+"))
                    {
                        depth++;
                        pos += 2;
                    }
                    else if (startsAt("+/"))
                    {
                        depth--;
                        pos += 2;
                    }
                    else
                        pos++;
                }
            }
            else
                return;
        }
    }

    private bool startsAt(string s) const @safe pure nothrow @nogc
        => pos + s.length <= src.length && src[pos .. pos + s.length] == s;
}

private bool isIdentStart(char c) @safe pure nothrow @nogc
    => c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80;

private bool isIdentPart(char c) @safe pure nothrow @nogc
    => isIdentStart(c) || (c >= '0' && c <= '9');

private bool isIdentifier(scope const(char)[] tok) @safe pure nothrow @nogc
    => tok.length && isIdentStart(tok[0]);
