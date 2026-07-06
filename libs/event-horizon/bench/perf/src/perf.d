/**
Hardware performance counters via `perf_event_open(2)` for the event-horizon
benchmarks — the "why" behind the ns/op numbers.

One counter group (cycles leader; instructions, branches, branch-misses,
cache-references, cache-misses, plus the page-fault software event) is opened
once and reused: each benchmark gets a dedicated *counting pass* that brackets
only the timed body with `PERF_EVENT_IOC_ENABLE`/`DISABLE`, so per-iteration
ioctls never pollute the wall-clock medians.

`inherit=true` folds in the counted task's child threads — needed for the
work-stealing pool, which fans out onto worker threads. Counters answer *why*:
IPC, instructions per op, branch/cache-miss rates, and page faults per op (the
allocation / mmap signature — the fiber-stack + ring-setup story the walker
investigation needed). Off Linux, or on kernels that refuse
`perf_event_open` (`perf_event_paranoid`, seccomp), the harness degrades
gracefully — the perf table is simply absent.

Adapted from `libs/wired/bench/runtime/src/sparkles/wired_bench/perf.d`, minus
the wired JSON coupling.
*/
module perf;

import std.math : isNaN;

/// Per-iteration counter averages of one benchmark's counting pass. `nan` =
/// the event could not be opened on this machine.
struct PerfStats
{
    ulong iters;               /// counting-pass iterations
    double cycles = 0;         /// CPU cycles per iteration
    double instructions = 0;   /// retired instructions per iteration
    double branches = 0;       /// branch instructions per iteration
    double branchMisses = 0;   /// mispredicted branches per iteration
    double cacheReferences = 0; /// LLC references per iteration
    double cacheMisses = 0;    /// LLC misses per iteration
    double pageFaults = 0;     /// page faults per iteration
    double scale = 1;          /// counter running/enabled ratio (1 = clean)
    bool userOnly;             /// true = kernel-side counting was refused
}

/// Instructions per cycle.
double ipc(in PerfStats p) @safe pure nothrow @nogc
    => p.cycles > 0 ? p.instructions / p.cycles : double.nan;

/// Branch misprediction rate in percent.
double branchMissPercent(in PerfStats p) @safe pure nothrow @nogc
    => p.branches > 0 ? p.branchMisses / p.branches * 100 : double.nan;

/// Last-level-cache miss rate in percent.
double cacheMissPercent(in PerfStats p) @safe pure nothrow @nogc
    => p.cacheReferences > 0 ? p.cacheMisses / p.cacheReferences * 100 : double.nan;

version (linux)
{
    // Compiled via sourceFiles, so the ImportC module name is the bare stem.
    import perf_events_c : eh_perf_close, eh_perf_disable, eh_perf_enable,
        eh_perf_group, eh_perf_open, eh_perf_read_counters, eh_perf_reset;

    /// The counter group. `tryOpen` once; `count` brackets one benchmark's
    /// timed body per iteration.
    struct PerfGroup
    {
        private eh_perf_group group;
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
                s ~= "; LLC events dropped (would multiplex — NMI watchdog?)";
            return s;
        }

        /**
        Opens the group. `inherit` also counts threads the task spawns (the
        pool workers). A short calibration decides whether the full group (with
        the LLC pair) co-schedules on this machine's free PMCs; a multiplexed
        group only yields rotation-scaled estimates, so the LLC pair is dropped
        rather than reported inaccurately.
        */
        static PerfGroup tryOpen(bool enabled, bool inherit = false) @trusted
        {
            PerfGroup g;
            if (!enabled)
                return g;
            g.opened = eh_perf_open(&g.group, /*with_cache=*/1, inherit) == 0;
            if (!g.opened)
                return g;
            if (g.calibratedScale() < 0.98)
            {
                eh_perf_close(&g.group);
                g.opened = eh_perf_open(&g.group, /*with_cache=*/0, inherit) == 0;
                g.cacheDropped = true;
            }
            return g;
        }

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
                eh_perf_close(&group);
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
            (() @trusted => eh_perf_reset(&group))();
            foreach (_; 0 .. iters)
            {
                (() @trusted => eh_perf_enable(&group))();
                timed();
                (() @trusted => eh_perf_disable(&group))();
                between();
            }

            ulong[7] totals;
            double scale;
            const rc = (() @trusted => eh_perf_read_counters(&group, &totals[0],
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
            s.scale = scale;
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
        static PerfGroup tryOpen(bool, bool inherit = false) @safe pure nothrow @nogc
            => PerfGroup();
        void close() @safe pure nothrow @nogc {}
        PerfStats count(Timed, Between)(scope Timed, scope Between, uint)
        {
            assert(false, "perf counters are Linux-only");
        }
    }
}

private double perIter(ulong total, uint iters) @safe pure nothrow @nogc
    => total == ulong.max ? double.nan : double(total) / iters;

/**
Divides a counting pass's per-iteration averages by `k` — for when the timed
body ran `k` inner ops, so the ~2-ioctl measurement floor (the enable/disable
syscall kernel transitions that fall inside the counting window, a few
thousand instructions) amortizes away and the reported numbers are true
per-op. Essential for sub-microsecond ops; a no-op (`k = 1`) otherwise.
*/
PerfStats perOp(PerfStats s, double k) @safe pure nothrow @nogc
{
    s.cycles /= k;
    s.instructions /= k;
    s.branches /= k;
    s.branchMisses /= k;
    s.cacheReferences /= k;
    s.cacheMisses /= k;
    s.pageFaults /= k;
    return s;
}

// ── table formatting ────────────────────────────────────────────────────────

/// One labelled row for the perf table.
struct PerfRow
{
    string label;
    PerfStats s;
}

/**
Prints the per-benchmark counter table: instructions/op, IPC, branch- and
LLC-miss rates, and page faults/op — the "why" behind the ns/op numbers.
`nan` cells (events unavailable) print as `-`.
*/
void printPerfTable(scope const PerfRow[] rows, string status)
{
    import std.stdio : writefln, writeln;

    writeln();
    writefln("hardware counters (%s):", status);
    writefln("%-16s %12s %6s %10s %8s %8s %9s",
        "benchmark", "instrs/op", "IPC", "cycles/op", "br-miss%", "LLC-miss%", "faults/op");
    foreach (const ref r; rows)
    {
        writefln("%-16s %12s %6s %10s %8s %8s %9s",
            r.label,
            num(r.s.instructions, 0),
            num(r.s.ipc, 2),
            num(r.s.cycles, 0),
            num(r.s.branchMissPercent, 2),
            num(r.s.cacheMissPercent, 2),
            num(r.s.pageFaults, 3));
    }
}

private string num(double v, int dp)
{
    import std.format : format;

    if (v.isNaN)
        return "-";
    return format("%.*f", dp, v);
}
