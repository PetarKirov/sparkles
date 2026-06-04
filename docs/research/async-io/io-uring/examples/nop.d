#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_nop"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — the minimal submit/complete cycle (`IORING_OP_NOP`, Linux 5.1).
 *
 * This is the "hello world" of `io_uring`: it sets up a ring, places one
 * `NOP` submission queue entry (SQE), submits it, waits for the matching
 * completion queue entry (CQE), and verifies the `user_data` cookie round-trips.
 * It exercises every part of the core machinery from the 5.1 introduction —
 * `io_uring_setup` (here via `Uring.setup`), the shared SQ/CQ rings, and the
 * `submit` / `wait` / `front` / `popFront` flow that every later op reuses.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "5.1 — The introduction".
 *
 * Run with: `dub run --single nop.d`
 *
 * Portability: if the running kernel has no `io_uring` (too old, or blocked by a
 * seccomp/container policy), the program prints a `SKIP:` line and exits 0 so it
 * stays green in CI regardless of the host kernel.
 */
module io_uring_nop;

import during;

import std.stdio : writefln, stderr;

int main()
{
    // `IORING_OP_NOP` carries this cookie through the kernel and hands it back
    // on the CQE — the mechanism every op uses to correlate completions.
    enum ulong cookie = 0xC0FFEE;

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Place a single NOP SQE. `putWith` clears the entry, runs the prep callback,
    // and advances the submission queue tail in one step.
    io.putWith!((ref SubmissionEntry e) {
        e.prepNop();
        e.user_data = cookie;
    })();

    const submitted = io.submit(1);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Block until at least one completion is ready, then consume it.
    io.wait(1);
    const res = io.front.res;
    const echoed = io.front.user_data;
    io.popFront();

    if (res < 0)
    {
        stderr.writefln("NOP completed with error: errno %d", -res);
        return 1;
    }

    if (echoed != cookie)
    {
        stderr.writefln("user_data mismatch: expected 0x%X, got 0x%X", cookie, echoed);
        return 1;
    }

    writefln("ok: NOP completed (res=%d), user_data 0x%X round-tripped through the ring", res, echoed);
    return 0;
}
