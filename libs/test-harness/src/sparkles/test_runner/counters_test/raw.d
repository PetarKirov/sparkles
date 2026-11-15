/**
 * The tests of `sparkles.profiling.counters.raw`. They use the harness
 * (`skipTest`, the benchmark layer), which depends on the counters, so
 * they live in the harness rather than self-hosting it in the counters'
 * package (build graph BGR8).
 */
module sparkles.test_runner.counters_test.raw;

import sparkles.profiling.counters.raw;
import sparkles.profiling.counters.capability : Capability, CapabilityAbsence,
    CapabilityReport, has, hasNamedColumns, hasSnapshot, isCounterBackend,
    reasonFor;

@("raw.parseRawEvent.fixtures")
@safe pure nothrow
unittest
{
    RawEvent ev;
    assert(parseRawEvent("r04c2", ev) && ev.config == 0x04c2 && ev.id == "raw:r04c2");
    assert(ev.type == 4 && !ev.excludeUser && !ev.excludeKernel);
    assert(parseRawEvent("r00C0", ev) && ev.config == 0xc0);
    assert(parseRawEvent("r0", ev) && ev.config == 0);
    assert(!parseRawEvent("04c2", ev), "missing the r prefix");
    assert(!parseRawEvent("r", ev), "no digits");
    assert(!parseRawEvent("rxyz", ev), "not hex");
    assert(!parseRawEvent("r00000000000000000", ev), "wider than 64 bits");
    assert(rawHeader("raw:r04c2") == "r04c2");
    assert(rawHeader("pfm:RETIRED_INSTRUCTIONS") == "RETIRED_INSTRUCTIONS");
}

@("raw.RawGroup.capabilities.notRequested")
@safe
unittest
{
    auto g = RawGroup.tryOpen(false, null);
    assert(!g.capabilities.has(Capability.countingRaw));
    version (linux)
        assert(g.capabilities.reasonFor(Capability.countingRaw) == "not requested");
    else
        assert(g.capabilities.reasonFor(Capability.countingRaw) == "not Linux");
}

version (linux)
{
    @("raw.RawGroup.countRetiredInstructions")
    @system
    unittest
    {
        import sparkles.test_runner.skip : skipTest;

        // Event select 0xC0 = retired instructions on both AMD and Intel x86.
        version (X86_64)
            enum selector = "r00c0";
        else
            enum selector = "r0";

        RawEvent ev;
        assert(parseRawEvent(selector, ev));
        auto g = RawGroup.tryOpen(true, [ev]);
        scope (exit)
            g.close();
        if (!g.available)
            skipTest(g.status());
        assert(g.capabilities.has(Capability.countingRaw));

        static ulong sink;
        const s = g.count(() {
            foreach (i; 0 .. 10_000)
                sink += i * i;
        }, () {}, 5);
        assert(s.iters == 5);
        assert(s.selectors == ["raw:" ~ selector]);
        version (X86_64)
        {
            import std.math : isNaN;

            // ~30k+ retired instructions per iteration; anything clearly
            // nonzero proves the plumbing (exact value is µarch-dependent).
            if (!s.values[0].isNaN)
                assert(s.values[0] > 1000);
        }
    }

}
