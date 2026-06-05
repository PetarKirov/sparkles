#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_futex"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — async futex wait/wake (`IORING_OP_FUTEX_WAIT`, Linux 6.7).
 *
 * Before 6.7 a thread that wanted to block on a futex had to call `futex(2)`
 * directly, taking it out of the io_uring completion-driven event loop. The
 * 6.7 `FUTEX_WAIT` / `FUTEX_WAKE` ops let a ring park on a 32-bit futex word
 * asynchronously: the wait turns into a CQE that lands whenever the word is
 * woken, so a futex hand-off composes with every other queued operation.
 *
 * This example is a two-thread ping-pong. The main thread submits a
 * `FUTEX_WAIT` against a private 32-bit futex (`FUTEX2_SIZE_U32 |
 * FUTEX2_PRIVATE`, matching any bit via `FUTEX_BITSET_MATCH_ANY`). A helper
 * pthread issues a *legacy* `futex(2)` `FUTEX_WAKE_PRIVATE` to wake it — the
 * io_uring FUTEX2 waiter and the classic futex(2) waker share the same kernel
 * hash bucket, so they interoperate. The helper retries on a short interval
 * (bounded to ~1s) to defeat the inherent race between SQE submission and the
 * kernel actually parking the waiter. We assert the wait CQE `res == 0`.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "6.7 — Futex, waitid, read-multishot (January 2024)".
 *
 * Run with: `dub run --single futex.d`
 *
 * Portability: if the running kernel has no `io_uring`, or is older than 6.7
 * (no `FUTEX_WAIT` op — detected via `io.probe()` or a `-EINVAL`/`-EOPNOTSUPP`
 * completion), the program prints a `SKIP:` line and exits 0 so it stays green
 * in CI regardless of the host kernel.
 */
module io_uring_futex;

import during;

import core.sys.posix.pthread;
import core.sys.posix.unistd : usleep;
import core.atomic : atomicLoad, atomicStore, MemoryOrder;

import std.stdio : writefln, stderr;

// errno values we treat as "feature unsupported" rather than a hard failure.
private enum EINVAL = 22;
private enum EOPNOTSUPP = 95;

// Legacy futex(2) syscall number + flags, used by the waker thread.
version (X86_64) private enum SYS_futex = 202;
else version (AArch64) private enum SYS_futex = 98;
else version (X86) private enum SYS_futex = 240;
else static assert(0, "Unsupported platform for the futex(2) waker");

private enum FUTEX_WAKE = 1;
private enum FUTEX_PRIVATE_FLAG = 128;
private enum FUTEX_WAKE_PRIVATE = FUTEX_WAKE | FUTEX_PRIVATE_FLAG;

private extern (C) int syscall(int sysno, ...) nothrow @nogc @system;

// Shared state between the main thread (waiter) and the helper (waker).
private struct WakeCtx
{
    uint* word; // the futex word both threads agree on
    shared int stop; // main thread sets this once the CQE arrives
    int attempts; // how many wake retries it took (diagnostic)
}

// Helper thread: repeatedly issue a legacy FUTEX_WAKE on the shared word until
// the main thread signals `stop` (it got its completion) or we hit the retry
// cap. Retrying defeats the race where the wake fires before the kernel has
// parked the io_uring waiter. @nogc/nothrow so it is safe as a raw pthread fn.
private extern (C) void* wakeWorker(void* arg) @system nothrow @nogc
{
    auto ctx = cast(WakeCtx*) arg;
    foreach (i; 0 .. 200) // 200 * 5ms = ~1s upper bound
    {
        if (atomicLoad!(MemoryOrder.acq)(ctx.stop))
            break;
        usleep(5_000);
        ctx.attempts = i + 1;
        syscall(SYS_futex, cast(void*) ctx.word, FUTEX_WAKE_PRIVATE, 1, null, null, 0);
    }
    return null;
}

int main()
{
    enum ulong cookie = 0xFADE;

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Static capability check: kernels < 6.7 don't advertise FUTEX_WAIT in the
    // probe, so we can skip cleanly before ever submitting an SQE.
    auto probe = io.probe();
    if (!cast(bool) probe || !probe.isSupported(Operation.FUTEX_WAIT))
    {
        writefln("SKIP: IORING_OP_FUTEX_WAIT unsupported (kernel < 6.7)");
        return 0;
    }

    // The futex word starts at 0; FUTEX_WAIT below uses expected value 0, so the
    // kernel parks the ring until someone (our helper) wakes the word.
    uint word = 0;
    WakeCtx ctx;
    ctx.word = &word;

    // Spawn the waker before submitting so it is already retrying by the time
    // the kernel parks our waiter.
    pthread_t tid;
    if (pthread_create(&tid, null, &wakeWorker, &ctx) != 0)
    {
        stderr.writefln("pthread_create failed");
        return 1;
    }

    // Submit the async FUTEX_WAIT. `val` is the expected current value (0); the
    // request completes when the word is woken (or differs from `val`).
    io.putWith!(
        (ref SubmissionEntry e, uint* w) {
        e.prepFutexWait(w, 0, FUTEX_BITSET_MATCH_ANY, FUTEX2_SIZE_U32 | FUTEX2_PRIVATE, 0);
        e.user_data = cookie;
    })(&word);

    const submitted = io.submit(1);
    if (submitted != 1)
    {
        atomicStore!(MemoryOrder.rel)(ctx.stop, 1);
        pthread_join(tid, null);
        stderr.writefln("submit failed: returned %d", submitted);
        return 1;
    }

    // Block for the wait completion. The helper thread is hammering FUTEX_WAKE,
    // so this is bounded by the helper's ~1s retry budget.
    io.wait(1);
    const res = io.front.res;
    const echoed = io.front.user_data;
    io.popFront();

    // Tell the helper to stop and reap it.
    atomicStore!(MemoryOrder.rel)(ctx.stop, 1);
    pthread_join(tid, null);

    // Runtime fallback: even if the probe lied, an unsupported op reports these.
    if (res == -EINVAL || res == -EOPNOTSUPP)
    {
        writefln("SKIP: IORING_OP_FUTEX_WAIT rejected at runtime (res=%d) — kernel < 6.7", res);
        return 0;
    }

    if (res < 0)
    {
        stderr.writefln("FUTEX_WAIT completed with error: errno %d", -res);
        return 1;
    }

    if (echoed != cookie)
    {
        stderr.writefln("user_data mismatch: expected 0x%X, got 0x%X", cookie, echoed);
        return 1;
    }

    writefln("ok: io_uring FUTEX_WAIT (res=%d) woken by a legacy futex(2) waker after %d attempt(s)",
        res, ctx.attempts);
    return 0;
}
