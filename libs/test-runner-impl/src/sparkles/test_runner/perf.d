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
 *
 * On macOS the same `PerfGroup` surface is backed by
 * `proc_pid_rusage(RUSAGE_INFO_V4)` — the unprivileged XNU fixed counters:
 * true retired instructions and core cycles (process-wide, user+kernel, all
 * threads), so `--perf` renders IPC and instr/iter with the other columns
 * honestly absent. Everything richer is a capability ad, not a backend: kpc
 * is root-or-blessed with the `RESTRICT_TO_KNOWN` allowlist, and sampling is
 * Instruments/xctrace-brokered only.
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
        perf_type_id, perf_hw_id, perf_sw_ids, perf_event_read_format,
        PERF_EVENT_IOC_DISABLE, PERF_EVENT_IOC_ENABLE;
    import core.sys.posix.unistd : posixClose = close;

    import sparkles.test_runner.perf_group : GroupSnapshot;

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
        private bool scaledMode;   /// full group kept multiplexing (--perf-scaled)
        private bool neverScheduled; /// calibration saw zero PMU time even reduced

        /// Whether counters are usable on this machine.
        bool available() const @safe pure nothrow @nogc => opened;

        /// Whether the group is usable but not in its clean default state
        /// (user-only fallback, dropped LLC pair, or scaled mode) — the
        /// bench header discloses `status()` once when this holds, so a
        /// silently narrowed or rescoped run never passes for a default one.
        package bool degraded() const @safe pure nothrow @nogc
            => userOnly || cacheDropped || scaledMode;

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
            if (scaledMode)
                s ~= "; multiplexed — values are labeled estimates (--perf-scaled)";
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
            if (scaledMode)
                present |= Capability.countingScaled;
            else
                absences ~= CapabilityAbsence(Capability.countingScaled,
                    "full-group estimates are opt-in (--perf-scaled); the default shrinks the "
                    ~ "group at open — residual per-pass scaling still renders ≈");
            if (opened && probeRdpmc(fds[0]))
                present |= Capability.selfMonitoring;
            else
                absences ~= CapabilityAbsence(Capability.selfMonitoring, opened
                    ? "cap_user_rdpmc denied (kernel rdpmc policy, or non-x86-64)"
                    : "user-space reads need an open counting group");
            absences ~= CapabilityAbsence(Capability.ipSampling,
                "overflow/IP sampling lands in B6");
            absences ~= CapabilityAbsence(Capability.preciseMemory, preciseMemoryAbsence());
            return CapabilityReport(present, absences);
        }

        /// Whether the kernel grants user-space (`rdpmc`) reads for this
        /// group's events on this host — a live mmap probe.
        private static bool probeRdpmc(int fd) @safe nothrow
        {
            import sparkles.test_runner.rdpmc : RdpmcCounter;

            auto reader = RdpmcCounter.tryMap(fd);
            const cap = reader.capRdpmc;
            reader.close();
            return cap;
        }

        /// Opens the group unless disabled; failure leaves it unavailable.
        /// A short calibration decides whether the full group (with the LLC
        /// pair) co-schedules on this machine's free PMCs — a multiplexed
        /// group yields only rotation-scaled estimates, so by default the LLC
        /// pair is dropped rather than reported inaccurately. With
        /// `allowScaled` (`--perf-scaled`) the full group is kept instead and
        /// its values render as labeled estimates.
        static PerfGroup tryOpen(bool enabled, bool allowScaled = false) @safe
        {
            PerfGroup g;
            g.requested = enabled;
            if (!enabled)
                return g;
            g.opened = g.openGroup(withCache: true);
            if (!g.opened)
                return g;
            const calibration = g.calibratedScale();
            if (calibration < 0.98)
            {
                if (allowScaled && calibration > 0)
                {
                    g.scaledMode = true;
                    return g;
                }
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
                fillUnavailable(s);
                return s;
            }
            assignSlots(s, values[]);
            return s;
        }

        /// Maps opened-counter slot values (fds order) back to the fixed
        /// `PerfStats` fields; a dropped event (e.g. the LLC pair under
        /// multiplexing) reads nan. Shared by the counting pass and the
        /// window read so a future eighth event is one edit.
        private void assignSlots(ref PerfStats s, scope const(double)[] values)
            const @safe pure nothrow @nogc
        {
            size_t slot;
            double[events.length] byEvent;
            foreach (i; 0 .. events.length)
                byEvent[i] = fds[i] < 0 ? double.nan : values[slot++];
            s.cycles = byEvent[0];
            s.instructions = byEvent[1];
            s.branches = byEvent[2];
            s.branchMisses = byEvent[3];
            s.cacheReferences = byEvent[4];
            s.cacheMisses = byEvent[5];
            s.pageFaults = byEvent[6];
        }

        /// All counter fields to nan: a failed read/window is unavailable,
        /// never zeros.
        private static void fillUnavailable(ref PerfStats s) @safe pure nothrow @nogc
        {
            s.cycles = s.instructions = s.branches = s.branchMisses
                = s.cacheReferences = s.cacheMisses = s.pageFaults = double.nan;
        }

        /// Enables/disables the whole group for window measurement — no
        /// `RESET`, so edge snapshots stay cumulative and overlapping windows
        /// (a whole-body candidate around in-body windows) compose freely.
        void enable() @safe
        {
            import sparkles.test_runner.perf_group : groupIoctl;

            if (opened)
                groupIoctl(fds[0], PERF_EVENT_IOC_ENABLE);
        }

        /// ditto
        void disable() @safe
        {
            import sparkles.test_runner.perf_group : groupIoctl;

            if (opened)
                groupIoctl(fds[0], PERF_EVENT_IOC_DISABLE);
        }

        /// Captures one window-edge reading; `ok == false` (inside) when the
        /// group is closed or the read failed.
        PerfSnapshot snapshot() const @safe
        {
            import sparkles.test_runner.perf_group : snapshotGroup;

            return opened ? PerfSnapshot(snapshotGroup(fds[0], nOpen)) : PerfSnapshot();
        }

        /// The counter deltas across one window, as window $(B totals)
        /// (`iters = 1`) — same gate vocabulary as the counting pass, plus
        /// the never-enabled gate (`windowDeltas`).
        PerfStats windowStats(in PerfSnapshot a, in PerfSnapshot b)
            const @safe pure nothrow @nogc
        {
            import sparkles.test_runner.perf_group : windowDeltas;

            PerfStats s;
            s.iters = 1;
            s.userOnly = userOnly;
            double[events.length] values;
            if (!windowDeltas(a.g, b.g, s.scale, values[]))
            {
                fillUnavailable(s);
                return s;
            }
            assignSlots(s, values[]);
            return s;
        }
    }

    /// One cumulative window-edge reading of the perf group.
    struct PerfSnapshot
    {
        package GroupSnapshot g;
    }
}
else version (OSX)
{
    import core.time : MonoTime, msecs;

    // ── The libproc surface. druntime has no binding; `proc_pid_rusage`
    // lives in libSystem (no extra link flags). Layout verified against the
    // macOS SDK header (`$(xcrun --show-sdk-path)/usr/include/sys/resource.h`)
    // on Darwin 25.3 / xnu-12377 (T6041) — pinned by the static asserts
    // below, the event_naming.d pfm_perf_encode_arg_t precedent.
    extern (C) private int proc_pid_rusage(int pid, int flavor, void* buffer) @nogc nothrow;
    extern (C) private int sysctlbyname(const(char)* name, void* oldp,
        size_t* oldlenp, void* newp, size_t newlen) @nogc nothrow;

    private enum int rusageInfoV4 = 4;

    /// xnu `bsd/sys/resource.h` `struct rusage_info_v4` (name kept C-style
    /// for the 1:1 field mapping): a 16-byte uuid then 35 × uint64. The two
    /// fields this backend reads — `ri_instructions`/`ri_cycles` — are the
    /// XNU "monotonic" fixed counters (`MT_CORE_INSTRS`/`MT_CORE_CYCLES`):
    /// true retired instructions and core cycles, per process, user+kernel,
    /// with no root and no entitlement.
    package struct rusage_info_v4
    {
        ubyte[16] ri_uuid;
        ulong ri_user_time;
        ulong ri_system_time;
        ulong ri_pkg_idle_wkups;
        ulong ri_interrupt_wkups;
        ulong ri_pageins;
        ulong ri_wired_size;
        ulong ri_resident_size;
        ulong ri_phys_footprint;
        ulong ri_proc_start_abstime;
        ulong ri_proc_exit_abstime;
        ulong ri_child_user_time;
        ulong ri_child_system_time;
        ulong ri_child_pkg_idle_wkups;
        ulong ri_child_interrupt_wkups;
        ulong ri_child_pageins;
        ulong ri_child_elapsed_abstime;
        ulong ri_diskio_bytesread;
        ulong ri_diskio_byteswritten;
        ulong ri_cpu_time_qos_default;
        ulong ri_cpu_time_qos_maintenance;
        ulong ri_cpu_time_qos_background;
        ulong ri_cpu_time_qos_utility;
        ulong ri_cpu_time_qos_legacy;
        ulong ri_cpu_time_qos_user_initiated;
        ulong ri_cpu_time_qos_user_interactive;
        ulong ri_billed_system_time;
        ulong ri_serviced_system_time;
        ulong ri_logical_writes;
        ulong ri_lifetime_max_phys_footprint;
        ulong ri_instructions;
        ulong ri_cycles;
        ulong ri_billed_energy;
        ulong ri_serviced_energy;
        ulong ri_interval_max_phys_footprint;
        ulong ri_runnable_time;
    }

    static assert(rusage_info_v4.sizeof == 296,
        "rusage_info_v4 must match xnu bsd/sys/resource.h (16-byte uuid + 35 × uint64)");
    static assert(rusage_info_v4.ri_instructions.offsetof == 248
        && rusage_info_v4.ri_cycles.offsetof == 256,
        "the fixed-counter fields moved — re-verify against the SDK header");

    /// One cumulative fixed-counter reading; `ok == false` = syscall failed.
    package struct RusageReading
    {
        ulong instructions;
        ulong cycles;
        bool ok;
    }

    /// Reads the full accounting struct; `false` = the syscall failed.
    /// Shared with the darwin tier-0 body (disk-I/O byte counters).
    package bool readRusageInfo(out rusage_info_v4 info) @trusted nothrow @nogc
    {
        import core.sys.posix.unistd : getpid;

        return proc_pid_rusage(getpid(), rusageInfoV4, &info) == 0;
    }

    /// Reads the process's cumulative retired-instruction/cycle counters.
    package RusageReading readFixedCounters() @safe nothrow @nogc
    {
        rusage_info_v4 info;
        if (!readRusageInfo(info))
            return RusageReading();
        return RusageReading(info.ri_instructions, info.ri_cycles, true);
    }

    /// The process-wide fixed-counter group (macOS): `proc_pid_rusage`'s
    /// `ri_instructions`/`ri_cycles` delivered through the same `PerfStats`
    /// surface as Linux's perf_event group — IPC, instructions and cycles
    /// per iteration; every other field explicitly unavailable. Scope
    /// honesty: these are process-wide free-running counters (user+kernel,
    /// all threads), not per-bracket configurable events — `degraded()`
    /// holds whenever the group is open, so every run discloses it once.
    /// kpc (the configurable per-thread tier) is deliberately not a
    /// backend: root-or-blessed-pid, the RESTRICT_TO_KNOWN allowlist, and
    /// single-owner EBUSY make it a capability ad, not a floor.
    struct PerfGroup
    {
        private bool requested;
        private bool opened;
        private bool armed; /// enable()/disable() window latch — the counters free-run
        private bool probeFailed; /// proc_pid_rusage itself failed
        private bool countersZero; /// counters flat across the probe spin (VM guest)
        private double selfInstr = 0; /// calibrated per-bracket snapshot cost
        private double selfCycles = 0;
        private string peSuffix; /// P/E-core disclosure, precomputed at open

        /// Whether the fixed counters tick on this host.
        bool available() const @safe pure nothrow @nogc => opened;

        /// Process-wide scope is a permanent departure from the Linux
        /// default (per-bracket events) — always disclosed once per run via
        /// the bench header's degraded-mode line.
        package bool degraded() const @safe pure nothrow @nogc => opened;

        /// The bare reason counting is unavailable — single-sourced between
        /// `status()` and `capabilities()`.
        private string countingAbsence() const @safe pure nothrow @nogc
        {
            if (!requested)
                return "not requested";
            if (countersZero)
                return "fixed counters read zero — virtualized guest, or monotonic disabled";
            return "proc_pid_rusage failed";
        }

        /// Human-readable availability, for a report header.
        string status() const @safe pure nothrow
        {
            if (!opened)
                return "unavailable (" ~ countingAbsence() ~ ")";
            return "process-wide fixed counters (proc_pid_rusage) — not per-bracket events"
                ~ peSuffix;
        }

        /// What this backend can deliver on this host (SPEC §6.2): scalar
        /// counting of the two fixed counters; reasoned absences for the
        /// rest, in the survey's language.
        CapabilityReport capabilities() const @safe nothrow
        {
            Capability present;
            CapabilityAbsence[] absences;
            if (opened)
                present |= Capability.counting;
            else
                absences ~= CapabilityAbsence(Capability.counting, countingAbsence());
            absences ~= CapabilityAbsence(Capability.countingRaw,
                "kpc requires root ('root or the blessed pid', xnu kern_kpc.c); "
                ~ "event allowlist RESTRICT_TO_KNOWN");
            absences ~= CapabilityAbsence(Capability.countingScaled,
                "two fixed counters, never multiplexed — no scaled mode on macOS");
            absences ~= CapabilityAbsence(Capability.selfMonitoring,
                "no user-space read path — fixed counters are read via the "
                ~ "proc_pid_rusage syscall");
            absences ~= CapabilityAbsence(Capability.ipSampling,
                "via Instruments/xctrace only (kperf is root-or-blessed; "
                ~ "no unprivileged sampling door)");
            absences ~= CapabilityAbsence(Capability.preciseMemory,
                "absent on macOS — kpc/kperf expose PC-capture only, no data-source packets");
            return CapabilityReport(present, absences);
        }

        /// Opens the group unless disabled. The probe reads, spins ~1 ms of
        /// real work, and reads again: a flat instruction counter means the
        /// monotonic counters are not ticking — Virtualization.framework
        /// guests (GitHub's macOS CI runners) — and the group degrades to a
        /// reasoned absence rather than fabricating zeros.
        static PerfGroup tryOpen(bool enabled, bool allowScaled = false) @safe
        {
            PerfGroup g;
            g.requested = enabled;
            if (!enabled)
                return g;
            const a = readFixedCounters();
            if (!a.ok)
            {
                g.probeFailed = true;
                return g;
            }
            probeSpin();
            const b = readFixedCounters();
            if (!b.ok || b.instructions == a.instructions)
            {
                g.countersZero = true;
                return g;
            }
            g.opened = true;
            g.calibrate();
            // The M7-shared portability rider: on P/E-core hosts the fixed
            // counters aggregate across core types — disclose it on the
            // same status line (a run-level provenance stamp is M7's job;
            // benchProvenance stays suite-controlled by contract).
            const levels = perfLevels();
            if (levels > 1)
            {
                import std.conv : text;

                g.peSuffix = text("; P/E-core host (", levels,
                    " perf levels) — fixed counters aggregate across core types");
            }
            return g;
        }

        /// `hw.nperflevels`: the number of distinct core performance levels
        /// (2 on P/E-core Apple Silicon); 0 when the sysctl is absent.
        private static uint perfLevels() @safe nothrow
        {
            uint levels;
            size_t len = levels.sizeof;
            const rc = (() @trusted => sysctlbyname("hw.nperflevels",
                &levels, &len, null, 0))();
            return rc == 0 ? levels : 0;
        }

        /// ~1 ms of unmistakable retirement for the probe.
        private static void probeSpin() @safe nothrow
        {
            static ulong sink;
            const t0 = MonoTime.currTime;
            while (MonoTime.currTime - t0 < 1.msecs)
                foreach (i; 0 .. 1000)
                    sink += i * i;
        }

        /// Median empty-bracket cost of the two `proc_pid_rusage` syscalls
        /// (they retire kernel-mode instructions attributed to this
        /// process), mirroring `Tier0Group`'s calibration; subtracted from
        /// each pass's per-iteration average, clamped by `netOfCost`.
        private void calibrate() @safe
        {
            import std.algorithm.sorting : sort;

            enum rounds = 9;
            double[rounds] instr, cyc;
            foreach (r; 0 .. rounds)
            {
                const a = readFixedCounters();
                const b = readFixedCounters();
                instr[r] = a.ok && b.ok ? double(b.instructions - a.instructions) : 0;
                cyc[r] = a.ok && b.ok ? double(b.cycles - a.cycles) : 0;
            }
            instr[].sort;
            cyc[].sort;
            selfInstr = instr[rounds / 2];
            selfCycles = cyc[rounds / 2];
        }

        /// Releases nothing — the group holds no descriptors.
        void close() @safe pure nothrow @nogc
        {
        }

        /// The counting pass: per-iteration snapshot-pair brackets (the
        /// tier-0 shape — `between()` stays outside the counted window),
        /// per-iteration averages net of the calibrated bracket cost.
        PerfStats count(Timed, Between)(scope Timed timed, scope Between between,
            uint iters)
        in (iters > 0)
        {
            import sparkles.test_runner.tier0 : netOfCost;

            PerfStats s;
            s.iters = iters;
            fillNonFixed(s);
            double sumInstr = 0, sumCycles = 0;
            foreach (_; 0 .. iters)
            {
                const a = readFixedCounters();
                timed();
                const b = readFixedCounters();
                between();
                if (a.ok && b.ok)
                {
                    sumInstr += double(b.instructions - a.instructions);
                    sumCycles += double(b.cycles - a.cycles);
                }
                else
                    sumInstr = sumCycles = double.nan; // a failed bracket poisons the pass
            }
            const inv = 1.0 / iters;
            s.instructions = netOfCost(sumInstr * inv, selfInstr);
            s.cycles = netOfCost(sumCycles * inv, selfCycles);
            return s;
        }

        /// The non-fixed fields must be explicitly unavailable: `PerfStats`
        /// defaults are 0, and zeros here would be fabricated counts.
        private static void fillNonFixed(ref PerfStats s) @safe pure nothrow @nogc
        {
            s.branches = s.branchMisses = s.cacheReferences = s.cacheMisses
                = s.pageFaults = double.nan;
        }

        /// The window-arming latch: darwin's fixed counters cannot be
        /// disabled, so `enable`/`disable` record intent into each snapshot
        /// — preserving the SPEC §4 never-enabled → nan gate.
        void enable() @safe pure nothrow @nogc
        {
            if (opened)
                armed = true;
        }

        /// ditto
        void disable() @safe pure nothrow @nogc
        {
            armed = false;
        }

        /// Captures one window-edge reading, stamped with the latch.
        PerfSnapshot snapshot() const @safe nothrow @nogc
            => opened ? PerfSnapshot(readFixedCounters(), armed) : PerfSnapshot();

        /// The fixed-counter deltas across one window, as window totals
        /// (`iters = 1`), net of one bracket's calibrated cost.
        PerfStats windowStats(in PerfSnapshot a, in PerfSnapshot b)
            const @safe pure nothrow @nogc
        {
            import sparkles.test_runner.tier0 : netOfCost;

            PerfStats s;
            s.iters = 1;
            fillNonFixed(s);
            if (!(a.armed && b.armed && a.r.ok && b.r.ok
                    && b.r.instructions >= a.r.instructions && b.r.cycles >= a.r.cycles))
            {
                s.instructions = s.cycles = double.nan;
                return s;
            }
            s.instructions = netOfCost(double(b.r.instructions - a.r.instructions), selfInstr);
            s.cycles = netOfCost(double(b.r.cycles - a.r.cycles), selfCycles);
            return s;
        }
    }

    /// One cumulative fixed-counter window edge, with the arming latch.
    struct PerfSnapshot
    {
        package RusageReading r;
        package bool armed;
    }
}
else
{
    /// Off Linux and macOS: a permanently-unavailable stub with the same
    /// surface.
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
            package bool degraded() const => false;
            string status() const => "unavailable (not Linux)";
            CapabilityReport capabilities() const
                => CapabilityReport(Capability.none, stubAbsence[]);
            static PerfGroup tryOpen(bool, bool = false) => PerfGroup();
            void close() {}
            void enable() {}
            void disable() {}
            PerfSnapshot snapshot() const => PerfSnapshot();
        }

        PerfStats count(Timed, Between)(scope Timed, scope Between, uint)
            => assert(false, "perf counters are Linux-only");

        PerfStats windowStats(in PerfSnapshot, in PerfSnapshot)
            const @safe pure nothrow @nogc
            => assert(false, "perf counters are Linux-only");
    }

    /// Off Linux: an empty window-edge marker with the same name.
    struct PerfSnapshot
    {
    }
}

// Whichever body the platform built (real or stub) satisfies the backend
// contract, including the snapshot/delta window primitive; the seam's
// compile-time tripwire.
static assert(isCounterBackend!PerfGroup);
static assert(hasSnapshot!PerfGroup);
static assert(!hasNamedColumns!PerfGroup);

@("perf.PerfGroup.capabilities.notRequested")
@safe
unittest
{
    auto g = PerfGroup.tryOpen(false);
    const r = g.capabilities;
    assert(!r.has(Capability.counting));
    version (linux)
        assert(r.reasonFor(Capability.counting) == "not requested");
    else version (OSX)
        assert(r.reasonFor(Capability.counting) == "not requested");
    else
        assert(r.reasonFor(Capability.counting) == "not Linux");
}

version (OSX)
{
    @("perf.PerfGroup.darwin.capabilities")
    @system
    unittest
    {
        import std.algorithm.searching : canFind;
        import sparkles.test_runner.skip : skipTest;

        auto g = PerfGroup.tryOpen(true);
        scope (exit)
            g.close();
        // The kpc/xctrace capability ads hold whether or not the fixed
        // counters tick (a VM guest still explains the whole domain).
        const r = g.capabilities;
        assert(r.reasonFor(Capability.countingRaw).canFind("RESTRICT_TO_KNOWN"));
        assert(r.reasonFor(Capability.ipSampling).canFind("xctrace"));
        assert(r.reasonFor(Capability.selfMonitoring) !is null);
        assert(r.reasonFor(Capability.preciseMemory) !is null);
        assert(r.reasonFor(Capability.countingScaled) !is null);
        if (!g.available)
            skipTest(g.status()); // Virtualization.framework guest
        assert(r.has(Capability.counting));
        assert(g.degraded, "process-wide scope is always disclosed");
    }

    @("perf.PerfGroup.darwin.statusByteIdentity")
    @safe pure nothrow
    unittest
    {
        PerfGroup g;
        g.requested = true;
        assert(g.status == "unavailable (proc_pid_rusage failed)");
        g.countersZero = true;
        assert(g.status
            == "unavailable (fixed counters read zero — virtualized guest, or monotonic disabled)");
        g.countersZero = false;
        g.opened = true;
        assert(g.status
            == "process-wide fixed counters (proc_pid_rusage) — not per-bracket events");
        assert(g.degraded == g.opened);
    }

    @("perf.PerfGroup.darwin.abiSanity")
    @system
    unittest
    {
        import sparkles.test_runner.skip : skipTest;

        // A live layout cross-check: a ~100k-iteration spin between two raw
        // readings must move ri_instructions by a plausible amount — a
        // misaligned struct reads garbage (absurd deltas) or dead fields
        // (zero deltas) instead.
        const a = readFixedCounters();
        if (!a.ok)
            skipTest("proc_pid_rusage failed");
        static ulong sink;
        foreach (i; 0 .. 100_000)
            sink += i * i;
        const b = readFixedCounters();
        assert(b.ok);
        const instr = b.instructions - a.instructions;
        if (instr == 0)
            skipTest("fixed counters read zero — virtualized guest");
        assert(instr > 10_000 && instr < 1_000_000_000,
            "the instruction delta of a 100k spin is plausible");
        assert(b.cycles > a.cycles, "cycles advance with instructions");
    }
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

    @("perf.PerfGroup.degraded")
    @safe pure nothrow @nogc
    unittest
    {
        PerfGroup g;
        assert(!g.degraded, "clean state");
        g.userOnly = true;
        assert(g.degraded);
        g.userOnly = false;
        g.cacheDropped = true;
        assert(g.degraded);
        g.cacheDropped = false;
        g.scaledMode = true;
        assert(g.degraded);
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

@("perf.PerfGroup.countSmoke")
@system
unittest
{
    // Un-gated: runs the perf_event path on Linux and the proc_pid_rusage
    // path on macOS; skips with the group's own reason elsewhere (stub) or
    // when the host refuses (paranoid kernels, VM guests).
    auto g = PerfGroup.tryOpen(true);
    scope (exit)
        g.close();
    import sparkles.test_runner.skip : skipTest;

    if (!g.available)
        skipTest(g.status());

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
        skipTest(g.status());

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

@("perf.PerfGroup.windowStats.spinWindow")
@system
unittest
{
    // The window model: enable once, read cumulative edges, delta — no
    // per-iteration bracket, no RESET. A spin window must retire
    // instructions; a window across a disabled group must read nan (the
    // never-enabled gate), never fabricated zeros.
    auto g = PerfGroup.tryOpen(true);
    scope (exit)
        g.close();
    import sparkles.test_runner.skip : skipTest;

    if (!g.available)
        skipTest(g.status());

    static ulong sink;
    static void spin()
    {
        foreach (i; 0 .. 200_000)
            sink += i * i;
    }

    // Disabled group (tryOpen leaves counters disarmed): enabled time does
    // not advance across the window, so the deltas are not measurements.
    const d0 = g.snapshot();
    spin();
    const d1 = g.snapshot();
    import std.math : isNaN;

    assert(g.windowStats(d0, d1).instructions.isNaN,
        "a never-enabled window must not fabricate zeros");

    g.enable();
    scope (exit)
        g.disable();
    const a = g.snapshot();
    spin();
    const b = g.snapshot();
    const s = g.windowStats(a, b);
    assert(s.iters == 1);
    if (s.instructions.isNaN)
        skipTest("window was multiplexed below the reliability gate");
    assert(s.instructions > 100_000, "a spin window retires instructions (totals, not per-iter)");
}
