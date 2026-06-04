#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_sqe_mixed"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — mixed-size SQEs and 128-byte opcodes
 * (`IORING_SETUP_SQE_MIXED` + `IORING_OP_NOP128`, Linux 6.19).
 *
 * Historically a ring's submission queue entries (SQEs) were a fixed stride:
 * either all 64 bytes, or — with `IORING_SETUP_SQE128` (6.16) — all 128 bytes.
 * `IORING_SETUP_SQE_MIXED` (6.19) lets a single ring carry *both*: ordinary
 * 64-byte SQEs sit alongside 128-byte SQEs, with the kernel and the userspace
 * library tracking the per-slot stride. `IORING_OP_NOP128` is the simplest op
 * that *requires* the wide layout — a `NOP` that occupies a 128-byte slot —
 * making it the canonical smoke test for the feature.
 *
 * This example sets up a mixed ring, emits one plain 64-byte `NOP` and one
 * 128-byte `NOP128` (reserved via `next128()`, which claims the two contiguous
 * SQ slots a 128-byte entry needs), submits them together, and reaps both CQEs.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *     § "6.19 — Mixed-size SQE and 128-byte opcodes".
 *
 * Run with: `dub run --single sqe-mixed.d`
 *
 * Portability: `SQE_MIXED`/`NOP128` land in Linux 6.19. On an older kernel
 * `io_uring_setup` rejects the flag with `-EINVAL` (or the op completes with
 * `-EINVAL`/`-EOPNOTSUPP`); the program then prints a `SKIP:` line and exits 0
 * so it stays green on hosts predating the feature. It is also green when the
 * host has no `io_uring` at all.
 */
module io_uring_sqe_mixed;

import during;

import std.stdio : writefln, stderr;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP;

int main()
{
    // Cookies that ride through the kernel and come back on the CQEs, letting us
    // confirm the 64-byte and 128-byte completions are correlated correctly.
    enum ulong cookie64 = 0x64;
    enum ulong cookie128 = 0x128;

    // `SQE_MIXED` is requested as a setup flag. On a pre-6.19 kernel this is the
    // gate that fails first (-EINVAL), giving us a clean SKIP without ever
    // touching the wide-SQE code path.
    Uring io;
    const setupRet = io.setup(8, SetupFlags.SQE_MIXED);
    if (setupRet == -EINVAL || setupRet == -EOPNOTSUPP)
    {
        writefln("SKIP: IORING_SETUP_SQE_MIXED unsupported (errno %d) — needs Linux 6.19+",
            -setupRet);
        return 0;
    }
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host",
            -setupRet);
        return 0;
    }

    // A normal 64-byte SQE: `putWith` reserves one slot and runs the prep callback.
    io.putWith!((ref SubmissionEntry e) {
        e.prepNop();
        e.user_data = cookie64;
    })();

    // A 128-byte SQE: `next128()` reserves the two contiguous SQ slots a wide
    // entry needs (on an SQE_MIXED ring) and returns a reference to fill in.
    // `prepNop128()` is the 128-byte NOP opcode (IORING_OP_NOP128).
    auto sqe128 = &io.next128();
    (*sqe128).prepNop128();
    sqe128.user_data = cookie128;

    // We asked for 2 logical ops; the wide one occupies an extra SQ slot, so the
    // kernel sees 3 submission slots. We only assert success, not the slot count.
    const submitted = io.submit(2);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Reap both completions. Bound the loop so a misbehaving kernel can't hang us.
    bool sawNop;
    bool sawNop128;
    foreach (i; 0 .. 2)
    {
        io.wait(1);
        const res = io.front.res;
        const echoed = io.front.user_data;
        io.popFront();

        // A kernel that knows SQE_MIXED setup but not the NOP128 op (or rejects
        // the wide layout) reports it per-op here — still an expected SKIP.
        if (res == -EINVAL || res == -EOPNOTSUPP)
        {
            writefln("SKIP: NOP128/SQE_MIXED op unsupported (errno %d) — needs Linux 6.19+",
                -res);
            return 0;
        }
        if (res < 0)
        {
            stderr.writefln("op completed with error: errno %d", -res);
            return 1;
        }

        if (echoed == cookie64)
            sawNop = true;
        else if (echoed == cookie128)
            sawNop128 = true;
        else
        {
            stderr.writefln("unexpected user_data: 0x%X", echoed);
            return 1;
        }
    }

    if (!sawNop || !sawNop128)
    {
        stderr.writefln("missing completion (nop=%s nop128=%s)", sawNop, sawNop128);
        return 1;
    }

    writefln("ok: SQE_MIXED ring completed a 64-byte NOP (0x%X) and a 128-byte NOP128 (0x%X)",
        cookie64, cookie128);
    return 0;
}
