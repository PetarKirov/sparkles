/**
Direct-style file-system verbs (SPEC §7.3, PLAN M7): open/close/fsync/statx
through the ring — the proactor's headline win over readiness models, where
regular files have no readiness and fall to thread pools.

Loop-side module (the capability concept + test double join `live`/`Env` in
M9). Pointer operands (paths, the statx out-buffer) live on the parked
verb's frame — the kernel-stable rule discharged by the §6.5 argument.
*/
module sparkles.event_horizon.fs;

// Gated on the *backend*, not just the platform. These verbs lower onto
// `io_uring`'s fs ops; the kqueue peer lowers none of them, because regular
// files have no readiness and its worker pool is deferred. `version (linux)`
// alone was enough while Linux implied uring — the `libkqueue` configuration
// makes Linux+kqueue selectable, and there `canSubmitOp!(Backend, OpStatx)` is
// false, so every verb here fails to instantiate rather than being absent.
// Empty is the honest answer: the capability genuinely is not there.
version (linux)
{
    version (EventHorizonLibkqueue) {}
    else version = EventHorizonRingFs;
}
version (EventHorizonRingFs)  :  // rides the linux Sched; generalizes with M10

import sparkles.base.text.cstring : CString, tryToCString;

import sparkles.event_horizon.errors;
import sparkles.event_horizon.io : FileHandle;
import sparkles.event_horizon.op;
import sparkles.event_horizon.sched : Sched;

/// `AT_FDCWD`: resolve relative paths against the working directory.
enum int atFdCwd = -100;

/// Common open policies; raw POSIX flags remain available through `openFile`.
enum FileMode
{
    read,
    writeTruncate,
    append,
}

/// Scheduler-bound file capability. Present only on backends implementing the
/// ring filesystem operations. Construction does not open or allocate anything.
struct RingFs
{
    enum capName = "fs";
    private Sched* _sched;

    this(Sched* sched) @safe pure nothrow @nogc { _sched = sched; }

    IoResult!FileHandle open(scope const(char)[] path, FileMode mode = FileMode.read) @system
    {
        import core.sys.posix.fcntl : O_RDONLY, O_WRONLY, O_CREAT, O_TRUNC, O_APPEND, O_CLOEXEC;

        int flags;
        final switch (mode)
        {
            case FileMode.read: flags = O_RDONLY; break;
            case FileMode.writeTruncate: flags = O_WRONLY | O_CREAT | O_TRUNC; break;
            case FileMode.append: flags = O_WRONLY | O_CREAT | O_APPEND; break;
        }
        return openFile(*_sched, path, flags | O_CLOEXEC, 0x180 /* 0600 */);
    }

    /// Executes the body with a borrowed handle, then closes under cancellation
    /// protection. The body must join users before returning and must not retain
    /// or close a copy. Body failure wins over close failure; a successful body
    /// reports a close failure. Escaped defects still close and propagate.
    /// Lexical cleanup uses no scope onExit slot and never parks in a destructor.
    auto withFile(F)(scope const(char)[] path, scope F body, FileMode mode = FileMode.read)
    {
        import std.traits : ReturnType;
        import sparkles.event_horizon.scope_ : protect;

        alias R = ReturnType!F;
        auto opened = open(path, mode);
        if (opened.hasError)
        {
            import std.traits : TemplateArgsOf;
            return ioErr!(TemplateArgsOf!R[0])(opened.error);
        }
        auto file = opened.value;
        // Fallback on exceptional unwind only. Normal close happens below so
        // its result can be returned. FileHandle.close is a synchronous fallback.
        scope(exit) file.close();
        auto result = () {
            try return body(file);
            catch (Throwable error)
            {
                // Error unwinding can elide scope(exit) in nothrow frames.
                file.close();
                throw error;
            }
        }();
        auto closed = protect!(() => closeFile(*_sched, file))(*_sched);
        if (!result.hasError && closed.hasError)
        {
            import std.traits : TemplateArgsOf;
            return ioErr!(TemplateArgsOf!R[0])(closed.error);
        }
        return result;
    }

    /// Reads and closes a file with an explicit byte bound. GC-allocating,
    /// byte-preserving convenience; see `transfer.readText`.
    IoResult!string readText(scope const(char)[] path, size_t maxBytes) @system
    {
        import sparkles.event_horizon.transfer : readText;

        return withFile(path, (ref FileHandle file) => readText(file, maxBytes));
    }
}

@("fs.capability.boundedTextAndScopedClose") @system unittest
{
    import core.stdc.errno : EFBIG, EIO;
    import core.sys.posix.fcntl : fcntl, F_GETFD;
    import std.stdio : File;
    import sparkles.event_horizon.sched : schedOrSkip;

    // /proc/self/fd gives a stable, isolated fixture path without a named temp
    // file; this module and its tests are Linux-only.
    auto fixture = File.tmpfile();
    fixture.rawWrite("hello");
    fixture.flush();
    import std.conv : to;
    const path = "/proc/self/fd/" ~ fixture.fileno.to!string;
    Sched sched;
    schedOrSkip(sched);
    scope(exit) sched.destroy();
    auto ran = sched.run(() {
        auto fs = RingFs(&sched);
        assert(fs.readText(path, 5).value == "hello");
        assert(fs.readText(path, 4).error.errnoValue == EFBIG);
        assert(fs.readText(path, 0).error.errnoValue == EFBIG);
        assert(fs.readText(path ~ "-missing", 5).hasError);
        int borrowed = -1;
        auto failed = fs.withFile(path, (ref FileHandle file) {
            borrowed = file.fd;
            return ioErr!void(EIO, OpKind.read);
        });
        assert(failed.error.errnoValue == EIO);
        assert(fcntl(borrowed, F_GETFD) == -1);
    });
    assert(!ran.hasError);
}

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
    // NUL-terminate on this frame — kernel-stable while parked (§6.5). The
    // CString lives on the same frame the raw array did, so the operand stays
    // valid for exactly as long; it just owns the `= void` and the bound.
    CString!4096 zpath;
    if (!tryToCString(zpath, [path]))
        return ioErr!FileHandle(36 /* ENAMETOOLONG */, OpKind.openAt,
            IoErrorStage.submit, "path too long");

    auto o = s.await(OpOpenAt(atFdCwd, zpath.ptr, flags, mode));
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
    CString!4096 zpath;
    if (!tryToCString(zpath, [path]))
        return ioErr!void(36 /* ENAMETOOLONG */, OpKind.statx,
            IoErrorStage.submit, "path too long");

    auto o = s.await(OpStatx(atFdCwd, zpath.ptr, 0, mask,
        (() @trusted => cast(void*) &out_)()));
    if (o.res < 0)
        return ioErr!void(-o.res, OpKind.statx);
    return ioOk();
}

version (unittest)
{
    import sparkles.event_horizon.sched : schedOrSkip;
}

@("fs.roundTrip.openWriteFsyncStatxRead")
@safe
unittest
{
    import core.lifetime : move;
    import core.sys.posix.fcntl : O_CREAT, O_RDONLY, O_TRUNC, O_WRONLY;
    import std.conv : octal;

    import sparkles.base.buffer : SharedBuffer;
    import sparkles.event_horizon.io : read, write;

    Sched s;
    schedOrSkip(s);

    static immutable payload = cast(immutable ubyte[]) "event horizon fs";
    enum path = "/tmp/sparkles-event-horizon-fs-test.txt";

    auto r = s.run(() {
        // Create + write + fsync + close — all through the ring.
        auto created = openFile(s, path, O_CREAT | O_WRONLY | O_TRUNC, octal!600);
        assert(created.hasValue);
        auto f = created.value;

        SharedBuffer!(ubyte, 64) out_;
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
        SharedBuffer!(ubyte, 64) in_;
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
