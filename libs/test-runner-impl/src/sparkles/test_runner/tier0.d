/**
 * Tier-0 cheap resource counters, in pure D — the always-available I/O-bound
 * signal that needs no `perf_event`, no tracepoints, and no elevated privilege.
 *
 * Two process-wide cumulative sources are sampled as deltas across a counting
 * pass (mirroring `perf.d`'s separate pass, so the reported ns/iter timings are
 * never perturbed):
 *
 * $(LIST
 *   * `getrusage(RUSAGE_SELF)` — minor/major page faults and voluntary /
 *     involuntary context switches (the direct blocked-on-I/O vs preempted
 *     signal);
 *   * `/proc/self/io` — `syscr`/`syscw` (read/write syscall counts), `rchar`/
 *     `wchar` (bytes through the syscall layer, cache included) and `read_bytes`/
 *     `write_bytes` (bytes that actually hit the block device). The gap between
 *     `rchar` and `read_bytes` is the page-cache-hit signal, for free.
 * )
 *
 * All metrics are `quantitative`: each `timed()` call is bracketed by its own
 * pair of cheap snapshots, so — like `perf.d`'s ioctl `ENABLE`/`DISABLE` — the
 * untimed `between()` teardown (a `benchCase`'s result release) is excluded from
 * the counted window. The snapshots cannot pause, so each bracket's own `/proc`
 * read lands inside its window; `tryOpen` calibrates that per-bracket self-cost
 * (median of several empty brackets) and `count` reports the workload net of it,
 * clamped at zero — so a body that does no I/O reads ≈0, not the instrumentation
 * constant. The getrusage-sourced page-fault and context-switch columns carry no
 * per-bracket cost. On macOS a darwin body serves the same surface from
 * `getrusage`'s maintained BSD-tail fields plus `proc_pid_rusage`'s disk-I/O
 * byte counters; elsewhere the group is permanently unavailable.
 */
module sparkles.test_runner.tier0;

import sparkles.test_runner.capability : Capability, CapabilityAbsence,
    CapabilityReport, has, hasNamedColumns, hasSnapshot, isCounterBackend,
    reasonFor;

/// Per-iteration Tier-0 counter deltas of one counting pass. A field is `nan`
/// when its source could not be read on this machine.
struct Tier0Stats
{
    ulong iters;      /// counting-pass iterations
    double minflt = 0; /// minor page faults per iteration (getrusage)
    double majflt = 0; /// major page faults per iteration (getrusage)
    double volCs = 0;  /// voluntary context switches per iteration (blocked on I/O)
    double involCs = 0; /// involuntary context switches per iteration (preempted)
    double syscr = 0;  /// read syscalls per iteration (/proc/self/io)
    double syscw = 0;  /// write syscalls per iteration
    double rdChars = 0; /// bytes read through the syscall layer (cache included)
    double wrChars = 0; /// bytes written through the syscall layer
    double rdBytes = 0; /// bytes that actually hit the block device (reads)
    double wrBytes = 0; /// bytes that actually hit the block device (writes)
}

/// Page-cache hit rate in percent: the fraction of bytes served without touching
/// the block device (`1 − read_bytes ÷ rchar`). `nan` when nothing was read (or
/// `read_bytes` is unavailable). A cold read's kernel readahead can pull more from
/// disk than userspace consumed (`read_bytes > rchar`), so the ratio is clamped to
/// a 0% hit rate rather than reported as `nan` — the cold case the metric reveals.
double cacheHitPercent(in Tier0Stats t) @safe pure nothrow @nogc
{
    import std.algorithm.comparison : min;

    return t.rdChars > 0 && t.rdBytes >= 0
        ? (1 - min(t.rdBytes, t.rdChars) / t.rdChars) * 100 : double.nan;
}

@("tier0.cacheHitPercent")
@safe pure nothrow @nogc
unittest
{
    import std.math : isClose, isNaN;

    assert(cacheHitPercent(Tier0Stats(rdChars: 4096, rdBytes: 0)).isClose(100));
    assert(cacheHitPercent(Tier0Stats(rdChars: 4096, rdBytes: 1024)).isClose(75));
    // Readahead: read_bytes > rchar → clamp to 0%, not nan.
    assert(cacheHitPercent(Tier0Stats(rdChars: 4096, rdBytes: 8192)).isClose(0));
    // Unknown block-device counter (nan) or nothing read → nan.
    assert(cacheHitPercent(Tier0Stats(rdChars: 4096, rdBytes: double.nan)).isNaN);
    assert(cacheHitPercent(Tier0Stats(rdChars: 0, rdBytes: 0)).isNaN);
}

/// Finds `key:` at a line start in a `/proc`-style `key:\tvalue` file and parses
/// the trailing unsigned integer; `-1` when the key is absent or unparsable.
long parseProcField(const(char)[] content, const(char)[] key) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < content.length)
    {
        if (content.length - i > key.length
            && content[i .. i + key.length] == key
            && content[i + key.length] == ':')
        {
            size_t j = i + key.length + 1;
            while (j < content.length && (content[j] == ' ' || content[j] == '\t'))
                j++;
            long value = 0;
            bool any;
            while (j < content.length && content[j] >= '0' && content[j] <= '9')
            {
                value = value * 10 + (content[j] - '0');
                j++;
                any = true;
            }
            return any ? value : -1;
        }
        while (i < content.length && content[i] != '\n')
            i++;
        if (i < content.length)
            i++;
    }
    return -1;
}

@("tier0.parseProcField")
@safe pure nothrow @nogc
unittest
{
    static immutable io = "rchar: 4096\nwchar: 0\nsyscr: 7\nread_bytes: 512\n";
    assert(parseProcField(io, "rchar") == 4096);
    assert(parseProcField(io, "syscr") == 7);
    assert(parseProcField(io, "read_bytes") == 512);
    assert(parseProcField(io, "write_bytes") == -1); // absent
    assert(parseProcField(io, "char") == -1);         // not a line-start key
}

/// Divides raw before/after readings into per-iteration `Tier0Stats`; a source
/// unavailable in either reading yields `nan` for its fields.
package Tier0Stats deltaStats(in Tier0Reading a, in Tier0Reading b, uint iters)
    @safe pure nothrow @nogc
in (iters > 0)
{
    const inv = 1.0 / iters;
    Tier0Stats s;
    s.iters = iters;

    // Per-field guard: a reading whose field is absent (a kernel
    // omitting/restricting it, or a platform whose libc reports but never
    // maintains it — XNU's rusage tail leaves ru_nvcsw permanently 0) is
    // -1, and an absent counter must read nan, never a fabricated 0 delta
    // (which would also feed a fake 100% cache-hit figure).
    static double guarded(long av, long bv, double inv) @safe pure nothrow @nogc
        => av >= 0 && bv >= 0 ? (bv - av) * inv : double.nan;

    if (a.rusageOk && b.rusageOk)
    {
        s.minflt = guarded(a.minflt, b.minflt, inv);
        s.majflt = guarded(a.majflt, b.majflt, inv);
        s.volCs = guarded(a.volCs, b.volCs, inv);
        s.involCs = guarded(a.involCs, b.involCs, inv);
    }
    else
        s.minflt = s.majflt = s.volCs = s.involCs = double.nan;
    if (a.ioOk && b.ioOk)
    {
        s.syscr = guarded(a.syscr, b.syscr, inv);
        s.syscw = guarded(a.syscw, b.syscw, inv);
        s.rdChars = guarded(a.rdChars, b.rdChars, inv);
        s.wrChars = guarded(a.wrChars, b.wrChars, inv);
        s.rdBytes = guarded(a.rdBytes, b.rdBytes, inv);
        s.wrBytes = guarded(a.wrBytes, b.wrBytes, inv);
    }
    else
        s.syscr = s.syscw = s.rdChars = s.wrChars = s.rdBytes = s.wrBytes = double.nan;
    return s;
}

@("tier0.deltaStats.absentBlockDeviceFields")
@safe pure nothrow @nogc
unittest
{
    import std.math : isClose, isNaN;

    // A kernel without CONFIG_TASK_IO_ACCOUNTING: rchar/syscr present, read_bytes/
    // write_bytes absent (-1) — ioOk is still true.
    const a = Tier0Reading(syscr: 10, syscw: 2, rdChars: 4096, wrChars: 0,
        rdBytes: -1, wrBytes: -1, ioOk: true);
    const b = Tier0Reading(syscr: 20, syscw: 4, rdChars: 8192, wrChars: 0,
        rdBytes: -1, wrBytes: -1, ioOk: true);
    const s = deltaStats(a, b, 2);
    assert(s.syscr.isClose(5) && s.rdChars.isClose(2048));
    assert(s.rdBytes.isNaN && s.wrBytes.isNaN, "absent block-device fields → nan");
    assert(cacheHitPercent(s).isNaN, "cache-hit unknown when read_bytes absent");
}

/// A single instant's raw cumulative counters.
struct Tier0Reading
{
    long minflt, majflt, volCs, involCs; /// getrusage
    long syscr, syscw, rdChars, wrChars, rdBytes, wrBytes; /// /proc/self/io
    bool rusageOk, ioOk;
}

version (linux)
{
    import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;

    /// The Tier-0 counter group. No fds; `count` snapshots the cumulative
    /// counters around each iteration. Carries the calibrated per-bracket
    /// self-cost of the snapshots themselves (see `calibrateSelfCost`).
    struct Tier0Group
    {
        private bool enabled;
        private Tier0Stats selfCost; /// per-bracket snapshot cost; 0 = uncalibrated

        /// Whether Tier-0 counters will be collected (Linux and requested).
        bool available() const @safe pure nothrow @nogc => enabled;

        /// Human-readable availability, for a report header.
        string status() const @safe pure nothrow
            => enabled ? "getrusage + /proc/self/io" : "not requested";

        /// What this backend can deliver: process-scope resource counting —
        /// present whenever requested (Linux needs no privilege for it).
        CapabilityReport capabilities() const @safe pure nothrow @nogc
            => enabled
                ? CapabilityReport(Capability.counting, null)
                : CapabilityReport(Capability.none, notRequestedAbsence[]);

        private static immutable CapabilityAbsence[1] notRequestedAbsence = [
            CapabilityAbsence(Capability.counting, "not requested"),
        ];

        /// Enables collection when `enabled` and calibrates the snapshot
        /// self-cost; otherwise an unavailable group (mirrors
        /// `PerfGroup.tryOpen(false)`), so the same call sites work.
        static Tier0Group tryOpen(bool enabled) @safe
        {
            auto g = Tier0Group(enabled);
            if (enabled)
                g.selfCost = g.calibrateSelfCost();
            return g;
        }

        /// The per-bracket cost of the bracketing snapshots themselves: each
        /// `start`/`end` pair puts one `/proc/self/io` read (~1 `syscr`, a few
        /// hundred `rchar` bytes) inside its own window. Measured as the median
        /// of several empty brackets so `count` can subtract it. Page-fault and
        /// context-switch fields stay 0 — they carry no steady-state bracket
        /// cost, and subtracting sporadic noise would bias real counts.
        private Tier0Stats calibrateSelfCost() @safe
        {
            import std.algorithm.sorting : sort;
            import std.math : isNaN;

            enum rounds = 9;
            double[rounds] syscr, syscw, rdChars, wrChars;
            foreach (i; 0 .. rounds)
            {
                const one = deltaStats(snapshot(), snapshot(), 1);
                syscr[i] = one.syscr;
                syscw[i] = one.syscw;
                rdChars[i] = one.rdChars;
                wrChars[i] = one.wrChars;
            }

            static double med(double[] v) @safe
            {
                if (v[0].isNaN)
                    return 0; // source unavailable — nothing to subtract
                v.sort;
                return v[$ / 2];
            }

            Tier0Stats cost;
            cost.syscr = med(syscr[]);
            cost.syscw = med(syscw[]);
            cost.rdChars = med(rdChars[]);
            cost.wrChars = med(wrChars[]);
            return cost;
        }

        /// Nothing to release; present for surface parity with `PerfGroup`.
        void close() @safe pure nothrow @nogc {}

        /// Reads the cumulative counters now.
        Tier0Reading snapshot() @safe nothrow @nogc
        {
            Tier0Reading r;
            rusage ru;
            if ((() @trusted => getrusage(RUSAGE_SELF, &ru))() == 0)
            {
                r.minflt = ru.ru_minflt;
                r.majflt = ru.ru_majflt;
                r.volCs = ru.ru_nvcsw;
                r.involCs = ru.ru_nivcsw;
                r.rusageOk = true;
            }
            char[1024] buf = void;
            const io = readProcSelfIo(buf[]);
            if (io.length)
            {
                r.syscr = parseProcField(io, "syscr");
                r.syscw = parseProcField(io, "syscw");
                r.rdChars = parseProcField(io, "rchar");
                r.wrChars = parseProcField(io, "wchar");
                r.rdBytes = parseProcField(io, "read_bytes");
                r.wrBytes = parseProcField(io, "write_bytes");
                // A field the kernel omits (older kernels, restricted) reads -1;
                // treat the source as usable iff the always-present counts are.
                r.ioOk = r.syscr >= 0 && r.rdChars >= 0;
            }
            return r;
        }

        /// The counting pass: brackets each `timed()` call with its own pair of
        /// snapshots so `between()` runs outside the counted window, sums the
        /// per-call deltas, and averages once. Returns per-iteration deltas; an
        /// unavailable source reads `nan` (it propagates through the sum).
        /// `batch` brackets that many iterations per snapshot pair, so the two
        /// `/proc` reads amortize instead of dominating a fast body (the tier-0
        /// analogue of the perf bracket's ioctl cost). Only sound when
        /// `between` is a no-op — the batched rows — so per-call rows keep
        /// `batch == 1`, where this is the original per-iteration loop.
        Tier0Stats count(Timed, Between)(scope Timed timed, scope Between between,
            uint iters, uint batch = 1)
        in (iters > 0)
        {
            Tier0Stats sum; // running sum of raw deltas (nan propagates)
            const k = batch == 0 ? 1 : batch;
            uint done, brackets;
            while (done < iters)
            {
                const n = k < iters - done ? k : iters - done;
                done += n;
                ++brackets;
                const start = snapshot();
                foreach (_; 0 .. n)
                    timed();
                const end = snapshot();
                foreach (_; 0 .. n)
                    between(); // untimed teardown, outside the start..end window
                // Raw (divisor 1): `sum` accumulates the whole pass's counts,
                // which the `1/iters` below turns into a per-iteration average
                // — correct for any batch size.
                const one = deltaStats(start, end, 1);
                sum.minflt += one.minflt;
                sum.majflt += one.majflt;
                sum.volCs += one.volCs;
                sum.involCs += one.involCs;
                sum.syscr += one.syscr;
                sum.syscw += one.syscw;
                sum.rdChars += one.rdChars;
                sum.wrChars += one.wrChars;
                sum.rdBytes += one.rdBytes;
                sum.wrBytes += one.wrBytes;
            }
            const inv = 1.0 / iters;
            sum.iters = iters;
            sum.minflt *= inv;
            sum.majflt *= inv;
            sum.volCs *= inv;
            sum.involCs *= inv;
            sum.syscr *= inv;
            sum.syscw *= inv;
            sum.rdChars *= inv;
            sum.wrChars *= inv;
            sum.rdBytes *= inv;
            sum.wrBytes *= inv;
            // Net of the brackets' own snapshot cost (calibrated at open):
            // without this a no-I/O body reads ~1 syscr and a few hundred
            // rchar bytes per iteration, and `cacheHitPercent`'s "nothing was
            // read → nan" branch is unreachable (rchar always > 0).
            //
            // The calibration is the cost of ONE bracket, and `sum` is now
            // per-iteration — so the amount to remove is one bracket's cost
            // spread over the iterations it covered. At `batch == 1` that is
            // `brackets == iters` and the factor is 1 (the original behaviour);
            // batching lowers it, because a batched pass really does pay the
            // snapshot cost fewer times.
            const costShare = double(brackets) / iters;
            sum.syscr = netOfCost(sum.syscr, selfCost.syscr * costShare);
            sum.syscw = netOfCost(sum.syscw, selfCost.syscw * costShare);
            sum.rdChars = netOfCost(sum.rdChars, selfCost.rdChars * costShare);
            sum.wrChars = netOfCost(sum.wrChars, selfCost.wrChars * costShare);
            return sum;
        }

        /// The tier-0 deltas across one window, as window $(B totals)
        /// (`iters = 1`), net of a single bracket's calibrated snapshot cost.
        Tier0Stats windowStats(in Tier0Reading a, in Tier0Reading b)
            const @safe pure nothrow @nogc
        {
            auto s = deltaStats(a, b, 1);
            s.syscr = netOfCost(s.syscr, selfCost.syscr);
            s.syscw = netOfCost(s.syscw, selfCost.syscw);
            s.rdChars = netOfCost(s.rdChars, selfCost.rdChars);
            s.wrChars = netOfCost(s.wrChars, selfCost.wrChars);
            return s;
        }
    }

    /// Reads `/proc/self/io` into `buf` via a raw `open`/`read`/`close`; returns
    /// the filled slice (empty on failure). `std.file` reports size 0 for `/proc`,
    /// so a direct read is required.
    private char[] readProcSelfIo(return scope char[] buf) @safe nothrow @nogc
    {
        import core.sys.posix.fcntl : open, O_RDONLY;
        import core.sys.posix.unistd : read, close;

        const fd = (() @trusted => open("/proc/self/io", O_RDONLY))();
        if (fd < 0)
            return null;
        scope (exit)
            (() @trusted => close(fd))();
        const n = (() @trusted => read(fd, buf.ptr, buf.length))();
        return n > 0 ? buf[0 .. n] : null;
    }

    @("tier0.Tier0Group.countSmoke")
    @system
    unittest
    {
        auto g = Tier0Group.tryOpen(true);
        assert(g.available);
        // A body that forces at least one write syscall so a count is observable.
        static void body_()
        {
            import core.sys.posix.unistd : write;

            char[1] c = ['x'];
            () @trusted { write(2, c.ptr, 0); }(); // 0-length write to stderr: a syscall, no output
        }

        const s = g.count(&body_, () {}, 64);
        assert(s.iters == 64);
        import std.math : isNaN;
        // On a normal Linux host both sources read; syscall count is non-negative.
        if (!s.syscw.isNaN)
            assert(s.syscw >= 0);
    }

    @("tier0.Tier0Group.countExcludesBetween")
    @system
    unittest
    {
        import std.conv : text;
        import std.math : isNaN;

        // Per-iteration bracketing must exclude the untimed `between` from the
        // window. The same writes count when they run as `timed` but not as
        // `between`. Compare the two so process-wide noise from concurrent test
        // threads (getrusage/proc are per-process) drops out of the DIFFERENCE
        // only on average — the two count() passes run sequentially, so the
        // signal (32 writes/iter) is sized to dwarf any realistic burst of
        // cross-thread write syscalls rather than merely exceed it.
        import sparkles.test_runner.skip : skipTest;

        auto g = Tier0Group.tryOpen(true);
        if (!g.available)
            skipTest("tier-0 counters unavailable");
        static void nop() {}
        static void writeBurst()
        {
            import core.sys.posix.unistd : write;

            char[1] c = ['x'];
            foreach (_; 0 .. 32) // 0-length writes: syscalls, no output
                () @trusted { write(2, c.ptr, 0); }();
        }

        const inTimed = g.count(&writeBurst, &nop, 64); // writes inside the window
        const inBetween = g.count(&nop, &writeBurst, 64); // writes outside the window
        if (!inTimed.syscw.isNaN && !inBetween.syscw.isNaN)
            assert(inTimed.syscw - inBetween.syscw > 16,
                text("writes in timed must count but in between must not; timed=",
                    inTimed.syscw, " between=", inBetween.syscw));
    }

    @("tier0.Tier0Group.selfCostSubtracted")
    @system
    unittest
    {
        import std.conv : text;
        import std.math : isNaN;

        // tryOpen calibrates the per-bracket snapshot cost; count reports net
        // of it. Assert the calibration CONSTANT directly (same-module access
        // to the private field): each empty bracket's own /proc read costs
        // ~1 syscr, so a calibration that measured nothing is broken. The
        // old form compared two sequentially-run count() passes, whose
        // process-wide cross-thread read noise differs between the passes —
        // under a loud parallel suite the comparison flaked.
        auto calibrated = Tier0Group.tryOpen(true);
        import sparkles.test_runner.skip : skipTest;

        if (!calibrated.available)
            skipTest("tier-0 counters unavailable");
        static void nop() {}
        const net = calibrated.count(&nop, &nop, 64);
        if (net.syscr.isNaN)
            skipTest("/proc/self/io unavailable (no per-task I/O accounting)");
        assert(calibrated.selfCost.syscr > 0.5,
            text("calibration must measure the bracket's own read; selfCost.syscr=",
                calibrated.selfCost.syscr));
        // And the subtraction engages: a no-op body nets close to zero, far
        // under the ~1 syscr/iter gross instrumentation constant.
        assert(net.syscr < calibrated.selfCost.syscr,
            text("net (", net.syscr, ") sits below the subtracted constant (",
                calibrated.selfCost.syscr, ")"));
    }
}
else version (OSX)
{
    import core.stdc.config : c_long;
    import core.sys.posix.sys.resource : rusage, RUSAGE_SELF;
    import core.sys.posix.sys.time : timeval;

    import sparkles.test_runner.perf : readRusageInfo, rusage_info_v4;

    /// druntime's Darwin `rusage` hides the BSD tail as `ru_opaque[14]`,
    /// but the kernel always fills it — this is the full `__DARWIN_C_FULL`
    /// layout from the SDK's `sys/resource.h`, bound to the same symbol.
    private struct darwinRusage
    {
        timeval ru_utime;
        timeval ru_stime;
        c_long ru_maxrss;
        c_long ru_ixrss;
        c_long ru_idrss;
        c_long ru_isrss;
        c_long ru_minflt;
        c_long ru_majflt;
        c_long ru_nswap;
        c_long ru_inblock;
        c_long ru_oublock;
        c_long ru_msgsnd;
        c_long ru_msgrcv;
        c_long ru_nsignals;
        c_long ru_nvcsw;
        c_long ru_nivcsw;
    }

    static assert(darwinRusage.sizeof == rusage.sizeof,
        "the named tail must overlay druntime's ru_opaque[14] exactly");

    pragma(mangle, "getrusage")
    private extern (C) int darwinGetrusage(int who, darwinRusage* usage) @nogc nothrow;

    /// The Tier-0 counter group (macOS): `getrusage`'s fault/context-switch
    /// counters plus `proc_pid_rusage`'s lifetime disk-I/O byte counters.
    /// The `/proc/self/io` syscall/character fields have no macOS analog —
    /// they stay `-1` in every reading and `deltaStats`' per-field guard
    /// renders them nan, never fabricated zeros. No calibration: neither
    /// source carries a per-bracket read cost worth netting (the same
    /// reasoning the linux body applies to its fault counters).
    struct Tier0Group
    {
        private bool enabled;

        private static immutable CapabilityAbsence[1] notRequestedAbsence = [
            CapabilityAbsence(Capability.counting, "not requested"),
        ];

        /// Whether Tier-0 counters will be collected (requested).
        bool available() const @safe pure nothrow @nogc => enabled;

        /// Human-readable availability, for a report header.
        string status() const @safe pure nothrow
            => enabled
                ? "getrusage + proc_pid_rusage disk I/O"
                : "unavailable (not requested)";

        /// What this backend can deliver: scalar counting.
        CapabilityReport capabilities() const @safe nothrow
        {
            if (enabled)
                return CapabilityReport(Capability.counting, null);
            return CapabilityReport(Capability.none, notRequestedAbsence[]);
        }

        /// Opens the group unless disabled — nothing can fail here.
        static Tier0Group tryOpen(bool enabled) @safe pure nothrow @nogc
            => Tier0Group(enabled);

        /// Releases nothing — the group holds no descriptors.
        void close() @safe pure nothrow @nogc
        {
        }

        /// Captures one instant's cumulative counters.
        Tier0Reading snapshot() const @safe nothrow @nogc
        {
            Tier0Reading r;
            r.syscr = r.syscw = r.rdChars = r.wrChars = -1; // no macOS analog
            darwinRusage ru;
            if ((() @trusted => darwinGetrusage(RUSAGE_SELF, &ru))() == 0)
            {
                r.minflt = ru.ru_minflt;
                r.majflt = ru.ru_majflt;
                // XNU reports but never maintains ru_nvcsw (probed live on
                // Darwin 25.3: 0 → 0 across 32 explicit sleeps, while
                // minflt/majflt/nivcsw all tick) — a permanently-dead field
                // must be absent, not a confident 0.00 column.
                r.volCs = -1;
                r.involCs = ru.ru_nivcsw;
                r.rusageOk = true;
            }
            rusage_info_v4 info;
            if (readRusageInfo(info))
            {
                r.rdBytes = info.ri_diskio_bytesread;
                r.wrBytes = info.ri_diskio_byteswritten;
                r.ioOk = true;
            }
            else
                r.rdBytes = r.wrBytes = -1;
            return r;
        }

        /// The counting pass: per-iteration snapshot pairs, per-iteration
        /// averages (nan propagates through the sum for absent fields).
        Tier0Stats count(Timed, Between)(scope Timed timed, scope Between between, uint iters)
        in (iters > 0)
        {
            Tier0Stats sum;
            foreach (_; 0 .. iters)
            {
                const start = snapshot();
                timed();
                const end = snapshot();
                between();
                const one = deltaStats(start, end, 1);
                sum.minflt += one.minflt;
                sum.majflt += one.majflt;
                sum.volCs += one.volCs;
                sum.involCs += one.involCs;
                sum.syscr += one.syscr;
                sum.syscw += one.syscw;
                sum.rdChars += one.rdChars;
                sum.wrChars += one.wrChars;
                sum.rdBytes += one.rdBytes;
                sum.wrBytes += one.wrBytes;
            }
            const inv = 1.0 / iters;
            sum.iters = iters;
            sum.minflt *= inv;
            sum.majflt *= inv;
            sum.volCs *= inv;
            sum.involCs *= inv;
            sum.syscr *= inv;
            sum.syscw *= inv;
            sum.rdChars *= inv;
            sum.wrChars *= inv;
            sum.rdBytes *= inv;
            sum.wrBytes *= inv;
            return sum;
        }

        /// The tier-0 deltas across one window, as window totals.
        Tier0Stats windowStats(in Tier0Reading a, in Tier0Reading b)
            const @safe pure nothrow @nogc
            => deltaStats(a, b, 1);
    }

    @("tier0.Tier0Group.darwinSnapshotMonotonic")
    @system
    unittest
    {
        auto g = Tier0Group.tryOpen(true);
        assert(g.available);
        const a = g.snapshot();
        assert(a.rusageOk, "getrusage works on macOS");
        assert(a.syscr == -1, "no /proc/self/io analog — guarded, not zero");
        assert(a.volCs == -1, "XNU never maintains ru_nvcsw — dead, not zero");

        // Fault in fresh pages so the maintained fields provably MOVE — a
        // reported-but-dead counter must never masquerade as a live one.
        auto pages = new ubyte[](4 << 20);
        pages[] = 0xab;
        const b = g.snapshot();
        import std.math : isNaN;

        const s = g.windowStats(a, b);
        assert(s.syscr.isNaN && s.rdChars.isNaN && s.volCs.isNaN,
            "absent/dead fields are nan, never fabricated zeros");
        assert(!s.minflt.isNaN, "the rusage fields are real");
        assert(s.minflt > 0, "4 MiB of faulted pages moves minflt");
        assert(pages[0] == 0xab);
        if (a.ioOk)
            assert(b.rdBytes >= a.rdBytes, "disk-I/O bytes are monotonic");
    }
}
else
{
    /// Non-Linux, non-macOS stub: Tier-0 counters are permanently
    /// unavailable.
    struct Tier0Group
    {
        private static immutable CapabilityAbsence[1] stubAbsence = [
            CapabilityAbsence(Capability.counting, "not Linux"),
        ];

        bool available() const @safe pure nothrow @nogc => false;
        string status() const @safe pure nothrow => "unavailable (not Linux)";
        CapabilityReport capabilities() const @safe pure nothrow @nogc
            => CapabilityReport(Capability.none, stubAbsence[]);
        static Tier0Group tryOpen(bool) @safe pure nothrow @nogc => Tier0Group();
        void close() @safe pure nothrow @nogc {}

        Tier0Stats count(Timed, Between)(scope Timed, scope Between, uint)
        {
            assert(false, "Tier-0 counters are Linux-only");
        }

        Tier0Reading snapshot() @safe pure nothrow @nogc => Tier0Reading();

        Tier0Stats windowStats(in Tier0Reading, in Tier0Reading)
            const @safe pure nothrow @nogc
            => assert(false, "Tier-0 counters are Linux-only");
    }
}

/// A counter net of its calibrated per-bracket cost, clamped at zero;
/// `nan` (source unavailable) passes through untouched. Platform-neutral:
/// the darwin perf body (proc_pid_rusage fixed counters) nets its bracket
/// cost through the same helper.
package double netOfCost(double total, double cost) @safe pure nothrow @nogc
{
    import std.algorithm.comparison : max;
    import std.math : isNaN;

    return total.isNaN ? total : max(0.0, total - cost);
}

@("tier0.netOfCost")
@safe pure nothrow @nogc
unittest
{
    import std.math : isNaN;

    assert(netOfCost(3.0, 1.0) == 2.0);
    assert(netOfCost(0.5, 1.0) == 0.0, "clamped: never negative");
    assert(netOfCost(double.nan, 1.0).isNaN, "unavailable stays unavailable");
}

// Whichever body the platform built (real or stub) satisfies the backend
// contract, including the optional snapshot/delta primitive.
static assert(isCounterBackend!Tier0Group);
static assert(hasSnapshot!Tier0Group);
static assert(!hasNamedColumns!Tier0Group);

@("tier0.Tier0Group.capabilities")
@safe
unittest
{
    // Linux and macOS both have real bodies with the same contract; every
    // other platform is the permanently-unavailable stub.
    bool realBody;
    version (linux)
        realBody = true;
    version (OSX)
        realBody = true;

    auto off = Tier0Group.tryOpen(false);
    assert(!off.capabilities.has(Capability.counting));
    if (realBody)
    {
        assert(off.capabilities.reasonFor(Capability.counting) == "not requested");
        auto on = Tier0Group.tryOpen(true);
        scope (exit)
            on.close();
        assert(on.capabilities.has(Capability.counting));
        assert(on.capabilities.reasonFor(Capability.counting) is null);
    }
    else
        assert(off.capabilities.reasonFor(Capability.counting) == "not Linux");
}
