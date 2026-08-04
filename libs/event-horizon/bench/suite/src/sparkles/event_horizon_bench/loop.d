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

These are all sub-microsecond except the reads, so they use `benchIter`
(batched timing) rather than `benchCase`, per the runner's guidance. Hardware
counters come from `--perf` — retired instructions and page faults are the
host-stable anchors to compare builds on.
*/
module sparkles.event_horizon_bench.loop;

version (linux)  :  // the uring backend's numbers; the peers have their own hosts

import core.lifetime : move;

import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchCase, benchIter, blackBox, Metric, Unit;
import sparkles.test_runner.skip : skipTest;

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
@benchmark
@system
unittest
{
    // One op per `io_uring_enter`: the un-amortized round-trip floor.
    LoopConfig cfg;
    cfg.backend.sqEntries = batch;
    DefaultLoop loop;
    if (DefaultLoop.create(loop, cfg).hasError)
        skipTest("io_uring unavailable");
    scope (exit) loop.destroy();

    ulong completions;
    benchIter({
        cast(void) loop.submit(OpNop(), &onNop, &completions);
        cast(void) loop.runOnce();
    });
}

@("loop.nop.batched")
@benchmark
@system
unittest
{
    // `batch` submissions drained together — the amortized submit + enter +
    // dispatch cost. One iteration is a whole batch, so median/iter is the
    // batch time (divide by `batch` for per-op).
    LoopConfig cfg;
    cfg.backend.sqEntries = batch;
    DefaultLoop loop;
    if (DefaultLoop.create(loop, cfg).hasError)
        skipTest("io_uring unavailable");
    scope (exit) loop.destroy();

    ulong completions;
    benchIter({
        foreach (_; 0 .. batch)
            cast(void) loop.submit(OpNop(), &onNop, &completions);
        while (loop.inFlight > 0)
            cast(void) loop.runOnce();
    }, ["ops-per-iter": "128"]);
}

@("loop.fiber.await")
@benchmark
@system
unittest
{
    // The same one-op round trip as `loop.nop.pingPong`, but parked on the
    // fiber seam. The delta between the two rows is the price of direct style.
    Sched sched;
    if (Sched.create(sched).hasError)
        skipTest("io_uring unavailable");
    scope (exit) sched.destroy();

    auto r = sched.run(() {
        import sparkles.event_horizon.io : nop;

        benchIter({ cast(void) nop(sched); });
    });
    assert(!r.hasError);
}

@("loop.effect.direct")
@benchmark
@system
unittest
{
    // The tier-C baseline: the veneer's arithmetic written directly. Both
    // operands and result go through `blackBox` or the whole chain folds away.
    benchIter({
        int v = blackBox(2);
        v = v * 10;
        v = v + 1;
        blackBox(v);
    });
}

@("loop.effect.veneer")
@benchmark
@system
unittest
{
    // The same chain through `Effect!T`. Against `loop.effect.direct` this
    // isolates the per-node `Outcome` construction — the interpreter is a
    // compile-time fold, so this is value cost, not dispatch cost.
    Sched sched;
    if (Sched.create(sched).hasError)
        skipTest("io_uring unavailable");
    scope (exit) sched.destroy();

    auto r = sched.run(() {
        import sparkles.event_horizon.effect : map, run, succeed;
        import sparkles.event_horizon.scope_ : withScope;

        cast(void) withScope!((ref sc) {
            static struct EmptyCtx {}
            EmptyCtx ctx;
            benchIter({
                auto o = run(succeed(blackBox(2)).map!(x => x * 10)
                    .map!(x => x + 1), sc, ctx);
                blackBox(o.value);
            });
        })(sched);
    });
    assert(!r.hasError);
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
@benchmark
@system
unittest
{
    benchIter({
        int v = 2;
        v = v * 10;
        v = v + 1;
        assert(v == 21); // stripped under releaseMode → body is dead code
    });
}

@("loop.effect.veneerLiteral")
@benchmark
@system
unittest
{
    Sched sched;
    if (Sched.create(sched).hasError)
        skipTest("io_uring unavailable");
    scope (exit) sched.destroy();

    auto r = sched.run(() {
        import sparkles.event_horizon.effect : map, run, succeed;
        import sparkles.event_horizon.scope_ : withScope;

        cast(void) withScope!((ref sc) {
            static struct EmptyCtx {}
            EmptyCtx ctx;
            benchIter({
                auto o = run(succeed(2).map!(x => x * 10).map!(x => x + 1),
                    sc, ctx);
                assert(o.value == 21);
            });
        })(sched);
    });
    assert(!r.hasError);
}

@("loop.read.registeredVsPlain")
@benchmark
@system
unittest
{
    // A cached 4 KiB read, plain vs `READ_FIXED` over a registered buffer.
    // Honest expectation: ~1.0x — skipping `get_user_pages` only pays under
    // many-buffer / high-concurrency load, not one already-cached page. Kept
    // as a regression tracker that the fixed path never falls behind.
    // ~7 µs per read puts these in `benchCase`'s range (µs and up), so each
    // variant gets its own row plus a bytes/s column.
    const fd = makeTempFile();
    if (fd < 0)
        skipTest("cannot create the temp fixture");
    scope (exit) closeFd(fd);

    registerRead(fd, registered: false);
    registerRead(fd, registered: true);
}

/// Registers one read variant as its own `benchCase` row. Takes its state by
/// value: under `--bench` the closures run after the body returns, so a shared
/// loop variable would be one slot for every case.
private void registerRead(int fd, bool registered)
{
    import sparkles.event_horizon.buffer : BufferPool;

    static struct Fixture
    {
        DefaultLoop loop;
        BufferPool!() pool;
        ulong done;
        bool ok;
        bool registered;
    }

    auto f = new Fixture;
    f.registered = registered;

    benchCase(
        name: registered ? "fixed (READ_FIXED)" : "plain",
        labels: ["buffers": registered ? "registered" : "pool"],
        setup: () {
            if (DefaultLoop.create(f.loop).hasError)
                return;
            if (BufferPool!().create(f.pool, 1, 4096).hasError)
                return;
            if (f.registered)
            {
                if (!f.loop.caps().registeredBuffers)
                    return; // caps absent: the case degrades, never breaks
                if (f.pool.register(f.loop).hasError)
                    return;
            }
            f.ok = true;
        },
        timed: () {
            if (!f.ok)
                return;
            auto b = f.pool.acquire();
            if (b.hasError)
                return;
            auto h = f.loop.submit(OpRead(fd, move(b.value), 0), &onRead, &f.done);
            if (h.hasError)
                return;
            cast(void) f.loop.runOnce();
        },
        after: () {},
        teardown: () {
            if (f.ok && f.registered)
                cast(void) f.loop.unregisterBuffers();
            f.loop.destroy();
        },
        metrics: [Metric(Unit("B"), 4096, Metric.Mode.rate)],
    );
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
