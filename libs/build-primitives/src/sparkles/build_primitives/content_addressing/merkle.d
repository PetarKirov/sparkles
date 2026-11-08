/**
The Merkle shell: one fold scheme (FSS3) that names a fileset's tree by
hashing each directory over its entries' ids, for any directory encoding
and any file identity.

A scheme is `MerkleFold!(Dir, Leaf)`. `Dir` encodes level 1, a directory;
`Leaf` names level 2, one file's bytes. Each is a struct with required
primitives and optional hooks, found by introspection:

$(TABLE
$(TR $(TH Part) $(TH Member) $(TH Meaning))
$(TR $(TD `Dir`) $(TD `enum order`) $(TD required: the `EntryOrder` the
    encoding sorts by; never `none` (FSS5)))
$(TR $(TD) $(TD `alias Id`) $(TD required: a directory's id, the fold's
    value, and the scheme's result for the fileset root))
$(TR $(TD) $(TD `void begin()`) $(TD required: starts a directory))
$(TR $(TD) $(TD `void directory(name, ref const Id)`) $(TD required: a
    subdirectory, with the id its own fold produced))
$(TR $(TD) $(TD `void file(name, bool executable, ref const Leaf.Id, ulong
    size)`) $(TD required: a regular file))
$(TR $(TD) $(TD `void symlink(name, target)`) $(TD required: a link))
$(TR $(TD) $(TD `Id seal()`) $(TD required: ends the directory))
$(TR $(TD) $(TD `enum metadata`) $(TD optional: the `FsoMetadata` the
    encoding needs; absent, the executable bit and link targets))
$(TR $(TD) $(TD `alias Leaf`) $(TD optional: the file identity the encoding
    expects, used when `MerkleFold` is given no `Leaf`))
$(TR $(TD `Leaf`) $(TD `alias Id`) $(TD required: a file's id))
$(TR $(TD) $(TD `void start(ulong size)`) $(TD required: begins a file of
    `size` bytes))
$(TR $(TD) $(TD `void put(scope const(ubyte)[])`) $(TD required: the next
    bytes))
$(TR $(TD) $(TD `Id finish()`) $(TD required: the file's id))
)

A file is read through its entry's `FsoRef` while `fold` runs, at the size
its `stat` reports; a file whose size changes while it is read fails the
resolution rather than give an id for bytes that never existed together.
Nothing allocates while hashing.

Specified in `docs/specs/build-primitives/filesets/decisions.md`, A19.
*/
module sparkles.build_primitives.content_addressing.merkle;

import std.digest : isDigest;

import sparkles.base.io.errors : ErrorKind;
import sparkles.build_primitives.fileset.fso : EntryOrder, FsoKind, FsoMetadata, Traversal;

/// Whether `L` is a file identity: a byte sink that names what it was fed.
enum bool isLeaf(L) = is(L.Id) && is(typeof((ref L l, scope const(ubyte)[] bytes) {
    l.start(ulong(0));
    l.put(bytes);
    L.Id id = l.finish();
}));

/// Whether `D` encodes a directory over the file ids of `Leaf`.
enum bool isDirFormat(D, Leaf) = is(D.Id) && is(typeof(D.order) : EntryOrder)
    && is(typeof((ref D d, ref const D.Id child, ref const Leaf.Id id, const(char)[] name) {
        d.begin();
        d.directory(name, child);
        d.file(name, true, id, ulong(0));
        d.symlink(name, name);
        D.Id sealed = d.seal();
    }));

/// The file identity a directory encoding expects, when it names one.
template DefaultLeaf(Dir)
{
    static if (__traits(hasMember, Dir, "Leaf"))
        alias DefaultLeaf = Dir.Leaf;
    else
        static assert(false, Dir.stringof ~ " names no Leaf: pass one to MerkleFold");
}

/**
A fold scheme naming a tree by `Dir`'s encoding over `Leaf`'s file ids. Its
value and result are `Dir.Id`.
*/
struct MerkleFold(Dir, Leaf = DefaultLeaf!Dir)
if (isLeaf!Leaf && isDirFormat!(Dir, Leaf))
{
    static assert(Dir.order != EntryOrder.none,
        Dir.stringof ~ " sorts by EntryOrder.none: its ids would differ between hosts (FSS5)");

    enum order = Dir.order;              ///
    enum traversal = Traversal.fold;     ///
    static if (__traits(hasMember, Dir, "metadata"))
        enum FsoMetadata metadata = Dir.metadata; ///
    else
        enum metadata = cast(FsoMetadata)(FsoMetadata.executable | FsoMetadata.linkTarget); ///

    alias Value = Dir.Id;  ///
    alias Result = Dir.Id; ///

    Dir dir;   /// the encoding's state, reused for every directory
    Leaf leaf; /// the file identity's state, reused for every file
    private string why;

    /// Encodes one directory, hashing its files.
    bool fold(Entries, Exec)(scope const(char)[] path, Entries entries, bool empty, ref Exec exec,
        out Value value)
    {
        dir.begin();
        foreach (e; entries)
        {
            final switch (e.node.kind)
            {
                case FsoKind.directory:
                    dir.directory(e.name, e.value);
                    break;
                case FsoKind.symlink:
                    dir.symlink(e.name, e.node.target);
                    break;
                case FsoKind.regular:
                    Leaf.Id id;
                    ulong size;
                    if (!hashFile(e.ref_, id, size))
                        return false;
                    dir.file(e.name, e.node.executable, id, size);
                    break;
            }
        }
        value = dir.seal();
        return true;
    }

    /// A tree whose entries cannot all be read has no id (FSE1).
    bool incomplete(scope const(char)[] path, ErrorKind kind) =>
        fail("an entry could not be read, so the tree has no id");

    /// Why the fold aborted.
    string failure() const => why;

    /// The fileset root's id.
    Result finish(ref Value root) => root;

    // Hashes the file `r` names, streamed at the size its `stat` reports.
    private bool hashFile(Ref)(Ref r, out Leaf.Id id, out ulong size)
    {
        const why = streamFile(r, leaf, size);
        if (why.length)
            return fail(why);
        id = leaf.finish();
        return true;
    }

    private bool fail(string s)
    {
        why = s;
        return false;
    }
}

/**
Streams the file `r` names into `sink`: `sink.start(size)` with the size its
`stat` reports, then `sink.put` with every byte. Returns why it failed, or
`null`; a file whose size changes while it is read fails, rather than give
bytes that never existed together.
*/
string streamFile(Ref, Sink)(Ref r, ref Sink sink, out ulong size)
{
    import sparkles.base.vfs.types : OpenMode;

    auto file = r.dir.openFile!(OpenMode.read)(r.name);
    if (file.hasError)
        return "a member could not be opened";
    const st = file.value.stat();
    if (st.hasError)
        return "a member could not be stat-ed";
    size = st.value.size;
    sink.start(size);
    ulong seen;
    ubyte[16 * 1024] buf = void;
    for (;;)
    {
        auto n = file.value.read(buf[]);
        if (n.hasError)
            return "a member could not be read";
        if (n.value == 0)
            break;
        seen += n.value;
        if (seen > size)
            break;
        sink.put(buf[0 .. n.value]);
    }
    return seen == size ? null : "a member changed size while it was read";
}

/// A file identity that is a digest of the file's bytes alone, with no
/// header: Snix's and REAPI's blobs, and iroh's.
struct DigestLeaf(H)
if (isDigest!H)
{
    alias Id = typeof(H.init.finish()); ///
    private H h;

    ///
    void start(ulong size)
    {
        h.start();
    }

    ///
    void put(scope const(ubyte)[] bytes)
    {
        h.put(bytes);
    }

    ///
    Id finish() => h.finish();
}

/**
A file identity that is a digest of a header and then the file's bytes, the
header naming `kind` and the length: git's `blob <length>\0`.
*/
struct FramedLeaf(H, string kind)
if (isDigest!H)
{
    alias Id = typeof(H.init.finish()); ///
    private H h;

    ///
    void start(ulong size)
    {
        h.start();
        putHeader(h, kind, size);
    }

    ///
    void put(scope const(ubyte)[] bytes)
    {
        h.put(bytes);
    }

    ///
    Id finish() => h.finish();
}

/// Writes `<kind> <length>\0` into the digest `h`: the header git puts before
/// every object.
void putHeader(H)(ref H h, scope const(char)[] kind, ulong length)
{
    import sparkles.base.text.writers : writeText;

    // An output range of text over the digest.
    static struct Into
    {
        H* h;
        void put(char c) { h.put(cast(ubyte) c); }
        void put(scope const(char)[] s) { h.put(cast(const(ubyte)[]) s); }
    }

    auto into = Into(&h);
    into.writeText(i"$(kind) $(length)\0");
}

/// A digest of `<kind> <length>\0` and then `bytes`: one whole git object.
auto objectDigest(H)(scope const(char)[] kind, scope const(ubyte)[] bytes)
{
    H h;
    h.start();
    putHeader(h, kind, bytes.length);
    h.put(bytes);
    return h.finish();
}

/// Neither leaf allocates or throws; the git object header is the one
/// `sha1sum` sees.
@("content_addressing.merkle.leaves")
@safe pure nothrow @nogc unittest
{
    import std.digest.sha : SHA1;

    import sparkles.base.hash.blake3 : Blake3, blake3;

    static immutable ubyte[] hello = cast(immutable(ubyte)[]) "hello\n";
    FramedLeaf!(SHA1, "blob") git;
    git.start(hello.length);
    git.put(hello);
    // `printf 'hello\n' | git hash-object --stdin`
    static immutable ubyte[20] gitHello = [
        0xce, 0x01, 0x36, 0x25, 0x03, 0x0b, 0xa8, 0xdb, 0xa9, 0x06,
        0xf7, 0x56, 0x96, 0x7f, 0x9e, 0x9c, 0xa3, 0x94, 0x46, 0x4a,
    ];
    assert(git.finish() == gitHello);
    assert(objectDigest!SHA1("blob", hello) == gitHello);

    DigestLeaf!Blake3 raw;
    raw.start(hello.length);
    raw.put(hello);
    assert(raw.finish() == blake3(hello));
}
