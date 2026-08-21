/**
Glob-filtered repository traversal — the `--include`/`--exclude` layer over the
`.gitignore`-aware walk.

$(LREF GitGlobFilter) composes `GitRepositoryFilter`'s verdict with
user-supplied include/exclude globs, with the explorer's precedence
([`XPF2`](../../../../../docs/specs/hue/tree-view.md)): an `include` match
overrides everything — a `.gitignore` exclusion included — except the
repository's own `.git` metadata; otherwise an `exclude` match drops the file.
Extracted from hue's document-set collector so any tool walking a repository
"these files, minus those" reuses one implementation.
*/
module sparkles.build_primitives.glob_walk;

import sparkles.build_primitives.dir_walk : dirEntriesFilter, DirWalkerRange,
    GitRepositoryFilter, repositoryGitIgnoreStack;

/**
`true` iff a file at root-relative `rel` passes the `include`/`exclude` globs:
an `include` match wins over everything, otherwise an `exclude` match drops the
entry. Each glob is matched against both the base name and the root-relative
path ($(LREF globAny)), so `*.d` and `src/*.d` both work.
*/
bool passesGlobs(scope const(char)[] rel, scope const(string)[] include,
    scope const(string)[] exclude) @safe
{
    if (include.length && globAny(rel, include))
        return true;
    return !(exclude.length && globAny(rel, exclude));
}

/// `true` iff any of `globs` matches `rel` or its base name — so `*.d` and
/// `src/*.d` both work without the caller pre-splitting the path.
bool globAny(scope const(char)[] rel, scope const(string)[] globs) @safe
{
    import std.path : baseName, globMatch;

    foreach (g; globs)
        if (globMatch(rel, g) || globMatch(rel.baseName, g))
            return true;
    return false;
}

/**
The walker hook: `GitRepositoryFilter`'s `.gitignore` verdict, then the
`include`/`exclude` globs on top of it.

Entering directories is delegated verbatim — the filter's scope stack pushes on
`enterDir` and pops on `leaveDir`, so short-circuiting either would unbalance
it. An ignored $(I directory) is therefore still not descended: an `include`
glob re-admits files the walk reaches, it does not force entry.
*/
struct GitGlobFilter
{
    GitRepositoryFilter git;
    const(string)[] include;
    const(string)[] exclude;

    bool enterDir(const(char)[] rel) @safe => git.enterDir(rel);

    void leaveDir(const(char)[] rel) @safe pure { git.leaveDir(rel); }

    bool includeFile(const(char)[] rel) @safe
    {
        // `include` overrides `.gitignore` (its documented meaning), but never
        // `.git/` itself: repository metadata is not a document.
        if (include.length && globAny(rel, include))
            return !isGitPath(rel);
        return git.includeFile(rel) && passesGlobs(rel, null, exclude);
    }
}

/// `true` iff `rel` is inside the repository's `.git` directory.
private bool isGitPath(scope const(char)[] rel) @safe pure nothrow @nogc
{
    import std.algorithm.searching : startsWith;

    return rel == ".git" || rel.startsWith(".git/");
}

/**
Traverses `root` using the `.gitignore` files found on disk — ancestor scopes
included, as `walkGitRepository` — with `include`/`exclude` globs layered on
top ($(LREF GitGlobFilter)).
*/
DirWalkerRange!GitGlobFilter globWalkGitRepository(string root,
    scope const(string)[] include = null, scope const(string)[] exclude = null) @safe
{
    auto filter = GitGlobFilter(
        git: GitRepositoryFilter(root, repositoryGitIgnoreStack(root)),
        include: include.dup,
        exclude: exclude.dup);
    return dirEntriesFilter(root, filter);
}

// ---------------------------------------------------------------------------

@("buildPrimitives.globWalk.includeWinsOverExclude")
@safe
unittest
{
    // No globs: everything passes.
    assert(passesGlobs("src/app.d", null, null));
    // `exclude` drops, matched against the base name or the whole path.
    assert(!passesGlobs("src/app.d", null, ["*.d"]));
    assert(!passesGlobs("src/app.d", null, ["src/*"]));
    assert(passesGlobs("src/app.md", null, ["*.d"]));
    // `include` wins over `exclude` (the explorer's precedence), and does not
    // itself restrict what an empty `exclude` already admits.
    assert(passesGlobs("src/app.d", ["app.d"], ["*.d"]));
    assert(passesGlobs("src/app.d", ["*.md"], null));
}

@("buildPrimitives.globWalk.globsOverGitignoreWalk")
@system
unittest
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath, dirName;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "globWalk-" ~ randomUUID.toString);
    foreach (pair; [
        [".gitignore", "build/\n*.tmp\n"],
        ["src/app.d", "module app;\n"],
        ["src/notes.md", "# notes\n"],
        ["src/scratch.tmp", "ignored\n"],
        ["build/out.d", "ignored\n"],
        [".git/config", "[core]\n"],
    ])
    {
        const path = buildPath(root, pair[0]);
        mkdirRecurse(path.dirName);
        write(path, pair[1]);
    }
    scope (exit)
        rmdirRecurse(root);

    static string[] sorted(R)(R r)
    {
        auto files = r.array;
        files.sort;
        return files;
    }

    // `.gitignore` and `.git/` filtering come from the repository walk.
    assert(sorted(globWalkGitRepository(root))
        == [".gitignore", "src/app.d", "src/notes.md"]);
    // `exclude` drops on top of it; `include` re-admits an ignored file.
    assert(sorted(globWalkGitRepository(root, null, ["*.md"]))
        == [".gitignore", "src/app.d"]);
    assert(sorted(globWalkGitRepository(root, ["*.tmp"]))
        == [".gitignore", "src/app.d", "src/notes.md", "src/scratch.tmp"]);
    // An ignored directory is still not descended: `include` re-admits files
    // the walk reaches, it does not force entry (the scope stack owns that).
    assert(sorted(globWalkGitRepository(root, ["out.d"]))
        == [".gitignore", "src/app.d", "src/notes.md"]);
}
