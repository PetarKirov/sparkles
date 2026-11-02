/**
A run's frame times as a distribution (`PRF6`–`PRF9`, `PRF14`, `PRF17`): the
mean, the slowest and the variance; the 50th, 95th and 99th percentiles and
the "1% low"; hitches counted against the display's refresh interval and
attributed to what their frames did; and, where frames report when they were
shown, the latency from a frame's start to its display.

Noting a frame is constant-time and allocates nothing; the summary is one line
through any output range, or a plain struct of numbers ($(LREF FrameSummary))
for JSON.
*/
module sparkles.profiling.stats;

import core.time : Duration, dur, msecs;

import sparkles.profiling.frame : FrameFlags, FrameRecord, flagCount, flagName;
import sparkles.profiling.histogram : FrameHistogram;

/// ditto
struct FrameStats
{
    uint frames;       /// frames noted
    Duration total;    /// their time, together
    Duration slowest;  ///
    uint over50ms;     /// frames that took 50 ms or more
    uint over100ms;    /// frames that took 100 ms or more

    /// The refresh interval a hitch is measured against (`PRF7`): 60 Hz until
    /// a caller that knows the display's sets it.
    Duration interval = dur!"hnsecs"(166_667);
    uint hitches;          /// frames over 1.5 intervals
    ulong missedRefreshes; /// the refreshes those frames missed
    uint[flagCount] hitchesWith; /// per flag bit, the hitches whose frame had it (`PRF8`)
    uint hitchesPlain;     /// hitches whose frame had no flag
    /// The frames noted before `interval` took its value: their hitches were
    /// counted against the one before (the 60 Hz default until the display
    /// reports its own), and the summary says so.
    uint intervalFrom;

    uint shownFrames;      /// frames whose display time was known (`PRF14`)
    Duration latencyTotal; ///
    Duration latencyWorst; ///

    FrameHistogram histogram; ///

    private double meanUs = 0, m2 = 0; // Welford, in microseconds

    // The writers are templates: their attributes are inferred, so they come
    // before the label below.
    /**
    `300 frames: mean 3.2 ms, slowest 46.9 ms, 0 over 50 ms, 0 over 100 ms;
    p50 3.1 ms, p95 4.0 ms, p99 9.8 ms, 1% low 98 fps; 2 hitches over 25.0 ms
    (3 refreshes missed: rebuilt 1, first 1)` — and `latency 21.4 ms mean,
    33.0 ms worst` where frames were shown (`PRF9`).
    */
    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;
        import sparkles.base.text : writeInteger;

        static void ms(ref Writer w, Duration d)
        {
            const tenths = (d.total!"usecs" + 50) / 100;
            writeInteger(w, tenths / 10);
            put(w, '.');
            writeInteger(w, tenths % 10);
            put(w, " ms");
        }

        writeInteger(w, frames);
        put(w, frames == 1 ? " frame" : " frames");
        if (frames == 0)
            return;
        put(w, ": mean ");
        ms(w, mean);
        put(w, ", slowest ");
        ms(w, slowest);
        put(w, ", ");
        writeInteger(w, over50ms);
        put(w, " over 50 ms, ");
        writeInteger(w, over100ms);
        put(w, " over 100 ms; p50 ");
        ms(w, p50);
        put(w, ", p95 ");
        ms(w, p95);
        put(w, ", p99 ");
        ms(w, p99);
        put(w, ", 1% low ");
        writeInteger(w, cast(ulong)(onePercentLowFps + 0.5));
        put(w, " fps; ");
        writeInteger(w, hitches);
        put(w, hitches == 1 ? " hitch over " : " hitches over ");
        ms(w, interval * 3 / 2);
        if (intervalFrom)
        {
            put(w, " from frame ");
            writeInteger(w, intervalFrom + 1);
        }
        if (hitches)
        {
            put(w, " (");
            writeInteger(w, missedRefreshes);
            put(w, missedRefreshes == 1 ? " refresh missed" : " refreshes missed");
            bool first = true;
            foreach (bit; 0 .. flagCount)
                if (hitchesWith[bit])
                {
                    put(w, first ? ": " : ", ");
                    first = false;
                    put(w, flagName(bit));
                    put(w, ' ');
                    writeInteger(w, hitchesWith[bit]);
                }
            if (hitchesPlain)
            {
                put(w, first ? ": " : ", ");
                put(w, "plain ");
                writeInteger(w, hitchesPlain);
            }
            put(w, ')');
        }
        if (shownFrames)
        {
            put(w, "; latency ");
            ms(w, meanLatency);
            put(w, " mean, ");
            ms(w, latencyWorst);
            put(w, " worst");
        }
    }

    /// `prettyPrint` writes the same line.
    void writePretty(Writer, Opts)(ref Writer w, in Opts, ushort = 0) const => toString(w);

@safe pure nothrow @nogc:

    /// Notes one frame that took `took`, carrying `flags`.
    void note(Duration took, FrameFlags flags = FrameFlags.none)
    {
        ++frames;
        total += took;
        if (took > slowest)
            slowest = took;
        if (took >= 50.msecs)
            ++over50ms;
        if (took >= 100.msecs)
            ++over100ms;
        histogram.add(took);
        const us = took.total!"hnsecs" / 10.0;
        const delta = us - meanUs;
        meanUs += delta / frames;
        m2 += delta * (us - meanUs);
        if (interval > Duration.zero && took * 2 > interval * 3)
        {
            ++hitches;
            const ticks = interval.total!"hnsecs";
            missedRefreshes += (took.total!"hnsecs" + ticks - 1) / ticks - 1;
            if (flags == FrameFlags.none)
                ++hitchesPlain;
            foreach (bit; 0 .. flagCount)
                if (flags & (1 << bit))
                    ++hitchesWith[bit];
        }
    }

    /// Notes a recorded frame: its CPU time, its flags and, where known, its
    /// latency.
    void note(in FrameRecord r)
    {
        note(r.cpu, r.flags);
        Duration latency;
        if (r.latency(latency))
            noteLatency(latency);
    }

    /**
    Notes the time from a frame's start to its display (`PRF14`), for a frame
    noted before its presentation time arrived — as it is, frames later.
    Note each frame's latency once: through here or a record that has it.
    */
    void noteLatency(Duration latency)
    {
        ++shownFrames;
        latencyTotal += latency;
        if (latency > latencyWorst)
            latencyWorst = latency;
    }

    /**
    Takes the display's reported refresh interval for hitches (`PRF7`,
    `PRF14`), from frames noted next; zero (no prediction) keeps the current
    one. Returns whether the interval changed.
    */
    bool noteRefresh(Duration refresh)
    {
        // Within 1 % is the same display: 16.666666 ms is the 60 Hz default.
        const delta = refresh > interval ? refresh - interval : interval - refresh;
        if (refresh <= Duration.zero || delta * 100 <= interval)
            return false;
        interval = refresh;
        intervalFrom = frames;
        return true;
    }

    /// The mean frame; zero before the first.
    Duration mean() const => frames ? total / frames : Duration.zero;

    /// The frame times' variance, in square milliseconds.
    double varianceMs2() const => frames > 1 ? m2 / (frames - 1) / 1e6 : 0;

    /// The 50th, 95th and 99th percentiles (`PRF6`).
    Duration p50() const => histogram.percentile(0.50);
    Duration p95() const => histogram.percentile(0.95); /// ditto
    Duration p99() const => histogram.percentile(0.99); /// ditto

    /// The "1% low": the frame rate of the mean of the slowest 1% of frames.
    double onePercentLowFps() const
    {
        const slow = histogram.meanOfSlowest(0.01);
        return slow > Duration.zero ? 1e7 / slow.total!"hnsecs" : 0;
    }

    /// The mean time from a frame's start to its display; zero when unknown.
    Duration meanLatency() const => shownFrames ? latencyTotal / shownFrames : Duration.zero;

    /// The numbers, for JSON (`PRF17`).
    FrameSummary summary() const
    {
        static double ms(Duration d) => d.total!"hnsecs" / 1e4;
        import std.math : sqrt;

        FrameSummary s = {
            frames: frames, meanMs: ms(mean), slowestMs: ms(slowest),
            stddevMs: sqrt(varianceMs2), p50Ms: ms(p50), p95Ms: ms(p95), p99Ms: ms(p99),
            onePercentLowFps: onePercentLowFps, over50ms: over50ms, over100ms: over100ms,
            refreshMs: ms(interval), hitches: hitches, missedRefreshes: missedRefreshes,
            hitchesRebuilt: hitchesWith[0], hitchesCompiled: hitchesWith[4],
            hitchesFirstFrame: hitchesWith[6], hitchesPlain: hitchesPlain,
            shownFrames: shownFrames, meanLatencyMs: ms(meanLatency),
            worstLatencyMs: ms(latencyWorst),
        };
        return s;
    }

}

/// A run's statistics as plain numbers, for `sparkles:wired` (`PRF17`).
struct FrameSummary
{
    uint frames;               ///
    double meanMs = 0;         ///
    double slowestMs = 0;      ///
    double stddevMs = 0;       ///
    double p50Ms = 0;          ///
    double p95Ms = 0;          ///
    double p99Ms = 0;          ///
    double onePercentLowFps = 0; ///
    uint over50ms;             ///
    uint over100ms;            ///
    double refreshMs = 0;      ///
    uint hitches;              ///
    ulong missedRefreshes;     ///
    uint hitchesRebuilt;       ///
    uint hitchesCompiled;      ///
    uint hitchesFirstFrame;    ///
    uint hitchesPlain;         ///
    uint shownFrames;          ///
    double meanLatencyMs = 0;  ///
    double worstLatencyMs = 0; ///
}

///
@("profiling.stats.notesAndWrites")
@safe pure nothrow @nogc unittest
{
    import core.time : usecs;
    import sparkles.base.buffer : checkToString;

    FrameStats s;
    checkToString(s, "0 frames");
    s.note(2.msecs);
    s.note(4.msecs);
    s.note(120.msecs, cast(FrameFlags)(FrameFlags.rebuilt | FrameFlags.firstFrame));
    assert(s.frames == 3 && s.slowest == 120.msecs && s.over50ms == 1 && s.over100ms == 1);
    assert(s.mean == 42.msecs);
    // 120 ms at 60 Hz: a hitch that missed 7 refreshes (8 intervals, the
    // frame's own one aside).
    assert(s.hitches == 1 && s.missedRefreshes == 7 && s.hitchesWith[0] == 1);
    checkToString(s, "3 frames: mean 42.0 ms, slowest 120.0 ms, 1 over 50 ms, 1 over 100 ms; "
        ~ "p50 4.0 ms, p95 121.9 ms, p99 121.9 ms, 1% low 8 fps; 1 hitch over 25.0 ms "
        ~ "(7 refreshes missed: rebuilt 1, first 1)");
}

@("profiling.stats.hitchesFollowTheRefresh")
@safe pure nothrow @nogc unittest
{
    FrameStats s;
    s.interval = dur!"hnsecs"(83_333); // 120 Hz
    s.note(10.msecs);  // under 1.5 intervals (12.5 ms)
    s.note(13.msecs);  // a hitch: one refresh missed
    s.note(30.msecs, FrameFlags.pipelineCompiled); // three missed
    assert(s.hitches == 2 && s.missedRefreshes == 1 + 3);
    assert(s.hitchesPlain == 1 && s.hitchesWith[4] == 1);
    const sum = s.summary;
    assert(sum.hitchesCompiled == 1 && sum.frames == 3 && sum.refreshMs > 8.3 && sum.refreshMs < 8.4);
}

@("profiling.stats.varianceAndLatency")
@safe pure nothrow @nogc unittest
{
    FrameStats s;
    foreach (i; 0 .. 1000)
        s.note(i % 2 ? 4.msecs : 6.msecs);
    assert(s.mean == 5.msecs);
    assert(s.varianceMs2 > 1.0 && s.varianceMs2 < 1.002, "a population of ±1 ms");
    assert(s.onePercentLowFps > 160 && s.onePercentLowFps < 170);

    FrameRecord r;
    r.cpu = 5.msecs;
    r.start = 100.msecs;
    r.shown = 120.msecs;
    r.shownKnown = true;
    s.note(r);
    assert(s.shownFrames == 1 && s.meanLatency == 20.msecs && s.latencyWorst == 20.msecs);
}

@("profiling.stats.summaryRoundTripsThroughJson")
@safe unittest
{
    import sparkles.wired.json : fromJSON, toJSON;

    FrameStats s;
    s.note(4.msecs);
    s.note(40.msecs, FrameFlags.rebuilt);
    const summary = s.summary;
    auto json = toJSON(summary);
    assert(json.hasValue);
    auto back = fromJSON!FrameSummary(json.value[]);
    assert(back.hasValue);
    assert(back.value == summary, "every field survives");
}

@("profiling.stats.lateLatencyAndTheReportedRefresh")
@safe pure nothrow @nogc unittest
{
    FrameStats s;
    s.note(10.msecs);
    s.noteLatency(30.msecs);
    s.noteLatency(40.msecs);
    assert(s.shownFrames == 2 && s.meanLatency == 35.msecs && s.latencyWorst == 40.msecs);

    // A 120 Hz display: 10 ms is a hitch now, not at 60 Hz.
    assert(!s.noteRefresh(Duration.zero) && !s.noteRefresh(s.interval));
    assert(!s.noteRefresh(dur!"nsecs"(16_666_666)), "the 60 Hz default, rounded");
    assert(s.noteRefresh(dur!"nsecs"(8_333_333)));
    s.note(13.msecs);
    assert(s.hitches == 1 && s.missedRefreshes == 1);
    import sparkles.base.buffer : checkToString;
    checkToString(s, "2 frames: mean 11.5 ms, slowest 13.0 ms, 0 over 50 ms, 0 over 100 ms; "
        ~ "p50 10.2 ms, p95 13.1 ms, p99 13.1 ms, 1% low 76 fps; 1 hitch over 12.5 ms from frame 2 "
        ~ "(1 refresh missed: plain 1); latency 35.0 ms mean, 40.0 ms worst");
}
