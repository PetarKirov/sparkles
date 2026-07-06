/**
 * Hardware performance counters via `perf_event_open(2)`, in pure D.
 *
 * One counter group (cycles leader; instructions, branches, branch-misses,
 * cache-references, cache-misses, plus the page-fault software event) is
 * opened once and reused: a benchmark's *counting pass* — separate from the
 * wall-clock measurement — brackets only the timed body with
 * `PERF_EVENT_IOC_ENABLE`/`DISABLE`, so the per-iteration ioctls never pollute
 * the reported timings and any `between()` cleanup is never counted.
 *
 * Counters answer *why* two implementations differ: IPC, cycles and
 * instructions per iteration, branch/cache miss rates, and the page-fault
 * (allocation) signature. On kernels that refuse `perf_event_open`
 * (`perf_event_paranoid`, seccomp) — and everywhere off Linux — this degrades
 * gracefully: `PerfGroup.available` is `false` and callers simply omit the
 * counter columns.
 *
 * The binding is pure D over druntime's `core.sys.linux.perf_event` (which
 * carries the arch-specific syscall numbers, the `perf_event_attr` layout, and
 * a `perf_event_open` wrapper) plus `ioctl`/`read`/`close` — no ImportC, so the
 * module source-includes cleanly into every host package's test build.
 */
module sparkles.test_runner.perf;

import std.math : isNaN;

/// Per-iteration counter averages of one counting pass. A field is `nan` when
/// the event could not be opened on this machine (e.g. the LLC pair was
/// dropped to avoid multiplexing, or the PMU exposes fewer events).
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

@safe pure nothrow @nogc
{
    /// Instructions per cycle.
    double ipc(in PerfStats p) => p.cycles > 0 ? p.instructions / p.cycles : double.nan;

    /// Branch misprediction rate in percent.
    double branchMissPercent(in PerfStats p)
        => p.branches > 0 ? p.branchMisses / p.branches * 100 : double.nan;

    /// Last-level-cache miss rate in percent.
    double cacheMissPercent(in PerfStats p)
        => p.cacheReferences > 0 ? p.cacheMisses / p.cacheReferences * 100 : double.nan;
}

version (linux)
{
    import core.sys.linux.perf_event : perf_event_attr, perf_event_open,
        perf_type_id, perf_hw_id, perf_sw_ids, perf_event_read_format,
        perf_event_ioc_flags, PERF_EVENT_IOC_DISABLE, PERF_EVENT_IOC_ENABLE,
        PERF_EVENT_IOC_RESET;
    import core.sys.posix.sys.ioctl : ioctl;
    import core.sys.posix.unistd : posixClose = close, read;

    /// One counted event. `type`/`config` are `perf_event_attr` field types;
    /// the values come from the `perf_type_id` / `perf_hw_id` / `perf_sw_ids`
    /// scoped enums.
    private struct Event
    {
        uint type;
        ulong config;
    }

    /// The seven counted events, in the order `PerfStats`'s fields expect.
    private static immutable Event[7] events = () {
        with (perf_type_id) with (perf_hw_id) with (perf_sw_ids)
        {
            immutable Event[7] table = [
                Event(type: PERF_TYPE_HARDWARE, config: PERF_COUNT_HW_CPU_CYCLES),
                Event(type: PERF_TYPE_HARDWARE, config: PERF_COUNT_HW_INSTRUCTIONS),
                Event(type: PERF_TYPE_HARDWARE, config: PERF_COUNT_HW_BRANCH_INSTRUCTIONS),
                Event(type: PERF_TYPE_HARDWARE, config: PERF_COUNT_HW_BRANCH_MISSES),
                Event(type: PERF_TYPE_HARDWARE, config: PERF_COUNT_HW_CACHE_REFERENCES),
                Event(type: PERF_TYPE_HARDWARE, config: PERF_COUNT_HW_CACHE_MISSES),
                Event(type: PERF_TYPE_SOFTWARE, config: PERF_COUNT_SW_PAGE_FAULTS),
            ];
            return table;
        }
    }();

    /// Whether event `i` is the last-level-cache pair (references/misses),
    /// dropped when the group would otherwise multiplex off the free PMCs.
    private bool isCacheEvent(size_t i) @safe pure nothrow @nogc
        => events[i].type == perf_type_id.PERF_TYPE_HARDWARE
            && (events[i].config == perf_hw_id.PERF_COUNT_HW_CACHE_REFERENCES
                || events[i].config == perf_hw_id.PERF_COUNT_HW_CACHE_MISSES);

    /// The process-wide counter group (Linux). `tryOpen` once; `count`
    /// brackets one benchmark's timed body per iteration.
    struct PerfGroup
    {
        private int[7] fds = -1;   /// -1 = event unavailable on this machine
        private bool userOnly;     /// true = kernel-side counting was refused
        private int nOpen;
        private bool opened;
        private bool cacheDropped;

        /// Whether counters are usable on this machine.
        bool available() const @safe pure nothrow @nogc => opened;

        /// Human-readable availability, for a report header.
        string status() const @safe pure nothrow
        {
            if (!opened)
                return "unavailable (perf_event_open failed — perf_event_paranoid?)";
            string s = userOnly ? "user-space only" : "kernel+user";
            if (cacheDropped)
                s ~= "; LLC events dropped (would multiplex — NMI watchdog holds a counter?)";
            return s;
        }

        /// Opens the group unless disabled; failure leaves it unavailable.
        /// A short calibration decides whether the full group (with the LLC
        /// pair) co-schedules on this machine's free PMCs — a multiplexed
        /// group yields only rotation-scaled estimates, so the LLC pair is
        /// dropped rather than reported inaccurately.
        static PerfGroup tryOpen(bool enabled) @safe
        {
            PerfGroup g;
            if (!enabled)
                return g;
            g.opened = g.openGroup(withCache: true);
            if (!g.opened)
                return g;
            if (g.calibratedScale() < 0.98)
            {
                g.closeFds();
                g.opened = g.openGroup(withCache: false);
                g.cacheDropped = true;
            }
            return g;
        }

        /// Opens the group with kernel+user counting, falling back to
        /// user-only; `true` when at least the cycles leader opened.
        private bool openGroup(bool withCache) @safe
        {
            fds[] = -1;
            if (tryOpenAt(excludeKernel: false, withCache: withCache))
                return true;
            closeFds();
            if (tryOpenAt(excludeKernel: true, withCache: withCache))
                return true;
            closeFds();
            return false;
        }

        private bool tryOpenAt(bool excludeKernel, bool withCache) @safe
        {
            nOpen = 0;
            userOnly = excludeKernel;
            int leader = -1;
            foreach (i; 0 .. events.length)
            {
                // The LLC pair pushes the group past the free PMCs when the NMI
                // watchdog holds one; drop it when calibration showed
                // multiplexing (values would be rotation-scaled estimates).
                if (!withCache && isCacheEvent(i))
                {
                    fds[i] = -1;
                    continue;
                }

                perf_event_attr attr;
                attr.size = perf_event_attr.sizeof;
                attr.type = events[i].type;
                attr.config = events[i].config;
                attr.disabled = leader < 0;
                attr.exclude_kernel = excludeKernel;
                attr.exclude_hv = 1;
                if (leader < 0)
                    with (perf_event_read_format)
                        attr.read_format = PERF_FORMAT_GROUP
                            | PERF_FORMAT_TOTAL_TIME_ENABLED
                            | PERF_FORMAT_TOTAL_TIME_RUNNING;

                const fd = (() @trusted => cast(int) perf_event_open(
                    hw_event: &attr, pid: 0, cpu: -1, group_fd: leader, flags: 0UL))();
                fds[i] = fd;
                if (fd >= 0)
                {
                    nOpen++;
                    if (leader < 0)
                        leader = fd;
                }
                else if (leader < 0)
                    return false; // no leader — this permission level is a bust
            }
            return true;
        }

        /// The group's running/enabled ratio over a ~2 ms spin.
        private double calibratedScale() @safe
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

        private void closeFds() @safe
        {
            foreach (ref fd; fds)
            {
                if (fd >= 0)
                    (() @trusted => posixClose(fd))();
                fd = -1;
            }
            nOpen = 0;
        }

        void close() @safe
        {
            if (opened)
            {
                closeFds();
                opened = false;
            }
        }

        /**
         * The counting pass: `iters` iterations with only `timed()` inside the
         * enabled window; `between()` runs uncounted. Returns per-iteration
         * averages.
         */
        PerfStats count(Timed, Between)(scope Timed timed, scope Between between,
            uint iters)
        in (iters > 0)
        {
            groupIoctl(PERF_EVENT_IOC_RESET);
            foreach (_; 0 .. iters)
            {
                groupIoctl(PERF_EVENT_IOC_ENABLE);
                timed();
                groupIoctl(PERF_EVENT_IOC_DISABLE);
                between();
            }

            PerfStats s;
            s.iters = iters;

            // read_format group layout: nr, time_enabled, time_running, then
            // one value per opened event in fds order.
            ulong[3 + events.length] buf;
            const want = cast(long)(ulong.sizeof * (3 + nOpen));
            const got = (() @trusted => read(fds[0], buf.ptr, buf.sizeof))();
            if (got < want)
                return s;

            const enabled = buf[1], running = buf[2];
            const ratio = (running > 0 && enabled > 0 && running < enabled)
                ? double(enabled) / double(running) : 1.0;
            s.scale = enabled > 0 ? round3(double(running) / double(enabled)) : 1.0;

            size_t slot;
            double[events.length] perIter;
            foreach (i; 0 .. events.length)
            {
                if (fds[i] < 0)
                {
                    perIter[i] = double.nan;
                    continue;
                }
                perIter[i] = round3(double(buf[3 + slot]) * ratio / iters);
                slot++;
            }
            s.cycles = perIter[0];
            s.instructions = perIter[1];
            s.branches = perIter[2];
            s.branchMisses = perIter[3];
            s.cacheReferences = perIter[4];
            s.cacheMisses = perIter[5];
            s.pageFaults = perIter[6];
            s.userOnly = userOnly;
            return s;
        }

        private void groupIoctl(uint request) @safe
        {
            import core.stdc.config : c_ulong;

            (() @trusted => ioctl(fds[0], cast(c_ulong) request,
                perf_event_ioc_flags.PERF_IOC_FLAG_GROUP))();
        }
    }
}
else
{
    /// Off Linux: a permanently-unavailable stub with the same surface.
    struct PerfGroup
    {
        // A whole-block attribute only for the plain members; `count` is a
        // template, so its attributes are left to infer.
        @safe pure nothrow @nogc
        {
            bool available() const => false;
            string status() const => "unavailable (not Linux)";
            static PerfGroup tryOpen(bool) => PerfGroup();
            void close() {}
        }

        PerfStats count(Timed, Between)(scope Timed, scope Between, uint)
            => assert(false, "perf counters are Linux-only");
    }
}

/// Rounded to 3 decimals so counter columns and any snapshots stay short.
private double round3(double v) @safe pure nothrow @nogc
{
    import std.math : round;

    return round(v * 1000) / 1000;
}

@("perf.PerfStats.derivedMetrics")
@safe pure nothrow @nogc
unittest
{
    import std.math : isClose;

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
@system
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
