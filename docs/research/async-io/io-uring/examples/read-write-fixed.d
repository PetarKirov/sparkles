#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_read_write_fixed"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — registered (fixed) buffers with `IORING_OP_WRITE_FIXED` /
 * `IORING_OP_READ_FIXED` (Linux 5.1).
 *
 * Fixed buffers shipped in the original 5.1 introduction alongside `NOP` and the
 * vectored read/write ops. The idea: register a fixed set of user buffers with the
 * kernel **once** (`io_uring_register(IORING_REGISTER_BUFFERS)`), so the kernel can
 * pin and map their pages up front. Subsequent `*_FIXED` ops then refer to a buffer
 * by **index** instead of an address+length, letting the kernel skip the per-I/O
 * `get_user_pages` / page-pinning dance — the headline zero-overhead-mapping win.
 *
 * This example:
 *   1. opens a throwaway file under `/tmp` (`O_CREAT|O_RDWR|O_TRUNC`),
 *   2. registers ONE buffer with `io.registerBuffers(buf[])`,
 *   3. `WRITE_FIXED`s a known payload from buffer index 0 at offset 0,
 *   4. clears the buffer region, then `READ_FIXED`s it back into index 0,
 *   5. asserts the bytes round-trip.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "5.1 — The introduction".
 *
 * Run with: `dub run --single read-write-fixed.d`
 *
 * Portability: fixed buffers are part of the 5.1 baseline, so no feature probe is
 * needed — but if the running kernel has no `io_uring` at all (too old, or blocked
 * by a seccomp/container policy), `setup` fails and we print a `SKIP:` line and exit
 * 0 so the example stays green in CI regardless of host kernel.
 */
module io_uring_read_write_fixed;

import during;

import std.stdio : writefln, stderr;

import core.stdc.stdlib : free, malloc;
import core.sys.linux.errno : EINVAL, ENOSYS, EOPNOTSUPP;
import core.sys.linux.fcntl : O_CREAT, O_RDWR, O_TRUNC, open;
import core.sys.posix.unistd : close, unlink;

int main()
{
    enum string payload = "io_uring fixed buffers, since Linux 5.1";

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // A throwaway file we own; unlinked on exit. The trailing NUL keeps it a valid
    // C string for the libc open()/unlink() calls.
    static immutable char[] path = "/tmp/io_uring_rw_fixed_example.tmp\0";
    const fd = open(&path[0], O_CREAT | O_RDWR | O_TRUNC, octal!"600");
    if (fd < 0)
    {
        stderr.writefln("open(%s) failed", path[0 .. $ - 1]);
        return 1;
    }
    scope (exit)
    {
        close(fd);
        unlink(&path[0]);
    }

    // Register a single fixed buffer. `registerBuffers` pins the pages and maps them
    // into the kernel once; *_FIXED ops below reference this region by index 0.
    enum size_t bufLen = 4096;
    auto bp = cast(ubyte*) malloc(bufLen);
    if (bp is null)
    {
        stderr.writefln("malloc(%d) failed", bufLen);
        return 1;
    }
    scope (exit) free(bp);
    ubyte[] buffer = bp[0 .. bufLen];

    const regRet = io.registerBuffers(buffer);
    if (regRet < 0)
    {
        // Registration itself is a 5.1 baseline feature; an error here is unexpected.
        stderr.writefln("registerBuffers failed: errno %d", -regRet);
        return 1;
    }
    scope (exit) io.unregisterBuffers();

    // Stage the payload into the registered region and WRITE_FIXED it to the file.
    // prepWriteFixed(e, fd, offset, slice-of-the-registered-buffer, bufferIndex).
    buffer[0 .. payload.length] = cast(const(ubyte)[]) payload;

    io.putWith!(
        (ref SubmissionEntry e, int f, ubyte[] b)
        {
            e.prepWriteFixed(f, 0, b, 0); // bufferIndex 0, file offset 0
            e.user_data = 1;
        })(fd, buffer[0 .. payload.length]);

    auto submitted = io.submit(1);
    if (submitted < 0)
    {
        stderr.writefln("submit (write) failed: errno %d", -submitted);
        return 1;
    }

    io.wait(1);
    auto wres = io.front.res;
    io.popFront();

    // *_FIXED can report -EINVAL/-EOPNOTSUPP if fixed buffers are unavailable in this
    // environment (e.g. a restrictive sandbox) — treat that as an honest SKIP.
    if (wres == -EINVAL || wres == -EOPNOTSUPP || wres == -ENOSYS)
    {
        writefln("SKIP: WRITE_FIXED unsupported here (errno %d)", -wres);
        return 0;
    }
    if (wres < 0)
    {
        stderr.writefln("WRITE_FIXED failed: errno %d", -wres);
        return 1;
    }
    if (wres != cast(int) payload.length)
    {
        stderr.writefln("WRITE_FIXED short write: wrote %d of %d bytes", wres, payload.length);
        return 1;
    }

    // Clear the registered region so the read genuinely round-trips through the file,
    // not through stale buffer contents.
    buffer[0 .. payload.length] = 0;

    io.putWith!(
        (ref SubmissionEntry e, int f, ubyte[] b)
        {
            e.prepReadFixed(f, 0, b, 0); // bufferIndex 0, file offset 0
            e.user_data = 2;
        })(fd, buffer[0 .. payload.length]);

    submitted = io.submit(1);
    if (submitted < 0)
    {
        stderr.writefln("submit (read) failed: errno %d", -submitted);
        return 1;
    }

    io.wait(1);
    auto rres = io.front.res;
    io.popFront();

    if (rres == -EINVAL || rres == -EOPNOTSUPP || rres == -ENOSYS)
    {
        writefln("SKIP: READ_FIXED unsupported here (errno %d)", -rres);
        return 0;
    }
    if (rres < 0)
    {
        stderr.writefln("READ_FIXED failed: errno %d", -rres);
        return 1;
    }
    if (rres != cast(int) payload.length)
    {
        stderr.writefln("READ_FIXED short read: read %d of %d bytes", rres, payload.length);
        return 1;
    }

    if (cast(const(char)[]) buffer[0 .. payload.length] != payload)
    {
        stderr.writefln("round-trip mismatch: got %s", cast(const(char)[]) buffer[0 .. payload.length]);
        return 1;
    }

    writefln(
        "ok: WRITE_FIXED then READ_FIXED round-tripped %d bytes through a registered buffer (index 0)",
        rres);
    return 0;
}

// `octal!"600"` — compile-time octal literal for the file mode, avoiding a leading-0
// literal (deprecated in D) while keeping the intent obvious.
private template octal(string s)
{
    enum uint octal = parseOctal(s);
}

private uint parseOctal(string s) pure nothrow @safe @nogc
{
    uint v;
    foreach (c; s)
        v = v * 8 + (c - '0');
    return v;
}
