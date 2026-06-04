#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_splice_tee"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — zero-copy `IORING_OP_SPLICE` (Linux 5.7) + `IORING_OP_TEE` (5.8).
 *
 * `splice(2)` moves bytes between two file descriptors *without* a round trip
 * through a userspace buffer, provided one end is a pipe — the kernel just moves
 * page references between the pipe buffers. `tee(2)` is its sibling: it
 * *duplicates* bytes from one pipe to another without consuming the source, so
 * the same data can still be read from the original pipe afterwards. 5.7 brought
 * `splice` into `io_uring` (`IORING_OP_SPLICE`); 5.8 added `IORING_OP_TEE`.
 *
 * This program wires up three pipes and runs the two ops back-to-back:
 *   1. Write a known payload into pipe A's write end (a plain `write(2)`).
 *   2. `SPLICE` A.read -> B.write — zero-copy hand-off, no userspace copy.
 *   3. `TEE` B.read -> C.write — duplicate B's bytes into C *without* draining B.
 *   4. `read(2)` from C (the tee'd copy) and then from B (the original) and
 *      verify both still carry the full payload.
 *
 * The load-bearing detail is the offset convention: for a pipe fd the splice
 * offset *must* be `-1` (`off_in`/`off_out`), which `during`'s `prepSplice`
 * takes as a `ulong`, so we pass `cast(ulong)-1` (== `ulong.max`). `prepTee` has
 * no offsets at all — pipes are inherently offset-less streams.
 *
 * The two SQEs are submitted as a single batch but ordered with `IO_LINK` so the
 * TEE cannot start reading pipe B until the SPLICE that fills it has completed.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.7 — Splice, provided buffers, fast poll (May 2020)".
 *
 * Run with: `dub run --single splice-tee.d`
 *
 * Portability: prints `SKIP:` and exits 0 when io_uring is unavailable or the
 * kernel lacks SPLICE/TEE (probe miss, or an op result of -EINVAL/-EOPNOTSUPP/
 * -ENOSYS). Exits nonzero only on a genuinely unexpected syscall failure.
 */
module io_uring_splice_tee;

import during;

import core.stdc.errno : EINVAL, ENOSYS, EOPNOTSUPP;
import core.sys.posix.unistd : close, pipe, read, write;

import std.stdio : stderr, writefln;

// User-data cookies so we can tell the two completions apart regardless of the
// order the kernel posts them.
enum ulong UD_SPLICE = 1;
enum ulong UD_TEE = 2;

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Cheap, kernel-version-agnostic capability gate: ask the ring's op probe
    // whether SPLICE and TEE are advertised. On a host that predates them this
    // short-circuits to a clean SKIP before we touch any pipes.
    auto probe = io.probe();
    if (cast(bool)probe && !(probe.isSupported(Operation.SPLICE) && probe.isSupported(Operation.TEE)))
    {
        writefln("SKIP: kernel io_uring lacks SPLICE/TEE (probe miss) — feature added in 5.7/5.8");
        return 0;
    }

    enum string payload = "io_uring zero-copy splice+tee\n";
    immutable(ubyte)[] tx = cast(immutable(ubyte)[]) payload;

    // Three pipes: A is the source, B receives the SPLICE, C receives the TEE.
    int[2] a = [-1, -1], b = [-1, -1], c = [-1, -1];
    if (pipe(a) != 0 || pipe(b) != 0 || pipe(c) != 0)
    {
        stderr.writefln("pipe(2) failed");
        return 1;
    }
    scope (exit)
        foreach (p; [a, b, c])
            foreach (fd; p)
                if (fd >= 0)
                    close(fd);

    // Seed pipe A with the payload via an ordinary blocking write — small enough
    // to fit comfortably in the default 64 KiB pipe buffer, so this never blocks.
    const wrote = write(a[1], tx.ptr, tx.length);
    if (wrote != cast(long) tx.length)
    {
        stderr.writefln("seed write to pipe A failed: wrote %d of %d", wrote, tx.length);
        return 1;
    }

    // SQE 1: SPLICE A.read -> B.write. Pipe offsets must be -1 (ulong.max here).
    // IO_LINK makes the following TEE wait for this to finish (and succeed).
    io.putWith!((ref SubmissionEntry e, int fdIn, int fdOut, uint len) {
        e.prepSplice(fdIn, cast(ulong)-1, fdOut, cast(ulong)-1, len, 0);
        e.flags |= SubmissionEntryFlags.IO_LINK;
        e.user_data = UD_SPLICE;
    })(a[0], b[1], cast(uint) tx.length);

    // SQE 2: TEE B.read -> C.write. TEE duplicates without consuming B, so the
    // bytes remain readable from B afterwards. No offsets for tee.
    io.putWith!((ref SubmissionEntry e, int fdIn, int fdOut, uint len) {
        e.prepTee(fdIn, fdOut, len, 0);
        e.user_data = UD_TEE;
    })(b[0], c[1], cast(uint) tx.length);

    const submitted = io.submit(2);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Collect both completions (bounded — exactly two SQEs were submitted).
    int spliceRes = int.min, teeRes = int.min;
    foreach (_; 0 .. 2)
    {
        io.wait(1);
        const cqe = io.front;
        if (cqe.user_data == UD_SPLICE)
            spliceRes = cqe.res;
        else if (cqe.user_data == UD_TEE)
            teeRes = cqe.res;
        io.popFront();
    }

    // A linked op that the kernel skips because its predecessor failed reports
    // -ECANCELED; treat an unsupported SPLICE/TEE as a clean SKIP either way.
    bool unsupported(int r)
    {
        return r == -EINVAL || r == -EOPNOTSUPP || r == -ENOSYS;
    }
    if (unsupported(spliceRes) || unsupported(teeRes))
    {
        writefln("SKIP: SPLICE/TEE rejected by kernel (splice res=%d, tee res=%d)", spliceRes, teeRes);
        return 0;
    }

    if (spliceRes != cast(int) tx.length)
    {
        stderr.writefln("SPLICE moved %d bytes, expected %d", spliceRes, tx.length);
        return 1;
    }
    if (teeRes != cast(int) tx.length)
    {
        stderr.writefln("TEE duplicated %d bytes, expected %d", teeRes, tx.length);
        return 1;
    }

    // The tee'd copy lands in C; the original is still queued in B because TEE
    // does not consume. Read both and verify the payload survived both hops.
    ubyte[256] rxC, rxB;
    const rdC = read(c[0], rxC.ptr, rxC.length);
    const rdB = read(b[0], rxB.ptr, rxB.length);
    if (rdC != cast(long) tx.length || rxC[0 .. tx.length] != tx[])
    {
        stderr.writefln("tee'd copy in pipe C mismatch (read %d bytes)", rdC);
        return 1;
    }
    if (rdB != cast(long) tx.length || rxB[0 .. tx.length] != tx[])
    {
        stderr.writefln("original bytes in pipe B were consumed by TEE (read %d bytes)", rdB);
        return 1;
    }

    writefln("ok: SPLICE moved %d bytes A->B zero-copy, TEE duplicated them B->C "
            ~ "without consuming (both pipes still held the payload)", spliceRes);
    return 0;
}
