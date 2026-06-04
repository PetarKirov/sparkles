#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_read_multishot"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — multishot read into ring-provided buffers
 * (`IORING_OP_READ_MULTISHOT`, Linux 6.7).
 *
 * A normal `READ` SQE produces one read and one CQE. `READ_MULTISHOT` stays
 * armed against a *pollable* fd (a pipe here): each time data arrives the kernel
 * pops a buffer from a registered buffer group, reads one chunk into it, and
 * posts a CQE — *without* re-submitting an SQE. While the request remains armed
 * each CQE carries `CQEFlags.MORE` (more completions to come) and
 * `CQEFlags.BUFFER` (a kernel-chosen buffer id is packed into the upper 16 bits
 * of `cqe.flags`). The request terminates — final CQE without `MORE` — on EOF,
 * on error, or when the buffer group runs dry (`-ENOBUFS`).
 *
 * This program:
 *   1. registers a buffer ring (`registerBufRing`, the 5.19 fast path) for group
 *      `BGID` and publishes a handful of equal-sized buffers,
 *   2. arms a single `READ_MULTISHOT` on the read end of a pipe with
 *      buffer-select (`prepReadMultishot` sets `IOSQE_BUFFER_SELECT` + `buf_group`),
 *   3. writes two separate chunks into the write end,
 *   4. waits for the two resulting CQEs and asserts each one set `MORE|BUFFER`
 *      and landed its chunk in exactly the buffer id the kernel reported.
 *
 * The "one SQE, many CQEs" shape is the whole point: the cost of arming a read
 * is paid once, and steady-state reads avoid the submit half of the syscall.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "6.7 — Futex, waitid, read-multishot (January 2024)".
 *
 * Run with: `dub run --single read-multishot.d`
 *
 * Portability: prints `SKIP:` and exits 0 when io_uring is unavailable, when the
 * op is unknown to `probe()`, or when an op/register call reports
 * -EINVAL/-EOPNOTSUPP/-ENOSYS (kernel predates 6.7). Exits nonzero only on a
 * genuinely unexpected syscall failure.
 */
module io_uring_read_multishot;

import during;

import core.stdc.errno : EINVAL, ENOSYS, EOPNOTSUPP;
import core.stdc.stdlib : free;
import core.sys.posix.stdlib : posix_memalign;
import core.sys.posix.unistd : close, pipe, write;

import std.stdio : stderr, writefln;

// Buffer-ring geometry. RING_ENTRIES must be a power of two — the kernel masks
// the producer tail with `ring_entries - 1`.
enum ushort BGID = 7;
enum uint RING_ENTRIES = 8;
enum uint BUF_SIZE = 64;
enum uint CHUNKS = 2; // number of separate writes -> number of multishot CQEs

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Fast unsupported-feature gate: ask the kernel whether it knows the op at
    // all. An old kernel (or one without the probe op) trips the SKIP path here
    // before we touch any buffers.
    auto probe = io.probe();
    if (!cast(bool) probe || !probe.isSupported(Operation.READ_MULTISHOT))
    {
        writefln("SKIP: IORING_OP_READ_MULTISHOT not advertised by probe — needs Linux 6.7+");
        return 0;
    }

    // A pipe gives us a *pollable* fd: multishot read re-arms on each readiness
    // edge. We read the read end via io_uring and feed it with ordinary write(2)
    // on the write end. Loopback-only, no fds beyond this process.
    int[2] p;
    if (pipe(p) != 0)
    {
        stderr.writefln("pipe() failed");
        return 1;
    }
    scope (exit) { close(p[0]); close(p[1]); }

    // Allocate the buffer ring page-aligned (IORING_REGISTER_PBUF_RING requires
    // page alignment). It is a flat array of RING_ENTRIES `io_uring_buf` slots;
    // slot 0's `resv` field doubles as the ring's producer tail.
    enum size_t ringBytes = io_uring_buf.sizeof * RING_ENTRIES;
    void* ringPtr;
    if (posix_memalign(&ringPtr, 4096, ringBytes) != 0 || ringPtr is null)
    {
        stderr.writefln("posix_memalign failed");
        return 1;
    }
    scope (exit) free(ringPtr);
    auto ring = cast(io_uring_buf*) ringPtr;
    ring[0 .. RING_ENTRIES] = io_uring_buf.init; // zero whole ring (incl. tail=0)

    // Backing storage for the buffers (separate from the 16-byte ring slots).
    auto store = new ubyte[BUF_SIZE * RING_ENTRIES];

    // Register the buffer ring for group BGID. A pre-6.7 kernel that nonetheless
    // lacks buffer rings would fail here; treat the unsupported errnos as SKIP.
    io_uring_buf_reg reg;
    reg.ring_addr = cast(ulong) ringPtr;
    reg.ring_entries = RING_ENTRIES;
    reg.bgid = BGID;
    const regRet = io.registerBufRing(reg);
    if (regRet == -EINVAL || regRet == -EOPNOTSUPP || regRet == -ENOSYS)
    {
        writefln("SKIP: IORING_REGISTER_PBUF_RING unsupported (errno %d) — needs Linux 5.19+", -regRet);
        return 0;
    }
    if (regRet < 0)
    {
        stderr.writefln("registerBufRing failed: errno %d", -regRet);
        return 1;
    }
    scope (exit) io.unregisterBufRing(BGID);

    // Publish all RING_ENTRIES buffers: each slot points at its BUF_SIZE chunk of
    // `store` and carries a distinct buffer id (`bid == index`, so we can recover
    // which chunk the kernel filled).
    enum uint mask = RING_ENTRIES - 1;
    foreach (ushort i; 0 .. cast(ushort) RING_ENTRIES)
    {
        auto slot = &ring[i & mask];
        slot.addr = cast(ulong) &store[i * BUF_SIZE];
        slot.len = BUF_SIZE;
        slot.bid = i;
    }
    // Advance the producer tail by the count of published buffers (tail lives in
    // slot 0, overlaying io_uring_buf.resv).
    ring[0].resv = cast(ushort) RING_ENTRIES;

    // Arm one multishot READ on the pipe read end, selecting from group BGID.
    // `prepReadMultishot` sets IOSQE_BUFFER_SELECT + buf_group for us. After this
    // single submit the kernel re-arms itself across completions.
    // The kernel's READ_MULTISHOT prep rejects a non-zero `len` (sqe->len must be
    // 0) and treats a `-1` offset as "use the file position" — the right choice
    // for a stream like a pipe. The per-read size is whatever buffer the group
    // hands out (BUF_SIZE here), not an SQE field.
    enum ulong cookie = 0x6EAD_3357;
    io.putWith!((ref SubmissionEntry e, int readFd) {
        e.prepReadMultishot(readFd, 0, -1, BGID);
        e.user_data = cookie;
    })(p[0]);
    const submitted = io.submit(0); // flush SQ without blocking
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Write CHUNKS distinct payloads. Each readiness edge drives one multishot
    // read -> one CQE. We write them one at a time and drain the CQE in between
    // so the two chunks don't coalesce into a single read.
    static immutable string[CHUNKS] payloads = ["first-chunk", "second-chunk!!"];

    foreach (idx, payload; payloads)
    {
        const wrote = write(p[1], &payload[0], payload.length);
        if (wrote != cast(ptrdiff_t) payload.length)
        {
            stderr.writefln("write to pipe failed: %d", wrote);
            return 1;
        }

        // Exactly one CQE is imminent per write — bounded wait.
        io.wait(1);
        const c = io.front;
        const res = c.res;
        const flags = c.flags;
        const echoed = c.user_data;
        io.popFront();

        if (echoed != cookie)
        {
            stderr.writefln("user_data mismatch: expected 0x%X, got 0x%X", cookie, echoed);
            return 1;
        }

        // -EINVAL/-EOPNOTSUPP slipping past the probe means the op truly is not
        // wired up on this kernel: SKIP rather than fail.
        if (res == -EINVAL || res == -EOPNOTSUPP || res == -ENOSYS)
        {
            writefln("SKIP: READ_MULTISHOT rejected at runtime (errno %d) — needs Linux 6.7+", -res);
            return 0;
        }
        // -ENOBUFS would mean our buffer group ran dry — a bug in our bookkeeping
        // here (we published far more buffers than chunks), so it's a hard error.
        if (res < 0)
        {
            stderr.writefln("READ_MULTISHOT chunk %d failed: errno %d", idx, -res);
            return 1;
        }

        if (res != cast(int) payload.length)
        {
            stderr.writefln("chunk %d byte count: expected %d, got %d", idx, payload.length, res);
            return 1;
        }

        // Multishot contract: each in-flight CQE must carry BUFFER (a buffer was
        // selected) and MORE (the request stays armed for the next chunk).
        if (!(flags & CQEFlags.BUFFER))
        {
            stderr.writefln("chunk %d: missing IORING_CQE_F_BUFFER (flags=0x%X)", idx, cast(uint) flags);
            return 1;
        }
        if (!(flags & CQEFlags.MORE))
        {
            stderr.writefln("chunk %d: multishot disarmed early, missing IORING_CQE_F_MORE (flags=0x%X)",
                idx, cast(uint) flags);
            return 1;
        }

        // Recover the kernel-chosen buffer id from the upper 16 bits and confirm
        // the bytes landed in that exact buffer.
        const bid = cast(ushort)(cast(uint) flags >> CQE_BUFFER_SHIFT);
        if (bid >= RING_ENTRIES)
        {
            stderr.writefln("chunk %d: out-of-range buffer id %d", idx, bid);
            return 1;
        }
        auto got = store[bid * BUF_SIZE .. bid * BUF_SIZE + res];
        if (cast(const(char)[]) got != payload)
        {
            stderr.writefln("chunk %d: payload mismatch in buffer %d", idx, bid);
            return 1;
        }

        writefln("ok: multishot chunk %d -> buffer id %d (%d bytes, MORE|BUFFER set): \"%s\"",
            idx, bid, res, cast(const(char)[]) got);
    }

    writefln("ok: one READ_MULTISHOT SQE produced %d completions across %d buffers",
        CHUNKS, RING_ENTRIES);
    return 0;
}
