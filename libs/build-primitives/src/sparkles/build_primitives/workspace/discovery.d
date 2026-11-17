/++
The workspace: the root recipe and every sub-package recipe it lists, read
once through the capability VFS into one value, with the record of what was
read ([design](../../../../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md),
BGW1).

The package graph
($(REF buildPackageGraph, sparkles,build_primitives,workspace,package_graph)),
the input sets
($(REF inputSets, sparkles,build_primitives,workspace,input_sets)) and the
commands that list the repository's packages are derived from a
$(LREF Workspace), and none of them reads a recipe again. Its read set says
which files it came from and what they held, so a plan built on it knows the
files that, changed, make it stale (BGP1), and a watch knows to read them
again.

$(LREF readWorkspace) reads through a directory handle, so a test reads a
tree literal in memory and nothing reaches the process's file system.
$(LREF readWorkspaceAt) opens a directory by path, for a command's entry
point.
+/
module sparkles.build_primitives.workspace.discovery;

import sparkles.base.io.errors : ErrorKind, IoError;
import sparkles.base.vfs.handles : DirRef;
import sparkles.base.vfs.types : OpenMode, Rights;
import sparkles.build_primitives.dub_manifest : DubManifest, parseDubManifest;
import sparkles.build_primitives.task.model : PlanExpected, planErr, planOk;
import sparkles.build_primitives.workspace.package_graph : DiscoveryError, DiscoveryErrorKind,
    normalizeRepoPath, SubPackageRecipe;

/// What a read was.
enum ReadKind : ubyte
{
    file,    /// a file's bytes were read
    probe,   /// only whether the path exists was asked
    listing, /// the files beneath a directory were listed (`names` says which)
    /// a lookup crossed a symbolic link; `names` is its target (BGF3)
    link,
    /// a `pkg-config` query: `path` is `pkg-config`, `names` its arguments,
    /// the digest that of its status and output
    query,
    /// an environment variable: `path` is its name, the digest that of its
    /// value; not `found` when unset
    environment,
}

/**
A path planning read: its path and what it held. A file's digest is that of
its bytes; a listing's, that of its members, one per line, in order; a
probe's is zero.
*/
struct ReadEntry
{
    string path;       /// repository-relative, `/`-separated, or absolute for a resolution's
    bool found;        /// whether it existed; an absent one is read as absent
    ubyte[32] digest;  /// BLAKE3 (D48); zero when absent, and for a probe
    ReadKind kind;     ///
    string names;      /// a listing's name patterns, space-separated: `*.d *.di`; a link's target; a query's arguments
}

/// The files a value was derived from (BGP1), sorted by path, each once.
struct ReadSet
{
    ReadEntry[] entries; ///

    /// Records that the file `path` was read, holding `bytes`, or was absent.
    void add(string path, scope const(ubyte)[] bytes, bool found) @safe pure nothrow
    {
        import sparkles.base.hash.blake3 : blake3;

        ReadEntry e = ReadEntry(path, found);
        if (found)
            e.digest = blake3(bytes);
        put(e);
    }

    /// Records an entry: sorted by path, then kind, then names; a second
    /// read of the same replaces the first.
    void put(ReadEntry e) @safe pure nothrow
    {
        static bool before(const ref ReadEntry a, const ref ReadEntry b) @safe pure nothrow @nogc
            => a.path != b.path ? a.path < b.path : a.kind != b.kind ? a.kind < b.kind : a.names < b.names;

        size_t at = entries.length;
        while (at > 0 && before(e, entries[at - 1]))
            --at;
        if (at > 0 && entries[at - 1].path == e.path && entries[at - 1].kind == e.kind
                && entries[at - 1].names == e.names)
        {
            entries[at - 1] = e;
            return;
        }
        entries = entries[0 .. at] ~ e ~ entries[at .. $];
    }

    /// The paths read, in order.
    string[] paths() const @safe pure nothrow
    {
        string[] result;
        foreach (ref e; entries)
            result ~= e.path;
        return result;
    }
}

/**
The repository's recipes, read once: the root's, and each sub-package's in
the order the root lists them, with what was read.
*/
struct Workspace
{
    string rootName;            /// the root package's name: `sparkles`
    DubManifest root;           /// the root recipe
    SubPackageRecipe[] recipes; /// in the order the root recipe lists them
    ReadSet reads;              /// every recipe read (BGP1)

    /// The full names of the packages in the repository, the root's first:
    /// `sparkles`, `sparkles:base`, …
    string[] packageNames() const @safe pure nothrow
    {
        string[] names = [rootName];
        foreach (ref r; recipes)
            if (r.manifest.name.length)
                names ~= rootName ~ ":" ~ r.manifest.name;
        return names;
    }

    /// The sub-packages' directories, as the root lists them, normalized.
    string[] packageDirectories() const @safe pure nothrow
    {
        string[] dirs;
        foreach (ref r; recipes)
            dirs ~= normalizeRepoPath(r.path);
        return dirs;
    }
}

/**
Reads the root recipe beneath `worktree` and every sub-package recipe it
lists, each once, through the handle. Fails on the first recipe that is
absent, unreadable or invalid, on an inline sub-package, and on a root with no
name.
*/
PlanExpected!(Workspace, DiscoveryError) readWorkspace(V, Rights R)(DirRef!(V, R) worktree)
{
    import std.conv : text;

    alias fail = (kind, detail) => planErr!Workspace(DiscoveryError(kind, detail));

    Workspace w;
    auto root = readRecipe(worktree, "dub.sdl", w.reads);
    if (root.hasError)
        return w.reads.entries[0].found ? planErr!Workspace(root.error)
            : fail(DiscoveryErrorKind.noRootRecipe, "dub.sdl");
    if (root.value.name.length == 0)
        return fail(DiscoveryErrorKind.unnamedPackage, "dub.sdl");
    w.rootName = root.value.name;
    w.root = root.value;
    foreach (ref sub; w.root.subPackages)
    {
        if (sub.path.length == 0)
            return fail(DiscoveryErrorKind.inlineSubPackage, sub.name);
        auto manifest = readRecipe(worktree, normalizeRepoPath(sub.path) ~ "/dub.sdl", w.reads);
        if (manifest.hasError)
            return planErr!Workspace(manifest.error);
        w.recipes ~= SubPackageRecipe(sub.path, manifest.value);
    }
    return planOk!DiscoveryError(w);
}

/**
Opens `repoRoot` read-only on the blocking backend and reads its workspace
($(LREF readWorkspace)): a command's entry point. The only place discovery
names a path of the process's file system.
*/
PlanExpected!(Workspace, DiscoveryError) readWorkspaceAt(string repoRoot) @safe
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.event_horizon.sys : BlockingVfs;

    auto vfs = new BlockingVfs;
    auto root = openRoot!(Rights.readOnly)(vfs, repoRoot, ambientAuthority());
    if (root.hasError)
        return planErr!Workspace(DiscoveryError(DiscoveryErrorKind.unreadableRecipe,
            repoRoot ~ ": " ~ describe(root.error)));
    return readWorkspace(root.value.borrow);
}

// Reads and parses the recipe at the repository-relative `path`, recording
// the read in `reads`.
private PlanExpected!(DubManifest, DiscoveryError) readRecipe(V, Rights R)(DirRef!(V, R) worktree,
    string path, ref ReadSet reads)
{
    import std.conv : text;

    alias unreadable = (reason) => planErr!DubManifest(
        DiscoveryError(DiscoveryErrorKind.unreadableRecipe, path ~ ": " ~ reason));

    size_t slash = path.length;
    while (slash > 0 && path[slash - 1] != '/')
        --slash;
    ubyte[] bytes;
    bool found;
    string why;
    if (slash == 0)
        why = readWhole(worktree, path, bytes, found);
    else
    {
        auto dir = worktree.walk(path[0 .. slash - 1]);
        if (dir.hasError)
            why = describe(dir.error);
        else
            why = readWhole(dir.value.borrow, path[slash .. $], bytes, found);
    }
    reads.add(path, bytes, found);
    if (why.length)
        return unreadable(why);
    auto parsed = parseDubManifest(cast(const(char)[]) bytes, path);
    if (parsed.hasError)
        return unreadable(text(parsed.error));
    return planOk!DiscoveryError(parsed.value);
}

// Reads the whole file `name` beneath `dir` into `bytes`; the reason it
// could not, or null. `found` is false when the file does not exist.
private string readWhole(V, Rights R)(DirRef!(V, R) dir, scope const(char)[] name, out ubyte[] bytes,
    out bool found)
{
    auto file = dir.openFile!(OpenMode.read)(name);
    if (file.hasError)
        return describe(file.error);
    found = true;
    ubyte[] buffer = new ubyte[4096];
    size_t n;
    while (true)
    {
        if (n == buffer.length)
            buffer.length *= 2;
        auto r = file.value.read(buffer[n .. $]);
        if (r.hasError)
            return describe(r.error);
        if (r.value == 0)
            break;
        n += r.value;
    }
    bytes = buffer[0 .. n];
    return null;
}

// What an I/O error says to a reader of a discovery error.
private string describe(const IoError e) @safe pure nothrow
{
    if (e.kind == ErrorKind.notFound)
        return "no such file";
    string name = "error";
    static foreach (member; __traits(allMembers, ErrorKind))
        if (e.kind == __traits(getMember, ErrorKind, member))
            name = member;
    return name ~ (e.context.length ? " (" ~ e.context ~ ")" : "");
}

version (unittest)
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.tree_literal : memTree;
}

/// A workspace read from a tree literal: nothing reaches the process's file
/// system, and every recipe read is recorded once, with its digest.
@("build_primitives.workspace.discovery.readWorkspace.treeLiteral")
@system
unittest
{
    import sparkles.base.hash.blake3 : blake3;

    auto tree = memTree(`dub.sdl = name "r"\nsubPackage "./libs/base/"\nsubPackage "apps/app"
        libs/base/dub.sdl = name "base"
        libs/base/src/a.d
        libs/base/README.md
        apps/app/dub.sdl = name "app"\ndependency "r:base" path="../.."
    `);
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    const w = readWorkspace(root.value.borrow);
    assert(!w.hasError, w.hasError ? w.error.detail : "");

    assert(w.value.rootName == "r");
    assert(w.value.packageNames == ["r", "r:base", "r:app"]);
    assert(w.value.packageDirectories == ["libs/base", "apps/app"]);
    assert(w.value.recipes[1].manifest.dependencies.length == 1);
    assert(w.value.reads.paths == ["apps/app/dub.sdl", "dub.sdl", "libs/base/dub.sdl"]);
    assert(w.value.reads.entries[2].found && w.value.reads.entries[2].digest == blake3(`name "base"`));
}

/// What makes reading fail, each recorded in the read set as read so far.
@("build_primitives.workspace.discovery.readWorkspace.errors")
@system
unittest
{
    static string failure(string literal)
    {
        auto tree = memTree(literal);
        auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
        const w = readWorkspace(root.value.borrow);
        assert(w.hasError, literal);
        return w.error.detail;
    }

    import std.algorithm.searching : startsWith;

    assert(failure("README.md") == "dub.sdl");
    assert(failure(`dub.sdl = name "r"\nsubPackage "libs/gone"`).startsWith("libs/gone/dub.sdl: "));
    assert(failure(`dub.sdl = subPackage "libs/a"`) == "dub.sdl");
    assert(failure(`dub.sdl = name "r"\nsubPackage "libs/a"
        libs/a/dub.sdl = name`).startsWith("libs/a/dub.sdl: "));
}
