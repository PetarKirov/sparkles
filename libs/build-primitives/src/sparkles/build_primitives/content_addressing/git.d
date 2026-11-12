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

/// A SHA-1 tree id as Nix's git hashing prints it, in SRI form: `sha1-` and
/// standard, padded base64 (CAG3).
char[33] toGitSri(in ubyte[20] digest) @safe pure nothrow @nogc
{
    import std.base64 : Base64;

    char[33] text = "sha1-                            ";
    Base64.encode(digest[], text[5 .. $]);
    return text;
}

/// A SHA-1 tree id as Software Heritage's identifier of a directory, its
/// SWHID: `swh:1:dir:` and the id in lowercase hex (CAG3).
char[50] toSwhid(in ubyte[20] digest) @safe pure nothrow @nogc
{
    char[50] text = "swh:1:dir:";
    text[10 .. $] = toHex(digest)[];
    return text;
}

/// The empty tree's id in both forms.
@("content_addressing.git.CAG3.forms")
@safe pure nothrow @nogc unittest
{
    import std.digest.sha : SHA1;

    GitTree!SHA1 git;
    git.begin();
    const id = git.seal().digest;
    assert(toSwhid(id)[] == "swh:1:dir:4b825dc642cb6eb9a060e54bf8d69288fbee4904");
    // As `nix hash path --mode git --algo sha1` prints an empty directory.
    assert(toGitSri(id)[] == "sha1-S4JdxkLLbrmgYOVL+NaSiPvuSQQ=");
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
