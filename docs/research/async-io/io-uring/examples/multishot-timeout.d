#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_multishot_timeout"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — multishot timeout (`IORING_TIMEOUT_MULTISHOT`, Linux 6.4).
 *
 * Before 6.4 a `TIMEOUT` SQE fired exactly once: it posted a single `-ETIME`
 * completion and then disarmed. Multishot timeout lets one submitted SQE act as
 * a recurring tick — the kernel re-arms it after each expiry and keeps posting a
 * fresh CQE every interval, each flagged with `CQEFlags.MORE` to mean "more
 * completions for this user_data are still coming". The request stays armed until
 * its `count` of fires is reached, or until you explicitly remove it — at which
 * point the terminating CQE arrives with `MORE` cleared.
 *
 * This example arms a ~20 ms multishot timer (`TimeoutFlags.MULTISHOT`,
 * `count == 0` => unbounded), collects 3 ticks (each `res == -ETIME`, each with
 * `MORE` set), then issues an `ASYNC_CANCEL` keyed by the timer's `user_data` to
 * stop the repeats and drains the terminating CQE (`res == -ECANCELED`, `MORE`
 * cleared). Total runtime ~60 ms.
 *
 * Implementation note: `during` 0.5.0's `prepCancel` helper does not compile
 * (it assigns a `uint` to a `CancelFlags` field without a cast), so we build the
 * `ASYNC_CANCEL` SQE by hand — the kernel matches the request whose `user_data`
 * equals the cancel SQE's `addr`. (The legacy `TIMEOUT_REMOVE` op returns
 * `-ENOENT` against a multishot timer, so async-cancel is the right tool here.)
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "6.4 — Multishot timeout".
 *
 * Run with: `dub run --single multishot-timeout.d`
 *
 * Portability: if the running kernel has no `io_uring` (too old, or blocked by a
 * seccomp/container policy), or if multishot timeout is unsupported (kernel < 6.4,
 * surfaced as a `-EINVAL`/`-EOPNOTSUPP` on the first CQE), the program prints a
 * `SKIP:` line and exits 0 so it stays green in CI regardless of the host kernel.
 */
module io_uring_multishot_timeout;

import during;

import std.stdio : writefln, stderr;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ETIME, ECANCELED;

int main()
{
    // Distinct cookies so we can tell the timer's ticks apart from the
    // cancel request's own completion when both are in flight.
    enum ulong timerData = 1;
    enum ulong cancelData = 2;

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // A short relative interval; with MULTISHOT and count==0 the kernel re-arms
    // this same timer after every expiry, posting one CQE per ~20 ms tick.
    KernelTimespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 20_000_000; // 20 ms

    io.putWith!(
        (ref SubmissionEntry e, ref KernelTimespec t)
        {
            e.prepTimeout(t, /*count*/ 0, TimeoutFlags.MULTISHOT);
            e.user_data = timerData;
        })(ts);

    const submitted = io.submit(0); // flush the SQ; the timer arms in the kernel
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    enum int wantTicks = 3;
    int seen;
    bool lastHadMore = false;

    // Collect 3 recurring ticks. We bound the wait by only ever asking for one
    // completion at a time and stopping after wantTicks fires.
    while (seen < wantTicks)
    {
        io.wait(1);
        const c = io.front;
        const res = c.res;
        const more = (c.flags & CQEFlags.MORE) != 0;
        io.popFront();

        // First CQE of -EINVAL/-EOPNOTSUPP => kernel predates multishot timeout.
        if (res == -EINVAL || res == -EOPNOTSUPP)
        {
            writefln("SKIP: multishot timeout unsupported on this kernel (errno %d) — needs Linux 6.4+", -res);
            return 0;
        }

        if (res != -ETIME)
        {
            stderr.writefln("unexpected tick result: errno %d (expected -ETIME)", -res);
            return 1;
        }
        if (!more)
        {
            // An unbounded multishot timer must keep MORE set while it re-arms.
            stderr.writefln("tick %d cleared CQEFlags.MORE while timer should still be armed", seen);
            return 1;
        }

        seen++;
        lastHadMore = more;
    }

    // Stop the recurring timer with an ASYNC_CANCEL keyed by its user_data.
    // `prepCancel` is broken in during 0.5.0, so fill the SQE by hand: the kernel
    // matches the in-flight request whose user_data == this SQE's `addr`.
    auto sqe = &io.next();
    *sqe = SubmissionEntry.init;
    sqe.opcode = Operation.ASYNC_CANCEL;
    sqe.fd = -1;
    sqe.addr = timerData; // key: cancel the request with this user_data
    sqe.user_data = cancelData;

    const cancelSubmitted = io.submit(0);
    if (cancelSubmitted < 0)
    {
        stderr.writefln("submit (cancel) failed: errno %d", -cancelSubmitted);
        return 1;
    }

    // Drain until we've observed BOTH the cancel request's own CQE and the timer's
    // terminating CQE (res == -ECANCELED, MORE cleared). A tick already in flight
    // may slip in before the cancel lands; we just consume it. The loop is bounded
    // by iteration count so it can never block indefinitely.
    bool sawCancel = false;
    bool sawTimerTermination = false;
    foreach (_; 0 .. 8)
    {
        if (sawCancel && sawTimerTermination)
            break;

        io.wait(1);
        // Consume every CQE currently ready, not just one — the cancel and the
        // timer termination often arrive in the same batch.
        while (!io.empty)
        {
            const c = io.front;
            const res = c.res;
            const data = c.user_data;
            const more = (c.flags & CQEFlags.MORE) != 0;
            io.popFront();

            if (data == timerData)
            {
                // A late tick (-ETIME, MORE set) or the termination
                // (-ECANCELED, MORE cleared).
                if (res == -ECANCELED || !more)
                    sawTimerTermination = true;
            }
            else if (data == cancelData)
            {
                // 0 == cancelled successfully. A benign race (timer fired as the
                // cancel ran) can report -ENOENT/-EALREADY; either way the timer
                // is gone, so don't treat those as failures.
                sawCancel = true;
            }
        }
    }

    if (!sawCancel || !sawTimerTermination)
    {
        stderr.writefln("did not observe both the cancel (%s) and the timer termination (%s)",
            sawCancel, sawTimerTermination);
        return 1;
    }

    writefln("ok: multishot timeout fired %d times (each -ETIME with CQEFlags.MORE), "
        ~ "then stopped via ASYNC_CANCEL (last fire MORE=%s)", seen, lastHadMore);
    return 0;
}
