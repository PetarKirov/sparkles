/**
 * The tests of `sparkles.profiling.counters.capability`. They use the harness
 * (`skipTest`, the benchmark layer), which depends on the counters, so
 * they live in the harness rather than self-hosting it in the counters'
 * package (build graph BGR8).
 */
module sparkles.test_runner.counters_test.capability;

import sparkles.profiling.counters.capability;

@("capability.capabilityName.everyMember")
@safe pure nothrow @nogc
unittest
{
    foreach (c; allCapabilities)
        assert(capabilityName(c).length > 4);
    assert(capabilityName(Capability.none) == "none");
    assert(capabilityName(Capability.preciseMemory) == "preciseMemory");
}

@("capability.CapabilityReport.hasAndReasonFor")
@safe pure nothrow @nogc
unittest
{
    static immutable CapabilityAbsence[2] absences = [
        CapabilityAbsence(Capability.eventTracing, "tracefs unreadable"),
        CapabilityAbsence(Capability.preciseMemory, "no engine"),
    ];
    const r = CapabilityReport(Capability.counting, absences[]);
    assert(r.has(Capability.counting));
    assert(!r.has(Capability.eventTracing));
    assert(r.reasonFor(Capability.eventTracing) == "tracefs unreadable");
    assert(r.reasonFor(Capability.preciseMemory) == "no engine");
    assert(r.reasonFor(Capability.counting) is null, "present flags carry no reason");
    assert(r.reasonFor(Capability.eventNaming) is null, "outside the domain");
}

@("capability.harnessPendingCapabilities.shape")
@safe pure nothrow @nogc
unittest
{
    const r = harnessPendingCapabilities();
    assert(r.available == Capability.none);
    assert(r.reasonFor(Capability.symbolization) !is null);
    assert(r.reasonFor(Capability.numaAttribution) !is null);
}

@("capability.isCounterBackend.detection")
@safe pure
unittest
{
    static struct Good
    {
        bool available() const => true;
        string status() const => "ok";
        CapabilityReport capabilities() const => CapabilityReport();
        void close() {}
        int count(Timed, Between)(scope Timed timed, scope Between between, uint iters) => 0;
    }

    static struct NoCapabilities
    {
        bool available() const => true;
        string status() const => "ok";
        void close() {}
        int count(Timed, Between)(scope Timed timed, scope Between between, uint iters) => 0;
    }

    static struct VoidCount
    {
        bool available() const => true;
        string status() const => "ok";
        CapabilityReport capabilities() const => CapabilityReport();
        void close() {}
        void count(Timed, Between)(scope Timed timed, scope Between between, uint iters) {}
    }

    static assert(isCounterBackend!Good);
    static assert(!isCounterBackend!NoCapabilities);
    static assert(!isCounterBackend!VoidCount, "a void count is not a counting pass");
    static assert(!hasSnapshot!Good && !hasNamedColumns!Good);
}

@("capability.optionalPrimitives.detection")
@safe pure
unittest
{
    static struct WithExtras
    {
        bool available() const => true;
        string status() const => "ok";
        CapabilityReport capabilities() const => CapabilityReport();
        void close() {}
        int count(Timed, Between)(scope Timed timed, scope Between between, uint iters) => 0;
        long snapshot() => 0;
        const(string)[] names() const => null;
    }

    static assert(isCounterBackend!WithExtras);
    static assert(hasSnapshot!WithExtras);
    static assert(hasNamedColumns!WithExtras);
}

@("capability.parseLongValue.fixtures")
@safe pure nothrow @nogc
unittest
{
    assert(parseLongValue("-1\n") == ProbedValue(true, -1));
    assert(parseLongValue("2") == ProbedValue(true, 2));
    assert(parseLongValue(" 11") == ProbedValue(true, 11));
    assert(parseLongValue("") == ProbedValue(false, 0));
    assert(parseLongValue("abc") == ProbedValue(false, 0));
    assert(parseLongValue("-") == ProbedValue(false, 0));
    assert(parseLongValue("0\n") == ProbedValue(true, 0));
}

version (linux)
{
    @("capability.probePmuType.absentPmu")
    @safe
    unittest
    {
        assert(probePmuType("nonexistent-pmu") == -1);
        assert(probePmuType("a-name-far-too-long-to-fit-the-fixed-path-buffer-"
            ~ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") == -1);
    }

    @("capability.probeParanoid.hostRange")
    @system
    unittest
    {
        import sparkles.test_runner.skip : skipTest;

        const p = probeParanoid();
        if (!p.ok)
            skipTest("/proc/sys/kernel/perf_event_paranoid unreadable");
        assert(p.value >= -1 && p.value <= 4);
    }

}
