/**
 * Registered closures outlive the frame that registered them.
 *
 * In its own module, and with one registration per helper, because the
 * failure needs a caller that sees `benchCase` only through its inferred
 * attributes and whose frame nothing else forces onto the heap (a `benchIter`
 * in the same function did, and hid it).
 */
module sparkles.test_runner.bench_frames_test;

import sparkles.test_runner.bench : benchCase, benchIter, blackBox;

// Each helper registers cases whose closures capture its frame, and nothing
// else: `sentinel` and `k` are reachable only through them. One registration
// per helper, so no other call's escape forces the frame onto the heap.
private void registerCase(int k)
{
    auto sentinel = new long[](8);
    sentinel[] = 1000 + k;
    benchCase(
        name: "case",
        timed: () => blackBox(sentinel[0]),
        after: (ref long v) {
            if (v != 1000 + k || sentinel.length != 8)
                throw new Exception("benchCase: the registering frame is gone");
        },
    );
}

private void registerVoidCase(int k)
{
    auto sentinel = new long[](8);
    sentinel[] = 1000 + k;
    benchCase(
        name: "void case",
        timed: () { blackBox(sentinel[0]); },
        after: () {
            if (sentinel.length != 8 || sentinel[7] != 1000 + k)
                throw new Exception("benchCase: the registering frame is gone");
        },
    );
}

private void registerSetupCase(int k)
{
    long[] sentinel;
    benchCase(
        name: "setup case",
        timed: () => blackBox(sentinel[0]),
        after: (ref long v) {
            if (v != 1000 + k)
                throw new Exception("benchCase: the registering frame is gone");
        },
        setup: () { sentinel = new long[](8); sentinel[] = 1000 + k; },
        teardown: () {
            if (sentinel.length != 8)
                throw new Exception("benchCase: the registering frame is gone");
        },
    );
}

private void registerIter(int k)
{
    auto sentinel = new long[](8);
    sentinel[] = 1000 + k;
    benchIter({
        if (sentinel.length != 8 || sentinel[7] != 1000 + k)
            throw new Exception("benchIter: the registering frame is gone");
    });
}

private void registerAll()
{
    foreach (k; 0 .. 3)
    {
        registerCase(k);
        registerVoidCase(k);
        registerSetupCase(k);
        registerIter(k);
    }
}

private void clobberStack()
{
    ubyte[64 * 1024] junk = 0xAB;
    blackBox(junk.ptr);
}

@("benchCase.frameClosuresOutliveTheBody")
@system
unittest
{
    // The closures run after the registering frame has returned, so the frame
    // they close over must be on the GC heap. A frontend that infers
    // `timed`/`after`/`run` `scope` lets the caller keep it on the stack
    // (LDC 1.43 did; DMD 2.115 did not), and the cases then read whatever
    // later calls left there. Reproduced by overwriting the stack and
    // recycling the heap between registration and measurement.
    import core.memory : GC;
    import core.time : usecs;
    import sparkles.test_runner.bench : BenchConfig, CounterGroups, measureCase,
        registerBenchmark;
    import sparkles.test_runner.model : Test;

    auto registered = registerBenchmark(
        Test(fullName: "m.frames", name: "frames", ptr: &registerAll), BenchConfig());
    assert(registered.result.succeeded);
    assert(registered.cases.length == 12);

    clobberStack();
    foreach (_; 0 .. 3)
    {
        GC.collect();
        foreach (__; 0 .. 100_000)
        {
            auto g = new long[](8);
            g[] = -1;
        }
    }

    auto counters = CounterGroups.none;
    const config = BenchConfig(iterations: 4, sampleCount: 2, minSampleTime: 1.usecs);
    foreach (c; registered.cases)
    {
        const row = measureCase(c, config, counters);
        assert(row.error.length == 0, row.error);
    }
}
