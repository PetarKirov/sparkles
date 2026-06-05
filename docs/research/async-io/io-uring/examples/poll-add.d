#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_poll_add"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — readiness notification with `IORING_OP_POLL_ADD` (Linux 5.1).
 *
 * `POLL_ADD` is io_uring's answer to `poll(2)`/`epoll`: arm a one-shot
 * readiness watch on a file descriptor and get a CQE when it becomes ready,
 * without ever calling `poll` from userspace. It is the building block for
 * event-loop style I/O — the kernel does the waiting and notifies you through
 * the same completion ring every other op uses.
 *
 * This example creates a libc `pipe()`, arms a `POLL_ADD` for `POLLIN` on the
 * read end, then writes one byte into the write end. Once the read end is
 * readable the CQE fires, and (per during's `tests/poll.d`) `res` carries the
 * set of ready poll events — a positive value with the `POLLIN` bit set.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "5.1 — The introduction (May 2019)".
 *
 * Run with: `dub run --single poll-add.d`
 *
 * Portability: `POLL_ADD` has existed since the 5.1 introduction, so it works on
 * any kernel that has io_uring at all. If io_uring is unavailable (too old, or
 * blocked by a seccomp/container policy) the program prints a `SKIP:` line and
 * exits 0 so it stays green in CI regardless of the host kernel.
 */
module io_uring_poll_add;

import during;

import core.sys.posix.poll : POLLIN;
import core.sys.posix.unistd : close, pipe, write;

import std.stdio : stderr, writefln, writeln;

int main()
{
    // user_data cookie identifying this poll op when its CQE comes back.
    enum ulong cookie = 1;

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // A classic anonymous pipe: fds[0] is the read end, fds[1] the write end.
    int[2] fds;
    if (pipe(fds) != 0)
    {
        stderr.writeln("SKIP: pipe() failed");
        return 0;
    }
    scope (exit)
    {
        close(fds[0]);
        close(fds[1]);
    }

    // Arm a one-shot poll on the read end for readability (POLLIN). The kernel
    // will park this until the fd is readable, then post a CQE.
    io.putWith!((ref SubmissionEntry e, int readFd) {
        e.prepPollAdd(readFd, PollEvents.IN);
        e.user_data = cookie;
    })(fds[0]);

    // submit(0) flushes the SQ without blocking on a completion count — the poll
    // is now armed in the kernel but the fd is not yet readable.
    const submitted = io.submit(0);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Make the read end readable: one byte into the write end is enough to
    // satisfy POLLIN and trip the armed poll.
    immutable ubyte one = 0x2A;
    const wrote = write(fds[1], &one, 1);
    if (wrote != 1)
    {
        stderr.writefln("write to pipe failed (ret %d)", wrote);
        return 1;
    }

    // Block for the poll completion.
    io.wait(1);
    const res = io.front.res;
    const echoed = io.front.user_data;
    io.popFront();

    if (res < 0)
    {
        stderr.writefln("POLL_ADD completed with error: errno %d", -res);
        return 1;
    }

    if (echoed != cookie)
    {
        stderr.writefln("user_data mismatch: expected %d, got %d", cookie, echoed);
        return 1;
    }

    // On success `res` is the bitmask of ready events; POLLIN must be set since
    // the pipe's read end now has data.
    if (!(res & POLLIN))
    {
        stderr.writefln("expected POLLIN in ready mask, got 0x%X", res);
        return 1;
    }

    writefln("ok: POLL_ADD reported readiness (res=0x%X, POLLIN set) on the pipe read end", res);
    return 0;
}
