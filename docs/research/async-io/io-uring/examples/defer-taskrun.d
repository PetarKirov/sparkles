#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_defer_taskrun"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — the modern low-overhead ring config: `SINGLE_ISSUER` +
 * `DEFER_TASKRUN` + `COOP_TASKRUN` (Linux 6.1, building on 6.0 and 5.19).
 *
 * This is the ring setup most thread-per-core async runtimes (tokio-uring-style,
 * one ring pinned to one thread) reach for. It combines three setup flags:
 *
 *   - `IORING_SETUP_COOP_TASKRUN` (5.19) — completion task-work runs
 *     cooperatively, only when the issuing task is already in the kernel, rather
 *     than the kernel forcing it via an inter-processor interrupt (IPI). Fewer
 *     IPIs == less cross-CPU noise.
 *   - `IORING_SETUP_SINGLE_ISSUER` (6.0) — a promise that exactly one task ever
 *     submits to this ring. That lets the kernel drop a chunk of internal
 *     locking/synchronization on the submission path.
 *   - `IORING_SETUP_DEFER_TASKRUN` (6.1) — completion task-work is *deferred*
 *     entirely until the owning task next enters the kernel asking for events
 *     (an `io_uring_enter` with `GETEVENTS`). This is the big win: completions
 *     are batched and processed at a single, predictable point, eliminating
 *     wakeups/IPIs between submit and reap. `DEFER_TASKRUN` *requires*
 *     `SINGLE_ISSUER` (only one task can be the one that "enters", so the
 *     ownership must be unambiguous), and it only makes progress when that task
 *     calls in with `GETEVENTS` — which is exactly what `io.wait()` does here.
 *
 * The demo: set the ring up with all three flags, submit a NOP plus a short
 * relative TIMEOUT, then `io.wait()` (entering with `GETEVENTS`, which is what
 * runs the deferred completion task-work) and verify both complete.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *     § "6.1 — Zero-copy sendmsg, deferred task-run (December 2022)".
 *
 * Run with: `dub run --single defer-taskrun.d`
 *
 * Portability: a kernel older than 6.1 rejects this flag combination with
 * `-EINVAL`; older still has no io_uring at all (`setup` fails). In both cases
 * the program prints a `SKIP:` line and exits 0 so it stays green in CI
 * regardless of the host kernel.
 */
module io_uring_defer_taskrun;

import during;

import std.stdio : writefln, stderr;

int main()
{
    enum ulong nopCookie = 0xDEFE2;
    enum ulong timeoutCookie = 0x71_3007;

    // The modern thread-per-core config. The order of detection matters: we first
    // probe whether io_uring exists at all (plain setup), then whether *this*
    // flag combination is accepted. That keeps the two SKIP reasons distinct.
    Uring io;
    const deferRet = io.setup(
        8,
        SetupFlags.SINGLE_ISSUER | SetupFlags.DEFER_TASKRUN | SetupFlags.COOP_TASKRUN,
    );
    if (deferRet < 0)
    {
        // -EINVAL here means the kernel knows io_uring but rejects one of these
        // flags (DEFER_TASKRUN < 6.1, SINGLE_ISSUER < 6.0). Distinguish "no
        // io_uring at all" from "this feature is too new" by retrying a plain setup.
        Uring plain;
        const plainRet = plain.setup(8);
        if (plainRet < 0)
        {
            writefln(
                "SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host",
                -plainRet);
            return 0;
        }
        writefln(
            "SKIP: SINGLE_ISSUER|DEFER_TASKRUN|COOP_TASKRUN rejected (errno %d) — needs Linux >= 6.1",
            -deferRet);
        return 0;
    }

    // A relative timeout that fires almost immediately (1ms). Under DEFER_TASKRUN
    // its completion task-work is deferred until we enter with GETEVENTS below.
    KernelTimespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 1_000_000; // 1ms

    // Enqueue a NOP and a short TIMEOUT. With deferred task-run, neither posts a
    // completion eagerly — the kernel parks the task-work until the owning task
    // (us) next enters the ring asking for events.
    io.putWith!((ref SubmissionEntry e) {
        e.prepNop();
        e.user_data = nopCookie;
    })();
    io.putWith!((ref SubmissionEntry e, ref KernelTimespec t) {
        e.prepTimeout(t, 0, TimeoutFlags.REL);
        e.user_data = timeoutCookie;
    })(ts);

    // submit(0) flushes the SQ without asking the kernel to wait on a count; it
    // returns the number of SQEs consumed.
    const submitted = io.submit(0);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }
    if (submitted != 2)
    {
        stderr.writefln("expected to submit 2 SQEs, submitted %d", submitted);
        return 1;
    }

    // Reap both completions. Each `io.wait` performs an io_uring_enter with
    // GETEVENTS — the single, deferred point at which the kernel runs the parked
    // completion task-work for this ring. A TIMEOUT with count 0 reports -ETIME.
    bool sawNop;
    bool sawTimeout;
    foreach (_; 0 .. 2)
    {
        io.wait(1);
        const c = io.front;
        const res = c.res;
        const ud = c.user_data;
        io.popFront();

        if (ud == nopCookie)
        {
            if (res < 0)
            {
                stderr.writefln("NOP completed with error: errno %d", -res);
                return 1;
            }
            sawNop = true;
        }
        else if (ud == timeoutCookie)
        {
            import core.sys.linux.errno : ETIME;
            // A relative timeout with count 0 elapses and reports -ETIME; that is
            // the expected success signal here, not a failure.
            if (res != -ETIME && res != 0)
            {
                stderr.writefln("TIMEOUT completed unexpectedly: errno %d", -res);
                return 1;
            }
            sawTimeout = true;
        }
        else
        {
            stderr.writefln("unexpected completion: user_data 0x%X", ud);
            return 1;
        }
    }

    if (!sawNop || !sawTimeout)
    {
        stderr.writefln(
            "missing completions: sawNop=%s sawTimeout=%s", sawNop, sawTimeout);
        return 1;
    }

    writefln(
        "ok: SINGLE_ISSUER|DEFER_TASKRUN|COOP_TASKRUN ring set up; NOP + TIMEOUT "
        ~ "reaped via GETEVENTS-driven deferred task-run");
    return 0;
}
