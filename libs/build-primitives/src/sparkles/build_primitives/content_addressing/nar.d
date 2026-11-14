/**
Nix's archive (NAR) as a stream scheme: the serialization `nix-store
--dump` writes, hashed as it is written, with its length beside the digest:
`NarHash` and `NarSize` (D2).

A NAR is serial: a directory's entries follow one another in byte order, a
subdirectory's whole subtree among them, so a later file of a directory is
written after an earlier subdirectory's subtree. The scheme therefore
declares `leave` (A19): it writes a directory's entries up to its first
subdirectory, keeps the rest, and resumes them when that subdirectory's
`leave` comes, reading their files through references that stay valid until
the directory's own `leave`.

A directory's header waits for the first file or link beneath it, so a
directory with no member beneath it is never written, and the archive names
the members' tree whatever directories the walk entered (C3). The archive's
root is always written.

The grammar, from Nix's `protocols/nix-archive`: each token is a string,
its length as a little-endian `u64` and its bytes padded with zeros to a
multiple of 8.

```
nar       = "nix-archive-1" node
node      = "(" "type" ( regular | symlink | directory ) ")"
regular   = "regular" [ "executable" "" ] "contents" contents
symlink   = "symlink" "target" target
directory = "directory" { "entry" "(" "name" name "node" node ")" }
```

A plan's start roots may lie beneath the fileset root, which a stream never
sees as a unit: the scheme writes the directories above them itself, as a
directory holding only the way to its roots. `nix-store --dump` is the
oracle (`content_addressing.nar.dump`).

The same walk can name the tree by Merkle directory encodings too, the
`Tee` of A19: `NarScheme!(H, Ref, Dirs)` feeds each file's bytes, read
once, to the NAR and to every `Dir`'s leaf, and encodes a directory when it
is closed, its entries put in the `Dir`'s own order. `CastoreNar` is the
castore identity with its `NarHash` beside it (D2).
*/
module sparkles.build_primitives.content_addressing.nar;

import std.digest : isDigest;
import std.digest.sha : SHA256;
import std.meta : allSatisfy, staticMap;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.io.errors : ErrorKind;
import sparkles.build_primitives.content_addressing.castore : CastoreDirectory;
import sparkles.build_primitives.content_addressing.merkle : DefaultLeaf, isDirFormat, streamFile;
import sparkles.build_primitives.fileset.fso : EntryOrder, FsoKind, FsoMetadata, precedes;

/// A NAR's digest by `H`, and its length in bytes.
struct NarHash(H)
if (isDigest!H)
{
    typeof(H.init.finish()) digest; ///
    ulong size;                     ///
}

/// The ids `Dirs` give a tree, and its NAR beside them.
struct WithNar(H, Dirs...)
if (isDigest!H)
{
    IdsOf!Dirs ids; /// `ids[i]` is `Dirs[i]`'s
    NarHash!H nar;  ///
}

/// The castore id of a fileset, and its NAR by SHA-256: the identity with
/// the `NarHash` stored beside it (D2).
alias CastoreNar(Ref) = NarScheme!(SHA256, Ref, CastoreDirectory);

private alias IdOf(Dir) = Dir.Id;
private alias LeafOf(Dir) = DefaultLeaf!Dir;
private alias LeafIdOf(Dir) = DefaultLeaf!Dir.Id;
private alias IdsOf(Dirs...) = staticMap!(IdOf, Dirs);
private enum bool isMerkleDir(Dir) = isDirFormat!(Dir, DefaultLeaf!Dir);

// The metadata `Dir` needs: what it declares, else `MerkleFold`'s default.
private template metadataOf(Dir)
{
    static if (__traits(hasMember, Dir, "metadata"))
        enum FsoMetadata metadataOf = Dir.metadata;
    else
        enum metadataOf = cast(FsoMetadata)(FsoMetadata.executable | FsoMetadata.linkTarget);
}

/**
The NAR of a fileset, hashed by `H` as it is written, and the ids that the
Merkle directory encodings `Dirs`, each over its own `Leaf`, give the same
tree. `Ref` is the reference type its entries carry, `FsoRef!(V, R)` for the
root's VFS `V` and rights `R`.

With no `Dirs` the result is the `NarHash`, and with some a `WithNar`. Each
file is read once, its bytes going to the NAR and to every leaf (A19's
`Tee`); the metadata declared is the union of the parts'.
*/
struct NarScheme(H, Ref, Dirs...)
if (isDigest!H && allSatisfy!(isMerkleDir, Dirs))
{
    enum order = EntryOrder.narOrder; ///
    enum metadata = () {
        auto m = cast(FsoMetadata)(FsoMetadata.executable | FsoMetadata.linkTarget);
        static foreach (Dir; Dirs)
            m |= metadataOf!Dir;
        return m;
    }(); ///
    static if (Dirs.length)
        alias Result = WithNar!(H, Dirs); ///
    else
        alias Result = NarHash!H; ///

    // An entry not yet written: its strings live in `text`. With `Dirs`, it
    // also keeps what its directory's encodings need: a subdirectory's ids,
    // set when the subdirectory is closed, or a file's leaf ids and size,
    // set when the file is written.
    private static struct Pending
    {
        size_t name, nameEnd, target, targetEnd;
        FsoKind kind;
        bool executable;
        Ref ref_;
        static if (Dirs.length)
        {
            IdsOf!Dirs ids;
            staticMap!(LeafIdOf, Dirs) leafIds;
            ulong size;
            bool held; // a directory with a member beneath it (C3)
        }
    }

    // An open directory: one a unit gave (`listed`), whose unwritten entries
    // are `pending[next .. end]`, or one above the start roots. Its entries
    // begin at `first`, its strings at `textMark`, and `path` is the length
    // of its path in `openPath`. Every open directory has a frame. A
    // directory's header is `deferred` until something beneath it is
    // written: one that closes still deferred holds no member, and is not
    // part of the tree named (C3). The archive's root is never deferred.
    private static struct Frame
    {
        size_t path, first, next, end, textMark;
        bool listed, deferred;
    }

    private H h;
    private ulong size;
    private UniqueBuffer!(Pending, 16) pending;
    private UniqueBuffer!(Frame, 16) frames;
    private UniqueBuffer!(char, 256) text;
    private UniqueBuffer!(char, 256) openPath; // the innermost open directory's path
    private bool started;
    private string why;
    static if (Dirs.length)
    {
        private Dirs dirs;                       // each encoding, reused for every directory
        private staticMap!(LeafOf, Dirs) leaves; // each file identity, reused for every file
        private IdsOf!Dirs rootIds;
        private UniqueBuffer!(uint, 64) sorted;  // one directory's entries, in a `Dir`'s order
    }

    /// Opens `path` and writes its entries up to its first subdirectory.
    bool visit(Entries, Exec)(scope const(char)[] path, Entries entries, bool empty, ref Exec exec)
    {
        if (!openTo(path))
            return false;
        Frame f = { path: path.length, first: pending.length, next: pending.length,
            textMark: text.length, listed: true, deferred: frames.length != 0 };
        foreach (e; entries)
        {
            Pending p;
            p.name = text.length;
            text.put(e.name);
            p.nameEnd = text.length;
            p.target = text.length;
            if (e.node.kind == FsoKind.symlink)
                text.put(e.node.target);
            p.targetEnd = text.length;
            p.kind = e.node.kind;
            p.executable = e.node.executable;
            p.ref_ = e.ref_;
            pending ~= p;
        }
        f.end = pending.length;
        frames ~= f;
        return advance();
    }

    /// Closes `path`, and resumes the directory holding it.
    bool leave(Exec)(scope const(char)[] path, ref Exec exec)
    {
        assert(frames.length && frames.back.listed && frames.back.next == frames.back.end
            && openPath[] == path, "a directory is left once its entries are written");
        close();
        return advance();
    }

    /// A tree whose entries cannot all be read has no NAR (FSE1).
    bool incomplete(scope const(char)[] path, ErrorKind kind) =>
        fail("an entry could not be read, so the tree has no NAR");

    /// Why the scheme aborted.
    string failure() const => why;

    /// The NAR's digest and length. The scheme is then ready for another
    /// resolution, its buffers kept (CAM5).
    Result finish()
    {
        if (!started)
        {
            // A fileset holding nothing is the empty directory.
            begin();
            frames ~= Frame.init;
        }
        while (frames.length)
            close();
        static if (Dirs.length)
            auto r = Result(rootIds, NarHash!H(h.finish(), size));
        else
            auto r = Result(h.finish(), size);
        started = false;
        size = 0;
        return r;
    }

    private void begin()
    {
        started = true;
        h.start();
        token("nix-archive-1");
        openDirectory(null);
    }

    // Opens the directory `path`, a unit's, without giving it a frame: closes
    // the open directories it is not beneath, and opens with a frame each
    // directory between them and it.
    private bool openTo(scope const(char)[] path)
    {
        if (!started)
        {
            begin();
            if (!path.length)
                return true; // the archive's root is the unit's directory
            frames ~= Frame.init;
        }
        else if (!frames.length)
            return fail("a directory came after the archive's root was done");
        while (!beneath(path, openPath[]))
        {
            if (frames.back.listed)
                return fail("a directory came before the one holding it was done");
            close();
        }
        const deeper = frames.back.listed;
        for (;;)
        {
            const start = openPath.length ? openPath.length + 1 : 0;
            size_t end = start;
            while (end < path.length && path[end] != '/')
                ++end;
            if (deeper && end != path.length)
                return fail("a unit skipped a directory");
            if (openPath.length)
                openPath.put('/');
            openPath.put(path[start .. end]);
            if (end == path.length)
                return true;
            Frame f = { path: openPath.length, first: pending.length, next: pending.length,
                end: pending.length, textMark: text.length, deferred: true };
            frames ~= f;
        }
    }

    // Writes the innermost listed directory's entries until a subdirectory,
    // whose own unit comes next, or until none is left.
    private bool advance()
    {
        while (frames.length && frames.back.listed)
        {
            auto f = &frames.back();
            if (f.next == f.end)
                return true; // its `leave` closes it
            auto p = pending[f.next++];
            const name = text[][p.name .. p.nameEnd];
            final switch (p.kind)
            {
                case FsoKind.directory:
                    return true; // opened by its own unit
                case FsoKind.symlink:
                    writeDeferred();
                    openEntry(name);
                    token("(");
                    token("type");
                    token("symlink");
                    token("target");
                    token(text[][p.target .. p.targetEnd]);
                    token(")");
                    token(")");
                    break;
                case FsoKind.regular:
                    writeDeferred();
                    openEntry(name);
                    token("(");
                    token("type");
                    token("regular");
                    if (p.executable)
                    {
                        token("executable");
                        token("");
                    }
                    token("contents");
                    auto contents = Contents(&this);
                    ulong length;
                    const failed = streamFile(p.ref_, contents, length);
                    if (failed.length)
                        return fail(failed);
                    pad(length);
                    static if (Dirs.length)
                    {
                        auto written = &pending[f.next - 1];
                        static foreach (i; 0 .. Dirs.length)
                            written.leafIds[i] = leaves[i].finish();
                        written.size = length;
                    }
                    token(")");
                    token(")");
                    break;
            }
        }
        return true;
    }

    // The bytes of one file's contents: its length, then the bytes; each
    // leaf hears them too.
    private static struct Contents
    {
        NarScheme* nar;

        void start(ulong length)
        {
            nar.u64(length);
            static if (Dirs.length)
                static foreach (i; 0 .. Dirs.length)
                    nar.leaves[i].start(length);
        }

        void put(scope const(ubyte)[] bytes)
        {
            nar.raw(bytes);
            static if (Dirs.length)
                static foreach (i; 0 .. Dirs.length)
                    nar.leaves[i].put(bytes);
        }
    }

    // Writes the headers of the open directories still deferred, outermost
    // first: something beneath them is about to be written.
    private void writeDeferred()
    {
        size_t k = frames.length;
        while (k > 1 && frames[k - 1].deferred)
            --k;
        for (; k < frames.length; ++k)
        {
            if (!frames[k].deferred)
                continue;
            const parent = frames[k - 1].path;
            openDirectory(openPath[][parent ? parent + 1 : 0 .. frames[k].path]);
            frames[k].deferred = false;
        }
    }

    // Opens a directory node, inside an entry named `name` unless it is the
    // archive's root.
    private void openDirectory(scope const(char)[] name)
    {
        if (name !is null)
            openEntry(name);
        token("(");
        token("type");
        token("directory");
    }

    private void openEntry(scope const(char)[] name)
    {
        token("entry");
        token("(");
        token("name");
        token(name);
        token("node");
    }

    // Closes the innermost open directory, and its entry unless it is the
    // archive's root. One still deferred was never written, and is left out.
    private void close()
    {
        const f = frames.back;
        const holds = !f.deferred;
        static if (Dirs.length)
        {
            IdsOf!Dirs ids;
            if (holds)
                static foreach (i; 0 .. Dirs.length)
                    ids[i] = encode!i(f.first, f.end);
        }
        frames.length = frames.length - 1;
        pending.length = f.first;
        text.length = f.textMark;
        if (holds)
        {
            token(")");
            if (frames.length)
                token(")");
        }
        const parentPath = frames.length ? frames.back.path : 0;
        static if (Dirs.length)
        {
            if (!frames.length)
                static foreach (i; 0 .. Dirs.length)
                    rootIds[i] = ids[i];
            else if (frames.back.listed)
            {
                // Its entry is the one `advance` stopped at.
                auto entry = &pending[frames.back.next - 1];
                assert(entry.kind == FsoKind.directory, "a directory closes into its entry");
                entry.held = holds;
                static foreach (i; 0 .. Dirs.length)
                    entry.ids[i] = ids[i];
            }
            else if (holds)
            {
                // A directory above the start roots holds only the ones
                // beneath it, each recorded as it closes.
                Pending p;
                p.name = text.length;
                text.put(openPath[][parentPath ? parentPath + 1 : 0 .. $]);
                p.nameEnd = p.target = p.targetEnd = text.length;
                p.kind = FsoKind.directory;
                p.held = true;
                static foreach (i; 0 .. Dirs.length)
                    p.ids[i] = ids[i];
                pending ~= p;
                frames.back.end = pending.length;
            }
        }
        openPath.length = parentPath;
    }

    static if (Dirs.length)
    {
        // `Dirs[i]`'s id of the directory whose entries are
        // `pending[first .. end]`, each written or closed already.
        private IdOf!(Dirs[i]) encode(size_t i)(size_t first, size_t end)
        {
            enum order = Dirs[i].order;
            sorted.clear(false);
            foreach (k; first .. end)
                sorted ~= cast(uint) k;
            // `pending` is in byte order, NAR's; another order re-sorts.
            static if (order != EntryOrder.narOrder)
            {
                import std.algorithm.sorting : sort;

                sort!((a, b) => precedes(order, nameOf(a), pending[a].kind, nameOf(b),
                    pending[b].kind))(sorted[]);
            }
            auto dir = &dirs[i];
            dir.begin();
            foreach (k; sorted[])
            {
                auto e = &pending[k];
                final switch (e.kind)
                {
                    case FsoKind.directory:
                        if (!e.held)
                            continue; // not part of the tree named (C3)
                        dir.directory(nameOf(k), e.ids[i]);
                        break;
                    case FsoKind.regular:
                        dir.file(nameOf(k), e.executable, e.leafIds[i], e.size);
                        break;
                    case FsoKind.symlink:
                        dir.symlink(nameOf(k), text[][e.target .. e.targetEnd]);
                        break;
                }
            }
            return dir.seal();
        }

        private const(char)[] nameOf(size_t k) => text[][pending[k].name .. pending[k].nameEnd];
    }

    private void token(scope const(char)[] s)
    {
        u64(s.length);
        raw(cast(const(ubyte)[]) s);
        pad(s.length);
    }

    private void u64(ulong n)
    {
        ubyte[8] le;
        foreach (i; 0 .. 8)
            le[i] = cast(ubyte)(n >> (8 * i));
        raw(le[]);
    }

    private void pad(ulong length)
    {
        static immutable ubyte[8] zeros;
        raw(zeros[0 .. (8 - length % 8) % 8]);
    }

    private void raw(scope const(ubyte)[] bytes)
    {
        h.put(bytes);
        size += bytes.length;
    }

    private bool fail(string s)
    {
        why = s;
        return false;
    }
}

/// Whether `path` is `dir` or lies beneath it.
private bool beneath(scope const(char)[] path, scope const(char)[] dir) @safe pure nothrow @nogc
    => dir.length == 0 || (path.length >= dir.length && path[0 .. dir.length] == dir
        && (path.length == dir.length || path[dir.length] == '/'));

/// A digest as Nix prints it in SRI form: `sha256-` and standard, padded
/// base64.
char[51] toSri(in ubyte[32] digest) @safe pure nothrow @nogc
{
    import std.base64 : Base64;

    char[51] text = "sha256-                                            ";
    Base64.encode(digest[], text[7 .. $]);
    return text;
}
