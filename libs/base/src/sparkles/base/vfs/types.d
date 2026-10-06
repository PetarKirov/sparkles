/**
The capability VFS's vocabulary: rights, the resolution policy, the sharing
of created entries, open modes, `Stat`, and the limits.

Specified in `docs/specs/base/vfs/SPEC.md`; each declaration names the
requirement it serves.
*/
module sparkles.base.vfs.types;

/**
The operations a handle permits (VFH4). Rights are part of a handle's type, so
an operation whose right is absent does not compile (VFH6), and a derived
handle can only have fewer (VFH5).
*/
enum Rights : ushort
{
    none = 0,                /// nothing
    lookup = 1 << 0,         /// open a child directory, walk a path
    list = 1 << 1,           /// list a directory
    stat = 1 << 2,           /// stat an entry, read a link's target
    read = 1 << 3,           /// read a file
    write = 1 << 4,          /// write a file
    create = 1 << 5,         /// create entries only their owner may access
    createShared = 1 << 6,   /// also create entries others may access (VFO5)
    remove = 1 << 7,         /// remove entries
    rename = 1 << 8,         /// rename entries

    /// look up, list, stat and read
    readOnly = lookup | list | stat | read,
    /// every right
    all = lookup | list | stat | read | write | create | createShared | remove | rename,
}

/// Whether `have` contains every member of `need`.
bool hasRights(Rights have, Rights need) @safe pure nothrow @nogc
    => (have & need) == need;

/**
Lists a rights value's members, for compile-time diagnostics: a combined value
prints as `lookup | list` rather than `cast(Rights)3u`.
*/
string rightsText(Rights r) @safe pure nothrow
{
    if (r == Rights.none)
        return "none";
    string text;
    // The single rights, named by the enum itself; a combination such as
    // `readOnly` names no right of its own.
    static foreach (member; __traits(allMembers, Rights))
    {{
        enum bit = __traits(getMember, Rights, member);
        static if (bit != 0 && (bit & (bit - 1)) == 0)
            if (r & bit)
                text ~= (text.length ? " | " : "") ~ member;
    }}
    return text;
}

///
@("vfs.types.rights")
@safe pure nothrow unittest
{
    static assert(Rights.readOnly == (Rights.lookup | Rights.list | Rights.stat | Rights.read));
    static assert(hasRights(Rights.all, Rights.readOnly));
    static assert(!hasRights(Rights.readOnly, Rights.remove));
    static assert(rightsText(Rights.readOnly) == "lookup | list | stat | read");
    static assert(rightsText(Rights.none) == "none");
    static assert(rightsText(Rights.all)
        == "lookup | list | stat | read | write | create | createShared | remove | rename");
}

/// How a walk treats a symbolic link (VFP4, VFP5).
enum SymlinkPolicy : ubyte
{
    none,    /// refuse every link
    beneath, /// follow links whose targets stay beneath the root
}

/// How a walk treats a `..` component (VFP6, VFP7).
enum DotDotPolicy : ubyte
{
    reject,  /// refuse it before any backend call
    inScope, /// return to the previously entered directory
}

/// A root's resolution policy, fixed when the root is opened (VFP1, VFP2).
struct ResolvePolicy
{
    SymlinkPolicy symlinks = SymlinkPolicy.none; ///
    DotDotPolicy dotDot = DotDotPolicy.reject;   ///
    bool crossMounts = false;                    ///
}

/// Which resolver serves a root (VFR2).
enum Resolution : ubyte
{
    componentWalk,   /// one entry at a time, by `sparkles.base.vfs.walk`
    kernelWholePath, /// the backend's whole-path resolver
}

/// How a root detects mount crossings (VFR2, VFP8).
enum MountCheck : ubyte
{
    none,   /// `crossMounts = true`: no check
    racy,   /// a device comparison after each open
    kernel, /// the kernel refuses the crossing
}

/// The sharing a root applies when a creating call names none (VFO5, VFH7).
enum CreateDefault : ubyte
{
    shared_,   /// the platform's ordinary sharing
    ownerOnly, /// only the creating user
}

/// Sharing argument: the platform's ordinary sharing, less the umask (VFO5).
struct Shared {}

/// Sharing argument: only the creating user may access the entry (VFO5).
struct OwnerOnly {}

version (Posix)
{
    /// Sharing argument: exactly these mode bits, less the umask (VFO5).
    struct PosixMode
    {
        uint bits; ///
    }
}

/// The runtime form of a sharing argument, as a backend receives it.
struct Sharing
{
    /// Which argument produced it.
    enum Kind : ubyte
    {
        shared_,   ///
        ownerOnly, ///
        posixMode, ///
    }

    Kind kind;      ///
    uint posixBits; /// valid for `posixMode`

    /// The mode bits this sharing requests before the umask (VFO5).
    uint modeBits(bool directory, bool executable) const @safe pure nothrow @nogc
    {
        final switch (kind)
        {
            case Kind.shared_:
                return directory || executable ? octal777 : octal666;
            case Kind.ownerOnly:
                return directory || executable ? octal700 : octal600;
            case Kind.posixMode:
                return posixBits;
        }
    }
}

private enum uint octal777 = 511, octal666 = 438, octal700 = 448, octal600 = 384;

/// The runtime form of each sharing argument.
Sharing sharingOf(Shared) @safe pure nothrow @nogc => Sharing(Sharing.Kind.shared_);
/// ditto
Sharing sharingOf(OwnerOnly) @safe pure nothrow @nogc => Sharing(Sharing.Kind.ownerOnly);
version (Posix)
{
    /// ditto
    Sharing sharingOf(PosixMode m) @safe pure nothrow @nogc
        => Sharing(Sharing.Kind.posixMode, m.bits);
}
/// ditto: a root's default.
Sharing sharingOf(CreateDefault d) @safe pure nothrow @nogc
    => d == CreateDefault.ownerOnly ? Sharing(Sharing.Kind.ownerOnly) : Sharing(Sharing.Kind.shared_);

/// Whether `S` is one of the sharing argument types.
enum isSharingArgument(S) = is(S == Shared) || is(S == OwnerOnly) || isPosixMode!S;

/// Whether `S` grants access beyond the owner, and so needs `createShared`.
enum needsCreateShared(S) = is(S == Shared) || isPosixMode!S;

version (Posix)
    private enum isPosixMode(S) = is(S == PosixMode);
else
    private enum isPosixMode(S) = false;

///
@("vfs.types.sharing")
@safe pure nothrow @nogc unittest
{
    assert(sharingOf(Shared()).modeBits(false, false) == octal666);
    assert(sharingOf(Shared()).modeBits(true, false) == octal777);
    assert(sharingOf(OwnerOnly()).modeBits(false, false) == octal600);
    assert(sharingOf(OwnerOnly()).modeBits(false, true) == octal700);
    version (Posix)
        assert(sharingOf(PosixMode(420)).modeBits(false, false) == 420);
    static assert(needsCreateShared!Shared && !needsCreateShared!OwnerOnly);
    assert(sharingOf(CreateDefault.ownerOnly).kind == Sharing.Kind.ownerOnly);
}

/// Data access of an open file (VFO4).
enum Access : ubyte
{
    read,      ///
    write,     ///
    readWrite, ///
    append,    ///
}

/// What `openFile` does about an existing or missing entry (VFO4).
enum Disposition : ubyte
{
    existing,         /// fail with `notFound` if absent
    createNew,        /// fail with `exists` if present
    createOrTruncate, /// create, or empty an existing file
}

/**
An open mode (VFO4). It is a template argument of `openFile`, so the rights
it needs are checked at compile time.
*/
struct OpenMode
{
    Access access;                                ///
    Disposition disposition = Disposition.existing; ///
    bool executable;                              /// only for a creating mode

    /// Common modes.
    enum read = OpenMode(Access.read);
    /// ditto
    enum write = OpenMode(Access.write);
    /// ditto
    enum readWrite = OpenMode(Access.readWrite);
    /// ditto
    enum append = OpenMode(Access.append);
    /// ditto
    enum createNew = OpenMode(Access.write, Disposition.createNew);
    /// ditto
    enum createOrTruncate = OpenMode(Access.write, Disposition.createOrTruncate);

    /// Whether this mode may create the file.
    bool creates() const @safe pure nothrow @nogc => disposition != Disposition.existing;

    /// The rights this mode needs.
    Rights rights() const @safe pure nothrow @nogc
    {
        Rights r;
        final switch (access)
        {
            case Access.read: r = Rights.read; break;
            case Access.write: r = Rights.write; break;
            case Access.readWrite: r = cast(Rights)(Rights.read | Rights.write); break;
            case Access.append: r = Rights.write; break;
        }
        return creates ? cast(Rights)(r | Rights.create) : r;
    }
}

///
@("vfs.types.openMode")
@safe pure nothrow @nogc unittest
{
    static assert(OpenMode.read.rights == Rights.read);
    static assert(OpenMode.createNew.rights == (Rights.write | Rights.create));
    static assert(!OpenMode.append.creates);
}

/// The kind of a directory entry (VFO6, VFO7).
enum EntryKind : ubyte
{
    unknown,   /// a listing could not tell cheaply
    regular,   ///
    directory, ///
    symlink,   ///
    other,     ///
}

/// What a stat fills beyond the always-present fields (VFO6).
enum StatMask : ubyte
{
    basic = 0,     /// kind, executable bit, size, device
    mtime = 1 << 0, /// also the modification time
}

/// The metadata of one entry, never of a link's target (VFO6).
struct Stat
{
    EntryKind kind;   ///
    bool executable;  /// always false on Windows
    ulong size;       ///
    ulong device;     /// the file system holding the entry
    bool hasMtime;    /// whether `mtimeNs` was requested and filled
    long mtimeNs;     /// nanoseconds since the Unix epoch
    version (Posix)
        uint permissions; /// the mode's permission bits
}

/// One listing entry. `name` is a slice of the caller's buffer, valid until
/// the listing advances (VFO7).
struct DirEntry
{
    const(char)[] name; ///
    EntryKind kind;     /// may be `unknown`
}

/// The limits of SPEC.md §11.
enum size_t maxNameLength = 255;
/// ditto: entered directories, shared with the `..` handle stack
enum size_t maxWalkDepth = 64;
/// ditto
enum size_t maxRemovalDepth = 64;
/// ditto
enum size_t maxSymlinkHops = 40;
/// ditto: the remaining path of a walk after splicing link targets into it
enum size_t maxSplicedPathLength = 4096;
/// ditto
enum size_t raceRetries = 128;
/// ditto
enum size_t windowsDeleteRetries = 50;
