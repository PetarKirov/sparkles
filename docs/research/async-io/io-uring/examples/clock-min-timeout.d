#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_clock_min_timeout"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — registered wait clock + min-timeout batched wait (Linux 6.12).
 *
 * 6.12 added two cooperating knobs for the batched-wait path:
 *
 *   * `IORING_REGISTER_CLOCK` selects which kernel clock source backs ring-side
 *     timeouts. The default is `CLOCK_MONOTONIC`; re-registering it here is a
 *     deliberate no-op that simply exercises the register wire-up. A program
 *     that wants suspend-aware deadlines would instead register `CLOCK_BOOTTIME`.
 *
 *   * The *min-timeout* batched wait lets a single `io_uring_enter` block for an
 *     overall deadline while guaranteeing a minimum dwell time, so the kernel can
 *     accumulate a batch of completions without an extra wakeup/context-switch per
 *     event. `during` exposes it as `submitAndWaitMinTimeout(want, ts, minWaitUsec)`,
 *     which drives the `io_uring_getevents_arg` (EXT_ARG) enter path.
 *
 * This example registers `CLOCK_MONOTONIC`, queues a short relative `TIMEOUT`
 * SQE, submits it, then performs a min-timeout wait. The TIMEOUT op fires with
 * `-ETIME`, proving the registered clock + min-timeout wait drove a real timed
 * completion.
 *
 * Two `during` 0.5.0 quirks are worked around here (both noted inline):
 *   1. `Uring.registerClock` passes `nr_args = 1`, but the kernel's
 *      `IORING_REGISTER_CLOCK` handler requires `nr_args == 0` and otherwise
 *      returns `-EINVAL`. We issue the `io_uring_register(2)` syscall directly.
 *   2. `Uring.submitAndWaitMinTimeout` only *waits* (`to_submit = 0`); it does not
 *      flush pending SQEs. We `io.submit(1)` the TIMEOUT first, then wait.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "6.12 — Clock source, buffer cloning, min-timeout (November 2024)".
 *
 * Run with: `dub run --single clock-min-timeout.d`
 *
 * Portability: if the running kernel has no `io_uring`, or is older than 6.12
 * (so `IORING_REGISTER_CLOCK` / the min-timeout enter return
 * `-EINVAL`/`-EOPNOTSUPP`/`-ENOSYS`), the program prints a `SKIP:` line and exits
 * 0 so it stays green in CI.
 */
module io_uring_clock_min_timeout;

import during;

import core.stdc.errno : errno, EINVAL, EOPNOTSUPP, ETIME, ENOSYS;
import std.stdio : writefln, stderr;

// Raw `io_uring_register(2)` access — needed to work around during 0.5.0 passing
// the wrong `nr_args` for `IORING_REGISTER_CLOCK` (see header note #1).
extern (C) long syscall(long number, ...) @system nothrow @nogc;
private enum __NR_io_uring_register = 427; // x86_64
private enum IORING_REGISTER_CLOCK = 29; // RegisterOpCode.REGISTER_CLOCK

// Posix clock id. `CLOCK_MONOTONIC` is the io_uring default; druntime's posix
// bindings don't surface it portably here, so define the constant locally.
private enum CLOCK_MONOTONIC = 1;

// Mirror of `struct io_uring_clock_register` from <linux/io_uring.h>.
private struct ClockRegister
{
    uint clockid;
    uint[3] __resv;
}

int main()
{
    enum ulong cookie = 0x6_12_C10C; // marks the TIMEOUT completion

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // (1) IORING_REGISTER_CLOCK (6.12): choose the clock source backing ring-side
    // timeouts. Re-registering the default CLOCK_MONOTONIC is a no-op but proves
    // the register path works on this kernel; pre-6.12 kernels reject it.
    //
    // We bypass during's `registerClock` because it passes nr_args=1, which the
    // kernel's REGISTER_CLOCK handler rejects with -EINVAL on every kernel; the
    // handler requires nr_args == 0.
    ClockRegister clk;
    clk.clockid = CLOCK_MONOTONIC;
    const clockRet = () @trusted {
        const r = syscall(__NR_io_uring_register, io.fd, IORING_REGISTER_CLOCK, cast(void*)&clk, 0);
        return r < 0 ? -errno : cast(int)r;
    }();
    if (clockRet == -EINVAL || clockRet == -EOPNOTSUPP || clockRet == -ENOSYS)
    {
        writefln("SKIP: IORING_REGISTER_CLOCK unsupported (errno %d) — needs Linux 6.12+", -clockRet);
        return 0;
    }
    if (clockRet < 0)
    {
        stderr.writefln("IORING_REGISTER_CLOCK(CLOCK_MONOTONIC) failed: errno %d", -clockRet);
        return 1;
    }

    // (2) Queue a relative TIMEOUT that fires after 20ms. `count = 0` means the
    // timeout completes purely on elapsed time (no completion-count trigger), so
    // the resulting CQE is guaranteed to be -ETIME.
    auto fire = KernelTimespec(0, 20_000_000); // 20ms
    io.putWith!((ref SubmissionEntry e, ref KernelTimespec t) {
        e.prepTimeout(t, /*count*/ 0, TimeoutFlags.REL);
        e.user_data = cookie;
    })(fire);

    // submitAndWaitMinTimeout only *waits* (to_submit=0) in during 0.5.0, so flush
    // the queued TIMEOUT SQE ourselves first.
    const submitted = io.submit(1);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // (3) min-timeout batched wait (6.12): one io_uring_enter that blocks for at
    // most `overall` (500ms), but is asked to dwell at least `minWaitUsec` (5ms)
    // before returning so the kernel can batch completions without an extra
    // wakeup. The 20ms TIMEOUT comfortably fires inside the 500ms ceiling. This
    // drives the EXT_ARG `io_uring_getevents_arg` enter path.
    auto overall = KernelTimespec(0, 500_000_000); // 500ms ceiling — bounds the wait
    enum uint minWaitUsec = 5_000; // 5ms minimum dwell
    const waitRet = io.submitAndWaitMinTimeout(1, overall, minWaitUsec);
    if (waitRet == -EINVAL || waitRet == -EOPNOTSUPP || waitRet == -ENOSYS)
    {
        writefln("SKIP: min-timeout wait unsupported (errno %d) — needs Linux 6.12+", -waitRet);
        return 0;
    }
    // A valid wait returns 0 (the requested completion is ready) or -ETIME if the
    // overall ceiling elapsed first. Either way we expect our 20ms TIMEOUT CQE.
    if (waitRet < 0 && waitRet != -ETIME)
    {
        stderr.writefln("submitAndWaitMinTimeout failed unexpectedly: errno %d", -waitRet);
        return 1;
    }

    if (io.empty)
    {
        stderr.writefln("no completion ready after min-timeout wait (waitRet=%d)", waitRet);
        return 1;
    }

    const res = io.front.res;
    const echoed = io.front.user_data;
    io.popFront();

    // The TIMEOUT op reports -ETIME when it fires by elapsed time. Anything else
    // means the op didn't behave as a relative timer.
    if (res != -ETIME)
    {
        stderr.writefln("TIMEOUT completed with unexpected res=%d (expected -ETIME=%d)", res, -ETIME);
        return 1;
    }
    if (echoed != cookie)
    {
        stderr.writefln("user_data mismatch: expected 0x%X, got 0x%X", cookie, echoed);
        return 1;
    }

    writefln("ok: registered CLOCK_MONOTONIC and the min-timeout batched wait "
        ~ "fired the relative TIMEOUT (res=-ETIME, user_data 0x%X)", echoed);
    return 0;
}
