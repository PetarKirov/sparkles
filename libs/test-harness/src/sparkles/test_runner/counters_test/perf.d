/**
 * The tests of `sparkles.profiling.counters.perf`. They use the harness
 * (`skipTest`, the benchmark layer), which depends on the counters, so
 * they live in the harness rather than self-hosting it in the counters'
 * package (build graph BGR8).
 */
module sparkles.test_runner.counters_test.perf;

import std.math : isNaN;

import sparkles.profiling.counters.perf;
import sparkles.profiling.counters.capability : Capability, CapabilityAbsence,
    CapabilityReport, has, hasNamedColumns, hasSnapshot, isCounterBackend,
    probeMaxPrecise, probePmuType, reasonFor;

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
        assert(PerfGroup.inState(requested: true).status
            == "unavailable (proc_pid_rusage failed)");
        assert(PerfGroup.inState(requested: true, countersZero: true).status
            == "unavailable (fixed counters read zero — virtualized guest, or monotonic disabled)");
        const opened = PerfGroup.inState(requested: true, opened: true);
        assert(opened.status
            == "process-wide fixed counters (proc_pid_rusage) — not per-bracket events");
        assert(opened.degraded);
        assert(!PerfGroup.inState(requested: true).degraded);
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
        // No upper bound: the counters are process-wide and this test runs
        // in the parallel worker pool — other threads only ADD instructions,
        // so a busy host must never turn an alignment check red. The lower
        // bound plus the zero-skip already distinguish a misaligned read
        // (garbage or dead field) from a live counter.
        assert(instr > 10_000, "the instruction delta of a 100k spin is plausible");
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
        assert(!PerfGroup.init.degraded, "clean state");
        assert(PerfGroup.inState(requested: true, userOnly: true).degraded);
        assert(PerfGroup.inState(requested: true, cacheDropped: true).degraded);
        assert(PerfGroup.inState(requested: true, scaledMode: true).degraded);
    }

    @("perf.PerfGroup.status.byteIdentity")
    @safe pure nothrow
    unittest
    {
        // The exact pre-capability-seam strings, byte for byte.
        assert(PerfGroup.inState(requested: true).status
            == "unavailable (perf_event_open failed — perf_event_paranoid?)");
        assert(PerfGroup.inState(requested: true, neverScheduled: true).status
            == "unavailable (PMU busy — the group never got scheduled)");
        assert(PerfGroup.inState(requested: true, opened: true).status == "kernel+user");
        assert(PerfGroup.inState(requested: true, opened: true, userOnly: true).status
            == "user-space only");
        assert(PerfGroup.inState(requested: true, opened: true, userOnly: true,
            cacheDropped: true).status
            == "user-space only; LLC events dropped (would multiplex — NMI watchdog holds a counter?)");
    }

}
