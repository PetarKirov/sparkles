#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_sqpoll"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — kernel-side submission polling (`IORING_SETUP_SQPOLL`, Linux 5.1).
 *
 * With `SQPOLL` the kernel spawns a side thread that *polls* the submission
 * queue tail. Once that thread is running and awake, userspace can hand it work
 * simply by writing an SQE and advancing the shared SQ tail — needing **no
 * `io_uring_enter` syscall at all** to submit. That syscall-free submission is
 * the whole point of SQPOLL, and this program demonstrates it directly in two
 * phases:
 *
 *   Phase 1 — prime the poll thread with one ordinary `submit`+`wait`. A freshly
 *             created SQPOLL ring's poll thread does not pick up work until it
 *             has been woken at least once, so this first `io_uring_enter`
 *             (which carries `IORING_ENTER_SQ_WAKEUP` when needed) gets it
 *             spinning. We confirm the NOP round-trips.
 *
 *   Phase 2 — THE PAYOFF: stage a second NOP and publish it with `Uring.flush()`,
 *             which only advances the shared SQ tail pointer in user memory and
 *             issues *no* syscall whatsoever. The now-awake poll thread observes
 *             the new tail and submits the entry on its own; we observe the
 *             completion by busy-polling the completion queue (so we never block
 *             on a syscall either). This is genuine, syscall-free submission.
 *
 * The tradeoff: the kernel thread burns a CPU while it spins, parking only after
 * `sq_thread_idle` ms of inactivity. Once parked it raises `IORING_SQ_NEED_WAKEUP`
 * and the next submission must ring a doorbell (`io_uring_enter` with
 * `IORING_ENTER_SQ_WAKEUP`) to wake it — so SQPOLL trades CPU for latency: a win
 * for a saturated I/O path, wasteful for a bursty one. We pick a large
 * `sq_thread_idle` so the thread stays awake across phase 2's short window.
 *
 * A `NOP` touches no file descriptor, so this needs no registered-files table.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "5.1 — The introduction".
 *
 * Run with: `dub run --single sqpoll.d`
 *
 * Portability: SQPOLL has historically required privilege (`CAP_SYS_ADMIN` /
 * `CAP_SYS_NICE`); on a stricter kernel `setup` returns `-EPERM`, and a host
 * without io_uring (or this flag) returns `-ENOSYS`/`-EINVAL`/`-EOPNOTSUPP`. In
 * every such case the program prints a `SKIP:` line and exits 0 so it stays
 * green in CI regardless of host kernel/privileges.
 */
module io_uring_sqpoll;

import during;

import core.sys.linux.errno : EPERM, EINVAL, ENOSYS, EOPNOTSUPP;
import core.thread : Thread;
import core.time : msecs;
import std.stdio : writefln, stderr;

int main()
{
    enum ulong primeCookie = 0x5_9011UL; // phase 1 correlation cookie
    enum ulong pollCookie  = 0x5_9012UL; // phase 2 (syscall-free) correlation cookie

    Uring io;

    // Request SQPOLL via the SetupParameters overload so we can tune the poll
    // thread's idle timeout. `sq_thread_idle` (ms) is how long the kernel poll
    // thread stays awake before parking and raising NEED_WAKEUP. We pick a value
    // far larger than this program's runtime, guaranteeing the thread is still
    // awake during phase 2 — so that submission stays purely syscall-free. We
    // deliberately omit SQ_AFF (CPU pinning), which would add a needless point of
    // failure on constrained CI hosts.
    SetupParameters params;
    params.flags = SetupFlags.SQPOLL;
    params.sq_thread_idle = 10_000; // 10 s — keeps the poll thread awake for the run

    const setupRet = io.setup(8, params);
    if (setupRet < 0)
    {
        // -EPERM: SQPOLL denied (needs privilege). -EINVAL/-ENOSYS/-EOPNOTSUPP:
        // io_uring or this specific setup flag is unavailable. All are "not
        // supported here", so SKIP and exit 0 rather than fail.
        const e = -setupRet;
        if (e == EPERM)
            writefln("SKIP: IORING_SETUP_SQPOLL denied (EPERM) — needs CAP_SYS_ADMIN/CAP_SYS_NICE");
        else if (e == EINVAL || e == ENOSYS || e == EOPNOTSUPP)
            writefln("SKIP: IORING_SETUP_SQPOLL unsupported (errno %d) — older kernel or no io_uring", e);
        else
            writefln("SKIP: SQPOLL setup failed (errno %d) — io_uring unavailable on this host", e);
        return 0;
    }

    // ---- Phase 1: prime the poll thread ------------------------------------
    // Stage a NOP and submit-and-wait normally. This single `io_uring_enter`
    // wakes the freshly created poll thread (passing SQ_WAKEUP if it was parked).
    io.putWith!((ref SubmissionEntry e) {
        e.prepNop();
        e.user_data = primeCookie;
    })();

    const primed = io.submit(1); // submit + wait for 1 completion
    if (primed < 0)
    {
        stderr.writefln("phase 1 submit failed: errno %d", -primed);
        return 1;
    }

    io.wait(1);
    {
        const res = io.front.res;
        const echoed = io.front.user_data;
        io.popFront();
        if (res < 0)
        {
            stderr.writefln("phase 1 NOP completed with error: errno %d", -res);
            return 1;
        }
        if (echoed != primeCookie)
        {
            stderr.writefln("phase 1 user_data mismatch: expected 0x%X, got 0x%X", primeCookie, echoed);
            return 1;
        }
    }

    // ---- Phase 2: syscall-free submission ----------------------------------
    // The poll thread is now spinning. Stage a second NOP and publish it with
    // `flush()` — which only advances the shared SQ tail pointer in user memory.
    // There is NO io_uring_enter syscall here; the kernel poll thread picks the
    // entry up on its own. We then busy-poll the completion queue (no blocking
    // syscall) so the entire phase-2 round-trip happens without entering the
    // kernel from userspace at all.
    io.putWith!((ref SubmissionEntry e) {
        e.prepNop();
        e.user_data = pollCookie;
    })();
    io.flush(); // <-- the syscall-free publish

    bool got;
    // Hard bound: 400 * 1 ms = 400 ms cap (well under the 2 s budget). On an awake
    // poll thread the NOP completes in well under a millisecond.
    foreach (_; 0 .. 400)
    {
        if (io.length > 0) { got = true; break; }
        Thread.sleep(1.msecs);
    }

    if (!got)
    {
        // The awake poll thread should have submitted+completed our NOP without a
        // syscall. Failing to within a generous bound is a genuine SQPOLL failure.
        stderr.writefln("SQPOLL poll thread did not pick up the flush()-only submission within the budget");
        return 1;
    }

    const res = io.front.res;
    const echoed = io.front.user_data;
    io.popFront();

    if (res < 0)
    {
        stderr.writefln("phase 2 NOP completed with error: errno %d", -res);
        return 1;
    }
    if (echoed != pollCookie)
    {
        stderr.writefln("phase 2 user_data mismatch: expected 0x%X, got 0x%X", pollCookie, echoed);
        return 1;
    }

    writefln("ok: SQPOLL kernel thread completed a NOP submitted via a syscall-free flush() "
        ~ "(res=%d); user_data 0x%X round-tripped", res, echoed);
    return 0;
}
