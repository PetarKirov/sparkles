#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_pipe"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — async pipe creation (`IORING_OP_PIPE`, Linux 6.16).
 *
 * Before 6.16, creating a pipe meant a synchronous `pipe2(2)` syscall outside
 * the ring. `IORING_OP_PIPE` lets the ring itself manufacture the pipe pair:
 * submit one SQE pointing at an `int[2]` buffer and, on completion, the kernel
 * has filled it with the read end (`fds[0]`) and write end (`fds[1]`) — exactly
 * like `pipe2(2)`, but folded into the same submit/complete batch as the rest of
 * your I/O (so a pipe can be created and immediately used in a single linked
 * chain without a syscall round-trip).
 *
 * This example creates a pipe through the ring, then proves it actually works by
 * writing a few bytes into the write end and reading them back out of the read
 * end (plain libc `write`/`read` — the point here is the *creation* op, not the
 * transfer), asserting the bytes round-trip before closing both ends.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "6.16 — Async pipe".
 *
 * Run with: `dub run --single pipe.d`
 *
 * Portability: prints a `SKIP:` line and exits 0 if io_uring is unavailable, or
 * if the `PIPE` op is unsupported (kernel older than the op's introduction —
 * detected via the probe or an `-EINVAL`/`-EOPNOTSUPP` completion), so it stays
 * green on CI hosts running older kernels.
 */
module io_uring_pipe;

import during;

import std.stdio : writefln, stderr;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS;
import core.sys.posix.unistd : close, read, write;

// O_CLOEXEC: ask the kernel to mark both pipe ends close-on-exec, the sane
// default for fds we never intend to leak across an exec. Linux value is octal
// 02000000, identical across the architectures this example targets.
enum int O_CLOEXEC = 0x80000;

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Fast path: if the kernel's op probe answers, trust it. A kernel too old to
    // know about PIPE simply reports it unsupported.
    auto probe = io.probe();
    if (cast(bool) probe && !probe.isSupported(Operation.PIPE))
    {
        writefln("SKIP: IORING_OP_PIPE unsupported on this kernel (needs Linux 6.16+)");
        return 0;
    }

    // The kernel writes the read end into fds[0] and the write end into fds[1].
    // We pass the buffer by pointer through `putWith` and dereference inside the
    // lambda so `prepPipe` binds it by reference.
    int[2] fds = [-1, -1];
    io.putWith!(
        (ref SubmissionEntry e, int[2]* out_)
        {
            e.prepPipe(*out_, O_CLOEXEC);
            e.user_data = 1;
        })(&fds);

    const submitted = io.submit(1);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    io.wait(1);
    const res = io.front.res;
    const cookie = io.front.user_data;
    io.popFront();

    // Runtime fallback: on a kernel without the op, the CQE itself reports the
    // failure. Treat those as "unsupported", anything else as a real error.
    if (res == -EINVAL || res == -EOPNOTSUPP || res == -ENOSYS)
    {
        writefln("SKIP: IORING_OP_PIPE rejected (errno %d) — kernel predates the op", -res);
        return 0;
    }
    if (res < 0)
    {
        stderr.writefln("PIPE completed with error: errno %d", -res);
        return 1;
    }
    if (cookie != 1)
    {
        stderr.writefln("user_data mismatch: expected 1, got %d", cookie);
        return 1;
    }
    if (fds[0] < 0 || fds[1] < 0)
    {
        stderr.writefln("PIPE did not fill the fd pair: fds=[%d, %d]", fds[0], fds[1]);
        return 1;
    }

    // Prove the freshly minted pipe works: a short round-trip through it.
    scope (exit) { close(fds[0]); close(fds[1]); }
    ubyte[8] tx = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04];
    ubyte[8] rx = 0;

    const wrote = write(fds[1], &tx[0], tx.length);
    if (wrote != tx.length)
    {
        stderr.writefln("write to pipe failed: returned %d (errno-side)", wrote);
        return 1;
    }
    const got = read(fds[0], &rx[0], rx.length);
    if (got != tx.length)
    {
        stderr.writefln("read from pipe short: returned %d, expected %d", got, tx.length);
        return 1;
    }
    if (rx[] != tx[])
    {
        stderr.writefln("pipe round-trip mismatch: tx=%(%02X %), rx=%(%02X %)", tx[], rx[]);
        return 1;
    }

    writefln("ok: PIPE created fds=[%d, %d] through the ring; %d bytes round-tripped",
        fds[0], fds[1], got);
    return 0;
}
