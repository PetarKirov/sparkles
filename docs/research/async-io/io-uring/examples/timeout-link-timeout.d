#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_timeout"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` timeouts — standalone `IORING_OP_TIMEOUT` (Linux 5.4) and a chained
 * `IORING_OP_LINK_TIMEOUT` (Linux 5.5).
 *
 * Before timeouts, `io_uring` had no in-kernel notion of "give up after N
 * nanoseconds": you either blocked in `io_uring_enter` or polled. 5.4 added a
 * first-class TIMEOUT op (and the single-`mmap` setup); 5.5 added LINK_TIMEOUT,
 * a timeout *attached* to the preceding linked SQE that cancels it when it fires.
 *
 * Part A — standalone TIMEOUT: arm a ~30ms relative timeout (`count = 0`, so it
 * expires on time rather than after a number of completions) and confirm the CQE
 * reports `-ETIME`.
 *
 * Part B — LINK_TIMEOUT: arm a `POLL_ADD` on the read end of a pipe that never
 * becomes readable (there is no writer), flagged `IO_LINK` so the *next* SQE is
 * linked to it. That next SQE is a `LINK_TIMEOUT` of ~30ms. When the timeout
 * fires it cancels the still-pending poll: the poll CQE comes back `-ECANCELED`
 * and the link-timeout CQE reports `-ETIME` (or `0` on some kernels).
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "5.4 — Timeouts and single mmap (November 2019)".
 *
 * Run with: `dub run --single timeout-link-timeout.d`
 *
 * Portability: if the running kernel has no `io_uring` (too old, or blocked by a
 * seccomp/container policy), or if the TIMEOUT/LINK_TIMEOUT ops are unsupported,
 * the program prints a `SKIP:` line and exits 0 so it stays green in CI.
 */
module io_uring_timeout;

import during;

import core.sys.linux.errno : ETIME, ECANCELED;
import core.sys.posix.unistd : close, pipe;

import std.stdio : writefln, stderr;

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // TIMEOUT (5.4) and LINK_TIMEOUT (5.5) are old enough that almost every
    // io_uring-capable kernel has them, but probe defensively so CI on the
    // oldest hosts still degrades to a SKIP rather than a hard failure.
    auto probe = io.probe();
    if (cast(bool) probe &&
        (!probe.isSupported(Operation.TIMEOUT) || !probe.isSupported(Operation.LINK_TIMEOUT)))
    {
        writefln("SKIP: TIMEOUT/LINK_TIMEOUT op not supported on this kernel");
        return 0;
    }

    // ---- Part A: a standalone relative TIMEOUT that should expire with -ETIME ----
    KernelTimespec tsA;
    tsA.tv_sec = 0;
    tsA.tv_nsec = 30_000_000; // 30ms

    io.putWith!((ref SubmissionEntry e, ref KernelTimespec t) {
        // count = 0 => purely time-based: fire after the duration elapses, not
        // after N completions. REL => the timespec is relative to "now".
        e.prepTimeout(t, 0, TimeoutFlags.REL);
        e.user_data = 1;
    })(tsA);

    const submittedA = io.submit(1);
    if (submittedA < 0)
    {
        // -EINVAL here would mean the op shape is unsupported on this kernel.
        if (-submittedA == 22 /* EINVAL */)
        {
            writefln("SKIP: TIMEOUT submit rejected (EINVAL) — unsupported on this kernel");
            return 0;
        }
        stderr.writefln("Part A submit failed: errno %d", -submittedA);
        return 1;
    }

    io.wait(1);
    const resA = io.front.res;
    io.popFront();

    if (resA == -22 /* -EINVAL */)
    {
        writefln("SKIP: TIMEOUT returned -EINVAL — unsupported on this kernel");
        return 0;
    }
    if (resA != -ETIME)
    {
        stderr.writefln("Part A: expected -ETIME (%d), got %d", -ETIME, resA);
        return 1;
    }

    // ---- Part B: POLL_ADD --IO_LINK--> LINK_TIMEOUT; the timeout cancels the poll ----
    int[2] fds;
    if (() @trusted { return pipe(fds); }() != 0)
    {
        stderr.writefln("pipe() failed");
        return 1;
    }
    scope (exit) { close(fds[0]); close(fds[1]); }

    // SQE 1: poll the pipe read end for readability. Nothing is ever written to
    // the pipe, so on its own this poll would block forever. IO_LINK ties the
    // *next* SQE to it.
    io.putWith!((ref SubmissionEntry e, int rfd) {
        e.prepPollAdd(rfd, PollEvents.IN);
        e.user_data = 10;
        e.flags |= SubmissionEntryFlags.IO_LINK;
    })(fds[0]);

    // SQE 2: the link timeout. Because the previous SQE set IO_LINK, this fires
    // ~30ms after the poll starts and cancels it.
    KernelTimespec tsB;
    tsB.tv_sec = 0;
    tsB.tv_nsec = 30_000_000; // 30ms

    io.putWith!((ref SubmissionEntry e, ref KernelTimespec t) {
        e.prepLinkTimeout(t, TimeoutFlags.REL);
        e.user_data = 11;
    })(tsB);

    const submittedB = io.submit(2);
    if (submittedB < 0)
    {
        stderr.writefln("Part B submit failed: errno %d", -submittedB);
        return 1;
    }

    // Both SQEs produce a CQE: the cancelled poll and the fired link-timeout.
    io.wait(2);

    int pollRes = int.max;
    int linkRes = int.max;
    foreach (_; 0 .. 2)
    {
        const c = io.front;
        if (c.user_data == 10) pollRes = c.res;
        else if (c.user_data == 11) linkRes = c.res;
        io.popFront();
    }

    // The poll must be cancelled by the firing link timeout.
    if (pollRes != -ECANCELED)
    {
        stderr.writefln("Part B: expected poll res -ECANCELED (%d), got %d", -ECANCELED, pollRes);
        return 1;
    }
    // The link timeout itself reports -ETIME (it fired) or 0 (kernel variation).
    if (linkRes != -ETIME && linkRes != 0)
    {
        stderr.writefln("Part B: expected link-timeout res -ETIME (%d) or 0, got %d", -ETIME, linkRes);
        return 1;
    }

    writefln("ok: TIMEOUT expired with -ETIME, and LINK_TIMEOUT cancelled a never-ready poll " ~
        "(poll res=%d -ECANCELED, link res=%d)", pollRes, linkRes);
    return 0;
}
