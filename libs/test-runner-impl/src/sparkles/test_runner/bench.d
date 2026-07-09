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
import sparkles.test_runner.syscalls : SyscallGroup, SyscallStats;
import sparkles.test_runner.tier0 : Tier0Group, Tier0Stats;

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

/// A unit of measure for a benchmark metric. A forward-compatible stand-in for
/// `sparkles.quantities`' runtime unit — today just the symbol (its identity).
/// Domain counts ("tweet", "frame", "req") are open-basis units minted by name;
/// "B"/"s" map to SI base dimensions once the quantities library lands.
struct Unit
{
    string symbol; /// "B", "req", "tweet", "s"
}

/// A measurement attached to a benchmark case: `amount` units of work per timed
/// iteration. Reported as a per-second `rate` (`amount ÷ iteration-time`, a
/// quantity of dimension `unit·s⁻¹`) or as a per-iteration `level` (as-is).
struct Metric
{
    /// How the runner reports `amount`.
    enum Mode
    {
        rate, /// `amount ÷ iteration-time` → `<unit>/s`
        level, /// the per-iteration `amount`, as-is
    }

    Unit unit;
    double amount;
    Mode mode;
}

/// Summary statistics of one benchmark row, in nanoseconds per iteration. A row
/// with a non-empty `error` is a failure row (its timing fields are unset).
struct BenchStats
{
    string name;
    ulong iterations; /// iterations per sample
    size_t samples;
    double nsPerIterMedian = 0;
    double nsPerIterDeviation = 0; /// median absolute deviation
    double nsPerIterMin = 0;
    double nsPerIterMax = 0;
    Metric[] metrics; /// client throughput / level metrics (empty = none)
    Nullable!PerfStats perf; /// hardware counters under `--perf` (empty otherwise)
    Nullable!Tier0Stats tier0; /// cheap /proc counters when a tier0 metric is selected
    Nullable!SyscallStats syscalls; /// syscall tracepoint counts under `--syscalls`
    string error; /// non-empty = an error row (a case whose `after` reported failure)
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
    string testName;   /// row name for benchIter / whole-body measurement
    bool used;         /// a benchIter/benchCase measured — skip whole-body
    BenchStats[] rows; /// one per benchIter/benchCase call (or whole-body)
    PerfGroup* perf;   /// null / unavailable = no perf counting pass
    Tier0Group* tier0; /// null / unavailable = no tier0 counting pass
    SyscallGroup* syscalls; /// null / unavailable = no syscall counting pass

    /// Enumerate mode (see `countBenchmarkCases`): `benchIter`/`benchCase` record
    /// only that a case exists (bumping `caseCount`) and skip all measurement, so
    /// the runner can learn the case total before the real, progress-tracked pass.
    bool enumerateOnly;
    size_t caseCount;  /// enumerate: number of cases the body emitted

    /// Real-run progress hook, invoked with the case name as each case starts
    /// measuring (null = no reporting). Typed `@safe nothrow @nogc` so calling it
    /// never constrains a benchmark body's own inferred attributes.
    void delegate(scope const(char)[] name) @safe nothrow @nogc onCaseStart;
}

private BenchContext* activeBenchContext; // thread-local, set by runBenchmark

/// The counting-pass iteration count for a measurement: the timing's iteration
/// count, capped so a cheap op's huge count does not make the (ioctl-bracketed)
/// counting pass slow.
private uint perfIters(ulong iterations, in BenchConfig config) @safe pure nothrow @nogc
{
    import std.algorithm.comparison : min;

    const n = min(iterations, config.perfMaxIters);
    return cast(uint)(n ? n : 1);
}

/// The perf counting pass for a measurement, when a counter group is available:
/// `timed` is bracketed by the counters, `between` runs uncounted.
private Nullable!PerfStats countIf(Timed, Between)(
    BenchContext* context, scope Timed timed, scope Between between, ulong iterations)
{
    Nullable!PerfStats perf;
    if (context.perf !is null && context.perf.available)
        perf = context.perf.count(timed, between, perfIters(iterations, context.config));
    return perf;
}

/// The tier0 counting pass, when a tier0 metric was selected: `timed`+`between`
/// bracketed by two cheap `/proc` snapshots. A separate pass from `countIf`, so
/// each is paid for only when its metrics are requested.
private Nullable!Tier0Stats countTier0If(Timed, Between)(
    BenchContext* context, scope Timed timed, scope Between between, ulong iterations)
{
    Nullable!Tier0Stats tier0;
    if (context.tier0 !is null && context.tier0.available)
        tier0 = context.tier0.count(timed, between, perfIters(iterations, context.config));
    return tier0;
}

/// The syscall counting pass, when `--syscalls` opened tracepoints: `timed`
/// bracketed by the counters, `between` uncounted (mirrors `countIf`).
private Nullable!SyscallStats countSyscallsIf(Timed, Between)(
    BenchContext* context, scope Timed timed, scope Between between, ulong iterations)
{
    Nullable!SyscallStats syscalls;
    if (context.syscalls !is null && context.syscalls.available)
        syscalls = context.syscalls.count(timed, between, perfIters(iterations, context.config));
    return syscalls;
}

/// Measures `run` inside a `@benchmark unittest`, excluding the surrounding
/// setup from the timing, and records one row named after the test. Outside a
/// `--bench` run (e.g. another runner executes the test), `run` runs once.
void benchIter(DG)(scope DG run)
if (is(typeof(run()) == void))
{
    auto context = activeBenchContext;
    if (context is null)
    {
        run();
        return;
    }
    if (context.enumerateOnly) // dry pass: just tally the case, don't measure
    {
        context.used = true;
        context.caseCount++;
        return;
    }
    context.used = true;
    if (context.onCaseStart !is null)
        context.onCaseStart(context.testName);
    auto m = measure(run, context.config);
    auto row = computeStats(context.testName, m.iterations, m.nsPerIter);
    row.perf = countIf(context, run, () {}, m.iterations);
    row.tier0 = countTier0If(context, run, () {}, m.iterations);
    row.syscalls = countSyscallsIf(context, run, () {}, m.iterations);
    context.rows ~= row;
}

@("benchIter.inertOutsideBenchRuns")
@safe
unittest
{
    int calls;
    benchIter({ ++calls; });
    assert(calls == 1);
}

// ─────────────────────────────────────────────────────────────────────────────
// Multi-row cases (`benchCase`)
// ─────────────────────────────────────────────────────────────────────────────

/// One timed call plus its untimed `after`: the elapsed nanoseconds and an
/// error message (empty = ok) when `after` reported a soft (`Expected`) failure.
private struct DriveResult
{
    long ns;
    string error;
}

/// Renders the error an `after` callback returned in an `Expected`.
private string errorText(V)(V v)
{
    static if (is(typeof(v.error.describe()) : string))
        return v.error.describe();
    else static if (is(typeof(v.error) : string))
        return v.error;
    else
    {
        import std.conv : text;

        return v.error.text;
    }
}

/// Invokes a no-argument `after` (for a `void`-returning `timed`). A `void`
/// return throws on failure; an `Expected` return yields a soft error message.
private string invokeAfter(After)(scope After after)
{
    static if (is(typeof(after()) == void))
    {
        after();
        return null;
    }
    else
    {
        auto v = after();
        return v.hasError ? errorText(v) : null;
    }
}

/// Invokes a result-taking `after(ref Res)`. Same throw-vs-`Expected` contract.
private string invokeAfter(Res, After)(scope After after, ref Res result)
{
    static if (is(typeof(after(result)) == void))
    {
        after(result);
        return null;
    }
    else
    {
        auto v = after(result);
        return v.hasError ? errorText(v) : null;
    }
}

/// Times one `timed()` call and runs `after` untimed on its result.
private DriveResult driveOnce(Timed, After)(scope Timed timed, scope After after)
{
    static if (is(typeof(timed()) == void))
    {
        const t0 = MonoTime.currTime;
        timed();
        const ns = (MonoTime.currTime - t0).total!"nsecs";
        return DriveResult(ns, invokeAfter(after));
    }
    else
    {
        const t0 = MonoTime.currTime;
        auto r = timed();
        const ns = (MonoTime.currTime - t0).total!"nsecs";
        return DriveResult(ns, invokeAfter(after, r));
    }
}

/// Measures one named case inside a `@benchmark` body and records a row; call it
/// repeatedly (over engines × datasets, say) to emit a matrix. `timed` is the
/// measured body — its result flows to `after`, which runs untimed after every
/// iteration to verify + release it. `after` may `throw` (→ the whole benchmark
/// test fails) or return an `Expected` error (→ this case becomes an error row
/// and the others continue). A case with nothing to release/verify passes a
/// no-op `after` (`(ref r) {}`, or `() {}` for a `void` body). `metrics` attach
/// throughput / level columns.
///
/// Uses per-call timing — each `timed()` timed alone, `after` between — so the
/// result can be released before the next iteration; suited to µs-and-up ops.
void benchCase(Timed, After)(
    string name, scope Timed timed, scope After after, Metric[] metrics = null)
{
    import std.algorithm.iteration : map;
    import std.array : array;

    auto context = activeBenchContext;
    if (context is null) // executed outside a --bench run: one probe, for correctness
    {
        cast(void) driveOnce(timed, after);
        return;
    }
    if (context.enumerateOnly) // dry pass: just tally the case, don't measure
    {
        context.used = true;
        context.caseCount++;
        return;
    }
    if (context.onCaseStart !is null)
        context.onCaseStart(name);

    // Probe once so an `after` throw/error surfaces before the measurement loop.
    {
        const probe = driveOnce(timed, after);
        if (probe.error.length)
        {
            context.rows ~= BenchStats(name: name, error: probe.error);
            return;
        }
    }
    context.used = true;

    // Per-call timing: collect until both the sample count and time budget met.
    long[] samples;
    long totalNs;
    const minTotal = context.config.minSampleTime.total!"nsecs";
    while (samples.length < context.config.sampleCount || totalNs < minTotal)
    {
        const d = driveOnce(timed, after);
        if (d.error.length)
        {
            context.rows ~= BenchStats(name: name, error: d.error);
            return;
        }
        samples ~= d.ns;
        totalNs += d.ns;
    }

    auto row = computeStats(name, 1, samples.map!(s => double(s)).array);
    row.metrics = metrics;

    // Counting pass: bracket `timed`; `after` releases the result (uncounted by
    // perf, inside the tier0 window). Perf and tier0 pass over the same closures.
    static if (is(typeof(timed()) == void))
    {
        auto release = () { cast(void) invokeAfter(after); };
        row.perf = countIf(context, timed, release, samples.length);
        row.tier0 = countTier0If(context, timed, release, samples.length);
        row.syscalls = countSyscallsIf(context, timed, release, samples.length);
    }
    else
    {
        typeof(timed()) last;
        auto run = () { last = timed(); };
        auto release = () { cast(void) invokeAfter(after, last); };
        row.perf = countIf(context, run, release, samples.length);
        row.tier0 = countTier0If(context, run, release, samples.length);
        row.syscalls = countSyscallsIf(context, run, release, samples.length);
    }
    context.rows ~= row;
}

/// The outcome of one `@benchmark` execution: the rows it emitted (one per
/// `benchIter`/`benchCase`, or one for a whole-body benchmark) and the test's
/// pass/fail `TestResult` (a thrown body fails; its rows may be partial).
struct BenchOutcome
{
    BenchStats[] rows;
    TestResult result;
}

/// Runs one `@benchmark` test with an active context so `benchIter`/`benchCase`
/// record rows; a body that calls neither is measured whole as a single row.
/// `onCaseStart` (optional) is invoked with each case's name as it begins
/// measuring — the seam the runner drives its live progress line from.
package(sparkles.test_runner)
BenchOutcome runBenchmark(Test test, in BenchConfig config, ref PerfGroup perf,
    ref Tier0Group tier0, ref SyscallGroup syscalls,
    void delegate(scope const(char)[] name) @safe nothrow @nogc onCaseStart = null)
{
    import sparkles.test_runner.execution : executeTest;

    BenchOutcome outcome;
    auto context = BenchContext(config: config, testName: test.name,
        perf: &perf, tier0: &tier0, syscalls: &syscalls, onCaseStart: onCaseStart);

    activeBenchContext = &context;
    scope (exit)
        activeBenchContext = null;

    outcome.result = executeTest(test);
    outcome.rows = context.rows;
    if (!outcome.result.succeeded)
        return outcome; // rows collected before a throw are kept

    if (!context.used) // no benchIter/benchCase — measure the whole body
    {
        if (onCaseStart !is null)
            onCaseStart(test.name);
        auto m = measure({ test.ptr(); }, config);
        auto row = computeStats(test.name, m.iterations, m.nsPerIter);
        row.perf = countIf(&context, { test.ptr(); }, () {}, m.iterations);
        row.tier0 = countTier0If(&context, { test.ptr(); }, () {}, m.iterations);
        row.syscalls = countSyscallsIf(&context, { test.ptr(); }, () {}, m.iterations);
        outcome.rows ~= row;
    }
    return outcome;
}

/// Enumerates `test`'s benchmark cases without measuring any of them, returning
/// the case count (a whole-body benchmark counts as 1). Runs the body once under
/// an `enumerateOnly` context so `benchIter`/`benchCase` only tally; the runner
/// sums this across tests to get the exact denominator for its progress line.
package(sparkles.test_runner)
size_t countBenchmarkCases(Test test)
{
    import sparkles.test_runner.execution : executeTest;

    auto context = BenchContext(testName: test.name, enumerateOnly: true);
    activeBenchContext = &context;
    scope (exit)
        activeBenchContext = null;

    cast(void) executeTest(test);
    return context.used ? context.caseCount : 1; // whole-body = one case
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
    auto tier0 = Tier0Group.tryOpen(false);
    auto syscalls = SyscallGroup.tryOpen(false, null);
    auto outcome = runBenchmark(Test(fullName: "m.b", name: "b", ptr: &body_), config, perf, tier0, syscalls);
    assert(outcome.result.succeeded);
    assert(outcome.rows[0].iterations == 4);
    assert(outcome.rows[0].samples == 3);
    assert(outcome.rows[0].nsPerIterMedian >= 0);
    assert(outcome.rows[0].perf.isNull); // no counters requested
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
    auto tier0 = Tier0Group.tryOpen(false);
    auto syscalls = SyscallGroup.tryOpen(false, null);
    auto outcome = runBenchmark(Test(fullName: "m.bi", name: "bi", ptr: &body_), config, perf, tier0, syscalls);
    assert(outcome.result.succeeded);
    assert(outcome.rows[0].iterations == 8);
    assert(outcome.rows[0].samples == 2);
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
    auto tier0 = Tier0Group.tryOpen(false);
    auto syscalls = SyscallGroup.tryOpen(false, null);
    auto outcome = runBenchmark(Test(fullName: "m.f", name: "f", ptr: &failing), BenchConfig(), perf, tier0, syscalls);
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
    auto tier0 = Tier0Group.tryOpen(false);
    auto syscalls = SyscallGroup.tryOpen(false, null);
    scope (exit)
        perf.close();
    if (!perf.available) // paranoid/sandboxed kernels refuse; not a failure
        return;

    const config = BenchConfig(iterations: 200, sampleCount: 2, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(Test(fullName: "m.p", name: "p", ptr: &body_), config, perf, tier0, syscalls);
    assert(outcome.result.succeeded);
    assert(!outcome.rows[0].perf.isNull);
    assert(outcome.rows[0].perf.get.instructions > 0);
}

@("benchCase.demo")
@benchmark @safe
unittest
{
    // Dogfoods benchCase: one @benchmark emits a row per size, each with an
    // element-throughput metric. Skipped by default; measured under `--bench`.
    import std.conv : text;

    foreach (size; [64, 256, 1024])
        benchCase(
            name: text("sum/", size),
            timed: () { size_t s; foreach (i; 0 .. size) s += i; blackBox(s); },
            after: () {}, // nothing to release
            metrics: [Metric(unit: Unit("elem"), amount: double(size), mode: Metric.Mode.rate)],
        );
}

@("syscalls.demo")
@benchmark @system
unittest
{
    // Dogfoods --syscalls: each measured iteration issues exactly one getpid, so
    // under `--bench --syscalls=getpid` the `sc:getpid` column reads ≈ 1.
    // Skipped by default; measured under --bench.
    import core.sys.posix.unistd : getpid;

    benchIter({ () @trusted { blackBox(getpid()); }(); });
}

@("benchCase.emitsRowsWithMetrics")
@system
unittest
{
    import core.time : usecs;
    import std.conv : text;

    static void body_()
    {
        foreach (i; 0 .. 3)
        {
            const n = (i + 1) * 200;
            benchCase(
                name: text("case", i),
                timed: () { foreach (j; 0 .. n) blackBox(j); },
                after: () {}, // nothing to release/verify
                metrics: [Metric(unit: Unit("B"), amount: double(n), mode: Metric.Mode.rate)],
            );
        }
    }

    auto perf = PerfGroup.tryOpen(false);
    auto tier0 = Tier0Group.tryOpen(false);
    auto syscalls = SyscallGroup.tryOpen(false, null);
    const config = BenchConfig(sampleCount: 2, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(Test(fullName: "m.mc", name: "mc", ptr: &body_), config, perf, tier0, syscalls);
    assert(outcome.result.succeeded);
    assert(outcome.rows.length == 3);
    assert(outcome.rows[0].name == "case0" && outcome.rows[0].error.length == 0);
    assert(outcome.rows[0].metrics.length == 1);
    assert(outcome.rows[0].metrics[0].unit.symbol == "B");
    assert(outcome.rows[2].name == "case2");
}

@("countBenchmarkCases.matrixAndWholeBody")
@system
unittest
{
    // A matrix body's cases are tallied without measuring; a body that calls
    // neither benchCase nor benchIter counts as one whole-body case.
    static void matrix()
    {
        foreach (i; 0 .. 3)
            benchCase(name: "c", timed: () { blackBox(i); }, after: () {});
    }

    static void whole()
    {
        size_t s;
        foreach (i; 0 .. 10)
            s += i;
        blackBox(s);
    }

    assert(countBenchmarkCases(Test(fullName: "m.matrix", name: "matrix", ptr: &matrix)) == 3);
    assert(countBenchmarkCases(Test(fullName: "m.whole", name: "whole", ptr: &whole)) == 1);
}

@("runBenchmark.onCaseStartPerCase")
@system
unittest
{
    import core.time : usecs;

    static void body_()
    {
        foreach (i; 0 .. 3)
            benchCase(name: "c", timed: () { blackBox(i); }, after: () {});
    }

    // The progress hook is `@safe nothrow @nogc`; count via a struct-method
    // delegate so no GC closure is needed and the strict type is satisfied.
    static struct Rec
    {
        size_t n;
        void tick(scope const(char)[] name) @safe nothrow @nogc
        {
            n++;
        }
    }

    Rec rec;
    auto perf = PerfGroup.tryOpen(false);
    auto tier0 = Tier0Group.tryOpen(false);
    auto syscalls = SyscallGroup.tryOpen(false, null);
    const config = BenchConfig(sampleCount: 1, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(Test(fullName: "m.b", name: "b", ptr: &body_),
        config, perf, tier0, syscalls, &rec.tick);
    assert(outcome.result.succeeded);
    assert(rec.n == 3); // exactly one tick per case
}

@("benchCase.expectedErrorIsIsolatedRow")
@system
unittest
{
    import core.time : usecs;
    import expected : Expected, err, ok;

    alias Res = Expected!(bool, string);
    static Res check(int r) => r == 5 ? ok!string(true) : err!bool("expected 5");

    static void body_()
    {
        // A soft (Expected) failure becomes an error row; the matrix continues.
        benchCase(name: "bad", timed: () => 3, after: (ref int r) => check(r));
        benchCase(name: "good", timed: () => 5, after: (ref int r) => check(r));
    }

    auto perf = PerfGroup.tryOpen(false);
    auto tier0 = Tier0Group.tryOpen(false);
    auto syscalls = SyscallGroup.tryOpen(false, null);
    const config = BenchConfig(sampleCount: 1, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(Test(fullName: "m.er", name: "er", ptr: &body_), config, perf, tier0, syscalls);
    assert(outcome.result.succeeded);
    assert(outcome.rows.length == 2);
    assert(outcome.rows[0].name == "bad" && outcome.rows[0].error == "expected 5");
    assert(outcome.rows[1].name == "good" && outcome.rows[1].error.length == 0);
}

@("benchCase.afterThrowFailsWholeTest")
@system
unittest
{
    import core.time : usecs;

    static void body_()
    {
        // A throwing `after` (a hard mismatch) aborts the whole benchmark test.
        benchCase(
            name: "boom",
            timed: () { int[] result; return result; },
            after: (ref int[] r) { assert(r.length == 1, "empty result"); },
        );
    }

    auto perf = PerfGroup.tryOpen(false);
    auto tier0 = Tier0Group.tryOpen(false);
    auto syscalls = SyscallGroup.tryOpen(false, null);
    auto outcome = runBenchmark(Test(fullName: "m.bt", name: "bt", ptr: &body_),
        BenchConfig(sampleCount: 1, minSampleTime: 1.usecs), perf, tier0, syscalls);
    assert(!outcome.result.succeeded);
    assert(outcome.result.thrown.length == 1);
}
