/++
Input states: what materializing an input set read, as a value
([design](../../../../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md),
BGW9, BGW13).

$(LREF observe) resolves a fileset through the capability VFS and yields an
$(LREF InputState): the members in path order, each with the BLAKE3 id of
its bytes; the castore id of the members' tree, the one
`sparkles.build_primitives.content_addressing.castore` names; every symbolic
link the resolution crossed, with its target; and every directory it
listed, members or not, which the fileset machine reports before listing it
(FSS9).

The state's own `id` covers what a reader of the members would read. A link
is a value in the tree, its target text and nothing more, so the tree's id
does not change when the file a link names does. The state's id therefore
also covers, for each link to a file, that file's id.

Two states of one set compare by `id`, and their $(LREF difference) is a
merge of two sorted lists: the $(LREF ChangeSet) a watch or git would give
for the same edits, which selection takes as it takes any other
($(LREF ChangeSet.paths)).

Every file's digest comes through one $(LREF DigestCache), validated by the
rule every cached digest follows (FSC3 and BGK5, `StatValidator`), so a run
reads a file at most once, whichever state needs it.
+/
module sparkles.build_primitives.workspace.input_state;

import std.conv : text;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.io.errors : ErrorKind;
import sparkles.base.text.errors : NoGcHook;
import sparkles.base.vfs.handles : DirRef;
import sparkles.base.vfs.types : Rights;

import sparkles.build_primitives.content_addressing.cache : CacheRejection, StatValidator;
import sparkles.build_primitives.content_addressing.castore : CastoreDirectory;
import sparkles.build_primitives.fileset.fso : EntryOrder, FsoFingerprint, FsoKind, FsoMetadata, Traversal;
import sparkles.build_primitives.fileset.machine : ResolutionError, ResolutionErrorCode, ResolutionLimits;
import sparkles.build_primitives.fileset.value : Fileset, Filesets;

/// A file's content id: BLAKE3 over its bytes (D48).
alias Digest = ubyte[32];

/// One member file of a state.
struct Member
{
    string path; /// relative to the fileset root, `/`-separated
    Digest id;   /// of its bytes
}

/// What a link's target turned out to be.
enum LinkTargetKind : ubyte
{
    file,      /// a regular file beneath the root: its id is part of the state's
    directory, /// a directory beneath the root, which the resolution entered
    absent,    /// nothing, or nothing that could be read
    outside,   /// an absolute target, or one that climbs out of the root
}

/// A symbolic link the resolution crossed.
struct LinkRead
{
    string path;         /// the link's own path
    string target;       /// its target text
    /// The target's path relative to the fileset root, `/`-separated;
    /// `null` when it lies outside.
    string resolved;
    LinkTargetKind kind; ///
    Digest id;           /// the target file's id; zero for any other kind
}

/// What materializing one fileset read (BGW9).
struct InputState
{
    Digest id;                 /// of the tree and of each link's target
    CastoreDirectory.Id tree;  /// the members' tree, as castore names it
    Member[] members;          /// in path order
    LinkRead[] links;          /// in path order
    string[] listed;           /// every directory listed, in path order
}

/// How a path changed (BGW13).
enum ChangeKind : ubyte
{
    modified, ///
    created,  ///
    removed,  ///
}

/// One changed path.
struct PathChange
{
    string path;     ///
    ChangeKind kind; ///
}

/// A set of changed paths, whichever source produced it (BGW13).
struct ChangeSet
{
    PathChange[] paths; /// sorted, each path once
    bool lossy;         /// the source may have missed changes

    /// The paths alone, for selection.
    string[] pathList() const @safe pure nothrow
    {
        string[] list;
        foreach (ref p; paths)
            list ~= p.path;
        return list;
    }
}

/**
The changes that turn `before` into `after`, two states of one set: each
member created, removed or with another id, and each link whose target or
target's id differs, by the link's path. A difference of two states is
never lossy.
*/
ChangeSet difference(const ref InputState before, const ref InputState after) @safe pure nothrow
{
    import std.algorithm.sorting : sort;

    ChangeSet set;
    if (before.id == after.id)
        return set;
    merge(before.members, after.members, set, (ref const Member a, ref const Member b) => a.id != b.id);
    merge(before.links, after.links, set,
        (ref const LinkRead a, ref const LinkRead b) => a.target != b.target || a.kind != b.kind || a.id != b.id);
    set.paths.sort!((a, b) => a.path < b.path);
    return set;
}

// Merges two lists sorted by path into `set`.
private void merge(T)(const(T)[] a, const(T)[] b, ref ChangeSet set,
    scope bool delegate(ref const T, ref const T) @safe pure nothrow differs) @safe pure nothrow
{
    size_t i, j;
    while (i < a.length || j < b.length)
    {
        if (j == b.length || (i < a.length && a[i].path < b[j].path))
            set.paths ~= PathChange(a[i++].path, ChangeKind.removed);
        else if (i == a.length || b[j].path < a[i].path)
            set.paths ~= PathChange(b[j++].path, ChangeKind.created);
        else
        {
            if (differs(a[i], b[j]))
                set.paths ~= PathChange(b[j].path, ChangeKind.modified);
            ++i;
            ++j;
        }
    }
}

/**
The digests of files by path, from one run to the next (BGW9). A recorded
digest is reused when the validator accepts the file's fingerprint against
the recording run's stamp (FSC3, BGK5); within one run a file whose
fingerprint has not moved is read once, whichever state asks for it. A
file with no fingerprint is read every time. The cache is advisory: with it
empty every id is the same, only more slowly computed.

The stored form is `encode`'s bytes, which `load` reads back; a damaged or
foreign cache is rejected whole. The cache performs no I/O.
*/
struct DigestCache(Validator = StatValidator)
{
    Validator validator; ///
    /// What the current run read, reused and found stamped in the future.
    size_t filesRead, filesReused, futureTimes;

    private static struct Record
    {
        FsoFingerprint fingerprint;
        Digest id;
    }

    private Record[string] previous, current;
    private long previousStamp, stamp;

    private enum ubyte[8] magic = cast(ubyte[8]) "SPKDIG01";

    /**
    Starts a run stamped `stampNs`, which must be no later than its first
    `stat` and read from the files' own clock (`fileSystemNow`). What the
    run before recorded stays usable, against that run's stamp.
    */
    void begin(long stampNs) @safe pure nothrow
    {
        if (current.length)
        {
            previous = current;
            previousStamp = stamp;
        }
        current = null;
        stamp = stampNs;
        filesRead = filesReused = futureTimes = 0;
    }

    /// The recorded id of `path`, if its fingerprint `fp` lets it be reused.
    bool lookup(scope const(char)[] path, bool hasFingerprint, in FsoFingerprint fp, out Digest id)
        @safe pure nothrow
    {
        if (!hasFingerprint)
            return false;
        if (auto r = path in current)
            if (r.fingerprint == fp)
            {
                id = r.id;
                ++filesReused;
                return true;
            }
        if (auto r = path in previous)
            if (validator.unchanged(r.fingerprint, fp, previousStamp))
            {
                id = r.id;
                current[path.idup] = *r;
                ++filesReused;
                return true;
            }
        return false;
    }

    /// Records that `path` was read and holds `id`.
    void record(scope const(char)[] path, bool hasFingerprint, in FsoFingerprint fp, in Digest id)
        @safe pure nothrow
    {
        ++filesRead;
        if (!hasFingerprint)
            return;
        current[path.idup] = Record(fp, id);
        if (fp.mtimeNs > stamp)
            ++futureTimes;
    }

    /// This run's record, for the next run's `load`.
    ubyte[] encode() const @safe pure nothrow
    {
        import std.algorithm.sorting : sort;
        import std.array : array;
        import sparkles.base.hash.blake3 : blake3;

        ubyte[] bytes = magic[].dup;
        putLong(bytes, stamp);
        putLong(bytes, current.length);
        auto paths = current.keys.array;
        paths.sort();
        foreach (p; paths)
        {
            const r = current[p];
            putLong(bytes, p.length);
            bytes ~= cast(const(ubyte)[]) p;
            putLong(bytes, r.fingerprint.size);
            putLong(bytes, r.fingerprint.device);
            putLong(bytes, r.fingerprint.inode);
            putLong(bytes, r.fingerprint.mtimeNs);
            putLong(bytes, r.fingerprint.ctimeNs);
            bytes ~= r.id[];
        }
        bytes ~= blake3(bytes)[];
        return bytes;
    }

    /**
    Loads a run `encode` wrote, as the previous run. A rejected cache
    leaves none loaded.
    */
    Expected!(size_t, CacheRejection, NoGcHook) load(scope const(ubyte)[] bytes) @safe pure nothrow
    {
        import sparkles.base.hash.blake3 : blake3;

        previous = null;
        previousStamp = 0;
        alias fail = (CacheRejection r) => err!(size_t, NoGcHook)(r);
        if (bytes.length < magic.length + 16 + 32)
            return fail(CacheRejection.truncated);
        if (bytes[0 .. magic.length] != magic[])
            return fail(CacheRejection.otherFormat);
        if (blake3(bytes[0 .. $ - 32]) != bytes[$ - 32 .. $])
            return fail(CacheRejection.damaged);
        auto rest = bytes[magic.length .. $ - 32];
        ulong stampBits, count;
        if (!takeLong(rest, stampBits) || !takeLong(rest, count))
            return fail(CacheRejection.truncated);
        Record[string] loaded;
        foreach (_; 0 .. count)
        {
            ulong length;
            if (!takeLong(rest, length) || rest.length < length)
                return fail(CacheRejection.damaged);
            const path = cast(string) rest[0 .. length].idup;
            rest = rest[length .. $];
            Record r;
            ulong mtime, ctime;
            if (!takeLong(rest, r.fingerprint.size) || !takeLong(rest, r.fingerprint.device)
                || !takeLong(rest, r.fingerprint.inode) || !takeLong(rest, mtime) || !takeLong(rest, ctime)
                || rest.length < 32)
                return fail(CacheRejection.damaged);
            r.fingerprint.mtimeNs = cast(long) mtime;
            r.fingerprint.ctimeNs = cast(long) ctime;
            r.id = rest[0 .. 32];
            rest = rest[32 .. $];
            loaded[path] = r;
        }
        if (rest.length)
            return fail(CacheRejection.damaged);
        previous = loaded;
        previousStamp = cast(long) stampBits;
        return ok!(CacheRejection, NoGcHook)(cast(size_t) count);
    }

    private static void putLong(ref ubyte[] bytes, ulong v) @safe pure nothrow
    {
        foreach (i; 0 .. 8)
            bytes ~= cast(ubyte)(v >> (8 * i));
    }

    private static bool takeLong(ref const(ubyte)[] bytes, out ulong v) @safe pure nothrow @nogc
    {
        if (bytes.length < 8)
            return false;
        foreach (i; 0 .. 8)
            v |= ulong(bytes[i]) << (8 * i);
        bytes = bytes[8 .. $];
        return true;
    }
}

/// What `observe` returns: the state, or why the resolution failed.
alias Observed = Expected!(InputState, ResolutionError, NoGcHook);

/**
Materializes `set` beneath `root` and returns its input state (BGW9),
reading each member file once, or not at all when `cache` has its digest.
Batches, and the reads the fold makes, run on `exec`. A link to a file is
followed to read the file's id; a link the root's policy follows into a
directory is entered, and its members are the state's under the link's
path. An entry that cannot be read fails the observation: a state of part
of a set would claim an id it does not have.
*/
Observed observe(V, Rights R, Cache, Exec)(DirRef!(V, R) root, ref const Filesets sets, Fileset set,
    ref Cache cache, ref Exec exec, ResolutionLimits limits = ResolutionLimits.init)
    => observe(root, sets, set, cache, exec, ListingHooks.init, limits);

/**
What a caller hears of the directories an observation lists (BGW14):
`before` each is listed, by its path relative to the root (`false`
aborts), and, once it is, the identity of the directory the handle listed,
when the root's rights allow a `stat`.
*/
struct ListingHooks
{
    bool delegate(scope const(char)[] path) before;                       ///
    void delegate(scope const(char)[] path, ulong device, ulong inode) listed; ///
}

/// ditto, telling `hooks` of each directory listed.
Observed observe(V, Rights R, Cache, Exec)(DirRef!(V, R) root, ref const Filesets sets, Fileset set,
    ref Cache cache, ref Exec exec, ListingHooks hooks, ResolutionLimits limits = ResolutionLimits.init)
{
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;
    import sparkles.base.hash.blake3 : Blake3;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    auto fold = StateFold!Cache(&cache);
    fold.hooks = hooks;
    auto got = resolveScheme(root, sets, set, fold, exec, limits);
    if (got.hasError)
        return err!(InputState, NoGcHook)(got.error);
    InputState state;
    state.tree = got.value;
    state.members = fold.members;
    state.members.sort!((a, b) => a.path < b.path);

    // An unreadable entry that is a link is one the policy would not follow
    // (it dangles, or climbs out of the root): the link is read, and what it
    // names is not. Any other leaves the set without a state (FSE1).
    LinkRead[] unfollowed;
    foreach (p; fold.incompletes)
    {
        const target = readLink(root, p);
        if (target is null)
            return err!(InputState, NoGcHook)(ResolutionError(ResolutionErrorCode.schemeFailed,
                ResolutionError.init.kind, "an entry could not be read, so the set has no state"));
        unfollowed ~= LinkRead(p, target);
    }
    bool isLink(string p) => fold.links.canFind!(l => l.path == p) || unfollowed.canFind!(l => l.path == p);

    // A followed link was listed through; one whose target is a file, or
    // that could not be followed, was not.
    string[] dirLinks;
    foreach (p; fold.throughLinks)
        if (!isLink(p))
            dirLinks ~= p;
    foreach (p; fold.listed)
        if (!isLink(p))
            state.listed ~= p;
    state.listed.sort();

    state.links = fold.links ~ unfollowed;
    foreach (p; dirLinks)
    {
        LinkRead l;
        l.path = p;
        l.target = readLink(root, p);
        state.links ~= l;
    }
    foreach (ref l; state.links)
        settleTarget(root, l, cache);
    state.links.sort!((a, b) => a.path < b.path);

    Blake3 h;
    h.start();
    h.put(cast(const(ubyte)[]) "sparkles input state 1\n");
    h.put(state.tree.digest[]);
    foreach (ref l; state.links)
    {
        h.put(cast(const(ubyte)[]) l.path);
        h.put(cast(ubyte) 0);
        h.put(cast(const(ubyte)[]) l.target);
        h.put(cast(ubyte) 0);
        h.put(cast(ubyte) l.kind);
        h.put(l.id[]);
    }
    state.id = h.finish();
    return ok!(ResolutionError, NoGcHook)(state);
}

/// The fold `observe` runs: castore's encoding, with every member, link and
/// listed directory recorded on the way.
private struct StateFold(Cache)
{
    import sparkles.build_primitives.content_addressing.merkle : DigestLeaf, Named, streamFile;
    import sparkles.base.hash.blake3 : Blake3;

    enum order = CastoreDirectory.order;
    enum traversal = Traversal.fold;
    enum metadata = cast(FsoMetadata)(FsoMetadata.executable | FsoMetadata.linkTarget | FsoMetadata.fingerprint);

    alias Value = Named!(CastoreDirectory.Id);
    alias Result = CastoreDirectory.Id;

    Cache* cache;
    CastoreDirectory dir;
    DigestLeaf!Blake3 leaf;
    Member[] members;
    LinkRead[] links;
    string[] listed, throughLinks, incompletes;
    string why;
    ListingHooks hooks;

    this(Cache* cache)
    {
        this.cache = cache;
    }

    bool listing(scope const(char)[] path, bool throughLink)
    {
        if (hooks.before !is null && !hooks.before(path))
            return fail("the listing of " ~ path.idup ~ " was refused");
        listed ~= path.idup;
        if (throughLink)
            throughLinks ~= path.idup;
        return true;
    }

    bool fold(Entries, Exec)(scope const(char)[] path, Entries entries, bool empty, ref Exec exec,
        out Value value)
    {
        import sparkles.base.vfs.types : StatMask;

        if (hooks.listed !is null)
            static if (__traits(compiles, entries.directory.stat(StatMask.identity)))
            {
                auto st = entries.directory.stat(StatMask.identity);
                if (st.hasValue && st.value.hasIdentity)
                    hooks.listed(path, st.value.device, st.value.inode);
            }
        dir.begin();
        bool holds;
        foreach (e; entries)
        {
            const full = path.length ? (path ~ "/" ~ e.name).idup : e.name.idup;
            final switch (e.node.kind)
            {
                case FsoKind.directory:
                    if (!e.value.holdsMember)
                        continue;
                    dir.directory(e.name, e.value.id);
                    break;
                case FsoKind.symlink:
                    links ~= LinkRead(full, e.node.target.idup);
                    dir.symlink(e.name, e.node.target);
                    break;
                case FsoKind.regular:
                    Digest id;
                    ulong size;
                    if (cache.lookup(full, e.hasFingerprint, e.fingerprint, id))
                        size = e.fingerprint.size;
                    else
                    {
                        const failed = streamFile(e.ref_, leaf, size);
                        if (failed.length)
                            return fail(failed);
                        id = leaf.finish();
                        cache.record(full, e.hasFingerprint, e.fingerprint, id);
                    }
                    members ~= Member(full, id);
                    dir.file(e.name, e.node.executable, id, size);
                    break;
            }
            holds = true;
        }
        value = Value(dir.seal(), holds);
        return true;
    }

    // An entry that could not be read: a link the policy would not follow,
    // dangling or climbing out of the root, or a real failure, which
    // `observe` tells apart once the resolution is done.
    bool incomplete(scope const(char)[] path, ErrorKind kind)
    {
        incompletes ~= path.idup;
        return true;
    }

    string failure() const => why;

    Result finish(ref Value root) => root.id;

    private bool fail(string s)
    {
        why = s;
        return false;
    }
}

/**
The links among the members of `set` beneath `root`, each with its target
settled (`resolved`, and `kind`, never an id), in path order. Reads no
file's bytes, so it costs a listing of the set: what the claim index needs
of links (BGW11). `root`'s policy should follow no link, so that every link
is a member.
*/
Expected!(LinkRead[], ResolutionError, NoGcHook) linksOf(V, Rights R, Exec)(DirRef!(V, R) root,
    ref const Filesets sets, Fileset set, ref Exec exec, ResolutionLimits limits = ResolutionLimits.init)
{
    import std.algorithm.sorting : sort;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    static struct Links
    {
        enum metadata = FsoMetadata.linkTarget;
        alias Result = LinkRead[];
        LinkRead[] links;

        bool visit(Entries, Exec)(scope const(char)[] path, scope Entries entries, bool empty, ref Exec exec)
        {
            foreach (e; entries)
                if (e.node.kind == FsoKind.symlink)
                    links ~= LinkRead(path.length ? (path ~ "/" ~ e.name).idup : e.name.idup,
                        e.node.target.idup);
            return true;
        }

        // An unreadable entry holds no link a pattern could see.
        bool incomplete(scope const(char)[] path, ErrorKind kind) => true;
        LinkRead[] finish() => links;
    }

    Links scheme;
    auto got = resolveScheme(root, sets, set, scheme, exec, limits);
    if (got.hasError)
        return err!(LinkRead[], NoGcHook)(got.error);
    auto links = got.value;
    foreach (ref l; links)
        settleKind(root, l);
    links.sort!((a, b) => a.path < b.path);
    return ok!(ResolutionError, NoGcHook)(links);
}

// Settles what the link `l` names, without reading it.
private void settleKind(V, Rights R)(DirRef!(V, R) root, ref LinkRead l)
{
    import std.string : lastIndexOf;
    import sparkles.base.vfs.types : EntryKind;

    l.resolved = resolveLinkTarget(l.path, l.target);
    if (l.resolved is null)
    {
        l.kind = LinkTargetKind.outside;
        return;
    }
    const slash = l.resolved.lastIndexOf('/');
    const name = slash < 0 ? l.resolved : l.resolved[slash + 1 .. $];
    void settle(D)(D dir)
    {
        auto st = dir.statAt(name);
        l.kind = st.hasError ? LinkTargetKind.absent
            : st.value.kind == EntryKind.directory ? LinkTargetKind.directory
            : LinkTargetKind.file;
    }

    if (slash < 0)
        settle(root);
    else
    {
        auto parent = root.walk(l.resolved[0 .. slash]);
        if (parent.hasError)
            l.kind = LinkTargetKind.absent;
        else
            settle(parent.value.borrow);
    }
}

/// The target text of the link at `path` beneath `root`; `null` when it
/// cannot be read.
private string readLink(V, Rights R)(DirRef!(V, R) root, string path)
{
    import std.string : lastIndexOf;

    char[4096] buf = void;
    const slash = path.lastIndexOf('/');
    if (slash < 0)
    {
        auto t = root.readlinkAt(path, buf[]);
        return t.hasError ? null : t.value.idup;
    }
    auto parent = root.walk(path[0 .. slash]);
    if (parent.hasError)
        return null;
    auto t = parent.value.readlinkAt(path[slash + 1 .. $], buf[]);
    return t.hasError ? null : t.value.idup;
}

/**
The path `target`, read relative to the directory holding the link at
`link`, beneath the root; `null` for an absolute target or one that climbs
out of the root.
*/
string resolveLinkTarget(const(char)[] link, const(char)[] target) @safe pure nothrow
{
    if (!target.length || target[0] == '/')
        return null;
    string[] parts;
    // Each `/`-separated component of `s`, in order.
    static void each(const(char)[] s, scope void delegate(const(char)[]) @safe pure nothrow dg)
        @safe pure nothrow
    {
        size_t start;
        foreach (i; 0 .. s.length + 1)
            if (i == s.length || s[i] == '/')
            {
                dg(s[start .. i]);
                start = i + 1;
            }
    }

    size_t slash = link.length;
    while (slash > 0 && link[slash - 1] != '/')
        --slash;
    if (slash > 1)
        each(link[0 .. slash - 1], (c) { parts ~= c.idup; });
    bool climbed;
    each(target, (c) {
        if (!c.length || c == "." || climbed)
            return;
        if (c != "..")
            parts ~= c.idup;
        else if (parts.length)
            parts = parts[0 .. $ - 1];
        else
            climbed = true;
    });
    if (climbed)
        return null;
    string joined;
    foreach (i, p; parts)
        joined ~= (i ? "/" : "") ~ p;
    return joined;
}

///
@("workspace.inputState.resolveLinkTarget")
@safe pure nothrow unittest
{
    assert(resolveLinkTarget("libs/ui-app/spec/resilience.md", "../../../docs/specs/ui-app/resilience.md")
        == "docs/specs/ui-app/resilience.md");
    assert(resolveLinkTarget("a/l", "./x/../y") == "a/y");
    assert(resolveLinkTarget("l", "x") == "x");
    assert(resolveLinkTarget("a/l", "../../x") is null, "climbs out of the root");
    assert(resolveLinkTarget("a/l", "/etc/passwd") is null, "absolute");
}

// Settles what the link `l` names, and for a file its id.
private void settleTarget(V, Rights R, Cache)(DirRef!(V, R) root, ref LinkRead l, ref Cache cache)
{
    import std.string : lastIndexOf;
    import sparkles.base.hash.blake3 : Blake3;
    import sparkles.base.vfs.types : EntryKind, StatMask;
    import sparkles.build_primitives.content_addressing.merkle : DigestLeaf, streamFile;
    import sparkles.build_primitives.fileset.scheme : FsoRef;

    l.resolved = l.target is null ? null : resolveLinkTarget(l.path, l.target);
    if (l.target is null)
    {
        l.kind = LinkTargetKind.absent;
        return;
    }
    if (l.resolved is null)
    {
        l.kind = LinkTargetKind.outside;
        return;
    }
    const slash = l.resolved.lastIndexOf('/');
    const name = slash < 0 ? l.resolved : l.resolved[slash + 1 .. $];

    void settle(D)(D dir)
    {
        enum mask = cast(StatMask)(StatMask.mtime | StatMask.identity | StatMask.change);
        auto st = dir.statAt(name, mask);
        if (st.hasError)
        {
            l.kind = LinkTargetKind.absent;
            return;
        }
        if (st.value.kind == EntryKind.directory)
        {
            l.kind = LinkTargetKind.directory;
            return;
        }
        if (st.value.kind != EntryKind.regular && st.value.kind != EntryKind.symlink)
        {
            l.kind = LinkTargetKind.absent;
            return;
        }
        // A target that is itself a link is opened, and the policy follows
        // it or refuses; its own fingerprint says nothing of its target's.
        FsoFingerprint fp;
        bool hasFp;
        if (st.value.kind == EntryKind.regular)
        {
            const s = st.value;
            hasFp = s.hasMtime && s.hasIdentity && s.hasCtime && !s.ctimeSettable;
            fp = FsoFingerprint(s.size, s.device, s.inode, s.mtimeNs, s.ctimeNs);
            if (cache.lookup(l.resolved, hasFp, fp, l.id))
            {
                l.kind = LinkTargetKind.file;
                return;
            }
        }
        DigestLeaf!Blake3 leaf;
        ulong size;
        auto r = FsoRef!(V, R)(dir, name);
        if (streamFile(r, leaf, size).length)
        {
            l.kind = LinkTargetKind.absent;
            return;
        }
        l.id = leaf.finish();
        l.kind = LinkTargetKind.file;
        cache.record(l.resolved, hasFp, fp, l.id);
    }

    if (slash < 0)
        settle(root);
    else
    {
        auto parent = root.walk(l.resolved[0 .. slash]);
        if (parent.hasError)
        {
            l.kind = LinkTargetKind.absent;
            return;
        }
        settle(parent.value.borrow);
    }
}

version (unittest)
{
    // Observes `f` (all of it when `glob` is null) over `vfs` with `cache`,
    // following links beneath the root. A template, so that the test-only
    // modules it imports are imported only by the tests that call it.
    InputState observed(V)(ref V vfs, ref DigestCache!() cache, string glob = null)
    {
        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.base.vfs.types : ResolvePolicy, SymlinkPolicy;
        import sparkles.build_primitives.fileset.pattern : CasePolicy;
        import sparkles.build_primitives.fileset.testing : RecordingExecutor;

        auto sets = Filesets(CasePolicy.sensitive);
        const f = glob is null ? sets.everything : sets.glob(glob).value;
        ResolvePolicy beneath;
        beneath.symlinks = SymlinkPolicy.beneath;
        auto root = openRoot!(Rights.readOnly)(&vfs, "", ambientAuthority(), beneath);
        assert(!root.hasError);
        RecordingExecutor exec;
        auto got = observe(root.value.borrow, sets, f, cache, exec);
        assert(!got.hasError, got.hasError ? got.error.context : "");
        return got.value;
    }
}

/// A state's members are in path order, each with the BLAKE3 of its bytes;
/// its tree is the one castore names for the same fileset; and it lists
/// every directory listed, members or not.
@("workspace.inputState.observe.members")
@system unittest
{
    import sparkles.build_primitives.fileset.testing : openFixture;

    import sparkles.base.hash.blake3 : blake3;
    import sparkles.build_primitives.content_addressing.testing : coldId;
    import sparkles.build_primitives.content_addressing.castore : toCastoreText;

    auto made = openFixture("src/b.d = bee\nsrc/a.d = ay\nsrc/none/x.txt = x\nREADME = r\n");
    auto vfs = &made.value.get().vfs;
    DigestCache!() cache;
    const state = observed(*vfs, cache, "src/**/*.d");
    assert(state.members == [Member("src/a.d", blake3(cast(const(ubyte)[]) "ay")),
        Member("src/b.d", blake3(cast(const(ubyte)[]) "bee"))]);
    assert(state.listed == ["src", "src/none"]);
    assert(state.links.length == 0);

    const all = observed(*vfs, cache);
    assert(toCastoreText(all.tree.digest) == coldId(*vfs), "the tree is castore's");
    assert(state.id != all.id);
}

/**
A link's target is part of the state: an edit to the file a link names
leaves the tree's id as it was and moves the state's, and the difference
names the link. A link the policy follows into a directory is recorded,
and its target's members are the state's under the link's path.
*/
@("workspace.inputState.observe.links")
@system unittest
{
    import sparkles.build_primitives.fileset.testing : openFixture;

    auto made = openFixture("docs/spec.md = one\nlib/spec.md -> ../docs/spec.md\nlib/out -> ../../x\n"
        ~ "lib/d -> ../docs\n");
    auto vfs = &made.value.get().vfs;
    vfs.clockNs = 10_000_000_000;
    DigestCache!() cache;
    cache.begin(vfs.clockNs);
    const before = observed(*vfs, cache, "lib/**");
    assert(before.links.length == 3, before.links.length.text);
    assert(before.links[0].path == "lib/d" && before.links[0].kind == LinkTargetKind.directory
        && before.links[0].resolved == "docs", before.links[0].text);
    assert(before.links[1].path == "lib/out" && before.links[1].kind == LinkTargetKind.outside);
    assert(before.links[2].path == "lib/spec.md" && before.links[2].kind == LinkTargetKind.file
        && before.links[2].resolved == "docs/spec.md");
    assert(before.members.length == 1 && before.members[0].path == "lib/d/spec.md", before.members.text);

    vfs.clockNs += 3_000_000_000;
    assert(vfs.writeFile("docs/spec.md", cast(const(ubyte)[]) "two"));
    cache.begin(vfs.clockNs);
    const after = observed(*vfs, cache, "lib/**");
    assert(after.id != before.id);
    const changes = difference(before, after);
    assert(changes.pathList == ["lib/d/spec.md", "lib/spec.md"], changes.pathList.text);
    assert(!changes.lossy);
}

/// The difference of two states is a merge: each path created, removed or
/// with another id, sorted, and nothing for two equal states.
@("workspace.inputState.difference")
@safe pure nothrow unittest
{
    const Digest one = 1, two = 2;
    InputState a, b;
    a.id = 1;
    b.id = 2;
    a.members = [Member("a", one), Member("b", one), Member("c", one)];
    b.members = [Member("b", two), Member("c", one), Member("d", one)];
    const d = difference(a, b);
    assert(d.paths == [PathChange("a", ChangeKind.removed), PathChange("b", ChangeKind.modified),
        PathChange("d", ChangeKind.created)]);
    assert(difference(a, a).paths.length == 0);
}

/**
Each file is read once in a run, whichever state asks for it, and a later
run reads only what changed. The cache survives `encode` and `load`, and a
damaged one is rejected whole.
*/
@("workspace.inputState.digestCache")
@system unittest
{
    import sparkles.build_primitives.fileset.testing : openFixture;

    auto made = openFixture("a/x = 1\na/y = 2\nb = 3\n");
    auto vfs = &made.value.get().vfs;
    vfs.clockNs = 10_000_000_000;
    DigestCache!() cache;
    cache.begin(vfs.clockNs);
    const whole = observed(*vfs, cache);
    const part = observed(*vfs, cache, "a/**");
    assert(cache.filesRead == 3 && cache.filesReused == 2, text(cache.filesRead, " ", cache.filesReused));

    vfs.clockNs += 3_000_000_000;
    assert(vfs.writeFile("b", cast(const(ubyte)[]) "33"));
    auto bytes = cache.encode();
    DigestCache!() next;
    assert(next.load(bytes).value == 3);
    next.begin(vfs.clockNs);
    const again = observed(*vfs, next);
    assert(next.filesRead == 1 && next.filesReused == 2, text(next.filesRead, " ", next.filesReused));
    DigestCache!() cold;
    assert(again.id == observed(*vfs, cold).id, "the cache is advisory");
    assert(again.id != whole.id && part.members.length == 2);

    bytes[10] ^= 1;
    assert(next.load(bytes).hasError, "a damaged cache is rejected");
}

/// `linksOf` lists the links among a set's members, settling each target
/// without reading it, under a policy that follows no link.
@("workspace.inputState.linksOf")
@system unittest
{
    import sparkles.build_primitives.fileset.testing : openFixture;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.pattern : CasePolicy;
    import sparkles.build_primitives.fileset.testing : RecordingExecutor;

    auto made = openFixture("docs/spec.md = one\ndocs/d/\nlib/spec.md -> ../docs/spec.md\nlib/d -> ../docs/d\n"
        ~ "lib/gone -> nothing\nlib/out -> ../../x\nother -> docs\n");
    auto vfs = &made.value.get().vfs;
    auto sets = Filesets(CasePolicy.sensitive);
    auto root = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority());
    RecordingExecutor exec;
    const f = sets.glob("lib/**").value;
    auto got = linksOf(root.value.borrow, sets, f, exec);
    assert(!got.hasError);
    string[] seen;
    foreach (l; got.value)
        seen ~= text(l.path, " ", l.kind, " ", l.resolved);
    assert(seen == ["lib/d directory docs/d", "lib/gone absent lib/nothing", "lib/out outside ",
        "lib/spec.md file docs/spec.md"], seen.text);
}
