#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_futex_waitv"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — vectored futex wait (`IORING_OP_FUTEX_WAITV`, Linux 6.7).
 *
 * `FUTEX_WAITV` arms a wait on a *vector* of futexes at once and completes as
 * soon as *any one* of them is woken — the async, batched counterpart of the
 * legacy `futex_waitv(2)` syscall. This is the building block a runtime uses to
 * block a task on several wakeup sources (e.g. several condition words) without
 * burning a thread per source.
 *
 * This example builds an array of two `futex_waitv` entries over two distinct
 * 32-bit words, submits a single `prepFutexWaitv(&v[0], 2, 0)`, and spins up a
 * helper pthread that wakes the *second* word via the legacy `futex(2)`
 * `FUTEX_WAKE_PRIVATE` syscall. The io_uring FUTEX2 waiter and the legacy futex
 * share the same kernel hash bucket for a given `uaddr`, so a legacy wake on a
 * matching, `FUTEX2_PRIVATE`-armed address wakes the io_uring waiter. We assert
 * the completion `res >= 0` (a wake / the index of the woken futex), not an error.
 *
 * The helper retries every 5 ms (bounded) to defeat the inherent race between
 * submission and the kernel actually parking the waiter; the main thread also
 * bounds its `wait` with a linked `TIMEOUT` so a misbehaving kernel can't hang.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "6.7 — Futex, waitid, read-multishot (January 2024)".
 *
 * Run with: `dub run --single futex-waitv.d`
 *
 * Portability: if the running kernel has no `io_uring` (too old / blocked by a
 * seccomp or container policy), or lacks `FUTEX_WAITV` (kernel < 6.7), the
 * program prints a `SKIP:` line and exits 0 so it stays green in CI regardless
 * of the host kernel. This box runs 6.18, where the feature is present.
 */
module io_uring_futex_waitv;

import during;

import std.stdio : writefln, stderr;

import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS;
import core.sys.posix.pthread;
import core.sys.posix.unistd : usleep;

// `SYS_futex` (the legacy futex(2) syscall) is universally available on Linux.
// We use it from the helper thread to issue a `FUTEX_WAKE_PRIVATE`.
version (X86_64) private enum SYS_futex = 202;
else version (X86) private enum SYS_futex = 240;
else version (AArch64) private enum SYS_futex = 98;
else static assert(0, "Unsupported platform for SYS_futex constant");

private enum FUTEX_WAKE         = 1;
private enum FUTEX_PRIVATE_FLAG = 128;
private enum FUTEX_WAKE_PRIVATE = FUTEX_WAKE | FUTEX_PRIVATE_FLAG;

private extern (C) int syscall(int sysno, ...) nothrow @nogc @system;

// Shared state between the main thread and the wake helper.
private struct WakeCtx
{
    uint*      word;       // address of the futex word the helper will wake
    shared int stop;       // set by main once the CQE has arrived
    int        attempts;   // number of wake attempts the helper made
}

// Helper thread: repeatedly `FUTEX_WAKE_PRIVATE`s `ctx.word` until the main
// thread sets `stop`. Bounded to ~1s of attempts so it can never hang the run.
private extern (C) void* wakeWorker(void* arg) @system nothrow @nogc
{
    auto ctx = cast(WakeCtx*) arg;
    foreach (i; 0 .. 200) // up to ~1s (200 * 5ms)
    {
        // Re-check before sleeping so we exit promptly once main signals stop.
        if (atomicLoad!(MemoryOrder.acq)(ctx.stop)) break;
        usleep(5_000); // 5ms
        ctx.attempts = i + 1;
        // arg2 = val = 1 => wake at most one waiter on this address.
        syscall(SYS_futex, cast(void*) ctx.word, FUTEX_WAKE_PRIVATE, 1, null, null, 0);
    }
    return null;
}

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Two distinct futex words. Both armed with val=0, matching their current
    // value, so the wait genuinely parks (a mismatch would return -EAGAIN).
    uint[2] words = [0, 0];

    // The vector of futexes to wait on. FUTEX2_SIZE_U32 selects a 32-bit futex
    // (the only size most arches support); FUTEX2_PRIVATE puts it in the
    // process-private hash so a legacy FUTEX_WAKE_PRIVATE on the same address
    // can match it.
    futex_waitv[2] vec;
    foreach (i; 0 .. 2)
    {
        vec[i].val   = 0; // expected value — must equal *uaddr for the wait to arm
        vec[i].uaddr = cast(ulong) &words[i];
        vec[i].flags = FUTEX2_SIZE_U32 | FUTEX2_PRIVATE;
    }

    // Spin up the helper that will wake the *second* word. FUTEX_WAITV completes
    // when ANY entry is woken, so waking words[1] must complete the whole wait.
    WakeCtx ctx;
    ctx.word = &words[1];

    pthread_t tid;
    const pr = pthread_create(&tid, null, &wakeWorker, &ctx);
    if (pr != 0)
    {
        stderr.writefln("pthread_create failed: errno %d", pr);
        return 1;
    }

    // Submit the vectored wait, linked to a TIMEOUT so the ring is never blocked
    // indefinitely: if the wake never lands, the TIMEOUT fires and unblocks
    // `wait`, and the wait CQE comes back -ECANCELED. IO_LINK means the timeout
    // is the deadline for the preceding waitv.
    enum ulong WAITV_DATA = 0xF07E;
    enum ulong TIMEOUT_DATA = 0x71_E0;

    io.putWith!(
        (ref SubmissionEntry e, futex_waitv* v)
        {
            e.prepFutexWaitv(v, 2, 0); // wait on both entries; wake on any
            e.user_data = WAITV_DATA;
            e.flags |= SubmissionEntryFlags.IO_LINK;
        })(&vec[0]);

    // 1.5s ceiling — comfortably above the helper's first 5ms attempt, well
    // under the 2s budget. KernelTimespec is {tv_sec, tv_nsec}.
    KernelTimespec ts = { tv_sec: 1, tv_nsec: 500_000_000 };
    io.putWith!(
        (ref SubmissionEntry e, KernelTimespec* t)
        {
            e.prepTimeout(*t, 0, TimeoutFlags.REL);
            e.user_data = TIMEOUT_DATA;
        })(&ts);

    const submitted = io.submit(0);
    if (submitted < 0)
    {
        atomicStore!(MemoryOrder.rel)(ctx.stop, 1);
        pthread_join(tid, null);
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Drain both completions (the waitv and the linked timeout). We need at most
    // two CQEs; capture the waitv result by user_data.
    int waitvRes = int.min;
    bool sawWaitv = false;
    foreach (_; 0 .. 2)
    {
        io.wait(1);
        const cqe = io.front;
        if (cqe.user_data == WAITV_DATA)
        {
            waitvRes = cqe.res;
            sawWaitv = true;
        }
        io.popFront();
        if (sawWaitv) break; // got what we came for; the timeout CQE (if any) can drain on exit
    }

    // Tell the helper to stop and join it before inspecting results.
    atomicStore!(MemoryOrder.rel)(ctx.stop, 1);
    pthread_join(tid, null);

    if (!sawWaitv)
    {
        stderr.writefln("no FUTEX_WAITV completion observed");
        return 1;
    }

    // -EINVAL / -EOPNOTSUPP / -ENOSYS => the op isn't supported on this kernel.
    if (waitvRes == -EINVAL || waitvRes == -EOPNOTSUPP || waitvRes == -ENOSYS)
    {
        writefln("SKIP: IORING_OP_FUTEX_WAITV unsupported on this kernel (res=%d)", waitvRes);
        return 0;
    }

    // A successful wake reports res >= 0 (the kernel returns the index of the
    // woken futex). A negative value here means the wait was cancelled by the
    // timeout (the helper never managed to wake it) or another genuine failure.
    if (waitvRes < 0)
    {
        stderr.writefln("FUTEX_WAITV was not woken: res=%d (errno %d), helper made %d attempts",
            waitvRes, -waitvRes, ctx.attempts);
        return 1;
    }

    writefln("ok: FUTEX_WAITV woken (res=%d, woken futex index) after %d helper wake attempt(s)",
        waitvRes, ctx.attempts);
    return 0;
}
