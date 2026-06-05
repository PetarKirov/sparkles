#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_epoll_wait"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — folding a legacy `epoll` set into the ring (`IORING_OP_EPOLL_WAIT`, Linux 6.15).
 *
 * Before 6.15 you bridged `io_uring` and `epoll` by adding the epoll fd as a
 * pollable fd (`IORING_OP_POLL_ADD` / `EPOLL_CTL`) and then calling `epoll_wait(2)`
 * synchronously once the ring told you the epoll set was readable. 6.15 added
 * `IORING_OP_EPOLL_WAIT`, which performs the `epoll_wait` *inside* the ring: you
 * submit an SQE pointing at an `epoll_event[]` buffer, and the matching CQE's
 * `res` reports how many ready events were written into it. This lets an existing
 * epoll-based event loop be migrated to `io_uring` one step at a time.
 *
 * Demonstrated here: build an epoll set watching the read end of a pipe for
 * `EPOLLIN`, write a byte to make it readable, then submit a single
 * `EPOLL_WAIT` SQE and verify it reports exactly one ready event for our pipe fd.
 * Because the pipe is already readable when we submit, the kernel can complete
 * the SQE immediately — no second thread, fully deterministic.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "6.15 — Zero-copy receive, epoll-wait, vectored fixed, query".
 *
 * Run with: `dub run --single epoll-wait.d`
 *
 * Portability: prints a `SKIP:` line and exits 0 when `io_uring` is unavailable
 * (old kernel / sandbox) or when this specific op is missing (kernel < 6.15,
 * surfaced as a probe miss or an `-EINVAL`/`-EOPNOTSUPP` CQE), so it stays green
 * in CI regardless of the host kernel.
 */
module io_uring_epoll_wait;

import during;

import core.sys.linux.epoll : epoll_create1, epoll_ctl, epoll_event, EPOLL_CTL_ADD, EPOLLIN;
import core.sys.posix.unistd : close, pipe, write;
import core.stdc.errno : EINVAL, EOPNOTSUPP, ENOSYS;

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

    // Probe whether the running kernel advertises IORING_OP_EPOLL_WAIT (Linux 6.15).
    // A miss here means the op simply doesn't exist on this kernel — skip cleanly.
    auto probe = io.probe();
    if (cast(bool) probe && !probe.isSupported(Operation.EPOLL_WAIT))
    {
        writefln("SKIP: IORING_OP_EPOLL_WAIT not supported (kernel < 6.15)");
        return 0;
    }

    // A pipe gives us a cheap, loopback-only fd to watch for readability.
    int[2] p;
    if (pipe(p) != 0)
    {
        stderr.writefln("pipe() failed");
        return 1;
    }
    scope (exit) { close(p[0]); close(p[1]); }

    // Build a classic epoll set and register the pipe's read end for EPOLLIN.
    int ep = epoll_create1(0);
    if (ep < 0)
    {
        stderr.writefln("epoll_create1() failed");
        return 1;
    }
    scope (exit) close(ep);

    epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = p[0];
    if (epoll_ctl(ep, EPOLL_CTL_ADD, p[0], &ev) != 0)
    {
        stderr.writefln("epoll_ctl(ADD) failed");
        return 1;
    }

    // Make the read end readable *before* submitting, so the EPOLL_WAIT SQE can
    // complete immediately — keeps the example deterministic and single-threaded.
    ubyte one = 0xAA;
    if (write(p[1], &one, 1) != 1)
    {
        stderr.writefln("write() to pipe failed");
        return 1;
    }

    // Submit IORING_OP_EPOLL_WAIT: the kernel runs epoll_wait against `ep` and
    // fills `out_` with up to its length ready events; the CQE's `res` is the count.
    epoll_event[4] out_;
    io.putWith!(
        (ref SubmissionEntry e, int epfd, epoll_event[] dst)
        {
            e.prepEpollWait(epfd, dst, 0);
            e.user_data = 1;
        })(ep, out_[]);

    const submitted = io.submit(1);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    io.wait(1);
    const res = io.front.res;
    io.popFront();

    // Some kernels accept setup/submit but reject the op at completion time — treat
    // -EINVAL / -EOPNOTSUPP / -ENOSYS as "feature absent" rather than a hard failure.
    if (res == -EINVAL || res == -EOPNOTSUPP || res == -ENOSYS)
    {
        writefln("SKIP: IORING_OP_EPOLL_WAIT rejected by kernel (errno %d) — feature unavailable", -res);
        return 0;
    }

    if (res < 0)
    {
        stderr.writefln("EPOLL_WAIT completed with error: errno %d", -res);
        return 1;
    }

    if (res != 1)
    {
        stderr.writefln("expected exactly 1 ready event, got res=%d", res);
        return 1;
    }

    if (out_[0].data.fd != p[0] || (out_[0].events & EPOLLIN) == 0)
    {
        stderr.writefln("ready event did not match the pipe fd / EPOLLIN");
        return 1;
    }

    writefln("ok: IORING_OP_EPOLL_WAIT reported %d ready event for pipe fd %d (EPOLLIN), epoll folded into the ring",
        res, out_[0].data.fd);
    return 0;
}
