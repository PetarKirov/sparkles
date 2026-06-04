#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_sync_cancel"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — synchronous cancellation from userspace
 * (`IORING_REGISTER_SYNC_CANCEL`, Linux 6.0).
 *
 * Before 6.0 the only way to cancel an in-flight request was to submit an
 * `IORING_OP_ASYNC_CANCEL` SQE and then reap *its* completion plus the
 * cancelled op's completion — an asynchronous, two-CQE dance. 6.0 added a
 * `register`-family opcode that cancels matching requests **synchronously**:
 * the `io_uring_register(REGISTER_SYNC_CANCEL, …)` call blocks until the
 * matching request(s) are torn down and returns the count, with no cancel SQE
 * and no extra CQE.
 *
 * This example:
 *   1. Opens a pipe and arms a `POLL_ADD` for `POLLIN` on the read end. Nothing
 *      is ever written, so the poll would block forever — a perfect stand-in
 *      for a genuinely in-flight request. The SQE carries `user_data = 1`.
 *   2. Fills an `io_uring_sync_cancel_reg` with `addr = 1` (match by the same
 *      `user_data`; `flags = 0` selects user_data matching) and calls
 *      `io.registerSyncCancel(reg)`.
 *   3. Reaps the poll's CQE and asserts it came back with `-ECANCELED`.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 * § "6.0 — Zero-copy send, single-issuer, sync cancel (October 2022)".
 *
 * Run with: `dub run --single sync-cancel.d`
 *
 * Portability: prints a `SKIP:` line and exits 0 when io_uring is unavailable
 * (old kernel / sandbox) or when `REGISTER_SYNC_CANCEL` is missing (kernel
 * < 6.0, reported as `-EINVAL` / `-ENOSYS`). It returns nonzero only if a call
 * that should have worked fails. This host runs kernel 6.18, where the feature
 * is present and is exercised for real.
 */
module io_uring_sync_cancel;

import during;

import core.sys.linux.errno : ECANCELED, EINTR, EINVAL, ENOSYS;
import core.sys.posix.unistd : close, pipe;

import std.stdio : writefln, stderr;

int main()
{
    // The cookie we will both tag the poll with and match against on cancel.
    enum ulong cookie = 1;

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host",
            -setupRet);
        return 0;
    }

    // A pipe with no writer: POLLIN on the read end can never become ready, so
    // the poll request stays genuinely in-flight until we cancel it.
    int[2] fds;
    if (pipe(fds) != 0)
    {
        stderr.writefln("pipe() failed");
        return 1;
    }
    scope (exit) { close(fds[0]); close(fds[1]); }

    // Arm a single POLL_ADD for readability on the read end, tagged with `cookie`.
    io.putWith!((ref SubmissionEntry e, int fd) {
        e.prepPollAdd(fd, PollEvents.IN);
        e.user_data = cookie;
    })(fds[0]);

    const submitted = io.submit(0); // submit without waiting — nothing will complete yet
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Synchronous cancel: match by user_data (flags = 0, the default selector).
    // timeout {0,0} means "don't wait for the cancel itself to settle"; a poll
    // is cancellable immediately so this returns the match count right away.
    io_uring_sync_cancel_reg reg;
    reg.addr = cookie;          // match key: the poll's user_data
    reg.fd = -1;                // unused when matching by user_data
    reg.flags = 0;              // 0 => match by user_data
    reg.opcode = 0;
    reg.timeout.tv_sec = 0;
    reg.timeout.tv_nsec = 0;

    const cret = io.registerSyncCancel(reg);
    if (cret == -EINVAL || cret == -ENOSYS)
    {
        writefln("SKIP: IORING_REGISTER_SYNC_CANCEL unsupported (errno %d) — needs Linux 6.0+",
            -cret);
        return 0;
    }
    if (cret < 0)
    {
        stderr.writefln("registerSyncCancel failed: errno %d", -cret);
        return 1;
    }

    // A successful synchronous cancel guarantees the cancelled request's CQE is
    // already enqueued, so the completion is here now. Bound the wait anyway so a
    // misbehaving kernel can't hang us: `submitAndWaitMinTimeout` blocks at most
    // `ts` (one second) before giving up. (EXT_ARG-style waits need Linux 5.11+,
    // which is implied by the 6.0 feature we are already on.)
    const ts = KernelTimespec(1, 0); // {1s, 0ns}
    const waited = io.submitAndWaitMinTimeout(1, ts, 0);
    if (waited < 0 || io.empty)
    {
        stderr.writefln("no completion after sync cancel (wait returned %d)", waited);
        return 1;
    }
    const res = io.front.res;
    const echoed = io.front.user_data;
    io.popFront();

    if (echoed != cookie)
    {
        stderr.writefln("user_data mismatch: expected %d, got %d", cookie, echoed);
        return 1;
    }

    // A cancelled request reports -ECANCELED (some kernels surface -EINTR for
    // interrupted ops); either confirms the synchronous cancel took effect.
    if (res != -ECANCELED && res != -EINTR)
    {
        stderr.writefln("expected -ECANCELED, got res=%d", res);
        return 1;
    }

    // `cret` is the kernel's reported match count (often 0 for a poll the kernel
    // tears down inline); the authoritative proof is the poll's -ECANCELED CQE.
    writefln("ok: REGISTER_SYNC_CANCEL torn down the in-flight poll; CQE returned %s (res=%d, matches=%d)",
        res == -ECANCELED ? "-ECANCELED" : "-EINTR", res, cret);
    return 0;
}
