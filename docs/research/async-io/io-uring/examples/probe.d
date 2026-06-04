#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_probe"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — capability detection via `IORING_REGISTER_PROBE` (Linux 5.6).
 *
 * Before 5.6, the only portable way to learn whether the kernel implemented a
 * given `io_uring` opcode was to submit it and inspect the completion for
 * `-EINVAL`. `IORING_REGISTER_PROBE` replaced that guesswork with a proper
 * query: the kernel fills an `io_uring_probe` table reporting, per opcode,
 * whether it is supported. This is THE mechanism a portable program uses to
 * decide at runtime which fast paths it may take on the host kernel.
 *
 * Here we set up a ring, fetch the probe table (`Uring.probe`, which wraps the
 * register call), and print a compact support report for a curated list of
 * historically interesting opcodes — from the original 5.1 `NOP`/`READ`/`WRITE`
 * through `SEND_ZC` (5.19), `FUTEX_WAIT` (6.7), `RECV_ZC`/`PIPE` (6.x), and the
 * 128-byte `NOP128`. Because it only *probes*, this example runs and succeeds
 * on every kernel that has `io_uring` at all — newer opcodes simply report
 * `no` rather than failing.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 * § "5.6 — The filesystem/syscall expansion (March 2020)".
 *
 * Run with: `dub run --single probe.d`
 *
 * Portability: if the host has no `io_uring`, or the kernel is older than 5.6
 * (so `IORING_REGISTER_PROBE` itself is unavailable and the probe fetch fails),
 * the program prints a `SKIP:` line and exits 0 so it stays green in CI.
 */
module io_uring_probe;

import during;

import std.stdio : writef, writefln, stderr;

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // `IORING_REGISTER_PROBE`: ask the kernel for its per-opcode support table.
    // `cast(bool)probe` is false (and `probe.error` holds -errno) when the
    // register call is unavailable — e.g. a pre-5.6 kernel that has io_uring
    // but not the PROBE register op.
    Probe probe = io.probe();
    if (!cast(bool) probe)
    {
        writefln("SKIP: IORING_REGISTER_PROBE unavailable (errno %d) — needs Linux 5.6+",
            -probe.error);
        return 0;
    }

    // A curated tour of the opcode timeline. The label is just for the report;
    // the kernel's verdict comes from `probe.isSupported`.
    static struct Op { Operation op; string name; }
    static immutable Op[] tour = [
        Op(Operation.NOP, "NOP"),
        Op(Operation.READ, "READ"),
        Op(Operation.WRITE, "WRITE"),
        Op(Operation.ACCEPT, "ACCEPT"),
        Op(Operation.CONNECT, "CONNECT"),
        Op(Operation.SEND, "SEND"),
        Op(Operation.RECV, "RECV"),
        Op(Operation.OPENAT, "OPENAT"),
        Op(Operation.TIMEOUT, "TIMEOUT"),
        Op(Operation.POLL_ADD, "POLL_ADD"),
        Op(Operation.SEND_ZC, "SEND_ZC"),
        Op(Operation.FUTEX_WAIT, "FUTEX_WAIT"),
        Op(Operation.RECV_ZC, "RECV_ZC"),
        Op(Operation.PIPE, "PIPE"),
        Op(Operation.NOP128, "NOP128"),
    ];

    int supported;
    foreach (entry; tour)
    {
        const ok = probe.isSupported(entry.op);
        if (ok) ++supported;
        writef("  %-11s %s\n", entry.name, ok ? "yes" : "no");
    }

    // One summary line, as required: how many of the curated opcodes this
    // kernel actually implements.
    writefln("ok: IORING_REGISTER_PROBE succeeded — %d/%d curated opcodes supported on this kernel",
        supported, cast(int) tour.length);
    return 0;
}
