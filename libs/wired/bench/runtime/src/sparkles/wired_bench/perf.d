/**
Hardware performance counters via `perf_event_open(2)`.

One counter group (cycles leader; instructions, branches, branch-misses,
cache-references, cache-misses, plus the page-fault software event) is
opened once per run and reused: each op gets a dedicated *counting pass*,
separate from the wall-clock measurement, that brackets only the timed body
with `PERF_EVENT_IOC_ENABLE`/`DISABLE` — the per-iteration ioctls therefore
never pollute the reported medians, and `between()` work (document release)
is never counted.

Counters answer *why* engines differ: IPC, cycles and instructions per
input byte, branch/cache miss rates, and page faults per iteration (the
allocation signature). On kernels that refuse `perf_event_open`
(`perf_event_paranoid`, seccomp) — and everywhere off Linux — the harness
degrades gracefully: perf columns are simply absent.
*/
module sparkles.wired_bench.perf;

/// Per-iteration counter averages of one op's counting pass. Values are
/// rounded to 3 decimals (JSON snapshot stability); `nan` = the event
/// could not be opened on this machine.
struct PerfStats
{
    ulong iters;                /// counting-pass iterations
    double cycles = 0;          /// CPU cycles per iteration
    double instructions = 0;    /// retired instructions per iteration
    double branches = 0;        /// branch instructions per iteration
    double branchMisses = 0;    /// mispredicted branches per iteration
    double cacheReferences = 0; /// LLC references per iteration
    double cacheMisses = 0;     /// LLC misses per iteration
    double pageFaults = 0;      /// page faults per iteration
    double scale = 1;           /// counter running/enabled ratio (1 = clean)
    bool userOnly;              /// true = kernel-side counting was refused
}

/// Instructions per cycle.
double ipc(in PerfStats p) @safe pure nothrow @nogc
{
    return p.cycles > 0 ? p.instructions / p.cycles : double.nan;
}

/// Branch misprediction rate in percent.
double branchMissPercent(in PerfStats p) @safe pure nothrow @nogc
{
    return p.branches > 0 ? p.branchMisses / p.branches * 100 : double.nan;
}

/// Last-level-cache miss rate in percent.
double cacheMissPercent(in PerfStats p) @safe pure nothrow @nogc
{
    return p.cacheReferences > 0
        ? p.cacheMisses / p.cacheReferences * 100 : double.nan;
}

version (linux)
{
    // Compiled via cSourcePaths, so the ImportC module name is the bare
    // file stem.
    import perf_events_c : jb_perf_close, jb_perf_disable, jb_perf_enable,
        jb_perf_group, jb_perf_open, jb_perf_read_counters, jb_perf_reset;

    /// The process-wide counter group (Linux). `tryOpen` once per run;
    /// `count` brackets one op's timed body per iteration.
    struct PerfGroup
    {
        private jb_perf_group group;
        private bool opened;
        private bool cacheDropped;

        /// Whether counters are usable on this machine.
        bool available() const @safe pure nothrow @nogc => opened;

        /// Human-readable availability for the report header.
        string status() const @safe pure nothrow
        {
            if (!opened)
                return "unavailable (perf_event_open failed — perf_event_paranoid?)";
            string s = group.user_only ? "user-space only" : "kernel+user";
            if (cacheDropped)
                s ~= "; LLC events dropped (would multiplex — NMI watchdog holds a counter?)";
            return s;
        }

        /// Opens the group unless disabled; failure leaves it unavailable.
        /// A short calibration decides whether the full group (with the LLC
        /// pair) co-schedules on this machine's free PMCs — a multiplexed
        /// group only yields rotation-scaled estimates, so the LLC pair is
        /// dropped rather than reported inaccurately.
        static PerfGroup tryOpen(bool enabled) @trusted
        {
            PerfGroup g;
            if (!enabled)
                return g;
            g.opened = jb_perf_open(&g.group, /*with_cache=*/1) == 0;
            if (!g.opened)
                return g;
            if (g.calibratedScale() < 0.98)
            {
                jb_perf_close(&g.group);
                g.opened = jb_perf_open(&g.group, /*with_cache=*/0) == 0;
                g.cacheDropped = true;
            }
            return g;
        }

        /// The group's running/enabled ratio over a ~2 ms spin.
        private double calibratedScale() @trusted
        {
            import core.time : MonoTime, msecs;

            static ulong sink;
            const stats = count(() {
                const deadline = MonoTime.currTime + 2.msecs;
                while (MonoTime.currTime < deadline)
                    foreach (i; 0 .. 1000)
                        sink += i * i;
            }, () {}, 3);
            return stats.scale;
        }

        void close() @trusted
        {
            if (opened)
            {
                jb_perf_close(&group);
                opened = false;
            }
        }

        /**
        The counting pass: `iters` iterations with only `timed()` inside the
        enabled window; `between()` runs uncounted. Returns per-iteration
        averages.
        */
        PerfStats count(Timed, Between)(scope Timed timed, scope Between between,
            uint iters)
        in (iters > 0)
        {
            (() @trusted => jb_perf_reset(&group))();
            foreach (_; 0 .. iters)
            {
                (() @trusted => jb_perf_enable(&group))();
                timed();
                (() @trusted => jb_perf_disable(&group))();
                between();
            }

            ulong[7] totals;
            double scale;
            const rc = (() @trusted => jb_perf_read_counters(&group, &totals[0],
                &scale))();

            PerfStats s;
            s.iters = iters;
            if (rc != 0)
                return s;
            s.cycles = perIter(totals[0], iters);
            s.instructions = perIter(totals[1], iters);
            s.branches = perIter(totals[2], iters);
            s.branchMisses = perIter(totals[3], iters);
            s.cacheReferences = perIter(totals[4], iters);
            s.cacheMisses = perIter(totals[5], iters);
            s.pageFaults = perIter(totals[6], iters);
            s.scale = round3(scale);
            s.userOnly = group.user_only != 0;
            return s;
        }
    }
}
else
{
    /// Off Linux: a permanently-unavailable stub with the same surface.
    struct PerfGroup
    {
        bool available() const @safe pure nothrow @nogc => false;

        string status() const @safe pure nothrow => "unavailable (not Linux)";

        static PerfGroup tryOpen(bool) @safe pure nothrow @nogc => PerfGroup();

        void close() @safe pure nothrow @nogc
        {
        }

        PerfStats count(Timed, Between)(scope Timed, scope Between, uint)
        {
            assert(false, "perf counters are Linux-only");
        }
    }
}

/// A per-iteration average, rounded; `ulong.max` (event unavailable) → nan.
private double perIter(ulong total, uint iters) @safe pure nothrow @nogc
{
    return total == ulong.max ? double.nan : round3(double(total) / iters);
}

/// Rounded to 3 decimals for short, formatter-stable JSON snapshots.
private double round3(double v) @safe pure nothrow @nogc
{
    import std.math : round;

    return round(v * 1000) / 1000;
}

@("perf.PerfStats.derivedMetrics")
@safe pure nothrow @nogc unittest
{
    import std.math : isClose, isNaN;

    PerfStats p;
    p.cycles = 1000;
    p.instructions = 3500;
    p.branches = 800;
    p.branchMisses = 8;
    p.cacheReferences = 100;
    p.cacheMisses = 25;
    assert(p.ipc.isClose(3.5));
    assert(p.branchMissPercent.isClose(1.0));
    assert(p.cacheMissPercent.isClose(25.0));

    const PerfStats empty;
    assert(empty.ipc.isNaN && empty.branchMissPercent.isNaN);
}

version (linux)
@("perf.PerfGroup.countSmoke")
unittest
{
    auto g = PerfGroup.tryOpen(true);
    scope (exit)
        g.close();
    if (!g.available) // sandboxed kernels may refuse; that is not a failure
        return;

    static ulong sink;
    const stats = g.count(() {
        foreach (i; 0 .. 100_000)
            sink += i * i;
    }, () {}, 3);

    assert(stats.iters == 3);
    // 100k multiply-accumulates cannot run in fewer than 10k instructions.
    assert(stats.instructions > 10_000);
    assert(stats.cycles > 0);
}
