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

import sparkles.build_primitives.resolve.tree : ResolveTree;
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
PlanExpected!(LockedPackage[], string) readDubLocks(const string[] locks, ResolveTree tree) @safe
{
    import std.json : JSONException, JSONType, parseJSON;

    LockedPackage[] packages;
    foreach (lock; locks)
    {
        string source;
        if (!tree.readText(lock, source))
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
    string sources, ResolveTree tree) @safe
{
    import sparkles.build_primitives.resolve.paths : joinedPath;

    RegistrySources result;
    foreach (ref p; packages)
    {
        const directory = joinedPath(sources, ".dub", "packages", p.name, p.version_, p.name);
        if (!tree.isDirectory(directory))
            return planErr!RegistrySources(text("`", p.name, "` ", p.version_, " (", p.lock,
                ") is not in the DUB sources at ", sources));
        result[p.name] = RegistrySource(directory, p.version_, p.repository);
    }
    return planOk!string(result);
}

@("build_primitives.resolve.registry.readDubLocks.andNixSources")
@safe unittest
{
    import sparkles.build_primitives.resolve.tree : memoryTree;

    string[string] files = [
        "/r/a.json": `{"dependencies": {"expected": {"version": "0.4.1", "sha256": "x"}}}`,
        "/r/b.json": `{"dependencies": {"eve": {"version": "c72f", "repository": "https://e", "sha256": "y"},
            "expected": {"version": "0.4.1", "sha256": "x"}}}`,
        "/r/bad.json": `{"dependencies": {"expected": {"version": "0.5.0", "sha256": "z"}}}`,
        "/s/.dub/packages/expected/0.4.1/expected/dub.json": "{}",
    ];
    auto tree = memoryTree(files);
    const locked = readDubLocks(["/r/a.json", "/r/b.json"], tree);
    assert(locked.hasValue, locked.error);
    // Sorted by name.
    assert(locked.value.length == 2 && locked.value[0].repository == "https://e");
    assert(readDubLocks(["/r/a.json", "/r/bad.json"], tree).hasError);
    assert(readDubLocks(["/r/absent.json"], tree).hasError);

    const sources = nixRegistrySources(locked.value[1 .. 2], "/s", tree);
    assert(sources.hasValue && sources.value["expected"] == RegistrySource("/s/.dub/packages/expected/0.4.1/expected", "0.4.1"));
    assert(nixRegistrySources(locked.value, "/s", tree).hasError);
}

/**
The registry packages a package's `dub.selections.json` selects, each found
in the first of `homes` that holds it, in DUB's own layout
(`<home>/packages/<name>/<version>/<name>`): how a tool that resolves one
package outside the build graph sees what `dub` would. `homes` are DUB home
directories, such as `$DUB_HOME` and `~/.dub`, or `<sources>/.dub` for the
tree the flake's `dub-sources` output builds.

A selection by path is left out (the recipe's path dependency is what
resolves it), and so is a selected package no home holds: resolution fails
only if it reaches that package. A selections file that is missing (or
unreadable) selects nothing; one that does not parse is an error.
*/
PlanExpected!(RegistrySources, string) selectedRegistrySources(string selections,
    const string[] homes, ResolveTree tree) @safe
{
    import std.json : JSONException, JSONType, parseJSON;
    import sparkles.build_primitives.resolve.paths : joinedPath;

    RegistrySources result;
    string source;
    if (!tree.readText(selections, source))
        return planOk!string(result);
    try
    {
        const json = parseJSON(source);
        const versions = "versions" in json.objectNoRef;
        if (versions is null || versions.type != JSONType.object)
            return planErr!RegistrySources(text(selections, ": no `versions` object"));
        foreach (name, entry; versions.objectNoRef)
        {
            string version_, repository;
            if (entry.type == JSONType.string)
                version_ = entry.str;
            else if (entry.type == JSONType.object)
            {
                if ("path" in entry.objectNoRef)
                    continue;
                if (auto v = "version" in entry.objectNoRef)
                    version_ = v.type == JSONType.string ? v.str : null;
                if (auto r = "repository" in entry.objectNoRef)
                    repository = r.type == JSONType.string ? r.str : null;
            }
            if (version_ is null)
                return planErr!RegistrySources(text(selections, ": `", name, "` selects no version"));
            foreach (home; homes)
            {
                const directory = joinedPath(home, "packages", name, version_, name);
                if (tree.isDirectory(directory))
                {
                    result[name] = RegistrySource(directory, version_, repository);
                    break;
                }
            }
        }
    }
    catch (JSONException e)
        return planErr!RegistrySources(text(selections, ": ", e.msg));
    return planOk!string(result);
}

///
@("build_primitives.resolve.registry.selectedRegistrySources")
@safe unittest
{
    import sparkles.build_primitives.resolve.tree : memoryTree;

    string[string] files = [
        "/p/dub.selections.json": `{"fileVersion": 1, "versions": {"optional": "1.3.1",
            "bolts": {"version": "1.3.1"}, "local": {"path": "../local"}, "absent": "2.0.0"}}`,
        "/p/bad/dub.selections.json": `{"versions": {"optional": {}}}`,
        "/h1/packages/optional/1.3.1/optional/dub.json": "{}",
        "/h2/packages/optional/1.3.1/optional/dub.json": "{}",
        "/h2/packages/bolts/1.3.1/bolts/dub.json": "{}",
    ];
    auto tree = memoryTree(files);
    const got = selectedRegistrySources("/p/dub.selections.json", ["/h1", "/h2"], tree);
    assert(got.hasValue, got.error);
    // The first home that holds a package wins; a path selection and a
    // package no home holds are left out.
    assert(got.value.length == 2);
    assert(got.value["optional"] == RegistrySource("/h1/packages/optional/1.3.1/optional", "1.3.1"));
    assert(got.value["bolts"] == RegistrySource("/h2/packages/bolts/1.3.1/bolts", "1.3.1"));

    const none = selectedRegistrySources("/q/dub.selections.json", ["/h1"], tree);
    assert(none.hasValue && none.value.length == 0);
    assert(selectedRegistrySources("/p/bad/dub.selections.json", ["/h1"], tree).hasError);
}
