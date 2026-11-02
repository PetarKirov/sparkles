/**
 * The measurement sources a `--bench` run opens in the test binary: which
 * counting passes its options select, the header notes that disclose what is
 * absent or degraded, and the `--list-metrics` probe. The runner sends the
 * options; the binary, which runs the bodies, opens the sources
 * (process-model TRP21).
 */
module sparkles.test_runner.bench_session;

import sparkles.test_runner.bench : CounterGroups;
import sparkles.profiling.counters.capability : BackendCapabilities;
import sparkles.test_runner.metrics : MetricDescriptor;
import sparkles.profiling.counters.raw : RawEvent;

/// The bench options that decide which sources open.
struct BenchOptions
{
    bool perf;
    bool perfScaled;
    uint perfIters;
    string syscalls;
    string metrics;
}

/// What opening the sources found, for the runner's header and its
/// `--metrics`/`--sort-by` validation.
struct BenchProbe
{
    /// Header lines: absent-but-requested capabilities, degraded groups,
    /// dropped columns, failed `pfm:` resolutions.
    string[] notes;
    /// The tracepoint names the syscall pass counts columns for.
    string[] syscallNames;
    /// The raw and resolved `pfm:` events the raw pass counts.
    RawEvent[] rawEvents;
}

/// The open sources of one bench run.
struct BenchSession
{
    CounterGroups counters;
    BenchProbe probe;

    void close()
    {
        counters.close();
    }
}

/// Opens the sources `options` select and records the header notes.
BenchSession openBenchSession(in BenchOptions options)
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import sparkles.test_runner.bench : BenchConfig;
    import sparkles.profiling.counters.capability : Capability, capabilityName, CapabilityReport;
    import sparkles.test_runner.metrics : pfmSelectorNames, rawSelectorEvents,
        selectsSource, syscallSelectorNames;

    BenchSession session;
    string[] notes;

    // Which counting passes to open: --perf OR a --metrics perf metric (so
    // `--metrics=ipc`/`=all` populate the perf columns, mirroring tier0); a
    // --metrics tier0 metric (opt-in, no perms); and the syscall pass for
    // --syscalls (null = off, "*" = total only, else a name list) OR a
    // --metrics syscall column (`syscalls`, `syscalls:<name>`, `all`).
    const metricSyscalls = syscallSelectorNames(options.metrics);
    const wantPerf = options.perf || options.perfScaled
        || selectsSource(options.metrics, "perf");
    const wantTier0 = selectsSource(options.metrics, "tier0");
    const wantSyscalls = options.syscalls.length > 0 || metricSyscalls.length > 0
        || selectsSource(options.metrics, "syscall");
    auto syscallNames = (options.syscalls == "*" || !options.syscalls.length)
        ? null : options.syscalls.splitter(',').array;
    foreach (n; metricSyscalls)
        if (!syscallNames.canFind(n))
            syscallNames ~= n;
    auto rawEvents = rawSelectorEvents(options.metrics);
    // pfm:<name> selectors resolve to raw events through libpfm (soft
    // dependency); a failed resolution warns and drops the column — like an
    // unknown selector, never a run failure.
    if (const pfmNames = pfmSelectorNames(options.metrics))
    {
        import sparkles.test_runner.event_naming : PfmResolver;

        auto resolver = PfmResolver.tryLoad();
        foreach (name; pfmNames)
        {
            RawEvent ev;
            string err;
            if (resolver.resolve(name, ev, err))
            {
                if (!rawEvents.canFind!(e => e.id == ev.id))
                    rawEvents ~= ev;
            }
            else
                notes ~= "--metrics: pfm:" ~ name ~ " — " ~ err;
        }
    }
    const wantRaw = rawEvents.length > 0;
    session.counters = CounterGroups.open(wantPerf, wantTier0, wantSyscalls, syscallNames,
        wantRaw, rawEvents, options.perfScaled);
    auto counters = &session.counters;

    // Absent-but-requested capabilities, one line each, re-derived from the
    // capability reports so the header and --list-metrics share one vocabulary.
    void noteAbsent(string flag, in CapabilityReport report, Capability wanted)
    {
        foreach (ref a; report.absences)
            if (a.capability & wanted)
                notes ~= flag ~ ": " ~ capabilityName(a.capability)
                    ~ " unavailable (" ~ a.reason ~ ")";
    }

    if (wantPerf && !counters.perf.available)
        noteAbsent("--perf", counters.perf.capabilities, Capability.counting);
    // A usable-but-degraded group (user-only fallback, dropped LLC pair,
    // scaled mode) is disclosed too — em-dash columns alone don't say why.
    if (wantPerf && counters.perf.available && counters.perf.degraded)
        notes ~= "--perf: " ~ counters.perf.status();
    if (options.perfIters > BenchConfig().perfMaxIters)
    {
        import std.conv : text;

        notes ~= text("--perf-iters: capped at ", BenchConfig().perfMaxIters,
            " (", options.perfIters, " requested)");
    }
    if (wantTier0 && !counters.tier0.available)
        noteAbsent("--metrics", counters.tier0.capabilities, Capability.counting);
    if (wantSyscalls && !counters.syscalls.available)
        noteAbsent("--syscalls", counters.syscalls.capabilities, Capability.eventTracing);
    if (wantRaw && !counters.raw.available)
        noteAbsent("--metrics", counters.raw.capabilities, Capability.countingRaw);
    // The group read caps the named tracepoints (SyscallGroup truncates its
    // list); a silently dropped column reads as "never fires" — say so.
    if (counters.syscalls.available && syscallNames.length > counters.syscalls.names.length)
    {
        import std.conv : text;

        notes ~= text("--syscalls: only the first ", counters.syscalls.names.length,
            " named tracepoints are counted (", syscallNames.length, " requested)");
    }
    // The raw group caps its event list the same way.
    if (wantRaw && rawEvents.length > counters.raw.names.length)
    {
        import std.conv : text;

        notes ~= text("--metrics: only the first ", counters.raw.names.length,
            " raw/pfm events are counted (", rawEvents.length, " requested)");
    }

    session.probe = BenchProbe(notes: notes, syscallNames: syscallNames,
        rawEvents: rawEvents);
    return session;
}

/// The `--list-metrics` probe: every source opened, regardless of options.
struct MetricsListing
{
    /// The catalog of the perf, tier-0 and syscall families, with true
    /// availability on this host.
    MetricDescriptor[] catalog;
    /// One capability block per backend, the workload sources included.
    BackendCapabilities[] blocks;
    /// The narrower fact the blocks cannot carry: counting works, runqueue
    /// attribution does not. Empty when attribution works.
    string wallNote;
}

/// ditto
MetricsListing listMetrics()
{
    import sparkles.test_runner.metrics : perfFamily, syscallFamily, tier0Family;
    import sparkles.profiling.counters.psi : PsiSource;
    import sparkles.test_runner.workload : WallSource, withWorkloadBlocks;

    MetricsListing listing;
    auto probe = CounterGroups.open(true, true, true, null, rawWanted: true);
    scope (exit)
        probe.close();
    listing.catalog = perfFamily(probe.perf.available,
        fixedOnly: probe.perf.fixedCountersOnly)
        ~ tier0Family(probe.tier0.available)
        ~ syscallFamily(probe.syscalls.available);
    auto wallProbe = WallSource.tryOpen(true);
    scope (exit)
        wallProbe.close();
    auto psi = PsiSource.tryOpen(true);
    scope (exit)
        psi.close();
    listing.blocks = withWorkloadBlocks(probe.capabilities, wallProbe, psi);
    // The block's ✓/✗ vocabulary can't carry "counting works but runqueue
    // attribution doesn't" — say the narrower fact separately. (PSI needs no
    // such line: its absence is a whole-source CapabilityAbsence.)
    if (wallProbe.available && !wallProbe.schedOk)
        listing.wallNote = "wall: runqueue attribution unavailable ("
            ~ wallProbe.schedReason ~ ") — workload windows fold it into `other`";
    return listing;
}
