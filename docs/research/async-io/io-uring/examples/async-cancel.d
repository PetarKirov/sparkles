#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_async_cancel"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — cancel an in-flight request (`IORING_OP_ASYNC_CANCEL`, Linux 5.5).
 *
 * 5.5 gave `io_uring` the ability to cancel a *pending* submission by its
 * `user_data` cookie. This example arms a `POLL_ADD` on the read end of a pipe
 * that nobody ever writes to — so the poll can never complete on its own — then
 * submits an `ASYNC_CANCEL` keyed to that same request. The kernel tears the
 * poll down and reports two completions:
 *
 *   - the poll CQE completes with `res == -ECANCELED` (it was cancelled), and
 *   - the cancel CQE completes with `res >= 0` — historically `0`, but newer
 *     kernels report the count of requests found & cancelled — or `-EALREADY`
 *     if the kernel had already started completing it.
 *
 * `during`'s `prepPollAdd`/`prepCancel` key off the *address* of a stable
 * variable: `e.setUserData(key)` stores `&key` in the SQE's `user_data`, and
 * `e.prepCancel(key)` puts that same `&key` into the cancel's match field — so
 * the two refer to the same in-flight request. The cancel SQE carries its own
 * distinct `user_data` cookie so we can tell the two CQEs apart.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.5 — Accept/connect, cancel, link-timeout (January 2020)".
 *
 * Run with: `dub run --single async-cancel.d`
 *
 * Portability: prints a `SKIP:` line and exits 0 if `io_uring` is unavailable
 * (old kernel / sandbox) or if `POLL_ADD`/`ASYNC_CANCEL` are not supported on
 * the running kernel (both predate the probe, but we guard defensively), so it
 * stays green in CI regardless of host kernel.
 */
module io_uring_async_cancel;

import during;

import core.sys.linux.errno : ECANCELED, EALREADY, EINVAL, EOPNOTSUPP, ENOSYS;
import core.sys.posix.unistd : pipe, close, read;

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

    // Defensive capability check: POLL_ADD (5.1) and ASYNC_CANCEL (5.5) both
    // predate the operation probe, but if the kernel reports them unsupported we
    // skip rather than fail.
    auto probe = io.probe();
    if (cast(bool)probe
        && (!probe.isSupported(Operation.POLL_ADD) || !probe.isSupported(Operation.ASYNC_CANCEL)))
    {
        writefln("SKIP: POLL_ADD/ASYNC_CANCEL not supported by this kernel's io_uring");
        return 0;
    }

    // A pipe whose read end never becomes readable (we never write to the write
    // end): the perfect target for a poll that we intend to cancel.
    int[2] fds;
    if (pipe(fds) != 0)
    {
        stderr.writefln("pipe() failed");
        return 1;
    }
    scope (exit) { close(fds[0]); close(fds[1]); }
    const readFd = fds[0];

    // `pollKey`'s address is the request's user_data; `prepCancel` keys off the
    // very same address, so it matches this poll. Must outlive the operation.
    int pollKey;
    enum ulong cancelCookie = 2;

    // SQE #1: poll the read end for readability. It will never fire on its own.
    io.putWith!((ref SubmissionEntry e, ref int key, int fd) {
        e.prepPollAdd(fd, PollEvents.IN);
        e.setUserData(key); // user_data := &key
    })(pollKey, readFd);

    // SQE #2: cancel the request identified by &pollKey.
    //
    // We hand-roll what `during`'s `prepCancel` does internally — set the
    // ASYNC_CANCEL opcode with `addr` pointing at the match key — because
    // `prepCancel`'s default-flag path is mis-typed in 0.5.0 (it assigns a bare
    // `uint` to the `CancelFlags`-typed union field and fails to compile). The
    // match field (`addr`) must equal the poll's `user_data`, i.e. `&pollKey`.
    io.putWith!((ref SubmissionEntry e, ref int key) {
        e.prepRW(Operation.ASYNC_CANCEL, -1, cast(void*)&key);
        e.cancel_flags = CancelFlags.init; // no CANCEL_ALL/FD/etc — key off user_data
        e.user_data = cancelCookie;
    })(pollKey);

    const submitted = io.submit(2);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Both the poll (cancelled) and the cancel op produce a completion.
    io.wait(2);

    bool sawPoll, sawCancel;
    int pollRes, cancelRes;
    const ulong pollUserData = cast(ulong)cast(void*)&pollKey;

    foreach (_; 0 .. 2)
    {
        if (io.empty) break;
        const c = io.front;
        if (c.user_data == pollUserData)
        {
            sawPoll = true;
            pollRes = c.res;
        }
        else if (c.user_data == cancelCookie)
        {
            sawCancel = true;
            cancelRes = c.res;
        }
        io.popFront();
    }

    if (!sawPoll || !sawCancel)
    {
        stderr.writefln("missing completion(s): sawPoll=%s sawCancel=%s", sawPoll, sawCancel);
        return 1;
    }

    // The cancelled poll must report -ECANCELED.
    if (pollRes != -ECANCELED)
    {
        stderr.writefln("poll CQE: expected -ECANCELED, got res=%d", pollRes);
        return 1;
    }

    // The cancel op succeeds with res >= 0 — historically 0, but newer kernels
    // report the *count* of requests found and cancelled (here 1). -EALREADY
    // means the request had already started completing (also a success: the
    // poll still ends up -ECANCELED).
    if (cancelRes < 0 && cancelRes != -EALREADY)
    {
        // -EINVAL/-EOPNOTSUPP/-ENOSYS here would mean the op isn't really
        // supported despite the probe — treat as SKIP, not failure.
        if (cancelRes == -EINVAL || cancelRes == -EOPNOTSUPP || cancelRes == -ENOSYS)
        {
            writefln("SKIP: ASYNC_CANCEL returned errno %d — unsupported on this kernel", -cancelRes);
            return 0;
        }
        stderr.writefln("cancel CQE: expected res >= 0 or -EALREADY, got res=%d", cancelRes);
        return 1;
    }

    writefln("ok: ASYNC_CANCEL torn down the poll (poll res=%d=-ECANCELED, cancel res=%d)",
        pollRes, cancelRes);
    return 0;
}
