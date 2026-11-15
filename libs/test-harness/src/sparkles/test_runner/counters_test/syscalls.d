/**
 * The tests of `sparkles.profiling.counters.syscalls`. They use the harness
 * (`skipTest`, the benchmark layer), which depends on the counters, so
 * they live in the harness rather than self-hosting it in the counters'
 * package (build graph BGR8).
 */
module sparkles.test_runner.counters_test.syscalls;

import sparkles.profiling.counters.syscalls;
import sparkles.profiling.counters.capability : Capability, CapabilityAbsence,
    CapabilityReport, has, hasNamedColumns, hasSnapshot, isCounterBackend,
    probeParanoid, reasonFor;

@("syscalls.parseTracepointId")
@safe pure nothrow @nogc
unittest
{
    assert(parseTracepointId("1234\n") == 1234);
    assert(parseTracepointId("42") == 42);
    assert(parseTracepointId("") == -1);
    assert(parseTracepointId("\n") == -1);
    assert(parseTracepointId("abc") == -1);
}

@("syscalls.SyscallGroup.capabilities")
@system
unittest
{
    auto off = SyscallGroup.tryOpen(false, null);
    assert(!off.capabilities.has(Capability.eventTracing));
    version (linux)
    {
        assert(off.capabilities.reasonFor(Capability.eventTracing) == "not requested");

        auto g = SyscallGroup.tryOpen(true, null);
        scope (exit)
            g.close();
        const r = g.capabilities;
        if (g.available)
            assert(r.has(Capability.eventTracing));
        else
        {
            // The reason names the failing gate: tracefs vs paranoid.
            import std.algorithm.searching : canFind;

            const reason = r.reasonFor(Capability.eventTracing);
            assert(reason.canFind("tracefs") || reason.canFind("perf_event_paranoid"));
        }
    }
    else
        assert(off.capabilities.reasonFor(Capability.eventTracing) == "not Linux");
}

version (linux)
{
    @("syscalls.SyscallGroup.countGetpid")
    @system
    unittest
    {
        import core.sys.posix.unistd : getpid;

        auto g = SyscallGroup.tryOpen(true, ["getpid"]);
        scope (exit)
            g.close();
        import sparkles.test_runner.skip : skipTest;

        if (!g.available) // perf_event_paranoid > 1 / root-only tracefs
            skipTest(g.status());

        static void body_()
        {
            import core.sys.posix.unistd : getpid;

            () @trusted { cast(void) getpid(); }();
        }

        const s = g.count(&body_, () {}, 200);
        assert(s.iters == 200);
        // The named getpid tracepoint is exact: ~1 getpid per iteration.
        import std.math : isNaN;

        if (!s.counts[0].isNaN)
            assert(s.counts[0] >= 0.9 && s.counts[0] <= 1.5);
        assert(s.total >= 1.0); // at least the getpid; plus the DISABLE ioctl
    }

}
