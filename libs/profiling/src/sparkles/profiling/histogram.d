/**
Frame durations counted in logarithmic bins (`PRF5`): 0.1 ms to 1 s, 64 bins a
decade, with an underflow and an overflow bin. Fixed-size and constant-time to
update; a percentile read from it is a bin's geometric middle, within half a
bin's width (±1.8 %) of the exact one. Outside the range a percentile reads as
the extreme seen: the slowest frame for the overflow bin, the fastest for the
underflow one.
*/
module sparkles.profiling.histogram;

import core.time : Duration, dur;
import std.math : floor, log10, pow, sqrt;

/// ditto
struct FrameHistogram
{
    enum binsPerDecade = 64;   ///
    enum decades = 4;          /// 0.1 ms → 1 s
    enum bins = binsPerDecade * decades; /// the in-range bins
    enum double lowUsecs = 100; /// the lowest bin's lower edge

    private uint[bins + 2] counts; // [0] underflow, [bins + 1] overflow
    private ulong total;
    // The extremes seen: what the underflow and overflow bins read as, so a
    // 5 s frame is not reported as 1 s.
    private Duration lowest = Duration.max, highest = Duration.zero;

@safe pure nothrow @nogc:

    /// Counts one duration.
    void add(Duration d)
    {
        ++counts[binOf(d)];
        ++total;
        if (d < lowest)
            lowest = d;
        if (d > highest)
            highest = d;
    }

    /// How many durations it counted.
    ulong count() const => total;

    /**
    The duration below which a fraction `q` (0 to 1) of the counted ones
    fall: the middle of the bin holding the `ceil(q × count)`th smallest.
    Zero when empty.
    */
    Duration percentile(double q) const
    {
        if (total == 0)
            return Duration.zero;
        q = q < 0 ? 0 : q > 1 ? 1 : q;
        ulong rank = cast(ulong)(q * total + 0.999_999);
        if (rank == 0)
            rank = 1;
        ulong seen;
        foreach (i, c; counts)
        {
            seen += c;
            if (seen >= rank)
                return readAs(i);
        }
        return readAs(counts.length - 1);
    }

    /**
    The mean of the slowest fraction `q` of the counted durations, at bin
    middles: what a "1% low" (`q = 0.01`) is the frame rate of. Zero when
    empty.
    */
    Duration meanOfSlowest(double q) const
    {
        if (total == 0 || !(q > 0))
            return Duration.zero;
        q = q > 1 ? 1 : q;
        ulong want = cast(ulong)(q * total + 0.999_999);
        if (want == 0)
            want = 1;
        double sum = 0;
        ulong taken;
        foreach_reverse (i, c; counts)
        {
            if (c == 0)
                continue;
            const take = c < want - taken ? c : want - taken;
            sum += take * usecsOf(readAs(i));
            taken += take;
            if (taken == want)
                break;
        }
        return usecs(sum / taken);
    }

    // What bin `i` reads as: its middle in range; the extreme seen outside.
    private Duration readAs(size_t i) const
        => i == 0 ? lowest : i > bins ? highest : middle(i);

    /// The bin `d` falls in: 0 below 0.1 ms, `bins + 1` at 1 s and over.
    static size_t binOf(Duration d)
    {
        const us = usecsOf(d);
        if (us < lowUsecs)
            return 0;
        const i = cast(long) floor(log10(us / lowUsecs) * binsPerDecade);
        return i >= bins ? bins + 1 : cast(size_t)(i + 1);
    }

    /// The geometric middle of bin `i`.
    static Duration middle(size_t i)
    {
        if (i == 0)
            return usecs(lowUsecs / 2);
        if (i > bins)
            return usecs(lowUsecs * pow(10.0, decades));
        return usecs(sqrt(edge(i - 1) * edge(i)));
    }

    private static double edge(size_t k) => lowUsecs * pow(10.0, cast(double) k / binsPerDecade);
    private static double usecsOf(Duration d) => d.total!"hnsecs" / 10.0;
    private static Duration usecs(double us) => dur!"hnsecs"(cast(long)(us * 10 + 0.5));
}

///
@("profiling.histogram.percentilesWithinABin")
@safe pure nothrow @nogc unittest
{
    import core.time : msecs, usecs;

    FrameHistogram h;
    assert(h.percentile(0.5) == Duration.zero);
    // 1..1000 ms in 1 ms steps: the exact p50 is 500 ms, p95 950, p99 990.
    foreach (ms; 1 .. 1001)
        h.add(ms.msecs);
    assert(h.count == 1000);
    static bool near(Duration got, double exactMs)
        => got.total!"usecs" >= exactMs * 1000 * 0.982 && got.total!"usecs" <= exactMs * 1000 * 1.019;
    assert(near(h.percentile(0.50), 500));
    assert(near(h.percentile(0.95), 950));
    assert(near(h.percentile(0.99), 990));
    // The slowest 1%: 991..1000 ms, of which 1000 ms is the overflow bin,
    // read as the slowest seen.
    assert(near(h.meanOfSlowest(0.01), 995.5));
    assert(h.meanOfSlowest(0) == Duration.zero && h.meanOfSlowest(double.nan) == Duration.zero);
    assert(near(h.meanOfSlowest(2), h.meanOfSlowest(1).total!"usecs" / 1000.0), "q clamps at 1");
    FrameHistogram wide;
    wide.add(5000.msecs);
    wide.add(20.usecs);
    assert(wide.percentile(1) == 5000.msecs, "the overflow bin reads as the slowest seen");
    assert(wide.percentile(0.5) == 20.usecs, "the underflow bin as the fastest");
    assert(FrameHistogram.binOf(50.usecs) == 0);
    assert(FrameHistogram.binOf(100.usecs) == 1);
    assert(FrameHistogram.binOf(2000.msecs) == FrameHistogram.bins + 1);
}
