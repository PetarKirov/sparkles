/**
hue's per-project state (`CFG23`–`CFG26`): what hue remembers about one
checkout, in `.sparkles/hue/project.json` under the project root, the way an
editor keeps a `.vscode` directory.

Today it holds one thing: the dub build live types describe, per package
(`PRJ19`). A package's configurations are its own — `gpu-effects` means
something only to the recipe that declares it — so a selection is keyed by
the recipe, relative to the project root, and overlays the global `dub`
section field by field.

The file is machine-owned: hue rewrites it whole, atomically, and a malformed
one is reported and left alone rather than overwritten.

NOTE: no module-level `@safe:` — the decode path infers `@system`.
*/
module project_state;

import std.path : buildPath, dirName;

import expected : err, Expected, ok;

import sparkles.build_primitives.dub_recipe : dubRecipeFor;

import settings : DubBuildSettings;
import settings_overlay : applyOverlay, Origin, OriginKind, Origins, Sparse;

/// The state file, relative to the project root (`CFG23`).
enum projectStatePath = buildPath(".sparkles", "hue", "project.json");

/// What `.sparkles/hue/project.json` holds.
struct HueProjectState
{
    /// The dub build per package (`CFG25`), keyed by $(LREF packageKey):
    /// only the fields a selection set, so an unset one falls through to the
    /// global `dub` section.
    Sparse!DubBuildSettings[string] dubPackages;
}

/**
The project root for `startPath` (`CFG24`): the nearest ancestor holding a
`.sparkles` directory, else the nearest holding `.git` (a directory, or the
file a linked worktree has), else `null`. `startPath` may be a file or a
directory.
*/
string findProjectRoot(string startPath) @safe
{
    import std.file : exists, isDir;
    import std.path : absolutePath, buildNormalizedPath;

    if (!startPath.length)
        return null;
    auto start = startPath.absolutePath.buildNormalizedPath;
    if (!(start.exists && start.isDir))
        start = start.dirName;

    static string climb(string dir, bool delegate(string) @safe found) @safe
    {
        for (;;)
        {
            if (found(dir))
                return dir;
            const parent = dir.dirName;
            if (parent == dir)
                return null;
            dir = parent;
        }
    }

    if (const root = climb(start, (d) {
            const s = d.buildPath(".sparkles");
            return s.exists && s.isDir;
        }))
        return root;
    return climb(start, (d) => d.buildPath(".git").exists);
}

/**
The key a package's state is stored under (`CFG25`): its recipe's directory
relative to `root`, with `/` separators and `.` for the root itself — or, for
a single-file package, the file's own relative path.
*/
string packageKey(string root, string recipe) @safe
{
    import std.algorithm.searching : endsWith;
    import std.array : replace;
    import std.path : absolutePath, buildNormalizedPath, relativePath;

    const target = recipe.endsWith(".d") ? recipe : recipe.dirName;
    const rel = target.absolutePath.buildNormalizedPath
        .relativePath(root.absolutePath.buildNormalizedPath);
    version (Windows)
        return rel.replace("\\", "/");
    else
        return rel;
}

/// Reads the state at `path`. A missing file is an empty state, not an
/// error; a malformed one is an error naming the file (`CFG26`).
Expected!(HueProjectState, string) readProjectState(string path)
{
    import std.file : exists;

    import sparkles.wired.json.jsonc : readJsoncFile;

    if (!path.exists)
        return ok!string(HueProjectState.init);
    auto r = readJsoncFile!HueProjectState(path);
    if (r.hasError)
        return err!HueProjectState(path ~ ": " ~ r.error.toString);
    return ok!string(r.value);
}

/// Writes `state` to `path` atomically, creating `.sparkles/hue/` as needed.
Expected!(void, string) writeProjectState(string path, in HueProjectState state)
{
    import sparkles.wired.json : writeJSONFile;

    auto r = writeJSONFile(state, path);
    if (r.hasError)
        return err!void(r.error.toString);
    return ok!string();
}

/// Where a document's dub build selection lives: the state file and the key
/// inside it. `found` is false for a document in no dub package.
struct PackageSlot
{
    string statePath; ///
    string key;       ///
    string recipe;    /// the recipe the key names
    bool found;       ///
}

/// The slot for the document at `docPath` (`CFG24`, `CFG25`). Without a
/// project root, the recipe's own directory is the root.
PackageSlot packageSlotFor(string docPath) @safe
{
    const recipe = dubRecipeFor(docPath);
    if (!recipe.length)
        return PackageSlot.init;
    auto root = findProjectRoot(recipe);
    if (!root.length)
        root = recipe.dirName;
    return PackageSlot(root.buildPath(projectStatePath), packageKey(root, recipe),
        recipe, found: true);
}

/// The dub build live types describe for one document, and any problem
/// reading the state that decided it.
struct ResolvedDubBuild
{
    DubBuildSettings build; ///
    string warning;         /// non-empty when the state file was unreadable
}

/// A mutable copy of settings a host holds `const` (its list fields copied).
DubBuildSettings mutableCopy(const DubBuildSettings s) @safe pure nothrow
{
    DubBuildSettings copy;
    static foreach (i, _; DubBuildSettings.tupleof)
    {
        static if (is(typeof(DubBuildSettings.tupleof[i]) == string[]))
            copy.tupleof[i] = s.tupleof[i].dup;
        else
            copy.tupleof[i] = s.tupleof[i];
    }
    return copy;
}

/**
The dub build for the document at `docPath` (`PRJ19`): the global `dub`
section with the document's package entry laid over it, field by field. An
unreadable state file contributes nothing and is reported.
*/
ResolvedDubBuild dubBuildFor(string docPath, const DubBuildSettings global)
{
    auto resolved = ResolvedDubBuild(global.mutableCopy);
    const slot = packageSlotFor(docPath);
    if (!slot.found)
        return resolved;
    auto state = readProjectState(slot.statePath);
    if (state.hasError)
    {
        resolved.warning = state.error;
        return resolved;
    }
    if (auto entry = slot.key in state.value.dubPackages)
    {
        Origins!DubBuildSettings origins;
        applyOverlay(resolved.build, origins, *entry,
            Origin(OriginKind.projectFile, "file:" ~ slot.statePath));
    }
    return resolved;
}

/**
Records `config` as the dub configuration of the document's package
(`CFG25`); an empty `config` clears the selection, and an entry left with no
field set is dropped. Refuses, without writing, when the existing file is
malformed — it may hold what a person wrote (`CFG26`).
*/
Expected!(void, string) selectDubConfiguration(in PackageSlot slot, string config)
{
    import std.typecons : Nullable;

    if (!slot.found)
        return err!void("no dub package");
    auto read = readProjectState(slot.statePath);
    if (read.hasError)
        return err!void(read.error);
    auto state = read.value;

    auto entry = state.dubPackages.get(slot.key, Sparse!DubBuildSettings.init);
    entry.config = config.length ? Nullable!string(config) : Nullable!string.init;
    if (entry == Sparse!DubBuildSettings.init)
        state.dubPackages.remove(slot.key);
    else
        state.dubPackages[slot.key] = entry;
    return writeProjectState(slot.statePath, state);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("project_state.findProjectRoot.sparklesBeatsGit")
@system unittest
{
    import std.file : mkdirRecurse;

    import sparkles.test_utils.tmpfs : TmpFS;

    auto t = TmpFS.create("hue-project-root");
    t.writeFileAt(".git", "gitdir: elsewhere\n"); // a linked worktree's marker
    t.writeFileAt("libs/a/dub.sdl", "name \"a\"\n");
    t.writeFileAt("libs/a/src/m.d", "module m;\n");

    const file = t.dir.buildPath("libs", "a", "src", "m.d");
    assert(findProjectRoot(file) == t.dir);

    // A `.sparkles` directory below the repository root claims its subtree.
    mkdirRecurse(t.dir.buildPath("libs", ".sparkles"));
    assert(findProjectRoot(file) == t.dir.buildPath("libs"));

    assert(findProjectRoot("") is null);
}

@("project_state.packageKey.relativeToTheRoot")
@safe unittest
{
    assert(packageKey("/r", "/r/libs/ui/dub.sdl") == "libs/ui");
    assert(packageKey("/r", "/r/dub.sdl") == ".");
    assert(packageKey("/r", "/r/libs/ui/examples/demo.d") == "libs/ui/examples/demo.d");
}

@("project_state.selectDubConfiguration.overlaysTheGlobalSection")
@system unittest
{
    import std.file : exists, readText;

    import sparkles.test_utils.tmpfs : TmpFS;

    auto t = TmpFS.create("hue-project-state");
    t.writeFileAt(".git/HEAD", "ref: refs/heads/main\n");
    t.writeFileAt("libs/ui/dub.sdl", "name \"ui\"\n");
    t.writeFileAt("libs/ui/src/m.d", "module m;\n");
    t.writeFileAt("libs/base/dub.sdl", "name \"base\"\n");
    t.writeFileAt("libs/base/src/b.d", "module b;\n");

    const ui = t.dir.buildPath("libs", "ui", "src", "m.d");
    const base = t.dir.buildPath("libs", "base", "src", "b.d");
    const slot = packageSlotFor(ui);
    assert(slot.found && slot.key == "libs/ui");
    assert(slot.statePath == t.dir.buildPath(".sparkles", "hue", "project.json"));

    // No file yet: the global section stands.
    auto global = DubBuildSettings(config: "library", buildType: "unittest");
    assert(dubBuildFor(ui, global).build == global);

    auto wrote = selectDubConfiguration(slot, "gpu-effects");
    assert(!wrote.hasError, wrote.hasError ? wrote.error : "");
    assert(slot.statePath.readText == "{\n  \"dubPackages\": {\n    \"libs/ui\": {\n"
        ~ "      \"config\": \"gpu-effects\"\n    }\n  }\n}\n", slot.statePath.readText);

    // The package entry wins where it speaks; the rest is global. Another
    // package is untouched.
    const got = dubBuildFor(ui, global);
    assert(got.build.config == "gpu-effects" && got.build.buildType == "unittest");
    assert(dubBuildFor(base, global).build == global);

    // Clearing drops the now-empty entry.
    assert(!selectDubConfiguration(slot, "").hasError);
    assert(readProjectState(slot.statePath).value.dubPackages.length == 0);
}

@("project_state.malformedFile.isReportedAndKept")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : readText;

    import sparkles.test_utils.tmpfs : TmpFS;

    auto t = TmpFS.create("hue-project-state-bad");
    t.writeFileAt(".git/HEAD", "ref: refs/heads/main\n");
    t.writeFileAt("dub.sdl", "name \"p\"\n");
    t.writeFileAt("src/m.d", "module m;\n");
    t.writeFileAt(".sparkles/hue/project.json", "{ \"dubPackages\": [ }");

    const doc = t.dir.buildPath("src", "m.d");
    const global = DubBuildSettings(config: "library");
    const got = dubBuildFor(doc, global);
    assert(got.build == global);
    assert(got.warning.canFind("project.json"), got.warning);

    assert(selectDubConfiguration(packageSlotFor(doc), "x").hasError);
    assert(t.dir.buildPath(".sparkles", "hue", "project.json").readText
        == "{ \"dubPackages\": [ }");
}
