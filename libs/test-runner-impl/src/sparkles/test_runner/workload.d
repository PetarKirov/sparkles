/**
 * The `@workload` window measurement model: one window, counter deltas.
 *
 * Where `@benchmark` runs a body many times and reports per-iteration
 * statistics, a workload runs once (or a few reps) and reports what happened
 * $(I across the window): every open counter source's delta between two edge
 * snapshots, plus a wall-clock decomposition into on-CPU time (rusage),
 * runqueue wait (schedstat), and a clamped residual. Sources are read
 * cumulatively at the edges (no per-iteration ioctl bracket, no `RESET` —
 * see `sparkles.test_runner.perf_group.GroupSnapshot`), so the driver's
 * whole-body candidate window and in-body `workloadWindow` calls overlap
 * freely in a single pass — a workload body is never re-run for counting,
 * because it may be expensive or non-idempotent.
 *
 * Edge-snapshot nesting order (outer → inner): psi, wall clock, wall
 * source (rusage/schedstat), syscalls, raw, tier-0, perf — so the cycle
 * counters see only the body, and each tier's window contains at most the
 * inner tiers' edge reads (a handful of syscalls per edge, negligible at
 * window granularity and disclosed here rather than hidden). Psi sits
 * outermost — outside even the wall clock and rusage windows — so its six
 * file reads per edge (~20 µs) contribute zero apparatus anywhere in the
 * decomposition; a system-wide µs-resolution integral's own window being a
 * few µs wider than the wall clock is immaterial.
 *
 * Decomposition honesty: only runqueue wait is a true per-cause duration
 * today; everything else off-CPU — locks, sleeps, disk — lands in
 * `offCpuOtherNs`, which clamps at zero and says so in `note` rather than
 * fabricating a cause. PSI stall integrals ride alongside as $(B system-wide
 * diagnostics) (`WorkloadWindow.psi`) — `/proc/pressure` cannot attribute to
 * the measured thread, so disk attribution waits for M8's cgroup scoping.
 * On Linux the decomposition is $(B thread-scoped) (`RUSAGE_THREAD` +
 * `/proc/thread-self/schedstat` — the only scoping under which
 * `wall = onCpu + runqueue + other` is arithmetically meaningful); the
 * process-wide reading is captured too, purely to disclose CPU burned by
 * other threads. Thread coverage caveats (counters follow clone inheritance,
 * the decomposition follows the driving thread) match the bench modes.
 */
module sparkles.test_runner.workload;

import std.math : isNaN;
import std.typecons : Nullable;

// The `workload` attribute struct shares its name with this module; the
// rename keeps the dogfood test's UDA unambiguous (discovery matches the
// UDA by type, not name).
import sparkles.test_runner.attributes : CacheRegime, workloadUda = workload;
import sparkles.test_runner.cache_regime : applyCold, applyWarm,
    CacheRegimeStamp, FsKind, fsKind, probeResidency, resolveStamp;
import sparkles.test_runner.bench : BenchConfig, CounterGroups, elapsedNs, errorCell;
import sparkles.test_runner.capability : BackendCapabilities, Capability,
    CapabilityAbsence, CapabilityReport;
import sparkles.test_runner.execution : executeTest, toThrown;
import sparkles.test_runner.model : Test, TestResult, Thrown;
import sparkles.test_runner.perf : PerfStats;
import sparkles.test_runner.psi : PsiReading, PsiSource;
import sparkles.test_runner.raw : RawStats;
import sparkles.test_runner.skip : TestSkipped;
import sparkles.test_runner.syscalls : SyscallStats;
import sparkles.test_runner.tier0 : Tier0Stats;

// ─────────────────────────────────────────────────────────────────────────────
// The wall source: rusage CPU times + schedstat runqueue wait
// ─────────────────────────────────────────────────────────────────────────────

/// One parsed `/proc/<tid>/schedstat` reading: three integers — cumulative
/// on-CPU nanoseconds, cumulative runqueue-wait nanoseconds, timeslice count.
struct SchedstatReading
{
    ulong onCpuNs;
    ulong runqueueNs;
    ulong timeslices;
    bool ok; /// `false` = file unreadable or malformed
}

/// Parses a schedstat line (`"123456 78901 42\n"`); `ok` is `false` on any
/// missing or non-numeric field.
SchedstatReading parseSchedstat(scope const(char)[] content) @safe pure nothrow @nogc
{
    SchedstatReading r;
    ulong[3] vals;
    size_t i;
    foreach (field; 0 .. 3)
    {
        while (i < content.length && (content[i] == ' ' || content[i] == '\t'))
            i++;
        if (i >= content.length || content[i] < '0' || content[i] > '9')
            return r;
        ulong v = 0;
        while (i < content.length && content[i] >= '0' && content[i] <= '9')
        {
            v = v * 10 + (content[i] - '0');
            i++;
        }
        vals[field] = v;
    }
    r.onCpuNs = vals[0];
    r.runqueueNs = vals[1];
    r.timeslices = vals[2];
    r.ok = true;
    return r;
}

@("workload.parseSchedstat")
@safe pure nothrow @nogc
unittest
{
    const r = parseSchedstat("123456789 5000000 321\n");
    assert(r.ok);
    assert(r.onCpuNs == 123_456_789);
    assert(r.runqueueNs == 5_000_000);
    assert(r.timeslices == 321);

    assert(!parseSchedstat("").ok);
    assert(!parseSchedstat("12 34").ok, "two fields are not a schedstat line");
    assert(!parseSchedstat("a b c").ok);
    assert(parseSchedstat("0 0 0").ok, "zeros are a valid fresh task");
}

/// One instant's cumulative CPU-time/scheduler reading. `-1` marks a failed
/// `getrusage` call; the schedstat sub-reading carries its own `ok`.
struct WallReading
{
    long threadUserUs = -1; /// `RUSAGE_THREAD` (Linux; -1 elsewhere)
    long threadSysUs = -1;
    long procUserUs = -1; /// `RUSAGE_SELF` — cross-thread disclosure only
    long procSysUs = -1;
    SchedstatReading sched;
}

version (linux)
    private enum int rusageThread = 1; // RUSAGE_THREAD: stable Linux ABI, not in druntime

/// The wall-decomposition source: snapshot-shaped like the counter tiers
/// (`tryOpen`/`available`/`status`/`capabilities`/`close`/`snapshot`), but
/// with no counting pass — it exists only for window edges.
struct WallSource
{
    private bool enabled;
    private bool threadOk_; /// RUSAGE_THREAD works (probed once; sandboxes may refuse it)
    private bool schedOk_;
    private string schedReason_;

    private static immutable CapabilityAbsence[1] notRequestedAbsence = [
        CapabilityAbsence(Capability.counting, "not requested"),
    ];
    private static immutable CapabilityAbsence[1] stubAbsence = [
        CapabilityAbsence(Capability.counting, "getrusage unavailable (not POSIX)"),
    ];

    /// Whether the source was requested (rusage itself is assumed on POSIX).
    bool available() const @safe pure nothrow @nogc
    {
        version (Posix)
            return enabled;
        else
            return false;
    }

    /// Whether runqueue attribution is available on this host.
    package bool schedOk() const @safe pure nothrow @nogc => schedOk_;

    /// Why runqueue attribution is unavailable (empty when it works).
    package string schedReason() const @safe pure nothrow @nogc => schedReason_;

    /// The scoping of the decomposition this source supports on this host:
    /// thread-scoped when `RUSAGE_THREAD` works, else the process-scoped
    /// fallback (a sandbox refusing RUSAGE_THREAD must not cost the whole
    /// on-CPU split — for the single-threaded workload phase the two agree).
    string scopeName() const @safe pure nothrow @nogc
    {
        version (linux)
            return threadOk_ ? "thread" : "process";
        else version (Posix)
            return "process";
        else
            return "none";
    }

    /// Human-readable availability, for a report header.
    string status() const @safe pure nothrow
    {
        if (!available)
        {
            version (Posix)
                return "unavailable (not requested)";
            else
                return "unavailable (getrusage unavailable — not POSIX)";
        }
        version (linux)
        {
            const base = threadOk_
                ? "thread-scoped getrusage"
                : "process-scoped getrusage (RUSAGE_THREAD refused)";
            return schedOk_
                ? base ~ " + schedstat"
                : base ~ "; runqueue unattributed (" ~ schedReason_ ~ ")";
        }
        else
            return "process-scoped getrusage; runqueue unattributed (not Linux)";
    }

    /// What this source can deliver: scalar counting of CPU/scheduler time.
    /// Schedstat absence is deliberately NOT a `CapabilityAbsence` — the
    /// report cannot hold `counting` as both present (rusage) and absent
    /// (schedstat); the narrower fact surfaces via `status()`, one stderr
    /// disclosure per run, and a per-window note instead.
    CapabilityReport capabilities() const @safe nothrow
    {
        if (available)
            return CapabilityReport(Capability.counting, null);
        version (Posix)
            return CapabilityReport(Capability.none, notRequestedAbsence[]);
        else
            return CapabilityReport(Capability.none, stubAbsence[]);
    }

    /// Opens the source unless disabled; probes schedstat readability once.
    static WallSource tryOpen(bool enabled) @safe nothrow
    {
        WallSource w;
        w.enabled = enabled;
        if (!enabled)
            return w;
        version (linux)
        {
            import core.sys.posix.sys.resource : getrusage, rusage;

            rusage probe;
            w.threadOk_ = (() @trusted => getrusage(rusageThread, &probe))() == 0;
            char[128] buf = void;
            w.schedOk_ = readThreadSchedstat(buf[]).ok;
            w.schedReason_ = w.schedOk_
                ? null : "/proc/thread-self/schedstat unreadable — CONFIG_SCHED_INFO=n or hardened /proc";
        }
        else
        {
            w.schedReason_ = "not Linux";
        }
        return w;
    }

    /// Releases nothing — the source holds no descriptors.
    void close() @safe pure nothrow @nogc
    {
    }

    /// Captures one window-edge reading.
    WallReading snapshot() const @safe nothrow @nogc
    {
        WallReading r;
        version (Posix)
        {
            import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;

            rusage ru;
            version (linux)
            {
                if (threadOk_ && (() @trusted => getrusage(rusageThread, &ru))() == 0)
                {
                    r.threadUserUs = ru.ru_utime.tv_sec * 1_000_000L + ru.ru_utime.tv_usec;
                    r.threadSysUs = ru.ru_stime.tv_sec * 1_000_000L + ru.ru_stime.tv_usec;
                }
            }
            if ((() @trusted => getrusage(RUSAGE_SELF, &ru))() == 0)
            {
                r.procUserUs = ru.ru_utime.tv_sec * 1_000_000L + ru.ru_utime.tv_usec;
                r.procSysUs = ru.ru_stime.tv_sec * 1_000_000L + ru.ru_stime.tv_usec;
            }
        }
        version (linux)
        {
            if (schedOk_)
            {
                char[128] buf = void;
                r.sched = readThreadSchedstat(buf[]);
            }
        }
        return r;
    }
}

version (linux)
{
    /// Reads the calling thread's schedstat (`/proc/thread-self/schedstat`,
    /// 3.17+), falling back to `/proc/self/schedstat` (identical for the main
    /// thread, where the workload phase runs).
    private SchedstatReading readThreadSchedstat(scope char[] buf) @safe nothrow @nogc
    {
        import sparkles.test_runner.capability : readSmallFile;

        auto r = parseSchedstat(readSmallFile("/proc/thread-self/schedstat", buf));
        if (!r.ok)
            r = parseSchedstat(readSmallFile("/proc/self/schedstat", buf));
        return r;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The wall-clock decomposition
// ─────────────────────────────────────────────────────────────────────────────

/// Where one window's wall-clock time went. A `nan` component means
/// $(I unattributable on this host) (its time is included in
/// `offCpuOtherNs`, and `note` says so) — never a measured zero.
struct WallDecomposition
{
    long wallNs; /// the window's wall-clock duration
    double onCpuUserNs = double.nan; /// rusage user time (µs resolution)
    double onCpuKernelNs = double.nan; /// rusage system time
    double offCpuRunqueueNs = double.nan; /// schedstat runqueue wait
    /// Disk-stall attribution — always nan today: `/proc/pressure` is
    /// system-scoped, so a thread-scoped attribution would report other
    /// processes' stalls as this workload's; it lands with M8's
    /// cgroup-scoped PSI. The system-wide integrals ship as diagnostics
    /// (`WorkloadWindow.psi`, the `io-stall` column) meanwhile.
    double offCpuDiskNs = double.nan;
    double offCpuOtherNs = double.nan; /// clamped residual: locks, sleeps, the rest
    string scope_; /// `"thread"` (Linux) or `"process"`
    string note; /// clamp/absence/cross-thread disclosures, `"; "`-joined
}

/// Assembles the decomposition from a window's wall time and its two edge
/// readings. Unattributable components contribute zero to the residual
/// subtraction and append a note (`runqueueAbsenceReason` names why, when
/// the caller knows); the residual clamps at zero, noting the clamp when it
/// discards more than the rusage quantization budget — one scheduler tick
/// (4 ms, the CONFIG_HZ=250 quantum) + 1 % of wall. With
/// `scope_ == "thread"`, process-minus-thread CPU above max(1 ms, 10 % of
/// wall) is disclosed as other-thread CPU.
WallDecomposition assembleDecomposition(long wallNs,
    in WallReading before, in WallReading after, string scope_,
    string runqueueAbsenceReason = null) @safe pure nothrow
{
    WallDecomposition d;
    d.wallNs = wallNs;
    d.scope_ = scope_;

    double attributed = 0;

    const thread = scope_ == "thread";
    const userBefore = thread ? before.threadUserUs : before.procUserUs;
    const userAfter = thread ? after.threadUserUs : after.procUserUs;
    const sysBefore = thread ? before.threadSysUs : before.procSysUs;
    const sysAfter = thread ? after.threadSysUs : after.procSysUs;

    if (userBefore >= 0 && userAfter >= 0)
    {
        d.onCpuUserNs = double(userAfter - userBefore) * 1000;
        d.onCpuKernelNs = double(sysAfter - sysBefore) * 1000;
        attributed += d.onCpuUserNs + d.onCpuKernelNs;
    }
    else
        appendNote(d.note, "on-CPU time unattributed (getrusage unavailable) — included in other");

    if (before.sched.ok && after.sched.ok
        && after.sched.runqueueNs >= before.sched.runqueueNs)
    {
        d.offCpuRunqueueNs = double(after.sched.runqueueNs - before.sched.runqueueNs);
        attributed += d.offCpuRunqueueNs;
    }
    else if (before.sched.ok && after.sched.ok)
    {
        // A backwards cumulative reading means the two edges resolved to
        // different tasks (the thread-self invariant broke) — a zero here
        // would be a fabricated "never waited" claim.
        appendNote(d.note,
            "runqueue wait unattributed (schedstat went backwards — edges from "
            ~ "different tasks?) — included in other");
    }
    else
        appendNote(d.note, "runqueue wait unattributed ("
            ~ (runqueueAbsenceReason.length ? runqueueAbsenceReason : "schedstat unreadable")
            ~ ") — included in other");

    // offCpuDiskNs stays nan: system-scoped PSI cannot attribute to the
    // measured thread — cgroup-scoped attribution lands with M8.

    double other = double(wallNs) - attributed;
    if (other < 0)
    {
        // The silent-clamp budget: rusage's utime/stime split is tick-sampled
        // and rescaled to the task's runtime, so a window can over-read by up
        // to a scheduler tick — 4 ms at CONFIG_HZ=250, the coarsest common
        // distro quantum — plus 1 % skew. That much excess is quantization,
        // not an anomaly worth a note (the model targets long windows, where
        // a tick is noise); cross-thread anomalies have their own disclosure.
        const budget = 4_000_000.0 + double(wallNs) / 100;
        if (-other > budget)
            appendNote(d.note, "on-CPU + runqueue exceed wall by "
                ~ microsString(-other) ~ " µs (clamped)");
        other = 0;
    }
    d.offCpuOtherNs = other;

    // Cross-thread disclosure: the decomposition covers the driving thread;
    // CPU burned elsewhere in the process is a fact worth printing, not an
    // error.
    if (thread && before.procUserUs >= 0 && after.procUserUs >= 0
        && before.threadUserUs >= 0 && after.threadUserUs >= 0)
    {
        const procCpuUs = (after.procUserUs - before.procUserUs)
            + (after.procSysUs - before.procSysUs);
        const threadCpuUs = (after.threadUserUs - before.threadUserUs)
            + (after.threadSysUs - before.threadSysUs);
        const crossNs = double(procCpuUs - threadCpuUs) * 1000;
        const threshold = wallNs / 10 > 1_000_000 ? double(wallNs) / 10 : 1_000_000.0;
        if (crossNs > threshold)
            appendNote(d.note, "process used " ~ microsString(crossNs)
                ~ " µs CPU on other threads — decomposition covers the driving thread");
    }
    return d;
}

/// Joins disclosure notes with `"; "`.
private void appendNote(ref string note, string add) @safe pure nothrow
{
    note = note.length ? note ~ "; " ~ add : add;
}

/// A nanosecond quantity as integral microseconds, for `nothrow` note text.
private string microsString(double ns) @safe pure nothrow
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.writers : writeInteger;

    SmallBuffer!(char, 24) buf;
    writeInteger(buf, cast(long)(ns / 1000));
    return buf[].idup;
}

@("workload.assembleDecomposition.fullAttribution")
@safe pure nothrow
unittest
{
    WallReading a, b;
    a.threadUserUs = 1_000;
    a.threadSysUs = 500;
    b.threadUserUs = 61_000; // +60 ms user
    b.threadSysUs = 20_500; // +20 ms kernel
    a.sched = SchedstatReading(onCpuNs: 0, runqueueNs: 1_000_000, timeslices: 1, ok: true);
    b.sched = SchedstatReading(onCpuNs: 0, runqueueNs: 6_000_000, timeslices: 9, ok: true); // +5 ms

    const d = assembleDecomposition(100_000_000, a, b, "thread");
    assert(d.wallNs == 100_000_000);
    assert(d.onCpuUserNs == 60_000_000.0);
    assert(d.onCpuKernelNs == 20_000_000.0);
    assert(d.offCpuRunqueueNs == 5_000_000.0);
    assert(d.offCpuDiskNs.isNaN,
        "PSI is system-scoped; disk attribution lands with M8 cgroups");
    assert(d.offCpuOtherNs == 15_000_000.0);
    assert(d.scope_ == "thread");
    assert(d.note.length == 0);
}

@("workload.assembleDecomposition.runqueueAbsent")
@safe pure nothrow
unittest
{
    import std.algorithm.searching : canFind;

    WallReading a, b;
    a.threadUserUs = 0;
    a.threadSysUs = 0;
    b.threadUserUs = 80_000; // 80 ms of a 100 ms wall
    b.threadSysUs = 0;

    const d = assembleDecomposition(100_000_000, a, b, "thread");
    assert(d.offCpuRunqueueNs.isNaN);
    assert(d.offCpuOtherNs == 20_000_000.0, "nan runqueue contributes zero");
    assert(d.note.canFind("runqueue wait unattributed"));
}

@("workload.assembleDecomposition.clampAndNote")
@safe pure nothrow
unittest
{
    import std.algorithm.searching : canFind;

    WallReading a, b;
    a.threadUserUs = 0;
    a.threadSysUs = 0;
    b.threadUserUs = 15_000; // 15 ms CPU against a 1 ms wall: beyond a tick
    b.threadSysUs = 0;
    a.sched.ok = b.sched.ok = true;

    const d = assembleDecomposition(1_000_000, a, b, "thread");
    assert(d.offCpuOtherNs == 0, "the residual clamps, never goes negative");
    assert(d.note.canFind("exceed wall"));
    assert(d.note.canFind("(clamped)"));

    // Sub-budget excess (tick-sampled rusage smearing) clamps silently.
    WallReading c = a, e = b;
    e.threadUserUs = 2_500; // 2.5 ms vs 1 ms wall: within the tick budget
    const quiet = assembleDecomposition(1_000_000, c, e, "thread");
    assert(quiet.offCpuOtherNs == 0);
    assert(!quiet.note.canFind("clamped"));
}

@("workload.assembleDecomposition.processScopeAndCrossThread")
@safe pure nothrow
unittest
{
    import std.algorithm.searching : canFind;

    // Process scope reads the RUSAGE_SELF pair.
    WallReading a, b;
    a.procUserUs = 0;
    a.procSysUs = 0;
    b.procUserUs = 30_000;
    b.procSysUs = 10_000;
    const p = assembleDecomposition(100_000_000, a, b, "process");
    assert(p.onCpuUserNs == 30_000_000.0);
    assert(p.onCpuKernelNs == 10_000_000.0);
    assert(p.scope_ == "process");

    // Thread scope with heavy other-thread CPU discloses it.
    WallReading c, e;
    c.threadUserUs = c.threadSysUs = 0;
    e.threadUserUs = 10_000; // thread: 10 ms
    e.threadSysUs = 0;
    c.procUserUs = c.procSysUs = 0;
    e.procUserUs = 90_000; // process: 90 ms — 80 ms elsewhere
    e.procSysUs = 0;
    const t = assembleDecomposition(100_000_000, c, e, "thread");
    assert(t.note.canFind("other threads"));
}

// ─────────────────────────────────────────────────────────────────────────────
// Window results and the in-body primitive
// ─────────────────────────────────────────────────────────────────────────────

/// A window's PSI stall-time deltas, in ns — $(B system-wide) diagnostics
/// ("the system accumulated this much stall concurrently with the window"),
/// never attribution to the measured thread (that lands with M8's
/// cgroup-scoped PSI). `nan` = line absent, edges unreadable, or a
/// backwards accumulator.
struct PsiStats
{
    double ioSomeNs = double.nan; /// ≥ 1 task stalled on io
    double ioFullNs = double.nan; /// all non-idle tasks stalled on io
    double memSomeNs = double.nan;
    double memFullNs = double.nan;
    double cpuSomeNs = double.nan;
    // No cpuFullNs: pinned to 0 at system scope; M8 adds it when cgroup
    // scope makes it meaningful.
}

/// Pure delta assembly between two edge readings. Subtraction happens in
/// long µs BEFORE the double conversion — the absolute accumulators on
/// long-uptime hosts approach 2⁵³ as ns, where double subtraction loses
/// ULPs; the deltas are small and exact.
PsiStats psiWindow(in PsiReading before, in PsiReading after) @safe pure nothrow @nogc
{
    static double someDelta(in typeof(before.io) a, in typeof(before.io) b)
        => a.ok && b.ok && b.someUs >= a.someUs
            ? double(b.someUs - a.someUs) * 1000 : double.nan;
    static double fullDelta(in typeof(before.io) a, in typeof(before.io) b)
        => a.ok && b.ok && a.fullUs >= 0 && b.fullUs >= a.fullUs
            ? double(b.fullUs - a.fullUs) * 1000 : double.nan;

    PsiStats s;
    s.ioSomeNs = someDelta(before.io, after.io);
    s.ioFullNs = fullDelta(before.io, after.io);
    s.memSomeNs = someDelta(before.memory, after.memory);
    s.memFullNs = fullDelta(before.memory, after.memory);
    s.cpuSomeNs = someDelta(before.cpu, after.cpu);
    return s;
}

@("workload.psiWindow.deltas")
@safe pure nothrow @nogc
unittest
{
    import sparkles.test_runner.psi : PsiFileReading;

    PsiReading a, b;
    a.io = PsiFileReading(someUs: 1_000, fullUs: 500, ok: true);
    b.io = PsiFileReading(someUs: 4_000, fullUs: 700, ok: true);
    a.memory = PsiFileReading(someUs: 10, fullUs: -1, ok: true); // no full line
    b.memory = PsiFileReading(someUs: 10, fullUs: -1, ok: true);
    a.cpu = PsiFileReading(someUs: 9, fullUs: 0, ok: true);
    b.cpu = PsiFileReading(someUs: 4, fullUs: 0, ok: true); // backwards

    const s = psiWindow(a, b);
    assert(s.ioSomeNs == 3_000_000.0, "µs deltas convert to ns");
    assert(s.ioFullNs == 200_000.0);
    assert(s.memSomeNs == 0.0, "a zero system delta is a true statement");
    assert(s.memFullNs.isNaN, "absent full line stays nan");
    assert(s.cpuSomeNs.isNaN, "a backwards accumulator is nan, never a number");

    // An unreadable edge poisons only its own file's deltas.
    PsiReading c = a;
    c.io = PsiFileReading.init; // !ok
    const t = psiWindow(c, b);
    assert(t.ioSomeNs.isNaN && t.ioFullNs.isNaN);
    assert(t.memSomeNs == 0.0);
}

/// One measured window. Deliberately NOT `BenchStats`: its per-iteration
/// timing fields would misrepresent a single window — counter stats here are
/// window $(B totals) (`iters == 1`).
struct WorkloadWindow
{
    string name;
    uint reps; /// times the window content ran inside this window
    WallDecomposition wall;
    Nullable!PerfStats perf;
    Nullable!Tier0Stats tier0;
    Nullable!SyscallStats syscalls;
    Nullable!RawStats raw;
    Nullable!PsiStats psi; /// system-wide stall deltas — diagnostics, not attribution
    Nullable!CacheRegimeStamp regime; /// what workloadFiles established for this window
    string error; /// non-empty = error (or, with `skipped`, skip) row
    bool skipped;
}

/// A workload test's windows plus its pass/fail/skip result.
struct WorkloadOutcome
{
    WorkloadWindow[] windows;
    TestResult result;
}

private struct WorkloadContext
{
    string testName;
    uint reps;
    CounterGroups* counters;
    WallSource* wall;
    PsiSource* psi;
    WorkloadWindow[] windows;
    uint[string] nameCounts; /// per-resolved-name occurrence counter (#2, #3, …)
    bool measuring; /// a window is open — nested `workloadWindow` calls run inertly
    WindowEdges candidate; /// the whole-body window's edges (refreshable by workloadFiles)
    Nullable!CacheRegimeStamp pendingStamp; /// the latest workloadFiles stamp
    CacheRegime markerRegime; /// the @workload marker's regime default
    bool prepSkipped; /// a workloadFiles call was refused under `measuring`
    uint candidateRefreshes; /// workloadFiles restarts of the whole-body window
}

/// The active workload measurement, when `runWorkload` is driving this
/// thread's test body (mirrors `bench.d`'s `activeBenchContext`).
private WorkloadContext* activeWorkloadContext;

/// Measures `run` as one window: the window content runs `reps` times (from
/// the `@workload` marker) between two edge snapshots of every open source.
/// Outside a workload measurement (a normal run, a foreign runner, or a
/// `@benchmark` context) the closure runs exactly once, inertly.
///
/// A `skipTest` inside the closure yields a yellow skipped window and the
/// body continues; any other throw records an error window (earlier windows
/// are kept) and propagates, failing the test.
void workloadWindow(DG)(scope DG run)
if (is(typeof(run()) == void))
{
    workloadWindow(null, run);
}

/// ditto, with an explicit window name (rendered as `<test>/<name>`).
void workloadWindow(DG)(string name, scope DG run)
if (is(typeof(run()) == void))
{
    auto ctx = activeWorkloadContext;
    // Inert outside a workload measurement — and inside one that is already
    // measuring a window (a nested call from an instrumented helper, or a
    // late call during the whole-body fallback reps): the enclosing window
    // already counts this work, so a second overlapping row would report it
    // twice.
    if (ctx is null || ctx.measuring)
    {
        run();
        return;
    }
    const base = name.length ? ctx.testName ~ "/" ~ name : ctx.testName;
    const n = ++ctx.nameCounts.require(base, 0);
    const windowName = n == 1 ? base : base ~ "#" ~ uintString(n);
    measureWindow(ctx, windowName, run);
}

/// Establishes the workload's page-cache regime for `paths` NOW — prep
/// (`cold` = fdatasync + fadvise-evict, `warm` = read-through preload,
/// `steadyState` = nothing) plus `mincore` residency verification before
/// and after — and stamps every window measured after this call with the
/// requested-vs-effective outcome. The first overload uses the `@workload`
/// marker's regime; the second overrides it per call. A later call
/// REPLACES the pending stamp (windows carry the stamp active at their
/// open).
///
/// Outside a workload measurement the call does NOTHING at all — no
/// eviction, no preload, no probes (manipulating the page cache during a
/// foreign runner's ordinary test run would be vandalism). Inside an open
/// window (or on a whole-body repetition after the first) prep is SKIPPED
/// and the window's note says so — running it there would sabotage the
/// measurement in flight.
void workloadFiles(scope const(string)[] paths...) @system
{
    auto ctx = activeWorkloadContext;
    if (ctx is null)
        return;
    workloadFilesImpl(ctx, ctx.markerRegime, paths);
}

/// ditto
void workloadFiles(CacheRegime regime, scope const(string)[] paths...) @system
{
    auto ctx = activeWorkloadContext;
    if (ctx is null)
        return;
    workloadFilesImpl(ctx, regime, paths);
}

private void workloadFilesImpl(WorkloadContext* ctx, CacheRegime regime,
    scope const(string)[] paths) @system
{
    import std.math : isNaN;

    if (paths.length == 0)
        return;
    if (ctx.measuring)
    {
        ctx.prepSkipped = true; // consumed with a context-specific note
        return;
    }

    // Filesystem kind across the set: any zfs file makes residency
    // ARC-blind for the aggregate; all-tmpfs keeps the tmpfs rules;
    // otherwise the thresholds apply to the page-weighted aggregate (a
    // mixed set's partial success shows up as a mid-band fraction, which
    // the downgrade note then discloses with its percentage).
    FsKind kind = fsKind(paths[0]);
    bool mixed;
    foreach (path; paths[1 .. $])
    {
        const k = fsKind(path);
        if (k != kind)
            mixed = true;
        if (k == FsKind.zfs)
            kind = FsKind.zfs;
    }
    if (mixed && kind != FsKind.zfs)
        kind = FsKind.other;

    static double aggregate(scope const(string)[] paths) @system
    {
        double total = 0, resident = 0;
        bool any;
        foreach (path; paths)
        {
            const r = probeResidency(path);
            if (r.ok)
            {
                total += double(r.pagesTotal);
                resident += double(r.pagesResident);
                any = true;
            }
        }
        return any && total > 0 ? resident / total : double.nan;
    }

    const residentBefore = aggregate(paths);

    string prepNote;
    if (regime == CacheRegime.cold)
    {
        foreach (path; paths)
            if (const err = applyCold(path))
            {
                appendNote(prepNote, err);
                break; // one reason suffices; the stamp downgrades anyway
            }
    }
    else if (regime == CacheRegime.warm)
    {
        foreach (path; paths)
            if (const err = applyWarm(path))
            {
                appendNote(prepNote, err);
                break;
            }
    }

    // steadyState provably preserves residency — one probe fills both.
    const residentAfter = regime == CacheRegime.steadyState
        ? residentBefore : aggregate(paths);

    auto stamp = resolveStamp(regime, kind, residentBefore, residentAfter, prepNote);
    if (mixed)
        appendNote(stamp.note, "mixed filesystems — residency verification approximate");
    ctx.pendingStamp = Nullable!CacheRegimeStamp(stamp);

    // Prep is setup, never workload: while the whole-body candidate is
    // still live (no windows recorded), re-open its edges so everything
    // above — probes, eviction, preload I/O — stays outside the measured
    // window. The refresh re-reads psi outermost, so prep's own writeback
    // stall also lands outside `psi0`. A SECOND call restarts the window
    // again, discarding real work run between the calls — disclosed on the
    // fallback window rather than silently vanished.
    if (ctx.windows.length == 0)
    {
        ctx.candidate = WindowEdges.open(*ctx.counters, *ctx.wall, *ctx.psi);
        ctx.candidateRefreshes++;
    }
}

private string uintString(uint v) @safe pure nothrow
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.writers : writeInteger;

    SmallBuffer!(char, 12) buf;
    writeInteger(buf, v);
    return buf[].idup;
}

/// The edge snapshots of one window, in the fixed nesting order (outer →
/// inner): psi, wall clock, wall source, syscalls, raw, tier-0, perf.
/// Psi is OUTERMOST: its file reads sit outside every other window,
/// including the wall clock and rusage — zero apparatus anywhere in the
/// decomposition (a system-wide integral's own window being ~20 µs wider
/// than the wall clock is immaterial at µs resolution).
private struct WindowEdges
{
    long t0;
    WallReading wall0;
    PsiReading psi0;
    // Snapshot types differ per platform; let the fields infer from the
    // groups' snapshot() return types.
    typeof(CounterGroups.init.syscalls.snapshot()) sys0;
    typeof(CounterGroups.init.raw.snapshot()) raw0;
    typeof(CounterGroups.init.tier0.snapshot()) tier00;
    typeof(CounterGroups.init.perf.snapshot()) perf0;

    static WindowEdges open(ref CounterGroups counters, ref WallSource wall,
        ref PsiSource psi) @safe
    {
        import core.time : MonoTime;

        WindowEdges e;
        if (psi.available)
            e.psi0 = psi.snapshot(); // before t0: outside the wall clock
        e.t0 = MonoTime.currTime.ticks;
        if (wall.available)
            e.wall0 = wall.snapshot();
        if (counters.syscalls.available)
            e.sys0 = counters.syscalls.snapshot();
        if (counters.raw.available)
            e.raw0 = counters.raw.snapshot();
        if (counters.tier0.available)
            e.tier00 = counters.tier0.snapshot();
        if (counters.perf.available)
            e.perf0 = counters.perf.snapshot();
        return e;
    }

    /// Takes the closing edges (inner → outer) and fills the window's stats.
    /// Raw stats attach whenever events were requested — a fully-refused
    /// group yields all-nan totals, keeping each selected column's em-dash
    /// presence (the contract `countInto` honors).
    void closeInto(ref WorkloadWindow w, ref CounterGroups counters,
        ref WallSource wall, ref PsiSource psi) @safe
    {
        if (counters.perf.available)
            w.perf = counters.perf.windowStats(perf0, counters.perf.snapshot());
        if (counters.tier0.available)
            w.tier0 = counters.tier0.windowStats(tier00, counters.tier0.snapshot());
        if (counters.raw.available || counters.raw.names.length)
            w.raw = counters.raw.windowStats(raw0, counters.raw.snapshot());
        if (counters.syscalls.available)
            w.syscalls = counters.syscalls.windowStats(sys0, counters.syscalls.snapshot());
        const wall1 = wall.available ? wall.snapshot() : WallReading();
        const wallNs = elapsedNs(t0);
        if (psi.available)
            w.psi = psiWindow(psi0, psi.snapshot()); // after elapsedNs: outside the wall clock
        w.wall = assembleDecomposition(wallNs, wall0, wall1, wall.scopeName,
            wall.schedReason);
        if (!wall.available)
            appendNote(w.wall.note, "decomposition unavailable (" ~ wall.status() ~ ")");
        addScaleNotes(w);
    }

    /// One note per source whose window failed a scale gate — the delta was
    /// rejected rather than reported as a number (never-scheduled, or
    /// multiplexed with under 1 ms of PMU time). "Rejected" is probed via
    /// the group's LEADER value (cycles / the syscall total / any raw
    /// value): the leader is open whenever the group is, so its nan can
    /// only mean the whole window was gated — a single refused non-leader
    /// event (nan next to real numbers) never triggers a false note.
    private static void addScaleNotes(ref WorkloadWindow w) @safe pure nothrow
    {
        static void noteFor(ref string note, string source, bool rejected, double scale)
        {
            if (!rejected)
                return;
            if (scale == 0)
                appendNote(note, source ~ ": group never scheduled across the window");
            else if (scale < 1)
                appendNote(note, source
                    ~ ": multiplexed window under 1 ms PMU time — counts dropped");
            // scale == 1 with nan values = read failure/never enabled; the
            // em dash already says "unavailable" and there is no finer fact.
        }

        if (!w.perf.isNull)
            noteFor(w.wall.note, "perf", w.perf.get.cycles.isNaN, w.perf.get.scale);
        if (!w.syscalls.isNull)
            noteFor(w.wall.note, "syscalls", w.syscalls.get.total.isNaN,
                w.syscalls.get.scale);
        if (!w.raw.isNull)
        {
            const r = w.raw.get;
            bool anyValue;
            foreach (v; r.values)
                if (!v.isNaN)
                {
                    anyValue = true;
                    break;
                }
            noteFor(w.wall.note, "raw", r.values.length > 0 && !anyValue, r.scale);
        }
    }
}

/// Measures one window around `run` (× `ctx.reps`) and appends it to the
/// context.
private void measureWindow(DG)(WorkloadContext* ctx, string name, scope DG run)
{
    auto w = WorkloadWindow(name: name, reps: ctx.reps);
    w.regime = ctx.pendingStamp; // the regime active at this window's open
    auto edges = WindowEdges.open(*ctx.counters, *ctx.wall, *ctx.psi);
    ctx.measuring = true;
    scope (exit)
        ctx.measuring = false;
    try
    {
        foreach (_; 0 .. ctx.reps)
            run();
    }
    catch (TestSkipped s)
    {
        w.error = errorCell(s.message.idup);
        w.skipped = true;
        ctx.prepSkipped = false; // this window's refusal must not leak to the next
        ctx.windows ~= w;
        return;
    }
    catch (Throwable t)
    {
        // Record the error window (earlier windows are kept), then let the
        // throw fail the test — the body cannot continue past an unwound
        // closure.
        const thrown = toThrown(t);
        w.error = errorCell(thrown.length
            ? thrown[0].type ~ ": " ~ thrown[0].message : "threw");
        ctx.prepSkipped = false;
        ctx.windows ~= w;
        throw t;
    }
    edges.closeInto(w, *ctx.counters, *ctx.wall, *ctx.psi);
    // Consume-once: the stamp described residency verified at the prep call
    // — this window consumed that state, so a later window without its own
    // workloadFiles call is UNSTAMPED (an em dash prompting a re-prep),
    // never a stale "cold" claim for a run the first window already warmed.
    ctx.pendingStamp.nullify();
    if (ctx.prepSkipped)
    {
        appendNote(w.wall.note,
            "workloadFiles inside a window — prep skipped; call it before the window");
        ctx.prepSkipped = false;
    }
    // The explicit-window twin of the whole-body late-rep disclosure: prep
    // ran once, but reps 2+ execute against the cache state rep 1 left
    // behind — a "cold" stamp on a reps > 1 window is cold for rep 1 only.
    if (ctx.reps > 1 && !w.regime.isNull
        && w.regime.get.requested != CacheRegime.steadyState)
        appendNote(w.wall.note,
            "regime prep ran once — reps 2+ reuse rep 1's cache state");
    ctx.windows ~= w;
}

// ─────────────────────────────────────────────────────────────────────────────
// The driver
// ─────────────────────────────────────────────────────────────────────────────

/// Runs one `@workload` test in a single pass: the perf-family groups are
/// armed once, a whole-body candidate window is opened, and the body runs
/// once. A body that called `workloadWindow` keeps those windows (the
/// candidate is discarded); a body that didn't runs its remaining
/// `reps − 1` repetitions inside the still-open candidate, which closes as
/// the single whole-body window — the body is never re-run for counting.
package(sparkles.test_runner)
WorkloadOutcome runWorkload(Test test, ref CounterGroups counters,
    ref WallSource wall, ref PsiSource psi) @system
{
    const reps = test.traits.workloadReps ? test.traits.workloadReps : 1;

    counters.beginWindows();
    scope (exit)
        counters.endWindows();

    auto ctx = WorkloadContext(testName: test.name, reps: reps,
        counters: &counters, wall: &wall, psi: &psi,
        markerRegime: test.traits.workloadRegime);
    activeWorkloadContext = &ctx;
    scope (exit)
        activeWorkloadContext = null;

    // The whole-body candidate's edges live in the context so a
    // workloadFiles call can refresh them (prep is setup, not workload).
    ctx.candidate = WindowEdges.open(counters, wall, psi);
    auto result = executeTest(test);

    if (result.succeeded && ctx.windows.length == 0)
    {
        // Whole-body fallback: SPEC's "body × reps" — the remaining reps run
        // inside the candidate window the first (already-measured) execution
        // opened. The candidate is now the window being measured: a
        // `workloadWindow` call that only fires on a later rep runs inertly
        // instead of double-reporting work the candidate already counts.
        ctx.measuring = true;
        bool broke;
        foreach (_; 1 .. reps)
        {
            try
                test.ptr();
            catch (TestSkipped s)
            {
                result.succeeded = false;
                result.skipped = true;
                result.skipReason = s.message.idup;
                broke = true;
                break;
            }
            catch (Throwable t)
            {
                result.succeeded = false;
                result.thrown = toThrown(t); // re-throws OutOfMemoryError
                broke = true;
                break;
            }
        }
        if (!broke)
        {
            auto w = WorkloadWindow(name: test.name, reps: reps);
            w.regime = ctx.pendingStamp;
            ctx.candidate.closeInto(w, counters, wall, psi);
            if (ctx.prepSkipped)
                appendNote(w.wall.note, "workloadFiles on a repetition after "
                    ~ "the first — prep ran only before rep 1");
            if (ctx.candidateRefreshes > 1)
                appendNote(w.wall.note, "whole-body window restarted by a later "
                    ~ "workloadFiles call — only work after the last call is "
                    ~ "measured (use explicit windows for multi-regime bodies)");
            ctx.windows ~= w;
        }
    }
    return WorkloadOutcome(ctx.windows, result);
}

/// Inserts the workload-phase sources' capability blocks among the counter
/// backends (after `raw`, before `pfm`) for `--list-metrics`. They belong
/// in the capability report, but deliberately not in `CounterGroups`' fixed
/// six-backend bench bundle — neither has a counting pass to contribute
/// there.
// `const`, not `in`: dip1000's `scope` would forbid the `capabilities()`
// member calls on the parameters.
BackendCapabilities[] withWorkloadBlocks(BackendCapabilities[] blocks,
    const WallSource wall, const PsiSource psi) @safe nothrow
{
    const wallEntry = BackendCapabilities("wall", wall.capabilities);
    const psiEntry = BackendCapabilities("psi", psi.capabilities);
    foreach (i, ref b; blocks)
        if (b.backend == "pfm")
            return blocks[0 .. i] ~ wallEntry ~ psiEntry ~ blocks[i .. $];
    return blocks ~ wallEntry ~ psiEntry;
}

@("workload.withWorkloadBlocks.insertsBeforePfm")
@safe
unittest
{
    auto blocks = CounterGroups.none.capabilities;
    const merged = withWorkloadBlocks(blocks,
        WallSource.tryOpen(true), PsiSource.tryOpen(true));
    assert(merged.length == blocks.length + 2);
    assert(merged[4].backend == "wall");
    assert(merged[5].backend == "psi");
    assert(merged[6].backend == "pfm");
    assert(merged[7].backend == "harness");
    version (Posix)
    {
        import sparkles.test_runner.capability : Capability, has;

        assert(merged[4].report.has(Capability.counting));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

@("workload.workloadWindow.inertRunsOnce")
@system // the active path catches TestSkipped/Throwable, so the template infers @system
unittest
{
    // Outside a workload measurement the closure runs exactly once — not
    // `reps` times — matching `benchIter`'s inert contract under foreign
    // runners.
    int calls;
    workloadWindow(() { calls++; });
    workloadWindow("named", () { calls++; });
    assert(calls == 2);
}

@("workload.WallSource.snapshotMonotonic")
@system
unittest
{
    auto w = WallSource.tryOpen(true);
    scope (exit)
        w.close();
    version (Posix)
    {
        assert(w.available);
        const a = w.snapshot();
        // Burn a little CPU so the second reading can only be ≥ the first.
        static ulong sink;
        foreach (i; 0 .. 100_000)
            sink += i * i;
        const b = w.snapshot();
        version (linux)
        {
            assert(a.threadUserUs >= 0, "RUSAGE_THREAD reads on Linux");
            assert(b.threadUserUs >= a.threadUserUs);
        }
        assert(a.procUserUs >= 0);
        assert(b.procUserUs >= a.procUserUs);
    }
    else
        assert(!w.available);

    const off = WallSource.tryOpen(false);
    assert(!off.available);
    import sparkles.test_runner.capability : Capability, has;

    assert(!off.capabilities.has(Capability.counting));
}

version (linux)
{
    @("workload.WallSource.schedstatProbe")
    @system
    unittest
    {
        // On a stock kernel thread-self schedstat parses; a hardened host
        // reports the reason instead of failing.
        auto w = WallSource.tryOpen(true);
        import std.algorithm.searching : canFind;

        if (w.schedOk)
        {
            const s = w.snapshot();
            assert(s.sched.ok);
            assert(w.status.canFind("schedstat"));
        }
        else
            assert(w.schedReason.length, "an absent schedstat carries its reason");
    }
}

@("workload.runWorkload.inBodyWindows")
@system
unittest
{
    import sparkles.test_runner.model : TestTraits;

    static void body_()
    {
        static ulong sink;
        workloadWindow("first", () { sink += 1; });
        workloadWindow(() { sink += 1; });
        workloadWindow(() { sink += 1; });
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false); // disabled: window shapes stay host-independent
    const outcome = runWorkload(
        Test(fullName: "m.w", name: "demo", ptr: &body_,
            traits: TestTraits(isWorkload: true, workloadReps: 2)),
        counters, wall, psi);

    assert(outcome.result.succeeded);
    assert(outcome.windows.length == 3, "the whole-body candidate is discarded");
    assert(outcome.windows[0].name == "demo/first");
    assert(outcome.windows[1].name == "demo");
    assert(outcome.windows[2].name == "demo#2");
    assert(outcome.windows[0].reps == 2);
    assert(outcome.windows[0].wall.wallNs >= 0);
    assert(outcome.windows[0].perf.isNull, "no counters requested → none attached");
}

@("workload.runWorkload.wholeBodyFallback")
@system
unittest
{
    import sparkles.test_runner.model : TestTraits;

    static int bodyRuns;
    bodyRuns = 0;
    static void plain()
    {
        bodyRuns++;
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false); // disabled: window shapes stay host-independent
    const outcome = runWorkload(
        Test(fullName: "m.p", name: "plain", ptr: &plain,
            traits: TestTraits(isWorkload: true, workloadReps: 3)),
        counters, wall, psi);

    assert(outcome.result.succeeded);
    assert(bodyRuns == 3, "reps run in the same pass — the body is never re-run for counting");
    assert(outcome.windows.length == 1);
    assert(outcome.windows[0].name == "plain");
    assert(outcome.windows[0].reps == 3);
}

@("workload.workloadWindow.nestedAndCollidingNames")
@system
unittest
{
    import sparkles.test_runner.model : TestTraits;

    static int innerRuns;
    innerRuns = 0;
    static void body_()
    {
        workloadWindow("outer", () {
            // Nested: the enclosing window already counts this work — the
            // inner call must run inertly (once per rep), not append
            // overlapping duplicate rows.
            workloadWindow("inner", () { innerRuns++; });
        });
        workloadWindow("outer", () {}); // named collision → #2
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false); // disabled: window shapes stay host-independent
    const outcome = runWorkload(
        Test(fullName: "m.n", name: "n", ptr: &body_,
            traits: TestTraits(isWorkload: true, workloadReps: 2)),
        counters, wall, psi);

    assert(outcome.result.succeeded);
    assert(outcome.windows.length == 2, "the nested call adds no row");
    assert(outcome.windows[0].name == "n/outer");
    assert(outcome.windows[1].name == "n/outer#2", "colliding names disambiguate");
    assert(innerRuns == 2, "the nested closure ran once per rep of the outer window");
}

@("workload.runWorkload.lateWindowStaysInert")
@system
unittest
{
    import sparkles.test_runner.model : TestTraits;

    // A window call that only fires on a later rep (state-guarded body):
    // the whole-body candidate is already measuring those reps, so the late
    // call must not add rows the candidate double-counts.
    static bool ready;
    static int runs;
    ready = false;
    runs = 0;
    static void lazyBody()
    {
        runs++;
        if (ready)
            workloadWindow("steady", () {});
        else
            ready = true;
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false); // disabled: window shapes stay host-independent
    const outcome = runWorkload(
        Test(fullName: "m.l", name: "lazy", ptr: &lazyBody,
            traits: TestTraits(isWorkload: true, workloadReps: 3)),
        counters, wall, psi);

    assert(outcome.result.succeeded);
    assert(runs == 3);
    assert(outcome.windows.length == 1, "one whole-body window, no late extras");
    assert(outcome.windows[0].name == "lazy");
}

@("workload.assembleDecomposition.backwardsSchedstat")
@safe pure nothrow
unittest
{
    import std.algorithm.searching : canFind;

    // A backwards cumulative runqueue reading (edges resolved to different
    // tasks) must be unattributable — a 0 would claim "never waited".
    WallReading a, b;
    a.threadUserUs = a.threadSysUs = 0;
    b.threadUserUs = 50_000;
    b.threadSysUs = 0;
    a.sched = SchedstatReading(onCpuNs: 9, runqueueNs: 9_000_000, timeslices: 9, ok: true);
    b.sched = SchedstatReading(onCpuNs: 1, runqueueNs: 1_000_000, timeslices: 1, ok: true);

    const d = assembleDecomposition(100_000_000, a, b, "thread");
    assert(d.offCpuRunqueueNs.isNaN, "backwards delta is nan, never a fabricated 0");
    assert(d.note.canFind("backwards"));

    // The caller-supplied absence reason lands in the note verbatim.
    WallReading c, e;
    c.threadUserUs = c.threadSysUs = 0;
    e.threadUserUs = 1_000;
    e.threadSysUs = 0;
    const p = assembleDecomposition(1_000_000, c, e, "thread", "not Linux");
    assert(p.note.canFind("runqueue wait unattributed (not Linux)"));
}

version (linux)
{
    @("workload.runWorkload.psiDiagnostics")
    @system
    unittest
    {
        import sparkles.test_runner.model : TestTraits;

        static void body_()
        {
            static ulong sink;
            foreach (i; 0 .. 100_000)
                sink += i * i;
        }

        auto counters = CounterGroups.none;
        auto wall = WallSource.tryOpen(true);
        auto psi = PsiSource.tryOpen(true);
        const outcome = runWorkload(
            Test(fullName: "m.psi", name: "psi-demo", ptr: &body_,
                traits: TestTraits(isWorkload: true, workloadReps: 1)),
            counters, wall, psi);

        assert(outcome.result.succeeded);
        const w = outcome.windows[0];
        if (!psi.available)
        {
            assert(w.psi.isNull, "no PSI host → no psi object");
            return; // CONFIG_PSI=n / psi=0 — degradation is the assertion
        }
        assert(!w.psi.isNull, "a PSI host attaches window deltas");
        const p = w.psi.get;
        assert(p.ioSomeNs.isNaN || p.ioSomeNs >= 0);
        assert(p.cpuSomeNs.isNaN || p.cpuSomeNs >= 0);
        // The honesty core of M5: the system-wide integral never leaks into
        // the decomposition.
        assert(w.wall.offCpuDiskNs.isNaN,
            "disk attribution stays unattributed until M8's cgroup scoping");
    }
}

@("workload.workloadFiles.inertDoesNothing")
@system
unittest
{
    // Outside a measurement the call must be a complete no-op — no
    // eviction, no preload, no probes. Observable: it neither throws nor
    // requires the paths to exist.
    workloadFiles("/nonexistent/never/created");
    workloadFiles(CacheRegime.cold, "/nonexistent/never/created");
}

@("workload.workloadFiles.stampsAndReplacement")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : deleteme, remove, write;
    import sparkles.test_runner.model : TestTraits;

    static string fileA, fileB;
    fileA = deleteme ~ ".regime-a";
    fileB = deleteme ~ ".regime-b";
    write(fileA, new ubyte[](256 * 1024));
    write(fileB, new ubyte[](256 * 1024));
    scope (exit)
    {
        remove(fileA);
        remove(fileB);
    }

    static void body_()
    {
        workloadFiles(CacheRegime.warm, fileA);
        workloadWindow("first", () {});
        workloadFiles(CacheRegime.steadyState, fileB);
        workloadWindow("second", () {});
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false);
    const outcome = runWorkload(
        Test(fullName: "m.st", name: "st", ptr: &body_,
            traits: TestTraits(isWorkload: true, workloadReps: 1)),
        counters, wall, psi);

    assert(outcome.result.succeeded);
    assert(outcome.windows.length == 2);
    // Each window carries the stamp active at ITS open — replacement, not merge.
    assert(!outcome.windows[0].regime.isNull);
    assert(outcome.windows[0].regime.get.requested == CacheRegime.warm);
    assert(!outcome.windows[1].regime.isNull);
    assert(outcome.windows[1].regime.get.requested == CacheRegime.steadyState);
    // A steadyState stamp fills both fractions from one probe.
    const st = outcome.windows[1].regime.get;
    version (Posix)
        assert(st.residentBefore is st.residentAfter
            || st.residentBefore == st.residentAfter);
}

@("workload.workloadFiles.wholeBodyStampAndRefresh")
@system
unittest
{
    import core.thread : Thread;
    import core.time : msecs, MonoTime;
    import std.file : deleteme, remove, write;
    import sparkles.test_runner.model : TestTraits;

    static string file;
    file = deleteme ~ ".regime-refresh";
    write(file, new ubyte[](64 * 1024));
    scope (exit)
        remove(file);

    // The refresh proof, deterministic and counter-free: the body sleeps
    // 20 ms BEFORE workloadFiles, then works ~5 ms. Without the candidate
    // refresh the whole-body window would read ≥ 25 ms; with it, the
    // sleep and the prep are outside the measured window.
    static void body_()
    {
        Thread.sleep(20.msecs);
        workloadFiles(file); // marker regime (steadyState here)
        static ulong sink;
        const t0 = MonoTime.currTime;
        while (MonoTime.currTime - t0 < 5.msecs)
            foreach (i; 0 .. 1000)
                sink += i * i;
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false);
    const outcome = runWorkload(
        Test(fullName: "m.rf", name: "rf", ptr: &body_,
            traits: TestTraits(isWorkload: true, workloadReps: 1)),
        counters, wall, psi);

    assert(outcome.result.succeeded);
    assert(outcome.windows.length == 1, "whole-body fallback window");
    const w = outcome.windows[0];
    assert(!w.regime.isNull, "the whole-body window carries the stamp");
    assert(w.wall.wallNs < 20_000_000,
        "the candidate was refreshed after prep — the pre-prep sleep is setup, not workload");
    assert(w.wall.wallNs >= 4_000_000, "the post-prep work IS measured");
}

@("workload.workloadFiles.midWindowPrepSkipped")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : deleteme, remove, write;
    import sparkles.test_runner.model : TestTraits;

    static string file;
    file = deleteme ~ ".regime-midwindow";
    write(file, new ubyte[](64 * 1024));
    scope (exit)
        remove(file);

    static void body_()
    {
        workloadWindow("w", () {
            workloadFiles(CacheRegime.cold, file); // mid-window: prep must not run
        });
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false);
    const outcome = runWorkload(
        Test(fullName: "m.mw", name: "mw", ptr: &body_,
            traits: TestTraits(isWorkload: true, workloadReps: 1)),
        counters, wall, psi);

    assert(outcome.result.succeeded);
    assert(outcome.windows.length == 1);
    const w = outcome.windows[0];
    assert(w.regime.isNull, "no stamp — prep never ran");
    assert(w.wall.note.canFind("prep skipped"),
        "the refusal is disclosed on the window, never silent");
}

version (linux)
{
    @("workload.workloadFiles.coldVsWarmAcceptance")
    @system
    unittest
    {
        import std.conv : text;
        import std.file : deleteme, remove, tempDir, write;
        import std.math : isNaN;
        import sparkles.test_runner.model : TestTraits;
        import sparkles.test_runner.skip : skipTest;

        // THE M6 acceptance: a cold window's block-device reads dwarf a
        // warm window's for the same body. Only meaningful on a filesystem
        // where fadvise evicts AND /proc/self/io sees block reads — tmpfs
        // has no I/O, zfs serves from ARC (mincore- and io-accounting-blind).
        const kind = fsKind(tempDir);
        if (kind != FsKind.other)
            skipTest(text("tempDir is ", kind, " — cold-vs-warm needs a plain fs"));

        auto counters = CounterGroups.open(false, true, false, null);
        scope (exit)
            counters.close();
        if (!counters.tier0.available)
            skipTest("tier-0 counters unavailable");

        static string file;
        file = deleteme ~ ".regime-acceptance";
        enum size = 64 << 20;
        write(file, new ubyte[](size));
        scope (exit)
            remove(file);

        static void body_()
        {
            static void readAll()
            {
                import std.stdio : File;

                auto f = File(file, "rb");
                ubyte[64 * 1024] buf = void;
                while (f.rawRead(buf[]).length == buf.length)
                {
                }
            }

            workloadFiles(CacheRegime.cold, file);
            workloadWindow("cold", &readAll);
            workloadFiles(CacheRegime.warm, file);
            workloadWindow("warm", &readAll);
        }

        auto wall = WallSource.tryOpen(true);
        auto psi = PsiSource.tryOpen(false);
        const outcome = runWorkload(
            Test(fullName: "m.cw", name: "cw", ptr: &body_,
                traits: TestTraits(isWorkload: true, workloadReps: 1)),
            counters, wall, psi);

        assert(outcome.result.succeeded);
        const coldW = outcome.windows[0];
        const warmW = outcome.windows[1];
        assert(coldW.regime.get.effective == CacheRegime.cold,
            text("cold established: ", coldW.regime.get.note));
        assert(warmW.regime.get.effective == CacheRegime.warm,
            text("warm established: ", warmW.regime.get.note));

        const coldRd = coldW.tier0.get.rdBytes;
        const warmRd = warmW.tier0.get.rdBytes;
        if (coldRd.isNaN || warmRd.isNaN)
            skipTest("block-device read accounting unavailable");
        assert(coldRd >= size / 2,
            text("a cold read hits the device: rdBytes=", coldRd));
        assert(coldRd > 10 * (warmRd + 1),
            text("cold reads dwarf warm ones: cold=", coldRd, " warm=", warmRd));
    }
}

@("workload.runWorkload.windowThrowKeepsEarlierWindows")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.test_runner.model : TestTraits;

    static void thrower()
    {
        workloadWindow("ok", () {});
        workloadWindow("bad", () { throw new Exception("boom"); });
        assert(false, "unreachable — the window throw unwinds the body");
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false); // disabled: window shapes stay host-independent
    const outcome = runWorkload(
        Test(fullName: "m.t", name: "t", ptr: &thrower,
            traits: TestTraits(isWorkload: true, workloadReps: 1)),
        counters, wall, psi);

    assert(!outcome.result.succeeded);
    assert(outcome.result.thrown.length, "the throw fails the test with its trace");
    assert(outcome.windows.length == 2, "the good window survives");
    assert(outcome.windows[0].name == "t/ok" && outcome.windows[0].error.length == 0);
    assert(outcome.windows[1].name == "t/bad");
    assert(outcome.windows[1].error.canFind("boom"));
    assert(!outcome.windows[1].skipped);
}

@("workload.runWorkload.windowSkipContinuesBody")
@system
unittest
{
    import sparkles.test_runner.model : TestTraits;
    import sparkles.test_runner.skip : skipTest;

    static void skipper()
    {
        workloadWindow("skippy", () { skipTest("no hardware"); });
        workloadWindow("after", () {});
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false); // disabled: window shapes stay host-independent
    const outcome = runWorkload(
        Test(fullName: "m.s", name: "s", ptr: &skipper,
            traits: TestTraits(isWorkload: true, workloadReps: 1)),
        counters, wall, psi);

    assert(outcome.result.succeeded, "a window-level skip does not fail the test");
    assert(outcome.windows.length == 2);
    assert(outcome.windows[0].skipped);
    assert(outcome.windows[0].error == "no hardware");
    assert(outcome.windows[1].error.length == 0, "the body continues past a skipped window");
}

@("workload.runWorkload.testLevelSkip")
@system
unittest
{
    import sparkles.test_runner.model : TestTraits;
    import sparkles.test_runner.skip : skipTest;

    static void skipAll()
    {
        skipTest("whole test skipped");
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false); // disabled: window shapes stay host-independent
    const outcome = runWorkload(
        Test(fullName: "m.sa", name: "sa", ptr: &skipAll,
            traits: TestTraits(isWorkload: true, workloadReps: 2)),
        counters, wall, psi);

    assert(outcome.result.skipped);
    assert(outcome.windows.length == 0, "no fabricated window for a skipped body");
}

version (linux)
{
    @("workload.decomposition.spinIsOnCpu")
    @system
    unittest
    {
        import core.time : MonoTime, msecs;
        import sparkles.test_runner.model : TestTraits;

        // The honesty pair, part 1: a pure spin's wall time is on-CPU time.
        static void spin()
        {
            static ulong sink;
            const t0 = MonoTime.currTime;
            while (MonoTime.currTime - t0 < 30.msecs)
                foreach (i; 0 .. 10_000)
                    sink += i * i;
        }

        // Neighboring parallel tests allocate tens of MiB; a GC
        // stop-the-world during the spin window suspends this thread and
        // the pause lands (honestly) in `other` — disable collections for
        // the window so the test measures the spin, not the suite.
        import core.memory : GC;

        GC.disable();
        scope (exit)
            GC.enable();

        auto counters = CounterGroups.none;
        auto wall = WallSource.tryOpen(true);
        auto psi = PsiSource.tryOpen(false);
        const outcome = runWorkload(
            Test(fullName: "m.spin", name: "spin", ptr: &spin,
                traits: TestTraits(isWorkload: true, workloadReps: 1)),
            counters, wall, psi);

        const d = outcome.windows[0].wall;
        assert(d.wallNs >= 25_000_000);
        const onCpu = d.onCpuUserNs + d.onCpuKernelNs;
        // Preemption-robust: under the parallel test pool the spin thread
        // can spend real wall time preempted on the runqueue — which the
        // thread-scoped decomposition correctly attributes to `runq`, not
        // on-CPU. The honesty claim is that a spin's NON-WAITING time is
        // on-CPU (never mis-attributed to the residual).
        const runq = d.offCpuRunqueueNs.isNaN ? 0.0 : d.offCpuRunqueueNs;
        assert(onCpu > (double(d.wallNs) - runq) * 0.5,
            "a spin's non-runqueue time is on-CPU time");
    }

    @("workload.decomposition.sleepIsOther")
    @system
    unittest
    {
        import core.thread : Thread;
        import core.time : msecs;
        import sparkles.test_runner.model : TestTraits;

        // Part 2: sleep is neither on-CPU nor runqueue nor disk — it must
        // land in the residual, never be attributed to a fabricated cause.
        static void sleeper()
        {
            Thread.sleep(30.msecs);
        }

        auto counters = CounterGroups.none;
        auto wall = WallSource.tryOpen(true);
        auto psi = PsiSource.tryOpen(false);
        const outcome = runWorkload(
            Test(fullName: "m.sleep", name: "sleep", ptr: &sleeper,
                traits: TestTraits(isWorkload: true, workloadReps: 1)),
            counters, wall, psi);

        const d = outcome.windows[0].wall;
        assert(d.wallNs >= 25_000_000);
        assert(d.offCpuOtherNs > double(d.wallNs) * 0.5,
            "sleep lands in the residual");
        if (!d.offCpuRunqueueNs.isNaN)
            assert(d.offCpuRunqueueNs < double(d.wallNs) * 0.5,
                "sleep is not runqueue wait");
    }

}

@("workload.runWorkload.perfWindowTotals")
@system
unittest
{
    // Un-gated: the darwin PerfGroup (proc_pid_rusage fixed counters, B3)
    // serves the same window surface, so this is the workload-window
    // acceptance test on macOS hardware too; VM guests and refused kernels
    // skip with the group's own reason.
    import sparkles.test_runner.model : TestTraits;
    import sparkles.test_runner.skip : skipTest;

    auto counters = CounterGroups.open(true, false, false, null);
    scope (exit)
        counters.close();
    if (!counters.perf.available)
        skipTest(counters.perf.status());

    static void crunch()
    {
        static ulong sink;
        foreach (i; 0 .. 500_000)
            sink += i * i;
    }

    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false);
    const outcome = runWorkload(
        Test(fullName: "m.c", name: "crunch", ptr: &crunch,
            traits: TestTraits(isWorkload: true, workloadReps: 1)),
        counters, wall, psi);

    assert(outcome.result.succeeded);
    assert(!outcome.windows[0].perf.isNull, "an open perf group attaches window stats");
    const p = outcome.windows[0].perf.get;
    assert(p.iters == 1, "window stats are totals, not per-iteration");
    if (p.instructions.isNaN)
        skipTest("window was multiplexed below the reliability gate");
    assert(p.instructions > 500_000,
        "a 500k-iteration spin retires at least that many instructions");
}

/// Dogfood: the runner's own `--bench` run measures this workload
/// (whole-body window, two reps). Deliberately ~15 ms per rep: the window
/// model targets long windows — rusage's tick-sampled user/kernel split
/// smears by up to a scheduler tick, which must be noise, not the signal.
@("workload.demo")
@workloadUda(reps: 2) @system
unittest
{
    import core.time : MonoTime, msecs;

    static ulong sink;
    const t0 = MonoTime.currTime;
    while (MonoTime.currTime - t0 < 15.msecs)
        foreach (i; 0 .. 10_000)
            sink += i * i;
}

@("workload.workloadFiles.consumeOnceAndRestartDisclosure")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : deleteme, remove, write;
    import sparkles.test_runner.model : TestTraits;

    static string file;
    file = deleteme ~ ".regime-consume";
    write(file, new ubyte[](64 * 1024));
    scope (exit)
        remove(file);

    // Consume-once: one prep, two windows — only the first is stamped.
    static void twoWindows()
    {
        workloadFiles(CacheRegime.warm, file);
        workloadWindow("first", () {});
        workloadWindow("second", () {});
    }

    auto counters = CounterGroups.none;
    auto wall = WallSource.tryOpen(true);
    auto psi = PsiSource.tryOpen(false);
    auto outcome = runWorkload(
        Test(fullName: "m.co", name: "co", ptr: &twoWindows,
            traits: TestTraits(isWorkload: true, workloadReps: 1)),
        counters, wall, psi);
    assert(!outcome.windows[0].regime.isNull);
    assert(outcome.windows[1].regime.isNull,
        "the second window is unstamped — the verified state is stale");

    // Windowless multi-call: the whole-body restart is disclosed.
    static void twoPreps()
    {
        workloadFiles(file);
        workloadFiles(file);
    }

    outcome = runWorkload(
        Test(fullName: "m.rs", name: "rs", ptr: &twoPreps,
            traits: TestTraits(isWorkload: true, workloadReps: 1)),
        counters, wall, psi);
    assert(outcome.windows.length == 1);
    assert(outcome.windows[0].wall.note.canFind("restarted"),
        "a second refresh discards prior work — never silently");
}
