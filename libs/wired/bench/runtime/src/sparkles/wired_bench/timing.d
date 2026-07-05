/**
The measurement loop.

`MonoTime`-based: after `warmup` untimed iterations, the timed body repeats
until both the minimum iteration count and the minimum accumulated time
budget are met. The reported center is the median (robust against scheduler
noise); the minimum is reported alongside as the "best case" bound.
*/
module sparkles.wired_bench.timing;

import core.time : Duration, MonoTime;

import std.algorithm : fold, sort;

import sparkles.wired_bench.config : TimingConfig;

/// Aggregate statistics of one timed op.
struct OpStats
{
    long medianNs;  /// median per-iteration time
    long minNs;     /// fastest iteration
    long meanNs;    /// arithmetic mean
    ulong iters;    /// measured iterations
}

/**
Times `timed` under `cfg`, running `between` untimed after every iteration
(document release, buffer reset). Templated over the callables so safety
attributes infer from what the engine's ops actually do.
*/
OpStats measureOp(Timed, Between)(scope Timed timed, scope Between between,
    in TimingConfig cfg)
if (is(typeof(timed())) && is(typeof(between())))
{
    foreach (_; 0 .. cfg.warmup)
    {
        timed();
        between();
    }

    long[] samples;
    samples.reserve(cfg.minIters);
    long totalNs;
    while (samples.length < cfg.minIters || totalNs < cfg.minTime.total!"nsecs")
    {
        immutable t0 = MonoTime.currTime;
        timed();
        immutable ns = (MonoTime.currTime - t0).total!"nsecs";
        samples ~= ns;
        totalNs += ns;
        between();
    }
    return summarize(samples, totalNs);
}

/// Reduces raw per-iteration samples to `OpStats`.
private OpStats summarize(long[] samples, long totalNs) @safe pure nothrow
in (samples.length > 0)
{
    samples.sort;
    const mid = samples.length / 2;
    const median = samples.length % 2 == 1
        ? samples[mid]
        : (samples[mid - 1] + samples[mid]) / 2;
    return OpStats(median, samples[0], totalNs / samples.length, samples.length);
}

/// Throughput in MB/s (decimal megabytes, the JSON-benchmark convention)
/// of `bytes` processed per `ns` nanoseconds. A sub-tick measurement
/// (`ns == 0`, possible only for degenerate micro-ops) reports infinity.
double mbPerSec(ulong bytes, long ns) @safe pure nothrow @nogc
in (ns >= 0)
{
    return ns > 0 ? (bytes * 1e9) / (ns * 1e6) : double.infinity;
}

@("timing.measureOp.respectsMinIters")
@safe unittest
{
    import core.time : msecs;

    uint calls, betweens;
    const stats = measureOp(() { calls++; }, () { betweens++; },
        TimingConfig(2, 5, 0.msecs));
    assert(stats.iters == 5);
    assert(calls == 7);      // 2 warmup + 5 measured
    assert(betweens == 7);
    assert(stats.minNs <= stats.medianNs);
}

@("timing.summarize.medianOfEven")
@safe pure unittest
{
    const stats = summarize([40, 10, 20, 30], 100);
    assert(stats.medianNs == 25);
    assert(stats.minNs == 10);
    assert(stats.meanNs == 25);
}

@("timing.mbPerSec.conversion")
@safe pure nothrow @nogc unittest
{
    // 1 MB in 1 ms = 1000 MB/s
    assert(mbPerSec(1_000_000, 1_000_000) == 1000.0);
}
