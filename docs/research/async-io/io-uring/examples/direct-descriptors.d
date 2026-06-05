#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_direct_descriptors"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — direct (registered) descriptors + `FIXED_FD_INSTALL`
 * (`IORING_OP_OPENAT` direct-open, Linux 5.15; `FIXED_FD_INSTALL`, Linux 6.8).
 *
 * Direct descriptors live in the ring's registered-files table instead of the
 * process fd table: a direct `openat` deposits the kernel file object straight
 * into a table slot and never allocates a userspace fd. Ops then address that
 * slot *by index* with the `IOSQE_FIXED_FILE` flag, which skips the per-op fd
 * lookup/refcount and removes the open-file from `/proc/<pid>/fd`. This example
 * walks the full life cycle:
 *
 *   1. `registerFiles([-1])` reserves one sparse (empty) slot in the table.
 *   2. `OPENAT_DIRECT` opens a temp file straight into slot 0 (no process fd).
 *   3. A `READ` addresses slot 0 via index 0 + `FIXED_FILE` — proving the file
 *      is usable purely by table index.
 *   4. `FIXED_FD_INSTALL` (6.8) materializes slot 0 back into a *real* process
 *      fd, returned in the CQE `res`; a plain libc `read()` through it confirms.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.15 — More filesystem ops, worker caps (October 2021)" (direct descriptors)
 *   and § "6.8 — Fixed-fd install, pbuf status (March 2024)" (FIXED_FD_INSTALL).
 *
 * Run with: `dub run --single direct-descriptors.d`
 *
 * Portability: if `io_uring` is unavailable, registered files / direct open are
 * unsupported, or `FIXED_FD_INSTALL` is missing (pre-6.8), the program prints a
 * `SKIP:` line and exits 0 so it stays green in CI regardless of host kernel.
 */
module io_uring_direct_descriptors;

import during;

import std.stdio : writefln, stderr;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS, EPERM;
import core.sys.linux.fcntl : AT_FDCWD, O_CREAT, O_RDONLY, O_WRONLY;
import core.sys.posix.unistd : close, read, unlink, write;

// The eight payload bytes we write to the temp file and expect to read back —
// twice: once through the registered slot, once through the installed real fd.
private static immutable ubyte[8] payload = [10, 20, 30, 40, 50, 60, 70, 80];

// `true` for the transient "feature not available on this kernel" errnos, so a
// missing capability becomes a clean SKIP rather than a hard failure.
private bool unsupported(int res) @safe pure nothrow @nogc
{
    return res == -EINVAL || res == -EOPNOTSUPP || res == -ENOSYS || res == -EPERM;
}

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Reserve a single *sparse* slot: -1 means "empty", ready to receive a
    // direct-opened file. The table must exist before OPENAT_DIRECT can target it.
    int[1] sparse = -1;
    const regRet = io.registerFiles(sparse[]);
    if (regRet != 0)
    {
        if (unsupported(regRet))
        {
            writefln("SKIP: registerFiles unsupported (errno %d)", -regRet);
            return 0;
        }
        stderr.writefln("registerFiles failed: errno %d", -regRet);
        return 1;
    }
    scope (exit) io.unregisterFiles();

    // Create a temp file with the known payload using ordinary libc I/O, then
    // close it — io_uring will reopen it directly into the table.
    enum string path = "/tmp/io_uring_direct_descriptors_demo\0";
    {
        const fd = openFile(path.ptr);
        if (fd < 0)
        {
            stderr.writefln("could not create temp file");
            return 1;
        }
        const w = write(fd, &payload[0], payload.length);
        close(fd);
        if (w != payload.length)
        {
            stderr.writefln("short write to temp file (%d)", w);
            return 1;
        }
    }
    scope (exit) unlink(path.ptr);

    // --- Step 1: OPENAT_DIRECT — open straight into registered slot 0. ---------
    // No process fd is allocated; the file object lands in the files table only.
    io.putWith!((ref SubmissionEntry e, const(char)* p) {
        e.prepOpenatDirect(AT_FDCWD, p, O_RDONLY, 0, /*fileIndex=*/ 0);
        e.user_data = 1;
    })(path.ptr);
    if (io.submit(1) != 1) { stderr.writefln("submit (open) failed"); return 1; }
    io.wait(1);
    {
        const res = io.front.res;
        io.popFront();
        if (unsupported(res))
        {
            writefln("SKIP: OPENAT_DIRECT unsupported (errno %d)", -res);
            return 0;
        }
        if (res != 0)
        {
            stderr.writefln("OPENAT_DIRECT failed: errno %d", -res);
            return 1;
        }
    }

    // --- Step 2: READ addressing slot 0 by index, with the FIXED_FILE flag. ----
    // The "fd" we pass is the *table index* (0); FIXED_FILE tells the kernel to
    // resolve it through the registered-files table instead of the process table.
    ubyte[8] viaIndex;
    io.putWith!((ref SubmissionEntry e, ubyte[] buf) {
        e.prepRead(/*index=*/ 0, buf, /*offset=*/ 0);
        e.flags |= SubmissionEntryFlags.FIXED_FILE;
        e.user_data = 2;
    })(viaIndex[]);
    if (io.submit(1) != 1) { stderr.writefln("submit (read-by-index) failed"); return 1; }
    io.wait(1);
    {
        const res = io.front.res;
        io.popFront();
        if (res < 0)
        {
            stderr.writefln("FIXED_FILE READ failed: errno %d", -res);
            return 1;
        }
        if (res != payload.length || viaIndex != payload)
        {
            stderr.writefln("read-by-index payload mismatch (res=%d)", res);
            return 1;
        }
    }

    // --- Step 3: FIXED_FD_INSTALL — promote slot 0 to a real process fd. -------
    // This op (6.8) is itself issued against the table index; prepFixedFdInstall
    // sets FIXED_FILE for us. The new, ordinary fd is returned in the CQE res.
    io.putWith!((ref SubmissionEntry e) {
        e.prepFixedFdInstall(/*fixedFd=*/ 0, /*flags=*/ 0);
        e.user_data = 3;
    })();
    if (io.submit(1) != 1) { stderr.writefln("submit (install) failed"); return 1; }
    io.wait(1);
    int newFd;
    {
        const res = io.front.res;
        io.popFront();
        if (unsupported(res))
        {
            writefln("SKIP: FIXED_FD_INSTALL unsupported (errno %d) — needs Linux 6.8+", -res);
            return 0;
        }
        if (res < 0)
        {
            stderr.writefln("FIXED_FD_INSTALL failed: errno %d", -res);
            return 1;
        }
        newFd = res;
    }
    scope (exit) close(newFd);

    // --- Step 4: confirm the installed fd is a normal, readable process fd. ----
    ubyte[8] viaRealFd;
    const rd = read(newFd, &viaRealFd[0], viaRealFd.length);
    if (rd != payload.length || viaRealFd != payload)
    {
        stderr.writefln("installed real fd read mismatch (rd=%d)", rd);
        return 1;
    }

    writefln("ok: direct fd opened into table slot 0, read by index, then "
        ~ "FIXED_FD_INSTALL → real fd %d (both reads returned the same 8 bytes)", newFd);
    return 0;
}

// Thin libc `open(path, O_CREAT|O_WRONLY, 0600)` wrapper — `core.sys.posix`'s
// `open` is variadic, which is awkward to call from a `@trusted` context, so we
// bind the C symbol directly.
private int openFile(const(char)* path) @trusted nothrow @nogc
{
    import std.conv : octal;
    return c_open(path, O_CREAT | O_WRONLY, octal!600);
}

extern (C) private int open(const(char)* path, int flags, ...) @trusted nothrow @nogc;
private alias c_open = open;
