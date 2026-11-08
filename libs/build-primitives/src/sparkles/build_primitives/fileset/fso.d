/**
The file-system object vocabulary (FSO1–FSO4), and what a scheme declares
about the entries it consumes (FSS1–FSS3).

Shared with the content-addressing contract and deliberately minimal: a node
is a regular file, a directory or a symbolic link, and nothing else is
representable. A regular file carries one boolean, its executable bit; a link
carries its target as opaque bytes, never followed. Ownership, the other
permission bits, timestamps, link counts and extended attributes are not
part of a node (FSO3). A scheme that wants a modification time declares it
(`FsoMetadata.mtime`) and receives it beside the node, not inside it.

The module depends on nothing, so it can move to `sparkles:base` unchanged
when a consumer that cannot depend on this package appears (decision A2).
*/
module sparkles.build_primitives.fileset.fso;

@safe pure nothrow @nogc:

/// The three node kinds (FSO1).
enum FsoKind : ubyte
{
    regular,   ///
    directory, ///
    symlink,   ///
}

/**
One node (FSO1). Made only by `regular`, `directory` and `symlink`, so no
other shape — an executable directory, a link with no target — can be
constructed outside this module. A link's target borrows from the caller.
*/
struct FsoNode
{
@safe pure nothrow @nogc:

    private FsoKind kind_;
    private bool executable_;
    private const(char)[] target_;

    /// A regular file.
    static FsoNode regular(bool executable) => FsoNode(FsoKind.regular, executable, null);

    /// A directory.
    static FsoNode directory() => FsoNode(FsoKind.directory, false, null);

    /// A symbolic link to `target`, bytes the node never interprets (FSO2).
    static FsoNode symlink(return scope const(char)[] target)
        => FsoNode(FsoKind.symlink, false, target);

    /// The node's kind.
    FsoKind kind() const => kind_;

    /// Whether a regular file is executable; `false` for every other kind.
    bool executable() const => executable_;

    /// A link's target; `null` for every other kind.
    const(char)[] target() const return => target_;
}

///
@("fileset.fso.FSO1.nodes")
unittest
{
    import std.traits : EnumMembers;

    static assert([EnumMembers!FsoKind].length == 3);
    const f = FsoNode.regular(true), d = FsoNode.directory(), l = FsoNode.symlink("../x");
    assert(f.kind == FsoKind.regular && f.executable && f.target is null);
    assert(d.kind == FsoKind.directory && !d.executable);
    assert(l.kind == FsoKind.symlink && !l.executable && l.target == "../x");
}

/**
The metadata a scheme declares it needs (FSS2), as a mask. Only what is
declared is requested (FSO4): a scheme declaring `none` causes no `stat`,
and no `readlink`, on its own account.
*/
enum FsoMetadata : ubyte
{
    none = 0,           ///
    executable = 1 << 0, /// a member file's executable bit
    mtime = 1 << 1,     /// a member file's or link's modification time
    linkTarget = 1 << 2, /// a member link's target
}

/// The entry ordering a scheme declares (FSS1).
enum EntryOrder : ubyte
{
    /// Any order. A fold scheme may not declare it (FSS5).
    none,
    /// By name, byte for byte, as NAR serializes a directory.
    narOrder,
    /// By name, a directory's name compared as if it ended in `/`, as git
    /// sorts a tree.
    gitTreeOrder,
    /// Directories, then regular files, then links, each by name, as
    /// REAPI's and Snix's directory messages keep three sorted lists.
    partitionedOrder,
}

/// Whether a scheme sees a directory before its children or after them
/// (FSS3).
enum Traversal : ubyte
{
    /// Pre-order, side-effecting into the scheme: a directory is handed
    /// over before any of its subdirectories.
    stream,
    /// Post-order: a directory is handed over with its children's values,
    /// after every one of them.
    fold,
}

/// Everything a scheme declares about how it consumes a resolution
/// (FSS1–FSS3). The default is what a path collector needs: any order, no
/// metadata, a stream.
struct SchemeShape
{
    EntryOrder order;      ///
    FsoMetadata metadata;  ///
    Traversal traversal;   ///
    /// A stream hears when a directory and everything beneath it are done
    /// (`StepKind.leave`); a serial format needs it (A19).
    bool leave;
}

/**
Whether the entry `a` of kind `ka` comes before `b` of kind `kb` in `order`.
Names are distinct within a directory, so this is a strict total order on
one directory's entries; `none` orders them by bytes.
*/
bool precedes(EntryOrder order, scope const(char)[] a, FsoKind ka, scope const(char)[] b, FsoKind kb)
{
    final switch (order)
    {
        case EntryOrder.none:
        case EntryOrder.narOrder:
            return a < b;
        case EntryOrder.gitTreeOrder:
            return gitCompare(a, ka == FsoKind.directory, b, kb == FsoKind.directory) < 0;
        case EntryOrder.partitionedOrder:
            const ra = partition(ka), rb = partition(kb);
            return ra != rb ? ra < rb : a < b;
    }
}

/// FSS1: `a` (a directory) and `a.b` tell `narOrder` from `gitTreeOrder`.
@("fileset.fso.FSS1.precedes")
unittest
{
    alias D = FsoKind.directory, F = FsoKind.regular, L = FsoKind.symlink;
    assert(precedes(EntryOrder.narOrder, "a", D, "a.b", F));
    assert(precedes(EntryOrder.gitTreeOrder, "a.b", F, "a", D));
    assert(!precedes(EntryOrder.gitTreeOrder, "a", D, "a.b", F));
    // A file `a` sorts as `a`, before `a.b`, in git's order too.
    assert(precedes(EntryOrder.gitTreeOrder, "a", F, "a.b", F));
    // `a/` against `a/b`'s first segment never arises; `ab` against `a/`:
    assert(precedes(EntryOrder.gitTreeOrder, "a", D, "ab", F));
    assert(precedes(EntryOrder.partitionedOrder, "z", D, "a", F));
    assert(precedes(EntryOrder.partitionedOrder, "z", F, "a", L));
    assert(precedes(EntryOrder.partitionedOrder, "a", L, "b", L));
}

private int gitCompare(scope const(char)[] a, bool aDir, scope const(char)[] b, bool bDir)
{
    const n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    // One is a prefix of the other: the next byte is the shorter one's
    // virtual `/`, or nothing.
    const ca = a.length > n ? a[n] : aDir ? '/' : 0;
    const cb = b.length > n ? b[n] : bDir ? '/' : 0;
    return ca == cb ? 0 : ca < cb ? -1 : 1;
}

private int partition(FsoKind k) => k == FsoKind.directory ? 0 : k == FsoKind.regular ? 1 : 2;
