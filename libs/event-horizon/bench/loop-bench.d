#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_loop_bench"
    dependency "sparkles:event-horizon" path="../../.."
    dependency "eh-bench-perf" path="perf"
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

import core.lifetime : move;
import core.time : Duration, MonoTime, msecs;

import std.stdio : writefln;

import sparkles.event_horizon.backend.concept : BackendConfig;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.event_horizon.op : Completion, OpNop, OpRead;
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
    // Tier C: a pure map/map chain via the Effect veneer vs the same math
    // written directly — the M12 overhead metric. The interpreter is a
    // compile-time fold (static dispatch, no instruction loop), so the cost
    // is not dispatch but the Outcome value constructed per node; measured at
    // ~30-40 ns/node, it is dwarfed by any real I/O leaf (μs scale).
    ulong directOps, veneerOps;
    Duration directElapsed, veneerElapsed;
    if (!Sched.create(sched).hasError)
    {
        auto r = sched.run(() {
            import sparkles.event_horizon.effect : effectOf, run, succeed, map;
            import sparkles.event_horizon.io : nop;
            import sparkles.event_horizon.scope_ : withScope;

            const fiberStart = MonoTime.currTime;
            while (MonoTime.currTime - fiberStart < minRunTime)
            {
                assert(!nop(sched).hasError);
                ++fiberOps;
            }
            fiberElapsed = MonoTime.currTime - fiberStart;

            // Direct-style pure map/chain baseline vs the veneer, same shape.
            cast(void) withScope!((ref sc) {
                static struct EmptyCtx { }
                EmptyCtx ctx;

                const dStart = MonoTime.currTime;
                while (MonoTime.currTime - dStart < minRunTime)
                {
                    int v = 2;
                    v = v * 10;
                    v = v + 1;
                    assert(v == 21);
                    ++directOps;
                }
                directElapsed = MonoTime.currTime - dStart;

                const vStart = MonoTime.currTime;
                while (MonoTime.currTime - vStart < minRunTime)
                {
                    auto eff = succeed(2).map!(x => x * 10).map!(x => x + 1);
                    auto o = run(eff, sc, ctx);
                    assert(o.value == 21);
                    ++veneerOps;
                }
                veneerElapsed = MonoTime.currTime - vStart;
            })(sched);
        });
        assert(!r.hasError);
        sched.destroy();
    }

    // ── Tier 3: registered vs plain buffer read throughput ──────────────
    // A back-to-back file read loop with plain pool buffers vs registered
    // buffers (READ_FIXED skips per-op get_user_pages). Honest caveat: for a
    // single small cached read the pin cost is noise, so this tracks ~1.0x —
    // the registration win is real only under many-buffer / high-concurrency
    // load (measured by the M14 cross-runtime echo bench). Kept here as a
    // regression tracker that the fixed path stays at least as fast.
    double plainReads = 0, fixedReads = 0;
    {
        auto tmp = makeTempFile();
        if (tmp >= 0)
        {
            plainReads = readThroughput(tmp, false);
            fixedReads = readThroughput(tmp, true);
            (() @trusted { import core.sys.posix.unistd : close; close(tmp); })();
        }
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
    if (veneerOps > 0)
    {
        const dns = directElapsed.total!"nsecs" / cast(double) directOps;
        const vns = veneerElapsed.total!"nsecs" / cast(double) veneerOps;
        writefln("effect direct  : %10.0f ops/s (%.2f ns/op)",
            opsPerSecond(directOps, directElapsed), dns);
        writefln("effect veneer  : %10.0f ops/s (%.2f ns/op — %.2f ns overhead, compile-time fold)",
            opsPerSecond(veneerOps, veneerElapsed), vns, vns - dns);
    }
    if (plainReads > 0)
    {
        writefln("read plain     : %10.0f reads/s", plainReads);
        writefln("read fixed     : %10.0f reads/s (%.2fx — REGISTER_BUFFERS + READ_FIXED)",
            fixedReads, fixedReads / plainReads);
    }

    perfPasses(cfg);
    return 0;
}

/// A dedicated hardware-counter pass per tier — the "why" behind the ns/op
/// numbers (instructions/op, IPC, branch/LLC-miss rates, page faults/op).
void perfPasses(LoopConfig cfg)
{
    import perf : PerfGroup, PerfRow, perOp, printPerfTable;

    auto pg = PerfGroup.tryOpen(true);
    if (!pg.available)
    {
        import std.stdio : writefln;

        writefln("\nhardware counters: %s", pg.status);
        return;
    }
    scope (exit) pg.close();

    // Each timed body runs `inner` ops so the ~2-ioctl measurement floor
    // amortizes; the reported counters are then true per-op (perOp divides).
    PerfRow[] rows;
    enum inner = 256;
    enum outer = 2000;

    // Tier A: NOP ping-pong — one submit + one runOnce (one io_uring_enter).
    {
        DefaultLoop l;
        if (!DefaultLoop.create(l, cfg).hasError)
        {
            ulong c;
            rows ~= PerfRow("nop-pingpong", pg.count(() {
                foreach (_; 0 .. inner)
                {
                    cast(void) l.submit(OpNop(), &onNop, &c);
                    cast(void) l.runOnce();
                }
            }, () {}, outer).perOp(inner));
            l.destroy();
        }
    }

    // Tier B: fiber await NOP — submit + park + CQE + enqueue + resume.
    {
        Sched s;
        if (!Sched.create(s).hasError)
        {
            cast(void) s.run(() {
                import sparkles.event_horizon.io : nop;

                rows ~= PerfRow("fiber-await", pg.count(() {
                    foreach (_; 0 .. inner)
                        cast(void) nop(s);
                }, () {}, outer).perOp(inner));
            });
            s.destroy();
        }
    }

    // Tier C: the Effect veneer — a pure map/map chain (no I/O), against the
    // same chain written directly, to isolate the Outcome-boxing cost.
    {
        Sched s;
        if (!Sched.create(s).hasError)
        {
            cast(void) s.run(() {
                import sparkles.event_horizon.effect : map, run, succeed;
                import sparkles.event_horizon.scope_ : withScope;

                cast(void) withScope!((ref sc) {
                    static struct EmptyCtx {}
                    EmptyCtx ctx;
                    rows ~= PerfRow("effect-direct", pg.count(() {
                        foreach (_; 0 .. inner)
                        {
                            int v = 2;
                            v = v * 10;
                            v = v + 1;
                            assert(v == 21);
                        }
                    }, () {}, outer).perOp(inner));
                    rows ~= PerfRow("effect-veneer", pg.count(() {
                        foreach (_; 0 .. inner)
                        {
                            auto o = run(succeed(2).map!(x => x * 10)
                                .map!(x => x + 1), sc, ctx);
                            assert(o.value == 21);
                        }
                    }, () {}, outer).perOp(inner));
                })(s);
            });
            s.destroy();
        }
    }

    const status = pg.status;
    printPerfTable(rows, status);
}

/// A small anonymous temp file with a page of content; `-1` on failure.
int makeTempFile() @trusted
{
    import core.stdc.stdio : tmpfile, fileno;
    import core.sys.posix.unistd : write;

    auto fp = tmpfile();
    if (fp is null)
        return -1;
    const fd = fileno(fp);
    ubyte[4096] page = 0;
    cast(void) write(fd, page.ptr, page.length);
    return fd;
}

/// Back-to-back 4 KiB reads at offset 0 for `minRunTime`; reads/second.
double readThroughput(int fd, bool registered) @trusted
{
    import sparkles.event_horizon.buffer : BufferPool;

    DefaultLoop loop;
    if (DefaultLoop.create(loop).hasError)
        return 0;
    scope (exit) loop.destroy();

    BufferPool!() pool;
    if (BufferPool!().create(pool, 1, 4096).hasError)
        return 0;
    if (registered)
    {
        if (!loop.caps().registeredBuffers)
            return 0;
        if (pool.register(loop).hasError)
            return 0;
    }
    scope (exit) if (registered) cast(void) loop.unregisterBuffers();

    static ulong done;
    static void onRead(void* ctx, ref Completion c) nothrow @nogc
    {
        ++*cast(ulong*) ctx;
    }

    done = 0;
    ulong count;
    const start = MonoTime.currTime;
    while (MonoTime.currTime - start < minRunTime)
    {
        auto b = pool.acquire();
        if (b.hasError)
            break;
        auto h = loop.submit(OpRead(fd, move(b.value), 0), &onRead, &done);
        if (h.hasError)
            break;
        cast(void) loop.runOnce();
        ++count;
    }
    return count / ((MonoTime.currTime - start).total!"nsecs" / 1e9);
}
