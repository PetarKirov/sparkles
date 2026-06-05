#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_openat_statx_close"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` as a general async-syscall surface — `OPENAT` + `STATX` + `READ` +
 * `CLOSE` (Linux 5.6).
 *
 * Linux 5.6 turned `io_uring` from an I/O-on-already-open-fds engine into a
 * general asynchronous syscall surface: filesystem operations that previously
 * had no async form — opening a path, stat-ing it, closing an fd — became plain
 * SQE opcodes. This example chains the four of them to read a file end to end
 * without ever issuing a synchronous open/stat/read/close:
 *
 *   1. write a known file under `/tmp` synchronously (libc) to have something to open;
 *   2. `OPENAT(AT_FDCWD, path, O_RDONLY)` — the completion's `res` is the new fd;
 *   3. `STATX(fd, "", AT_EMPTY_PATH, STATX_SIZE)` — verify the file size;
 *   4. `READ(fd, buf, 0)` — verify the bytes round-trip;
 *   5. `CLOSE(fd)` — release it through the ring.
 *
 * Each step is its own submit/wait: `OPENAT`'s result fd is the input to the
 * following ops, so they cannot be batched into one independent submission.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 * § "5.6 — The filesystem/syscall expansion (March 2020)".
 *
 * Run with: `dub run --single openat-statx-close.d`
 *
 * Portability: prints a `SKIP:` line and exits 0 when `io_uring` is unavailable
 * (old kernel / sandbox) or when any of these 5.6 ops is unsupported, so it stays
 * green in CI regardless of the host kernel.
 */
module io_uring_openat_statx_close;

import during;

import core.sys.posix.fcntl : AT_FDCWD, O_CREAT, O_RDONLY, O_WRONLY, open;
import core.sys.posix.unistd : close, unlink, write;

import std.stdio : stderr, writefln;
import std.string : toStringz;

// ABI-stable constants the kernel uses but druntime does not surface here.
enum int AT_EMPTY_PATH = 0x1000; // statx() on an open fd with an empty path
enum uint STATX_SIZE = 0x0000_0200; // request stx_size in the result mask

// Minimal mirror of the kernel `struct statx` (256 bytes, ABI-stable). We only
// read `stx_size`, which lives at byte offset 40; the rest is padding we never
// touch. `prepStatx` takes the buffer generically, so any 256-byte struct with
// the field at the right offset works.
struct Statx
{
    uint stx_mask; // 0
    uint stx_blksize; // 4
    ulong stx_attributes; // 8
    uint stx_nlink; // 16
    uint stx_uid; // 20
    uint stx_gid; // 24
    ushort stx_mode; // 28
    ushort[1] _spare0; // 30
    ulong stx_ino; // 32
    ulong stx_size; // 40 -- the only field we assert on
    ubyte[256 - 48] _rest; // 48.. -- timestamps, dev numbers, future fields
}

static assert(Statx.stx_size.offsetof == 40, "stx_size must sit at the kernel ABI offset");
static assert(Statx.sizeof >= 256, "statx buffer must cover the full kernel struct");

int main()
{
    // The file we will open/stat/read through the ring.
    enum string path = "/tmp/io_uring_openat_statx_close.txt";
    immutable(ubyte)[] payload = cast(immutable(ubyte)[]) "io_uring touched the filesystem\n";

    // --- Step 1: create the test file synchronously (plain libc). -----------
    {
        const wfd = open(path.toStringz, O_CREAT | O_WRONLY, octal!"600");
        if (wfd < 0)
        {
            writefln("SKIP: could not create %s (errno %d)", path, errnoOf(wfd));
            return 0;
        }
        const wrote = write(wfd, payload.ptr, payload.length);
        close(wfd);
        if (wrote != payload.length)
        {
            stderr.writefln("setup write short: %d of %d bytes", wrote, payload.length);
            return 1;
        }
    }
    scope (exit) unlink(path.toStringz);

    // --- Ring setup. --------------------------------------------------------
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // The filesystem ops all arrived together in 5.6; probe one representative
    // op up front so a pre-5.6 kernel skips cleanly rather than erroring mid-chain.
    auto probe = io.probe();
    if (cast(bool) probe && !probe.isSupported(Operation.OPENAT))
    {
        writefln("SKIP: IORING_OP_OPENAT unsupported on this kernel (pre-5.6)");
        return 0;
    }

    // --- Step 2: OPENAT — the completion res is the freshly opened fd. ------
    auto cpath = path.toStringz; // keep the C string alive across the submit
    io.putWith!((ref SubmissionEntry e, const(char)* p) {
        e.prepOpenat(AT_FDCWD, p, O_RDONLY, 0);
        e.user_data = 1;
    })(cpath);
    if (io.submit(1) < 0)
        return fail("submit OPENAT");
    io.wait(1);
    const openRes = io.front.res;
    io.popFront();
    if (isUnsupported(openRes))
    {
        writefln("SKIP: OPENAT returned %d (op unsupported on this kernel)", openRes);
        return 0;
    }
    if (openRes < 0)
        return failErr("OPENAT", openRes);
    const fd = openRes; // the async-opened fd, used by the next ops

    // From here a failure leaks the fd unless we close it; do that on any early return.
    scope (failure) close(fd);

    // --- Step 3: STATX on the open fd (empty path + AT_EMPTY_PATH). ---------
    Statx stx;
    io.putWith!((ref SubmissionEntry e, int f, Statx* sb) {
        // Empty path + AT_EMPTY_PATH means "stat the fd itself", like fstat().
        e.prepStatx(f, emptyCString, AT_EMPTY_PATH, STATX_SIZE, *sb);
        e.user_data = 2;
    })(fd, &stx);
    if (io.submit(1) < 0)
        return failClose(fd, "submit STATX");
    io.wait(1);
    const statxRes = io.front.res;
    io.popFront();
    if (isUnsupported(statxRes))
    {
        close(fd);
        writefln("SKIP: STATX returned %d (op unsupported on this kernel)", statxRes);
        return 0;
    }
    if (statxRes < 0)
    {
        close(fd);
        return failErr("STATX", statxRes);
    }
    if (stx.stx_size != payload.length)
    {
        close(fd);
        stderr.writefln("STATX size mismatch: expected %d, got %d", payload.length, stx.stx_size);
        return 1;
    }

    // --- Step 4: READ the whole file through the ring and verify content. ---
    ubyte[128] readBuf;
    io.putWith!((ref SubmissionEntry e, int f, ubyte[] b) {
        e.prepRead(f, b, 0);
        e.user_data = 3;
    })(fd, readBuf[]);
    if (io.submit(1) < 0)
        return failClose(fd, "submit READ");
    io.wait(1);
    const readRes = io.front.res;
    io.popFront();
    if (readRes < 0)
    {
        close(fd);
        return failErr("READ", readRes);
    }
    if (readRes != cast(int) payload.length || readBuf[0 .. payload.length] != payload[])
    {
        close(fd);
        stderr.writefln("READ content mismatch (res=%d)", readRes);
        return 1;
    }

    // --- Step 5: CLOSE the fd through the ring (no scope guard hereafter). ---
    io.putWith!((ref SubmissionEntry e, int f) {
        e.prepClose(f);
        e.user_data = 4;
    })(fd);
    if (io.submit(1) < 0)
        return failClose(fd, "submit CLOSE");
    io.wait(1);
    const closeRes = io.front.res;
    io.popFront();
    if (closeRes < 0)
    {
        close(fd); // ring CLOSE failed; fall back to a synchronous close
        return failErr("CLOSE", closeRes);
    }

    writefln("ok: async OPENAT→STATX(size=%d)→READ(%d bytes)→CLOSE chained through io_uring",
        stx.stx_size, readRes);
    return 0;
}

// --- small helpers ----------------------------------------------------------

// A `const(char)*` to a single NUL byte: an empty C path for STATX-on-fd.
const(char)* emptyCString() @trusted nothrow @nogc
{
    static immutable char[1] empty = ['\0'];
    return &empty[0];
}

// libc syscalls return -1 and set errno; this wrapper environment doesn't read
// errno portably, so for the setup path we just report the raw -1.
int errnoOf(int ret) @safe pure nothrow @nogc => -ret;

// io_uring surfaces "this op doesn't exist on this kernel" as -EINVAL/-EOPNOTSUPP/-ENOSYS.
bool isUnsupported(int res) @safe pure nothrow @nogc
{
    enum int EINVAL = 22, ENOSYS = 38, EOPNOTSUPP = 95;
    return res == -EINVAL || res == -EOPNOTSUPP || res == -ENOSYS;
}

int fail(string what)
{
    stderr.writefln("%s failed", what);
    return 1;
}

int failErr(string op, int res)
{
    stderr.writefln("%s completed with error: errno %d", op, -res);
    return 1;
}

int failClose(int fd, string what)
{
    close(fd);
    return fail(what);
}

// `octal!"600"` — file mode literal computed at compile time.
template octal(string digits)
{
    enum uint octal = parseOctal(digits);
}

uint parseOctal(string s) @safe pure nothrow @nogc
{
    uint v = 0;
    foreach (c; s)
        v = v * 8 + (c - '0');
    return v;
}
