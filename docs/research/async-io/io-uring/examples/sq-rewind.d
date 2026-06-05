#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_sq_rewind"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — SQ rewind (`IORING_SETUP_SQ_REWIND`, Linux 7.0).
 *
 * Normally the submission-queue tail only moves forward, and once the kernel has
 * been told (via the shared `tail` index) about a batch of SQEs it owns them —
 * any it can't process in one `io_uring_enter` would simply be lost to the
 * application. `IORING_SETUP_SQ_REWIND` changes that: when the kernel stops a
 * batch part-way (e.g. it hit a malformed SQE), it *rewinds its head* back over
 * the SQEs it did not consume, so the application can re-submit them. This makes
 * partial submits recoverable and enables speculative batching where a program
 * prepares entries optimistically and re-drives whatever the kernel didn't take.
 *
 * The flag requires `IORING_SETUP_NO_SQARRAY` (head/tail index the SQE array
 * directly, so there is a well-defined tail to rewind) and is incompatible with
 * `SQPOLL` (a kernel poll thread could consume an SQE out from under a rewind).
 *
 * What this program demonstrates (when the kernel supports the flag):
 *   1. queue three NOPs, deliberately corrupting the *middle* one (bogus opcode);
 *   2. `submit()` — the kernel processes SQE #1, chokes on the malformed #2, and
 *      stops the batch early, rewinding its head over the un-consumed #2 and #3;
 *   3. drain the completion(s) from that partial submit;
 *   4. `submit()` again with no fresh `putWith` — on a rewind ring the trailing
 *      good NOP (#3) survived and is re-sent, and we assert its `user_data`
 *      round-trips. On a non-rewind ring SQE #3 would have been dropped, so this
 *      observably exercises the rewind machinery rather than a plain NOP.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "7.0 — SQ rewind".
 *
 * Run with: `dub run --single sq-rewind.d`
 *
 * Portability: this box runs Linux 6.18, which predates `SQ_REWIND` (Linux 7.0),
 * so `io_uring_setup` is expected to reject the flag with `-EINVAL`; we print a
 * `SKIP:` line and exit 0. The same SKIP path covers hosts with no `io_uring`
 * at all (too old, or blocked by a seccomp/container policy).
 */
module io_uring_sq_rewind;

import during;

import std.stdio : writefln, stderr;

int main()
{
    import core.stdc.errno : EINVAL, EOPNOTSUPP, ENOSYS, EPERM;

    Uring io;

    // SQ_REWIND requires NO_SQARRAY (the direct head/tail layout that gives a
    // rewindable tail) and is mutually exclusive with SQPOLL.
    const setupRet = io.setup(8, SetupFlags.NO_SQARRAY | SetupFlags.SQ_REWIND);
    if (setupRet < 0)
    {
        const e = -setupRet;
        // -EINVAL / -EOPNOTSUPP / -ENOSYS: the kernel doesn't know this flag
        // (e.g. < 7.0, like this 6.18 box). -EPERM: policy-blocked.
        if (e == EINVAL || e == EOPNOTSUPP || e == ENOSYS || e == EPERM)
        {
            writefln("SKIP: IORING_SETUP_SQ_REWIND unsupported (errno %d) — needs Linux 7.0+", e);
            return 0;
        }
        stderr.writefln("io_uring_setup(NO_SQARRAY|SQ_REWIND) failed unexpectedly: errno %d", e);
        return 1;
    }

    // Three NOPs; the middle one is sabotaged with a bogus opcode so the kernel
    // refuses it and halts the batch there. The trailing good NOP (user_data 3)
    // is the one whose survival proves the rewind behaviour.
    enum ulong goodHead = 1, badMiddle = 2, goodTail = 3;
    io.putWith!((ref SubmissionEntry e) { e.prepNop(); e.user_data = goodHead; })();
    io.putWith!((ref SubmissionEntry e) {
        e.prepNop();
        e.opcode = cast(Operation) 0xFF; // not a real op — kernel rejects it
        e.user_data = badMiddle;
    })();
    io.putWith!((ref SubmissionEntry e) { e.prepNop(); e.user_data = goodTail; })();

    // First submit: the kernel takes the leading good NOP, then stops at the
    // malformed one. It must report a partial count (>0, <3) and rewind its head
    // over the SQEs it did not consume.
    const first = io.submit();
    if (first < 0)
    {
        stderr.writefln("first submit failed: errno %d", -first);
        return 1;
    }
    if (!(first > 0 && first < 3))
    {
        stderr.writefln("expected a partial submit (1 or 2), got %d", first);
        return 1;
    }

    // Drain everything that completed from the partial submit (bounded: the
    // kernel produced exactly `first` CQEs and they are already imminent).
    io.wait(1);
    while (!io.empty)
        io.popFront();

    // Second submit with NO new SQE queued. On a SQ_REWIND ring the un-consumed
    // trailing NOP was rewound and re-presented, so this sends exactly one SQE.
    // Without rewind support `submit()` would have nothing left to send here.
    const second = io.submit();
    if (second < 0)
    {
        stderr.writefln("re-submit of rewound SQE failed: errno %d", -second);
        return 1;
    }
    if (second != 1)
    {
        stderr.writefln("rewound SQE was lost: re-submit sent %d entries, expected 1", second);
        return 1;
    }

    // The survivor completes; its cookie confirms it is exactly the SQE the
    // kernel rewound rather than something freshly minted.
    io.wait(1);
    const res = io.front.res;
    const echoed = io.front.user_data;
    io.popFront();

    if (res < 0)
    {
        stderr.writefln("rewound NOP completed with error: errno %d", -res);
        return 1;
    }
    if (echoed != goodTail)
    {
        stderr.writefln("rewound SQE mismatch: expected user_data %d, got %d", goodTail, echoed);
        return 1;
    }

    writefln("ok: SQ_REWIND recovered the trailing SQE after a partial submit "
        ~ "(first sent %d, leftover user_data %d re-submitted and completed)", first, echoed);
    return 0;
}
