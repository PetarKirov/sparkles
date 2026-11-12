/**
iroh's collection, as `sendme` sends a directory (CAI1–CAI3): every member
regular file, listed under a label and its path, each named by the BLAKE3
digest of its bytes, and the whole named by the digest of the hash sequence
that lists them.

A collection is two blobs. The _metadata blob_ is the 13 bytes
`CollectionV0.` and then the names, in postcard: a count, then each name's
length and its UTF-8 bytes, every number an unsigned LEB128 varint. The
_hash sequence_ is the metadata blob's digest followed by each file's
digest, in the names' byte order. The collection's name is the hash
sequence's BLAKE3 digest, the hash a `sendme` ticket carries.

The collection is flat, so as a directory encoding (`IrohCollection`) a
directory's id is the list of the files beneath it, their paths relative to
it, and `collectionOf` labels, sorts and hashes the root's list (C6). It
names a file by BLAKE3 over its bytes, castore's file identity, so a tee
holding both hashes each file once (CAT4). Links are left out and counted,
as `sendme` leaves them out (CAI2).

iroh-blobs' own `Collection`, over `sendme`'s import, is the oracle
(`content_addressing.collection.irohBlobs`).
*/
module sparkles.build_primitives.content_addressing.collection;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.hash.blake3 : Blake3, blake3;
import sparkles.base.text.errors : NoGcHook;
import sparkles.build_primitives.content_addressing.merkle : DigestLeaf, MerkleFold;
import sparkles.build_primitives.fileset.fso : EntryOrder;

/// The 13 bytes a collection's metadata blob starts with.
enum string collectionHeader = "CollectionV0.";

/// One file of a collection: its path beneath the directory whose id holds
/// it, `/` between components, its BLAKE3 digest and its size.
struct CollectionFile
{
    string path;       ///
    ubyte[32] digest;  ///
    ulong size;        ///
}

/// iroh's collection as a directory encoding: a directory's id is the list
/// of the files beneath it, and the number of links left out.
struct IrohCollection
{
    /// The files beneath a directory, paths relative to it, in no order, and
    /// the links beneath it, which a collection cannot carry.
    static struct Id
    {
        immutable(CollectionFile)[] files; ///
        size_t links;                      ///
    }

    alias Leaf = DigestLeaf!Blake3; ///
    // Any order serves: `collectionOf` sorts the whole list once.
    enum order = EntryOrder.narOrder; ///

    private CollectionFile[] files;
    private size_t links;

    ///
    void begin() @safe pure nothrow
    {
        // A fresh list: the last directory's id still holds the old one.
        files = null;
        links = 0;
    }

    ///
    void directory(scope const(char)[] name, ref const Id child) @safe pure nothrow
    {
        foreach (ref f; child.files)
            files ~= CollectionFile(joinPath(name, f.path), f.digest, f.size);
        links += child.links;
    }

    ///
    void file(scope const(char)[] name, bool executable, ref const ubyte[32] id, ulong size)
        @safe pure nothrow
    {
        files ~= CollectionFile(name.idup, id, size);
    }

    ///
    void symlink(scope const(char)[] name, scope const(char)[] target) @safe pure nothrow
    {
        ++links;
    }

    ///
    Id seal() @trusted pure nothrow
    {
        // Nothing else refers to `files` once it is sealed: `begin` drops it.
        return Id(cast(immutable(CollectionFile)[]) files, links);
    }

    private static string joinPath(scope const(char)[] dir, string path) @safe pure nothrow
    {
        auto joined = new char[dir.length + 1 + path.length];
        joined[0 .. dir.length] = dir[];
        joined[dir.length] = '/';
        joined[dir.length + 1 .. $] = path[];
        return (() @trusted => cast(string) joined)();
    }
}

/// The collection a fileset's tree holds, before it is labelled.
alias IrohCollectionScheme = MerkleFold!IrohCollection;

/// A collection's name and what it lists (CAI1).
struct CollectionName
{
    ubyte[32] root;          /// the hash sequence's digest: the collection's name
    ubyte[32] meta;          /// the metadata blob's digest
    CollectionFile[] files;  /// the files, paths without the label, in the names' order
    ulong bytes;             /// the files' total size
    size_t links;            /// the links left out (CAI2)
}

/// A collection's name, or why `sendme` could not name it.
alias CollectionExpected = Expected!(CollectionName, string, NoGcHook);

/**
Labels the files of `root`, a fileset's id under `IrohCollection`, with
`label` and names the collection, as `sendme send label` would. Fails for a
label that is not one path component, and for a member whose path is not
UTF-8 or holds a `\` in a component, naming it (CAI3).
*/
CollectionExpected collectionOf(in IrohCollection.Id root, scope const(char)[] label) @safe
{
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;

    if (label.length == 0 || label == "." || label == ".." || label.canFind('/') || label.canFind('\\'))
        return err!(CollectionName, NoGcHook)(("the label `" ~ label ~ "` is not one path component").idup);
    CollectionName c;
    c.links = root.links;
    c.files = root.files.dup;
    foreach (ref f; c.files)
    {
        if (!isUtf8(f.path))
            return err!(CollectionName, NoGcHook)("`" ~ f.path ~ "` is not UTF-8, which a collection's names must be");
        if (f.path.canFind('\\'))
            return err!(CollectionName, NoGcHook)("`" ~ f.path ~ "` holds a `\\`, which a collection refuses in a name");
        c.bytes += f.size;
    }
    // Every name starts with the label and a `/`: the paths sort as the names do.
    sort!((a, b) => a.path < b.path)(c.files);

    Blake3 meta;
    meta.put(cast(const(ubyte)[]) collectionHeader);
    putVarint(meta, c.files.length);
    foreach (ref f; c.files)
    {
        putVarint(meta, label.length + 1 + f.path.length);
        meta.put(cast(const(ubyte)[]) label);
        meta.put(cast(const(ubyte)[]) "/");
        meta.put(cast(const(ubyte)[]) f.path);
    }
    c.meta = meta.finish();

    Blake3 seq;
    seq.put(c.meta[]);
    foreach (ref f; c.files)
        seq.put(f.digest[]);
    c.root = seq.finish();
    return ok!(string, NoGcHook)(c);
}

/**
Writes a collection's metadata blob for `names` (CAI1): the header, then
the names in postcard.
*/
void collectionMeta(Writer)(scope const(char[])[] names, ref Writer w)
{
    w.put(cast(const(ubyte)[]) collectionHeader);
    putVarint(w, names.length);
    foreach (n; names)
    {
        putVarint(w, n.length);
        w.put(cast(const(ubyte)[]) n);
    }
}

/// Three names, encoded by hand from postcard's rules: the header, the
/// count, each length and its bytes.
@("content_addressing.collection.CAI1.metaBlob")
@safe pure nothrow unittest
{
    import sparkles.base.buffer : UniqueBuffer;

    UniqueBuffer!(ubyte, 64) b;
    collectionMeta(["d/a", "d/é", "d/" ~ 'x'.repeatChar(130)], b);
    ubyte[] expected = cast(ubyte[]) "CollectionV0.".dup;
    expected ~= 3;
    expected ~= [3, 'd', '/', 'a'];
    expected ~= [4, 'd', '/', 0xc3, 0xa9];
    expected ~= [132, 1, 'd', '/'];        // 132 bytes: a varint of two bytes
    foreach (_; 0 .. 130)
        expected ~= 'x';
    assert(b[] == expected);
}

/// The name is the digest of the hash sequence: the metadata blob's digest,
/// then the files' digests in name order; links are left out and counted.
@("content_addressing.collection.CAI1.byHand")
@safe unittest
{
    IrohCollection c;
    c.begin();
    const one = blake3(cast(const(ubyte)[]) "1"), two = blake3(cast(const(ubyte)[]) "22");
    c.file("b", false, two, 2);
    c.symlink("l", "b");
    const sub = c.seal();
    c.begin();
    c.file("a", true, one, 1);
    c.directory("s", sub);
    const root = c.seal();

    const got = collectionOf(root, "top");
    assert(got.hasValue);
    const n = got.value;
    assert(n.links == 1 && n.bytes == 3 && n.files.length == 2);
    assert(n.files[0].path == "a" && n.files[1].path == "s/b");

    ubyte[] meta = cast(ubyte[]) "CollectionV0.".dup;
    meta ~= [2, 5, 't', 'o', 'p', '/', 'a', 7, 't', 'o', 'p', '/', 's', '/', 'b'];
    assert(n.meta == blake3(meta));
    assert(n.root == blake3(n.meta[] ~ one[] ~ two[]));
}

/// A label that is not one path component, a `\` in a member's name and a
/// name that is not UTF-8 are refused, naming the member (CAI3).
@("content_addressing.collection.CAI3.refused")
@safe unittest
{
    IrohCollection c;
    c.begin();
    const id = blake3(cast(const(ubyte)[]) "");
    c.file("ok", false, id, 0);
    const fine = c.seal();
    foreach (bad; ["", ".", "..", "a/b", "a\\b"])
        assert(collectionOf(fine, bad).hasError, bad);
    assert(collectionOf(fine, ".a").hasValue);

    c.begin();
    c.file("x\\y", false, id, 0);
    const slash = collectionOf(c.seal(), "t");
    assert(slash.hasError && slash.error == "`x\\y` holds a `\\`, which a collection refuses in a name");

    c.begin();
    c.file("\xff", false, id, 0);
    const notUtf8 = collectionOf(c.seal(), "t");
    assert(notUtf8.hasError && notUtf8.error == "`\xff` is not UTF-8, which a collection's names must be");
}

/// An empty collection lists nothing, and is still named.
@("content_addressing.collection.CAI2.empty")
@safe unittest
{
    IrohCollection c;
    c.begin();
    const got = collectionOf(c.seal(), "t");
    assert(got.hasValue && got.value.files.length == 0);
    assert(got.value.meta == blake3(cast(const(ubyte)[]) "CollectionV0.\x00"));
    assert(got.value.root == blake3(got.value.meta[]));
}

// ---------------------------------------------------------------------------

// Writes `n` as an unsigned LEB128 varint, postcard's encoding of a length.
private void putVarint(Writer)(ref Writer w, ulong n)
{
    ubyte[10] b;
    size_t k;
    do
    {
        ubyte byte_ = n & 0x7f;
        n >>= 7;
        if (n)
            byte_ |= 0x80;
        b[k++] = byte_;
    }
    while (n);
    w.put(b[0 .. k]);
}

// Whether `s` is well-formed UTF-8.
private bool isUtf8(scope const(char)[] s) @safe pure nothrow
{
    import std.uni : isSurrogate;

    // Decoded by hand: Phobos' decoders throw, or turn a malformed sequence
    // into U+FFFD, which a real U+FFFD cannot be told apart from.
    size_t i;
    while (i < s.length)
    {
        const c = s[i];
        size_t len = c < 0x80 ? 1 : (c & 0xe0) == 0xc0 ? 2 : (c & 0xf0) == 0xe0 ? 3 : (c & 0xf8) == 0xf0 ? 4 : 0;
        if (len == 0 || i + len > s.length || (len == 2 && c < 0xc2))
            return false;
        dchar d = len == 1 ? c : len == 2 ? c & 0x1f : len == 3 ? c & 0x0f : c & 0x07;
        foreach (k; 1 .. len)
        {
            if ((s[i + k] & 0xc0) != 0x80)
                return false;
            d = (d << 6) | (s[i + k] & 0x3f);
        }
        if ((len == 3 && d < 0x800) || (len == 4 && (d < 0x10000 || d > 0x10ffff)) || isSurrogate(d))
            return false;
        i += len;
    }
    return true;
}

@("content_addressing.collection.isUtf8")
@safe pure nothrow unittest
{
    assert(isUtf8("") && isUtf8("abc") && isUtf8("é") && isUtf8("€") && isUtf8("\U0001F600"));
    assert(isUtf8("\xef\xbf\xbd"), "U+FFFD itself is valid");
    assert(!isUtf8("\xff") && !isUtf8("\xc3") && !isUtf8("\xc0\xaf"), "invalid, truncated, overlong");
    assert(!isUtf8("\xed\xa0\x80"), "a surrogate");
}

// `n` copies of `c`, for the tests.
private string repeatChar(char c, size_t n) @safe pure nothrow
{
    auto s = new char[n];
    s[] = c;
    return (() @trusted => cast(string) s)();
}
