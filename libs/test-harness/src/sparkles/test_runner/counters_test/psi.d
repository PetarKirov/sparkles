/**
 * The tests of `sparkles.profiling.counters.psi`. They use the harness
 * (`skipTest`, the benchmark layer), which depends on the counters, so
 * they live in the harness rather than self-hosting it in the counters'
 * package (build graph BGR8).
 */
module sparkles.test_runner.counters_test.psi;

import sparkles.profiling.counters.psi;
import sparkles.profiling.counters.capability : Capability, CapabilityAbsence,
    CapabilityReport;

@("psi.parsePsiFile.realShapes")
@safe pure nothrow @nogc
unittest
{
    // The live /proc/pressure/io shape (values from the dev box).
    const io = parsePsiFile("some avg10=83.80 avg60=83.62 avg300=82.70 total=3960524451711\n"
        ~ "full avg10=77.31 avg60=76.70 avg300=74.71 total=3736825779413\n");
    assert(io.ok);
    assert(io.someUs == 3_960_524_451_711);
    assert(io.fullUs == 3_736_825_779_413);

    // cpu's full line is pinned to total=0 at system scope.
    const cpu = parsePsiFile("some avg10=0.00 avg60=0.00 avg300=0.28 total=10504111166\n"
        ~ "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n");
    assert(cpu.ok);
    assert(cpu.someUs == 10_504_111_166);
    assert(cpu.fullUs == 0);

    // Pre-5.13 kernels: cpu has no full line at all.
    const old = parsePsiFile("some avg10=0.00 avg60=0.00 avg300=0.00 total=42\n");
    assert(old.ok);
    assert(old.someUs == 42);
    assert(old.fullUs == -1, "an absent full line stays -1");
}

@("psi.parsePsiFile.rejectsGarbage")
@safe pure nothrow @nogc
unittest
{
    assert(!parsePsiFile("").ok);
    assert(!parsePsiFile("garbage\n").ok);
    assert(!parsePsiFile("some avg10=0.00 avg60=0.00 avg300=0.00\n").ok,
        "a some line without total= is not a reading");
    assert(!parsePsiFile("some avg10=0.00 total=\n").ok, "total= with no digits");
    assert(!parsePsiFile("full avg10=0.00 total=5\n").ok,
        "a full line without a some line is not a valid reading");
    // The decaying averages must never be mistaken for the total.
    const avgOnly = parsePsiFile("some avg10=99.99 avg60=99.99 avg300=99.99 total=7\n");
    assert(avgOnly.someUs == 7);
    // Truncated mid-total: REJECTED — the digits read so far are a
    // valid-looking but wrong prefix; accepting them at a torn BEFORE edge
    // would fabricate a near-boot-sized stall delta that passes every
    // downstream gate.
    assert(!parsePsiFile("some avg10=0.00 total=123").ok);
    const torn = parsePsiFile("some avg10=0.00 total=5\nfull avg10=0.00 total=3");
    assert(torn.someUs == 5, "the newline-terminated some line is complete");
    assert(torn.fullUs == -1, "the EOF-cut full total may be torn — rejected");
    // Glued tokens and overflowing digit runs are not readings.
    assert(!parsePsiFile("sometotal=7\n").ok);
    assert(!parsePsiFile("some avg10=0.00 total=99999999999999999999\n").ok,
        "a 20-digit total would wrap long — rejected, never wrapped");
}

@("psi.PsiSource.notRequested")
@safe
unittest
{
    import sparkles.profiling.counters.capability : has, reasonFor;

    const off = PsiSource.tryOpen(false);
    assert(!off.available);
    assert(!off.capabilities.has(Capability.counting));
    assert(off.capabilities.reasonFor(Capability.counting) == "not requested");
    assert(off.status == "unavailable (not requested)");
}

version (linux)
{
    @("psi.PsiSource.liveSnapshotMonotonic")
    @system
    unittest
    {
        import sparkles.test_runner.skip : skipTest;

        auto s = PsiSource.tryOpen(true);
        scope (exit)
            s.close();
        if (!s.available)
            skipTest(s.status()); // CONFIG_PSI=n / psi=0

        const a = s.snapshot();
        static ulong sink;
        foreach (i; 0 .. 200_000)
            sink += i * i;
        const b = s.snapshot();

        assert(a.io.ok && b.io.ok);
        assert(a.io.someUs >= 0);
        assert(b.io.someUs >= a.io.someUs, "the total is monotonic");
        assert(b.memory.ok && b.cpu.ok, "all three files read on a PSI host");
        assert(b.cpu.someUs >= a.cpu.someUs);
    }

}
