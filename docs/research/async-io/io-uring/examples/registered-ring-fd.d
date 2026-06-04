#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_registered_ring_fd"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — registered ring fd (`IORING_REGISTER_RING_FDS`, Linux 5.18).
 *
 * Every `io_uring_enter(2)` normally takes the ring's file descriptor as its
 * first argument, so the kernel must do an `fdget()` to translate that integer
 * into the backing `struct file` and a matching `fdput()` afterwards — once per
 * syscall. For submit-heavy, syscall-per-batch workloads that fdget/fdput pair
 * is pure overhead. `IORING_REGISTER_RING_FDS` lets userspace register the ring
 * fd once and thereafter pass a small *registered index* plus the
 * `IORING_ENTER_REGISTERED_RING` flag, so the kernel skips the fd lookup
 * entirely on the hot path.
 *
 * `during` wires this up transparently: after `registerRingFd()` succeeds it
 * passes the registered index + `ENTER_REGISTERED_RING` on every subsequent
 * `submit`/`wait`. We prove the registered ring is functional by running a full
 * NOP submit/complete cycle through it, then revert with `unregisterRingFd()`.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.18 — Ring-fd registration, msg-ring, linked-file".
 *
 * Run with: `dub run --single registered-ring-fd.d`
 *
 * Portability: if io_uring is unavailable, or the kernel predates 5.18 (the
 * register call returns `-EINVAL`/`-EOPNOTSUPP`/`-ENOSYS`), the program prints a
 * `SKIP:` line and exits 0 so it stays green regardless of the host kernel.
 */
module io_uring_registered_ring_fd;

import during;

import core.stdc.errno : EINVAL, EOPNOTSUPP, ENOSYS;

import std.stdio : writefln, stderr;

int main()
{
    enum ulong cookie = 0x5180_F00D; // 5.18 marker, just a recognizable user_data

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Register the ring's own fd. On success `during` swaps in the registered
    // index + ENTER_REGISTERED_RING for all later io_uring_enter(2) calls.
    const regRet = io.registerRingFd();
    if (regRet == -EINVAL || regRet == -EOPNOTSUPP || regRet == -ENOSYS)
    {
        writefln("SKIP: IORING_REGISTER_RING_FDS unsupported (errno %d) — needs Linux 5.18+", -regRet);
        return 0;
    }
    if (regRet < 0)
    {
        // Any other negative result is a genuine, unexpected failure.
        stderr.writefln("registerRingFd failed: errno %d", -regRet);
        return 1;
    }

    // From here on, every submit/wait reaches the kernel via the *registered*
    // ring index — no per-syscall fdget/fdput. Drive a NOP through it to prove
    // the registered ring still submits and completes correctly.
    io.putWith!((ref SubmissionEntry e) {
        e.prepNop();
        e.user_data = cookie;
    })();

    const submitted = io.submit(1); // uses the registered ring fd under the hood
    if (submitted < 0)
    {
        stderr.writefln("submit (via registered ring) failed: errno %d", -submitted);
        return 1;
    }

    io.wait(1);
    const res = io.front.res;
    const echoed = io.front.user_data;
    io.popFront();

    if (res < 0)
    {
        stderr.writefln("NOP via registered ring completed with error: errno %d", -res);
        return 1;
    }
    if (echoed != cookie)
    {
        stderr.writefln("user_data mismatch: expected 0x%X, got 0x%X", cookie, echoed);
        return 1;
    }

    // Revert to using the real ring fd again. Mirrors liburing's
    // io_uring_unregister_ring_fd; -EINVAL here would mean "wasn't registered".
    const unregRet = io.unregisterRingFd();
    if (unregRet < 0)
    {
        stderr.writefln("unregisterRingFd failed: errno %d", -unregRet);
        return 1;
    }

    writefln("ok: registered ring fd, ran a NOP through it (res=%d, user_data 0x%X), then unregistered — io_uring_enter skips per-call fdget/fdput",
        res, echoed);
    return 0;
}
