/**
Direct-style file-system verbs (SPEC §7.3, PLAN M7): open/close/fsync/statx
through the ring — the proactor's headline win over readiness models, where
regular files have no readiness and fall to thread pools.

Loop-side module (the capability concept + test double join `live`/`Env` in
M9). Pointer operands (paths, the statx out-buffer) live on the parked
verb's frame — the kernel-stable rule discharged by the §6.5 argument.
*/
module sparkles.event_horizon.fs;

version (linux)  :  // rides the linux Sched; generalizes with M10

import sparkles.event_horizon.errors;
import sparkles.event_horizon.io : FileHandle;
import sparkles.event_horizon.op;
import sparkles.event_horizon.sched : Sched;

/// `AT_FDCWD`: resolve relative paths against the working directory.
enum int atFdCwd = -100;

/// A `struct statx` mirror (kernel UAPI layout, 256 bytes).
struct Statx
{
    uint stx_mask;            /// which fields the kernel filled
    uint stx_blksize;         /// preferred I/O block size
    ulong stx_attributes;     /// file attributes
    uint stx_nlink;           /// hard links
    uint stx_uid;             /// owner
    uint stx_gid;             /// group
    ushort stx_mode;          /// type + permissions
    ushort[1] __spare0;
    ulong stx_ino;            /// inode
    ulong stx_size;           /// size in bytes
    ulong stx_blocks;         /// 512B blocks allocated
    ulong stx_attributes_mask; /// which attributes are supported
    StatxTimestamp stx_atime; /// access
    StatxTimestamp stx_btime; /// birth
    StatxTimestamp stx_ctime; /// change
    StatxTimestamp stx_mtime; /// modify
    uint stx_rdev_major;      /// device (special files)
    uint stx_rdev_minor;      /// ditto
    uint stx_dev_major;       /// containing device
    uint stx_dev_minor;       /// ditto
    ulong stx_mnt_id;         /// mount id
    uint stx_dio_mem_align;   /// direct-IO alignment
    uint stx_dio_offset_align; /// ditto
    ulong[12] __spare3;
}

static assert(Statx.sizeof == 256);

/// One statx timestamp.
struct StatxTimestamp
{
    long tv_sec;  /// seconds
    uint tv_nsec; /// nanoseconds
    int __reserved;
}

/// `STATX_BASIC_STATS`.
enum uint statxBasicStats = 0x7FF;

/**
Opens `path` (relative paths resolve against the cwd); parks until the
completion delivers the fd. `flags`/`mode` are the `open(2)` values
(`O_RDONLY` etc. from `core.sys.posix.fcntl`).
*/
IoResult!FileHandle openFile(ref Sched s, scope const(char)[] path, int flags,
    uint mode = 0)
{
    // NUL-terminate on this frame — kernel-stable while parked (§6.5).
    char[4096] zpath = void;
    if (path.length >= zpath.length)
        return ioErr!FileHandle(36 /* ENAMETOOLONG */, OpKind.openAt,
            IoErrorStage.submit, "path too long");
    zpath[0 .. path.length] = path[];
    zpath[path.length] = '\0';

    auto o = s.await(OpOpenAt(atFdCwd, (() @trusted => zpath.ptr)(), flags, mode));
    if (o.res < 0)
        return ioErr!FileHandle(-o.res, OpKind.openAt);
    return ioOk(FileHandle(o.res));
}

/// Closes the handle through the ring.
IoResult!void closeFile(ref Sched s, ref FileHandle f)
{
    auto o = s.await(OpClose(f.fd));
    f.fd = -1;
    if (o.res < 0)
        return ioErr!void(-o.res, OpKind.close);
    return ioOk();
}

/// Flushes the file to storage.
IoResult!void fsyncFile(ref Sched s, FileHandle f)
{
    auto o = s.await(OpFsync(f.fd));
    if (o.res < 0)
        return ioErr!void(-o.res, OpKind.fsync);
    return ioOk();
}

/// Stats `path` into `out_` (basic stats by default).
IoResult!void statxPath(ref Sched s, scope const(char)[] path, ref Statx out_,
    uint mask = statxBasicStats)
{
    char[4096] zpath = void;
    if (path.length >= zpath.length)
        return ioErr!void(36 /* ENAMETOOLONG */, OpKind.statx,
            IoErrorStage.submit, "path too long");
    zpath[0 .. path.length] = path[];
    zpath[path.length] = '\0';

    auto o = s.await(OpStatx(atFdCwd, (() @trusted => zpath.ptr)(), 0, mask,
        (() @trusted => cast(void*) &out_)()));
    if (o.res < 0)
        return ioErr!void(-o.res, OpKind.statx);
    return ioOk();
}

@("fs.roundTrip.openWriteFsyncStatxRead")
@safe
unittest
{
    import core.lifetime : move;
    import core.sys.posix.fcntl : O_CREAT, O_RDONLY, O_TRUNC, O_WRONLY;
    import std.conv : octal;

    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.event_horizon.io : read, write;

    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP: io_uring unavailable
    scope (exit) s.destroy();

    static immutable payload = cast(immutable ubyte[]) "event horizon fs";
    enum path = "/tmp/sparkles-event-horizon-fs-test.txt";

    auto r = s.run(() {
        // Create + write + fsync + close — all through the ring.
        auto created = openFile(s, path, O_CREAT | O_WRONLY | O_TRUNC, octal!600);
        assert(created.hasValue);
        auto f = created.value;

        SmallBuffer!(ubyte, 64) out_;
        out_ ~= payload[];
        auto wrote = write(f, move(out_), 0);
        assert(!wrote.res.hasError && wrote.res.value == payload.length);
        assert(!fsyncFile(s, f).hasError);
        assert(!closeFile(s, f).hasError);

        // statx sees the size.
        Statx st;
        assert(!statxPath(s, path, st).hasError);
        assert(st.stx_size == payload.length);

        // Read it back.
        auto opened = openFile(s, path, O_RDONLY);
        assert(opened.hasValue);
        auto rd = opened.value;
        SmallBuffer!(ubyte, 64) in_;
        in_.length = 64;
        auto got = read(rd, move(in_), 0);
        assert(!got.res.hasError && got.res.value == payload.length);
        assert(got.buf[][0 .. got.res.value] == payload[]);
        assert(!closeFile(s, rd).hasError);
    });
    assert(!r.hasError);

    // Tidy the fixture (plain libc; the test is about the ring path).
    (() @trusted {
        import core.sys.posix.unistd : unlink;

        unlink(path);
    })();
}
