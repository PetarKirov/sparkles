/**
Command-line configuration for the wired runtime JSON benchmark.

The option set mirrors the conventions of `compile-time-bench.d`: short + long
names via `@CliOption`, comma-separated list filters, and a `--json` dump for
before/after comparison.
*/
module sparkles.wired_bench.config;

import core.time : Duration, msecs;

import std.algorithm : canFind, map, splitter;
import std.array : array;

import sparkles.core_cli.args : CliOption;

/// Command-line configuration, parsed by `sparkles:core-cli`.
struct BenchOptions
{
    @CliOption("d|data-dir", "Directory with the benchmark corpora (default: $WIRED_BENCH_DATA)")
    string dataDir;

    @CliOption("D|datasets", "Comma-separated dataset names (default all)")
    string datasets = "twitter,citm_catalog,canada,github_events";

    @CliOption("e|engines", "Comma-separated engine name filter (default: all)")
    string engines;

    @CliOption("o|ops", "Comma-separated ops: parse,insitu,serialize,validate,decode (default all)")
    string ops = "parse,insitu,serialize,validate,decode";

    @CliOption("w|warmup", "Warmup iterations per op")
    uint warmup = 3;

    @CliOption("i|min-iters", "Minimum measured iterations per op")
    uint minIters = 10;

    @CliOption("t|min-time-ms", "Minimum measured time budget per op, in milliseconds")
    uint minTimeMs = 2000;

    @CliOption("j|json", "Dump the report as JSON to this file")
    string json;

    @CliOption("skip-verify", "Skip cross-engine fingerprint verification (debug only)")
    bool skipVerify;

    @CliOption("no-perf", "Skip the hardware-counter pass (perf_event_open)")
    bool noPerf;

    @CliOption("perf-iters", "Iterations of each op's counting pass")
    uint perfIters = 20;

    /// Whether `name` passes the `--engines` filter (empty filter = all).
    bool engineEnabled(string name) const @safe pure
    {
        return engines.length == 0 || engines.splitter(',').canFind(name);
    }

    /// Whether `op` passes the `--ops` filter.
    bool opEnabled(string op) const @safe pure
    {
        return ops.splitter(',').canFind(op);
    }

    /// The dataset names selected by `--datasets`.
    string[] datasetNames() const @safe pure
    {
        return datasets.splitter(',').map!(n => n.idup).array;
    }

    /// The measured-iteration policy derived from the options.
    TimingConfig timing() const @safe pure
    {
        return TimingConfig(warmup, minIters, minTimeMs.msecs);
    }
}

/// The warmup/repeat policy of one timed op.
struct TimingConfig
{
    uint warmup;      /// untimed iterations before measuring
    uint minIters;    /// at least this many measured iterations
    Duration minTime; /// and at least this much accumulated measured time
}

@("BenchOptions.engineEnabled.filter")
@safe pure unittest
{
    BenchOptions opts;
    assert(opts.engineEnabled("std.json"));
    opts.engines = "std.json,yyjson";
    assert(opts.engineEnabled("yyjson"));
    assert(!opts.engineEnabled("mir-ion"));
}

@("BenchOptions.opEnabled.filter")
@safe pure unittest
{
    BenchOptions opts;
    assert(opts.opEnabled("parse") && opts.opEnabled("decode"));
    opts.ops = "parse";
    assert(!opts.opEnabled("serialize"));
}
