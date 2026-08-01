/**
 * Shared `perf_event` counter-group mechanics: the `ENABLE`/`DISABLE` counting
 * bracket and the `PERF_FORMAT_GROUP` scaled read. Both the hardware-counter
 * group (`perf.d`) and the syscall-tracepoint group (`syscalls.d`) open a
 * `perf_event` group led by an fd, bracket a benchmark's timed body with the
 * same ioctls, and read the group with the same layout (`nr`, `time_enabled`,
 * `time_running`, then one value per opened counter). This module holds that
 * common core so a change to the scaling/rounding is made once, not twice.
 */
module sparkles.test_runner.perf_group;

version (linux)
{
    import core.sys.linux.perf_event : perf_event_ioc_flags,
        PERF_EVENT_IOC_DISABLE, PERF_EVENT_IOC_ENABLE, PERF_EVENT_IOC_RESET;
    import core.sys.posix.sys.ioctl : ioctl;
    import core.sys.posix.unistd : read;

    /// Rounds to three decimals; used only for the diagnostic `scale` field (a
    /// ratio in [0, 1]) so report headers stay short. Counter values are NOT
    /// rounded — see `projectPerIter`.
    package double round3(double v) @safe pure nothrow @nogc
    {
        import std.math.rounding : round;

        return round(v * 1000) / 1000;
    }

    /// One counter's per-iteration projection: the multiplex-corrected average.
    /// Deliberately unrounded — a rare-but-present event (one syscall or page
    /// fault in 10 000 iterations) must stay distinguishable from one that
    /// never fired; rendering formats to significant digits anyway.
    package double projectPerIter(ulong raw, double ratio, uint iters)
        @safe pure nothrow @nogc
        => double(raw) * ratio / iters;

    @("perf_group.projectPerIter.keepsRareEvents")
    @safe pure nothrow @nogc
    unittest
    {
        assert(projectPerIter(1, 1.0, 10_000) == 1e-4); // a 3-decimal round floors this to 0
        assert(projectPerIter(3370, 1.0, 1000) == 3.37);
    }

    /// Sends a group-wide `perf_event` ioctl to the group leader `leaderFd`.
    package void groupIoctl(int leaderFd, uint request) @safe
    {
        import core.stdc.config : c_ulong;

        (() @trusted => ioctl(leaderFd, cast(c_ulong) request,
                perf_event_ioc_flags.PERF_IOC_FLAG_GROUP))();
    }

    private enum maxCounters = 64; // perf group opens 7; syscall group up to 1 + 62

    /// A group's cumulative `time_enabled`/`time_running` at the start of a
    /// counting pass. `PERF_EVENT_IOC_RESET` zeroes the counter *values* but not
    /// these time fields — they accumulate from `perf_event_open` — so a
    /// long-lived group must correct each pass by the pass's own time deltas,
    /// not the whole process history.
    package struct GroupTimeBase
    {
        ulong enabled;
        ulong running;
    }

    /// The counting pass's ioctl bracket: `RESET` once, then per iteration
    /// `ENABLE`, `timed()`, `DISABLE`, `between()` — so only `timed()` is counted
    /// and `between()` (a benchmark's result release) runs uncounted. Returns the
    /// pass's time baseline for `readScaledGroup`.
    package GroupTimeBase bracketCountingPass(Timed, Between)(int leaderFd,
        scope Timed timed, scope Between between, uint iters)
    {
        groupIoctl(leaderFd, PERF_EVENT_IOC_RESET);
        const base = readGroupTimes(leaderFd);
        // A throw from timed() escapes between ENABLE and DISABLE; the groups
        // are long-lived (opened once per --bench run) and the streaming runner
        // continues after an error row, so an un-disabled group would keep
        // counting for the rest of the run.
        scope (failure)
            groupIoctl(leaderFd, PERF_EVENT_IOC_DISABLE);
        foreach (_; 0 .. iters)
        {
            groupIoctl(leaderFd, PERF_EVENT_IOC_ENABLE);
            timed();
            groupIoctl(leaderFd, PERF_EVENT_IOC_DISABLE);
            between();
        }
        return base;
    }

    /// Reads just the group's cumulative time fields; `(0, 0)` on a short read,
    /// so a failed baseline degrades the correction to the cumulative times
    /// (the pre-delta behavior), never to garbage.
    private GroupTimeBase readGroupTimes(int leaderFd) @safe
    {
        ulong[3 + maxCounters] buf;
        const got = (() @trusted => read(leaderFd, buf.ptr, buf.sizeof))();
        return got >= cast(long)(3 * ulong.sizeof)
            ? GroupTimeBase(buf[1], buf[2]) : GroupTimeBase();
    }

    /// The multiplex correction for one pass: when the PMU rotated the group
    /// out for part of the pass (`running < enabled`), the raw counts cover
    /// only the running fraction and are scaled up by `enabled/running`; a
    /// fully-scheduled (or empty) pass is `1`.
    package double scaledRatio(ulong enabledDelta, ulong runningDelta)
        @safe pure nothrow @nogc
    {
        return (runningDelta > 0 && enabledDelta > 0 && runningDelta < enabledDelta)
            ? double(enabledDelta) / double(runningDelta) : 1.0;
    }

    /// A pass that was enabled but never got PMU time (the kernel's
    /// `<not counted>` state — vPMU limits, or pinned events hogging every
    /// counter): its zero counts are meaningless, not measurements.
    package bool groupNeverRan(ulong enabledDelta, ulong runningDelta)
        @safe pure nothrow @nogc
    {
        return enabledDelta > 0 && runningDelta == 0;
    }

    /// A multiplexed pass whose PMU time is under a millisecond: the scaled
    /// estimate is noise, not a measurement (a 0.58 ms slice measured a 5.7×
    /// scale error on the survey's counting probe). Rendered unavailable —
    /// never as a number.
    package bool unreliableScale(ulong enabledDelta, ulong runningDelta)
        @safe pure nothrow @nogc
    {
        return runningDelta > 0 && runningDelta < enabledDelta
            && runningDelta < 1_000_000;
    }

    @("perf_group.unreliableScale")
    @safe pure nothrow @nogc
    unittest
    {
        assert(unreliableScale(2_000_000, 580_000), "the probe's 0.58 ms case");
        assert(!unreliableScale(580_000, 580_000), "exact short pass is fine");
        assert(!unreliableScale(10_000_000, 5_000_000), "≥1 ms scaled is a labeled estimate");
        assert(!unreliableScale(1_000_000, 0), "never-ran is its own state");
        assert(!unreliableScale(0, 0));
    }

    @("perf_group.groupNeverRan")
    @safe pure nothrow @nogc
    unittest
    {
        assert(groupNeverRan(1000, 0));
        assert(!groupNeverRan(1000, 1)); // any PMU time → scaled estimate
        assert(!groupNeverRan(0, 0)); // nothing enabled: empty, not starved
    }

    @("perf_group.scaledRatio")
    @safe pure nothrow @nogc
    unittest
    {
        assert(scaledRatio(0, 0) == 1.0);
        assert(scaledRatio(1000, 1000) == 1.0);
        assert(scaledRatio(2000, 1000) == 2.0);
        assert(scaledRatio(0, 1000) == 1.0); // degenerate: never enabled
        // The correction depends only on the pass's deltas — identical passes
        // yield identical ratios regardless of how much history preceded them.
        assert(scaledRatio(2000, 1000) == scaledRatio(2_000_000, 1_000_000));
    }

    /// Reads a `PERF_FORMAT_GROUP` group from `leaderFd` (`nOpen` counters opened,
    /// values returned in fd order). On success fills `values[0 .. nOpen]` with the
    /// per-iteration averages, multiplex-corrected by the *pass's* enabled/running
    /// deltas against `base` (see `GroupTimeBase`), sets `scale` to
    /// `round3(runningΔ/enabledΔ)` (`1` = no multiplexing), and returns `true`.
    /// On a short/interrupted read returns `false` and leaves `values`/`scale`
    /// untouched (the caller fills `nan`); on a pass the PMU never scheduled
    /// (`groupNeverRan`) returns `false` with `scale = 0` — the zero counts
    /// are the kernel's `<not counted>` state, not measurements.
    package bool readScaledGroup(int leaderFd, uint nOpen, uint iters,
        ref double scale, scope double[] values,
        GroupTimeBase base = GroupTimeBase.init) @safe
    in (values.length >= nOpen)
    {
        ulong[3 + maxCounters] buf;
        const want = cast(long)(ulong.sizeof * (3 + nOpen));
        const got = (() @trusted => read(leaderFd, buf.ptr, buf.sizeof))();
        if (got < want)
            return false;

        // Saturating deltas: the time fields are monotonic since open, so they
        // can only undershoot the baseline if the baseline read itself failed
        // (base = 0 → the delta is the cumulative time).
        const enabled = buf[1] >= base.enabled ? buf[1] - base.enabled : buf[1];
        const running = buf[2] >= base.running ? buf[2] - base.running : buf[2];
        return scaleGroupValues(enabled, running, iters, buf[3 .. 3 + nOpen],
            scale, values);
    }

    /// The gate/scale tail shared by the counting-pass read and the window
    /// delta: applies the never-ran and unreliable-scale gates to a pass's (or
    /// window's) enabled/running time deltas, then fills `values[0 .. raw.length]`
    /// with the multiplex-corrected per-iteration projections of the raw
    /// counts. `scale` contract as on `readScaledGroup`.
    private bool scaleGroupValues(ulong enabled, ulong running, uint iters,
        scope const(ulong)[] raw, ref double scale, scope double[] values)
        @safe pure nothrow @nogc
    in (values.length >= raw.length)
    {
        if (groupNeverRan(enabled, running))
        {
            scale = 0;
            return false;
        }
        if (unreliableScale(enabled, running))
        {
            // The true ratio still reaches the caller (calibration reads it to
            // tell "multiplexed" from "never scheduled"); only the values are
            // rejected. Unrounded: round3 would quantize a <0.0005 ratio to
            // exactly 0, which callers reserve for "never scheduled".
            scale = double(running) / double(enabled);
            return false;
        }
        const ratio = scaledRatio(enabled, running);
        scale = enabled > 0 ? round3(double(running) / double(enabled)) : 1.0;
        foreach (k, r; raw)
            values[k] = projectPerIter(r, ratio, iters);
        return true;
    }

    /// One cumulative `PERF_FORMAT_GROUP` reading at a window edge — a pure
    /// `read(2)`, no ioctl, no `RESET` — so an outer window candidate and
    /// inner in-body windows can overlap freely: each computes its own deltas
    /// between its own two edges.
    package struct GroupSnapshot
    {
        ulong enabled;
        ulong running;
        ulong[maxCounters] values;
        uint n; /// counters captured
        bool ok; /// `false` = short/failed read
    }

    /// Captures a window-edge snapshot of the group led by `leaderFd`.
    package GroupSnapshot snapshotGroup(int leaderFd, uint nOpen) @safe
    in (nOpen <= maxCounters)
    {
        GroupSnapshot s;
        ulong[3 + maxCounters] buf;
        const want = cast(long)(ulong.sizeof * (3 + nOpen));
        const got = (() @trusted => read(leaderFd, buf.ptr, buf.sizeof))();
        if (got < want)
            return s;
        s.enabled = buf[1];
        s.running = buf[2];
        s.values[0 .. nOpen] = buf[3 .. 3 + nOpen];
        s.n = nOpen;
        s.ok = true;
        return s;
    }

    /// Window deltas between two edge snapshots of one group: fills
    /// `values[0 .. a.n]` with the window's multiplex-corrected $(B totals)
    /// (`iters = 1`), sets `scale`, and returns `true` — same gate vocabulary
    /// as `readScaledGroup`, plus one gate the pass path cannot hit: a window
    /// across which the group's `enabled` time never advanced (the group was
    /// never enabled) yields `false` with `values`/`scale` untouched — zero
    /// deltas there would be fabricated counts, not measurements.
    package bool windowDeltas(in GroupSnapshot a, in GroupSnapshot b,
        ref double scale, scope double[] values) @safe pure nothrow @nogc
    in (values.length >= a.n)
    {
        if (!a.ok || !b.ok || a.n != b.n)
            return false;
        const enabled = b.enabled >= a.enabled ? b.enabled - a.enabled : 0;
        const running = b.running >= a.running ? b.running - a.running : 0;
        if (enabled == 0)
            return false;
        // Counter values are monotonic between the edges (windows never
        // RESET); saturate anyway so a misuse can't wrap to huge totals.
        ulong[maxCounters] deltas;
        foreach (k; 0 .. a.n)
            deltas[k] = b.values[k] >= a.values[k] ? b.values[k] - a.values[k] : 0;
        return scaleGroupValues(enabled, running, 1, deltas[0 .. a.n],
            scale, values);
    }

    @("perf_group.windowDeltas.gates")
    @safe pure nothrow @nogc
    unittest
    {
        static GroupSnapshot edge(ulong enabled, ulong running,
            ulong v0, ulong v1, bool ok = true)
        {
            GroupSnapshot s;
            s.enabled = enabled;
            s.running = running;
            s.values[0] = v0;
            s.values[1] = v1;
            s.n = 2;
            s.ok = ok;
            return s;
        }

        double scale = 123;
        double[2] vals = [-1, -1];

        // Failed edge read → no result, nothing touched.
        assert(!windowDeltas(edge(0, 0, 0, 0, false), edge(9, 9, 9, 9), scale, vals[]));
        assert(scale == 123 && vals[0] == -1);

        // Never enabled across the window → no result (zeros would be
        // fabricated), nothing touched.
        assert(!windowDeltas(edge(5000, 5000, 10, 20), edge(5000, 5000, 10, 20),
                scale, vals[]));
        assert(scale == 123 && vals[0] == -1);

        // Enabled but never scheduled → the kernel's <not counted>: scale 0.
        assert(!windowDeltas(edge(0, 0, 0, 0), edge(5000, 0, 0, 0), scale, vals[]));
        assert(scale == 0 && vals[0] == -1);

        // Multiplexed with under 1 ms of PMU time → unreliable: the true
        // ratio is reported, the values are rejected.
        scale = 123;
        assert(!windowDeltas(edge(0, 0, 0, 0), edge(2_000_000, 580_000, 100, 200),
                scale, vals[]));
        assert(scale == 0.29 && vals[0] == -1);

        // Clean window → totals, scale 1.
        assert(windowDeltas(edge(1000, 1000, 10, 20), edge(2_001_000, 2_001_000, 110, 220),
                scale, vals[]));
        assert(scale == 1 && vals[0] == 100 && vals[1] == 200);

        // Multiplexed ≥ 1 ms → scaled totals, labeled scale.
        assert(windowDeltas(edge(0, 0, 0, 0), edge(4_000_000, 2_000_000, 100, 200),
                scale, vals[]));
        assert(scale == 0.5 && vals[0] == 200 && vals[1] == 400);
    }
}
