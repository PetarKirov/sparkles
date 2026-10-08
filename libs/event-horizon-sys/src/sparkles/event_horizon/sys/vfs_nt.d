/**
`BlockingVfs` on Windows: the capability VFS's blocking backend over the NT
native API (VFB4).

Every primitive is an `NtCreateFile` relative to the parent handle
(`OBJECT_ATTRIBUTES.RootDirectory`) with `FILE_OPEN_REPARSE_POINT`, so the
named entry is never followed (VFN9); a name-surrogate reparse tag, set for
symbolic links and junctions, is a link (VFN7). Directory handles share
delete access, so a directory can be removed through its own handle. The
kernel resolver is `OBJ_DONT_REPARSE`, which refuses any reparse point on
the way (VFN5). Deletion goes through the entry's own handle with POSIX
semantics, falling back to the classic disposition (VFN13).

Specified in `docs/specs/base/vfs/backends.md`.
*/
module sparkles.event_horizon.sys.vfs_nt;

version (Windows):

import core.atomic : atomicLoad, atomicStore;

import sparkles.base.io.errors : ErrorKind, IoError, IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.base.text.utf16 : utf16ToUtf8, utf8ToUtf16;
import sparkles.base.vfs.names : pathComponents;
import sparkles.base.vfs.types : Access, Disposition, DotDotPolicy, EntryKind, MountCheck,
    OpenMode, ResolvePolicy, Sharing, Stat, StatMask, SymlinkPolicy, maxSplicedPathLength,
    windowsDeleteRetries;
import sparkles.event_horizon.sys.nt;

/// The context a backend gives when its kernel resolver turned out to be
/// withdrawn during a call (VFR5).
enum kernelWithdrawnContext = "the kernel resolver is no longer available";

/// The blocking backend over the NT native API.
struct BlockingVfs
{
    /// An open NT handle, stored as an integer so a handle carries no pointer.
    struct Handle
    {
        private size_t raw;
    }

    /// A directory listing: a fresh handle and its query buffer (VFN10).
    struct Listing
    {
        private size_t raw;
        private ubyte[4096] buffer;
        private size_t offset, filled;
        private bool started, done;
    }

    /// Test switch: resolve every walk with the component walk (oracle 3).
    bool forceComponentWalk;
    /// Test switch: behave as if the kernel resolver were withdrawn (VFR5).
    bool simulateWithdrawal;

    @disable this(this);

    // ------------------------------------------------------------ primitives

    /// The ambient open behind `openRoot`: follows reparse points (VFH7).
    IoResult!Handle openRootDir(scope const(char)[] path) @safe nothrow @nogc
    {
        import core.sys.windows.winbase : CreateFileW, FILE_FLAG_BACKUP_SEMANTICS, OPEN_EXISTING;
        import core.sys.windows.winbase : INVALID_HANDLE_VALUE;

        wchar[maxSplicedPathLength + 1] w;
        const n = wide(path, w[0 .. $ - 1]);
        if (n == size_t.max)
            return ioErr!Handle(ErrorKind.nameTooLong, OpKind.resolve);
        w[n] = 0;
        auto h = (() @trusted => CreateFileW(w.ptr, directoryAccess, FILE_SHARE_ALL, null,
            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null))();
        if (h == INVALID_HANDLE_VALUE)
            return ioErr!Handle(win32Error(OpKind.resolve));
        return ioOk(Handle(cast(size_t) h));
    }

    /// Opens the directory `name` in `dir` without following it.
    IoResult!Handle openDirAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
        => openDirectory(dir, name, directoryAccess);

    /// Opens the directory `name` in `dir` for traversal only (VFN14).
    IoResult!Handle openSearchAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
        => openDirectory(dir, name, FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE);

    /// A new handle to the directory `dir` names, with full access.
    IoResult!Handle reopen(Handle dir) @safe nothrow @nogc
    {
        size_t h;
        const s = ntOpen(dir.raw, null, directoryAccess, directoryOptions, 0, FILE_OPEN, null, h);
        return ntSuccess(s) ? ioOk(Handle(h)) : ioErr!Handle(ntError(s, OpKind.openAt));
    }

    /// Opens or creates the file `name` in `dir` without following it.
    IoResult!Handle openFileAt(Handle dir, scope const(char)[] name, OpenMode mode,
        Sharing sharing) @safe nothrow @nogc
    {
        ULONG access = FILE_READ_ATTRIBUTES | SYNCHRONIZE;
        final switch (mode.access)
        {
            case Access.read: access |= readAccess; break;
            case Access.write: access |= writeAccess; break;
            case Access.readWrite: access |= readAccess | writeAccess; break;
            case Access.append: access |= FILE_APPEND_DATA; break;
        }
        ULONG disposition;
        final switch (mode.disposition)
        {
            case Disposition.existing: disposition = FILE_OPEN; break;
            case Disposition.createNew: disposition = FILE_CREATE; break;
            case Disposition.createOrTruncate: disposition = FILE_OVERWRITE_IF; break;
        }
        OwnerOnlyDescriptor sd;
        void* descriptor = sharing.kind == Sharing.Kind.ownerOnly && mode.creates ? sd.build() : null;
        size_t h;
        const s = ntOpenName(dir.raw, name, access,
            FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
            disposition, descriptor, h);
        if (!ntSuccess(s))
        {
            if (s == STATUS_FILE_IS_A_DIRECTORY && isLinkAt(dir, name))
                return ioErr!Handle(ErrorKind.symlinkRefused, OpKind.openAt, s);
            return ioErr!Handle(ntError(s, OpKind.openAt));
        }
        if (isLinkHandle(h))
        {
            close(Handle(h));
            return ioErr!Handle(ErrorKind.symlinkRefused, OpKind.openAt);
        }
        return ioOk(Handle(h));
    }

    /// Creates the directory `name` in `dir`.
    IoResult!void mkdirAt(Handle dir, scope const(char)[] name, Sharing sharing)
        @safe nothrow @nogc
    {
        OwnerOnlyDescriptor sd;
        void* descriptor = sharing.kind == Sharing.Kind.ownerOnly ? sd.build() : null;
        size_t h;
        const s = ntOpenName(dir.raw, name, FILE_LIST_DIRECTORY | SYNCHRONIZE,
            FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT, FILE_CREATE, descriptor, h);
        if (!ntSuccess(s))
            return ioErr!void(ntError(s, OpKind.mkdirAt));
        close(Handle(h));
        return ioOk();
    }

    /// Stats the entry `name` in `dir` itself.
    IoResult!Stat statAt(Handle dir, scope const(char)[] name, StatMask mask) @safe nothrow @nogc
    {
        size_t h;
        const s = ntOpenName(dir.raw, name, FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_OPEN_REPARSE_POINT | FILE_OPEN_FOR_BACKUP_INTENT | FILE_SYNCHRONOUS_IO_NONALERT,
            FILE_OPEN, null, h);
        if (!ntSuccess(s))
            return ioErr!Stat(ntError(s, OpKind.statAt));
        auto st = fstat(Handle(h), mask);
        close(Handle(h));
        return st;
    }

    /// Stats an open handle.
    IoResult!Stat fstat(Handle handle, StatMask mask) @safe nothrow @nogc
    {
        import core.sys.windows.winbase : BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle;

        BY_HANDLE_FILE_INFORMATION info;
        if (!(() @trusted => GetFileInformationByHandle(cast(HANDLE) handle.raw, &info))())
            return ioErr!Stat(win32Error(OpKind.statAt));
        FILE_ATTRIBUTE_TAG_INFORMATION tag;
        IO_STATUS_BLOCK io;
        const t = (() @trusted => NtQueryInformationFile(cast(HANDLE) handle.raw, &io, &tag,
            tag.sizeof, FileAttributeTagInformation))();
        Stat st;
        const attrs = info.dwFileAttributes;
        if (ntSuccess(t) && (attrs & FILE_ATTRIBUTE_REPARSE_POINT)
            && (tag.ReparseTag & REPARSE_TAG_NAME_SURROGATE))
            st.kind = EntryKind.symlink;
        else if (attrs & FILE_ATTRIBUTE_DIRECTORY)
            st.kind = EntryKind.directory;
        else
            st.kind = EntryKind.regular;
        st.size = st.kind == EntryKind.directory ? 0
            : (cast(ulong) info.nFileSizeHigh << 32) | info.nFileSizeLow;
        st.device = info.dwVolumeSerialNumber;
        if (mask & StatMask.mtime)
        {
            st.hasMtime = true;
            const ticks = (cast(long) info.ftLastWriteTime.dwHighDateTime << 32)
                | info.ftLastWriteTime.dwLowDateTime;
            st.mtimeNs = (ticks - 116_444_736_000_000_000L) * 100;
        }
        return ioOk(st);
    }

    /// Reads the target of the link `name` in `dir` into `buffer` (UTF-8).
    IoResult!size_t readlinkAt(Handle dir, scope const(char)[] name, scope char[] buffer)
        @safe nothrow @nogc
    {
        size_t h;
        const s = ntOpenName(dir.raw, name, FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_OPEN_REPARSE_POINT | FILE_OPEN_FOR_BACKUP_INTENT | FILE_SYNCHRONOUS_IO_NONALERT,
            FILE_OPEN, null, h);
        if (!ntSuccess(s))
            return ioErr!size_t(ntError(s, OpKind.readlinkAt));
        scope (exit) close(Handle(h));
        ubyte[16 * 1024] data;
        IO_STATUS_BLOCK io;
        const f = (() @trusted => NtFsControlFile(cast(HANDLE) h, null, null, null, &io,
            FSCTL_GET_REPARSE_POINT, null, 0, data.ptr, cast(ULONG) data.length))();
        if (!ntSuccess(f))
            return ioErr!size_t(f == STATUS_NOT_A_REPARSE_POINT
                ? IoError(ErrorKind.other, f, OpKind.readlinkAt, IoErrorStage.completion,
                    "not a symbolic link")
                : ntError(f, OpKind.readlinkAt));
        const target = (() @trusted => reparseTarget(data[]))();
        if (target is null)
            return ioErr!size_t(ErrorKind.other, OpKind.readlinkAt, 0, IoErrorStage.completion,
                "not a symbolic link");
        auto n = utf16ToUtf8(target, buffer);
        if (n.hasError)
            return ioErr!size_t(ErrorKind.bufferTooSmall, OpKind.readlinkAt);
        foreach (ref c; buffer[0 .. n.value])
            if (c == '\\')
                c = '/';
        return ioOk(n.value);
    }

    /// Creates the link `name` in `dir` with the relative `target`. A target
    /// that names an existing directory makes a directory link. Windows needs
    /// a privilege or developer mode for this; without one it fails with
    /// `permission`.
    IoResult!void symlinkAt(Handle dir, scope const(char)[] name, scope const(char)[] target)
        @safe nothrow @nogc
    {
        wchar[maxSplicedPathLength] wt;
        const tn = wide(target, wt[]);
        if (tn == size_t.max)
            return ioErr!void(ErrorKind.nameTooLong, OpKind.symlinkAt);
        foreach (ref c; wt[0 .. tn])
            if (c == '/')
                c = '\\';
        const directory = isDirectoryRelative(dir, wt[0 .. tn]);
        size_t h;
        const s = ntOpenName(dir.raw, name, FILE_WRITE_DATA | FILE_WRITE_ATTRIBUTES | DELETE
            | SYNCHRONIZE, (directory ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE)
            | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT, FILE_CREATE, null, h);
        if (!ntSuccess(s))
            return ioErr!void(ntError(s, OpKind.symlinkAt));
        ubyte[16 * 1024] data;
        const length = (() @trusted => symlinkReparseData(data[], wt[0 .. tn]))();
        IO_STATUS_BLOCK io;
        const f = (() @trusted => NtFsControlFile(cast(HANDLE) h, null, null, null, &io,
            FSCTL_SET_REPARSE_POINT, data.ptr, cast(ULONG) length, null, 0))();
        if (!ntSuccess(f))
        {
            deleteHandle(h);
            close(Handle(h));
            return ioErr!void(ntError(f, OpKind.symlinkAt));
        }
        close(Handle(h));
        return ioOk();
    }

    /// Removes the non-directory `name` in `dir`; a link is removed itself.
    IoResult!void unlinkAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
    {
        size_t h;
        const s = ntOpenName(dir.raw, name, deleteAccess, deleteOptions, FILE_OPEN, null, h);
        if (!ntSuccess(s))
            return ioErr!void(ntError(s, OpKind.unlinkAt));
        scope (exit) close(Handle(h));
        const kind = kindOf(h);
        if (kind == EntryKind.directory)
            return ioErr!void(ErrorKind.isADirectory, OpKind.unlinkAt);
        const d = deleteHandle(h);
        return ntSuccess(d) ? ioOk() : ioErr!void(ntError(d, OpKind.unlinkAt));
    }

    /// Removes the empty directory `name` in `dir`.
    IoResult!void rmdirAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
    {
        size_t h;
        const s = ntOpenName(dir.raw, name, deleteAccess, deleteOptions, FILE_OPEN, null, h);
        if (!ntSuccess(s))
            return ioErr!void(ntError(s, OpKind.rmdirAt));
        scope (exit) close(Handle(h));
        if (kindOf(h) != EntryKind.directory)
            return ioErr!void(ErrorKind.notADirectory, OpKind.rmdirAt);
        const d = deleteHandle(h);
        return ntSuccess(d) ? ioOk() : ioErr!void(ntError(d, OpKind.rmdirAt));
    }

    /// Renames `name` in `dir` to `dstName` in `dstDir`, replacing a file there.
    IoResult!void renameAt(Handle dir, scope const(char)[] name, Handle dstDir,
        scope const(char)[] dstName) @safe nothrow @nogc
    {
        size_t h;
        const s = ntOpenName(dir.raw, name, DELETE | SYNCHRONIZE, FILE_OPEN_REPARSE_POINT
            | FILE_OPEN_FOR_BACKUP_INTENT | FILE_SYNCHRONOUS_IO_NONALERT, FILE_OPEN, null, h);
        if (!ntSuccess(s))
            return ioErr!void(ntError(s, OpKind.renameAt));
        scope (exit) close(Handle(h));
        FILE_RENAME_INFORMATION info;
        info.ReplaceIfExists = 1;
        info.RootDirectory = (() @trusted => cast(HANDLE) dstDir.raw)();
        const n = wide(dstName, info.FileName[]);
        if (n == size_t.max)
            return ioErr!void(ErrorKind.nameTooLong, OpKind.renameAt);
        if (n + 1 > info.FileName.length)
            return ioErr!void(ErrorKind.nameTooLong, OpKind.renameAt);
        info.FileNameLength = cast(ULONG)(n * 2);
        info.FileName[n] = 0;
        // The length must cover at least the C struct with its one-element
        // name array: 24 bytes, more than the 20-byte header plus a short name.
        enum headerBytes = FILE_RENAME_INFORMATION.FileName.offsetof;
        const length = headerBytes + (n + 1) * 2 < 24 ? 24 : headerBytes + (n + 1) * 2;
        IO_STATUS_BLOCK io;
        const r = (() @trusted => NtSetInformationFile(cast(HANDLE) h, &io, &info,
            cast(ULONG) length, FileRenameInformation))();
        return ntSuccess(r) ? ioOk() : ioErr!void(ntError(r, OpKind.renameAt));
    }

    /// Starts a listing over a fresh handle for `dir` (VFN10).
    IoResult!Listing openListing(Handle dir) @safe nothrow @nogc
    {
        auto fresh = reopen(dir);
        if (fresh.hasError)
        {
            IoError e = fresh.error;
            e.op = OpKind.readDir;
            return ioErr!Listing(e);
        }
        Listing l;
        l.raw = fresh.value.raw;
        return ioOk(l);
    }

    /// Advances a listing, skipping `.` and `..`.
    IoResult!bool nextEntry(scope ref Listing l, scope char[] buffer, out size_t nameLength,
        out EntryKind kind) @safe nothrow @nogc
    {
        while (true)
        {
            if (l.done)
                return ioOk(false);
            if (l.offset >= l.filled)
            {
                IO_STATUS_BLOCK io;
                const s = (() @trusted => NtQueryDirectoryFile(cast(HANDLE) l.raw, null, null,
                    null, &io, l.buffer.ptr, cast(ULONG) l.buffer.length,
                    FileFullDirectoryInformation, 0, null, !l.started))();
                l.started = true;
                if (s == STATUS_NO_MORE_FILES)
                {
                    l.done = true;
                    return ioOk(false);
                }
                if (!ntSuccess(s))
                    return ioErr!bool(ntError(s, OpKind.readDir));
                l.offset = 0;
                l.filled = io.Information;
            }
            const entry = (() @trusted => cast(FILE_FULL_DIR_INFORMATION*)(l.buffer.ptr + l.offset))();
            const next = (() @trusted => entry.NextEntryOffset)();
            const attrs = (() @trusted => entry.FileAttributes)();
            const tag = (() @trusted => entry.EaSize)();
            const wname = (() @trusted => (cast(const(wchar)*) &entry.FileName[0])[
                0 .. entry.FileNameLength / 2])();
            l.offset = next ? l.offset + next : l.filled;
            if (wname == "."w || wname == ".."w)
                continue;
            auto n = utf16ToUtf8(wname, buffer);
            if (n.hasError)
                return ioErr!bool(ErrorKind.bufferTooSmall, OpKind.readDir);
            nameLength = n.value;
            kind = (attrs & FILE_ATTRIBUTE_REPARSE_POINT) && (tag & REPARSE_TAG_NAME_SURROGATE)
                ? EntryKind.symlink : (attrs & FILE_ATTRIBUTE_DIRECTORY) ? EntryKind.directory
                : EntryKind.regular;
            return ioOk(true);
        }
    }

    /// Ends a listing.
    void closeListing(scope ref Listing l) @safe nothrow @nogc
    {
        if (l.raw)
            close(Handle(l.raw));
        l.raw = 0;
    }

    /// Reads from an open file.
    IoResult!size_t read(Handle h, scope ubyte[] buffer) @safe nothrow @nogc
    {
        import core.sys.windows.winbase : ReadFile;

        uint got;
        const ok = (() @trusted => ReadFile(cast(HANDLE) h.raw, buffer.ptr,
            cast(uint) buffer.length, &got, null))();
        return ok ? ioOk(cast(size_t) got) : ioErr!size_t(win32Error(OpKind.read));
    }

    /// Writes to an open file.
    IoResult!size_t write(Handle h, scope const(ubyte)[] data) @safe nothrow @nogc
    {
        import core.sys.windows.winbase : WriteFile;

        uint put;
        const ok = (() @trusted => WriteFile(cast(HANDLE) h.raw, data.ptr,
            cast(uint) data.length, &put, null))();
        return ok ? ioOk(cast(size_t) put) : ioErr!size_t(win32Error(OpKind.write));
    }

    /// Flushes an open file to stable storage.
    IoResult!void sync(Handle h) @safe nothrow @nogc
    {
        import core.sys.windows.winbase : FlushFileBuffers;

        return (() @trusted => FlushFileBuffers(cast(HANDLE) h.raw))() ? ioOk()
            : ioErr!void(win32Error(OpKind.fsync));
    }

    /// Closes a handle.
    IoResult!void close(Handle h) @safe nothrow @nogc
    {
        const s = (() @trusted => NtClose(cast(HANDLE) h.raw))();
        return ntSuccess(s) ? ioOk() : ioErr!void(ntError(s, OpKind.close));
    }

    // ------------------------------------------------------- kernel resolver

    /// Whether the kernel resolves whole paths under `policy` (VFN5).
    bool wholePathFor(ResolvePolicy policy) @safe nothrow @nogc
    {
        if (forceComponentWalk || simulateWithdrawal)
            return false;
        return policy.symlinks == SymlinkPolicy.none && policy.dotDot == DotDotPolicy.reject
            && resolverAvailable();
    }

    /// Whether the kernel resolver has been found withdrawn (VFR5).
    bool wholePathWithdrawn() const @safe nothrow @nogc
        => simulateWithdrawal || atomicLoad(resolverAbsent);

    /// How a root under `policy` detects mount crossings (VFN6). With
    /// `OBJ_DONT_REPARSE` a volume mount point, being a reparse point, is
    /// refused by the kernel.
    MountCheck mountCheckFor(ResolvePolicy policy) @safe nothrow @nogc
    {
        if (policy.crossMounts)
            return MountCheck.none;
        return wholePathFor(policy) ? MountCheck.kernel : MountCheck.racy;
    }

    /// Resolves `path` from `start` in one call with `OBJ_DONT_REPARSE`.
    IoResult!Handle resolveWhole(Handle start, scope const(char)[] path, ResolvePolicy policy)
        @safe nothrow @nogc
    {
        wchar[maxSplicedPathLength] w;
        size_t n;
        foreach (c; pathComponents(path))
        {
            if (n)
            {
                if (n >= w.length)
                    return ioErr!Handle(ErrorKind.nameTooLong, OpKind.resolve);
                w[n++] = '\\';
            }
            const m = wide(c, w[n .. $]);
            if (m == size_t.max)
                return ioErr!Handle(ErrorKind.nameTooLong, OpKind.resolve);
            n += m;
        }
        if (n == 0)
            return reopen(start);
        size_t h;
        const s = ntOpen(start.raw, w[0 .. n], directoryAccess, directoryOptions,
            OBJ_DONT_REPARSE, FILE_OPEN, null, h);
        if (ntSuccess(s))
            return ioOk(Handle(h));
        if (s == STATUS_INVALID_PARAMETER && !probe())
        {
            atomicStore(resolverAbsent, true);
            return ioErr!Handle(ErrorKind.unsupported, OpKind.resolve, s, IoErrorStage.probe,
                kernelWithdrawnContext);
        }
        // VFN2: the kernel says only that the path was not found when an
        // intermediate is a file; step through to tell which, opening nothing
        // that is returned. The kernel's refusal stays the result (VFR4).
        if (s == STATUS_OBJECT_PATH_NOT_FOUND)
            return ioErr!Handle(classifyPath(start, path, s));
        return ioErr!Handle(ntError(s, OpKind.resolve));
    }

    // The kind of the first step of `path` that fails, with `s` as its code.
    IoError classifyPath(Handle start, scope const(char)[] path, NTSTATUS s) @safe nothrow @nogc
    {
        size_t[64] opened;
        size_t depth;
        size_t cur = start.raw;
        scope (exit)
            foreach (h; opened[0 .. depth])
                close(Handle(h));
        foreach (c; pathComponents(path))
        {
            auto next = openSearchAt(Handle(cur), c);
            if (next.hasError)
            {
                IoError e = next.error;
                e.op = OpKind.resolve;
                e.code = s;
                return e;
            }
            if (depth == opened.length)
                break;
            opened[depth++] = next.value.raw;
            cur = next.value.raw;
        }
        return ntError(s, OpKind.resolve);
    }

private:

    enum ULONG directoryAccess = FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES
        | SYNCHRONIZE;
    enum ULONG directoryOptions = FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT
        | FILE_OPEN_FOR_BACKUP_INTENT | FILE_SYNCHRONOUS_IO_NONALERT;
    enum ULONG deleteAccess = DELETE | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | SYNCHRONIZE;
    enum ULONG deleteOptions = FILE_OPEN_REPARSE_POINT | FILE_OPEN_FOR_BACKUP_INTENT
        | FILE_SYNCHRONOUS_IO_NONALERT;
    enum ULONG readAccess = READ_CONTROL | FILE_READ_DATA | FILE_READ_EA;
    enum ULONG writeAccess = FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_ATTRIBUTES
        | FILE_WRITE_EA;

    static shared bool resolverAbsent;

    IoResult!Handle openDirectory(Handle dir, scope const(char)[] name, ULONG access)
        @safe nothrow @nogc
    {
        size_t h;
        const s = ntOpenName(dir.raw, name, access, directoryOptions, FILE_OPEN, null, h);
        if (!ntSuccess(s))
        {
            // VFN2/VFN7: a file link is not a directory object; ask which it is.
            if (s == STATUS_NOT_A_DIRECTORY && isLinkAt(dir, name))
                return ioErr!Handle(ErrorKind.symlinkRefused, OpKind.openAt, s);
            return ioErr!Handle(ntError(s, OpKind.openAt));
        }
        if (isLinkHandle(h))
        {
            close(Handle(h));
            return ioErr!Handle(ErrorKind.symlinkRefused, OpKind.openAt);
        }
        return ioOk(Handle(h));
    }

    // Whether the open handle is a name-surrogate reparse point (VFN7).
    bool isLinkHandle(size_t h) @safe nothrow @nogc
    {
        FILE_ATTRIBUTE_TAG_INFORMATION tag;
        IO_STATUS_BLOCK io;
        const s = (() @trusted => NtQueryInformationFile(cast(HANDLE) h, &io, &tag, tag.sizeof,
            FileAttributeTagInformation))();
        return ntSuccess(s) && (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
            && (tag.ReparseTag & REPARSE_TAG_NAME_SURROGATE);
    }

    bool isLinkAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
    {
        size_t h;
        const s = ntOpenName(dir.raw, name, FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_OPEN_REPARSE_POINT | FILE_OPEN_FOR_BACKUP_INTENT | FILE_SYNCHRONOUS_IO_NONALERT,
            FILE_OPEN, null, h);
        if (!ntSuccess(s))
            return false;
        scope (exit) close(Handle(h));
        return isLinkHandle(h);
    }

    EntryKind kindOf(size_t h) @safe nothrow @nogc
    {
        FILE_ATTRIBUTE_TAG_INFORMATION tag;
        IO_STATUS_BLOCK io;
        const s = (() @trusted => NtQueryInformationFile(cast(HANDLE) h, &io, &tag, tag.sizeof,
            FileAttributeTagInformation))();
        if (!ntSuccess(s))
            return EntryKind.unknown;
        if ((tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
            && (tag.ReparseTag & REPARSE_TAG_NAME_SURROGATE))
            return EntryKind.symlink;
        return (tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? EntryKind.directory
            : EntryKind.regular;
    }

    bool isDirectoryRelative(Handle dir, scope const(wchar)[] target) @safe nothrow @nogc
    {
        size_t h;
        const s = ntOpen(dir.raw, target, FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_OPEN_FOR_BACKUP_INTENT | FILE_SYNCHRONOUS_IO_NONALERT, 0, FILE_OPEN, null, h);
        if (!ntSuccess(s))
            return false;
        scope (exit) close(Handle(h));
        return kindOf(h) == EntryKind.directory;
    }

    // VFN13: delete through the handle with POSIX semantics; fall back to the
    // classic disposition; retry sharing violations and not-yet-empty
    // directories up to the limit.
    NTSTATUS deleteHandle(size_t h) @safe nothrow @nogc
    {
        import core.sys.windows.winbase : Sleep;

        NTSTATUS s;
        foreach (attempt; 0 .. windowsDeleteRetries)
        {
            FILE_DISPOSITION_INFORMATION_EX ex;
            ex.Flags = FILE_DISPOSITION_DELETE | FILE_DISPOSITION_POSIX_SEMANTICS
                | FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE;
            IO_STATUS_BLOCK io;
            s = (() @trusted => NtSetInformationFile(cast(HANDLE) h, &io, &ex, ex.sizeof,
                FileDispositionInformationEx))();
            if (s == STATUS_INVALID_PARAMETER || s == STATUS_NOT_SUPPORTED
                || s == STATUS_INVALID_INFO_CLASS)
            {
                clearReadOnly(h);
                FILE_DISPOSITION_INFORMATION classic;
                classic.DeleteFile = 1;
                s = (() @trusted => NtSetInformationFile(cast(HANDLE) h, &io, &classic,
                    classic.sizeof, FileDispositionInformation))();
            }
            if (s != STATUS_SHARING_VIOLATION && s != STATUS_DIRECTORY_NOT_EMPTY)
                return s;
            (() @trusted => Sleep(1))();
        }
        return s;
    }

    // Clears the read-only attribute; true if the entry had it.
    bool clearReadOnly(size_t h) @safe nothrow @nogc
    {
        FILE_BASIC_INFORMATION basic;
        IO_STATUS_BLOCK io;
        if (!ntSuccess((() @trusted => NtQueryInformationFile(cast(HANDLE) h, &io, &basic,
                basic.sizeof, FileBasicInformation))()))
            return false;
        if (!(basic.FileAttributes & FILE_ATTRIBUTE_READONLY))
            return false;
        basic.FileAttributes &= ~FILE_ATTRIBUTE_READONLY;
        if (basic.FileAttributes == 0)
            basic.FileAttributes = FILE_ATTRIBUTE_NORMAL;
        (() @trusted => NtSetInformationFile(cast(HANDLE) h, &io, &basic, basic.sizeof,
            FileBasicInformation))();
        return true;
    }

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

    // OBJ_DONT_REPARSE is refused with STATUS_INVALID_PARAMETER where unsupported.
    static bool probe() @safe nothrow @nogc
    {
        size_t h;
        const s = ntOpen(0, "\\??\\C:\\"w, FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_DIRECTORY_FILE | FILE_OPEN_FOR_BACKUP_INTENT | FILE_SYNCHRONOUS_IO_NONALERT,
            OBJ_DONT_REPARSE, FILE_OPEN, null, h);
        if (ntSuccess(s))
        {
            (() @trusted => NtClose(cast(HANDLE) h))();
            return true;
        }
        return s != STATUS_INVALID_PARAMETER;
    }
}

// ---------------------------------------------------------------- helpers

private:

/// Converts UTF-8 to UTF-16 into `w`; `size_t.max` if it does not fit.
size_t wide(scope const(char)[] s, scope wchar[] w) @safe nothrow @nogc
{
    auto n = utf8ToUtf16(s, w);
    return n.hasError ? size_t.max : n.value;
}

NTSTATUS ntOpenName(size_t root, scope const(char)[] name, ULONG access, ULONG options,
    ULONG disposition, scope void* sd, out size_t handle) @safe nothrow @nogc
{
    wchar[256] w;
    const n = wide(name, w[]);
    if (n == size_t.max)
        return STATUS_NAME_TOO_LONG;
    return ntOpen(root, w[0 .. n], access, options, 0, disposition, sd, handle);
}

NTSTATUS ntOpen(size_t root, scope const(wchar)[] name, ULONG access, ULONG options,
    ULONG attributes, ULONG disposition, scope void* sd, out size_t handle) @trusted nothrow @nogc
{
    UNICODE_STRING u;
    u.Length = cast(USHORT)(name.length * 2);
    u.MaximumLength = u.Length;
    u.Buffer = cast(wchar*) name.ptr;
    OBJECT_ATTRIBUTES oa;
    oa.Length = OBJECT_ATTRIBUTES.sizeof;
    oa.RootDirectory = cast(HANDLE) root;
    oa.ObjectName = &u;
    oa.Attributes = OBJ_CASE_INSENSITIVE | attributes;
    oa.SecurityDescriptor = sd;
    IO_STATUS_BLOCK io;
    HANDLE h;
    const s = NtCreateFile(&h, access, &oa, &io, null, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_ALL,
        disposition, options, null, 0);
    handle = cast(size_t) h;
    return s;
}

/// The print name of a symbolic-link or junction reparse buffer, or null.
const(wchar)[] reparseTarget(return scope ubyte[] data) @system nothrow @nogc
{
    const tag = *cast(uint*) data.ptr;
    if (!(tag & REPARSE_TAG_NAME_SURROGATE))
        return null;
    const header = cast(ushort*)(data.ptr + 8);
    const substituteOffset = header[0], substituteLength = header[1];
    const printOffset = header[2], printLength = header[3];
    const pathBuffer = tag == IO_REPARSE_TAG_SYMLINK ? data.ptr + 20 : data.ptr + 16;
    const offset = printLength ? printOffset : substituteOffset;
    const length = printLength ? printLength : substituteLength;
    return (cast(const(wchar)*)(pathBuffer + offset))[0 .. length / 2];
}

/// Fills a relative symbolic-link reparse buffer; returns its length.
size_t symlinkReparseData(scope ubyte[] data, scope const(wchar)[] target) @system nothrow @nogc
{
    const bytes = cast(ushort)(target.length * 2);
    *cast(uint*) data.ptr = IO_REPARSE_TAG_SYMLINK;
    *cast(ushort*)(data.ptr + 4) = cast(ushort)(12 + 2 * bytes);
    *cast(ushort*)(data.ptr + 6) = 0;
    auto header = cast(ushort*)(data.ptr + 8);
    header[0] = 0;          // substitute name offset
    header[1] = bytes;      // substitute name length
    header[2] = bytes;      // print name offset
    header[3] = bytes;      // print name length
    *cast(uint*)(data.ptr + 16) = SYMLINK_FLAG_RELATIVE;
    auto names = cast(wchar*)(data.ptr + 20);
    names[0 .. target.length] = target[];
    names[target.length .. 2 * target.length] = target[];
    return 20 + 2 * bytes;
}

/// A protected DACL that admits only the process's user (VFN12).
struct OwnerOnlyDescriptor
{
    import core.sys.windows.winbase : AddAccessAllowedAceEx, GetCurrentProcess, GetTokenInformation,
        InitializeAcl, InitializeSecurityDescriptor, OpenProcessToken,
        SetSecurityDescriptorControl, SetSecurityDescriptorDacl;
    import core.sys.windows.winnt : ACL, ACL_REVISION, GENERIC_ALL, SECURITY_DESCRIPTOR,
        SECURITY_DESCRIPTOR_REVISION, SE_DACL_PROTECTED, TOKEN_INFORMATION_CLASS, TOKEN_QUERY,
        TOKEN_USER;

    ubyte[256] user;
    ubyte[512] acl;
    SECURITY_DESCRIPTOR sd;

    void* build() return @trusted nothrow @nogc
    {
        HANDLE token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
            return null;
        scope (exit) NtClose(token);
        DWORD got;
        if (!GetTokenInformation(token, TOKEN_INFORMATION_CLASS.TokenUser, user.ptr,
                cast(DWORD) user.length, &got))
            return null;
        auto sid = (cast(TOKEN_USER*) user.ptr).User.Sid;
        auto a = cast(ACL*) acl.ptr;
        if (!InitializeAcl(a, cast(DWORD) acl.length, ACL_REVISION)
            || !AddAccessAllowedAceEx(a, ACL_REVISION, 0, GENERIC_ALL, sid)
            || !InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION)
            || !SetSecurityDescriptorDacl(&sd, 1, a, 0)
            || !SetSecurityDescriptorControl(&sd, SE_DACL_PROTECTED, SE_DACL_PROTECTED))
            return null;
        return &sd;
    }
}

IoError win32Error(OpKind op) @trusted nothrow @nogc
{
    import core.sys.windows.winbase : GetLastError;
    import core.sys.windows.winerror : ERROR_ACCESS_DENIED, ERROR_ALREADY_EXISTS, ERROR_DIRECTORY,
        ERROR_DIR_NOT_EMPTY, ERROR_FILE_EXISTS, ERROR_FILE_NOT_FOUND, ERROR_FILENAME_EXCED_RANGE,
        ERROR_INVALID_NAME, ERROR_PATH_NOT_FOUND, ERROR_SHARING_VIOLATION;

    const e = GetLastError();
    ErrorKind k;
    switch (e)
    {
        case ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND: k = ErrorKind.notFound; break;
        case ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS: k = ErrorKind.exists; break;
        case ERROR_DIRECTORY: k = ErrorKind.notADirectory; break;
        case ERROR_DIR_NOT_EMPTY: k = ErrorKind.notEmpty; break;
        case ERROR_ACCESS_DENIED: k = ErrorKind.permission; break;
        case ERROR_SHARING_VIOLATION: k = ErrorKind.busy; break;
        case ERROR_INVALID_NAME: k = ErrorKind.invalidName; break;
        case ERROR_FILENAME_EXCED_RANGE: k = ErrorKind.nameTooLong; break;
        default: k = ErrorKind.other; break;
    }
    return IoError(k, cast(int) e, op);
}

/// The portable kind of an `NTSTATUS` (VFN1, VFN2).
IoError ntError(NTSTATUS s, OpKind op) @safe pure nothrow @nogc
{
    ErrorKind k;
    switch (s)
    {
        case STATUS_OBJECT_NAME_NOT_FOUND, STATUS_OBJECT_PATH_NOT_FOUND, STATUS_NO_SUCH_FILE,
            STATUS_DELETE_PENDING, STATUS_FILE_DELETED:
            k = ErrorKind.notFound; break;
        case STATUS_OBJECT_NAME_COLLISION: k = ErrorKind.exists; break;
        case STATUS_NOT_A_DIRECTORY: k = ErrorKind.notADirectory; break;
        case STATUS_FILE_IS_A_DIRECTORY: k = ErrorKind.isADirectory; break;
        case STATUS_DIRECTORY_NOT_EMPTY: k = ErrorKind.notEmpty; break;
        case STATUS_ACCESS_DENIED, STATUS_CANNOT_DELETE: k = ErrorKind.permission; break;
        case STATUS_SHARING_VIOLATION: k = ErrorKind.busy; break;
        case STATUS_OBJECT_NAME_INVALID: k = ErrorKind.invalidName; break;
        case STATUS_NAME_TOO_LONG: k = ErrorKind.nameTooLong; break;
        case STATUS_REPARSE_POINT_ENCOUNTERED: k = ErrorKind.symlinkRefused; break;
        default: k = ErrorKind.other; break;
    }
    return IoError(k, s, op);
}
