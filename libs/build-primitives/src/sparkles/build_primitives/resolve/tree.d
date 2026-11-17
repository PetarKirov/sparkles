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
import sparkles.base.vfs.types : Stat;
import sparkles.build_primitives.task.model : PlanExpected;
import sparkles.build_primitives.workspace.discovery : ReadEntry, ReadKind, ReadSet, Workspace;
import sparkles.build_primitives.workspace.package_graph : DiscoveryError;

/// What resolution reads of the file system.
interface ResolveTree
{
    /// The text of the file at the absolute `path`; false when there is no
    /// such file.
    bool readText(string path, out string text) @safe;

    /// Whether `path` names a directory, a link to one included: a probe
    /// whose `names` is `directory`.
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

    /// The files read, the paths probed and the directories listed so far,
    /// each with what was found.
    ReadSet reads() @safe;

    /**
    Runs `work` and returns what it read, probed and listed, a listing the
    tree had cached included: the read set of one resolution, when the tree
    serves several.
    */
    ReadSet recorded(scope void delegate() @safe work) @safe;

    /// How many listings the tree has made, as opposed to served from its
    /// cache.
    size_t listingsMade() @safe;

    /**
    The workspace whose root recipe is in the directory `root`, read through
    the root that serves it (BGF2), its reads recorded with absolute paths.
    */
    PlanExpected!(Workspace, DiscoveryError) workspace(string root) @safe;

    /// Records a `pkg-config` query, its exit status and its output (BGP1).
    void noteQuery(scope const(string)[] arguments, int status, scope const(char)[] output) @safe;

    /// Records that planning consulted the environment variable `name`,
    /// and its value, or that it was unset (BGP1).
    void noteEnvironment(string name, scope const(char)[] value, bool set) @safe;

    /// What must fail planning: a link that is absolute or climbs above the
    /// root holding it, and a path beneath no root (BGF3).
    const(TreeFault)[] faults() @safe;
}

/// A lookup the tree refused (BGF3).
struct TreeFault
{
    string path;   /// the link, absolute; or the path no root serves
    string target; /// the link's target; empty for a path no root serves
    string reason; ///
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
    private ReadSet* recording;
    private string[][string] listed; // by root and names: each listing made once
    private bool[string] rootFound;  // by the same key: whether the root was a directory
    private size_t listingsMade_;
    private TreeFault[] faults_;
    private bool strict; // a path beneath no mount is a fault
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
        import sparkles.base.hash.blake3 : blake3;

        const(ubyte)[] bytes;
        string resolved;
        const found = read(path, bytes, resolved);

        auto e = ReadEntry(slashes(path), found);
        if (found)
            e.digest = blake3(bytes);
        note(e);
        // Read through a link: the target is read too (BGF3).
        if (found && resolved != e.path)
        {
            e.path = resolved;
            note(e);
        }
        if (found)
            text = (() @trusted => cast(string) bytes)();
        return found;
    }

    bool isDirectory(string path) @safe
    {
        size_t at;
        string dir, name;
        Stat st;
        const found = lookup(path, at, dir, name, st) && st.kind == EntryKind.directory;
        note(ReadEntry(slashes(path), found, (ubyte[32]).init, ReadKind.probe, "directory"));
        return found;
    }

    bool exists(string path) @safe
    {
        size_t at;
        string dir, name;
        Stat st;
        const found = lookup(path, at, dir, name, st);
        note(ReadEntry(slashes(path), found, (ubyte[32]).init, ReadKind.probe));
        return found;
    }

    PlanExpected!(Workspace, DiscoveryError) workspace(string root) @safe
    {
        import sparkles.build_primitives.task.model : planErr;
        import sparkles.build_primitives.workspace.discovery : readWorkspace;
        import sparkles.build_primitives.workspace.package_graph : DiscoveryErrorKind;

        size_t at;
        string relative;
        if (!locate(root, at, relative))
            return planErr!Workspace(DiscoveryError(DiscoveryErrorKind.unreadableRecipe,
                root ~ ": beneath no root the tree serves"));
        auto w = (() {
            if (relative.length == 0)
                return readWorkspace(mounts[at].dir.borrow);
            auto dir = mounts[at].dir.walk(relative);
            if (dir.hasError)
                return planErr!Workspace(DiscoveryError(DiscoveryErrorKind.unreadableRecipe,
                    root ~ ": not a directory"));
            return readWorkspace(dir.value.borrow);
        })();
        if (!w.hasError)
        {
            const base = withSlash(slashes(root));
            foreach (e; w.value.reads.entries)
            {
                auto absolute = e;
                absolute.path = base ~ e.path;
                note(absolute);
            }
        }
        return w;
    }

    void noteQuery(scope const(string)[] arguments, int status, scope const(char)[] output) @safe
    {
        import std.conv : text;
        import sparkles.base.hash.blake3 : blake3;

        string joined;
        foreach (i, a; arguments)
            joined ~= (i ? " " : "") ~ a;
        const answer = text(status, "\n", output);
        note(ReadEntry("pkg-config", status == 0, blake3(cast(const(ubyte)[]) answer), ReadKind.query, joined));
    }

    void noteEnvironment(string name, scope const(char)[] value, bool set) @safe
    {
        import sparkles.base.hash.blake3 : blake3;

        note(ReadEntry(name, set, set ? blake3(cast(const(ubyte)[]) value) : (ubyte[32]).init,
            ReadKind.environment));
    }

    const(TreeFault)[] faults() @safe => faults_;

    string[] files(string root, scope const(string)[] names) @safe
    {
        import std.algorithm.sorting : sort;
        import sparkles.build_primitives.fileset.driver : PathCollector, resolve;
        import sparkles.build_primitives.fileset.pattern : CasePolicy;
        import sparkles.build_primitives.fileset.value : Fileset, Filesets;

        const base = withSlash(slashes(root));
        string key = base;
        foreach (name; names)
            key ~= " " ~ name;
        if (auto cached = key in listed)
        {
            noteListing(base, names, *cached, rootFound[key]);
            return (*cached).dup;
        }
        bool found;
        auto made = list(root, names, found);
        listed[key] = made;
        rootFound[key] = found;
        ++listingsMade_;
        noteListing(base, names, made, found);
        return made.dup;
    }

    ReadSet reads() @safe => reads_;

    ReadSet recorded(scope void delegate() @safe work) @safe
    {
        auto into = new ReadSet;
        auto outer = recording;
        recording = into;
        scope (exit)
            recording = outer;
        work();
        return *into;
    }

    size_t listingsMade() @safe => listingsMade_;

    // Records `e` in the tree's read set and in the one being recorded.
    private void note(ReadEntry e) @safe
    {
        reads_.put(e);
        if (recording !is null)
            recording.put(e);
    }

    // Records a listing of `base` by `names`: its members' digest, or that
    // `base` was no directory.
    private void noteListing(string base, scope const(string)[] names, scope const(string)[] members,
        bool found) @safe
    {
        import sparkles.base.hash.blake3 : blake3;

        string joined, patterns;
        foreach (m; members)
            joined ~= m ~ "\n";
        foreach (i, name; names)
            patterns ~= (i ? " " : "") ~ name;
        note(ReadEntry(base, found, found ? blake3(cast(const(ubyte)[]) joined) : (ubyte[32]).init,
            ReadKind.listing, patterns));
    }

    // Lists `root` by `names`, through a fileset resolution; `found` says
    // whether `root` is a directory.
    private string[] list(string root, scope const(string)[] names, out bool found) @safe
    {
        import std.algorithm.sorting : sort;
        import sparkles.build_primitives.fileset.driver : PathCollector, resolve;
        import sparkles.build_primitives.fileset.pattern : CasePolicy;
        import sparkles.build_primitives.fileset.value : Fileset, Filesets;

        size_t at;
        string parentDir, entry;
        Stat st;
        if (!lookup(root, at, parentDir, entry, st) || st.kind != EntryKind.directory)
            return null;
        const relative = parentDir.length ? parentDir ~ "/" ~ entry : entry;
        // Resolved from the mount, not from the listed directory: a link
        // beneath it whose target climbs above it but stays in the mount
        // resolves (FSD6), as `ui-app`'s link to its specification does.
        const prefix = relative.length ? "/" ~ globEscaped(relative) : "";
        auto sets = Filesets(CasePolicy.sensitive);
        Fileset f = sets.nothing;
        foreach (name; names)
        {
            auto g = sets.glob(prefix ~ "/**/" ~ name);
            if (!g.hasError)
                f = sets.union_(f, g.value);
        }
        f = sets.difference(f, sets.glob(prefix ~ "/**/.*").value);
        PathCollector sink;
        cast(void) resolve(mounts[at].dir.borrow, sets, f, sink);
        found = true;
        // A link the resolution refused to follow out of the mount (BGF3).
        foreach (u; sink.unreadable)
            if (u.length > 13 && u[$ - 13 .. $] == ": escapesRoot")
                faults_ ~= TreeFault(mounts[at].prefix ~ u[0 .. $ - 13], null, "a link that leaves the root");
        const base = withSlash(slashes(root));
        const strip = relative.length ? relative.length + 1 : 0;
        string[] result;
        foreach (member; sink.members)
            if (member.length > strip)
                result ~= base ~ member[strip .. $];
        return result.sort.release;
    }

    // The bytes of the file at `path`, and the path it resolved to.
    private bool read(string path, out const(ubyte)[] bytes, out string resolved) @safe
    {
        size_t at;
        string dir, name;
        Stat st;
        if (!lookup(path, at, dir, name, st) || name.length == 0 || st.kind != EntryKind.regular)
            return false;
        resolved = mounts[at].prefix ~ (dir.length ? dir ~ "/" : "") ~ name;
        if (dir.length == 0)
            return readIn(mounts[at].dir, name, bytes);
        auto parent = mounts[at].dir.walk(dir);
        return !parent.hasError && readIn(parent.value, name, bytes);
    }

    /*
    Resolves the absolute `path` one entry at a time from the mount that
    serves it, as `symlinks = beneath` does (VFP5), recording each link it
    crosses with its target (BGF3). A link that is absolute or climbs above
    its mount is a fault, named by the link. On success, `at` is the mount,
    `dir` the directory holding the final entry beneath it (empty for the
    mount itself), `name` that entry (empty when `path` is the mount), and
    `stat` the entry's, with links followed.

    The directories `dir` walks through are reached through no link, so a
    walk to them under any policy finds the same directory.
    */
    private bool lookup(string path, out size_t at, out string dir, out string name, out Stat stat) @safe
    {
        import sparkles.base.hash.blake3 : blake3;

        string relative;
        if (!locate(path, at, relative))
        {
            if (strict)
                faults_ ~= TreeFault(slashes(path), null, "beneath none of the build graph's roots");
            return false;
        }
        string[] pending = components(relative);
        string[] done;
        string lastLink, lastTarget;
        size_t hops;
        while (pending.length)
        {
            const c = pending[0];
            pending = pending[1 .. $];
            if (c == "..")
            {
                if (done.length == 0)
                {
                    faults_ ~= TreeFault(lastLink, lastTarget, "a link that climbs out of " ~ mounts[at].prefix);
                    return false;
                }
                done = done[0 .. $ - 1];
                continue;
            }
            const parent = joinPath(done);
            auto st = statIn(at, parent, c);
            if (st.hasError)
                return false;
            if (st.value.kind == EntryKind.symlink)
            {
                const link = mounts[at].prefix ~ (parent.length ? parent ~ "/" : "") ~ c;
                char[4096] buffer;
                string target;
                if (!readlinkIn(at, parent, c, buffer, target))
                    return false;
                note(ReadEntry(link, true, blake3(cast(const(ubyte)[]) target), ReadKind.link, target));
                if (++hops > 40)
                {
                    faults_ ~= TreeFault(link, target, "a link loop");
                    return false;
                }
                if (target.length == 0 || fileSystemRoot(slashes(target)) !is null)
                {
                    faults_ ~= TreeFault(link, target, "an absolute link");
                    return false;
                }
                lastLink = link;
                lastTarget = target;
                pending = components(slashes(target)) ~ pending;
                continue;
            }
            if (pending.length == 0)
            {
                dir = parent;
                name = c;
                stat = st.value;
                return true;
            }
            if (st.value.kind != EntryKind.directory)
                return false;
            done ~= c;
        }
        // The path ended in the directory `done` names, through a link or `..`.
        stat.kind = EntryKind.directory;
        if (done.length)
        {
            dir = joinPath(done[0 .. $ - 1]);
            name = done[$ - 1];
        }
        return true;
    }

    // The entry `name` in the directory `parent` beneath mount `at`, links
    // not followed.
    private auto statIn(size_t at, string parent, string name) @safe
    {
        if (parent.length == 0)
            return mounts[at].dir.statAt(name);
        auto d = mounts[at].dir.walk(parent);
        if (d.hasError)
            return typeof(d.value.statAt(name))(d.error);
        return d.value.statAt(name);
    }

    private bool readlinkIn(size_t at, string parent, string name, ref char[4096] buffer, out string target) @safe
    {
        if (parent.length == 0)
        {
            auto t = mounts[at].dir.readlinkAt(name, buffer[]);
            if (t.hasError)
                return false;
            target = t.value.idup;
            return true;
        }
        auto d = mounts[at].dir.walk(parent);
        if (d.hasError)
            return false;
        auto t = d.value.readlinkAt(name, buffer[]);
        if (t.hasError)
            return false;
        target = t.value.idup;
        return true;
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
A tree over the process's file system that serves only `roots` (BGF2), each
opened once, read-only, with ambient authority. The first is the worktree,
whose listings follow links beneath it; the others are pinned registry
source directories, which follow none. A path beneath no root is a fault
(`faults`), and so is a root that cannot be opened.
*/
ResolveTree rootedTree(scope const(string)[] roots) @safe
{
    import core.lifetime : move;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, SymlinkPolicy;
    import sparkles.event_horizon.sys : BlockingVfs;

    auto vfs = new BlockingVfs;
    auto tree = new VfsTree!BlockingVfs(vfs);
    tree.strict = true;
    foreach (i, root; roots)
    {
        const policy = ResolvePolicy(i == 0 ? SymlinkPolicy.beneath : SymlinkPolicy.none, DotDotPolicy.reject,
            crossMounts: true);
        auto opened = openRoot!(Rights.readOnly)(vfs, root, ambientAuthority(), policy);
        if (opened.hasError)
        {
            tree.faults_ ~= TreeFault(root, null, "a root that cannot be opened");
            continue;
        }
        tree.mount(root, move(opened.value));
    }
    return tree;
}

/**
A tree that serves `files`, a map from absolute `/`-separated path to text,
from memory: built into a tree literal, so it is read through the VFS as a
disk would be, with `links`, a map from absolute path to link target, as
its symbolic links. Tests change a file by building the tree again.
*/
ResolveTree memoryTree(const string[string] files, const string[string] links = null) @safe
{
    import core.lifetime : move;
    import sparkles.base.unique : Unique;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.mem : MemVfs;
    import sparkles.build_primitives.fileset.tree_literal : MemTree, memTree;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, SymlinkPolicy;

    string literal;
    size_t bytes;
    foreach (path, text; files)
    {
        // An empty file is its bare path: a trailing ` = ` would be trimmed.
        literal ~= trimSlashes(path) ~ (text.length ? " = " ~ escapedLiteral(text) : "") ~ "\n";
        bytes += text.length + path.length;
    }
    foreach (path, target; links)
        literal ~= trimSlashes(path) ~ " -> " ~ target ~ "\n";
    auto made = memTree(literal, spareNodes: 64 + 4 * files.length, spareBytes: 4096 + 2 * bytes);
    assert(!made.hasError, "a tree literal of the files");
    // The tree owns the `MemTree`, whose storage stays where it is as the
    // owner moves, and closes its root before freeing it.
    auto vfs = &made.value.get().vfs;
    auto tree = new VfsTree!(MemVfs, Unique!MemTree)(vfs, move(made.value));
    // As the worktree is mounted: listings follow links beneath the root.
    auto root = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority(),
        ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject, crossMounts: true));
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

// `path` with the fileset glob's special characters escaped.
private string globEscaped(string path) @safe pure nothrow
{
    string result;
    foreach (c; path)
    {
        if (c == '*' || c == '?' || c == '[' || c == ']' || c == '{' || c == '}' || c == '\\' || c == '!')
            result ~= '\\';
        result ~= c;
    }
    return result;
}

// The non-empty components of a `/`-separated path, without `.`.
private string[] components(string path) @safe pure nothrow
{
    string[] result;
    size_t start;
    foreach (i; 0 .. path.length + 1)
        if (i == path.length || path[i] == '/')
        {
            const c = path[start .. i];
            if (c.length && c != ".")
                result ~= c;
            start = i + 1;
        }
    return result;
}

private string joinPath(scope const(string)[] parts) @safe pure nothrow
{
    string result;
    foreach (i, p; parts)
        result ~= (i ? "/" : "") ~ p;
    return result;
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
    string content;
    assert(tree.readText("/r/dub.sdl", content) && content == "name \"r\"\n");
    assert(!tree.readText("/r/dub.json", content));
    assert(tree.isDirectory("/r/source") && tree.isDirectory("/r") && !tree.isDirectory("/r/dub.sdl"));
    assert(tree.exists("/r/views/logo.txt"), "a file exists");
    assert(tree.exists("/r/views"), "a directory exists");
    assert(!tree.exists("/r/src"), "an absent one does not");
    assert(tree.files("/r/source", ["*.d"]) == ["/r/source/app.d", "/r/source/sub/b.d"]);
    assert(tree.files("/r/source/", ["*"]) == ["/r/source/app.d", "/r/source/notes.txt", "/r/source/sub/b.d"]);
    assert(tree.files("/r/absent", ["*"]) == []);
    // What was read, probed and listed, each with what it found.
    string[] reads;
    foreach (ref e; tree.reads.entries)
        reads ~= text(e.path, " ", e.kind, e.names.length ? " " ~ e.names : "", e.found ? "" : " absent");
    assert(reads == [
        "/r probe directory", "/r/absent/ listing * absent", "/r/dub.json file absent", "/r/dub.sdl file",
        "/r/dub.sdl probe directory absent", "/r/source probe directory", "/r/source/ listing *",
        "/r/source/ listing *.d", "/r/src probe absent", "/r/views probe", "/r/views/logo.txt probe",
    ], reads.text);

    // A listing is made once per root and names, and served again from the
    // tree's cache, recorded each time.
    const made = tree.listingsMade;
    const recorded = tree.recorded(() { cast(void) tree.files("/r/source", ["*.d"]); });
    assert(tree.listingsMade == made && recorded.entries.length == 1 && recorded.entries[0].kind == ReadKind.listing);
}

version (unittest) import std.conv : text;

/// A lookup through a link records the link and its target (BGF3); one to a
/// directory serves its files and listings. An absolute link, and one that
/// climbs above the root, fail the lookup as faults naming the link.
@("build_primitives.resolve.tree.links")
@safe
unittest
{
    import std.algorithm : canFind, map;
    import std.array : array;

    const files = ["/r/docs/spec.md": "spec", "/r/docs/other.md": "other"];
    auto tree = memoryTree(files, ["/r/app/spec.md": "../docs/spec.md", "/r/app/abs.md": "/etc/passwd",
        "/r/app/out.md": "../../../x", "/r/lib": "docs"]);
    string content;
    assert(tree.readText("/r/app/spec.md", content) && content == "spec");
    assert(tree.reads.entries.canFind!(e => e.kind == ReadKind.file && e.path == "/r/docs/spec.md"), "the target");
    assert(tree.reads.entries.canFind!(e => e.kind == ReadKind.link && e.path == "/r/app/spec.md"
        && e.names == "../docs/spec.md"));
    assert(tree.readText("/r/lib/other.md", content) && content == "other", "through a directory link");
    assert(tree.isDirectory("/r/lib"));
    assert(tree.files("/r/lib", ["*.md"]) == ["/r/lib/other.md", "/r/lib/spec.md"]);
    assert(tree.faults.length == 0);

    assert(!tree.readText("/r/app/abs.md", content));
    assert(!tree.exists("/r/app/out.md"));
    assert(tree.faults.map!(f => f.path ~ " " ~ f.reason).array == [
        "/r/app/abs.md an absolute link", "/r/app/out.md a link that climbs out of /",
    ], tree.faults.text);

    // Retargeting the link changes the read set.
    auto retargeted = memoryTree(files, ["/r/app/spec.md": "../docs/other.md"]);
    assert(retargeted.readText("/r/app/spec.md", content) && content == "other");
    const before = tree.reads.entries.filter!(e => e.kind == ReadKind.link && e.path == "/r/app/spec.md").front;
    const after = retargeted.reads.entries.filter!(e => e.kind == ReadKind.link).front;
    assert(before.digest != after.digest && after.names == "../docs/other.md");
}

version (unittest) import std.algorithm : filter;
