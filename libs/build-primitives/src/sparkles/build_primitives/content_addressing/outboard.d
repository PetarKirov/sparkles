/**
iroh's outboard: the interior of a file's BLAKE3 tree, kept beside the file
so that any part of it can be checked against the file's id as it is read
(CAO, decision C2).

BLAKE3 hashes 1024-byte chunks into a binary tree whose left subtree always
holds the largest power of two chunks below the whole. iroh stores that tree
down to groups of 16 chunks (16 KiB): one 64-byte record per parent node, the
left child's chaining value and then the right's, in pre-order, with no
header and no size. A file of `n` groups has `n - 1` records; a file of one
group has none, its root alone names it. A file's root is its plain BLAKE3
digest, which is also its castore id.

$(UL
$(LI $(LREF OutboardLeaf) is a file identity that builds the outboard while it
    hashes, so naming a file and producing its outboard is one read.)
$(LI $(LREF check) accepts a supplied tree without the file: its outboard has
    the length its size implies and its top record chains to its root.)
$(LI $(LREF verifyGroup) and $(LREF VerifiedReader) check bytes read later,
    one group at a time, before any of the group is surfaced.)
$(LI $(LREF OutboardSupply) hands supplied trees to `MerkleFold`, which then
    names those files without opening them (CAO1).)
)

n0's `bao-tree`, which iroh uses, is the oracle
(`content_addressing.outboard.baoTree`).
*/
module sparkles.build_primitives.content_addressing.outboard;

import core.bitop : bsr;

import sparkles.base.buffer : HeapBuffer;
import sparkles.base.expected : Expected, err, ok;
import sparkles.base.hash.blake3 : Blake3, blake3, blake3ParentCv, blake3ParentRoot;
import sparkles.base.text.errors : NoGcHook;
import sparkles.build_primitives.content_addressing.merkle : Supplied;

/// The bytes in one chunk group: 16 chunks, iroh's `BlockSize(4)`.
enum size_t chunkGroupSize = 16 * 1024;

/// The bytes in one outboard record: two chaining values.
enum size_t recordSize = 64;

/// The chunk groups of a file of `size` bytes; an empty file has one.
ulong chunkGroups(ulong size) @safe pure nothrow @nogc =>
    size == 0 ? 1 : (size + chunkGroupSize - 1) / chunkGroupSize;

/// The bytes in the outboard of a file of `size` bytes.
ulong outboardSize(ulong size) @safe pure nothrow @nogc =>
    (chunkGroups(size) - 1) * recordSize;

/// The bytes in group `group` of a file of `size` bytes.
size_t groupLength(ulong size, ulong group) @safe pure nothrow @nogc
in (group < chunkGroups(size))
{
    const start = group * chunkGroupSize;
    const rest = size - start;
    return rest < chunkGroupSize ? cast(size_t) rest : chunkGroupSize;
}

///
@("content_addressing.outboard.sizes")
@safe pure nothrow @nogc unittest
{
    assert(chunkGroups(0) == 1 && outboardSize(0) == 0);
    assert(chunkGroups(chunkGroupSize) == 1 && outboardSize(chunkGroupSize) == 0);
    assert(chunkGroups(chunkGroupSize + 1) == 2 && outboardSize(chunkGroupSize + 1) == 64);
    assert(outboardSize(40_000) == 128);
    assert(groupLength(40_000, 2) == 40_000 - 2 * chunkGroupSize);
}

// The groups in the left subtree of a node over `groups` groups: the largest
// power of two below it, as in BLAKE3's own tree.
private ulong leftGroups(ulong groups) @safe pure nothrow @nogc
in (groups > 1)
    => ulong(1) << bsr(groups - 1);

/// Why a supplied tree or the bytes read against it were refused.
enum OutboardError : ubyte
{
    wrongLength,   /// the outboard's length is not the one its size implies
    rootMismatch,  /// the outboard's top record does not chain to the root
    groupMismatch, /// a chunk group's bytes do not chain to the root
    shortGroup,    /// a chunk group was not the length the size implies
    readFailed,    /// the file could not be read
}

/// What a supplied tree check returns.
alias OutboardResult(T) = Expected!(T, OutboardError, NoGcHook);

/**
A file's supplied tree: its root digest and size, which travel beside the
outboard, and the outboard itself, borrowed.
*/
struct SuppliedTree
{
    ubyte[32] root;           /// the file's BLAKE3 digest
    ulong size;               /// the file's length in bytes
    const(ubyte)[] outboard;  /// the pre-order records, borrowed
}

/**
Accepts `tree` without reading the file it describes: the outboard is as long
as the size implies, and its top record merges into the root. A file of one
group has no record, so only its length can be checked until it is read.
*/
OutboardResult!bool check(in SuppliedTree tree) @safe pure nothrow @nogc
{
    if (tree.outboard.length != outboardSize(tree.size))
        return err!(bool, NoGcHook)(OutboardError.wrongLength);
    if (tree.outboard.length)
    {
        const ubyte[32] left = tree.outboard[0 .. 32], right = tree.outboard[32 .. 64];
        if (blake3ParentRoot(left, right) != tree.root)
            return err!(bool, NoGcHook)(OutboardError.rootMismatch);
    }
    return ok!(OutboardError, NoGcHook)(true);
}

/**
Checks the bytes of chunk group `group` against `tree`, walking from the root
down the records to it: each record must merge into the value its parent
expects, and the group's own chaining value must equal the last. `tree` is
assumed to have passed $(LREF check).
*/
OutboardResult!bool verifyGroup(in SuppliedTree tree, ulong group, scope const(ubyte)[] bytes)
    @safe pure nothrow @nogc
in (group < chunkGroups(tree.size))
{
    if (bytes.length != groupLength(tree.size, group))
        return err!(bool, NoGcHook)(OutboardError.shortGroup);
    ulong lo = 0, hi = chunkGroups(tree.size);
    if (hi == 1)
        return blake3(bytes) == tree.root ? ok!(OutboardError, NoGcHook)(true)
            : err!(bool, NoGcHook)(OutboardError.groupMismatch);

    ubyte[32] expected = tree.root;
    bool root = true;
    size_t at = 0; // the record of the node covering [lo, hi)
    while (hi - lo > 1)
    {
        const record = tree.outboard[at * recordSize .. (at + 1) * recordSize];
        const ubyte[32] left = record[0 .. 32], right = record[32 .. 64];
        const merged = root ? blake3ParentRoot(left, right) : blake3ParentCv(left, right);
        if (merged != expected)
            return err!(bool, NoGcHook)(OutboardError.groupMismatch);
        root = false;
        const mid = lo + leftGroups(hi - lo);
        if (group < mid)
        {
            expected = left;
            at += 1;
            hi = mid;
        }
        else
        {
            expected = right;
            at += cast(size_t) (mid - lo); // past this node and its left subtree
            lo = mid;
        }
    }
    Blake3 h;
    h.setInputOffset(group * chunkGroupSize);
    h.put(bytes);
    return h.finishNonRoot() == expected ? ok!(OutboardError, NoGcHook)(true)
        : err!(bool, NoGcHook)(OutboardError.groupMismatch);
}

/**
A file identity that is the file's BLAKE3 digest, and that builds the file's
outboard as it hashes. The outboard of the last file named stays readable
until the next `start`.
*/
struct OutboardLeaf
{
    alias Id = ubyte[32]; ///

    private Blake3 group_;
    private ulong groups_, index_;
    private size_t fill_;
    private HeapBuffer!(ubyte[32]) cvs_;
    private HeapBuffer!ubyte outboard_;

    @disable this(this);

    ///
    void start(ulong size) @safe pure nothrow @nogc
    {
        groups_ = chunkGroups(size);
        index_ = 0;
        fill_ = 0;
        group_ = Blake3.init;
        cvs_.clear(false);
        outboard_.clear(false);
    }

    ///
    void put(scope const(ubyte)[] bytes) @safe pure nothrow @nogc
    {
        while (bytes.length)
        {
            const take = bytes.length < chunkGroupSize - fill_ ? bytes.length : chunkGroupSize - fill_;
            group_.put(bytes[0 .. take]);
            fill_ += take;
            bytes = bytes[take .. $];
            if (fill_ == chunkGroupSize && groups_ > 1)
                endGroup();
        }
    }

    ///
    Id finish() @safe pure nothrow @nogc
    {
        if (groups_ == 1)
            return group_.finish();
        if (fill_ > 0)
            endGroup();
        assert(cvs_.length == groups_, "the file was not the size it started with");
        outboard_.length = cast(size_t) ((groups_ - 1) * recordSize);
        size_t at;
        return merge(0, groups_, true, at);
    }

    /// The outboard of the file last named.
    const(ubyte)[] outboard() const @safe pure nothrow @nogc return => outboard_[];

    private void endGroup() @safe pure nothrow @nogc
    {
        cvs_.put(group_.finishNonRoot());
        index_ += 1;
        fill_ = 0;
        group_ = Blake3.init;
        group_.setInputOffset(index_ * chunkGroupSize);
    }

    // The value of the node over groups [lo, hi), writing its record and its
    // descendants' in pre-order from slot `at`.
    private ubyte[32] merge(ulong lo, ulong hi, bool root, ref size_t at) @safe pure nothrow @nogc
    {
        if (hi - lo == 1)
            return cvs_[cast(size_t) lo];
        const slot = at++;
        const mid = lo + leftGroups(hi - lo);
        const left = merge(lo, mid, false, at);
        const right = merge(mid, hi, false, at);
        auto record = outboard_[][slot * recordSize .. (slot + 1) * recordSize];
        record[0 .. 32] = left[];
        record[32 .. 64] = right[];
        return root ? blake3ParentRoot(left, right) : blake3ParentCv(left, right);
    }
}

/**
Reads a file through `File` (any handle with `read(scope ubyte[])`), one chunk
group at a time, surfacing a group's bytes only once they chain to the
supplied root (CAO2). A group that does not is refused whole.
*/
struct VerifiedReader(File)
{
    private File* file_;
    private SuppliedTree tree_;
    private ulong group_;
    private ubyte[chunkGroupSize] buffer_ = void;
    private size_t have_, taken_;

    @disable this(this);

    /// Reads `file` against `tree`, which has passed $(LREF check).
    this(return scope File* file, in SuppliedTree tree)
    {
        file_ = file;
        tree_ = tree;
    }

    /**
    Fills `dst` with the next verified bytes; returns how many, 0 at the end
    of the file. Refuses a group whose bytes do not chain to the root.
    */
    OutboardResult!size_t read(scope ubyte[] dst) scope
    {
        if (taken_ == have_)
        {
            if (group_ == chunkGroups(tree_.size))
                return ok!(OutboardError, NoGcHook)(size_t(0));
            const want = groupLength(tree_.size, group_);
            size_t got;
            while (got < want)
            {
                auto n = file_.read(buffer_[got .. want]);
                if (n.hasError)
                    return err!(size_t, NoGcHook)(OutboardError.readFailed);
                if (n.value == 0)
                    break;
                got += n.value;
            }
            if (got != want)
                return err!(size_t, NoGcHook)(OutboardError.shortGroup);
            auto v = verifyGroup(tree_, group_, buffer_[0 .. want]);
            if (v.hasError)
                return err!(size_t, NoGcHook)(v.error);
            group_ += 1;
            have_ = want;
            taken_ = 0;
        }
        size_t n = dst.length < have_ - taken_ ? dst.length : have_ - taken_;
        dst[0 .. n] = buffer_[taken_ .. taken_ + n];
        taken_ += n;
        return ok!(OutboardError, NoGcHook)(n);
    }
}

/**
A supply of trees for `MerkleFold` (`FSS8`, CAO1). `Store` finds the tree
supplied for a member, if any, through
`bool find(scope const(char)[] dir, scope const(char)[] name, out SuppliedTree)`,
where `dir` is the member's directory relative to the fileset root.
*/
struct OutboardSupply(Store)
{
    Store store; ///

    /**
    The id and size of the member `name` in `dir` from its supplied tree:
    `Supplied.none` when there is none, `Supplied.refused` when its tree
    fails $(LREF check).
    */
    Supplied supply(scope const(char)[] dir, scope const(char)[] name, out ubyte[32] id, out ulong size)
    {
        SuppliedTree tree;
        if (!store.find(dir, name, tree))
            return Supplied.none;
        if (check(tree).hasError)
            return Supplied.refused;
        id = tree.root;
        size = tree.size;
        return Supplied.taken;
    }
}

version (unittest)
{
    // Deterministic bytes, distinct in every group.
    private void fillPattern(scope ubyte[] bytes) @safe pure nothrow @nogc
    {
        foreach (i, ref b; bytes)
            b = cast(ubyte) ((i * 31 + (i >> 14) * 7) % 251);
    }

    // A file of bytes in memory, read in pieces of at most `piece`.
    private struct BytesFile
    {
        const(ubyte)[] bytes;
        size_t piece = 5000;

        Expected!(size_t, OutboardError, NoGcHook) read(scope ubyte[] dst) @safe pure nothrow @nogc
        {
            auto n = dst.length < bytes.length ? dst.length : bytes.length;
            if (n > piece)
                n = piece;
            dst[0 .. n] = bytes[0 .. n];
            bytes = bytes[n .. $];
            return ok!(OutboardError, NoGcHook)(n);
        }
    }

    private static immutable ulong[] sizes = [0, 1, 1024, chunkGroupSize, chunkGroupSize + 1,
        40_000, 3 * chunkGroupSize, 5 * chunkGroupSize + 7, 9 * chunkGroupSize - 1];
}

/// A file's root is its BLAKE3 digest, its outboard as long as its size
/// implies, and every chunk group of it checks against the two; fed in any
/// pieces, the leaf builds the same outboard.
@("content_addressing.outboard.leaf")
@safe nothrow @nogc unittest
{
    HeapBuffer!ubyte data;
    data.length = 9 * chunkGroupSize;
    fillPattern(data[]);
    OutboardLeaf whole, pieces;
    foreach (size; sizes)
    {
        const bytes = data[][0 .. cast(size_t) size];
        whole.start(size);
        whole.put(bytes);
        const root = whole.finish();
        assert(root == blake3(bytes));
        assert(whole.outboard.length == outboardSize(size));

        pieces.start(size);
        for (size_t at = 0; at < bytes.length; at += 3000)
            pieces.put(bytes[at .. at + 3000 < bytes.length ? at + 3000 : bytes.length]);
        assert(pieces.finish() == root && pieces.outboard == whole.outboard);

        const tree = SuppliedTree(root, size, whole.outboard);
        assert(!check(tree).hasError);
        foreach (g; 0 .. chunkGroups(size))
        {
            const at = cast(size_t) (g * chunkGroupSize);
            assert(!verifyGroup(tree, g, bytes[at .. at + groupLength(size, g)]).hasError);
        }
    }
}

/// A supplied tree that does not hold together is refused before any file is
/// read: a record flipped at the top, a truncated outboard. One flipped
/// lower down is caught when the groups beneath it are read.
@("content_addressing.outboard.check")
@safe nothrow @nogc unittest
{
    HeapBuffer!ubyte data;
    data.length = 5 * chunkGroupSize + 7;
    fillPattern(data[]);
    OutboardLeaf leaf;
    leaf.start(data.length);
    leaf.put(data[]);
    const root = leaf.finish();
    HeapBuffer!ubyte ob;
    ob.put(leaf.outboard);
    assert(ob.length == 5 * recordSize);

    assert(check(SuppliedTree(root, data.length, ob[][0 .. $ - 1])).error == OutboardError.wrongLength);
    assert(check(SuppliedTree(root, data.length + chunkGroupSize, ob[])).error
        == OutboardError.wrongLength);
    ob[3] ^= 1;
    assert(check(SuppliedTree(root, data.length, ob[])).error == OutboardError.rootMismatch);
    ob[3] ^= 1;

    // The record of groups 0 and 1 is the third in pre-order: the root's,
    // then the one over groups 0 to 3, then this one.
    ob[2 * recordSize + 40] ^= 1;
    const tree = SuppliedTree(root, data.length, ob[]);
    assert(!check(tree).hasError, "the top record is intact");
    assert(verifyGroup(tree, 1, data[][chunkGroupSize .. 2 * chunkGroupSize]).error
        == OutboardError.groupMismatch);
    assert(verifyGroup(tree, 0, data[][0 .. chunkGroupSize]).error == OutboardError.groupMismatch);
    assert(!verifyGroup(tree, 2, data[][2 * chunkGroupSize .. 3 * chunkGroupSize]).hasError);
    assert(!verifyGroup(tree, 5, data[][5 * chunkGroupSize .. $]).hasError);
}

/// CAO2: a reader surfaces a group only once it chains to the root. With one
/// byte of group 2 flipped, groups 0 and 1 are read whole, and then the read
/// fails without returning a byte of group 2.
@("content_addressing.outboard.CAO2.verifiedReader")
@safe nothrow @nogc unittest
{
    HeapBuffer!ubyte data, seen;
    data.length = 4 * chunkGroupSize + 100;
    fillPattern(data[]);
    OutboardLeaf leaf;
    leaf.start(data.length);
    leaf.put(data[]);
    const tree = SuppliedTree(leaf.finish(), data.length, leaf.outboard);

    // Reads everything `file` holds through a verifying reader into `seen`.
    OutboardResult!size_t readAll(ref BytesFile file) @safe nothrow @nogc
    {
        seen.clear(false);
        auto reader = VerifiedReader!BytesFile(&file, tree);
        ubyte[7000] buf;
        for (;;)
        {
            auto n = reader.read(buf[]);
            if (n.hasError || n.value == 0)
                return n;
            seen.put(buf[0 .. n.value]);
        }
    }

    auto intact = BytesFile(data[]);
    assert(!readAll(intact).hasError && seen[] == data[]);

    data[2 * chunkGroupSize + 9] ^= 0x40;
    auto flipped = BytesFile(data[]);
    assert(readAll(flipped).error == OutboardError.groupMismatch);
    assert(seen.length == 2 * chunkGroupSize, "no byte of the corrupt group is returned");
    assert(seen[] == data[][0 .. 2 * chunkGroupSize]);
    data[2 * chunkGroupSize + 9] ^= 0x40;

    auto truncated = BytesFile(data[][0 .. $ - 1]);
    assert(readAll(truncated).error == OutboardError.shortGroup);

    // An empty file, and one of a single group, check against the root alone.
    foreach (size; [0, 5000])
    {
        leaf.start(size);
        leaf.put(data[][0 .. size]);
        const small = SuppliedTree(leaf.finish(), size, leaf.outboard);
        auto file = BytesFile(data[][0 .. size]);
        auto reader = VerifiedReader!BytesFile(&file, small);
        ubyte[8000] buf;
        assert(reader.read(buf[]).value == size);
        assert(reader.read(buf[]).value == 0);
    }
}
