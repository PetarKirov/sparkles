/**
The resolver's file access (build-graph SPEC §11; fileset-native workspace
design BGW1, BGW8): every recipe read, existence probe and file listing
resolution makes goes through a $(LREF ResolveTree), and its one
implementation, $(LREF VfsTree), reads through the capability VFS. A listing
is a fileset resolution, not a directory walk, so it skips what dub skips by
the same rule the input sets state.

Paths are absolute and normalized. A tree serves them from the directories
mounted on it: $(LREF systemTree) mounts the file system's roots as it meets
them, with ambient authority, and is the only place resolution names the
process's file system; $(LREF memoryTree) serves a map of files from memory,
so a test reads no disk. Every read and probe is recorded in the tree's read
set (BGP1): the files resolution depended on, found or absent.
*/
module sparkles.build_primitives.resolve.tree;

import sparkles.base.vfs.handles : Dir;
import sparkles.base.vfs.types : EntryKind, OpenMode, Rights;
import sparkles.build_primitives.workspace.discovery : ReadSet;

/// What resolution reads of the file system.
interface ResolveTree
{
    /// The text of the file at the absolute `path`; false when there is no
    /// such file.
    bool readText(string path, out string text) @safe;

    /// Whether `path` names a directory, a link to one included.
    bool isDirectory(string path) @safe;

    /// Whether `path` names anything.
    bool exists(string path) @safe;

    /**
    The files beneath the directory `root` whose base name matches one of
    the fileset name patterns `names` (`*.d`), without any with a hidden
    component beneath `root`, as dub's `collectFiles` takes them: absolute,
    sorted. Empty when `root` is no directory.
    */
    string[] files(string root, scope const(string)[] names) @safe;

    /// The files read and the paths probed so far, each with what was
    /// found.
    ReadSet reads() @safe;
}

/**
A tree over the capability-VFS backend `V`: the directories mounted on it
serve the absolute paths beneath them. With `ambient`, a path no mount
serves mounts its file system's root (`/`, or a drive on Windows) on first
use.

`keep` is held for the tree's lifetime and dropped after its mounts are
closed: the owner of the storage `vfs` points into, when nothing else owns
it. The mounts live off the GC heap, so that the tree's destructor closes
them before `keep` goes. As GC objects of their own they could be finalized
after the tree, closing a handle on a backend already freed.
*/
final class VfsTree(V, Keep = typeof(null)) : ResolveTree
{
    private V* vfs;
    private Mount*[] mounts; // each malloc'd, released by the destructor
    private bool ambient;
    private ReadSet reads_;
    private Keep keep; // destroyed after the destructor's body, so after the mounts

    // A directory mounted at an absolute prefix.
    private static struct Mount
    {
        string prefix; // absolute, ending in `/`
        Dir!(V, Rights.readOnly) dir;
    }

    /// A tree with nothing mounted, reading through `vfs`.
    this(V* vfs, bool ambient = false) @safe pure nothrow @nogc
    {
        this.vfs = vfs;
        this.ambient = ambient;
    }

    static if (!is(Keep == typeof(null)))
    {
        /// A tree with nothing mounted, reading through `vfs`, which `keep`
        /// owns.
        this(V* vfs, Keep keep) @safe
        {
            import core.lifetime : move;

            this.vfs = vfs;
            this.keep = move(keep);
        }
    }

    ~this()
    {
        import core.memory : GC, pureFree;

        foreach (m; mounts)
            (() @trusted {
                destroy(*m);
                GC.removeRange(m);
                pureFree(m);
            })();
        mounts = null;
    }

    /// Serves the absolute directory `prefix` from `dir`.
    void mount(string prefix, Dir!(V, Rights.readOnly) dir) @safe
    {
        import core.lifetime : emplace, move;
        import core.memory : GC, pureMalloc;

        auto m = (() @trusted {
            auto p = cast(Mount*) pureMalloc(Mount.sizeof);
            assert(p !is null, "out of memory for a mount");
            // The prefix is GC memory, and so may be what the handle holds.
            GC.addRange(p, Mount.sizeof);
            return emplace(p);
        })();
        m.prefix = withSlash(slashes(prefix));
        m.dir = move(dir);
        mounts ~= m;
    }

    bool readText(string path, out string text) @safe
    {
        const(ubyte)[] bytes;
        const found = read(path, bytes);
        reads_.add(slashes(path), bytes, found);
        if (found)
            text = (() @trusted => cast(string) bytes)();
        return found;
    }

    bool isDirectory(string path) @safe
    {
        size_t at;
        string relative;
        if (!locate(path, at, relative))
            return false;
        if (relative.length == 0)
            return true;
        return !mounts[at].dir.walk(relative).hasError;
    }

    bool exists(string path) @safe
    {
        size_t at;
        string relative;
        bool found;
        if (locate(path, at, relative))
        {
            if (relative.length == 0)
                found = true;
            else
            {
                const slash = lastSlash(relative);
                if (slash < 0)
                    found = !mounts[at].dir.statAt(relative).hasError;
                else
                {
                    auto parent = mounts[at].dir.walk(relative[0 .. slash]);
                    found = !parent.hasError && !parent.value.statAt(relative[slash + 1 .. $]).hasError;
                }
            }
        }
        reads_.add(slashes(path), null, found);
        return found;
    }

    string[] files(string root, scope const(string)[] names) @safe
    {
        import std.algorithm.sorting : sort;
        import sparkles.build_primitives.fileset.driver : PathCollector, resolve;
        import sparkles.build_primitives.fileset.pattern : CasePolicy;
        import sparkles.build_primitives.fileset.value : Fileset, Filesets;

        size_t at;
        string relative;
        if (!locate(root, at, relative))
            return null;
        auto sets = Filesets(CasePolicy.sensitive);
        Fileset f = sets.nothing;
        foreach (name; names)
        {
            auto g = sets.glob("/**/" ~ name);
            if (!g.hasError)
                f = sets.union_(f, g.value);
        }
        f = sets.difference(f, sets.glob("/**/.*").value);
        PathCollector sink;
        if (relative.length == 0)
            cast(void) resolve(mounts[at].dir.borrow, sets, f, sink);
        else
        {
            auto dir = mounts[at].dir.walk(relative);
            if (dir.hasError)
                return null;
            cast(void) resolve(dir.value.borrow, sets, f, sink);
        }
        const base = withSlash(slashes(root));
        string[] result;
        foreach (member; sink.members)
            result ~= base ~ member;
        return result.sort.release;
    }

    ReadSet reads() @safe => reads_;

    // The bytes of the file at `path`, if it is one.
    private bool read(string path, out const(ubyte)[] bytes) @safe
    {
        size_t at;
        string relative;
        if (!locate(path, at, relative) || relative.length == 0)
            return false;
        const slash = lastSlash(relative);
        if (slash < 0)
            return readIn(mounts[at].dir, relative, bytes);
        auto parent = mounts[at].dir.walk(relative[0 .. slash]);
        return !parent.hasError && readIn(parent.value, relative[slash + 1 .. $], bytes);
    }

    private static bool readIn(D)(ref D dir, scope const(char)[] name, out const(ubyte)[] bytes) @safe
    {
        auto file = dir.openFile!(OpenMode.read)(name);
        if (file.hasError)
            return false;
        ubyte[] buffer = new ubyte[4096];
        size_t n;
        while (true)
        {
            if (n == buffer.length)
                buffer.length *= 2;
            auto r = file.value.read(buffer[n .. $]);
            if (r.hasError)
                return false;
            if (r.value == 0)
                break;
            n += r.value;
        }
        bytes = buffer[0 .. n];
        return true;
    }

    // The mount serving `path` and the path beneath it, the longest mount
    // first; with `ambient`, the root of `path`'s file system is mounted
    // when nothing serves it.
    private bool locate(string path, out size_t at, out string relative) @safe
    {
        const p = slashes(path);
        if (findMount(p, at, relative))
            return true;
        if (!ambient)
            return false;
        const root = fileSystemRoot(p);
        if (root is null)
            return false;
        static if (is(typeof(openAmbient!V(vfs, root))))
        {
            auto opened = openAmbient!V(vfs, root);
            if (opened.hasError)
                return false;
            import core.lifetime : move;

            mount(root, move(opened.value));
        }
        else
            return false;
        return findMount(p, at, relative);
    }

    private bool findMount(string p, out size_t at, out string relative) @safe pure nothrow
    {
        ptrdiff_t best = -1;
        foreach (i, m; mounts)
        {
            const inside = (p ~ "/") == m.prefix
                || (p.length >= m.prefix.length && p[0 .. m.prefix.length] == m.prefix);
            if (inside && (best < 0 || m.prefix.length > mounts[best].prefix.length))
                best = i;
        }
        if (best < 0)
            return false;
        at = best;
        const prefix = mounts[best].prefix;
        relative = p.length >= prefix.length ? trimSlashes(p[prefix.length .. $]) : "";
        return true;
    }
}

// Opens the file system root `root` read-only on `vfs` with ambient
// authority. As dub reads it: links are followed, and a file system mounted
// beneath it is crossed, so the policy follows links beneath the root, which
// every target is, and crosses mounts.
private auto openAmbient(V)(V* vfs, string root) @safe
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, SymlinkPolicy;

    const policy = ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject, crossMounts: true);
    return openRoot!(Rights.readOnly)(vfs, root, ambientAuthority(), policy);
}

/**
A tree over the process's file system, read through the blocking backend:
each file system root is mounted, with ambient authority, when a path first
needs it.
*/
ResolveTree systemTree() @safe
{
    import sparkles.event_horizon.sys : BlockingVfs;

    return new VfsTree!BlockingVfs(new BlockingVfs, ambient: true);
}

/**
A tree that serves `files`, a map from absolute `/`-separated path to text,
from memory: built into a tree literal, so it is read through the VFS as a
disk would be. Tests change a file by building the tree again.
*/
ResolveTree memoryTree(const string[string] files) @safe
{
    import core.lifetime : move;
    import sparkles.base.unique : Unique;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.mem : MemVfs;
    import sparkles.build_primitives.fileset.tree_literal : MemTree, memTree;

    string literal;
    size_t bytes;
    foreach (path, text; files)
    {
        // An empty file is its bare path: a trailing ` = ` would be trimmed.
        literal ~= trimSlashes(path) ~ (text.length ? " = " ~ escapedLiteral(text) : "") ~ "\n";
        bytes += text.length + path.length;
    }
    auto made = memTree(literal, spareNodes: 64 + 4 * files.length, spareBytes: 4096 + 2 * bytes);
    assert(!made.hasError, "a tree literal of the files");
    // The tree owns the `MemTree`, whose storage stays where it is as the
    // owner moves, and closes its root before freeing it.
    auto vfs = &made.value.get().vfs;
    auto tree = new VfsTree!(MemVfs, Unique!MemTree)(vfs, move(made.value));
    auto root = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority());
    assert(!root.hasError, "the tree's root");
    tree.mount("/", move(root.value));
    return tree;
}

// `text` as a tree literal's value writes it: `\n` and `\\` escaped.
private string escapedLiteral(string text) @safe pure nothrow
{
    string result;
    foreach (c; text)
        result ~= c == '\n' ? `\n` : c == '\\' ? `\\` : [c];
    return result;
}

// `path` with `\` as `/`.
private string slashes(string path) @safe pure nothrow
{
    foreach (c; path)
        if (c == '\\')
        {
            auto copy = path.dup;
            foreach (ref d; copy)
                if (d == '\\')
                    d = '/';
            return (() @trusted => cast(string) copy)();
        }
    return path;
}

private string withSlash(string path) @safe pure nothrow => path.length && path[$ - 1] == '/' ? path : path ~ "/";

private string trimSlashes(string path) @safe pure nothrow @nogc
{
    while (path.length && path[0] == '/')
        path = path[1 .. $];
    while (path.length && path[$ - 1] == '/')
        path = path[0 .. $ - 1];
    return path;
}

private ptrdiff_t lastSlash(scope const(char)[] path) @safe pure nothrow @nogc
{
    foreach_reverse (i, c; path)
        if (c == '/')
            return i;
    return -1;
}

// The root of the file system `path` lies on: `/`, or `C:/`; null for a
// relative path.
private string fileSystemRoot(string path) @safe pure nothrow
{
    if (path.length && path[0] == '/')
        return "/";
    if (path.length >= 3 && path[1] == ':' && path[2] == '/')
        return path[0 .. 3];
    return null;
}

/// A memory tree serves its files, lists by fileset patterns without hidden
/// components, and records what was read and probed.
@("build_primitives.resolve.tree.memoryTree")
@safe
unittest
{
    auto tree = memoryTree([
        "/r/dub.sdl": "name \"r\"\n",
        "/r/source/app.d": "void main() {}",
        "/r/source/sub/b.d": "",
        "/r/source/.hidden/c.d": "",
        "/r/source/.d": "",
        "/r/source/notes.txt": "",
        "/r/views/logo.txt": "",
    ]);
    string text;
    assert(tree.readText("/r/dub.sdl", text) && text == "name \"r\"\n");
    assert(!tree.readText("/r/dub.json", text));
    assert(tree.isDirectory("/r/source") && tree.isDirectory("/r") && !tree.isDirectory("/r/dub.sdl"));
    assert(tree.exists("/r/views/logo.txt"), "a file exists");
    assert(tree.exists("/r/views"), "a directory exists");
    assert(!tree.exists("/r/src"), "an absent one does not");
    assert(tree.files("/r/source", ["*.d"]) == ["/r/source/app.d", "/r/source/sub/b.d"]);
    assert(tree.files("/r/source/", ["*"]) == ["/r/source/app.d", "/r/source/notes.txt", "/r/source/sub/b.d"]);
    assert(tree.files("/r/absent", ["*"]) == []);
    assert(tree.reads.paths == ["/r/dub.json", "/r/dub.sdl", "/r/src", "/r/views", "/r/views/logo.txt"],
        tree.reads.paths.text);
}

version (unittest) import std.conv : text;
