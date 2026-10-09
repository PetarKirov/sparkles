/**
Directory capabilities: `Dir`, `File`, their borrows, and `openRoot`
(VFH1–VFH8, VFO1–VFO10).

A `Dir!(V, R)` is an open directory on backend `V` with rights `R`. Every
operation names one entry relative to it, or, for `walk` and `walkAll`, a path
resolved from it under the root's policy. Rights are checked at compile time:
an operation whose right is absent fails a `static assert` that names the
right (VFH6). Lexical refusals happen before any backend call.

`openRoot` is the only function that resolves a path from the process root;
it requires an `AmbientAuthority`, which only `ambientAuthority()` makes, so
every such call can be found by searching for that name (VFH7).
*/
module sparkles.base.vfs.handles;

import core.atomic : atomicOp;
import core.lifetime : move;
import std.traits : isInstanceOf;

import sparkles.base.io.errors : ErrorKind, IoError, IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.base.vfs.concept : hasWholePathResolver, isVfs, mountCheckOf, resolverWithdrawn;
import sparkles.base.vfs.names : checkLinkTarget, checkName, lexicalError;
import sparkles.base.vfs.remove : removeTreeAt;
import sparkles.base.vfs.types;
import sparkles.base.vfs.walk : walkFrom;
import sparkles.base.vfs.write : writeFileAtomicAt;

/**
The token `openRoot` requires (VFH7). Only `ambientAuthority()` makes one, so
searching for that name finds every place that creates authority from a path.
*/
struct AmbientAuthority
{
    private bool _granted;

    /// Whether this token came from `ambientAuthority()`, which an API that
    /// takes one checks in its contract. A default-initialized token is not.
    bool granted() const @safe pure nothrow @nogc => _granted;
}

/// ditto
AmbientAuthority ambientAuthority() @safe pure nothrow @nogc => AmbientAuthority(true);

/// What every handle derived from one root shares (VFP2, VFR2).
struct RootInfo
{
    ResolvePolicy policy;       ///
    Resolution resolution;      ///
    MountCheck mountCheck;      ///
    CreateDefault createDefault; ///
    bool requireKernel;         ///
    ulong id;                   /// distinguishes roots for VFO8
}

private shared ulong nextRootId;

/// The state a `Dir` owns and its borrows point at.
struct DirCore(V)
{
    package V* vfs;
    package V.Handle handle;
    package RootInfo root;
    package bool open;
}

/**
Opens the directory `path` as a root with rights `R` (VFH7). The only
operation that resolves a path from the process root or current directory,
and the only one that follows symbolic links in the path it is given.
*/
IoResult!(Dir!(V, R)) openRoot(Rights R, V)(V* vfs, scope const(char)[] path,
    AmbientAuthority authority, ResolvePolicy policy = ResolvePolicy.init,
    CreateDefault create = CreateDefault.shared_, bool requireKernel = false)
if (isVfs!V)
in (authority.granted, "AmbientAuthority must come from ambientAuthority()")
{
    RootInfo info;
    info.policy = policy;
    info.createDefault = create;
    info.requireKernel = requireKernel;
    info.mountCheck = mountCheckOf(*vfs, policy);
    info.id = atomicOp!"+="(nextRootId, 1);
    static if (hasWholePathResolver!V)
        info.resolution = vfs.wholePathFor(policy)
            ? Resolution.kernelWholePath : Resolution.componentWalk;
    else
        info.resolution = Resolution.componentWalk;
    if (requireKernel && info.resolution != Resolution.kernelWholePath)
        return ioErr!(Dir!(V, R))(ErrorKind.unsupported, OpKind.resolve, 0,
            IoError.init.stage, "the kernel resolver is unavailable for this policy");

    auto h = vfs.openRootDir(path);
    if (h.hasError)
        return ioErr!(Dir!(V, R))(h);
    return ioOk(Dir!(V, R)(DirCore!V(vfs, h.value, info, true)));
}

/// An owning, move-only directory capability (VFH1).
struct Dir(V, Rights R)
if (isVfs!V)
{
    /// The backend this handle belongs to (VFH3).
    alias Backend = V;

    package DirCore!V core;

    @disable this(this);

    package this(DirCore!V core) @safe pure nothrow @nogc
    {
        this.core = core;
    }

    ~this()
    {
        if (core.open)
        {
            core.open = false;
            core.vfs.close(core.handle); // VFH1: a close failure here is dropped
        }
    }

    /// Closes the handle, returning any failure. The destructor then does nothing.
    IoResult!void close()
    {
        if (!core.open)
            return ioOk();
        core.open = false;
        return core.vfs.close(core.handle);
    }

    /// A borrow with the same rights (VFH2).
    DirRef!(V, R) borrow() return => DirRef!(V, R)(&core);

    /// A borrow with fewer rights (VFH5).
    DirRef!(V, R2) attenuate(Rights R2)() return
    {
        static assert(hasRights(R, R2), "attenuate cannot widen rights: this handle has "
            ~ rightsText(R) ~ ", and " ~ rightsText(R2) ~ " is not a subset");
        return DirRef!(V, R2)(&core);
    }

    /// Whether this is an open handle rather than an empty `.init`.
    bool alive() const scope => core.open;

    private ref inout(DirCore!V) self() inout return => core;

    mixin DirOperations!(V, R);
}

/// A borrowed directory capability: the owner's operations, no `close`, and
/// under `-preview=dip1000` it cannot outlive its owner (VFH2).
struct DirRef(V, Rights R)
if (isVfs!V)
{
    /// The backend this handle belongs to (VFH3).
    alias Backend = V;

    private DirCore!V* core;

    /// A borrow with fewer rights (VFH5).
    DirRef!(V, R2) attenuate(Rights R2)() return scope
    {
        static assert(hasRights(R, R2), "attenuate cannot widen rights: this handle has "
            ~ rightsText(R) ~ ", and " ~ rightsText(R2) ~ " is not a subset");
        return DirRef!(V, R2)(core);
    }

    /// Whether this borrows an open handle rather than being an empty `.init`.
    bool alive() const scope => core !is null && core.open;

    private ref inout(DirCore!V) self() inout return scope => *core;

    mixin DirOperations!(V, R);
}

/// The operations of `Dir` and `DirRef`, written once.
mixin template DirOperations(V, Rights R)
{
    import sparkles.base.vfs.types : rightsText;

    private static void need(Rights r, string op)()
    {
        static assert(hasRights(R, r), op ~ " needs " ~ rightsText(r)
            ~ "; this handle has " ~ rightsText(R));
    }

    private Sharing sharingFor(S...)() scope
    {
        static assert(S.length <= 1, "at most one sharing argument");
        static if (S.length == 1)
        {
            static assert(isSharingArgument!(S[0]), S[0].stringof ~ " is not a sharing argument");
            static assert(!needsCreateShared!(S[0]) || hasRights(R, Rights.createShared),
                "creating a " ~ S[0].stringof ~ " entry needs createShared; this handle has "
                ~ rightsText(R));
            return Sharing.init; // replaced by the caller with sharingOf(arg)
        }
        else
            return hasRights(R, Rights.createShared)
                ? sharingOf(self.root.createDefault) : sharingOf(CreateDefault.ownerOnly);
    }

    private Sharing resolveSharing(S...)(S sharing) scope
    {
        static if (S.length == 1)
        {
            cast(void) sharingFor!S();
            return sharingOf(sharing[0]);
        }
        else
            return sharingFor!()();
    }

    private static IoResult!T emptyHandle(T)()
        => ioErr!T(ErrorKind.other, OpKind.none, 9, IoErrorStage.completion, "empty handle");

    /// The backend's handle, for backend tests and interoperation with code
    /// that takes a raw descriptor. Using it bypasses rights and policy.
    V.Handle backendHandle() const scope => self.handle;

    /// The root's policy (VFP2), resolver and mount check (VFR2).
    ResolvePolicy policy() const scope => self.root.policy;
    /// ditto
    Resolution resolution() scope
        => self.root.resolution == Resolution.kernelWholePath && !resolverWithdrawn(*self.vfs)
            ? Resolution.kernelWholePath : Resolution.componentWalk;
    /// ditto
    MountCheck mountCheck() const scope => self.root.mountCheck;

    /// Opens the directory `name` (VFO3).
    IoResult!(Dir!(V, R)) openDir()(scope const(char)[] name) scope
    {
        need!(Rights.lookup, "openDir");
        if (!alive)
            return emptyHandle!(Dir!(V, R))();
        const k = checkName(name);
        if (k != ErrorKind.other)
            return ioErr!(Dir!(V, R))(lexicalError(k, OpKind.openAt));
        auto h = self.vfs.openDirAt(self.handle, name);
        if (h.hasError)
            return ioErr!(Dir!(V, R))(h);
        return ioOk(Dir!(V, R)(DirCore!V(self.vfs, h.value, self.root, true)));
    }

    /// Opens or creates the file `name` (VFO3, VFO4, VFO5).
    IoResult!(File!(V, fileRights(R, mode))) openFile(OpenMode mode, S...)(
        scope const(char)[] name, S sharing) scope
    {
        alias F = File!(V, fileRights(R, mode));
        static assert(hasRights(R, mode.rights), "openFile with this mode needs "
            ~ rightsText(mode.rights) ~ "; this handle has " ~ rightsText(R));
        if (!alive)
            return emptyHandle!F();
        static if (S.length)
        {
            static assert(mode.creates, "a sharing argument needs a creating mode");
            version (Posix)
                static assert(!(is(S[0] == PosixMode) && mode.executable),
                    "PosixMode already states the bits; do not combine it with executable");
        }
        const k = checkName(name);
        if (k != ErrorKind.other)
            return ioErr!F(lexicalError(k, OpKind.openAt));
        auto h = self.vfs.openFileAt(self.handle, name, mode, resolveSharing(sharing));
        if (h.hasError)
            return ioErr!F(h);
        return ioOk(F(self.vfs, h.value));
    }

    /// Creates the directory `name` (VFO3, VFO5).
    IoResult!void mkdirAt(S...)(scope const(char)[] name, S sharing) scope
    {
        need!(Rights.create, "mkdirAt");
        if (!alive)
            return emptyHandle!(void)();
        const k = checkName(name);
        if (k != ErrorKind.other)
            return ioErr!void(lexicalError(k, OpKind.mkdirAt));
        return self.vfs.mkdirAt(self.handle, name, resolveSharing(sharing));
    }

    /// Stats the entry `name` itself (VFO2, VFO6).
    IoResult!Stat statAt()(scope const(char)[] name, StatMask mask = StatMask.basic) scope
    {
        need!(Rights.stat, "statAt");
        if (!alive)
            return emptyHandle!(Stat)();
        const k = checkName(name);
        if (k != ErrorKind.other)
            return ioErr!Stat(lexicalError(k, OpKind.statAt));
        return self.vfs.statAt(self.handle, name, mask);
    }

    /// Reads the target of the link `name` into `buffer` and returns the
    /// filled part of it (VFO3).
    IoResult!(char[]) readlinkAt()(scope const(char)[] name, return scope char[] buffer) scope
    {
        need!(Rights.stat, "readlinkAt");
        if (!alive)
            return emptyHandle!(char[])();
        const k = checkName(name);
        if (k != ErrorKind.other)
            return ioErr!(char[])(lexicalError(k, OpKind.readlinkAt));
        auto n = self.vfs.readlinkAt(self.handle, name, buffer);
        if (n.hasError)
            return ioErr!(char[])(n);
        return ioOk(buffer[0 .. n.value]);
    }

    /// Creates the link `name` to a relative `target` (VFO3, VFO10).
    IoResult!void symlinkAt()(scope const(char)[] name, scope const(char)[] target) scope
    {
        need!(Rights.create, "symlinkAt");
        if (!alive)
            return emptyHandle!(void)();
        auto k = checkName(name);
        if (k == ErrorKind.other)
            k = checkLinkTarget(target);
        if (k != ErrorKind.other)
            return ioErr!void(lexicalError(k, OpKind.symlinkAt));
        return self.vfs.symlinkAt(self.handle, name, target);
    }

    /// Removes the non-directory `name` (VFO3).
    IoResult!void unlinkAt()(scope const(char)[] name) scope
    {
        need!(Rights.remove, "unlinkAt");
        if (!alive)
            return emptyHandle!(void)();
        const k = checkName(name);
        if (k != ErrorKind.other)
            return ioErr!void(lexicalError(k, OpKind.unlinkAt));
        return self.vfs.unlinkAt(self.handle, name);
    }

    /// Removes the empty directory `name` (VFO3).
    IoResult!void rmdirAt()(scope const(char)[] name) scope
    {
        need!(Rights.remove, "rmdirAt");
        if (!alive)
            return emptyHandle!(void)();
        const k = checkName(name);
        if (k != ErrorKind.other)
            return ioErr!void(lexicalError(k, OpKind.rmdirAt));
        return self.vfs.rmdirAt(self.handle, name);
    }

    /// Renames `name` to `dstName` in `dst`, which must belong to the same
    /// root (VFO3, VFO8).
    IoResult!void renameAt(D)(scope const(char)[] name, ref D dst,
        scope const(char)[] dstName) scope
    // `is(D == Dir!(V, R2), Rights R2)` alone would also match a backend with an
    // `alias this` to `V`; the exact type of `D.Backend` is what VFH3 needs.
    if ((isInstanceOf!(.Dir, D) || isInstanceOf!(.DirRef, D)) && is(D.Backend == V))
    {
        need!(Rights.rename, "renameAt");
        if (!alive)
            return emptyHandle!(void)();
        static assert(hasRights(D.rights, Rights.rename),
            "renameAt needs rename on the destination too; it has " ~ rightsText(D.rights));
        auto k = checkName(name);
        if (k == ErrorKind.other)
            k = checkName(dstName);
        if (k != ErrorKind.other)
            return ioErr!void(lexicalError(k, OpKind.renameAt));
        if (!dst.alive)
            return emptyHandle!void();
        if (dst.self.root.id != self.root.id)
            return ioErr!void(lexicalError(ErrorKind.escapesRoot, OpKind.renameAt));
        return self.vfs.renameAt(self.handle, name, dst.self.handle, dstName);
    }

    /// Lists this directory (VFO7).
    IoResult!(Listing!V) list()() scope
    {
        need!(Rights.list, "list");
        if (!alive)
            return emptyHandle!(Listing!V)();
        auto l = self.vfs.openListing(self.handle);
        if (l.hasError)
            return ioErr!(Listing!V)(l);
        // The backend pointer is the one the caller gave `openRoot`, which every
        // handle of the root holds; a listing holds it on the same terms.
        return (() @trusted => ioOk(Listing!V(cast(V*) self.vfs, l.value)))();
    }

    /// A `Dir` for the directory `path` names, under the root's policy (VFP).
    IoResult!(Dir!(V, R)) walk()(scope const(char)[] path) scope
    {
        need!(Rights.lookup, "walk");
        if (!alive)
            return emptyHandle!(Dir!(V, R))();
        auto h = walkFrom(*self.vfs, self.handle, path, self.root.policy,
            self.root.resolution, false, Sharing.init, self.root.requireKernel);
        if (h.hasError)
            return ioErr!(Dir!(V, R))(h);
        return ioOk(Dir!(V, R)(DirCore!V(self.vfs, h.value, self.root, true)));
    }

    /// As `walk`, creating missing directories (VFO3, VFO5).
    IoResult!(Dir!(V, R)) walkAll(S...)(scope const(char)[] path, S sharing) scope
    {
        need!(cast(Rights)(Rights.lookup | Rights.create), "walkAll");
        if (!alive)
            return emptyHandle!(Dir!(V, R))();
        auto h = walkFrom(*self.vfs, self.handle, path, self.root.policy,
            self.root.resolution, true, resolveSharing(sharing), self.root.requireKernel);
        if (h.hasError)
            return ioErr!(Dir!(V, R))(h);
        return ioOk(Dir!(V, R)(DirCore!V(self.vfs, h.value, self.root, true)));
    }

    /// Removes `name` and everything beneath it (VFD).
    IoResult!void removeTree()(scope const(char)[] name) scope
    {
        need!(cast(Rights)(Rights.lookup | Rights.list | Rights.remove), "removeTree");
        if (!alive)
            return emptyHandle!(void)();
        const k = checkName(name);
        if (k != ErrorKind.other)
            return ioErr!void(lexicalError(k, OpKind.unlinkAt));
        return removeTreeAt(*self.vfs, self.handle, name, self.root.policy.crossMounts);
    }

    /// Replaces the contents of `name` atomically (VFO9).
    IoResult!void writeFileAtomic(S...)(scope const(char)[] name,
        scope const(ubyte)[] bytes, S sharing) scope
    {
        need!(cast(Rights)(Rights.create | Rights.write | Rights.rename), "writeFileAtomic");
        if (!alive)
            return emptyHandle!(void)();
        const k = checkName(name);
        if (k != ErrorKind.other)
            return ioErr!void(lexicalError(k, OpKind.openAt));
        return writeFileAtomicAt(*self.vfs, self.handle, name, bytes,
            resolveSharing(sharing), false);
    }

    /// ditto, from text.
    IoResult!void writeFileAtomic(S...)(scope const(char)[] name,
        scope const(char)[] text, S sharing) scope
        => writeFileAtomic(name, cast(const(ubyte)[]) text, sharing);

    /// The rights of this handle's type.
    enum Rights rights = R;
}

/// The rights a file opened with `mode` from a directory with rights `R` has.
Rights fileRights(Rights R, OpenMode mode) @safe pure nothrow @nogc
{
    Rights r = cast(Rights)(mode.rights & (Rights.read | Rights.write));
    return cast(Rights)(r | (R & Rights.stat));
}

/// The longest entry name a listing holds: 255 bytes on POSIX, and 255 UTF-16
/// code units on Windows, which is at most 765 bytes of UTF-8.
enum size_t maxListedNameBytes = 1024;

/// A listing in progress (VFO7): `next` advances, `front` is valid until the
/// next advance. It owns its name buffer, so it borrows nothing from the
/// caller, and it closes itself when destroyed.
struct Listing(V)
{
    private V* vfs;
    private V.Listing state;
    private char[maxListedNameBytes] names;
    private size_t nameLength;
    private EntryKind kind;
    private bool open;

    @disable this(this);

    private this(V* vfs, V.Listing state)
    {
        this.vfs = vfs;
        this.state = state;
        open = true;
    }

    ~this()
    {
        if (open)
        {
            open = false;
            vfs.closeListing(state);
        }
    }

    /// Advances to the next entry; `false` at the end.
    IoResult!bool next() scope
    {
        if (!open)
            return ioErr!bool(ErrorKind.other, OpKind.readDir, 9, IoErrorStage.completion,
                "empty handle");
        return vfs.nextEntry(state, names[], nameLength, kind);
    }

    /// The current entry; its name is valid until the next advance.
    DirEntry front() return => DirEntry(names[0 .. nameLength], kind);
}

/// An owning, move-only open file (VFH1, VFO3).
struct File(V, Rights R)
if (isVfs!V)
{
    private V* vfs;
    private V.Handle handle;
    private bool open;

    @disable this(this);

    package this(V* vfs, V.Handle handle)
    {
        this.vfs = vfs;
        this.handle = handle;
        open = true;
    }

    ~this()
    {
        if (open)
        {
            open = false;
            vfs.close(handle);
        }
    }

    /// Closes the file, returning any failure.
    IoResult!void close()
    {
        if (!open)
            return ioOk();
        open = false;
        return vfs.close(handle);
    }

    /// Reads into `buffer`; returns the number of bytes read, 0 at the end.
    IoResult!size_t read()(scope ubyte[] buffer) scope
    {
        static assert(hasRights(R, Rights.read), "read needs a file opened for reading");
        if (!open)
            return ioErr!(size_t)(ErrorKind.other, OpKind.none, 9,
                IoErrorStage.completion, "empty handle");
        return vfs.read(handle, buffer);
    }

    /// Writes `bytes`; returns the number written.
    IoResult!size_t write()(scope const(ubyte)[] bytes) scope
    {
        static assert(hasRights(R, Rights.write), "write needs a file opened for writing");
        if (!open)
            return ioErr!(size_t)(ErrorKind.other, OpKind.none, 9,
                IoErrorStage.completion, "empty handle");
        return vfs.write(handle, bytes);
    }

    /// Stats the open file (VFO6).
    IoResult!Stat stat()(StatMask mask = StatMask.basic) scope
    {
        static assert(hasRights(R, Rights.stat), "stat needs the stat right");
        if (!open)
            return ioErr!(Stat)(ErrorKind.other, OpKind.none, 9,
                IoErrorStage.completion, "empty handle");
        return vfs.fstat(handle, mask);
    }

    /// Flushes the file to stable storage.
    IoResult!void sync()() scope
    {
        static assert(hasRights(R, Rights.write), "sync needs a file opened for writing");
        if (!open)
            return ioErr!(void)(ErrorKind.other, OpKind.none, 9,
                IoErrorStage.completion, "empty handle");
        return vfs.sync(handle);
    }

    /// Lends the operating-system descriptor, where the backend has one, so
    /// the event loop's I/O verbs can use this file. The borrow must not
    /// outlive the `File`. It also bypasses this type's compile-time rights;
    /// the operating system still enforces the access the file was opened
    /// with.
    static if (__traits(hasMember, V, "borrowFd"))
        auto borrowFd() scope => vfs.borrowFd(handle);

    /// The rights of this handle's type.
    enum Rights rights = R;
}

/// The contract at a glance (SPEC.md §2), on the in-memory backend.
@("vfs.handles.glance")
@safe unittest
{
    import sparkles.base.vfs.mem : testVfs;

    auto vfs = testVfs();
    vfs.mkdirs("out");

    auto root = openRoot!(Rights.all)(vfs, "out", ambientAuthority());
    assert(!root.hasError);

    auto dir = root.value.walkAll("reports/latest");
    assert(!dir.hasError);
    assert(!dir.value.writeFileAtomic("summary.txt", "hello", OwnerOnly()).hasError);
    assert(vfs.contents("out/reports/latest/summary.txt") == "hello");
    assert(vfs.sharingOf("out/reports/latest/summary.txt").kind == Sharing.Kind.ownerOnly);

    auto view = dir.value.attenuate!(Rights.readOnly);
    static assert(!__traits(compiles, view.removeTree("x")));
    auto file = view.openFile!(OpenMode.read)("summary.txt");
    ubyte[8] buf;
    assert(file.value.read(buf[]).value == 5);
    assert(buf[0 .. 5] == "hello");
}
