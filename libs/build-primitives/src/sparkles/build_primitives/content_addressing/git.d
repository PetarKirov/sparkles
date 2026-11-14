/**
Git's tree object as a directory encoding for `MerkleFold`: entries
`<mode> <name>\0<id>` in `gitTreeOrder`, hashed with git's object header by
`H`, SHA-1 in a SHA-1 repository and SHA-256 in a SHA-256 one.

A file is a blob, `blob <length>\0` and its bytes; a link is a blob of its
target. A directory holding nothing has no id, as git's index cannot hold
one: its parent omits it, and a fileset holding nothing is the empty tree.

`git write-tree` is the oracle (`content_addressing.git.writeTree`).
*/
module sparkles.build_primitives.content_addressing.git;

import std.digest : isDigest;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.build_primitives.content_addressing.merkle : FramedLeaf, MerkleFold, objectDigest;
import sparkles.build_primitives.fileset.fso : EntryOrder;

/// Git's tree encoding, hashed by `H`.
struct GitTree(H)
if (isDigest!H)
{
    /// Git's object id under `H`.
    alias Digest = typeof(H.init.finish());

    /// A tree's id, and whether it holds nothing, which its parent omits.
    static struct Id
    {
        Digest digest; ///
        bool empty;    ///
    }

    alias Leaf = FramedLeaf!(H, "blob"); ///
    enum order = EntryOrder.gitTreeOrder; ///

    private UniqueBuffer!(ubyte, 1024) body;

    ///
    void begin()
    {
        body.clear(false);
    }

    ///
    void directory(scope const(char)[] name, ref const Id child)
    {
        if (!child.empty)
            entry("40000", name, child.digest);
    }

    ///
    void file(scope const(char)[] name, bool executable, ref const Digest id, ulong size)
    {
        entry(executable ? "100755" : "100644", name, id);
    }

    ///
    void symlink(scope const(char)[] name, scope const(char)[] target)
    {
        const id = objectDigest!H("blob", cast(const(ubyte)[]) target);
        entry("120000", name, id);
    }

    ///
    Id seal() => Id(objectDigest!H("tree", body[]), body.length == 0);

    private void entry(string mode, scope const(char)[] name, ref const Digest id)
    {
        body.put(cast(const(ubyte)[]) mode);
        body.put(cast(ubyte) ' ');
        body.put(cast(const(ubyte)[]) name);
        body.put(cast(ubyte) 0);
        body.put(id[]);
    }
}

/// Git's tree id of a fileset, by `H`.
alias GitTreeScheme(H) = MerkleFold!(GitTree!H);

/// An id as `git` prints it: lowercase hex.
auto toHex(size_t n)(in ubyte[n] digest)
{
    import std.digest : LetterCase, toHexString;

    return toHexString!(LetterCase.lower)(digest);
}

/// The tree holding nothing has git's well-known empty-tree id.
@("content_addressing.git.emptyTree")
@safe pure nothrow @nogc unittest
{
    import std.digest.sha : SHA1;

    GitTree!SHA1 git;
    git.begin();
    const id = git.seal();
    assert(id.empty);
    assert(toHex(id.digest) == "4b825dc642cb6eb9a060e54bf8d69288fbee4904");
}
