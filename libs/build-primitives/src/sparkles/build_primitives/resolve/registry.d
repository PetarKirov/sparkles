/**
Registry packages from the repository's DUB locks (build-graph SPEC BGR4).

A dependency that is no in-tree package resolves to the source the locks
(`nix/dub-lock.json`, `nix/ci-dub-lock.json`) pin, never to a version a
registry offers. $(LREF readDubLocks) reads the locks; $(LREF nixRegistrySources)
locates each pinned package in the source tree the flake's `dub-sources`
output lays out from them (`$SPARKLES_DUB_SOURCES`).
*/
module sparkles.build_primitives.resolve.registry;

import std.conv : text;

import sparkles.build_primitives.resolve.driver : ResolveDriver;
import sparkles.build_primitives.resolve.project : RegistrySource, RegistrySources;
import sparkles.build_primitives.task.model : PlanExpected, planErr, planOk;

/// One package a lock pins.
struct LockedPackage
{
    string name;        /// the root package name
    string version_;    /// a version, or a commit for a repository package
    string repository;  /// a repository package's URL; null for a registry one
    string sha256;      /// the Nix hash of the source
    string lock;        /// the lock file that pins it
}

/// Reads the packages `locks` pin. The same package pinned twice must be
/// pinned identically.
PlanExpected!(LockedPackage[], string) readDubLocks(const string[] locks, ResolveDriver driver) @safe
{
    import std.json : JSONException, JSONType, parseJSON;

    LockedPackage[] packages;
    foreach (lock; locks)
    {
        string source;
        if (!driver.readText(lock, source))
            return planErr!(LockedPackage[])(text("cannot read the DUB lock ", lock));
        try
        {
            const json = parseJSON(source);
            const dependencies = "dependencies" in json.objectNoRef;
            if (dependencies is null || dependencies.type != JSONType.object)
                return planErr!(LockedPackage[])(text(lock, ": no `dependencies` object"));
            foreach (name, entry; dependencies.objectNoRef)
            {
                string field(string key)
                {
                    auto value = key in entry.objectNoRef;
                    return value !is null && value.type == JSONType.string ? value.str : null;
                }

                auto locked = LockedPackage(name, field("version"), field("repository"),
                    field("sha256"), lock);
                if (locked.version_ is null || locked.sha256 is null)
                    return planErr!(LockedPackage[])(text(lock, ": `", name, "` lacks a version or a hash"));
                bool known;
                foreach (ref p; packages)
                    if (p.name == name)
                    {
                        known = true;
                        if (p.version_ != locked.version_ || p.sha256 != locked.sha256)
                            return planErr!(LockedPackage[])(text("`", name, "` is pinned differently in ",
                                p.lock, " and ", lock));
                    }
                if (!known)
                    packages ~= locked;
            }
        }
        catch (JSONException e)
            return planErr!(LockedPackage[])(text(lock, ": ", e.msg));
    }
    import std.algorithm.sorting : sort;

    return planOk!string(packages.sort!((a, b) => a.name < b.name).release);
}

/**
The source directory of each package in `packages`, inside the tree the
flake's `dub-sources` output builds from the locks
(`<sources>/.dub/packages/<name>/<version>/<name>`). A package missing
from the tree is an error.
*/
PlanExpected!(RegistrySources, string) nixRegistrySources(const LockedPackage[] packages,
    string sources, ResolveDriver driver) @safe
{
    import std.path : buildPath;

    RegistrySources result;
    foreach (ref p; packages)
    {
        const directory = buildPath(sources, ".dub", "packages", p.name, p.version_, p.name);
        if (!driver.isDirectory(directory))
            return planErr!RegistrySources(text("`", p.name, "` ", p.version_, " (", p.lock,
                ") is not in the DUB sources at ", sources));
        result[p.name] = RegistrySource(directory, p.version_, p.repository);
    }
    return planOk!string(result);
}

@("build_primitives.resolve.registry.readDubLocks.andNixSources")
@safe unittest
{
    import sparkles.build_primitives.resolve.driver : MemoryDriver;

    auto driver = new MemoryDriver([
        "/r/a.json": `{"dependencies": {"expected": {"version": "0.4.1", "sha256": "x"}}}`,
        "/r/b.json": `{"dependencies": {"eve": {"version": "c72f", "repository": "https://e", "sha256": "y"},
            "expected": {"version": "0.4.1", "sha256": "x"}}}`,
        "/r/bad.json": `{"dependencies": {"expected": {"version": "0.5.0", "sha256": "z"}}}`,
        "/s/.dub/packages/expected/0.4.1/expected/dub.json": "{}",
    ]);
    const locked = readDubLocks(["/r/a.json", "/r/b.json"], driver);
    assert(locked.hasValue, locked.error);
    // Sorted by name.
    assert(locked.value.length == 2 && locked.value[0].repository == "https://e");
    assert(readDubLocks(["/r/a.json", "/r/bad.json"], driver).hasError);
    assert(readDubLocks(["/r/absent.json"], driver).hasError);

    const sources = nixRegistrySources(locked.value[1 .. 2], "/s", driver);
    assert(sources.hasValue && sources.value["expected"] == RegistrySource("/s/.dub/packages/expected/0.4.1/expected", "0.4.1"));
    assert(nixRegistrySources(locked.value, "/s", driver).hasError);
}
