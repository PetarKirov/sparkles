/**
Loop and tier microbenchmarks for `sparkles:event-horizon`, on
`sparkles:test-runner` (`dub test -- --bench`).

The three API tiers measured against each other on one machine, one run:

$(LIST
    $(ITEM tier A — the callback loop: batched NOP throughput (the amortized
    submit + `io_uring_enter` + dispatch floor) and the un-amortized
    ping-pong round trip, one `io_uring_enter` per op;)
    $(ITEM tier B — the fiber seam: the same NOP round trip through
    submit → park → CQE → enqueue → resume, so the difference against tier A
    $(I is) the direct-style cost;)
    $(ITEM tier C — the `Effect!T` veneer: a pure three-node `map` chain against
    the same arithmetic written directly, isolating the per-node `Outcome`
    construction (the interpreter itself is a compile-time fold);)
    $(ITEM tier 3 — registered vs plain buffers on a cached read.)
)

These are all sub-microsecond except the reads, so they are batched cases
(`BenchTiming.batched`) rather than per-call ones, per the runner's
guidance. Hardware counters come from `--perf` — retired instructions and
page faults are the host-stable anchors to compare builds on.
*/
module sparkles.event_horizon_bench.loop;

version (linux)  :  // the uring backend's numbers; the peers have their own hosts

import core.lifetime : move;

import sparkles.test_runner.attributes : benchCases;
import sparkles.test_runner.bench : BenchTiming, benchCase, blackBox, Metric, Unit;
import sparkles.test_runner.skip : skipTest;

import sparkles.event_horizon.buffer : BufferPool;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.event_horizon.op : Completion, OpNop, OpRead;
import sparkles.event_horizon.sched : Sched;

/// Submissions per batched round (also the SQ depth the loop is built with).
private enum uint batch = 128;

/// Tier-A completion callback: counts, nothing else — the cheapest possible
/// dispatch, so the measurement is loop overhead and not user work.
extern (D) private void onNop(void* p, ref Completion) nothrow @nogc
{
    ++*cast(ulong*) p;
}

@("loop.nop.pingPong")
@benchCases
@system
unittest
{
    // One op per `io_uring_enter`: the un-amortized round-trip floor.
    skipWithoutLoop();
    benchCase(NopCase!1());
}

@("loop.nop.batched")
@benchCases
@system
unittest
{
    // `batch` submissions drained together — the amortized submit + enter +
    // dispatch cost. One iteration is a whole batch, so median/iter is the
    // batch time (divide by `batch` for per-op).
    skipWithoutLoop();
    benchCase(NopCase!batch(), labels: ["ops-per-iter": "128"]);
}

/// Skips the calling test where a loop cannot be created (no io_uring).
private void skipWithoutLoop()
{
    DefaultLoop probe;
    if (DefaultLoop.create(probe).hasError)
        skipTest("io_uring unavailable");
    probe.destroy();
}

/// `ops` NOPs per iteration on a loop opened in `setup` and closed in
/// `teardown`: one is submitted and reaped by one `runOnce`, more are
/// submitted together and drained.
private struct NopCase(uint ops)
{
    enum timing = BenchTiming.batched;
    DefaultLoop loop;
    ulong completions;

    void setup()
    {
        LoopConfig cfg;
        cfg.backend.sqEntries = batch;
        if (DefaultLoop.create(loop, cfg).hasError)
            skipTest("io_uring unavailable");
    }

    void timed()
    {
        static if (ops == 1)
        {
            cast(void) loop.submit(OpNop(), &onNop, &completions);
            cast(void) loop.runOnce();
        }
        else
        {
            foreach (_; 0 .. ops)
                cast(void) loop.submit(OpNop(), &onNop, &completions);
            while (loop.inFlight > 0)
                cast(void) loop.runOnce();
        }
    }

    void teardown() { loop.destroy(); }
}

/// Ops per measured iteration for the scheduler-backed rows. Each iteration
/// stands up its own scheduler and does `schedOps` operations inside it, so
/// the one-off setup amortizes to noise (and cancels outright when two such
/// rows are differenced).
private enum uint schedOps = 10_000;

@("loop.fiber.await")
@benchCases
@system
unittest
{
    // The same one-op round trip as `loop.nop.pingPong`, but parked on the
    // fiber seam. The delta between the two rows is the price of direct style.
    // median/iter covers `schedOps` awaits — divide by it for per-op.
    {
        Sched probe;
        if (Sched.create(probe).hasError)
            skipTest("io_uring unavailable");
        probe.destroy();
    }

    static struct FiberAwait
    {
        enum timing = BenchTiming.batched;

        void timed()
        {
            import sparkles.event_horizon.io : nop;

            Sched sched;
            if (Sched.create(sched).hasError)
                return;
            scope (exit) sched.destroy();
            cast(void) sched.run(() {
                foreach (_; 0 .. schedOps)
                    cast(void) nop(sched);
            });
        }
    }

    benchCase(FiberAwait(), labels: ["ops-per-iter": "10000"]);
}

/// Chain evaluations per measured iteration for the tier-C rows.
private enum uint effectOps = 1_000_000;

@("loop.effect.direct")
@benchCases
@system
unittest
{
    // The tier-C baseline: the veneer's arithmetic written directly. Both
    // operands and result go through `blackBox` or the whole chain folds away.
    // Carries the SAME scheduler+scope wrapper as `loop.effect.veneer` so the
    // two differ only in the chain — the wrapper cancels in the difference.
    {
        Sched probe;
        if (Sched.create(probe).hasError)
            skipTest("io_uring unavailable");
        probe.destroy();
    }

    static struct EffectDirect
    {
        enum timing = BenchTiming.batched;

        void timed()
        {
            import sparkles.event_horizon.scope_ : withScope;

            Sched sched;
            if (Sched.create(sched).hasError)
                return;
            scope (exit) sched.destroy();
            cast(void) sched.run(() {
                cast(void) withScope!((ref sc) {
                    foreach (_; 0 .. effectOps)
                    {
                        int v = blackBox(2);
                        v = v * 10;
                        v = v + 1;
                        blackBox(v);
                    }
                })(sched);
            });
        }
    }

    benchCase(EffectDirect(), labels: ["ops-per-iter": "1000000"]);
}

@("loop.effect.veneer")
@benchCases
@system
unittest
{
    // The same chain through `Effect!T`. Against `loop.effect.direct` this
    // isolates the per-node `Outcome` construction — the interpreter is a
    // compile-time fold, so this is value cost, not dispatch cost.
    {
        Sched probe;
        if (Sched.create(probe).hasError)
            skipTest("io_uring unavailable");
        probe.destroy();
    }

    static struct EffectVeneer
    {
        enum timing = BenchTiming.batched;

        void timed()
        {
            import sparkles.event_horizon.effect : map, run, succeed;
            import sparkles.event_horizon.scope_ : withScope;

            Sched sched;
            if (Sched.create(sched).hasError)
                return;
            scope (exit) sched.destroy();
            cast(void) sched.run(() {
                cast(void) withScope!((ref sc) {
                    static struct EmptyCtx {}
                    EmptyCtx ctx;
                    foreach (_; 0 .. effectOps)
                    {
                        auto o = run(succeed(blackBox(2)).map!(x => x * 10)
                            .map!(x => x + 1), sc, ctx);
                        blackBox(o.value);
                    }
                })(sched);
            });
        }
    }

    benchCase(EffectVeneer(), labels: ["ops-per-iter": "1000000"]);
}

// ── A/B controls: the old standalone harness's body shape ───────────────────
// The retired `loop-bench.d` executable measured the veneer at ~1045 instr/op
// against ~31 for direct — 45x what the barrier-guarded rows above report, and
// both figures reproduce. The bodies below are that harness's exact shapes (a
// compile-time-constant seed, and an `assert` — stripped under releaseMode —
// where the rows above use `blackBox`). Measured in the SAME binary as the
// rows above, they isolate the 45x to the body shape rather than to the build
// or the apparatus, which is what makes the veneer's real cost decidable.

@("loop.effect.directLiteral")
@benchCases
@system
unittest
{
    {
        Sched probe;
        if (Sched.create(probe).hasError)
            skipTest("io_uring unavailable");
        probe.destroy();
    }

    static struct EffectDirectLiteral
    {
        enum timing = BenchTiming.batched;

        void timed()
        {
            import sparkles.event_horizon.scope_ : withScope;

            Sched sched;
            if (Sched.create(sched).hasError)
                return;
            scope (exit) sched.destroy();
            cast(void) sched.run(() {
                cast(void) withScope!((ref sc) {
                    foreach (_; 0 .. effectOps)
                    {
                        int v = 2;
                        v = v * 10;
                        v = v + 1;
                        assert(v == 21); // stripped under releaseMode → dead code
                    }
                })(sched);
            });
        }
    }

    benchCase(EffectDirectLiteral(), labels: ["ops-per-iter": "1000000"]);
}

@("loop.effect.veneerLiteral")
@benchCases
@system
unittest
{
    {
        Sched probe;
        if (Sched.create(probe).hasError)
            skipTest("io_uring unavailable");
        probe.destroy();
    }

    static struct EffectVeneerLiteral
    {
        enum timing = BenchTiming.batched;

        void timed()
        {
            import sparkles.event_horizon.effect : map, run, succeed;
            import sparkles.event_horizon.scope_ : withScope;

            Sched sched;
            if (Sched.create(sched).hasError)
                return;
            scope (exit) sched.destroy();
            cast(void) sched.run(() {
                cast(void) withScope!((ref sc) {
                    static struct EmptyCtx {}
                    EmptyCtx ctx;
                    foreach (_; 0 .. effectOps)
                    {
                        auto o = run(succeed(2).map!(x => x * 10).map!(x => x + 1),
                            sc, ctx);
                        assert(o.value == 21);
                    }
                })(sched);
            });
        }
    }

    benchCase(EffectVeneerLiteral(), labels: ["ops-per-iter": "1000000"]);
}

@("loop.read.registeredVsPlain")
@benchCases
@system
unittest
{
    // A cached 4 KiB read, plain vs `READ_FIXED` over a registered buffer.
    // Honest expectation: ~1.0x — skipping `get_user_pages` only pays under
    // many-buffer / high-concurrency load, not one already-cached page. Kept
    // as a regression tracker that the fixed path never falls behind.
    // ~7 µs per read puts these in `benchCase`'s range (µs and up), so each
    // variant gets its own row plus a bytes/s column.
    foreach (registered; [false, true])
        benchCase(ReadCase(registered), name: registered ? "fixed (READ_FIXED)" : "plain",
            labels: ["buffers": registered ? "registered" : "pool"],
            metrics: [Metric(Unit("B"), 4096, Metric.Mode.rate)]);
}

/// One read variant: its fixture fd, loop and pool are opened in `setup` and
/// closed in `teardown`.
private struct ReadCase
{
    DefaultLoop loop;
    BufferPool!() pool;
    ulong done;
    int fd = -1;
    bool ok;
    bool registered;

    this(bool registered) { this.registered = registered; }

    void setup()
    {
        fd = makeTempFile();
        if (fd < 0)
            return;
        if (DefaultLoop.create(loop).hasError)
            return;
        if (BufferPool!().create(pool, 1, 4096).hasError)
            return;
        if (registered)
        {
            if (!loop.caps().registeredBuffers)
                return; // caps absent: the case degrades, never breaks
            if (pool.register(loop).hasError)
                return;
        }
        ok = true;
    }

    void timed()
    {
        // Never call `runOnce` without a submission in flight: it would
        // block in `io_cqring_wait` for a completion that cannot arrive.
        if (!ok)
            return;
        auto b = pool.acquire();
        if (b.hasError)
            return;
        auto h = loop.submit(OpRead(fd, move(b.value), 0), &onRead, &done);
        if (h.hasError)
            return;
        cast(void) loop.runOnce();
    }

    void teardown()
    {
        if (ok && registered)
            cast(void) loop.unregisterBuffers();
        loop.destroy();
        if (fd >= 0)
            closeFd(fd);
    }
}

extern (D) private void onRead(void* ctx, ref Completion) nothrow @nogc
{
    ++*cast(ulong*) ctx;
}

/// A small anonymous temp file with a page of content; `-1` on failure.
private int makeTempFile() @trusted
{
    import core.stdc.stdio : fileno, tmpfile;
    import core.sys.posix.unistd : write;

    auto fp = tmpfile();
    if (fp is null)
        return -1;
    const fd = fileno(fp);
    ubyte[4096] page = 0;
    cast(void) write(fd, page.ptr, page.length);
    return fd;
}

private void closeFd(int fd) @trusted
{
    import core.sys.posix.unistd : close;

    close(fd);
}
