#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_registered_files"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — registered files + `IOSQE_FIXED_FILE` (Linux 5.1).
 *
 * One of the original 5.1 features: `IORING_REGISTER_FILES` lets a ring
 * pre-register a table of file descriptors with the kernel. Submissions then
 * address a file by its *table index* instead of a raw fd, with the
 * `IOSQE_FIXED_FILE` flag set on the SQE.
 *
 * Why it matters: for every plain (non-fixed) op the kernel must look the fd up
 * in the process fd table and bump/drop the file's reference count on each
 * submit/complete. A registered file is grabbed once at registration time and
 * held for the life of the table, so per-op submission skips that fget/fput
 * dance entirely — a measurable win for high-IOPS workloads that hammer the
 * same descriptors.
 *
 * This program:
 *   1. creates a temp file (libc) and writes a known 256-byte pattern,
 *   2. reopens it read-only and registers it as fixed-file table index 0,
 *   3. submits a `prepRead` whose `fd` argument is the *index* 0, with
 *      `SubmissionEntryFlags.FIXED_FILE` set, then verifies the bytes read back
 *      match the pattern,
 *   4. unregisters the table.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "5.1 — The introduction".
 *
 * Run with: `dub run --single registered-files.d`
 *
 * Portability: if the running kernel has no `io_uring` (too old, or blocked by a
 * seccomp/container policy), the program prints a `SKIP:` line and exits 0. The
 * fixed-file table itself dates from the 5.1 introduction, so any kernel new
 * enough to run io_uring at all supports it.
 */
module io_uring_registered_files;

import during;

import core.stdc.stdlib : malloc, free;
import core.sys.linux.errno : EINVAL, EOPNOTSUPP;
import core.sys.linux.fcntl : open, O_CREAT, O_RDONLY, O_WRONLY, O_TRUNC;
import core.sys.posix.unistd : close, unlink, write;

import std.stdio : writefln, stderr;
import std.string : toStringz;

int main()
{
    enum ulong cookie = 0x5151_0001;

    // A deterministic 256-byte pattern (0,1,2,...,255) we will write and then
    // read back through the fixed-file table.
    ubyte[256] pattern;
    foreach (i, ref b; pattern)
        b = cast(ubyte) i;

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // --- 1. Create a temp file and write the known pattern via plain libc. ---
    const char* path = toStringz("/tmp/io_uring_registered_files.tmp");
    {
        const wfd = open(path, O_CREAT | O_WRONLY | O_TRUNC, octal!600);
        if (wfd < 0)
        {
            stderr.writefln("could not create temp file");
            return 1;
        }
        const wr = write(wfd, &pattern[0], pattern.length);
        close(wfd);
        if (wr != pattern.length)
        {
            stderr.writefln("short write to temp file: %d", wr);
            unlink(path);
            return 1;
        }
    }
    scope (exit) unlink(path);

    // --- 2. Reopen read-only and register it as fixed-file table index 0. ---
    const rfd = open(path, O_RDONLY, 0);
    if (rfd < 0)
    {
        stderr.writefln("could not reopen temp file");
        return 1;
    }
    scope (exit) close(rfd);

    const int[1] tableFds = [rfd];
    const regRet = io.registerFiles(tableFds[]);
    if (regRet == -EINVAL || regRet == -EOPNOTSUPP)
    {
        // Defensive: fixed files exist since 5.1, so this should not happen on a
        // kernel that completed io_uring_setup, but stay green if it ever does.
        writefln("SKIP: IORING_REGISTER_FILES unsupported (errno %d)", -regRet);
        return 0;
    }
    if (regRet != 0)
    {
        stderr.writefln("registerFiles failed: errno %d", -regRet);
        return 1;
    }

    // --- 3. Read the file BY TABLE INDEX, not by raw fd. ---
    // The buffer the kernel fills lives in process memory; allocate it off-GC so
    // the example stays self-contained and pointer-stable for the duration.
    enum size_t len = pattern.length;
    auto bufPtr = cast(ubyte*) malloc(len);
    if (bufPtr is null)
    {
        stderr.writefln("malloc failed");
        io.unregisterFiles();
        return 1;
    }
    scope (exit) free(bufPtr);
    ubyte[] readBuf = bufPtr[0 .. len];
    readBuf[] = 0;

    io.putWith!((ref SubmissionEntry e, ubyte[] dst) {
        // NOTE: the first arg to prepRead is `0` — the *index* into the
        // registered-file table, not `rfd`. FIXED_FILE tells the kernel to
        // interpret it that way.
        e.prepRead(0, dst, 0);
        e.flags |= SubmissionEntryFlags.FIXED_FILE;
        e.user_data = cookie;
    })(readBuf);

    const submitted = io.submit(1);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        io.unregisterFiles();
        return 1;
    }

    io.wait(1);
    const res = io.front.res;
    const echoed = io.front.user_data;
    io.popFront();

    // --- 4. Unregister the table (kernel drops its single held reference). ---
    const unregRet = io.unregisterFiles();
    if (unregRet != 0)
    {
        stderr.writefln("unregisterFiles failed: errno %d", -unregRet);
        return 1;
    }

    // Validate the fixed-file read.
    if (res < 0)
    {
        stderr.writefln("fixed-file read failed: errno %d", -res);
        return 1;
    }
    if (echoed != cookie)
    {
        stderr.writefln("user_data mismatch: expected 0x%X, got 0x%X", cookie, echoed);
        return 1;
    }
    if (res != cast(int) len || readBuf[] != pattern[])
    {
        stderr.writefln("content mismatch: read %d bytes, pattern check failed", res);
        return 1;
    }

    writefln("ok: read %d bytes via fixed-file table index 0 (IOSQE_FIXED_FILE), pattern verified", res);
    return 0;
}

/// Compile-time octal literal helper (D dropped the `0NNN` octal syntax).
private enum octal(int n) = {
    int v = 0, mul = 1, x = n;
    while (x > 0) { v += (x % 10) * mul; mul *= 8; x /= 10; }
    return v;
}();
