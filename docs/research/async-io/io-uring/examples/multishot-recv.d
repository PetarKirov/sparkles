#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_multishot_recv"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — multishot RECV into a buffer ring (`IORING_RECV_MULTISHOT`, Linux 6.0).
 *
 * A plain `RECV` (5.6) consumes one SQE per received segment: you re-arm it for
 * every read. Multishot RECV (6.0) flips that — a *single* armed SQE stays live
 * and posts a fresh CQE for each incoming segment, each one selecting a buffer
 * from a provided-buffer ring. The kernel keeps the operation armed (signalled by
 * `CQEFlags.MORE` on every non-final CQE) so a server can drain a busy socket with
 * one submission instead of N.
 *
 * This program builds directly on the 5.19 buffer-ring example:
 *   1. registers a small buffer ring (`registerBufRing`) for group id `BGID`,
 *   2. publishes several buffers into that ring,
 *   3. arms ONE multishot RECV that selects from the group
 *      (`prepRecvMultishot(fd, gid, len)` sets `IOSQE_BUFFER_SELECT`, `buf_group`,
 *      and `IORING_RECV_MULTISHOT` for us),
 *   4. writes TWO separate messages into the peer end of a socketpair,
 *   5. waits and asserts it gets TWO CQEs from that one SQE, each carrying
 *      `CQEFlags.MORE` (still armed) + `CQEFlags.BUFFER` (a buffer was selected),
 *      landing in two *distinct* ring buffers with the right bytes.
 *
 * The MORE flag is the multishot contract: it stays set while the op is armed and
 * clears on the terminal CQE. The selected buffer id is in the upper 16 bits of
 * `cqe.flags` (`>> CQE_BUFFER_SHIFT`), exactly as for single-shot buffer-select.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "6.0 — Zero-copy send, single-issuer, sync cancel (October 2022)".
 *
 * Run with: `dub run --single multishot-recv.d`
 *
 * Portability: prints `SKIP:` and exits 0 when io_uring is unavailable or the
 * running kernel predates multishot RECV (the RECV CQE comes back -EINVAL on a
 * pre-6.0 kernel, or registerBufRing -> -EINVAL/-EOPNOTSUPP/-ENOSYS pre-5.19).
 * Exits nonzero only on a genuinely unexpected syscall failure.
 */
module io_uring_multishot_recv;

import during;

import core.stdc.errno : EINVAL, EOPNOTSUPP, ENOSYS;
import core.stdc.stdlib : free;
import core.sys.posix.stdlib : posix_memalign;
import core.sys.posix.sys.socket : AF_UNIX, SOCK_STREAM, socketpair;
import core.sys.posix.unistd : close, write;

import std.stdio : stderr, writefln;

// Group id for our buffer ring, and the buffer geometry. RING_ENTRIES must be a
// power of two — the kernel masks the tail with `ring_entries - 1`.
enum ushort BGID = 7;
enum uint RING_ENTRIES = 8;
enum uint BUF_SIZE = 64;

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // A connected pair of local sockets: we recv on sv[0] via io_uring and write
    // the payloads into sv[1] with ordinary write(2). Loopback-only, no network.
    int[2] sv;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
    {
        stderr.writefln("socketpair failed");
        return 1;
    }
    scope (exit) { close(sv[0]); close(sv[1]); }

    // Allocate the buffer ring page-aligned (the kernel requires page alignment for
    // IORING_REGISTER_PBUF_RING). It is a flat array of RING_ENTRIES `io_uring_buf`
    // slots; slot 0's resv field doubles as the ring's producer tail.
    enum size_t ringBytes = io_uring_buf.sizeof * RING_ENTRIES;
    void* ringPtr;
    if (posix_memalign(&ringPtr, 4096, ringBytes) != 0 || ringPtr is null)
    {
        stderr.writefln("posix_memalign failed");
        return 1;
    }
    scope (exit) free(ringPtr);
    auto ring = cast(io_uring_buf*) ringPtr;
    ring[0 .. RING_ENTRIES] = io_uring_buf.init; // zero the whole ring (incl. tail=0)

    // Backing storage for the buffers themselves (separate from the ring slots).
    auto store = new ubyte[BUF_SIZE * RING_ENTRIES];

    // Register the ring with the kernel for group `BGID`.
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

    // Publish all RING_ENTRIES buffers into the ring. Each slot points at its
    // BUF_SIZE chunk of `store` and carries a distinct buffer id (`bid`). The
    // kernel returns the chosen `bid` in the CQE's upper 16 bits.
    enum uint mask = RING_ENTRIES - 1;
    foreach (ushort i; 0 .. cast(ushort) RING_ENTRIES)
    {
        auto slot = &ring[i & mask];
        slot.addr = cast(ulong) &store[i * BUF_SIZE];
        slot.len = BUF_SIZE;
        slot.bid = i; // buffer id == index, so we can recover the chunk later
    }
    // Publish: advance the producer tail by the number of buffers we added. The
    // tail lives in slot 0 (it overlays io_uring_buf.resv there).
    ring[0].resv = cast(ushort) RING_ENTRIES;

    // Arm ONE multishot RECV that selects buffers from group BGID. The gid overload
    // sets IOSQE_BUFFER_SELECT + sqe->buf_group, and the multishot wrapper adds
    // IORING_RECV_MULTISHOT — so this single SQE will keep posting a CQE per segment.
    enum ulong recvCookie = 0xB16_5EE5;
    // Pass `sv[0]` as an explicit arg rather than capturing it: a capturing lambda
    // would force a GC closure and break `putWith`'s `@nogc`.
    io.putWith!((ref SubmissionEntry e, int recvFd) {
        e.prepRecvMultishot(recvFd, BGID, BUF_SIZE);
        e.user_data = recvCookie;
    })(sv[0]);
    const submitted = io.submit(0); // flush the SQ without blocking on a count
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Two separate messages to feed the peer end. Each becomes its own readable
    // segment on sv[0], so the armed multishot RECV should post one CQE per message.
    immutable ubyte[][2] payloads = [
        cast(immutable ubyte[]) "first multishot segment",
        cast(immutable ubyte[]) "second multishot segment!!",
    ];

    // Drive one segment at a time: write a message, then drain the CQE the armed SQE
    // produces for it, *before* writing the next. On a stream socket two back-to-back
    // writes can coalesce into a single readable chunk (and thus a single CQE);
    // interleaving write-then-drain guarantees two distinct segments — two CQEs from
    // the one armed SQE, each selecting a fresh ring buffer — deterministically,
    // without relying on kernel scheduling. We never re-arm: the multishot SQE stays
    // live across both completions (signalled by CQE_F_MORE).
    ushort[2] gotBids;
    foreach (idx, p; payloads)
    {
        const wrote = write(sv[1], &p[0], p.length);
        if (wrote != cast(ptrdiff_t) p.length)
        {
            stderr.writefln("write to peer failed: %d", wrote);
            return 1;
        }

        io.wait(1); // one CQE is guaranteed imminent (data already written)
        const c = io.front;
        const res = c.res;
        const flags = c.flags;
        const echoed = c.user_data;
        io.popFront();

        if (echoed != recvCookie)
        {
            stderr.writefln("user_data mismatch: expected 0x%X, got 0x%X", recvCookie, echoed);
            return 1;
        }

        // A pre-6.0 kernel rejects the multishot bit on the very first CQE.
        if (res == -EINVAL || res == -EOPNOTSUPP || res == -ENOSYS)
        {
            writefln("SKIP: IORING_RECV_MULTISHOT unsupported (errno %d) — needs Linux 6.0+", -res);
            return 0;
        }
        if (res < 0)
        {
            // -ENOBUFS would mean the ring ran out of published buffers — a real bug
            // in our bookkeeping, not an unsupported-feature case.
            stderr.writefln("multishot RECV CQE #%d failed: errno %d", idx, -res);
            return 1;
        }

        // Multishot contract: each non-terminal CQE carries MORE (still armed). With
        // two segments and 8 buffers the op cannot exhaust the ring, so both of our
        // CQEs must be armed.
        if (!(flags & CQEFlags.MORE))
        {
            stderr.writefln("multishot RECV CQE #%d lost CQE_F_MORE (flags=0x%X) — op disarmed early",
                idx, cast(uint) flags);
            return 1;
        }
        // Buffer-select contract: a buffer must have been chosen, with its id in the
        // upper 16 bits of flags.
        if (!(flags & CQEFlags.BUFFER))
        {
            stderr.writefln("multishot RECV CQE #%d has no CQE_F_BUFFER (flags=0x%X)",
                idx, cast(uint) flags);
            return 1;
        }
        const bid = cast(ushort)(cast(uint) flags >> CQE_BUFFER_SHIFT);
        if (bid >= RING_ENTRIES)
        {
            stderr.writefln("kernel returned out-of-range buffer id %d", bid);
            return 1;
        }

        // Confirm the bytes landed in exactly the buffer the kernel selected.
        auto got = store[bid * BUF_SIZE .. bid * BUF_SIZE + res];
        if (got != payloads[idx])
        {
            stderr.writefln("payload #%d mismatch in selected buffer %d", idx, bid);
            return 1;
        }
        gotBids[idx] = bid;
    }

    // The whole point of multishot: two segments, two CQEs, from ONE armed SQE — and
    // each landed in a *distinct* ring buffer (the kernel pops a fresh slot per CQE).
    if (gotBids[0] == gotBids[1])
    {
        stderr.writefln("expected distinct buffers, both CQEs used buffer id %d", gotBids[0]);
        return 1;
    }

    writefln("ok: one armed multishot RECV posted 2 CQEs (MORE+BUFFER) into distinct buffers %d and %d",
        gotBids[0], gotBids[1]);
    return 0;
}
