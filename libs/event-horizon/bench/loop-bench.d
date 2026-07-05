#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_loop_bench"
    dependency "sparkles:event-horizon" path="../../.."
    platforms "linux"
    targetPath "build"
    buildType "release"
+/
/**
 * Tier-A baseline microbenchmark (PLAN M3: "first benchmark baseline
 * recorded"). Two numbers, meant to be tracked across milestones:
 *
 *  - batched NOP throughput — submit BATCH nops, drain, repeat: amortized
 *    submit + enter + dispatch cost per op (the loop-overhead ceiling);
 *  - ping-pong NOP latency — one op per runOnce: the un-amortized
 *    round-trip floor (one io_uring_enter per op).
 *
 * Run with: `dub run --single loop-bench.d` (add `--build=release` when
 * invoking through a checkout that overrides the default).
 *
 * SKIPs (exit 0) when io_uring is unavailable so it never breaks a run.
 */
module event_horizon_loop_bench;

import core.time : Duration, MonoTime, msecs;

import std.stdio : writefln;

import sparkles.event_horizon.backend.concept : BackendConfig;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.event_horizon.op : Completion, OpNop;
import sparkles.event_horizon.sched : Sched;

enum batch = 128;
enum minRunTime = 500.msecs;

extern (D) void onNop(void* p, ref Completion) nothrow @nogc
{
    ++*cast(ulong*) p;
}

double opsPerSecond(ulong ops, Duration elapsed)
    => ops / (elapsed.total!"nsecs" / 1e9);

int main()
{
    LoopConfig cfg;
    cfg.backend.sqEntries = batch;
    DefaultLoop loop;
    auto created = DefaultLoop.create(loop, cfg);
    if (created.hasError)
    {
        writefln("SKIP: io_uring unavailable (errno %d)", created.error.errnoValue);
        return 0;
    }
    scope (exit) loop.destroy();

    ulong completions;

    // ── batched throughput ──────────────────────────────────────────────
    ulong batchedOps;
    auto start = MonoTime.currTime;
    while (MonoTime.currTime - start < minRunTime)
    {
        foreach (_; 0 .. batch)
            cast(void) loop.submit(OpNop(), &onNop, &completions);
        while (loop.inFlight > 0)
            cast(void) loop.runOnce();
        batchedOps += batch;
    }
    const batchedElapsed = MonoTime.currTime - start;

    // ── ping-pong latency ───────────────────────────────────────────────
    ulong pingPongOps;
    start = MonoTime.currTime;
    while (MonoTime.currTime - start < minRunTime)
    {
        cast(void) loop.submit(OpNop(), &onNop, &completions);
        cast(void) loop.runOnce();
        ++pingPongOps;
    }
    const pingPongElapsed = MonoTime.currTime - start;

    assert(completions == batchedOps + pingPongOps);

    // ── fiber await ping-pong (tier B vs tier A overhead) ───────────────
    // Same one-op-per-enter round-trip, but through the fiber seam:
    // submit + park + CQE + enqueue + resume per op.
    loop.destroy();
    Sched sched;
    ulong fiberOps;
    Duration fiberElapsed;
    if (!Sched.create(sched).hasError)
    {
        auto r = sched.run(() {
            import sparkles.event_horizon.io : nop;

            const fiberStart = MonoTime.currTime;
            while (MonoTime.currTime - fiberStart < minRunTime)
            {
                assert(!nop(sched).hasError);
                ++fiberOps;
            }
            fiberElapsed = MonoTime.currTime - fiberStart;
        });
        assert(!r.hasError);
        sched.destroy();
    }

    writefln("batched   (x%d): %10.0f ops/s", batch,
        opsPerSecond(batchedOps, batchedElapsed));
    writefln("ping-pong (x1) : %10.0f ops/s (%.0f ns/op)",
        opsPerSecond(pingPongOps, pingPongElapsed),
        pingPongElapsed.total!"nsecs" / cast(double) pingPongOps);
    if (fiberOps > 0)
        writefln("fiber     (x1) : %10.0f ops/s (%.0f ns/op — await/park/resume over ping-pong)",
            opsPerSecond(fiberOps, fiberElapsed),
            fiberElapsed.total!"nsecs" / cast(double) fiberOps);
    return 0;
}
