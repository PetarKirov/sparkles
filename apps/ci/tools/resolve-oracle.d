#!/usr/bin/env dub
/+ dub.sdl:
    name "resolve_oracle"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:wired" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Oracle 1 of the build graph (build-graph `testing.md`, SPEC BGR7): resolves
every request the repository's commands make with the pinned dub and with
`sparkles.build_primitives.resolve`, and reports every resolved field on which
the two disagree.

dub's side is `dub-resolve-probe.d`, which links the pinned dub as a library
and is run as its own process (sparkles' preview flags would reach dub's
modules otherwise). Build it first:
---
dub build --single apps/ci/tools/dub-resolve-probe.d -b checked
---

For each in-repo package the requests are:
$(LIST
    * its test root (`dub test`: the `unittest` build type and dub's
        generated test configuration);
    * its default configuration under the `checked` build type;
    * each configuration of it that some recipe selects with
        `subConfiguration`, under `checked`.
)
and every single-file package `ci` runs is one request under `debug`, as
`ci` runs it: each example `ci --example-files` runs, and each fence of a
tracked Markdown file `ci --verify` runs. dub reads a fence as `ci` hands it
over, its in-tree dependencies by version rewritten to paths; the resolver
reads it as written, with its in-tree rewrite (BGR6).
Every binary target of each request is compared: source files, import, C
import and string import paths, versions, debug versions, dflags, lflags,
libraries, target type and name, build options and requirements, as dub
hands them to a generator (what `dub describe` reports), and then the
result of library resolution (which it cannot show: decision D20).

Paths are compared normalized, with a registry package's directory written
as `<registry>/<name>/<version>/<name>`, since dub reads it from its package
cache and the resolver from the flake's `dub-sources`. dub's generated test
main file, which the resolver leaves to the test-root generator, is left out.
A library target's own `pkg-config --cflags` are D17's recorded divergence and
are left out of the resolver's side.

Each accepted disagreement is listed in $(LREF accepted) with the decision
that accepts it.

Usage (from the repository root, inside the dev shell):
---
dub run --single apps/ci/tools/resolve-oracle.d -- [--package=:base]… [--single-file=<file.d>]…
    [--markdown=<file.md>]… [--compiler=ldc2] [--verbose]
---
With no selection, every request in scope is made. Exits non-zero on any
unaccepted disagreement.
*/
module resolve_oracle;

import std.algorithm : canFind, countUntil, endsWith, filter, map, sort, startsWith;
import std.array : array, join, split;
import std.conv : to, text;
import std.experimental.allocator.mallocator : Mallocator;
import std.file : exists, getcwd, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.getopt : getopt;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildNormalizedPath, buildPath, dirName, relativePath;
import std.process : environment, execute;
import std.stdio : stderr, writefln, writeln;
import std.string : indexOf, lineSplitter, strip, stripLeft;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.build_primitives.dub_manifest : parseEmbeddedDubManifest, readDubManifest;
import sparkles.wired.sdl : SdlNode, SdlQualifiedName, SdlScalar, SdlScalarKind, locateEmbeddedRecipe,
    parseEmbeddedSdlDocument, sdlDubRecipe, sdlEditor;
import ours = sparkles.build_primitives.resolve;

/// One request: a package, a configuration (null for the default one), a
/// build type, and whether it is the test root.
struct Request
{
    string package_;      /// `:base`, or a single-file package's label
    string configuration; ///
    string buildType;     ///
    bool testRoot;        ///
    /// A single-file package: the file dub reads, and the one the resolver
    /// reads (the same file, or a Markdown fence before `ci`'s rewrite).
    string dubFile, ourFile;

    string toString() const
        => testRoot ? package_ ~ " (test root)"
            : package_ ~ " [" ~ (configuration.length ? configuration : "default") ~ "] " ~ buildType;

    string probeArgument() const
        => text("--request=", dubFile.length ? dubFile : package_, ",", configuration, ",", buildType, ",",
            testRoot);
}

/// One target's fields, normalized for comparison.
struct Fields
{
    string[] targetType, targetName;
    string[] sourceFiles, importPaths, cImportPaths, stringImportPaths;
    string[] versions, debugVersions, dflags, lflags, libs, options, requirements;
    string[] resolvedLibs, resolvedLflags, resolvedDflags;
}

/// The fields compared, in report order.
enum string[] fieldNames = ["targetType", "targetName", "sourceFiles", "importPaths",
    "cImportPaths", "stringImportPaths", "versions", "debugVersions", "dflags", "lflags", "libs",
    "options", "requirements", "resolvedLibs", "resolvedLflags", "resolvedDflags"];

/// Fields whose order carries no meaning: compared as sets.
enum string[] setFields = ["options", "requirements"];

/// A disagreement the decisions accept.
struct Accepted
{
    string field;     /// the field it concerns
    string decision;  /// the decision record that accepts it
    /// Whether a disagreement on `field` of `target` in `request` is this one.
    bool function(in Request request, string target, in string[] dub, in string[] resolved) matches;
}

/// The accepted disagreements, each with its decision.
immutable Accepted[] accepted = [
    // D22: the resolver normalizes the paths it joins, and so drops a second
    // spelling of a directory dub keeps (`libs/x/../y/src` and `libs/y/src`).
    Accepted("importPaths", "D22", &onlyDubRepeats),
    Accepted("cImportPaths", "D22", &onlyDubRepeats),
    Accepted("stringImportPaths", "D22", &onlyDubRepeats),
    Accepted("sourceFiles", "D22", &onlyDubRepeats),
];

/// Whether `resolved` is `dub` without its repeated entries.
bool onlyDubRepeats(in Request, string, in string[] dub, in string[] resolved)
{
    string[] unique;
    foreach (entry; dub)
        if (!unique.canFind(entry))
            unique ~= entry;
    return unique == resolved;
}

/// Where Markdown fences are written, as `<n>/dub/<name>.d` (what `ci` hands
/// dub) and `<n>/ours/<name>.d` (the fence as written).
string fenceRoot;

/// The DUB home the probe runs in, seeded with the locked registry sources.
string dubHome;

/// Normalizes a path: `.`/`..` folded, a registry package written by name,
/// and the two copies of a Markdown fence written as one.
string normalizePath(string path)
{
    auto normalized = buildNormalizedPath(path);
    if (fenceRoot.length && normalized.startsWith(fenceRoot ~ "/"))
    {
        const parts = normalized[fenceRoot.length + 1 .. $].split('/');
        if (parts.length >= 2)
            return (["<fence>", parts[0]] ~ parts[2 .. $]).join('/');
    }
    // The registry sources: the DUB home seeded for the probe, or the
    // flake's `dub-sources`.
    const seeded = dubHome ~ "/packages/";
    if (dubHome.length && normalized.startsWith(seeded))
        return "<registry>/" ~ normalized[seeded.length .. $];
    const marker = "/.dub/packages/";
    const at = normalized.indexOf(marker);
    return at < 0 ? normalized : "<registry>/" ~ normalized[at + marker.length .. $];
}

string[] strings(const JSONValue j) => j.array.map!(e => e.str).array;

/// dub's fields for one target, its test main file left out.
Fields dubFields(const JSONValue t, string cache)
{
    const generated = buildNormalizedPath(cache);
    string[] paths(string key)
        => strings(t[key]).filter!(p => !buildNormalizedPath(p).startsWith(generated))
            .map!normalizePath.array;

    Fields f;
    f.targetType = [t["targetType"].str];
    f.targetName = [t["targetName"].str];
    f.sourceFiles = paths("sourceFiles");
    f.importPaths = paths("importPaths");
    f.cImportPaths = paths("cImportPaths");
    f.stringImportPaths = paths("stringImportPaths");
    static foreach (field; ["versions", "debugVersions", "dflags", "lflags", "libs", "options",
            "requirements", "resolvedLibs", "resolvedLflags", "resolvedDflags"])
        __traits(getMember, f, field) = strings(t[field]);
    return f;
}

/// The resolver's fields for one target.
Fields ourFields(const ref ours.ResolvedTarget target, const ours.BuildPlatform platform,
    ours.PkgConfigDriver pkgConfig)
{
    const bs = target.settings;
    Fields f;
    f.targetType = [bs.targetType.to!string];
    f.targetName = [bs.targetName];
    f.sourceFiles = bs.sourceFiles.map!normalizePath.array;
    f.importPaths = bs.importPaths.map!normalizePath.array;
    f.cImportPaths = bs.cImportPaths.map!normalizePath.array;
    f.stringImportPaths = bs.stringImportPaths.map!normalizePath.array;
    f.versions = bs.versions.dup;
    f.debugVersions = bs.debugVersions.dup;
    f.dflags = bs.dflags.dup;
    f.lflags = bs.lflags.dup;
    f.libs = bs.libs.dup;
    f.options = ours.optionNames(bs.options);
    f.requirements = ours.requirementNames(bs.requirements);

    auto resolved = bs.dup;
    const libraries = ours.resolveLibraries(resolved, platform, pkgConfig);
    f.resolvedLibs = resolved.libs.dup;
    f.resolvedLflags = resolved.lflags.dup;
    // D17: a library target's own `--cflags` are a recorded divergence.
    const isLibrary = bs.targetType == ours.TargetType.staticLibrary
        || bs.targetType == ours.TargetType.library;
    f.resolvedDflags = isLibrary
        ? resolved.dflags.filter!(d => !libraries.dflags.canFind(d)).array
        : resolved.dflags.dup;
    return f;
}

/// The resolver's platform for the one dub reports.
ours.BuildPlatform platformOf(const JSONValue p)
    => ours.BuildPlatform(strings(p["platform"]), strings(p["architecture"]), p["compiler"].str,
        p["compilerBinary"].str, cast(int) p["frontendVersion"].integer, p["compilerVersion"].str);

/// The in-repo packages, by their `:name`.
string[] inRepoPackages(string repoRoot)
{
    const root = readDubManifest(repoRoot.buildPath("dub.sdl"));
    string[] names;
    foreach (sub; root.value.subPackages)
        names ~= ":" ~ readDubManifest(repoRoot.buildPath(sub.path, "dub.sdl")).value.name;
    return names;
}

/// Every configuration of an in-repo package some recipe selects.
string[][string] selectedConfigurations(string repoRoot)
{
    string[][string] selected;
    void note(string dependency, string configuration)
    {
        if (!dependency.startsWith("sparkles:"))
            return;
        auto list = &selected.require(":" ~ dependency["sparkles:".length .. $], null);
        if (!(*list).canFind(configuration))
            *list ~= configuration;
    }

    const root = readDubManifest(repoRoot.buildPath("dub.sdl"));
    foreach (sub; root.value.subPackages)
    {
        const manifest = readDubManifest(repoRoot.buildPath(sub.path, "dub.sdl")).value;
        foreach (s; manifest.subConfigurations)
            note(s.dependency, s.configuration);
        foreach (ref c; manifest.configurations)
            foreach (s; c.subConfigurations)
                note(s.dependency, s.configuration);
    }
    return selected;
}

/// The tracked files matching `pathspecs`.
string[] gitLsFiles(string[] pathspecs)
{
    const result = execute(["git", "ls-files", "--"] ~ pathspecs);
    if (result.status != 0)
        throw new Exception("git ls-files failed: " ~ result.output);
    return result.output.lineSplitter.filter!(l => l.length != 0).map!(l => l.idup).array;
}

/// The single-file examples `ci --example-files` runs: the globs of
/// `standaloneExampleGlobs` in `apps/ci/src/app.d`, read from the source so
/// the oracle follows that list.
string[] exampleFiles()
{
    const source = readText("apps/ci/src/app.d");
    const start = source.indexOf("string[] standaloneExampleGlobs()");
    if (start < 0)
        throw new Exception("standaloneExampleGlobs not found in apps/ci/src/app.d");
    const end = start + source[start .. $].indexOf("];");
    string[] globs;
    foreach (line; source[start .. end].lineSplitter)
    {
        const l = line.strip;
        if (l.startsWith(`"`) && l.endsWith(`",`))
            globs ~= l[1 .. $ - 2].idup;
    }
    return gitLsFiles(globs).filter!(f => locateEmbeddedRecipe(readText(f)).found).array;
}

/// A Markdown fence `ci --verify` runs.
struct Fence
{
    string file; /// the Markdown file
    size_t line; /// the fence's opening line, from 1
    string name; /// the recipe's name, which `ci` names the file after
    string code; ///
}

/// The fences of `markdown` that `ci`'s `extractExamples` runs: a `d` fence
/// outside a wrapper fence, not marked `md-example-skip`, opening with a dub
/// shebang and an SDL recipe, and naming `main`.
Fence[] fencesOf(string markdown)
{
    static string marker(const(char)[] line)
    {
        const t = line.stripLeft;
        if (!t.length || (t[0] != '`' && t[0] != '~'))
            return null;
        size_t n;
        while (n < t.length && t[n] == t[0])
            ++n;
        return n >= 3 ? t[0 .. n].idup : null;
    }

    const lines = readText(markdown).lineSplitter.map!(l => l.idup).array;
    Fence[] fences;
    for (size_t i = 0; i < lines.length; ++i)
    {
        // A wrapper fence (four or more markers) quotes Markdown: skip it.
        const open = marker(lines[i]);
        if (open.length >= 4)
        {
            foreach (j; i + 1 .. lines.length)
            {
                const m = marker(lines[j]);
                if (m.length >= open.length && m[0] == open[0] && lines[j].strip.length == m.length)
                {
                    i = j;
                    break;
                }
            }
            continue;
        }
        if (!lines[i].strip.startsWith("```d"))
            continue;
        const close = lines[i + 1 .. $].countUntil!(l => l.strip.startsWith("```"));
        if (close < 0)
            continue;
        const body = lines[i + 1 .. i + 1 + close];
        const opened = i;
        i += 1 + close;

        size_t before = opened;
        while (before > 0 && lines[before - 1].strip.length == 0)
            --before;
        if (before > 0 && lines[before - 1].strip.startsWith("<!-- md-example-skip"))
            continue;
        if (body.length < 2 || !body[0].strip.startsWith("#!/usr/bin/env dub")
            || !body.canFind!(l => l.canFind("main")))
            continue;
        const code = body.join("\n");
        const recipe = locateEmbeddedRecipe(code);
        if (!recipe.found || recipe.isJson)
            continue;
        const manifest = parseEmbeddedDubManifest(code);
        fences ~= Fence(markdown, opened + 1,
            manifest.hasValue && manifest.value.name.length ? manifest.value.name : "unnamed", code);
    }
    return fences;
}

/**
`code` as `ci` hands it to dub (`writeInTreeDeps` in `apps/ci/src/dub_deps.d`):
each `dependency "<in-tree package>" version="*"` rewritten to
`path="<the repository, relative to fromDir>"`.
*/
string rewriteInTreeDeps(string code, string repoRoot, string fromDir, in string[] inTreeNames)
{
    auto embedded = parseEmbeddedSdlDocument!sdlDubRecipe(code);
    if (!embedded.recipe.found || embedded.recipe.isJson || embedded.parsed.hasError)
        return code;
    const rel = repoRoot.relativePath(fromDir);
    auto editor = sdlEditor!sdlDubRecipe(embedded.parsed.document, code);
    void rewrite(scope const SdlNode node)
    {
        foreach (child; node.byChild)
        {
            if (child.qualifiedName == SdlQualifiedName(null, "dependency")
                && child.valueCount == 1 && child.attributeCount == 1)
            {
                const value = child.byValue.front;
                const attribute = child.byAttribute.front;
                if (value.kind == SdlScalarKind.string_ && inTreeNames.canFind(value.stringValue)
                    && attribute.qualifiedName == SdlQualifiedName(null, "version")
                    && attribute.value.kind == SdlScalarKind.string_
                    && attribute.value.stringValue == "*")
                    editor.replaceAttribute(attribute, SdlQualifiedName(null, "path"), SdlScalar(rel));
            }
            rewrite(child);
        }
    }
    rewrite(embedded.parsed.document.root);
    UniqueBuffer!char output;
    Mallocator allocator;
    if (editor.write(output, allocator).hasError)
        return code;
    return output[].idup;
}

int main(string[] args)
{
    string[] packages, singleFiles, markdownFiles;
    string compilerName = "ldc2";
    string probe = "apps/ci/tools/build/dub_resolve_probe";
    bool verbose;
    getopt(args, "package", &packages, "single-file", &singleFiles, "markdown", &markdownFiles,
        "compiler", &compilerName, "probe", &probe, "verbose", &verbose);
    // No selection selects everything in scope.
    const everything = packages.length == 0 && singleFiles.length == 0 && markdownFiles.length == 0;

    const repoRoot = getcwd;
    const sources = environment.get("SPARKLES_DUB_SOURCES");
    if (sources is null || !probe.exists)
    {
        stderr.writeln("run inside the dev shell, after building ", probe);
        return 2;
    }

    auto driver = new ours.SystemDriver;
    auto pkgConfig = new ours.SystemPkgConfig;
    const locked = ours.readDubLocks([repoRoot.buildPath("nix", "dub-lock.json"),
        repoRoot.buildPath("nix", "ci-dub-lock.json")], driver);
    if (locked.hasError)
    {
        stderr.writeln(locked.error);
        return 2;
    }
    const registry = ours.nixRegistrySources(locked.value, sources, driver);
    if (registry.hasError)
    {
        stderr.writeln(registry.error);
        return 2;
    }

    const subPackages = inRepoPackages(repoRoot);
    if (everything)
    {
        packages = subPackages.dup;
        singleFiles = exampleFiles();
        // The files CI's `--verify` job passes: every tracked one but the
        // highlighter's test data, whose fences are fixtures.
        markdownFiles = gitLsFiles(["*.md", ":!libs/syntax/test/data/**",
            ":!libs/source-view/test/data/**"]);
    }
    const selected = selectedConfigurations(repoRoot);
    Request[] requests;
    foreach (p; packages)
    {
        requests ~= Request(p, null, "unittest", true);
        requests ~= Request(p, null, "checked", false);
        foreach (c; selected.get(p, null))
            requests ~= Request(p, c, "checked", false);
    }
    // Single-file packages, under the build type `ci` runs them with.
    foreach (file; singleFiles)
    {
        const path = buildNormalizedPath(repoRoot, file);
        requests ~= Request(file, null, "debug", false, path, path);
    }
    // Markdown fences, each written twice: as `ci` rewrites it for dub, and
    // as written, for the resolver's in-tree rewrite (BGR6).
    fenceRoot = buildPath(tempDir, "resolve-oracle-fences");
    if (fenceRoot.exists)
        rmdirRecurse(fenceRoot);
    const inTreeNames = ["sparkles"] ~ subPackages.map!(p => "sparkles" ~ p).array;
    size_t fenceCount;
    foreach (markdown; markdownFiles)
        foreach (fence; fencesOf(markdown))
        {
            const dir = buildPath(fenceRoot, (fenceCount++).to!string);
            const dubFile = buildPath(dir, "dub", fence.name ~ ".d");
            const ourFile = buildPath(dir, "ours", fence.name ~ ".d");
            mkdirRecurse(dubFile.dirName);
            mkdirRecurse(ourFile.dirName);
            write(dubFile, rewriteInTreeDeps(fence.code, repoRoot, dubFile.dirName, inTreeNames));
            write(ourFile, fence.code);
            requests ~= Request(text(fence.file, ":", fence.line), null, "debug", false, dubFile, ourFile);
        }

    // dub sees only the packages the locks pin, in a writable copy, as `ci`'s
    // seeded DUB home holds them: what else the user's cache holds could
    // select another version for a recipe without selections.
    dubHome = buildPath(tempDir, "resolve-oracle-dub-home");
    if (dubHome.exists)
        rmdirRecurse(dubHome);
    mkdirRecurse(dubHome);
    const seeded = execute(["cp", "-r", "--no-preserve=mode", buildPath(sources, ".dub", "packages"),
        buildPath(dubHome, "packages")]);
    if (seeded.status != 0)
    {
        stderr.writeln("cannot seed ", dubHome, ": ", seeded.output);
        return 2;
    }

    const output = buildPath(tempDir, "resolve-oracle-probe.json");
    const run = execute([probe, "--compiler=" ~ compilerName, "--out=" ~ output]
        ~ requests.map!(r => r.probeArgument).array, ["DUB_HOME": dubHome]);
    if (run.status != 0)
    {
        stderr.writeln("the probe failed:\n", run.output);
        return 2;
    }
    const results = parseJSON(readText(output)).array;

    // A request dub fails before it determines the platform is resolved for
    // the platform the others report: the compiler is the same throughout.
    JSONValue anyPlatform;
    foreach (result; results)
        if (auto p = "platform" in result.objectNoRef)
        {
            anyPlatform = *p;
            break;
        }

    size_t disagreements, acceptedCount, failures, bothFail, compared;
    string[] hiddenEdges;
    foreach (i, ref request; requests)
    {
        const dub = results[i];
        const dubFailed = ("error" in dub.objectNoRef) !is null;
        const dubPlatform = "platform" in dub.objectNoRef;
        if (dubPlatform is null && anyPlatform.type != JSONType.object)
        {
            ++failures;
            writefln("%s: dub: %s", request, dub["error"].str);
            continue;
        }
        auto platform = platformOf(dubPlatform ? *dubPlatform : anyPlatform);
        auto ourRequest = request.ourFile.length
            ? ours.ResolveRequest(singleFile: request.ourFile, buildType: request.buildType,
                platform: platform)
            : ours.ResolveRequest(directory: repoRoot, subPackage: request.package_,
                configuration: request.configuration, buildType: request.buildType, platform: platform,
                testRoot: request.testRoot);
        // A fence's in-tree dependencies by version are the working tree's.
        if (request.ourFile != request.dubFile)
            ourRequest.inTree["sparkles"] = repoRoot;
        foreach (name, source; registry.value)
            ourRequest.registry[name] = source;
        const resolution = ours.resolve(ourRequest, driver);

        if (resolution.hasError || dubFailed)
        {
            // Both refusing a request is agreement; it is counted, and shown
            // with `--verbose`.
            if (resolution.hasError != dubFailed)
                ++failures;
            else
                ++bothFail;
            if (resolution.hasError != dubFailed || verbose)
                writefln("%s: dub %s; the resolver %s", request,
                    dubFailed ? "fails: " ~ dub["error"].str : "resolves",
                    resolution.hasError ? "fails: " ~ resolution.error.message : "resolves");
            continue;
        }
        foreach (ref edge; resolution.value.hiddenEdges)
            if (!hiddenEdges.canFind(edge.text))
                hiddenEdges ~= edge.text;
        if (resolution.value.configuration != dub["configuration"].str)
        {
            ++disagreements;
            writefln("%s: configuration: dub %s, resolver %s", request, dub["configuration"].str,
                resolution.value.configuration);
        }

        Fields[string] dubTargets, ourTargets;
        foreach (name, t; dub["targets"].objectNoRef)
            dubTargets[name] = dubFields(t, dub["cache"].str);
        foreach (ref t; resolution.value.targets)
            ourTargets[t.package_] = ourFields(t, platform, pkgConfig);
        if (dubTargets.keys.sort.release != ourTargets.keys.sort.release)
        {
            ++disagreements;
            writefln("%s: targets: dub %s, resolver %s", request, dubTargets.keys.sort, ourTargets.keys.sort);
        }
        foreach (name, ref dubSide; dubTargets)
        {
            auto ourSide = name in ourTargets;
            if (ourSide is null)
                continue;
            ++compared;
            static foreach (field; fieldNames)
            {{
                const d = __traits(getMember, dubSide, field);
                const o = __traits(getMember, *ourSide, field);
                const same = setFields.canFind(field) ? d.dup.sort.release == o.dup.sort.release : d == o;
                if (!same)
                {
                    bool isAccepted;
                    foreach (ref a; accepted)
                        if (a.field == field && a.matches(request, name, d, o))
                            isAccepted = true;
                    if (isAccepted)
                        ++acceptedCount;
                    else
                    {
                        ++disagreements;
                        const orderOnly = d.dup.sort.release == o.dup.sort.release;
                        writefln("%s: %s: %s%s", request, name, field, orderOnly ? " (order only)" : "");
                        writefln("    dub only:      %s", d.filter!(x => !o.canFind(x)).array);
                        writefln("    resolver only: %s", o.filter!(x => !d.canFind(x)).array);
                        if (verbose || orderOnly)
                            writefln("    dub:      %s\n    resolver: %s", d, o);
                    }
                }
            }}
        }
        if (verbose)
            writefln("%s: %s targets compared", request, dubTargets.length);
    }

    // Oracle 13: BGR8's hidden edges, which the gate requires to be none.
    foreach (edge; hiddenEdges.sort)
        writeln("hidden edge: ", edge);
    writefln("%s requests, %s targets compared: %s disagreements, %s accepted, %s resolution failures, "
        ~ "%s refused by both, %s hidden edges",
        requests.length, compared, disagreements, acceptedCount, failures, bothFail, hiddenEdges.length);
    return disagreements || failures || hiddenEdges.length ? 1 : 0;
}
