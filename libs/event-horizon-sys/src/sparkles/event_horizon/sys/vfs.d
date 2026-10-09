/**
`BlockingVfs`: the capability VFS's blocking backend (VFB4), one blocking
system call per primitive, relative to the parent handle.

On POSIX the primitives are the `*at` family, never following the named entry
(VFN9). Directories a walk passes through are opened for search only where
the platform can (VFN14). Linux resolves whole paths with `openat2(2)` and
macOS with `O_NOFOLLOW_ANY` where the policy allows (VFN5); each probe's
absence is cached for the process, its presence never (VFN3), and a race the
kernel reports is retried up to the limit (VFN4).

Specified in `docs/specs/base/vfs/backends.md`.
*/
module sparkles.event_horizon.sys.vfs;

version (Posix):

import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno : errno, EACCES, EAGAIN, EBUSY, EEXIST, EINTR, EINVAL, EISDIR, ELOOP,
    ENAMETOOLONG, ENOENT, ENOSYS, ENOTDIR, ENOTEMPTY, EPERM, EXDEV;

import sparkles.base.io.errors : ErrorKind, IoError, IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.base.vfs.types : Access, Disposition, EntryKind, MountCheck, OpenMode,
    ResolvePolicy, Sharing, Stat, StatMask, SymlinkPolicy, DotDotPolicy, maxNameLength,
    maxSplicedPathLength, raceRetries;
import sparkles.event_horizon.sys.descriptor : BorrowedFd;
import sparkles.event_horizon.sys.error_kinds : errnoKind;
import sparkles.event_horizon.sys.posix;

/// The context a backend gives when its kernel resolver turned out to be
/// withdrawn during a call (VFR5).
enum kernelWithdrawnContext = "the kernel resolver is no longer available";

/// The blocking backend over POSIX system calls.
struct BlockingVfs
{
    /// An open descriptor.
    struct Handle
    {
        private int fd = -1;
    }

    /// A listing: a `DIR` over a fresh descriptor for the directory (VFN10).
    struct Listing
    {
        private DIR* dir;
    }

    /// Test switch: resolve every walk with the component walk (oracle 3).
    bool forceComponentWalk;

    /// Test switch: this instance behaves as if a probe had found the kernel
    /// resolver withdrawn (VFR5). The real cache is process-wide (VFN3); the
    /// switch is per instance so parallel tests do not see it.
    bool simulateWithdrawal;

    @disable this(this);

    // ------------------------------------------------------------ primitives

    /// The ambient open behind `openRoot`: follows links (VFH7).
    IoResult!Handle openRootDir(scope const(char)[] path) @safe nothrow @nogc
    {
        char[maxSplicedPathLength + 1] z;
        if (!terminate(path, z))
            return ioErr!Handle(ErrorKind.nameTooLong, OpKind.resolve);
        const fd = (() @trusted => retry(() => openat(AT_FDCWD, z.ptr,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC)))();
        return fd < 0 ? ioErr!Handle(failure(OpKind.resolve)) : ioOk(Handle(fd));
    }

    /// Opens the directory `name` in `dir` without following it.
    IoResult!Handle openDirAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
        => openDirectory(dir, name, O_RDONLY | O_DIRECTORY);

    /// Opens the directory `name` in `dir` for search only (VFN14).
    IoResult!Handle openSearchAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
        => openDirectory(dir, name, searchOnlyFlag ? searchOnlyFlag : O_RDONLY | O_DIRECTORY);

    /// A new handle to the directory `dir` names, with full access.
    IoResult!Handle reopen(Handle dir) @safe nothrow @nogc
    {
        const fd = (() @trusted => retry(() => openat(dir.fd, ".".ptr,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC)))();
        return fd < 0 ? ioErr!Handle(failure(OpKind.openAt)) : ioOk(Handle(fd));
    }

    /// Opens or creates the file `name` in `dir` without following it.
    IoResult!Handle openFileAt(Handle dir, scope const(char)[] name, OpenMode mode,
        Sharing sharing) @safe nothrow @nogc
    {
        char[maxNameLength + 1] z;
        if (!terminate(name, z))
            return ioErr!Handle(ErrorKind.nameTooLong, OpKind.openAt);
        int flags = O_NOFOLLOW | O_CLOEXEC;
        final switch (mode.access)
        {
            case Access.read: flags |= O_RDONLY; break;
            case Access.write: flags |= O_WRONLY; break;
            case Access.readWrite: flags |= O_RDWR; break;
            case Access.append: flags |= O_WRONLY | O_APPEND; break;
        }
        final switch (mode.disposition)
        {
            case Disposition.existing: break;
            case Disposition.createNew: flags |= O_CREAT | O_EXCL; break;
            case Disposition.createOrTruncate: flags |= O_CREAT | O_TRUNC; break;
        }
        const bits = sharing.modeBits(false, mode.executable);
        const fd = (() @trusted => retry(() => openat(dir.fd, z.ptr, flags, bits)))();
        if (fd < 0)
        {
            const e = errno;
            // VFN2: O_NOFOLLOW on a link fails with ELOOP (EMLINK on FreeBSD,
            // EFTYPE on NetBSD).
            if (e == ELOOP || isBsdNoFollowErrno(e))
                return ioErr!Handle(ErrorKind.symlinkRefused, OpKind.openAt, e);
            return ioErr!Handle(failure(OpKind.openAt, e));
        }
        // A read-only open of a directory succeeds on POSIX; a File is never one.
        stat_t st;
        if ((() @trusted => .fstat(fd, &st))() == 0 && (st.st_mode & S_IFMT) == S_IFDIR)
        {
            (() @trusted => .close(fd))();
            return ioErr!Handle(ErrorKind.isADirectory, OpKind.openAt, EISDIR);
        }
        return ioOk(Handle(fd));
    }

    /// Creates the directory `name` in `dir`.
    IoResult!void mkdirAt(Handle dir, scope const(char)[] name, Sharing sharing)
        @safe nothrow @nogc
    {
        char[maxNameLength + 1] z;
        if (!terminate(name, z))
            return ioErr!void(ErrorKind.nameTooLong, OpKind.mkdirAt);
        const bits = sharing.modeBits(true, false);
        const r = (() @trusted => retry(() => mkdirat(dir.fd, z.ptr, cast(ushort) bits)))();
        return r < 0 ? ioErr!void(failure(OpKind.mkdirAt)) : ioOk();
    }

    /// Stats the entry `name` in `dir` itself.
    IoResult!Stat statAt(Handle dir, scope const(char)[] name, StatMask mask) @safe nothrow @nogc
    {
        char[maxNameLength + 1] z;
        if (!terminate(name, z))
            return ioErr!Stat(ErrorKind.nameTooLong, OpKind.statAt);
        stat_t st;
        const r = (() @trusted => fstatat(dir.fd, z.ptr, &st, AT_SYMLINK_NOFOLLOW))();
        return r < 0 ? ioErr!Stat(failure(OpKind.statAt)) : ioOk(toStat(st, mask));
    }

    /// Lends the descriptor behind `h`; `File.borrowFd` forwards here.
    BorrowedFd borrowFd(Handle h) const @safe pure nothrow @nogc => BorrowedFd(h.fd);

    /// Stats an open handle.
    IoResult!Stat fstat(Handle h, StatMask mask) @safe nothrow @nogc
    {
        stat_t st;
        const r = (() @trusted => .fstat(h.fd, &st))();
        return r < 0 ? ioErr!Stat(failure(OpKind.statAt)) : ioOk(toStat(st, mask));
    }

    /// Reads the target of the link `name` in `dir` into `buffer`.
    IoResult!size_t readlinkAt(Handle dir, scope const(char)[] name, scope char[] buffer)
        @safe nothrow @nogc
    {
        char[maxNameLength + 1] z;
        if (!terminate(name, z))
            return ioErr!size_t(ErrorKind.nameTooLong, OpKind.readlinkAt);
        const n = (() @trusted => readlinkat(dir.fd, z.ptr, buffer.ptr, buffer.length))();
        if (n < 0)
        {
            const e = errno;
            if (e == EINVAL)
                return ioErr!size_t(ErrorKind.other, OpKind.readlinkAt, e,
                    IoErrorStage.completion, "not a symbolic link");
            return ioErr!size_t(failure(OpKind.readlinkAt, e));
        }
        // readlink truncates silently: a full buffer may have been too small.
        if (cast(size_t) n == buffer.length)
            return ioErr!size_t(ErrorKind.bufferTooSmall, OpKind.readlinkAt);
        return ioOk(cast(size_t) n);
    }

    /// Creates the link `name` in `dir` with `target` stored verbatim.
    IoResult!void symlinkAt(Handle dir, scope const(char)[] name, scope const(char)[] target)
        @safe nothrow @nogc
    {
        char[maxNameLength + 1] z;
        char[maxSplicedPathLength + 1] t;
        if (!terminate(name, z) || !terminate(target, t))
            return ioErr!void(ErrorKind.nameTooLong, OpKind.symlinkAt);
        const r = (() @trusted => symlinkat(t.ptr, dir.fd, z.ptr))();
        return r < 0 ? ioErr!void(failure(OpKind.symlinkAt)) : ioOk();
    }

    /// Removes the non-directory `name` in `dir`.
    IoResult!void unlinkAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
    {
        char[maxNameLength + 1] z;
        if (!terminate(name, z))
            return ioErr!void(ErrorKind.nameTooLong, OpKind.unlinkAt);
        const r = (() @trusted => unlinkat(dir.fd, z.ptr, 0))();
        if (r == 0)
            return ioOk();
        const e = errno;
        // Linux says EISDIR for a directory; macOS says EPERM.
        if (e == EISDIR || (e == EPERM && isDirectoryAt(dir, z)))
            return ioErr!void(ErrorKind.isADirectory, OpKind.unlinkAt, e);
        return ioErr!void(failure(OpKind.unlinkAt, e));
    }

    /// Removes the empty directory `name` in `dir`.
    IoResult!void rmdirAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
    {
        char[maxNameLength + 1] z;
        if (!terminate(name, z))
            return ioErr!void(ErrorKind.nameTooLong, OpKind.rmdirAt);
        const r = (() @trusted => unlinkat(dir.fd, z.ptr, AT_REMOVEDIR))();
        if (r == 0)
            return ioOk();
        const e = errno;
        if (e == ENOTEMPTY || e == EEXIST)
            return ioErr!void(ErrorKind.notEmpty, OpKind.rmdirAt, e);
        return ioErr!void(failure(OpKind.rmdirAt, e));
    }

    /// Renames `name` in `dir` to `dstName` in `dstDir`.
    IoResult!void renameAt(Handle dir, scope const(char)[] name, Handle dstDir,
        scope const(char)[] dstName) @safe nothrow @nogc
    {
        char[maxNameLength + 1] z, d;
        if (!terminate(name, z) || !terminate(dstName, d))
            return ioErr!void(ErrorKind.nameTooLong, OpKind.renameAt);
        const r = (() @trusted => renameat(dir.fd, z.ptr, dstDir.fd, d.ptr))();
        if (r == 0)
            return ioOk();
        const e = errno;
        if (e == ENOTEMPTY || e == EEXIST)
            return ioErr!void(ErrorKind.notEmpty, OpKind.renameAt, e);
        return ioErr!void(failure(OpKind.renameAt, e));
    }

    /// Starts a listing over a fresh descriptor for `dir` (VFN10).
    IoResult!Listing openListing(Handle dir) @safe nothrow @nogc
    {
        auto fresh = reopen(dir);
        if (fresh.hasError)
        {
            IoError e = fresh.error;
            e.op = OpKind.readDir;
            return ioErr!Listing(e);
        }
        auto d = (() @trusted => fdopendir(fresh.value.fd))();
        if (d is null)
        {
            const e = errno;
            (() @trusted => .close(fresh.value.fd))();
            return ioErr!Listing(failure(OpKind.readDir, e));
        }
        return ioOk(Listing(d));
    }

    /// Advances a listing, skipping `.` and `..`.
    IoResult!bool nextEntry(scope ref Listing listing, scope char[] buffer, out size_t nameLength,
        out EntryKind kind) @safe nothrow @nogc
    {
        while (true)
        {
            errno = 0;
            auto e = (() @trusted => readdir(listing.dir))();
            if (e is null)
                return errno == 0 ? ioOk(false) : ioErr!bool(failure(OpKind.readDir));
            const name = (() @trusted => entryName(e))();
            if (name == "." || name == "..")
                continue;
            if (buffer.length < name.length)
                return ioErr!bool(ErrorKind.bufferTooSmall, OpKind.readDir);
            buffer[0 .. name.length] = name[];
            nameLength = name.length;
            kind = (() @trusted => entryKind(e))();
            return ioOk(true);
        }
    }

    /// Ends a listing.
    void closeListing(scope ref Listing listing) @safe nothrow @nogc
    {
        if (listing.dir !is null)
            (() @trusted => closedir(listing.dir))();
        listing.dir = null;
    }

    /// Reads from an open file.
    IoResult!size_t read(Handle h, scope ubyte[] buffer) @safe nothrow @nogc
    {
        const n = (() @trusted => retry(() => cast(int) .read(h.fd, buffer.ptr, buffer.length)))();
        return n < 0 ? ioErr!size_t(failure(OpKind.read)) : ioOk(cast(size_t) n);
    }

    /// Writes to an open file.
    IoResult!size_t write(Handle h, scope const(ubyte)[] data) @safe nothrow @nogc
    {
        const n = (() @trusted => retry(() => cast(int) .write(h.fd, data.ptr, data.length)))();
        return n < 0 ? ioErr!size_t(failure(OpKind.write)) : ioOk(cast(size_t) n);
    }

    /// Flushes an open file to stable storage.
    IoResult!void sync(Handle h) @safe nothrow @nogc
    {
        const r = (() @trusted => retry(() => fsync(h.fd)))();
        return r < 0 ? ioErr!void(failure(OpKind.fsync)) : ioOk();
    }

    /// Closes a handle. `EINTR` is not retried: the descriptor is gone either way.
    IoResult!void close(Handle h) @safe nothrow @nogc
    {
        const r = (() @trusted => .close(h.fd))();
        return r < 0 && errno != EINTR ? ioErr!void(failure(OpKind.close)) : ioOk();
    }

    // ------------------------------------------------------- kernel resolver

    /// Whether the kernel resolves whole paths under `policy` (VFN5).
    bool wholePathFor(ResolvePolicy policy) @safe nothrow @nogc
    {
        if (forceComponentWalk || simulateWithdrawal)
            return false;
        version (linux)
            return resolverAvailable();
        else version (OSX)
            return policy.symlinks == SymlinkPolicy.none && policy.dotDot == DotDotPolicy.reject
                && policy.crossMounts && resolverAvailable();
        else
            return false;
    }

    /// Whether a probe found the kernel resolver withdrawn since a root chose
    /// it (VFR5).
    bool wholePathWithdrawn() const @safe nothrow @nogc
        => simulateWithdrawal || atomicLoad(resolverAbsent);

    /// How a root under `policy` detects mount crossings (VFN6).
    MountCheck mountCheckFor(ResolvePolicy policy) @safe nothrow @nogc
    {
        if (policy.crossMounts)
            return MountCheck.none;
        version (linux)
            return wholePathFor(policy) ? MountCheck.kernel : MountCheck.racy;
        else
            return MountCheck.racy;
    }

    /// Resolves `path` from `start` in one call (VFN5), retrying a reported
    /// race (VFN4). Its refusal is the result (VFR4).
    IoResult!Handle resolveWhole(Handle start, scope const(char)[] path, ResolvePolicy policy)
        @safe nothrow @nogc
    {
        char[maxSplicedPathLength + 1] z;
        if (!terminate(path.length ? path : ".", z))
            return ioErr!Handle(ErrorKind.nameTooLong, OpKind.resolve);
        version (linux)
        {
            OpenHow how;
            how.flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC;
            how.resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS;
            if (policy.symlinks == SymlinkPolicy.none)
                how.resolve |= RESOLVE_NO_SYMLINKS;
            if (!policy.crossMounts)
                how.resolve |= RESOLVE_NO_XDEV;
            foreach (attempt; 0 .. raceRetries + 1)
            {
                const fd = (() @trusted => openat2(start.fd, z.ptr, how))();
                if (fd >= 0)
                    return ioOk(Handle(fd));
                const e = errno;
                if (e == EAGAIN)
                    continue; // VFN4
                if (e == EINTR)
                    continue;
                return ioErr!Handle(classifyOpenat2(start, z, how, e, policy));
            }
            return ioErr!Handle(ErrorKind.raceRetryExhausted, OpKind.resolve, EAGAIN);
        }
        else version (OSX)
        {
            const fd = (() @trusted => retry(() => openat(start.fd, z.ptr,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)))();
            if (fd >= 0)
                return ioOk(Handle(fd));
            const e = errno;
            if (e == ELOOP)
                return ioErr!Handle(ErrorKind.symlinkRefused, OpKind.resolve, e);
            if (e == EINVAL && !probe())
            {
                atomicStore(resolverAbsent, true);
                return ioErr!Handle(ErrorKind.unsupported, OpKind.resolve, e,
                    IoErrorStage.probe, kernelWithdrawnContext);
            }
            return ioErr!Handle(failure(OpKind.resolve, e));
        }
        else
            return ioErr!Handle(ErrorKind.unsupported, OpKind.resolve);
    }

    // ------------------------------------------------------------ internals

private:

    static shared bool resolverAbsent;

    IoResult!Handle openDirectory(Handle dir, scope const(char)[] name, int flags)
        @safe nothrow @nogc
    {
        char[maxNameLength + 1] z;
        if (!terminate(name, z))
            return ioErr!Handle(ErrorKind.nameTooLong, OpKind.openAt);
        const fd = (() @trusted => retry(() => openat(dir.fd, z.ptr,
            flags | O_NOFOLLOW | O_CLOEXEC)))();
        if (fd >= 0)
            return ioOk(Handle(fd));
        const e = errno;
        // VFN2: ENOTDIR or ELOOP is a link or a non-directory; ask which.
        if (e == ENOTDIR || e == ELOOP || isBsdNoFollowErrno(e))
        {
            stat_t st;
            if ((() @trusted => fstatat(dir.fd, z.ptr, &st, AT_SYMLINK_NOFOLLOW))() == 0)
                return ioErr!Handle((st.st_mode & S_IFMT) == S_IFLNK
                    ? ErrorKind.symlinkRefused : ErrorKind.notADirectory, OpKind.openAt, e);
        }
        return ioErr!Handle(failure(OpKind.openAt, e));
    }

    bool isDirectoryAt(Handle dir, scope ref const char[maxNameLength + 1] z) @safe nothrow @nogc
    {
        stat_t st;
        return (() @trusted => fstatat(dir.fd, z.ptr, &st, AT_SYMLINK_NOFOLLOW))() == 0
            && (st.st_mode & S_IFMT) == S_IFDIR;
    }

    version (linux)
    {
        IoError classifyOpenat2(Handle start, scope ref const char[maxSplicedPathLength + 1] z,
            ref const OpenHow how, int e, ResolvePolicy policy) @safe nothrow @nogc
        {
            if (e == ELOOP)
                return IoError(policy.symlinks == SymlinkPolicy.none
                    ? ErrorKind.symlinkRefused : ErrorKind.symlinkLoop, e, OpKind.resolve);
            if (e == EXDEV)
            {
                // VFN2: a crossing or an escape? Look again without NO_XDEV.
                if (how.resolve & RESOLVE_NO_XDEV)
                {
                    OpenHow probeHow = how;
                    probeHow.flags = O_PATH | O_CLOEXEC;
                    probeHow.resolve &= ~RESOLVE_NO_XDEV;
                    const fd = (() @trusted => openat2(start.fd, z.ptr, probeHow))();
                    if (fd >= 0)
                    {
                        (() @trusted => .close(fd))();
                        return IoError(ErrorKind.crossesMount, e, OpKind.resolve);
                    }
                }
                return IoError(ErrorKind.escapesRoot, e, OpKind.resolve);
            }
            if ((e == ENOSYS || e == EPERM) && !probe())
            {
                atomicStore(resolverAbsent, true);
                return IoError(ErrorKind.unsupported, e, OpKind.resolve, IoErrorStage.probe,
                    kernelWithdrawnContext);
            }
            return errnoError(e, OpKind.resolve);
        }
    }

    // Probes the kernel resolver once; absence is cached, presence never (VFN3).
    static bool resolverAvailable() @safe nothrow @nogc
    {
        if (atomicLoad(resolverAbsent))
            return false;
        if (!probe())
        {
            atomicStore(resolverAbsent, true);
            return false;
        }
        return true;
    }

    static bool probe() @safe nothrow @nogc
    {
        if (atomicLoad(resolverAbsent))
            return false;
        version (linux)
        {
            OpenHow how;
            how.flags = O_PATH | O_CLOEXEC;
            how.resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS;
            const fd = (() @trusted => openat2(AT_FDCWD, ".".ptr, how))();
            if (fd >= 0)
            {
                (() @trusted => .close(fd))();
                return true;
            }
            return errno != ENOSYS && errno != EPERM && errno != EINVAL;
        }
        else version (OSX)
        {
            const fd = (() @trusted => openat(AT_FDCWD, "/".ptr,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY))();
            if (fd >= 0)
            {
                (() @trusted => .close(fd))();
                return true;
            }
            return false;
        }
        else
            return false;
    }
}

// ---------------------------------------------------------------- helpers

private:

/// Copies `s` with a NUL into `z`; false if it does not fit or holds a NUL.
bool terminate(size_t N)(scope const(char)[] s, ref char[N] z) @safe pure nothrow @nogc
{
    if (s.length >= N)
        return false;
    foreach (c; s)
        if (c == '\0')
            return false;
    z[0 .. s.length] = s[];
    z[s.length] = '\0';
    return true;
}

/// Repeats a call while it fails with `EINTR`.
int retry(scope int delegate() @system nothrow @nogc call) @system nothrow @nogc
{
    int r;
    do
        r = call();
    while (r < 0 && errno == EINTR);
    return r;
}

bool isBsdNoFollowErrno(int e) @safe pure nothrow @nogc
{
    version (FreeBSD)
    {
        import core.stdc.errno : EMLINK;

        return e == EMLINK;
    }
    else version (NetBSD)
        return e == 79; // EFTYPE
    else
        return false;
}

IoError failure(OpKind op, int e) @safe nothrow @nogc => errnoError(e, op);
IoError failure(OpKind op) @safe nothrow @nogc => errnoError(errno, op);

/// The portable kind of an `errno` (VFN1).
/// Every open here refuses to follow a link, so `ELOOP` means the link was
/// refused, not that a chain of them ran too long.
IoError errnoError(int e, OpKind op) @safe pure nothrow @nogc
    => IoError(e == ELOOP ? ErrorKind.symlinkRefused : errnoKind(e), e, op);

Stat toStat(ref const stat_t st, StatMask mask) @safe pure nothrow @nogc
{
    Stat s;
    switch (st.st_mode & S_IFMT)
    {
        case S_IFREG: s.kind = EntryKind.regular; break;
        case S_IFDIR: s.kind = EntryKind.directory; break;
        case S_IFLNK: s.kind = EntryKind.symlink; break;
        default: s.kind = EntryKind.other; break;
    }
    s.executable = (st.st_mode & octal100) != 0;
    s.size = st.st_size;
    s.device = st.st_dev;
    s.permissions = st.st_mode & octal7777;
    if (mask & StatMask.mtime)
    {
        s.hasMtime = true;
        static if (__traits(compiles, st.st_mtim))
            s.mtimeNs = st.st_mtim.tv_sec * 1_000_000_000L + st.st_mtim.tv_nsec;
        else static if (__traits(compiles, st.st_mtimespec))
            s.mtimeNs = st.st_mtimespec.tv_sec * 1_000_000_000L + st.st_mtimespec.tv_nsec;
        else
            s.mtimeNs = st.st_mtime * 1_000_000_000L;
    }
    return s;
}

enum uint octal100 = 64, octal7777 = 4095;

const(char)[] entryName(return scope dirent* e) @system pure nothrow @nogc
{
    size_t n;
    while (n < e.d_name.length && e.d_name[n] != '\0')
        ++n;
    return e.d_name[0 .. n];
}

EntryKind entryKind(scope dirent* e) @system pure nothrow @nogc
{
    import core.sys.posix.dirent : DT_DIR, DT_LNK, DT_REG, DT_UNKNOWN;

    switch (e.d_type)
    {
        case DT_DIR: return EntryKind.directory;
        case DT_REG: return EntryKind.regular;
        case DT_LNK: return EntryKind.symlink;
        case DT_UNKNOWN: return EntryKind.unknown;
        default: return EntryKind.other;
    }
}
