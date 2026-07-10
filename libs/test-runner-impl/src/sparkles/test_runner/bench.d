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
import sparkles.test_runner.model : Test, TestResult, Thrown;
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
    string[string] labels; /// orthogonal grouping dimensions (from the case's `labels`)
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

/// An error-row `BenchStats` for a case whose measurement threw, so the streaming
/// runner can surface the crash in its group table (like a soft `Expected` error)
/// instead of dropping the row and aborting the matrix. `thrown` is the converted
/// chain (`toThrown`, which already re-throws `OutOfMemoryError`).
package(sparkles.test_runner)
BenchStats errorRow(string name, string[string] labels, in Thrown[] thrown)
{
    import std.conv : text;

    const msg = thrown.length ? text(thrown[0].type, ": ", thrown[0].message) : "threw";
    return BenchStats(name: name, labels: labels, error: errorCell(msg));
}

/// The first line of a (possibly multi-line) error message, ellipsized:
/// `BenchStats.error` lands in a single table cell, and an embedded newline
/// breaks the no-core-cli fallback grid's rectangular layout. The full text
/// still reaches the console via the failure trace (thrown path); `Expected`
/// messages are one-liners by convention.
package(sparkles.test_runner)
string errorCell(string message) @safe pure nothrow
{
    foreach (i, ch; message)
        if (ch == '\n' || ch == '\r')
            return message[0 .. i] ~ " …";
    return message;
}

@("bench.errorCell.firstLineOnly")
@safe pure nothrow
unittest
{
    assert(errorCell("boom") == "boom");
    assert(errorCell("boom\ndetails\nmore") == "boom …");
    assert(errorCell("boom\r\ndetails") == "boom …");
    assert(errorCell("") == "");
}

@("benchCase.inertPathSurfacesExpectedError")
@system
unittest
{
    import std.exception : assertThrown;
    import expected : err;

    // Outside --bench (a foreign runner executing the test) a soft `Expected`
    // error from `after` must fail the test, not vanish; teardown still runs.
    static bool teardownRan;
    teardownRan = false;
    assertThrown(benchCase(name: "bad", timed: () {},
        after: () => err!bool("mismatch"),
        teardown: () { teardownRan = true; }));
    assert(teardownRan, "teardown runs on the inert failure path");
}

@("bench.errorRow.carriesNameLabelsMessage")
@system
unittest
{
    auto row = errorRow("wired/twitter/decode", ["dataset": "twitter"],
        [Thrown(type: "object.Exception", message: "boom")]);
    assert(row.name == "wired/twitter/decode");
    assert(row.labels["dataset"] == "twitter");
    assert(row.error == "object.Exception: boom");
    assert(errorRow("c", null, null).error == "threw"); // empty chain fallback
}

/// Times `run` with the libtest protocol: doubles the per-sample iteration
/// count until one sample takes `config.minSampleTime`, then collects
/// `config.sampleCount` samples. Returns `(iterations, ns/iter samples)`.
package(sparkles.test_runner)
auto measure(DG)(scope DG run, in BenchConfig config)
{
    import std.typecons : tuple;

    static long sampleOnceNs(scope DG run, ulong iterations)
    {
        const t0 = MonoTime.currTime.ticks;
        foreach (_; 0 .. iterations)
            run();
        return elapsedNs(t0);
    }

    // Warmup + auto-scale: double until one sample is long enough to time.
    ulong iterations = config.iterations ? config.iterations : 1;
    if (!config.iterations)
        while (sampleOnceNs(run, iterations) < config.minSampleTime.total!"nsecs"
                && iterations < 1UL << 40)
            iterations *= 2;

    auto nsPerIter = new double[](config.sampleCount);
    foreach (ref sample; nsPerIter)
        sample = double(sampleOnceNs(run, iterations)) / iterations;

    return tuple!("iterations", "nsPerIter")(iterations, nsPerIter);
}

/// Nanoseconds elapsed since `startTicks` (a `MonoTime.currTime.ticks` value).
/// Raw ticks, not `MonoTime` subtraction: the latter yields a `Duration`,
/// whose hnsec storage quantizes every sample to a 100 ns grid — fatal to
/// sub-microsecond per-call medians.
private long elapsedNs(long startTicks) @safe nothrow @nogc
{
    import core.time : convClockFreq;

    return convClockFreq(MonoTime.currTime.ticks - startTicks,
        MonoTime.ticksPerSecond, 1_000_000_000L);
}

@("bench.elapsedNs.preservesSubHnsecDeltas")
@safe pure nothrow @nogc
unittest
{
    import core.time : convClockFreq;

    // 42 ticks of a 1 GHz monotonic clock is 42 ns — the Duration (hnsec)
    // path reports 0. The helper's conversion keeps the clock's resolution.
    assert(convClockFreq(42, 1_000_000_000L, 1_000_000_000L) == 42);
    assert(convClockFreq(42, 10_000_000L, 1_000_000_000L) == 4200);
}

// ─────────────────────────────────────────────────────────────────────────────
// In-test measurement API (`benchIter`) and the runner-side driver
// ─────────────────────────────────────────────────────────────────────────────

/// One benchmark case, captured by `benchCase`/`benchIter` and measured later by
/// `measureCase`. The generic `timed`/`after` closures are type-erased to uniform
/// delegates at registration, so a heterogeneous matrix collapses to a flat list
/// the runner can freely filter, group, sort, and schedule before executing.
///
/// The delegates run at *execution* time, not registration — so their captured
/// state must outlive the registering body (use `setup`/`teardown` for untimed
/// per-case setup and release; capture fresh per-case values, never a shared loop
/// variable).
struct RegisteredCase
{
    string name;              /// row name (the varying dimension, e.g. an engine)
    string[string] labels;    /// orthogonal dimensions for grouping, e.g. `["dataset": …]`
    Metric[] metrics;         /// throughput / level columns
    void delegate() setup;    /// untimed, once before measurement (null = none)
    void delegate() runTimed; /// the measured body (value results stashed internally)
    /// Untimed, after each measured call; `null`/`""` = ok, else an error message.
    /// `null` selects batched timing (`benchIter` / whole-body — no per-call release).
    string delegate() runAfter;
    void delegate() teardown; /// untimed, once after measurement (null = none)
}

/// The three counter sources bundled into one value, so the bench driver threads
/// a single `CounterGroups` instead of three parallel params/pointers/fields (and
/// a matching triple of `Nullable` result fields). Each source is opened
/// independently; one not requested — or unavailable on this machine — contributes
/// no columns. Adding a future source is one field plus one line in each of
/// `open`/`close`/`countInto`, not a shotgun edit across every call site.
struct CounterGroups
{
    PerfGroup perf;
    Tier0Group tier0;
    SyscallGroup syscalls;

    /// Opens each requested source: `--perf` (`perfWanted`), a selected tier0
    /// metric (`tier0Wanted`), and `--syscalls` (`syscallWanted` + `syscallNames`).
    static CounterGroups open(bool perfWanted, bool tier0Wanted, bool syscallWanted,
        const(string)[] syscallNames) @safe
    {
        CounterGroups g;
        g.perf = PerfGroup.tryOpen(perfWanted);
        g.tier0 = Tier0Group.tryOpen(tier0Wanted);
        g.syscalls = SyscallGroup.tryOpen(syscallWanted, syscallNames);
        return g;
    }

    /// An all-unavailable bundle: no counting passes (tests, non-counting runs).
    static CounterGroups none() @safe => CounterGroups.open(false, false, false, null);

    /// Releases every source's resources.
    void close() @safe
    {
        perf.close();
        tier0.close();
        syscalls.close();
    }

    /// Runs each available source's counting pass over `timed`/`between` (the
    /// iteration count capped once) and fills `row`'s perf/tier0/syscall fields.
    void countInto(Timed, Between)(ref BenchStats row, scope Timed timed,
        scope Between between, ulong iterations, in BenchConfig config)
    {
        const iters = perfIters(iterations, config);
        if (perf.available)
            row.perf = perf.count(timed, between, iters);
        if (tier0.available)
            row.tier0 = tier0.count(timed, between, iters);
        if (syscalls.available)
            row.syscalls = syscalls.count(timed, between, iters);
    }
}

private struct BenchContext
{
    BenchConfig config;
    string testName;         /// row name for benchIter / whole-body measurement
    RegisteredCase[] cases;  /// registration output (the body's benchCase/benchIter calls)
    CounterGroups* counters; /// null = no counting passes
}

private BenchContext* activeBenchContext; // thread-local, set during registration

/// The counting-pass iteration count for a measurement: the timing's iteration
/// count, capped so a cheap op's huge count does not make the (ioctl-bracketed)
/// counting pass slow.
private uint perfIters(ulong iterations, in BenchConfig config) @safe pure nothrow @nogc
{
    import std.algorithm.comparison : min;

    const n = min(iterations, config.perfMaxIters);
    return cast(uint)(n ? n : 1);
}

/// Registers a batched-timing case that measures `run` (excluding surrounding
/// setup from the timing), named after the test. Under `--bench` the case is
/// recorded and measured later; outside a `--bench` run (e.g. another runner
/// executes the test) `run` runs once, for correctness.
void benchIter(DG)(DG run, string[string] labels = null)
if (is(typeof(run()) == void))
{
    auto context = activeBenchContext;
    if (context is null)
    {
        run();
        return;
    }
    // `runAfter: null` → batched measurement (a tight loop, no per-call release).
    context.cases ~= RegisteredCase(
        name: context.testName,
        labels: labels,
        runTimed: () { run(); },
    );
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
        const t0 = MonoTime.currTime.ticks;
        timed();
        const ns = elapsedNs(t0);
        return DriveResult(ns, invokeAfter(after));
    }
    else
    {
        const t0 = MonoTime.currTime.ticks;
        auto r = timed();
        const ns = elapsedNs(t0);
        return DriveResult(ns, invokeAfter(after, r));
    }
}

/// Times one already-erased `runTimed()` call and runs `runAfter` untimed after.
private DriveResult driveErased(scope void delegate() runTimed, scope string delegate() runAfter)
{
    const t0 = MonoTime.currTime.ticks;
    runTimed();
    const ns = elapsedNs(t0);
    return DriveResult(ns, runAfter is null ? null : runAfter());
}

/// Whether the per-call timing loop should collect another sample. It stops once
/// both the sample count and the time budget are met — except a sub-nanosecond op
/// on a coarse clock can round every per-call delta to `0`, so `totalNs` never
/// reaches the budget: once the sample count is met with the clock not advancing
/// at all, the budget is unreachable and sampling stops (rather than spinning
/// forever, the analogue of `measure`'s `iterations < 1UL << 40` cap).
private bool keepSampling(size_t samples, long totalNs, in BenchConfig config)
    @safe pure nothrow @nogc
{
    if (samples >= config.sampleCount && totalNs == 0)
        return false;
    return samples < config.sampleCount || totalNs < config.minSampleTime.total!"nsecs";
}

@("bench.keepSampling.zeroProgressTerminates")
@safe pure nothrow @nogc
unittest
{
    import core.time : msecs;

    const config = BenchConfig(sampleCount: 32, minSampleTime: 5.msecs);
    assert(keepSampling(0, 0, config));               // need samples
    assert(keepSampling(32, 100, config));            // clock advancing, budget unmet
    assert(!keepSampling(32, 0, config));             // zero progress → stop, no hang
    assert(!keepSampling(32, 5.msecs.total!"nsecs", config)); // both met
    assert(keepSampling(4, 0, config));               // count unmet → keep, even at 0 ns
}

/// A `Setup`/`Teardown` argument as a plain `void delegate()` (`null` when absent).
/// A `@safe` delegate converts to the `@system` slot (the erased case is measured
/// on the runner side, not from a `@safe` body); a delegate value passes through so
/// a runtime `null` (e.g. an engine with no setup) is preserved for `measureCase`'s
/// null guard; a `function` pointer (a lambda capturing only globals) is wrapped.
private void delegate() toVoidDg(S)(S s)
{
    static if (is(S == typeof(null)))
        return null;
    else static if (is(S : void delegate()))
        return s; // already a delegate (possibly null) — preserve it
    else
        // function pointer → wrap into a delegate, preserving a runtime null so
        // measureCase's `!is null` guard still treats it as "no setup/teardown"
        // (a non-null wrapper around a null fptr would call through null).
        return s is null ? null : () { s(); };
}

@("bench.toVoidDg.preservesNull")
@safe
unittest
{
    assert(toVoidDg(null) is null);
    void delegate() nullDg;
    assert(toVoidDg(nullDg) is null); // null delegate preserved
    void function() nullFp;
    assert(toVoidDg(nullFp) is null); // null fptr → null, not a call-through wrapper
    static void f() @safe {}
    assert(toVoidDg(&f) !is null); // real fptr → wrapped
}

/// Type-erases a case's generic `timed`/`after` into a `RegisteredCase`'s uniform
/// delegates. A value-returning `timed` stashes its result in a shared slot that
/// `runAfter` reads, so the value still flows to `after` across the erasure.
private RegisteredCase makeCase(Timed, After)(string name, string[string] labels,
    Timed timed, After after, Metric[] metrics, void delegate() setup, void delegate() teardown)
{
    RegisteredCase c;
    c.name = name;
    c.labels = labels;
    c.metrics = metrics;
    c.setup = setup;
    c.teardown = teardown;
    static if (is(typeof(timed()) == void))
    {
        c.runTimed = () { timed(); };
        c.runAfter = () => invokeAfter(after);
    }
    else
    {
        typeof(timed()) last; // shared by both closures via the promoted frame
        c.runTimed = () { last = timed(); };
        c.runAfter = () => invokeAfter(after, last);
    }
    return c;
}

/// Registers one named case inside a `@benchmark` body; call it repeatedly (over
/// engines × datasets, say) to emit a matrix. `timed` is the measured body — its
/// result flows to `after`, which runs untimed after every iteration to verify +
/// release it. `after` may `throw` (→ the whole benchmark test fails) or return an
/// `Expected` error (→ this case becomes an error row and the others continue). A
/// case with nothing to release/verify passes a no-op `after` (`(ref r) {}`, or
/// `() {}` for a `void` body). `metrics` attach throughput / level columns.
///
/// Optional `setup`/`teardown` run untimed once around this case's measurement (at
/// execution time) — put per-case state that a scheduled, deferred run needs there
/// (e.g. parse the document a serialize case serializes, and release it after).
///
/// Optional `labels` name orthogonal dimensions of the case (e.g.
/// `["dataset": "twitter", "operation": "serialize"]`); `--group-by` selects label
/// keys to group and stream the report by, while `name` stays the varying
/// dimension shown per row (typically the implementation being compared).
///
/// Under `--bench` the case is *registered* and measured later by the runner, so
/// the closures run after the body returns: capture fresh per-case state (never a
/// shared loop variable), and keep any state they need alive via `setup`. Outside
/// a `--bench` run the case runs once immediately, for correctness.
///
/// Uses per-call timing — each `timed()` timed alone, `after` between — so the
/// result can be released before the next iteration; suited to µs-and-up ops.
void benchCase(Timed, After, Setup = typeof(null), Teardown = typeof(null))(
    string name, Timed timed, After after, Metric[] metrics = null,
    string[string] labels = null, Setup setup = null, Teardown teardown = null)
{
    auto context = activeBenchContext;
    if (context is null) // outside a --bench run: run once, for correctness
    {
        static if (!is(Setup == typeof(null)))
            if (setup !is null)
                setup();
        scope (exit)
        {
            static if (!is(Teardown == typeof(null)))
                if (teardown !is null)
                    teardown();
        }
        const r = driveOnce(timed, after);
        // An `Expected` error from `after` isolates a *row* under --bench;
        // outside --bench there is no table to isolate into, and swallowing
        // it would green a failing verification under a foreign runner.
        if (r.error.length)
            throw new Exception("benchCase '" ~ name ~ "': " ~ r.error);
        return;
    }
    context.cases ~= makeCase(name, labels, timed, after, metrics,
        toVoidDg(setup), toVoidDg(teardown));
}

/// Measures one registered case into a `BenchStats` row. `setup`/`teardown` bracket
/// the whole measurement (untimed); a `runAfter`-reported soft error or a probe
/// failure yields an error row. `null` `runAfter` selects batched timing (a tight
/// `measure` loop, for `benchIter`/whole-body); otherwise per-call timing releases
/// the result between calls. A thrown `runTimed`/`runAfter` propagates to the caller.
package(sparkles.test_runner)
BenchStats measureCase(RegisteredCase c, in BenchConfig config, ref CounterGroups counters)
{
    auto ctx = BenchContext(config: config, counters: &counters);
    return measureCase(&ctx, c);
}

/// ditto
package(sparkles.test_runner)
BenchStats measureCase(BenchContext* context, RegisteredCase c)
{
    import std.algorithm.iteration : map;
    import std.array : array;

    if (c.setup !is null)
        c.setup();
    scope (exit)
        if (c.teardown !is null)
            c.teardown();

    if (c.runAfter is null) // batched: benchIter / whole-body
    {
        auto m = measure(c.runTimed, context.config);
        auto row = computeStats(c.name, m.iterations, m.nsPerIter);
        row.labels = c.labels;
        row.metrics = c.metrics;
        if (context.counters !is null)
            context.counters.countInto(row, c.runTimed, () {}, m.iterations, context.config);
        return row;
    }

    // Probe once so an `after` error surfaces before the measurement loop —
    // except under a pinned count, where every call is one of the N samples.
    if (!context.config.iterations)
    {
        const probe = driveErased(c.runTimed, c.runAfter);
        if (probe.error.length)
            return BenchStats(name: c.name, labels: c.labels,
                error: errorCell(probe.error));
    }

    // Per-call timing: collect until both the sample count and time budget met
    // (or the clock stalls at 0 ns — see `keepSampling`). A pinned
    // `@benchmark(iterations: N)` runs exactly N timed calls, one sample each.
    long[] samples;
    long totalNs;
    while (context.config.iterations
        ? samples.length < context.config.iterations
        : keepSampling(samples.length, totalNs, context.config))
    {
        const d = driveErased(c.runTimed, c.runAfter);
        if (d.error.length)
            return BenchStats(name: c.name, labels: c.labels,
                error: errorCell(d.error));
        samples ~= d.ns;
        totalNs += d.ns;
    }

    auto row = computeStats(c.name, 1, samples.map!(s => double(s)).array);
    row.labels = c.labels;
    row.metrics = c.metrics;

    // Counting pass: bracket `runTimed`; `runAfter` releases the result between
    // iterations (excluded from every source's window).
    auto release = () { cast(void) c.runAfter(); };
    if (context.counters !is null)
        context.counters.countInto(row, c.runTimed, release, samples.length, context.config);
    return row;
}

/// The outcome of one `@benchmark` execution: the rows it emitted (one per
/// `benchIter`/`benchCase`, or one for a whole-body benchmark) and the test's
/// pass/fail `TestResult` (a thrown body fails; its rows may be partial).
struct BenchOutcome
{
    BenchStats[] rows;
    TestResult result;
}

/// The result of running (registering) one `@benchmark` test body: the cases it
/// registered and the body's pass/fail `TestResult` (a body that throws during
/// registration fails and registers no — or partial — cases).
package(sparkles.test_runner)
struct Registration
{
    RegisteredCase[] cases;
    TestResult result;
}

/// Runs one `@benchmark` test body to *register* its cases (via `benchIter`/
/// `benchCase`), without measuring them. A body that registers none is treated as
/// a single whole-body case named after the test (the body itself is the measured
/// unit). Registration-time throws are caught into `result`.
package(sparkles.test_runner)
Registration registerBenchmark(Test test, in BenchConfig config)
{
    import sparkles.test_runner.execution : executeTest;

    auto context = BenchContext(config: config, testName: test.name);
    activeBenchContext = &context;
    scope (exit)
        activeBenchContext = null;

    auto result = executeTest(test);
    if (result.succeeded && context.cases.length == 0)
        context.cases ~= RegisteredCase(name: test.name, runTimed: { test.ptr(); });
    return Registration(context.cases, result);
}

/// Registers one `@benchmark` test then measures every case it emitted, in
/// registration order. Kept for the single-test / non-streaming path (and the
/// self-tests that read `rows` synchronously); the streaming runner registers
/// across all tests first and schedules the cases itself. A case that throws
/// during measurement fails the whole test (partial rows are kept).
package(sparkles.test_runner)
BenchOutcome runBenchmark(Test test, in BenchConfig config, ref CounterGroups counters,
    void delegate(scope const(char)[] name) @safe nothrow @nogc onCaseStart = null)
{
    import sparkles.test_runner.execution : toThrown;

    auto reg = registerBenchmark(test, config);
    BenchOutcome outcome;
    outcome.result = reg.result;
    if (!reg.result.succeeded)
        return outcome;

    auto ctx = BenchContext(config: config, counters: &counters);
    foreach (ref c; reg.cases)
    {
        if (onCaseStart !is null)
            onCaseStart(c.name);
        try
            outcome.rows ~= measureCase(&ctx, c);
        catch (Throwable t)
        {
            outcome.result.succeeded = false;
            outcome.result.thrown ~= toThrown(t);
            return outcome; // a thrown case fails the test; keep partial rows
        }
    }
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
    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(Test(fullName: "m.b", name: "b", ptr: &body_), config, counters);
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
    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(Test(fullName: "m.bi", name: "bi", ptr: &body_), config, counters);
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

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(Test(fullName: "m.f", name: "f", ptr: &failing), BenchConfig(), counters);
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

    auto counters = CounterGroups.open(true, false, false, null);
    scope (exit)
        counters.close();
    if (!counters.perf.available) // paranoid/sandboxed kernels refuse; not a failure
        return;

    const config = BenchConfig(iterations: 200, sampleCount: 2, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(Test(fullName: "m.p", name: "p", ptr: &body_), config, counters);
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
    // The per-case work is registered through a helper taking `size` by value, so
    // each case's `timed` closure captures its own `size` (a loop-body variable is
    // one shared slot under deferred execution — the register model's key contract).
    import std.conv : text;

    static void reg(int size) @safe
    {
        benchCase(
            name: text("sum/", size),
            timed: () { size_t s; foreach (i; 0 .. size) s += i; blackBox(s); },
            after: () {}, // nothing to release
            metrics: [Metric(unit: Unit("elem"), amount: double(size), mode: Metric.Mode.rate)],
        );
    }

    foreach (size; [64, 256, 1024])
        reg(size);
}

version (linux)
@("syscalls.demo")
@benchmark @system
unittest
{
    // Dogfoods --syscalls (Linux-only, like the tracepoint counters it demos):
    // each measured iteration issues exactly one getpid, so under
    // `--bench --syscalls=getpid` the `sc:getpid` column reads ≈ 1.
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

    auto counters = CounterGroups.none;
    const config = BenchConfig(sampleCount: 2, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(Test(fullName: "m.mc", name: "mc", ptr: &body_), config, counters);
    assert(outcome.result.succeeded);
    assert(outcome.rows.length == 3);
    assert(outcome.rows[0].name == "case0" && outcome.rows[0].error.length == 0);
    assert(outcome.rows[0].metrics.length == 1);
    assert(outcome.rows[0].metrics[0].unit.symbol == "B");
    assert(outcome.rows[2].name == "case2");
}

@("registerBenchmark.matrixAndWholeBody")
@system
unittest
{
    // Registration collects a matrix body's cases without measuring; a body that
    // calls neither benchCase nor benchIter registers a single whole-body case.
    static void matrix()
    {
        static void reg(int i) { benchCase(name: "c", timed: () { blackBox(i); }, after: () {}); }
        foreach (i; 0 .. 3)
            reg(i);
    }

    static void whole()
    {
        size_t s;
        foreach (i; 0 .. 10)
            s += i;
        blackBox(s);
    }

    assert(registerBenchmark(Test(fullName: "m.matrix", name: "matrix", ptr: &matrix),
            BenchConfig()).cases.length == 3);
    auto wb = registerBenchmark(Test(fullName: "m.whole", name: "whole", ptr: &whole), BenchConfig());
    assert(wb.cases.length == 1 && wb.cases[0].name == "whole");
}

@("runBenchmark.onCaseStartPerCase")
@system
unittest
{
    import core.time : usecs;

    // Register through a per-case helper so each deferred `timed` closure captures
    // its own `i` — the "never a shared loop variable" contract benchCase documents
    // (a bare `foreach (i; …)` capture would read one shared, post-loop `i`).
    static void reg(int i)
    {
        benchCase(name: "c", timed: () { blackBox(i); }, after: () {});
    }

    static void body_()
    {
        foreach (i; 0 .. 3)
            reg(i);
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
    auto counters = CounterGroups.none;
    const config = BenchConfig(sampleCount: 1, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(Test(fullName: "m.b", name: "b", ptr: &body_),
        config, counters, &rec.tick);
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

    auto counters = CounterGroups.none;
    const config = BenchConfig(sampleCount: 1, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(Test(fullName: "m.er", name: "er", ptr: &body_), config, counters);
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

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(Test(fullName: "m.bt", name: "bt", ptr: &body_),
        BenchConfig(sampleCount: 1, minSampleTime: 1.usecs), counters);
    assert(!outcome.result.succeeded);
    assert(outcome.result.thrown.length == 1);
}

@("measureCase.setupTeardownOnce")
@system
unittest
{
    import core.time : usecs;

    // setup/teardown bracket the whole measurement (once each), while timed runs
    // many times — the seam that lets a deferred, scheduled case set up and release
    // its own state at execution time.
    static size_t setups, teardowns, timeds;
    setups = teardowns = timeds = 0;

    static void body_()
    {
        benchCase(
            name: "c",
            timed: () { timeds++; blackBox(timeds); },
            after: () {},
            setup: () { setups++; },
            teardown: () { teardowns++; },
        );
    }

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(Test(fullName: "m.st", name: "st", ptr: &body_),
        BenchConfig(sampleCount: 3, minSampleTime: 1.usecs), counters);
    assert(outcome.result.succeeded);
    assert(setups == 1, "setup runs exactly once, not per iteration");
    assert(teardowns == 1, "teardown runs exactly once, not per iteration");
    assert(timeds > 1, "timed runs repeatedly");
}

@("measureCase.teardownRunsOnError")
@system
unittest
{
    import core.time : usecs;
    import expected : err, ok;

    // A soft error yields an error row; teardown still runs (it is scope-guarded),
    // so a scheduled case never leaks its per-case state on the failure path.
    static size_t teardowns;
    teardowns = 0;

    static void body_()
    {
        benchCase(
            name: "bad",
            timed: () {},
            after: () => err!bool("boom"),
            teardown: () { teardowns++; },
        );
    }

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(Test(fullName: "m.te", name: "te", ptr: &body_),
        BenchConfig(sampleCount: 1, minSampleTime: 1.usecs), counters);
    assert(outcome.result.succeeded);
    assert(outcome.rows.length == 1 && outcome.rows[0].error == "boom");
    assert(teardowns == 1, "teardown runs even when the case errors");
}

@("measureCase.pinnedIterationsPerCall")
@system
unittest
{
    // `@benchmark(iterations: N)` pins a per-call case to exactly N timed calls
    // (one sample each): no probe call, no auto-scaling past the pin.
    static size_t timeds;
    timeds = 0;

    static void body_()
    {
        benchCase(name: "pinned", timed: () { timeds++; blackBox(timeds); },
            after: () {});
    }

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(Test(fullName: "m.pin", name: "pin", ptr: &body_),
        BenchConfig(iterations: 7), counters);
    assert(outcome.result.succeeded);
    assert(timeds == 7, "exactly the pinned number of timed calls");
    assert(outcome.rows.length == 1);
    assert(outcome.rows[0].samples == 7);
    assert(outcome.rows[0].iterations == 1, "per-call rows are 1 iteration/sample");
}
