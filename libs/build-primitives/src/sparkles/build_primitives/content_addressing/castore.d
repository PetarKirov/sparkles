/**
Snix's castore as a directory encoding for `MerkleFold`: the default
identity of a fileset (A19).

A file's id is BLAKE3 over its bytes, with no header: the same digest names
the blob in iroh. A directory's id is BLAKE3 over its `Directory` message in
canonical protobuf, which holds three lists, each sorted by name: the
subdirectories, the files and the links, so `partitionedOrder` emits them
in the order the message encodes them. Each entry carries a size beside its
digest: a file's length, and for a subdirectory the number of entries beneath
it. A directory holding nothing is kept, with the digest of the empty
message.

The message, from Snix's `castore.proto`:

```proto
message Directory {
    repeated DirectoryEntry directories = 1;
    repeated FileEntry files = 2;
    repeated SymlinkEntry symlinks = 3;
}
message DirectoryEntry { bytes name = 1; bytes digest = 2; uint64 size = 3; }
message FileEntry { bytes name = 1; bytes digest = 2; uint64 size = 3; bool executable = 4; }
message SymlinkEntry { bytes name = 1; bytes target = 2; }
```

Canonical protobuf writes fields in number order and leaves out a field at
its default value: a zero size, a `false` executable bit. Snix's own
`snix-castore ingest` is the oracle (`content_addressing.castore.snix`).
*/
module sparkles.build_primitives.content_addressing.castore;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.hash.blake3 : Blake3, blake3;
import sparkles.build_primitives.content_addressing.merkle : DigestLeaf, MerkleFold;
import sparkles.build_primitives.fileset.fso : EntryOrder;

@safe:

/// Snix castore's directory encoding.
struct CastoreDirectory
{
    /// A directory's id: its digest, and the number of entries beneath it.
    static struct Id
    {
        ubyte[32] digest; ///
        ulong size;       ///
    }

    alias Leaf = DigestLeaf!Blake3; ///
    enum order = EntryOrder.partitionedOrder; ///

    private UniqueBuffer!(ubyte, 1024) body;
    private ulong size;
    private ubyte lastField; // each list follows the one before (canonical form)

    ///
    void begin() pure nothrow @nogc
    {
        body.clear(false);
        size = 0;
        lastField = 0;
    }

    ///
    void directory(scope const(char)[] name, ref const Id child) pure nothrow @nogc
    {
        const sizeLength = child.size ? 1 + varintLength(child.size) : 0;
        open(1, field(name.length) + field(32) + sizeLength);
        bytesField(1, cast(const(ubyte)[]) name);
        bytesField(2, child.digest[]);
        if (child.size)
            varintField(3, child.size);
        size += 1 + child.size;
    }

    ///
    void file(scope const(char)[] name, bool executable, ref const ubyte[32] id, ulong length)
        pure nothrow @nogc
    {
        const sizeLength = length ? 1 + varintLength(length) : 0;
        open(2, field(name.length) + field(32) + sizeLength + (executable ? 2 : 0));
        bytesField(1, cast(const(ubyte)[]) name);
        bytesField(2, id[]);
        if (length)
            varintField(3, length);
        if (executable)
            varintField(4, 1);
        size += 1;
    }

    ///
    void symlink(scope const(char)[] name, scope const(char)[] target) pure nothrow @nogc
    {
        open(3, field(name.length) + (target.length ? field(target.length) : 0));
        bytesField(1, cast(const(ubyte)[]) name);
        if (target.length)
            bytesField(2, cast(const(ubyte)[]) target);
        size += 1;
    }

    ///
    Id seal() pure nothrow @nogc => Id(blake3(body[]), size);

    // Starts an entry of the message's list `number`, `length` bytes long.
    private void open(ubyte number, size_t length) pure nothrow @nogc
    in (number >= lastField, "castore's lists are encoded in field order")
    {
        lastField = number;
        key(number, 2);
        varint(length);
    }

    private void bytesField(ubyte number, scope const(ubyte)[] bytes) pure nothrow @nogc
    {
        key(number, 2);
        varint(bytes.length);
        body.put(bytes);
    }

    private void varintField(ubyte number, ulong value) pure nothrow @nogc
    {
        key(number, 0);
        varint(value);
    }

    private void key(ubyte number, ubyte wireType) pure nothrow @nogc
    {
        body.put(cast(ubyte)((number << 3) | wireType));
    }

    private void varint(ulong value) pure nothrow @nogc
    {
        while (value >= 0x80)
        {
            body.put(cast(ubyte)(value | 0x80));
            value >>= 7;
        }
        body.put(cast(ubyte) value);
    }

    // The length of a bytes field of `n` bytes, key and length included.
    private static size_t field(size_t n) pure nothrow @nogc => 1 + varintLength(n) + n;
}

/// The bytes of `value` as a protobuf varint.
size_t varintLength(ulong value) pure nothrow @nogc
{
    size_t n = 1;
    while (value >= 0x80)
    {
        value >>= 7;
        ++n;
    }
    return n;
}

/// The castore id of a fileset.
alias CastoreScheme = MerkleFold!CastoreDirectory;

/// A digest as Snix prints it: `blake3-` and standard, padded base64.
char[51] toCastoreText(in ubyte[32] digest) pure nothrow @nogc
{
    import std.base64 : Base64;

    char[51] text = "blake3-                                            ";
    Base64.encode(digest[], text[7 .. $]);
    return text;
}

/// The empty directory is the digest of the empty message; sizes count
/// every entry beneath, and a nested directory's own.
@("content_addressing.castore.encoding")
pure nothrow @nogc unittest
{
    CastoreDirectory d;
    d.begin();
    const empty = d.seal();
    assert(empty.digest == blake3(""));
    assert(empty.size == 0);
    assert(toCastoreText(empty.digest) == "blake3-rxNJufX5oaagQE3qNtzJSZvLJcmtwRK3zJqTyuQfMmI=");

    d.begin();
    const ubyte[32] zero;
    d.directory("d", empty);
    d.file("f", true, zero, 3);
    d.symlink("l", "f");
    const id = d.seal();
    assert(id.size == 3);
    // directories: [{name "d", digest}]; files: [{name "f", digest, size 3,
    // executable}]; symlinks: [{name "l", target "f"}].
    ubyte[128] want;
    size_t n;
    void put(scope const(ubyte)[] bytes...)
    {
        want[n .. n + bytes.length] = bytes;
        n += bytes.length;
    }

    put(0x0a, 37, 0x0a, 1, 'd', 0x12, 32);
    put(empty.digest[]);
    put(0x12, 41, 0x0a, 1, 'f', 0x12, 32);
    put(zero[]);
    put(0x18, 3, 0x20, 1);
    put(0x1a, 6, 0x0a, 1, 'l', 0x12, 1, 'f');
    assert(id.digest == blake3(want[0 .. n]));

    d.begin();
    d.directory("e", id);
    assert(d.seal().size == 4);
}
