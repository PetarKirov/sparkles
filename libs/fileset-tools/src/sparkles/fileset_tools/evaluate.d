/**
Resolving a query: parse, compile, walk, and the numbers the Stats tab shows
(`FXU1`). A query resolves against a directory on disk, or against a tree held
in memory — a tutorial's named tree (`FXT4`).
*/
module sparkles.fileset_tools.evaluate;

import core.time : MonoTime;
import std.algorithm.sorting : sort;
import std.conv : text;

import sparkles.base.io.errors : ErrorKind;
import sparkles.base.vfs.handles : ambientAuthority, DirRef, openRoot;
import sparkles.base.vfs.types : Rights;
import std.digest.sha : SHA1, SHA256;

import sparkles.build_primitives.content_addressing.castore : CastoreDirectory, toCastoreText;
import sparkles.build_primitives.content_addressing.collection : collectionOf, CollectionFile, IrohCollection;
import sparkles.build_primitives.content_addressing.git : GitTree, toGitSri, toHex, toSwhid;
import sparkles.build_primitives.content_addressing.nar : NarScheme, toSri;
import sparkles.build_primitives.content_addressing.store_path : defaultStoreName, nixStorePath;
import sparkles.build_primitives.fileset.driver : InlineExecutor;
import sparkles.build_primitives.fileset.fso : EntryOrder, FsoKind, FsoMetadata;
import sparkles.build_primitives.fileset.pattern : CasePolicy;
import sparkles.build_primitives.fileset.query : compileQuery, gitTrackedPaths, parseQuery, Query,
    QueryError;
import sparkles.build_primitives.fileset.scheme : FsoRef, resolveScheme;
import sparkles.build_primitives.fileset.value : Fileset, Filesets;

/// Where a query resolves: a directory, or a tree literal held in memory.
struct Root
{
    string dir = ".";    /// the directory, when `literal` is null
    string literal;      /// a tree literal (`FXT4`), resolved in memory
    string name;         /// what the header calls an in-memory tree

    /// Whether this is an in-memory tree.
    bool inMemory() const @safe pure nothrow @nogc => literal !is null;

    /// The label a collection of its files carries (`FXS1`): `name` when
    /// given, else the directory's own name, as `sendme` would name it.
    string label() const @safe
    {
        import std.path : absolutePath, baseName, buildNormalizedPath;

        return name.length ? name : baseName(buildNormalizedPath(absolutePath(dir)));
    }
}

/// One member of the fileset.
struct Member
{
    string path;     ///
    FsoKind kind;    ///
    bool executable; ///
    string target;   /// a link's
    ulong size;      /// a file's
}

/// What a walk found.
struct Collected
{
    Member[] members;    /// in the walk's order: depth first, by name
    string[] empty;      /// directories holding no member (FSV4)
    string[] unreadable; /// `path: why`
    size_t directories;  /// directories the walk handed over
}

/// A stream scheme collecting each member with its size.
struct Collect
{
    enum order = EntryOrder.narOrder;
    enum metadata = cast(FsoMetadata)(FsoMetadata.executable | FsoMetadata.linkTarget);
    alias Result = Collected;
    private Collected c;

    ///
    bool visit(Entries, Exec)(scope const(char)[] path, Entries entries, bool empty, ref Exec exec)
    {
        ++c.directories;
        if (empty)
            c.empty ~= path.length ? path.idup : ".";
        foreach (e; entries)
        {
            if (e.node.kind == FsoKind.directory)
                continue;
            Member m;
            m.path = path.length ? text(path, "/", e.name) : e.name.idup;
            m.kind = e.node.kind;
            m.executable = e.node.executable;
            m.target = e.node.target.idup;
            if (m.kind == FsoKind.regular)
            {
                auto st = e.ref_.dir.statAt(e.name);
                if (!st.hasError)
                    m.size = st.value.size;
            }
            c.members ~= m;
        }
        return true;
    }

    ///
    bool incomplete(scope const(char)[] path, ErrorKind kind)
    {
        c.unreadable ~= text(path, ": ", kind);
        return true;
    }

    ///
    Collected finish() => c;
}

/// Everything the panes show about one query.
struct Outcome
{
    Query query;            /// the parse, tokens included
    bool resolved;          /// it compiled and the walk succeeded
    QueryError failure;     /// why not, when it parsed
    Collected found;        ///
    ulong bytes;            /// total file bytes
    double millis = 0;      /// the walk's wall time
    bool hasIds;            /// the ids below were computed for this fileset
    string castore;         /// the castore id, as Snix prints it
    string narHash;         /// the SRI `NarHash`
    ulong narSize;          ///
    string storePath;       /// where Nix would copy it, as `source` (`CAP1`)
    string gitTree;         /// git's SHA-1 tree id, in hex
    string gitSri;          /// ... as Nix's git hashing prints it (`CAG3`)
    string swhid;           /// ... as a SWHID
    string collection;      /// iroh's collection, in hex; empty with `collectionError`
    string collectionError; /// why the fileset has no collection (`CAI3`)
    size_t collectionLinks; /// links a collection leaves out (`CAI2`)
    size_t collectionExecutables; /// files whose executable bit a collection cannot carry
    CollectionFile[] collectionFiles; /// its files, in its order, paths from the root
    string label;           /// the collection's label
    string[2][] extensions; /// the commonest extensions, `[ext, count]`, most first
    string[] hints;         /// what a bare call name meant (`FXL9`)

    /// Whether the query did not parse or did not resolve.
    bool failed() const @safe pure nothrow @nogc => !query.ok || !resolved;

    /// The error to show, parse or resolution.
    QueryError error() const @safe pure nothrow @nogc => query.ok ? failure : query.error;
}

/// The largest fileset whose ids are computed on every edit.
enum ulong autoIdBytes = 32 << 20;

/// Parses and resolves `source` beneath `root`; computes the ids when the
/// fileset is small or `withIds` asks.
Outcome evaluate(in Root root, string source, bool withIds = false)
{
    Outcome o;
    o.query = parseQuery(source);
    if (!o.query.ok)
        return o;
    if (root.inMemory)
    {
        import sparkles.build_primitives.fileset.tree_literal : memTree;

        auto tree = memTree(root.literal, spareBytes: 1 << 16);
        if (tree.hasError)
        {
            o.failure = QueryError(text("the tree `", root.name, "` does not parse"), 0);
            return o;
        }
        auto dir = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
        resolveInto(dir.value.borrow, root, o, withIds);
        return o;
    }
    import sparkles.event_horizon.sys : BlockingVfs;

    auto vfs = new BlockingVfs;
    auto dir = openRoot!(Rights.readOnly)(vfs, root.dir, ambientAuthority());
    if (dir.hasError)
    {
        o.failure = QueryError(text("cannot open ", root.dir), 0);
        return o;
    }
    resolveInto(dir.value.borrow, root, o, withIds);
    return o;
}

private void resolveInto(V, Rights R)(DirRef!(V, R) dir, in Root root, ref Outcome o, bool withIds)
{
    auto sets = Filesets(CasePolicy.sensitive);
    const where = root.dir.idup;
    auto compiled = compileQuery(o.query, sets, root.inMemory ? null : () @safe => gitTrackedPaths(where));
    if (!compiled.ok)
    {
        o.failure = compiled.error;
        return;
    }
    InlineExecutor exec;
    Collect collect;
    const t0 = MonoTime.currTime;
    auto r = resolveScheme(dir, sets, compiled.set, collect, exec);
    o.millis = (MonoTime.currTime - t0).total!"usecs" / 1000.0;
    if (r.hasError)
    {
        o.failure = QueryError(r.error.context, 0);
        return;
    }
    o.resolved = true;
    o.found = r.value;

    // A bare call name that names no file meant the call (`FXL9`).
    foreach (name; o.query.bareCallNames)
    {
        auto alone = compileQuery(parseQuery(name), sets, null);
        if (!alone.ok)
            continue;
        Collect c;
        auto got = resolveScheme(dir, sets, alone.set, c, exec);
        if (!got.hasError && got.value.members.length == 0)
            o.hints ~= text("`", name, "` names no file: the call is `", name, "()`");
    }

    size_t[string] byExt;
    foreach (ref m; o.found.members)
    {
        o.bytes += m.size;
        byExt[extensionOf(m.path)]++;
    }
    size_t[string] counts = byExt;
    foreach (ext, n; counts)
        o.extensions ~= [ext, text(n)];
    sort!((a, b) => counts[a[0]] != counts[b[0]] ? counts[a[0]] > counts[b[0]] : a[0] < b[0])(o.extensions);

    if (withIds || o.bytes <= autoIdBytes)
    {
        // Every name in one read, castore and the collection sharing BLAKE3
        // (`CAT2`, `CAT4`).
        NarScheme!(SHA256, FsoRef!(V, Rights.readOnly), CastoreDirectory, GitTree!SHA1, IrohCollection) ids;
        auto id = resolveScheme(dir, sets, compiled.set, ids, exec);
        if (!id.hasError)
        {
            o.hasIds = true;
            o.castore = toCastoreText(id.value.ids[0].digest).idup;
            o.narHash = toSri(id.value.nar.digest).idup;
            o.narSize = id.value.nar.size;
            const path = nixStorePath(id.value.nar.digest, defaultStoreName);
            o.storePath = path.hasValue ? path.value : path.error;
            const git = id.value.ids[1].digest;
            o.gitTree = toHex(git)[].idup;
            o.gitSri = toGitSri(git)[].idup;
            o.swhid = toSwhid(git)[].idup;
            o.label = root.label;
            auto c = collectionOf(id.value.ids[2], o.label);
            if (c.hasValue)
            {
                o.collection = toHex(c.value.root)[].idup;
                o.collectionLinks = c.value.links;
                foreach (ref m; o.found.members)
                    o.collectionExecutables += m.kind == FsoKind.regular && m.executable;
                o.collectionFiles = c.value.files;
            }
            else
                o.collectionError = c.error;
        }
    }
}

/// `.d` for `a/b.d`; `(none)` for `Makefile` and `.envrc`.
string extensionOf(string path) @safe pure nothrow
{
    size_t slash, dot = size_t.max;
    foreach (i, c; path)
        if (c == '/')
        {
            slash = i + 1;
            dot = size_t.max;
        }
        else if (c == '.' && i > slash)
            dot = i;
    return dot == size_t.max ? "(none)" : path[dot .. $];
}

///
@("fileset_tools.extensionOf")
@safe pure nothrow unittest
{
    assert(extensionOf("a/b.d") == ".d");
    assert(extensionOf(".hidden/Makefile") == "(none)");
    assert(extensionOf("a.b/.envrc") == "(none)");
    assert(extensionOf("x.tar.gz") == ".gz");
}

/// `1.2 KiB`.
string humanBytes(ulong n) @safe
{
    import std.format : format;

    static immutable units = ["B", "KiB", "MiB", "GiB", "TiB"];
    double v = n;
    size_t u;
    while (v >= 1024 && u + 1 < units.length)
    {
        v /= 1024;
        ++u;
    }
    return u == 0 ? text(n, " B") : format!"%.1f %s"(v, units[u]);
}

///
@("fileset_tools.humanBytes")
@safe unittest
{
    assert(humanBytes(0) == "0 B" && humanBytes(1023) == "1023 B");
    assert(humanBytes(1536) == "1.5 KiB" && humanBytes(3 << 20) == "3.0 MiB");
}

/// A query over an in-memory tree selects its members, with their kinds and
/// sizes, and the ids beside them.
@("fileset_tools.evaluate.inMemory")
@system unittest
{
    const root = Root(literal: "src/a.d = 12345\nsrc/a_test.d = x\nbin/run +x = #!\nREADME.md = hi\nl -> src\n",
        name: "t");
    auto o = evaluate(root, "(src/** - **/*_test.d) | bin/* | l");
    assert(o.resolved, o.error.message);
    string[] paths;
    foreach (m; o.found.members)
        paths ~= m.path;
    assert(paths == ["l", "bin/run", "src/a.d"], text(paths)); // the walk's order: a directory's files first
    assert(o.found.members[1].executable && o.found.members[0].kind == FsoKind.symlink);
    assert(o.bytes == 2 + 5 && o.hasIds && o.narHash[0 .. 7] == "sha256-");

    const bad = evaluate(root, "(a");
    assert(bad.failed && bad.error.offset == 2);
    const untracked = evaluate(root, "gitTracked()");
    assert(untracked.failed && untracked.error.message == "not a git work tree");
}
