/**
POSIX declarations the capability VFS's blocking backend needs and druntime
lacks: `openat2(2)` on Linux, `fdopendir`, and the open flags druntime does
not define for every platform (`O_DIRECTORY`, `O_CLOEXEC`, `O_SEARCH`,
`O_NOFOLLOW_ANY` on Darwin).
*/
module sparkles.event_horizon.sys.posix;

version (Posix):

// `Darwin` is not predefined; druntime declares it from these, and so do we.
version (OSX) version = Darwin;
else version (iOS) version = Darwin;
else version (TVOS) version = Darwin;
else version (WatchOS) version = Darwin;

public import core.sys.posix.dirent : DIR, closedir, dirent, readdir;
public import core.sys.posix.fcntl : AT_FDCWD, AT_REMOVEDIR, AT_SYMLINK_NOFOLLOW, O_CREAT,
    O_EXCL, O_NOFOLLOW, O_RDONLY, O_RDWR, O_TRUNC, O_WRONLY, O_APPEND, openat;
public import core.sys.posix.sys.stat : fstat, fstatat, mkdirat, stat_t, S_IFMT, S_IFDIR,
    S_IFREG, S_IFLNK;
public import core.sys.posix.unistd : close, fsync, read, readlinkat, symlinkat, unlinkat, write;
public import core.sys.posix.stdio : renameat;

version (linux)
{
    public import core.sys.posix.fcntl : O_CLOEXEC, O_DIRECTORY, O_PATH;

    /// `open_how` of `openat2(2)`.
    struct OpenHow
    {
        ulong flags;   ///
        ulong mode;    ///
        ulong resolve; ///
    }

    /// `resolve` flags of `openat2(2)`.
    enum ulong RESOLVE_NO_XDEV = 0x01;
    /// ditto
    enum ulong RESOLVE_NO_MAGICLINKS = 0x02;
    /// ditto
    enum ulong RESOLVE_NO_SYMLINKS = 0x04;
    /// ditto
    enum ulong RESOLVE_BENEATH = 0x08;

    /// `openat2` has the same number on every architecture (asm-generic).
    enum long SYS_openat2 = 437;

    /// Calls `openat2(2)`; returns the descriptor, or -1 with `errno` set.
    int openat2(int dirfd, scope const(char)* path, ref const OpenHow how) @system nothrow @nogc
    {
        import core.sys.linux.unistd : syscall;

        return cast(int) syscall(SYS_openat2, dirfd, path, &how, OpenHow.sizeof);
    }

    /// The flag that opens a directory for search only (VFN14).
    enum int searchOnlyFlag = O_PATH | O_DIRECTORY;
}
else version (Darwin)
{
    enum int O_DIRECTORY = 0x00100000; ///
    enum int O_CLOEXEC = 0x01000000;   ///
    enum int O_EXEC = 0x40000000;      ///
    enum int O_SEARCH = O_EXEC | O_DIRECTORY; ///
    /// Refuses a symbolic link in any component of the path (macOS 11+).
    enum int O_NOFOLLOW_ANY = 0x20000000;

    /// ditto
    enum int searchOnlyFlag = O_SEARCH;
}
else version (FreeBSD)
{
    public import core.sys.posix.fcntl : O_CLOEXEC, O_DIRECTORY;

    enum int O_EXEC = 0x00040000;   ///
    enum int O_SEARCH = O_EXEC;     ///
    /// ditto
    enum int searchOnlyFlag = O_SEARCH | O_DIRECTORY;
}
else
{
    public import core.sys.posix.fcntl : O_CLOEXEC, O_DIRECTORY;

    /// No search-only open: the walk falls back to read access.
    enum int searchOnlyFlag = 0;
}

version (OSX)
{
    version (X86_64)
    {
        pragma(mangle, "fdopendir$INODE64")
        extern (C) DIR* fdopendir(int fd) nothrow @nogc @system;
    }
    else
        extern (C) DIR* fdopendir(int fd) nothrow @nogc @system;
}
else
    extern (C) DIR* fdopendir(int fd) nothrow @nogc @system; ///
