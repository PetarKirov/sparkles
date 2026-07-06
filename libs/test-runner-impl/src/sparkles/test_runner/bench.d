/**
 * Benchmark measurement: auto-scaling iteration counts, basic robust
 * statistics, and an optimizer barrier.
 *
 * `@benchmark unittest` blocks are executed by the runner's `--bench` mode.
 * By default the whole test body is the measured unit. To time only part of
 * the body (excluding setup), call $(LREF benchIter) inside the test:
 * ---
 * @("sort.bench")
 * @benchmark @safe
 * unittest
 * {
 *     import sparkles.test_runner.bench : benchIter, blackBox;
 *
 *     auto data = makeInput();          // setup — not measured
 *     benchIter({ blackBox(data.dup.sort()); });  // measured
 * }
 * ---
 *
 * The measurement protocol follows Rust libtest's `Bencher`: the iteration
 * count per sample is doubled until a sample takes at least
 * `BenchConfig.minSampleTime`, then `BenchConfig.sampleCount` samples are
 * collected and summarized as median / median-absolute-deviation / min / max
 * nanoseconds per iteration.
 */
module sparkles.test_runner.bench;

import core.time : Duration, MonoTime, msecs;

import std.typecons : Nullable;

import sparkles.test_runner.attributes : benchmark, ctfe;
import sparkles.test_runner.model : Test, TestResult;
import sparkles.test_runner.perf : PerfGroup, PerfStats;

// ─────────────────────────────────────────────────────────────────────────────
// Optimizer barrier
// ─────────────────────────────────────────────────────────────────────────────

private __gshared size_t blackBoxSink;

/// An identity function the optimizer cannot see through: forces `value` to
/// be materialized, so benchmarked computations are not eliminated as dead
/// code or constant-folded. The analogue of Rust's `black_box`.
pragma(inline, true)
auto ref T blackBox(T)(auto ref T value)
{
    version (LDC)
    {
        import ldc.llvmasm : __asm;

        () @trusted { __asm("", "r,~{memory}", cast(const(void)*) &value); }();
    }
    else
    {
        import core.volatile : volatileStore;

        () @trusted {
            volatileStore(cast(size_t*) &blackBoxSink, cast(size_t) &value);
        }();
    }
    return value;
}

@("blackBox.identity")
@safe
unittest
{
    assert(blackBox(42) == 42);
    auto arr = [1, 2, 3];
    assert(blackBox(arr) is arr);
}

// ─────────────────────────────────────────────────────────────────────────────
// Measurement
// ─────────────────────────────────────────────────────────────────────────────

/// Tuning knobs of one benchmark run.
struct BenchConfig
{
    /// Fixed iteration count per sample; `0` auto-scales until one sample
    /// takes at least `minSampleTime`.
    uint iterations = 0;

    /// Auto-scaling target duration of one sample.
    Duration minSampleTime = 5.msecs;

    /// Number of samples to collect.
    uint sampleCount = 32;

    /// Cap on the perf counting-pass iterations. Kept separate from the timing
    /// sample so a cheap op's huge auto-scaled count does not make the (ioctl-
    /// bracketed) counting pass slow; counters stabilize well before this.
    uint perfMaxIters = 100_000;
}

/// Summary statistics of one benchmark, in nanoseconds per iteration.
struct BenchStats
{
    string name;
    ulong iterations; /// iterations per sample
    size_t samples;
    double nsPerIterMedian = 0;
    double nsPerIterDeviation = 0; /// median absolute deviation
    double nsPerIterMin = 0;
    double nsPerIterMax = 0;
    Nullable!PerfStats perf; /// hardware counters under `--perf` (empty otherwise)
}

/// The median of a sorted, non-empty slice.
double medianOf(in double[] sorted) @safe pure nothrow @nogc
in (sorted.length > 0, "medianOf requires a non-empty slice")
{
    const mid = sorted.length / 2;
    return sorted.length % 2
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
}

@("medianOf.oddEven")
@safe pure nothrow @nogc
unittest
{
    static immutable odd = [1.0, 2.0, 10.0];
    assert(medianOf(odd) == 2.0);
    static immutable even = [1.0, 2.0, 3.0, 10.0];
    assert(medianOf(even) == 2.5);
}

/// Summarizes raw per-sample measurements (ns/iter) into `BenchStats`.
BenchStats computeStats(string name, ulong iterations, double[] nsPerIter) @safe
in (nsPerIter.length > 0, "computeStats requires at least one sample")
{
    import std.algorithm.iteration : map;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.math.algebraic : abs;

    nsPerIter.sort;
    const median = medianOf(nsPerIter);
    auto deviations = nsPerIter.map!(x => abs(x - median)).array;
    deviations.sort;

    return BenchStats(
        name: name,
        iterations: iterations,
        samples: nsPerIter.length,
        nsPerIterMedian: median,
        nsPerIterDeviation: medianOf(deviations),
        nsPerIterMin: nsPerIter[0],
        nsPerIterMax: nsPerIter[$ - 1],
    );
}

@("computeStats.ctfe")
@ctfe @safe
unittest
{
    // Dogfoods @ctfe: forced through CTFE by the runner's `static assert`.
    const stats = computeStats("ct", 2, [4.0, 2.0, 3.0]);
    assert(stats.nsPerIterMedian == 3.0);
    assert(stats.nsPerIterMin == 2.0);
}

@("medianOf.bench")
@benchmark @safe
unittest
{
    // Dogfoods @benchmark: skipped by default, measured under `--bench`.
    // The input passes through `blackBox` too, so the pure computation
    // cannot be constant-folded away.
    double[5] values = [5.0, 1.0, 4.0, 2.0, 3.0];
    blackBox(medianOf(blackBox(values[])));
}

@("computeStats.basic")
@safe
unittest
{
    auto stats = computeStats("s", 10, [3.0, 1.0, 2.0]);
    assert(stats.nsPerIterMedian == 2.0);
    assert(stats.nsPerIterMin == 1.0);
    assert(stats.nsPerIterMax == 3.0);
    assert(stats.nsPerIterDeviation == 1.0);
    assert(stats.samples == 3);
    assert(stats.iterations == 10);
}

/// Times `run` with the libtest protocol: doubles the per-sample iteration
/// count until one sample takes `config.minSampleTime`, then collects
/// `config.sampleCount` samples. Returns `(iterations, ns/iter samples)`.
package(sparkles.test_runner)
auto measure(DG)(scope DG run, in BenchConfig config)
{
    import std.typecons : tuple;

    static Duration sampleOnce(scope DG run, ulong iterations)
    {
        const started = MonoTime.currTime;
        foreach (_; 0 .. iterations)
            run();
        return MonoTime.currTime - started;
    }

    // Warmup + auto-scale: double until one sample is long enough to time.
    ulong iterations = config.iterations ? config.iterations : 1;
    if (!config.iterations)
        while (sampleOnce(run, iterations) < config.minSampleTime && iterations < 1UL << 40)
            iterations *= 2;

    auto nsPerIter = new double[](config.sampleCount);
    foreach (ref sample; nsPerIter)
        sample = double(sampleOnce(run, iterations).total!"nsecs") / iterations;

    return tuple!("iterations", "nsPerIter")(iterations, nsPerIter);
}

// ─────────────────────────────────────────────────────────────────────────────
// In-test measurement API (`benchIter`) and the runner-side driver
// ─────────────────────────────────────────────────────────────────────────────

private struct BenchContext
{
    BenchConfig config;
    bool used;
    ulong iterations;
    double[] nsPerIter;
    PerfGroup* perf;      /// null / unavailable = no counting pass
    PerfStats perfStats;
    bool perfMeasured;
}

private BenchContext* activeBenchContext; // thread-local, set by runBenchmark

/// Runs the perf counting pass over `run` when the context has an available
/// counter group, storing the per-iteration counters. The counting pass reuses
/// the timing's auto-scaled iteration count, capped by `perfMaxIters`.
private void measurePerf(DG)(BenchContext* context, scope DG run)
{
    import std.algorithm.comparison : min;

    if (context.perf is null || !context.perf.available)
        return;
    const iters = cast(uint) min(context.iterations, context.config.perfMaxIters);
    context.perfStats = context.perf.count(run, () {}, iters ? iters : 1);
    context.perfMeasured = true;
}

/// Measures `run` inside a `@benchmark unittest`, excluding the surrounding
/// setup code from the timing. Outside a `--bench` run (e.g. when another
/// runner executes the test), `run` is invoked exactly once.
void benchIter(DG)(scope DG run)
if (is(typeof(run()) == void))
{
    if (auto context = activeBenchContext)
    {
        context.used = true;
        auto measured = measure(run, context.config);
        context.iterations = measured.iterations;
        context.nsPerIter = measured.nsPerIter;
        measurePerf(context, run);
    }
    else
        run();
}

@("benchIter.inertOutsideBenchRuns")
@safe
unittest
{
    int calls;
    benchIter({ ++calls; });
    assert(calls == 1);
}

/// The outcome of one `--bench` execution: statistics on success, a failed
/// `TestResult` when the test threw.
struct BenchOutcome
{
    BenchStats stats;
    TestResult result;
}

/// Runs one `@benchmark` test: invokes the test once with an active bench
/// context; if it did not call `benchIter`, the whole body is measured as
/// the iteration unit (the probe invocation doubling as warmup).
package(sparkles.test_runner)
BenchOutcome runBenchmark(Test test, in BenchConfig config, ref PerfGroup perf)
{
    import sparkles.test_runner.execution : executeTest;

    BenchOutcome outcome;
    auto context = BenchContext(config: config, perf: &perf);

    activeBenchContext = &context;
    scope (exit)
        activeBenchContext = null;

    outcome.result = executeTest(test);
    if (!outcome.result.succeeded)
        return outcome;

    if (!context.used)
    {
        auto measured = measure({ test.ptr(); }, config);
        context.iterations = measured.iterations;
        context.nsPerIter = measured.nsPerIter;
        measurePerf(&context, { test.ptr(); });
    }

    outcome.stats = computeStats(test.name, context.iterations, context.nsPerIter);
    if (context.perfMeasured)
        outcome.stats.perf = context.perfStats;
    return outcome;
}

@("runBenchmark.wholeBody")
@system
unittest
{
    import core.time : usecs;

    static void body_()
    {
        blackBox(1 + 1);
    }

    const config = BenchConfig(iterations: 4, sampleCount: 3, minSampleTime: 1.usecs);
    auto perf = PerfGroup.tryOpen(false);
    auto outcome = runBenchmark(Test(fullName: "m.b", name: "b", ptr: &body_), config, perf);
    assert(outcome.result.succeeded);
    assert(outcome.stats.iterations == 4);
    assert(outcome.stats.samples == 3);
    assert(outcome.stats.nsPerIterMedian >= 0);
    assert(outcome.stats.perf.isNull); // no counters requested
}

@("runBenchmark.benchIterBody")
@system
unittest
{
    import core.time : usecs;

    static void body_()
    {
        int side; // setup that must run exactly once per probe call
        benchIter({ blackBox(side += 1); });
    }

    const config = BenchConfig(iterations: 8, sampleCount: 2, minSampleTime: 1.usecs);
    auto perf = PerfGroup.tryOpen(false);
    auto outcome = runBenchmark(Test(fullName: "m.bi", name: "bi", ptr: &body_), config, perf);
    assert(outcome.result.succeeded);
    assert(outcome.stats.iterations == 8);
    assert(outcome.stats.samples == 2);
}

@("runBenchmark.failure")
@system
unittest
{
    static void failing()
    {
        int zero = 0;
        assert(zero == 1, "bench setup failed");
    }

    auto perf = PerfGroup.tryOpen(false);
    auto outcome = runBenchmark(Test(fullName: "m.f", name: "f", ptr: &failing), BenchConfig(), perf);
    assert(!outcome.result.succeeded);
    assert(outcome.result.thrown.length == 1);
}

@("runBenchmark.capturesPerf")
@system
unittest
{
    import core.time : usecs;

    static ulong sink;
    static void body_()
    {
        benchIter({ foreach (i; 0 .. 1000) sink += i * i; });
    }

    auto perf = PerfGroup.tryOpen(true);
    scope (exit)
        perf.close();
    if (!perf.available) // paranoid/sandboxed kernels refuse; not a failure
        return;

    const config = BenchConfig(iterations: 200, sampleCount: 2, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(Test(fullName: "m.p", name: "p", ptr: &body_), config, perf);
    assert(outcome.result.succeeded);
    assert(!outcome.stats.perf.isNull);
    assert(outcome.stats.perf.get.instructions > 0);
}
