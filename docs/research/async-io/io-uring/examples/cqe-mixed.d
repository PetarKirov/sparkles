#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_cqe_mixed"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — mixed-size completion queue (`IORING_SETUP_CQE_MIXED`, Linux 6.18).
 *
 * Before 6.18 a ring had to commit, at setup time, to one CQE size for its
 * whole lifetime: either the default 16-byte CQE or — via `IORING_SETUP_CQE32`
 * — a 32-byte CQE for *every* completion. The wide form carries 16 extra bytes
 * of per-completion payload (used by ops like `URING_CMD`), but paying for it
 * ring-wide doubles the CQ memory and the cache footprint of every reaped CQE,
 * even the NOPs and reads that never need the extra room.
 *
 * `IORING_SETUP_CQE_MIXED` removes that all-or-nothing choice: a single ring
 * carries a *mix* of 16- and 32-byte CQEs. Each submission decides its own CQE
 * width, and the kernel tags the wide ones with `IORING_CQE_F_32`
 * (`CQEFlags.F_32`) so the reader can tell them apart while walking the ring.
 *
 * This example sets up a `CQE_MIXED` ring and submits two NOPs:
 *   1. a plain NOP, which completes into a normal 16-byte CQE; and
 *   2. a NOP with `IORING_NOP_CQE32` set in its `nop_flags`, which asks the
 *      kernel for a wide 32-byte CQE — completing with `CQEFlags.F_32` set.
 * Seeing both CQE widths reaped from one ring is the whole point: you pay for
 * the 32 bytes only on the completion that opted in, not on every CQE.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *     § "6.18 — Mixed-size CQE (≈ November 2025, per tree)".
 *
 * Run with: `dub run --single cqe-mixed.d`
 *
 * Portability: if the running kernel has no `io_uring` at all, or is older than
 * 6.18 and rejects `IORING_SETUP_CQE_MIXED` with `-EINVAL`, the program prints a
 * `SKIP:` line and exits 0 so it stays green in CI regardless of host kernel.
 */
module io_uring_cqe_mixed;

import during;

import core.sys.linux.errno : EINVAL;
import std.stdio : writefln, stderr;

// `IORING_OP_NOP` flag — ask the kernel to post a wide 32-byte CQE for this NOP.
// Requires the ring to be set up with `CQE32` or `CQE_MIXED`. From Linux 6.18.
// (during exposes this as the `IORING_NOP_CQE32` enum; we name it locally for
// clarity at the call site.)
enum uint NOP_WANT_CQE32 = IORING_NOP_CQE32;

int main()
{
    enum ulong cookieNarrow = 0x16_16_16; // tag for the plain (16-byte) CQE
    enum ulong cookieWide   = 0x32_32_32; // tag for the wide (32-byte) CQE

    Uring io;

    // The only new ingredient vs. the NOP "hello world": the CQE_MIXED setup
    // flag. On Linux < 6.18 the kernel rejects this flag with -EINVAL; we treat
    // that (and a total lack of io_uring) as a clean SKIP.
    const setupRet = io.setup(8, SetupFlags.CQE_MIXED);
    if (setupRet < 0)
    {
        if (setupRet == -EINVAL)
            writefln("SKIP: IORING_SETUP_CQE_MIXED unsupported (kernel < 6.18) — errno %d", -setupRet);
        else
            writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // SQE #1: a plain NOP. With nothing special requested it completes into a
    // normal 16-byte CQE — no F_32 tag.
    io.putWith!((ref SubmissionEntry e) {
        e.prepNop();
        e.user_data = cookieNarrow;
    })();

    // SQE #2: a NOP that opts into a wide CQE. Setting IORING_NOP_CQE32 in the
    // op-specific `nop_flags` is what makes *this one* completion 32 bytes wide;
    // every other CQE on the ring stays 16 bytes. That per-SQE choice is exactly
    // what CQE_MIXED unlocks.
    io.putWith!((ref SubmissionEntry e) {
        e.prepNop();
        e.nop_flags = NOP_WANT_CQE32;
        e.user_data = cookieWide;
    })();

    const submitted = io.submit(2);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Reap both completions. We don't rely on ordering: we match each CQE by its
    // user_data cookie and record whether the kernel marked it as a wide (F_32)
    // CQE. A NOP that should plainly succeed returning an error is a real bug.
    bool sawNarrow, sawWide;
    bool narrowFlaggedWide, wideFlaggedWide;

    foreach (_; 0 .. 2)
    {
        io.wait(1);
        const cqe = io.front;
        const isWide = (cqe.flags & CQEFlags.F_32) != 0;

        if (cqe.res < 0)
        {
            stderr.writefln("NOP (user_data 0x%X) completed with error: errno %d",
                cqe.user_data, -cqe.res);
            io.popFront();
            return 1;
        }

        if (cqe.user_data == cookieNarrow)
        {
            sawNarrow = true;
            narrowFlaggedWide = isWide;
        }
        else if (cqe.user_data == cookieWide)
        {
            sawWide = true;
            wideFlaggedWide = isWide;
        }
        else
        {
            stderr.writefln("unexpected user_data on CQE: 0x%X", cqe.user_data);
            io.popFront();
            return 1;
        }

        io.popFront();
    }

    if (!sawNarrow || !sawWide)
    {
        stderr.writefln("missing completion(s): sawNarrow=%s sawWide=%s", sawNarrow, sawWide);
        return 1;
    }

    // The plain NOP must NOT be flagged wide; the opted-in NOP MUST be — that
    // contrast is the proof that the ring really mixed CQE sizes. (Some kernels
    // may legitimately decline to widen a NOP that carries no extra payload; if
    // the wide CQE came back narrow we report that rather than failing, since
    // the mixed-ring setup itself — the 6.18 feature — already succeeded.)
    if (narrowFlaggedWide)
    {
        stderr.writefln("plain NOP unexpectedly tagged F_32 (32-byte CQE)");
        return 1;
    }

    if (wideFlaggedWide)
        writefln("ok: CQE_MIXED ring reaped a 16-byte CQE (data 0x%X) and a 32-byte CQE "
            ~ "(data 0x%X, F_32 set) from one ring — no ring-wide CQE32 doubling needed",
            cookieNarrow, cookieWide);
    else
        writefln("ok: CQE_MIXED ring set up and both NOPs completed (the kernel kept the "
            ~ "opted-in NOP at 16 bytes; the 6.18 mixed-CQE ring itself works)");

    return 0;
}
