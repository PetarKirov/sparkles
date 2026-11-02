#!/usr/bin/env dub
/+ dub.sdl:
    name "resolve_oracle"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
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
dub run --single apps/ci/tools/resolve-oracle.d -- [--package=:base]… [--compiler=ldc2] [--verbose]
---
Exits non-zero on any unaccepted disagreement.
*/
module resolve_oracle;

import std.algorithm : canFind, filter, map, sort, startsWith;
import std.array : array;
import std.conv : to, text;
import std.file : exists, getcwd, readText, tempDir;
import std.getopt : getopt;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildNormalizedPath, buildPath;
import std.process : environment, execute;
import std.stdio : stderr, writefln, writeln;
import std.string : indexOf;

import sparkles.build_primitives.dub_manifest : readDubManifest;
import ours = sparkles.build_primitives.resolve;

/// One request: a package, a configuration (null for the default one), a
/// build type, and whether it is the test root.
struct Request
{
    string package_;      /// `:base`
    string configuration; ///
    string buildType;     ///
    bool testRoot;        ///

    string toString() const
        => testRoot ? package_ ~ " (test root)"
            : package_ ~ " [" ~ (configuration.length ? configuration : "default") ~ "] " ~ buildType;

    string probeArgument() const
        => text("--request=", package_, ",", configuration, ",", buildType, ",", testRoot);
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

/// Normalizes a path: `.`/`..` folded, a registry package written by name.
string normalizePath(string path)
{
    auto normalized = buildNormalizedPath(path);
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

int main(string[] args)
{
    string[] packages;
    string compilerName = "ldc2";
    string probe = "apps/ci/tools/build/dub_resolve_probe";
    bool verbose;
    getopt(args, "package", &packages, "compiler", &compilerName, "probe", &probe, "verbose", &verbose);

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

    if (packages.length == 0)
        packages = inRepoPackages(repoRoot);
    const selected = selectedConfigurations(repoRoot);
    Request[] requests;
    foreach (p; packages)
    {
        requests ~= Request(p, null, "unittest", true);
        requests ~= Request(p, null, "checked", false);
        foreach (c; selected.get(p, null))
            requests ~= Request(p, c, "checked", false);
    }

    const output = buildPath(tempDir, "resolve-oracle-probe.json");
    const run = execute([probe, "--compiler=" ~ compilerName, "--out=" ~ output]
        ~ requests.map!(r => r.probeArgument).array);
    if (run.status != 0)
    {
        stderr.writeln("the probe failed:\n", run.output);
        return 2;
    }
    const results = parseJSON(readText(output)).array;

    size_t disagreements, acceptedCount, failures, compared;
    string[] hiddenEdges;
    foreach (i, ref request; requests)
    {
        const dub = results[i];
        const dubFailed = ("error" in dub.objectNoRef) !is null;
        if ("platform" !in dub.objectNoRef)
        {
            ++failures;
            writefln("%s: dub: %s", request, dub["error"].str);
            continue;
        }
        auto platform = platformOf(dub["platform"]);
        auto ourRequest = ours.ResolveRequest(directory: repoRoot, subPackage: request.package_,
            configuration: request.configuration, buildType: request.buildType, platform: platform,
            testRoot: request.testRoot);
        foreach (name, source; registry.value)
            ourRequest.registry[name] = source;
        const resolution = ours.resolve(ourRequest, driver);

        if (resolution.hasError || dubFailed)
        {
            if (resolution.hasError != dubFailed)
            {
                ++failures;
                writefln("%s: dub %s; the resolver %s", request,
                    dubFailed ? "fails: " ~ dub["error"].str : "resolves",
                    resolution.hasError ? "fails: " ~ resolution.error.message : "resolves");
            }
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
        ~ "%s hidden edges",
        requests.length, compared, disagreements, acceptedCount, failures, hiddenEdges.length);
    return disagreements || failures || hiddenEdges.length ? 1 : 0;
}
