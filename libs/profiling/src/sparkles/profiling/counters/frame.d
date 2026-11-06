/**
The frame thread's hardware counters, per frame (`PRF23`): the same perf
group a benchmark's counting pass reads (`sparkles.profiling.counters.perf`),
read at each frame's edges and summarized over the run — instructions and
cycles a frame, IPC, branch and cache miss rates, and page faults, which say
whether a frame allocates.

The group counts the thread that opened it, so the frame loop opens it. Where
the kernel refuses counters (`perf_event_paranoid`, an Android app's
sandbox), `FrameCounters.available` is false and its summary says why.
*/
module sparkles.profiling.counters.frame;

import sparkles.profiling.counters.perf : PerfGroup, PerfSnapshot, PerfStats;

/// The counters at a frame's edges, and their summary.
struct FrameCounters
{
    private PerfGroup group;
    private PerfSnapshot started;
    private bool open;

    /// The summary: means over the frames read.
    FrameCounterStats stats;

    /// Opens the calling thread's counter group, enabled. False if refused.
    bool start() @safe
    {
        group = PerfGroup.tryOpen(true);
        open = group.available;
        if (open)
            group.enable();
        stats.status = open ? null : group.status;
        return open;
    }

    /// Whether counters are being read.
    bool available() const @safe pure nothrow @nogc => open;

    /// Marks a frame's start.
    void beginFrame() @safe
    {
        if (open)
            started = group.snapshot();
    }

    /// Reads the frame since `beginFrame` into the summary, if `keep`.
    void endFrame(bool keep = true) @safe
    {
        if (!open)
            return;
        const s = group.windowStats(started, group.snapshot());
        if (keep)
            stats.note(s);
    }

    /// Closes the group.
    void stop() @safe
    {
        if (open)
            group.close();
        open = false;
    }
}

/// ditto
struct FrameCounterStats
{
    uint frames;            /// frames read
    double instructions = 0; /// summed
    double cycles = 0;       /// ditto
    double branches = 0;     /// ditto
    double branchMisses = 0; /// ditto
    double cacheReferences = 0; /// ditto
    double cacheMisses = 0;  /// ditto
    double pageFaults = 0;   /// ditto
    double worstPageFaults = 0; /// in one frame
    uint faultingFrames;     /// frames with a page fault
    string status;           /// why there are none, where refused

    /// Notes one frame's counters; a `nan` (an event this machine lacks) adds
    /// nothing.
    void note(in PerfStats s) @safe pure nothrow @nogc
    {
        import std.math : isNaN;

        static void add(ref double sum, double v) { if (!isNaN(v)) sum += v; }
        ++frames;
        add(instructions, s.instructions);
        add(cycles, s.cycles);
        add(branches, s.branches);
        add(branchMisses, s.branchMisses);
        add(cacheReferences, s.cacheReferences);
        add(cacheMisses, s.cacheMisses);
        if (!isNaN(s.pageFaults))
        {
            pageFaults += s.pageFaults;
            if (s.pageFaults > worstPageFaults)
                worstPageFaults = s.pageFaults;
            if (s.pageFaults > 0)
                ++faultingFrames;
        }
    }

    /**
    `300 frames: 12.3 M instructions, 9.1 M cycles a frame (IPC 1.35);
    branch misses 1.2 %, LLC misses 8.0 %; page faults 0.4 a frame, 12 at
    most, in 7 frames`.
    */
    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;
        import sparkles.base.text : writeInteger;

        static void fixed(ref Writer w, double v, uint digits)
        {
            ulong scale = 1;
            foreach (_; 0 .. digits)
                scale *= 10;
            const n = cast(ulong)(v * scale + 0.5);
            writeInteger(w, n / scale);
            if (digits)
            {
                put(w, '.');
                auto frac = n % scale;
                for (ulong d = scale / 10; d > 1 && frac < d; d /= 10)
                    put(w, '0');
                writeInteger(w, frac);
            }
        }

        static void millions(ref Writer w, double v)
        {
            fixed(w, v / 1e6, 2);
            put(w, " M");
        }

        if (frames == 0)
        {
            put(w, "no counters");
            if (status.length)
            {
                put(w, " (");
                put(w, status);
                put(w, ')');
            }
            return;
        }
        writeInteger(w, frames);
        put(w, frames == 1 ? " frame: " : " frames: ");
        millions(w, instructions / frames);
        put(w, " instructions, ");
        millions(w, cycles / frames);
        put(w, " cycles a frame");
        if (cycles > 0)
        {
            put(w, " (IPC ");
            fixed(w, instructions / cycles, 2);
            put(w, ')');
        }
        if (branches > 0 || cacheReferences > 0)
        {
            put(w, ";");
            if (branches > 0)
            {
                put(w, " branch misses ");
                fixed(w, branchMisses / branches * 100, 1);
                put(w, " %");
            }
            if (cacheReferences > 0)
            {
                put(w, branches > 0 ? ", LLC misses " : " LLC misses ");
                fixed(w, cacheMisses / cacheReferences * 100, 1);
                put(w, " %");
            }
        }
        put(w, "; page faults ");
        fixed(w, pageFaults / frames, 1);
        put(w, " a frame, ");
        writeInteger(w, cast(ulong) worstPageFaults);
        put(w, " at most, in ");
        writeInteger(w, faultingFrames);
        put(w, faultingFrames == 1 ? " frame" : " frames");
    }
}

///
@("profiling.counters.frame.summarizesFrames")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : checkWriter;

    FrameCounterStats s;
    checkWriter!((ref b) => s.toString(b))("no counters");
    s.status = "perf_event_paranoid=3";
    checkWriter!((ref b) => s.toString(b))("no counters (perf_event_paranoid=3)");

    PerfStats a = { iters: 1, cycles: 8e6, instructions: 10e6, branches: 1e6, branchMisses: 1e4,
        cacheReferences: 1e5, cacheMisses: 8e3, pageFaults: 0 };
    PerfStats b = a;
    b.pageFaults = 12;
    b.cacheReferences = b.cacheMisses = double.nan; // dropped from the group
    s.note(a);
    s.note(b);
    checkWriter!((ref b) => s.toString(b))("2 frames: 10.00 M instructions, 8.00 M cycles a frame "
        ~ "(IPC 1.25); branch misses 1.0 %, LLC misses 8.0 %; page faults 6.0 a frame, "
        ~ "12 at most, in 1 frame");
}

@("profiling.counters.frame.readsThisThread")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    FrameCounters c;
    if (!c.start())
        skipTest("hardware counters unavailable: " ~ c.stats.status);
    scope (exit)
        c.stop();
    foreach (frame; 0 .. 3)
    {
        c.beginFrame();
        ulong x = 1;
        foreach (i; 0 .. 100_000)
            x = x * 6_364_136_223_846_793_005UL + i;
        assert(x != 0);
        c.endFrame();
    }
    assert(c.stats.frames == 3);
    assert(c.stats.instructions / 3 > 100_000, "each frame ran at least its loop's instructions");
}
