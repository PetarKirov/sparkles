#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_napi"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — NAPI busy-poll registration (`IORING_REGISTER_NAPI`, Linux 6.9).
 *
 * NAPI busy-polling lets a ring spin on the network stack's NAPI receive path
 * for a bounded window instead of sleeping until an interrupt fires — trading
 * CPU cycles for lower receive latency on networked completions. It is
 * configured per-ring (not per-NIC) via `io_uring_register(IORING_REGISTER_NAPI)`,
 * which `during` exposes as `Uring.registerNapi`.
 *
 * This example builds an `io_uring_napi` config (a busy-poll timeout in
 * microseconds plus the `prefer_busy_poll` flag), registers it, prints the
 * parameters on success, then tears it back down with `unregisterNapi`.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 * § "6.9 — NAPI busy-poll, ftruncate (May 2024)".
 *
 * Run with: `dub run --single napi.d`
 *
 * Portability: NAPI busy-poll arrived in 6.9 and can additionally be gated by
 * the running kernel's network configuration. If `io_uring` is unavailable, or
 * `registerNapi` reports `-EINVAL`/`-EOPNOTSUPP`/`-ENOSYS`, the program prints a
 * `SKIP:` line and exits 0 so it stays green in CI regardless of the host.
 */
module napi_example;

import during;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS;

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

    // NAPI busy-poll config: spin the NAPI receive path for up to 50us before
    // falling back to interrupt-driven wakeups, and prefer busy polling.
    io_uring_napi napi;
    napi.busy_poll_to = 50;        // busy-poll timeout, microseconds
    napi.prefer_busy_poll = 1;     // prefer busy poll over interrupts

    const regRet = io.registerNapi(napi);
    if (regRet == -EINVAL || regRet == -EOPNOTSUPP || regRet == -ENOSYS)
    {
        // Kernel < 6.9, or NAPI busy-poll not available in this environment.
        // This is an expected outcome on hosts without NAPI support.
        writefln("SKIP: IORING_REGISTER_NAPI unsupported here (errno %d) — needs Linux 6.9+ with NAPI busy-poll", -regRet);
        return 0;
    }
    if (regRet < 0)
    {
        stderr.writefln("registerNapi failed unexpectedly: errno %d", -regRet);
        return 1;
    }

    // On success the kernel writes the *previous* config back into `napi`, but
    // the values we just registered are the ones that matter for the demo.
    writefln("ok: registered NAPI busy-poll (busy_poll_to=%dus, prefer_busy_poll=%d)",
        50, 1);

    // Tear the registration back down. `unregisterNapi` fills its argument with
    // the configuration that was in effect; we don't need it, so pass a fresh one.
    io_uring_napi prev;
    const unregRet = io.unregisterNapi(prev);
    if (unregRet < 0)
    {
        stderr.writefln("unregisterNapi failed: errno %d", -unregRet);
        return 1;
    }

    return 0;
}
