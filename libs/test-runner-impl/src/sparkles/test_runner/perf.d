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

import sparkles.test_runner.capability : Capability, CapabilityAbsence,
    CapabilityReport, has, hasNamedColumns, hasSnapshot, isCounterBackend,
    probeMaxPrecise, probePmuType, reasonFor;

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
        perf_type_id, perf_hw_id, perf_sw_ids, perf_event_read_format;
    import core.sys.posix.unistd : posixClose = close;

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
        private bool requested;
        private bool opened;
        private bool cacheDropped;
        private bool neverScheduled; /// calibration saw zero PMU time even reduced

        /// Whether counters are usable on this machine.
        bool available() const @safe pure nothrow @nogc => opened;

        /// The bare reason counting is unavailable — single-sourced between
        /// `status()` and `capabilities()` so the two never diverge.
        private string countingAbsence() const @safe pure nothrow @nogc
        {
            if (!requested)
                return "not requested";
            if (neverScheduled)
                return "PMU busy — the group never got scheduled";
            return "perf_event_open failed — perf_event_paranoid?";
        }

        /// Human-readable availability, for a report header.
        string status() const @safe pure nothrow
        {
            if (!opened)
                return "unavailable (" ~ countingAbsence() ~ ")";
            string s = userOnly ? "user-space only" : "kernel+user";
            if (cacheDropped)
                s ~= "; LLC events dropped (would multiplex — NMI watchdog holds a counter?)";
            return s;
        }

        /// Why precise-memory sampling is absent: the flag stays off until a
        /// backend delivers it (B5), but the reason carries the host finding.
        private static string preciseMemoryAbsence() @safe nothrow @nogc
        {
            if (probePmuType("ibs_op") >= 0)
                return "hardware present (ibs_op PMU) — data-source sampling lands in B5";
            if (probeMaxPrecise() > 0)
                return "hardware present (PEBS, cpu/caps/max_precise > 0) — data-source sampling lands in B5";
            return "no precise-sampling PMU (no ibs_op; cpu/caps/max_precise = 0)";
        }

        /// What this backend can deliver on this host, this run (SPEC §6.2):
        /// scalar counting when the group opened, and a reasoned absence for
        /// every perf-domain capability a later milestone delivers.
        CapabilityReport capabilities() const @safe nothrow
        {
            Capability present;
            CapabilityAbsence[] absences;
            if (opened)
                present |= Capability.counting;
            else
                absences ~= CapabilityAbsence(Capability.counting, countingAbsence());
            absences ~= CapabilityAbsence(Capability.countingScaled,
                "labeled multiplexed estimates land in B2 (groups shrink to exact today)");
            absences ~= CapabilityAbsence(Capability.selfMonitoring,
                "user-space counter reads (rdpmc) land in B2");
            absences ~= CapabilityAbsence(Capability.ipSampling,
                "overflow/IP sampling lands in B6");
            absences ~= CapabilityAbsence(Capability.preciseMemory, preciseMemoryAbsence());
            absences ~= CapabilityAbsence(Capability.eventNaming,
                "event-name tables (libpfm4) land in B2");
            return CapabilityReport(present, absences);
        }

        /// Opens the group unless disabled; failure leaves it unavailable.
        /// A short calibration decides whether the full group (with the LLC
        /// pair) co-schedules on this machine's free PMCs — a multiplexed
        /// group yields only rotation-scaled estimates, so the LLC pair is
        /// dropped rather than reported inaccurately.
        static PerfGroup tryOpen(bool enabled) @safe
        {
            PerfGroup g;
            g.requested = enabled;
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
                // The drop bets the multiplexing on the LLC pair; when even the
                // reduced group gets zero PMU time (vPMU limits, pinned events
                // hogging every counter), a pass reads the kernel's
                // `<not counted>` zeros — report unavailable instead.
                if (g.opened && g.calibratedScale() == 0)
                {
                    g.closeFds();
                    g.opened = false;
                    g.neverScheduled = true;
                }
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
            import sparkles.test_runner.perf_group : bracketCountingPass, readScaledGroup;

            const base = bracketCountingPass(fds[0], timed, between, iters);

            PerfStats s;
            s.iters = iters;
            s.userOnly = userOnly;

            // Group read: one scaled per-iteration value per opened counter, in
            // fds order. A short read → counters unavailable (nan → em dash).
            double[events.length] values;
            if (!readScaledGroup(fds[0], nOpen, iters, s.scale, values[], base))
            {
                s.cycles = s.instructions = s.branches = s.branchMisses
                    = s.cacheReferences = s.cacheMisses = s.pageFaults = double.nan;
                return s;
            }

            // Map opened-counter slots back to the fixed fields; a dropped event
            // (e.g. the LLC pair under multiplexing) reads nan.
            size_t slot;
            double[events.length] perIter;
            foreach (i; 0 .. events.length)
                perIter[i] = fds[i] < 0 ? double.nan : values[slot++];
            s.cycles = perIter[0];
            s.instructions = perIter[1];
            s.branches = perIter[2];
            s.branchMisses = perIter[3];
            s.cacheReferences = perIter[4];
            s.cacheMisses = perIter[5];
            s.pageFaults = perIter[6];
            return s;
        }
    }
}
else
{
    /// Off Linux: a permanently-unavailable stub with the same surface.
    struct PerfGroup
    {
        private static immutable CapabilityAbsence[1] stubAbsence = [
            CapabilityAbsence(Capability.counting, "not Linux"),
        ];

        // A whole-block attribute only for the plain members; `count` is a
        // template, so its attributes are left to infer.
        @safe pure nothrow @nogc
        {
            bool available() const => false;
            string status() const => "unavailable (not Linux)";
            CapabilityReport capabilities() const
                => CapabilityReport(Capability.none, stubAbsence[]);
            static PerfGroup tryOpen(bool) => PerfGroup();
            void close() {}
        }

        PerfStats count(Timed, Between)(scope Timed, scope Between, uint)
            => assert(false, "perf counters are Linux-only");
    }
}

// Whichever body the platform built (real or stub) satisfies the backend
// contract; the seam's compile-time tripwire.
static assert(isCounterBackend!PerfGroup);
static assert(!hasSnapshot!PerfGroup && !hasNamedColumns!PerfGroup);

@("perf.PerfGroup.capabilities.notRequested")
@safe
unittest
{
    auto g = PerfGroup.tryOpen(false);
    const r = g.capabilities;
    assert(!r.has(Capability.counting));
    version (linux)
        assert(r.reasonFor(Capability.counting) == "not requested");
    else
        assert(r.reasonFor(Capability.counting) == "not Linux");
}

version (linux)
{
    @("perf.PerfGroup.capabilities.opened")
    @system
    unittest
    {
        import sparkles.test_runner.skip : skipTest;

        auto g = PerfGroup.tryOpen(true);
        scope (exit)
            g.close();
        if (!g.available)
            skipTest(g.status());
        const r = g.capabilities;
        assert(r.has(Capability.counting));
        assert(r.reasonFor(Capability.counting) is null);
        assert(r.reasonFor(Capability.preciseMemory) !is null,
            "the perf domain always explains the precise-memory gap");
        assert(r.reasonFor(Capability.countingScaled) !is null);
    }

    @("perf.PerfGroup.status.byteIdentity")
    @safe pure nothrow
    unittest
    {
        // The exact pre-capability-seam strings, byte for byte.
        PerfGroup g;
        g.requested = true;
        assert(g.status == "unavailable (perf_event_open failed — perf_event_paranoid?)");
        g.neverScheduled = true;
        assert(g.status == "unavailable (PMU busy — the group never got scheduled)");
        g.neverScheduled = false;
        g.opened = true;
        assert(g.status == "kernel+user");
        g.userOnly = true;
        assert(g.status == "user-space only");
        g.cacheDropped = true;
        assert(g.status == "user-space only; LLC events dropped (would multiplex — NMI watchdog holds a counter?)");
    }
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
    import sparkles.test_runner.skip : skipTest;

    if (!g.available) // sandboxed kernels may refuse
        skipTest("hardware counters unavailable (perf_event_paranoid?)");

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

@("perf.PerfGroup.usableAfterThrowingPass")
@system
unittest
{
    // A timed body that throws escapes the ENABLE/DISABLE bracket; the
    // scope(failure) guard must leave the shared group disabled and the throw
    // must propagate (the streaming runner turns it into an error row), with
    // the group still measuring correctly on the next pass.
    auto g = PerfGroup.tryOpen(true);
    scope (exit)
        g.close();
    import sparkles.test_runner.skip : skipTest;

    if (!g.available)
        skipTest("hardware counters unavailable (perf_event_paranoid?)");

    static ulong sink;
    bool threw;
    try
        g.count(() { sink++; throw new Exception("boom"); }, () {}, 3);
    catch (Exception)
        threw = true;
    assert(threw, "the throw propagates out of the counting pass");

    const stats = g.count(() {
        foreach (i; 0 .. 100_000)
            sink += i * i;
    }, () {}, 3);
    import std.math : isNaN;

    if (!stats.instructions.isNaN)
        assert(stats.instructions > 10_000, "the group still measures after a throw");
}
