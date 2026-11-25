/**
 * Benchmark measurement: auto-scaling iteration counts, basic robust
 * statistics, and an optimizer barrier.
 *
 * `@benchmark unittest` blocks are executed by the runner's `--bench` mode.
 * The whole test body is the measured unit. To keep setup out of the timing,
 * register the measured part as a case of a `@benchCases` test, with
 * $(LREF benchCase); a `BenchTiming.batched` case is timed the way a
 * whole body is:
 * ---
 * import sparkles.test_runner.attributes : benchCases;
 * import sparkles.test_runner.bench : BenchTiming, benchCase, blackBox;
 *
 * static struct SortCopy
 * {
 *     enum timing = BenchTiming.batched;
 *     int[] data;
 *
 *     void timed() @safe { blackBox(data.dup.sort()); } // measured
 * }
 *
 * @("sort.bench")
 * @benchCases @safe
 * unittest
 * {
 *     benchCase(SortCopy(makeInput())); // setup — not measured
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

import sparkles.test_runner.attributes : benchCases, benchmark, ctfe;
import sparkles.profiling.counters.capability : BackendCapabilities, harnessPendingCapabilities;
import sparkles.test_runner.model : Test, TestResult, TestTraits, Thrown;
import sparkles.test_runner.skip : TestSkipped;
import sparkles.profiling.counters.perf : PerfGroup, PerfStats;
import sparkles.profiling.counters.raw : RawEvent, RawGroup, RawStats;
import sparkles.profiling.counters.syscalls : SyscallGroup, SyscallStats;
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

    /// Pinned counting-pass iteration count (`--perf-iters`); `0` follows the
    /// timing pass's count. A pin makes per-pass counter totals — and ops
    /// with a one-time cost amortized inside the counting window —
    /// reproducible across runs by construction.
    uint perfIters = 0;

    /// Iterations bracketed together per counting-pass measurement
    /// (`--perf-batch`); `0` auto-sizes from the timing pass so one bracket
    /// spans about `perfBatchTargetNs`. The bracket itself costs ~2.2 µs (an
    /// ioctl ENABLE/DISABLE pair) and the tier-0 equivalent two `/proc` reads,
    /// so without batching a nanosecond-scale body's counters report the
    /// apparatus rather than the body. Applies to batched rows (a whole body,
    /// a `BenchTiming.batched` case) only — per-call `benchCase` rows must
    /// keep their release interleaved and always use 1.
    uint perfBatch = 0;
}

/// Auto-batching target: one counting-pass bracket spans about this long, so
/// the bracket's own ~2.2 µs sits near 0.2 % of the measured window.
private enum double perfBatchTargetNs = 1_000_000.0;

/// Iterations to bracket together for a body measured at `nsPerIter`. Clamped
/// to `[1, iters]`; `1` (no batching, the original pass) for bodies already at
/// least `perfBatchTargetNs` long, so slow benchmarks are untouched.
private uint perfBatchFor(double nsPerIter, uint iters, in BenchConfig config)
    @safe pure nothrow @nogc
{
    if (config.perfBatch)
        return config.perfBatch < iters ? config.perfBatch : iters;
    if (!(nsPerIter > 0)) // nan/0 → cannot size; keep the unbatched pass
        return 1;
    const wanted = perfBatchTargetNs / nsPerIter;
    if (!(wanted > 1))
        return 1;
    return wanted < iters ? cast(uint) wanted : iters;
}

@("bench.perfBatchFor.sizesAndClamps")
@safe pure nothrow @nogc
unittest
{
    // A 1 ns body wants ~10^6 per bracket, clamped to the pass's iterations.
    assert(perfBatchFor(1.0, 100_000, BenchConfig()) == 100_000);
    // A body already at/over the target never batches (the original pass).
    assert(perfBatchFor(perfBatchTargetNs, 100_000, BenchConfig()) == 1);
    assert(perfBatchFor(2 * perfBatchTargetNs, 100_000, BenchConfig()) == 1);
    // 1 µs → ~1000 iterations per bracket; 10 µs → ~100.
    assert(perfBatchFor(1_000.0, 100_000, BenchConfig()) == 1_000);
    assert(perfBatchFor(10_000.0, 100_000, BenchConfig()) == 100);
    // Pinned, and pins clamp to the iteration count too.
    assert(perfBatchFor(1.0, 100_000, BenchConfig(perfBatch: 64)) == 64);
    assert(perfBatchFor(1.0, 10, BenchConfig(perfBatch: 64)) == 10);
    // Degenerate timings never batch.
    assert(perfBatchFor(0.0, 100, BenchConfig()) == 1);
    assert(perfBatchFor(double.nan, 100, BenchConfig()) == 1);
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
    Nullable!RawStats raw; /// raw hardware events named via `--metrics=raw:…`
    string error; /// non-empty = an error row (a case whose `after` reported failure)
    bool skipped; /// the error is a `skipTest` reason (rendered yellow, run stays green)
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
BenchStats errorRow(string name, string[string] labels, in Thrown[] thrown) @safe
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

/// A `@benchCases` test named `name`, as discovery describes one — for the
/// harness's tests, here and in `bench_case_test` (which a dependent package's
/// test build compiles without this module's `version (unittest)`).
package Test casesTest(string name, void function() body_)
    => Test(fullName: "m." ~ name, name: name, ptr: body_,
        traits: TestTraits(isBenchmark: true, registersCases: true));

version (unittest)
{
    /// An `Expected`-shaped result for the tests: `benchCase` finds a soft
    /// error by the `hasError` and `error` members alone, so the harness's
    /// tests need no repository package (process-model TRP1).
    private struct SoftResult
    {
        string error;
        bool hasError() const @safe pure nothrow @nogc => error.length != 0;
    }

    /// A case that spins `n` times and has nothing to verify.
    private struct Spin
    {
        int n;
        void timed() { foreach (j; 0 .. n) blackBox(j); }
    }
}

@("benchCase.inertPathSurfacesExpectedError")
@system
unittest
{
    import std.exception : assertThrown;

    // Outside --bench (a foreign runner executing the test) a soft `Expected`
    // error from `after` must fail the test, not vanish; teardown still runs.
    static bool teardownRan;
    teardownRan = false;
    static struct Bad
    {
        void timed() {}
        SoftResult after() => SoftResult("mismatch");
        void teardown() { teardownRan = true; }
    }

    assertThrown(benchCase(Bad(), name: "bad"));
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
/// sub-microsecond per-call medians. Shared with the workload window driver.
package(sparkles.test_runner)
long elapsedNs(long startTicks) @safe nothrow @nogc
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
// Registered cases and the runner-side driver
// ─────────────────────────────────────────────────────────────────────────────

/**
One benchmark case, registered by `benchCase` (or a whole body) and measured
later by `measureCase`. Every case is erased to the same shape — a block of
state the case owns and function pointers over it (TRB1) — so a heterogeneous
matrix collapses to a flat list the runner can freely filter, group, sort,
and schedule before executing.

The hooks are `function` pointers, not delegates: a function pointer cannot
close over the registering frame, so nothing a case needs can die with the body
that registered it. `state` is a GC block holding the case (its scanned
references stay alive) and, for a value-returning `timed`, the last result.
*/
struct RegisteredCase
{
    string name;              /// row name (the varying dimension, e.g. an engine)
    string[string] labels;    /// orthogonal dimensions for grouping, e.g. `["dataset": …]`
    Metric[] metrics;         /// throughput / level columns
    void* state;              /// the case's own block, passed to every hook
    void function(void*) setup;    /// untimed, once before measurement (null = none)
    void function(void*) runTimed; /// the measured body (a result is kept in `state`)
    /// Untimed, after each measured call; `null`/`""` = ok, else an error message.
    /// `null` selects batched timing (a batched case or a whole body — no
    /// per-call release).
    string function(void*) runAfter;
    void function(void*) teardown; /// untimed, once after measurement (null = none)
    /// Destroys the case — its destructor runs — at most once, however often it
    /// is called (null = nothing to destroy). Runs after `teardown`, and for a
    /// case never measured when the worker shuts down.
    void function(void*) dispose;
}

/// Destroys every case in `cases` that `measureCase` did not (idempotent).
package(sparkles.test_runner)
void disposeCases(scope RegisteredCase[] cases) @system
{
    foreach (ref c; cases)
        if (c.dispose !is null)
            c.dispose(c.state);
}

/// The three counter sources bundled into one value, so the bench driver threads
/// a single `CounterGroups` instead of three parallel params/pointers/fields (and
/// a matching triple of `Nullable` result fields). Each source is opened
/// independently; one not requested — or unavailable on this machine — contributes
/// no columns. Adding a future source is one field plus one line in each of
/// `open`/`close`/`countInto`/`capabilities`, not a shotgun edit across every
/// call site.
struct CounterGroups
{
    PerfGroup perf;
    Tier0Group tier0;
    SyscallGroup syscalls;
    RawGroup raw;

    /// Opens each requested source: `--perf` (`perfWanted`; `perfScaled`
    /// keeps a multiplexing group and labels its estimates), a selected tier0
    /// metric (`tier0Wanted`), `--syscalls` (`syscallWanted` + `syscallNames`),
    /// and raw events named via `--metrics=raw:…` (`rawEvents`; empty +
    /// `rawWanted` = a permission probe only).
    static CounterGroups open(bool perfWanted, bool tier0Wanted, bool syscallWanted,
        const(string)[] syscallNames, bool rawWanted = false,
        const(RawEvent)[] rawEvents = null, bool perfScaled = false) @safe
    {
        CounterGroups g;
        g.perf = PerfGroup.tryOpen(perfWanted, perfScaled);
        g.tier0 = Tier0Group.tryOpen(tier0Wanted);
        g.syscalls = SyscallGroup.tryOpen(syscallWanted, syscallNames);
        g.raw = RawGroup.tryOpen(rawWanted, rawEvents);
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
        raw.close();
    }

    /// Enables the perf-family groups for window measurement (`@workload`):
    /// counters run from here until `endWindows`, and window edges read them
    /// cumulatively (no per-iteration ioctl bracket; tier-0 is snapshot-only
    /// and needs no arming). See `sparkles.test_runner.workload`.
    void beginWindows() @safe
    {
        perf.enable();
        syscalls.enable();
        raw.enable();
    }

    /// ditto
    void endWindows() @safe
    {
        perf.disable();
        syscalls.disable();
        raw.disable();
    }

    /// Runs each available source's counting pass over `timed`/`between` (the
    /// iteration count capped once) and fills `row`'s perf/tier0/syscall fields.
    void countInto(Timed, Between)(ref BenchStats row, scope Timed timed,
        scope Between between, ulong iterations, in BenchConfig config,
        uint batch = 1)
    {
        const iters = perfIters(iterations, config);
        if (perf.available)
            row.perf = perf.count(timed, between, iters, batch);
        if (tier0.available)
            row.tier0 = tier0.count(timed, between, iters, batch);
        if (syscalls.available)
            row.syscalls = syscalls.count(timed, between, iters, batch);
        // Raw rows attach whenever events were *requested*, not only when one
        // opened: a fully-refused group still yields all-nan stats, so every
        // selected raw column keeps its em-dash presence (the same
        // selected-but-unavailable contract the static families honor).
        if (raw.available || raw.names.length)
            row.raw = raw.count(timed, between, iters, batch);
    }

    /// Every backend's capability report in field order, plus the
    /// harness-level pending block — the one value `--list-metrics` and the
    /// bench header render from. Labels reuse the metric catalog's `source`
    /// vocabulary.
    BackendCapabilities[] capabilities() const @safe nothrow
    {
        import sparkles.test_runner.event_naming : namingCapabilities;

        return [
            BackendCapabilities("perf", perf.capabilities),
            BackendCapabilities("tier0", tier0.capabilities),
            BackendCapabilities("syscall", syscalls.capabilities),
            BackendCapabilities("raw", raw.capabilities),
            BackendCapabilities("pfm", namingCapabilities),
            BackendCapabilities("harness", harnessPendingCapabilities),
        ];
    }
}

@("bench.CounterGroups.capabilities")
@safe
unittest
{
    import sparkles.profiling.counters.capability : Capability, reasonFor;

    const blocks = CounterGroups.none.capabilities;
    assert(blocks.length == 6);
    assert(blocks[0].backend == "perf");
    assert(blocks[1].backend == "tier0");
    assert(blocks[2].backend == "syscall");
    assert(blocks[3].backend == "raw");
    assert(blocks[4].backend == "pfm");
    assert(blocks[5].backend == "harness");
    assert(blocks[5].report.reasonFor(Capability.symbolization) !is null);
    assert(blocks[5].report.reasonFor(Capability.numaAttribution) !is null);
}

private struct BenchContext
{
    BenchConfig config;
    string testName;         /// row name of a whole body and of an unnamed case
    bool registersCases;     /// the body is `@benchCases` (else `@benchmark`)
    RegisteredCase[] cases;  /// registration output (the body's benchCase calls)
    CounterGroups* counters; /// null = no counting passes
}

private BenchContext* activeBenchContext; // thread-local, set during registration

/// Suite-provenance lines registered via `benchProvenance`, in first-seen
/// order. Read by the bench driver for the header and `--bench-json` meta.
package string[] provenanceLines;

/**
 * Records one line of suite provenance — a fact the suite controls that
 * materially shapes the numbers and that a committed baseline must carry to
 * be self-describing: an allocator regime ("glibc malloc trim/mmap
 * thresholds raised to 64 MiB"), a codegen configuration
 * ("codegen: library-inline"), a data-set variant. Keep each line short and
 * declarative.
 *
 * Callable from a `@benchmark` body, a `benchCase` helper, or a suite's
 * `shared static this` (module constructors run on the main thread before
 * the driver). Under `--bench` the lines print once in the run header and
 * land in `--bench-json`'s `meta.provenance`; outside `--bench` the call is
 * inert. Exact duplicates are recorded once.
 */
void benchProvenance(string line) @safe nothrow
{
    import std.algorithm.searching : canFind;

    if (line.length && !provenanceLines.canFind(line))
        provenanceLines ~= line;
}

@("bench.benchProvenance.accumulatesAndDedups")
@safe nothrow
unittest
{
    const before = provenanceLines.length;
    scope (exit)
        provenanceLines = provenanceLines[0 .. before];
    benchProvenance("fact A");
    benchProvenance("fact B");
    benchProvenance("fact A"); // duplicate
    benchProvenance(""); // empty is ignored
    assert(provenanceLines[before .. $] == ["fact A", "fact B"]);
}

/// The counting-pass iteration count for a measurement: the timing's iteration
/// count, capped so a cheap op's huge count does not make the (ioctl-bracketed)
/// counting pass slow.
private uint perfIters(ulong iterations, in BenchConfig config) @safe pure nothrow @nogc
{
    import std.algorithm.comparison : min;

    const wanted = config.perfIters ? config.perfIters : iterations;
    const n = min(wanted, config.perfMaxIters);
    return cast(uint)(n ? n : 1);
}

@("bench.perfIters.pinAndCap")
@safe pure nothrow @nogc
unittest
{
    assert(perfIters(50, BenchConfig()) == 50, "follows the timing count");
    assert(perfIters(1_000_000, BenchConfig()) == 100_000, "capped");
    assert(perfIters(50, BenchConfig(perfIters: 7)) == 7, "pinned");
    assert(perfIters(50, BenchConfig(perfIters: 500_000)) == 100_000,
        "a pin past the cap is capped");
    assert(perfIters(0, BenchConfig()) == 1, "at least one iteration");
}

/// The case a `@benchmark` test is: its own body, measured batched.
private struct WholeBody
{
    void function() body_;
    void timed() { body_(); }
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

/// Times one erased `runTimed` call and runs `runAfter` untimed after it.
private DriveResult driveErased(ref RegisteredCase c) @system
{
    const t0 = MonoTime.currTime.ticks;
    c.runTimed(c.state);
    const ns = elapsedNs(t0);
    return DriveResult(ns, c.runAfter is null ? null : c.runAfter(c.state));
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

/// Enforces `groupKeyOf`'s collision-freedom invariant at registration time:
/// group-key parts are joined with the US control character (`metrics.d`'s
/// `groupKeySep`), which therefore must not appear in a case name or label —
/// throwing here fails the registering `@benchmark` body with a readable
/// message instead of silently merging distinct groups later.
private void validateGroupSafe(string name, in string[string] labels) @safe pure
{
    static bool clean(in char[] s) @safe pure nothrow @nogc
    {
        foreach (ch; s)
            if (ch == '\x1f')
                return false;
        return true;
    }

    if (!clean(name))
        throw new Exception(
            "benchCase name contains the reserved group separator U+001F: " ~ name);
    foreach (k, v; labels)
        if (!clean(k) || !clean(v))
            throw new Exception("benchCase '" ~ name
                ~ "' label contains the reserved group separator U+001F: "
                ~ k ~ "=" ~ v);
}

@("bench.validateGroupSafe")
@safe pure
unittest
{
    import std.exception : assertThrown;

    validateGroupSafe("ok", ["dataset": "x/y"]); // '/' is fine — U+001F is not
    assertThrown(validateGroupSafe("a\x1fb", null));
    assertThrown(validateGroupSafe("ok", ["k": "a\x1fb"]));
    assertThrown(validateGroupSafe("ok", ["a\x1fb": "v"]));
}

/// Whether a value of type `T` can reach a stack frame: `T` is a nested
/// struct, union or class (it carries a hidden frame pointer), or holds a
/// delegate, directly or through a struct, union or static-array field. A
/// bench case must not (TRB2): it runs after the frame that built it returns.
/// Classes and pointers are followed no further — what they point to lives
/// wherever it was allocated, and dip1000 rejects pointing at a local in
/// `@safe` code.
template reachesFrame(T)
{
    import std.traits : Fields, isDelegate;

    static if (isDelegate!T)
        enum reachesFrame = true;
    else static if (is(T == struct) || is(T == union))
        enum reachesFrame = __traits(isNested, T) || anySatisfy!(.reachesFrame, Fields!T);
    else static if (is(T == class))
        enum reachesFrame = __traits(isNested, T);
    else static if (is(T == E[n], E, size_t n))
        enum reachesFrame = .reachesFrame!E;
    else
        enum reachesFrame = false;
}

private alias anySatisfy = imported!"std.meta".anySatisfy;

///
@("bench.reachesFrame")
@safe
unittest
{
    int local;
    struct Nested { int get() => local; }
    static struct Plain { int[4] a; string s; Object o; int* p; }
    static struct HoldsDelegate { int delegate() dg; }
    static struct Deep { HoldsDelegate[2] inner; }

    static assert(!reachesFrame!Plain);
    static assert(reachesFrame!Nested);
    static assert(reachesFrame!HoldsDelegate);
    static assert(reachesFrame!Deep);
    static assert(reachesFrame!(void delegate()));
    static assert(!reachesFrame!(void function()));
}

/// The block a registered case lives in: the case itself, the last result of a
/// value-returning `timed` (handed to `after`), and whether it was destroyed.
private struct CaseCell(C)
{
    C bench;
    static if (!is(CaseResult!C == void))
        CaseResult!C last;
    bool disposed;
}

/// What `C.timed` returns.
private alias CaseResult(C) = typeof(imported!"std.traits".lvalueOf!C.timed());

/// The erased hooks of a case of type `C`: `static` functions over its
/// `CaseCell`, so the apparatus closes over nothing either.
private template CaseHooks(C)
{
    alias Cell = CaseCell!C;
    enum bool hasResult = !is(CaseResult!C == void);

    static if (__traits(hasMember, C, "setup"))
        void setup(void* p) { (cast(Cell*) p).bench.setup(); }

    void runTimed(void* p)
    {
        auto cell = cast(Cell*) p;
        static if (hasResult)
            cell.last = cell.bench.timed();
        else
            cell.bench.timed();
    }

    string runAfter(void* p)
    {
        auto cell = cast(Cell*) p;
        static if (hasResult)
            return runAfterOf(cell.bench, cell.last);
        else
            return runAfterOf(cell.bench);
    }

    static if (__traits(hasMember, C, "teardown"))
        void teardown(void* p) { (cast(Cell*) p).bench.teardown(); }

    void dispose(void* p)
    {
        auto cell = cast(Cell*) p;
        if (cell.disposed)
            return;
        cell.disposed = true;
        destroy(cell.bench);
    }
}

/// Runs `bench.after` on `result` (or with no argument, when that is the
/// signature it has), or nothing without one. A `void` `after` reports failure
/// by throwing; an `Expected` one by its error, returned as text.
private string runAfterOf(C, R...)(ref C bench, ref R result)
if (R.length <= 1)
{
    static if (!__traits(hasMember, C, "after"))
        return null;
    else
    {
        static if (R.length == 1 && __traits(compiles, bench.after(result[0])))
            alias call = () => bench.after(result[0]);
        else
            alias call = () => bench.after();

        static if (is(typeof(call()) == void))
        {
            call();
            return null;
        }
        else
        {
            auto v = call();
            return v.hasError ? errorText(v) : null;
        }
    }
}

/// Moves `bench` into a GC block of its own and erases it into a
/// `RegisteredCase`. `perCall` selects per-call timing (`after` runs between
/// calls, even when `C` has none); otherwise the case is batched.
private RegisteredCase eraseCase(C)(C bench, string name, string[string] labels,
    Metric[] metrics, bool perCall)
{
    import core.lifetime : move;

    alias Hooks = CaseHooks!C;
    auto cell = new CaseCell!C;
    move(bench, cell.bench);

    RegisteredCase c;
    c.name = name;
    c.labels = labels;
    c.metrics = metrics;
    c.state = cell;
    c.runTimed = &Hooks.runTimed;
    if (perCall)
        c.runAfter = &Hooks.runAfter;
    static if (__traits(hasMember, C, "setup"))
        c.setup = &Hooks.setup;
    static if (__traits(hasMember, C, "teardown"))
        c.teardown = &Hooks.teardown;
    c.dispose = &Hooks.dispose;
    return c;
}

/**
Registers one benchmark case inside a `@benchCases` body; call it repeatedly
(over engines × datasets, say) to emit a matrix, one row per call (TRB1–TRB4).

The case is a struct. The runner moves it into memory it owns and calls its
members there, all optional except `timed`:

$(UL
$(LI `setup()` — untimed, once before the case is measured.)
$(LI `timed()` — the measured call. What it returns flows to `after`.)
$(LI `after(ref R result)` or `after()` — untimed, after every measured call,
    to verify and release the result. It reports a failure by throwing or by
    returning an `Expected` error; either way this case becomes an error row and
    the rest of the matrix still runs.)
$(LI `teardown()` — untimed, once after the measurement.)
$(LI `timing` — an `enum` naming the case's $(LREF BenchTiming).)
)

The case's destructor runs after `teardown`, once; a case the run never
measures (a filter excluded it) is destroyed when the worker shuts down. Like
any D struct, a moved-from copy is destroyed too, as `.init`.

Everything the case needs is a field, set by its constructor from the call's
arguments — by value, so each case of a loop has its own. A case type that
could reach the registering frame — a nested (non-`static`) struct, or a
delegate field — is rejected at compile time: the case runs after that frame
has returned (TRB2).

`labels` name orthogonal dimensions of the case (e.g.
`["dataset": "twitter", "operation": "serialize"]`); `--group-by` selects label
keys to group and stream the report by, while `name` stays the varying
dimension shown per row (typically the implementation being compared).
`metrics` attach throughput / level columns.

Outside a `--bench` run the case runs once immediately — `setup`, one `timed`,
`after`, `teardown` — and an `after` error throws, so a plain `dub test` still
checks it.

By default each `timed()` is timed alone, with `after` between calls, so a
result can be released before the next iteration: suited to µs-and-up
operations. A case that declares `enum timing = BenchTiming.batched;` is timed
in back-to-back batches instead (see $(LREF BenchTiming)) — the choice for
nanosecond-scale micro-benchmarks, which a per-call clock read would swamp. A
batched case has no `after`: nothing runs between its calls.

`name` defaults to the test's name — the row a whole-body `@benchmark` would
produce — so a test that times a single operation needs none.
*/
void benchCase(C)(C bench, string name = null, string[string] labels = null,
    Metric[] metrics = null)
if (is(C == struct))
{
    import core.lifetime : move;

    static assert(__traits(hasMember, C, "timed"),
        "benchCase: `" ~ C.stringof ~ "` has no `timed()` to measure");
    static assert(!reachesFrame!C,
        "benchCase: `" ~ C.stringof ~ "` can reach the frame that registers it"
        ~ " (a nested struct, or a delegate field), which is gone when the case runs:"
        ~ " make it a `static struct` and pass what it needs to its constructor");
    static assert(timingOf!C == BenchTiming.perCall || !__traits(hasMember, C, "after"),
        "benchCase: `" ~ C.stringof ~ "` is `BenchTiming.batched`, whose calls run back"
        ~ " to back, so it cannot have an `after`: verify in `teardown`, or time it"
        ~ " per call");
    runOrRegister(move(bench), name, labels, metrics);
}

/**
How a $(LREF benchCase) case's `timed()` calls are timed. A case selects one by
declaring `enum timing = BenchTiming.batched;`; without one it is `perCall`.
*/
enum BenchTiming
{
    /// Each call timed alone, `after` between calls (one call per sample).
    perCall,
    /// Calls run back to back, the count per sample doubled until a sample
    /// takes `BenchConfig.minSampleTime` (libtest's `Bencher`), and the
    /// counting pass brackets many calls at once (`BenchConfig.perfBatch`).
    batched,
}

/// The `BenchTiming` a case type `C` declares (`perCall` when it declares none).
private template timingOf(C)
{
    static if (__traits(hasMember, C, "timing"))
    {
        static assert(is(typeof(C.timing) : BenchTiming),
            "benchCase: `" ~ C.stringof ~ ".timing` must be a `BenchTiming`");
        enum BenchTiming timingOf = C.timing;
    }
    else
        enum BenchTiming timingOf = BenchTiming.perCall;
}

// `benchCase` past its compile-time checks: runs the case now outside `--bench`,
// registers it under one.
private void runOrRegister(C)(C bench, string name, string[string] labels,
    Metric[] metrics)
{
    import core.lifetime : move;

    validateGroupSafe(name, labels);
    auto context = activeBenchContext;
    if (context is null) // outside a --bench run: run once, for correctness
    {
        static if (__traits(hasMember, C, "setup"))
            bench.setup();
        scope (exit)
        {
            static if (__traits(hasMember, C, "teardown"))
                bench.teardown();
        }
        static if (is(CaseResult!C == void))
        {
            bench.timed();
            const error = runAfterOf(bench);
        }
        else
        {
            auto result = bench.timed();
            const error = runAfterOf(bench, result);
        }
        // An `Expected` error from `after` isolates a *row* under --bench;
        // outside --bench there is no table to isolate into, and swallowing
        // it would green a failing verification under a foreign runner.
        if (error.length)
            throw new Exception("benchCase '" ~ name ~ "': " ~ error);
        return;
    }
    if (!context.registersCases)
        throw new Exception("benchCase: `" ~ context.testName ~ "` is a `@benchmark`, whose"
            ~ " body is the measured unit; a body that registers cases is `@benchCases`");
    context.cases ~= eraseCase(move(bench), name is null ? context.testName : name,
        labels, metrics, perCall: timingOf!C == BenchTiming.perCall);
}

/// Measures one registered case into a `BenchStats` row. `setup`/`teardown` bracket
/// the whole measurement (untimed); a `runAfter`-reported soft error or a probe
/// failure yields an error row. `null` `runAfter` selects batched timing (a tight
/// `measure` loop, for a batched case or a whole body); otherwise per-call timing releases
/// the result between calls. A thrown `runTimed`/`runAfter` propagates to the caller.
package(sparkles.test_runner)
BenchStats measureCase(RegisteredCase c, in BenchConfig config,
    ref CounterGroups counters) @system
{
    auto ctx = BenchContext(config: config, counters: &counters);
    return measureCase(&ctx, c);
}

/// ditto
package(sparkles.test_runner)
BenchStats measureCase(BenchContext* context, RegisteredCase c) @system
{
    import std.algorithm.iteration : map;
    import std.array : array;

    // Registered first, so it runs last: the case is destroyed even when its
    // `teardown` throws.
    scope (exit)
        if (c.dispose !is null)
            c.dispose(c.state);
    if (c.setup !is null)
        c.setup(c.state);
    scope (exit)
        if (c.teardown !is null)
            c.teardown(c.state);

    auto runTimed = () { c.runTimed(c.state); };
    if (c.runAfter is null) // batched: a batched case or a whole body
    {
        auto m = measure(runTimed, context.config);
        auto row = computeStats(c.name, m.iterations, m.nsPerIter);
        row.labels = c.labels;
        row.metrics = c.metrics;
        if (context.counters !is null)
        {
            // Batched row (`between` is a no-op), so the counting pass may
            // bracket many iterations at once — without which a fast body's
            // counters are all bracket. Sized from the timing pass we just ran.
            const batch = perfBatchFor(row.nsPerIterMedian,
                perfIters(m.iterations, context.config), context.config);
            context.counters.countInto(row, runTimed, () {}, m.iterations,
                context.config, batch);
        }
        return row;
    }

    // Probe once so an `after` error surfaces before the measurement loop —
    // except under a pinned count, where every call is one of the N samples.
    if (!context.config.iterations)
    {
        const probe = driveErased(c);
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
        const d = driveErased(c);
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
    auto release = () { cast(void) c.runAfter(c.state); };
    if (context.counters !is null)
        context.counters.countInto(row, runTimed, release, samples.length, context.config);
    return row;
}

/// The outcome of one `@benchmark` execution: the rows it emitted (one per
/// `benchCase`, or one for a whole-body benchmark) and the test's
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

/// Runs one benchmark test body to *register* its cases, without measuring
/// them: a `@benchCases` body's `benchCase` calls, or for a `@benchmark` one a
/// single whole-body case named after the test (the body itself is the
/// measured unit). Registration-time throws are caught into `result`.
package(sparkles.test_runner)
Registration registerBenchmark(Test test, in BenchConfig config) @system
{
    import sparkles.test_runner.execution : executeTest, toThrown;

    auto context = BenchContext(config: config, testName: test.name,
        registersCases: test.traits.registersCases);
    activeBenchContext = &context;
    scope (exit)
        activeBenchContext = null;

    auto result = executeTest(test);
    if (result.succeeded && context.cases.length == 0)
    {
        if (context.registersCases)
        {
            // A matrix that came out empty is a bug (a filter, a typo in a
            // loop bound), not a benchmark of the body: say so, unless the
            // body skipped (then `result` already says skipped).
            result.succeeded = false;
            result.thrown = toThrown(
                new Exception("`" ~ test.name ~ "` registered no cases"));
        }
        else // `@benchmark`: the body is the measured unit
            context.cases ~= eraseCase(WholeBody(test.ptr), test.name, null, null,
                perCall: false);
    }
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
    @system
{
    import sparkles.test_runner.execution : toThrown;

    auto reg = registerBenchmark(test, config);
    scope (exit)
        disposeCases(reg.cases); // the ones a failure left unmeasured
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
        catch (TestSkipped s)
        {
            // A measurement-time skip: a yellow skipped row, not a failure.
            outcome.rows ~= BenchStats(name: c.name, labels: c.labels,
                error: errorCell(s.message.idup), skipped: true);
        }
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

@("runBenchmark.batchedCase")
@system
unittest
{
    import core.time : usecs;

    static struct Side
    {
        enum timing = BenchTiming.batched;
        int side;
        void timed() { blackBox(side += 1); }
    }

    static void body_()
    {
        benchCase(Side());
    }

    const config = BenchConfig(iterations: 8, sampleCount: 2, minSampleTime: 1.usecs);
    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(casesTest("bi", &body_), config, counters);
    assert(outcome.result.succeeded);
    assert(outcome.rows[0].name == "bi", "an unnamed case is named after its test");
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
        // 100k multiply-adds: the signal must dwarf the darwin bracket
        // residue — a ~1k body sits below the calibrated proc_pid_rusage
        // syscall cost and intermittently nets (clamps) to exactly 0 there.
        // This test is about the perf CAPTURE plumbing, not precision.
        foreach (i; 0 .. 100_000)
            sink += i * i;
    }

    auto counters = CounterGroups.open(true, false, false, null);
    scope (exit)
        counters.close();
    import sparkles.test_runner.skip : skipTest;

    if (!counters.perf.available) // paranoid/sandboxed kernels refuse
        skipTest(counters.perf.status());

    const config = BenchConfig(iterations: 20, sampleCount: 2, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(Test(fullName: "m.p", name: "p", ptr: &body_), config, counters);
    assert(outcome.result.succeeded);
    assert(!outcome.rows[0].perf.isNull);
    assert(outcome.rows[0].perf.get.instructions > 0);
}

@("benchCase.demo")
@benchCases @safe
unittest
{
    // Dogfoods benchCase: one @benchmark emits a row per size, each with an
    // element-throughput metric. Skipped by default; measured under `--bench`.
    // Each case is a value carrying its own `size`, so the loop needs no helper.
    import std.conv : text;

    static struct Sum
    {
        int size;
        void timed() @safe { size_t s; foreach (i; 0 .. size) s += i; blackBox(s); }
    }

    foreach (size; [64, 256, 1024])
        benchCase(Sum(size), name: text("sum/", size),
            metrics: [Metric(unit: Unit("elem"), amount: double(size), mode: Metric.Mode.rate)]);
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

    () @trusted { blackBox(getpid()); }();
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
            benchCase(Spin(n), name: text("case", i),
                metrics: [Metric(unit: Unit("B"), amount: double(n), mode: Metric.Mode.rate)]);
        }
    }

    auto counters = CounterGroups.none;
    const config = BenchConfig(sampleCount: 2, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(casesTest("mc", &body_), config, counters);
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
    // `@benchmark` registers a single whole-body case.
    static void matrix()
    {
        foreach (i; 0 .. 3)
            benchCase(Spin(i), name: "c");
    }

    static void whole()
    {
        size_t s;
        foreach (i; 0 .. 10)
            s += i;
        blackBox(s);
    }

    assert(registerBenchmark(casesTest("matrix", &matrix),
            BenchConfig()).cases.length == 3);
    auto wb = registerBenchmark(Test(fullName: "m.whole", name: "whole", ptr: &whole), BenchConfig());
    assert(wb.cases.length == 1 && wb.cases[0].name == "whole");
}

@("runBenchmark.onCaseStartPerCase")
@system
unittest
{
    import core.time : usecs;

    static void body_()
    {
        foreach (i; 0 .. 3)
            benchCase(Spin(i), name: "c");
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
    auto outcome = runBenchmark(casesTest("b", &body_),
        config, counters, &rec.tick);
    assert(outcome.result.succeeded);
    assert(rec.n == 3); // exactly one tick per case
}

@("benchCase.expectedErrorIsIsolatedRow")
@system
unittest
{
    import core.time : usecs;

    static struct Yields
    {
        int value;
        int timed() => value;
        SoftResult after(ref int r) => r == 5 ? SoftResult.init : SoftResult("expected 5");
    }

    static void body_()
    {
        // A soft (Expected) failure becomes an error row; the matrix continues.
        benchCase(Yields(3), name: "bad");
        benchCase(Yields(5), name: "good");
    }

    auto counters = CounterGroups.none;
    const config = BenchConfig(sampleCount: 1, minSampleTime: 1.usecs);
    auto outcome = runBenchmark(casesTest("er", &body_), config, counters);
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

    // On this in-process path (`runBenchmark`, a single test measured where it
    // registered) a throwing `after` aborts the whole benchmark test. The
    // runner's worker instead makes it an error row and measures the rest
    // (`benchCase.throwIsAnErrorRowInTheWorker`).
    static struct Boom
    {
        int[] timed() => null;
        void after(ref int[] r) { assert(r.length == 1, "empty result"); }
    }

    static void body_()
    {
        benchCase(Boom(), name: "boom");
    }

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(casesTest("bt", &body_),
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

    static struct Counted
    {
        void setup() { setups++; }
        void timed() { timeds++; blackBox(timeds); }
        void teardown() { teardowns++; }
    }

    static void body_()
    {
        benchCase(Counted(), name: "c");
    }

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(casesTest("st", &body_),
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

    // A soft error yields an error row; teardown still runs (it is scope-guarded),
    // so a scheduled case never leaks its per-case state on the failure path.
    static size_t teardowns;
    teardowns = 0;

    static struct Bad
    {
        void timed() {}
        SoftResult after() => SoftResult("boom");
        void teardown() { teardowns++; }
    }

    static void body_()
    {
        benchCase(Bad(), name: "bad");
    }

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(casesTest("te", &body_),
        BenchConfig(sampleCount: 1, minSampleTime: 1.usecs), counters);
    assert(outcome.result.succeeded);
    assert(outcome.rows.length == 1 && outcome.rows[0].error == "boom");
    assert(teardowns == 1, "teardown runs even when the case errors");
}

@("runBenchmark.skipDuringRegistration")
@system
unittest
{
    import sparkles.test_runner.skip : skipTest;

    // A skipTest at the top of a @benchmark body (the recommended environment
    // guard) marks the whole test skipped: no rows, not failed, and no
    // zero-case whole-body fallback.
    static void body_()
    {
        skipTest("no perf counters on this machine");
        // unreachable
    }

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(Test(fullName: "m.sk", name: "sk", ptr: &body_),
        BenchConfig(), counters);
    assert(outcome.result.skipped && !outcome.result.succeeded);
    assert(outcome.result.skipReason == "no perf counters on this machine");
    assert(outcome.rows.length == 0);
}

@("runBenchmark.skipDuringMeasurement")
@system
unittest
{
    import core.time : usecs;
    import sparkles.test_runner.skip : skipTest;

    // A skipTest inside a case's `timed` skips only that case's row (yellow,
    // run stays green); the other cases still measure.
    static struct Skipper
    {
        void timed() { skipTest("needs root"); }
    }

    static void body_()
    {
        benchCase(Skipper(), name: "skipper");
        benchCase(Spin(1), name: "fine");
    }

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(casesTest("skm", &body_),
        BenchConfig(sampleCount: 1, minSampleTime: 1.usecs), counters);
    assert(outcome.result.succeeded, "a case-level skip does not fail the test");
    assert(outcome.rows.length == 2);
    assert(outcome.rows[0].skipped && outcome.rows[0].error == "needs root");
    assert(!outcome.rows[1].skipped && outcome.rows[1].error.length == 0);
}

@("measureCase.pinnedIterationsPerCall")
@system
unittest
{
    // `@benchmark(iterations: N)` pins a per-call case to exactly N timed calls
    // (one sample each): no probe call, no auto-scaling past the pin.
    static size_t timeds;
    timeds = 0;

    static struct Pinned
    {
        void timed() { timeds++; blackBox(timeds); }
    }

    static void body_()
    {
        benchCase(Pinned(), name: "pinned");
    }

    auto counters = CounterGroups.none;
    auto outcome = runBenchmark(casesTest("pin", &body_),
        BenchConfig(iterations: 7), counters);
    assert(outcome.result.succeeded);
    assert(timeds == 7, "exactly the pinned number of timed calls");
    assert(outcome.rows.length == 1);
    assert(outcome.rows[0].samples == 7);
    assert(outcome.rows[0].iterations == 1, "per-call rows are 1 iteration/sample");
}
