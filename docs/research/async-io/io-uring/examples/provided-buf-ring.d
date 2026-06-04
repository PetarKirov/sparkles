#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_provided_buf_ring"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — ring-provided buffers (`IORING_REGISTER_PBUF_RING`, Linux 5.19).
 *
 * Before 5.19 an app that wanted the kernel to pick a receive buffer had to feed
 * them in one syscall at a time via `IORING_OP_PROVIDE_BUFFERS`. The 5.19 buffer
 * *ring* replaces that with a shared, app-owned ring of `io_uring_buf` slots: the
 * app publishes buffers by writing slots and bumping a tail, and the kernel pops a
 * slot for each buffer-select operation — no per-buffer syscall.
 *
 * This program:
 *   1. registers a small buffer ring (`registerBufRing`) for group id `BGID`,
 *   2. publishes a few buffers into that ring,
 *   3. submits a `RECV` that *selects* a buffer from the group
 *      (`IOSQE_BUFFER_SELECT` + `buf_group`, set for us by the gid `prepRecv`),
 *   4. writes some bytes into the other end of a socketpair,
 *   5. waits and asserts the CQE carries `CQEFlags.BUFFER` — the chosen buffer id
 *      is in the upper 16 bits of `cqe.flags` — and that the bytes landed in the
 *      buffer the kernel picked.
 *
 * The `io_uring_buf_ring` memory layout is the load-bearing detail: the ring is an
 * array of 16-byte `io_uring_buf` slots, and the *tail* counter is overlaid on the
 * `resv` field of the slot at index 0 (so slot 0's data area is unused for the
 * head/tail bookkeeping — we publish into the masked tail position regardless).
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.19 — Buffer rings, zero-copy groundwork, big SQE/CQE (July 2022)".
 *
 * Run with: `dub run --single provided-buf-ring.d`
 *
 * Portability: prints `SKIP:` and exits 0 when io_uring is unavailable or the
 * running kernel predates buffer rings (registerBufRing -> -EINVAL/-EOPNOTSUPP/
 * -ENOSYS). Exits nonzero only on a genuinely unexpected syscall failure.
 */
module io_uring_provided_buf_ring;

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
    // the payload into sv[1] with an ordinary write(2). Loopback-only, no network.
    int[2] sv;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
    {
        stderr.writefln("socketpair failed");
        return 1;
    }
    scope (exit) { close(sv[0]); close(sv[1]); }

    // Allocate the buffer ring page-aligned (liburing requires page alignment for
    // IORING_REGISTER_PBUF_RING). It is a flat array of RING_ENTRIES `io_uring_buf`
    // slots; slot 0's tail field doubles as the ring's producer tail.
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

    // Submit a RECV that selects a buffer from group BGID. This gid overload sets
    // IOSQE_BUFFER_SELECT and sqe->buf_group for us; `len` caps the recv size.
    enum ulong cookie = 0xB0FF_1234;
    // Pass `sv[0]` as an explicit arg rather than capturing it: a capturing lambda
    // would force a GC closure and break `putWith`'s `@nogc`.
    io.putWith!((ref SubmissionEntry e, int recvFd) {
        e.prepRecv(recvFd, BGID, BUF_SIZE);
        e.user_data = cookie;
    })(sv[0]);
    const submitted = io.submit(0); // flush the SQ without blocking on a count
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Write a payload into the peer; the queued RECV will land it in a ring buffer.
    immutable ubyte[] payload = cast(immutable ubyte[]) "ring-provided buffer!";
    const wrote = write(sv[1], &payload[0], payload.length);
    if (wrote != cast(ptrdiff_t) payload.length)
    {
        stderr.writefln("write to peer failed: %d", wrote);
        return 1;
    }

    // Wait for the RECV completion (bounded: a single, guaranteed-imminent CQE).
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
    if (res < 0)
    {
        // -ENOBUFS here would mean the kernel found no published buffer — a real bug
        // in our ring bookkeeping, not an unsupported-feature case.
        stderr.writefln("RECV failed: errno %d", -res);
        return 1;
    }

    // The buffer-select contract: CQEFlags.BUFFER must be set, and the buffer id
    // the kernel picked is in the upper 16 bits of the flags.
    if (!(flags & CQEFlags.BUFFER))
    {
        stderr.writefln("RECV completed without IORING_CQE_F_BUFFER (flags=0x%X)", cast(uint) flags);
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
    if (got != payload)
    {
        stderr.writefln("payload mismatch in selected buffer %d", bid);
        return 1;
    }

    writefln("ok: ring-provided RECV used buffer id %d (%d bytes): \"%s\"",
        bid, res, cast(const(char)[]) got);
    return 0;
}
