/**
 * `benchCase` against the ways a deferred case used to go wrong (TRB1–TRB4).
 *
 * The runner registers a body's cases, returns from it, and measures them
 * later. These tests register from ordinary bodies, then do to the cases what
 * the rest of a run does — overwrite the stack, recycle the heap — before
 * measuring them.
 *
 * In its own module because whether a frame stays on the stack depends on
 * how the registering module infers the API's parameters: compiled beside
 * the template, in `bench.d`, a frame-capturing registration once passed while
 * every user module failed.
 */
module sparkles.test_runner.bench_case_test;

import core.time : usecs;

import sparkles.test_runner.bench : BenchConfig, BenchTiming, CounterGroups, RegisteredCase,
    benchCase, blackBox, casesTest, disposeCases, measureCase, registerBenchmark;
import sparkles.test_runner.model : Test, TestTraits;

private:

__gshared string[] journal;

const config = BenchConfig(iterations: 4, sampleCount: 2, minSampleTime: 1.usecs);

// Registers `body_` as a `@benchCases` test (or, with `cases: false`, a
// `@benchmark` one) and checks that registration succeeded.
RegisteredCase[] register(void function() body_, bool cases = true)
{
    auto registered = registerBenchmark(cases ? casesTest("t", body_) : benchmarkTest(body_),
        BenchConfig());
    assert(registered.result.succeeded);
    return registered.cases;
}

Test benchmarkTest(void function() body_)
    => Test(fullName: "m.b", name: "b", ptr: body_, traits: TestTraits(isBenchmark: true));

// What the rest of a run does between registration and measurement.
void overwriteStackAndRecycleHeap()
{
    import core.memory : GC;

    static void clobber()
    {
        ubyte[64 * 1024] junk = 0xAB;
        blackBox(junk.ptr);
    }

    clobber();
    foreach (_; 0 .. 3)
    {
        GC.collect();
        foreach (__; 0 .. 100_000)
        {
            auto g = new long[](8);
            g[] = -1;
        }
    }
}

string[] measureAll(RegisteredCase[] cases)
{
    string[] errors;
    auto counters = CounterGroups.none;
    foreach (c; cases)
        errors ~= measureCase(c, config, counters).error;
    return errors;
}

// A case whose state is reachable only through the case: a GC block the
// collector may reclaim, and the loop value it was built from.
struct Sentinel
{
    int k;
    long[] cells;

    this(int k)
    {
        this.k = k;
        cells = new long[](8);
        cells[] = 1000 + k;
    }

    long timed() => blackBox(cells[0]);

    void after(ref long v)
    {
        if (v != 1000 + k || cells.length != 8 || cells[7] != 1000 + k)
            throw new Exception("the case's state is gone");
        journal ~= [cast(char)('0' + k)];
    }
}

@("benchCase.casesOutliveTheBody")
@system
unittest
{
    // Registered straight from a loop: no helper, no heap object, no closure.
    static void body_()
    {
        foreach (k; 0 .. 3)
            benchCase(Sentinel(k), name: "sentinel");
    }

    journal = null;
    auto cases = register(&body_);
    assert(cases.length == 3);
    overwriteStackAndRecycleHeap();
    foreach (error; measureAll(cases))
        assert(error.length == 0, error);
    // Each case saw its own loop value (TRB3), once per measured call.
    assert(journal.length == 3 * config.iterations);
    assert(journal[0] == "0" && journal[$ - 1] == "2");
}

// Logs every hook, and its destructor only for the live instance (a moved-from
// copy is `.init`).
struct Lifecycle
{
    bool live;
    int pending; // results timed has produced and after has not released

    this(bool live) { this.live = live; }

    void setup() { journal ~= "setup"; }
    int timed() { ++pending; journal ~= "timed"; return 1; }
    void after(ref int r) { pending -= r; journal ~= "after"; }
    void teardown() { assert(pending == 0, "a result was not released"); journal ~= "teardown"; }

    ~this()
    {
        if (live)
            journal ~= "destroyed";
    }
}

@("benchCase.lifecycleBracketsTheMeasurement")
@system
unittest
{
    import std.algorithm.searching : count;

    static void body_()
    {
        benchCase(Lifecycle(true), name: "lifecycle");
    }

    journal = null;
    auto cases = register(&body_);
    assert(journal == [], "registration runs no hook");
    measureAll(cases);

    // setup, then per call timed + after, then teardown, then the destructor.
    assert(journal[0] == "setup");
    assert(journal[$ - 2] == "teardown" && journal[$ - 1] == "destroyed");
    const calls = journal.count("timed");
    assert(calls == config.iterations);
    assert(journal.count("after") == calls, "after releases every result");
    foreach (i; 0 .. calls)
        assert(journal[1 + 2 * i] == "timed" && journal[2 + 2 * i] == "after");
    assert(journal.count("destroyed") == 1);

    disposeCases(cases); // idempotent: the measured case is not destroyed again
    assert(journal.count("destroyed") == 1);
}

@("benchCase.unmeasuredCaseIsDestroyedOnce")
@system
unittest
{
    import std.algorithm.searching : count;

    static void body_()
    {
        benchCase(Lifecycle(true), name: "filtered out");
    }

    journal = null;
    auto cases = register(&body_);
    disposeCases(cases); // what the worker does at shutdown
    disposeCases(cases);
    assert(journal == ["destroyed"], "no hook runs, the destructor once");
}

struct Throws
{
    bool live;
    this(bool live) { this.live = live; }
    void timed() {}
    void after() { throw new Exception("mismatch"); }
    void teardown() { journal ~= "teardown"; }
    ~this() { if (live) journal ~= "destroyed"; }
}

@("benchCase.throwStillTearsDownAndDestroys")
@system
unittest
{
    import std.exception : collectExceptionMsg;

    // A throw leaves `measureCase` (the worker turns it into an error row with
    // its trace and measures the rest); the case is still torn down and
    // destroyed on the way out.
    static void body_()
    {
        benchCase(Throws(true), name: "throws");
    }

    journal = null;
    auto cases = register(&body_);
    auto counters = CounterGroups.none;
    assert(collectExceptionMsg(measureCase(cases[0], config, counters)) == "mismatch");
    assert(journal == ["teardown", "destroyed"]);
}

@("benchCase.inertOutsideBench")
@system
unittest
{
    // Outside --bench the case runs once, in order, and is destroyed.
    journal = null;
    benchCase(Lifecycle(true), name: "inert");
    assert(journal == ["setup", "timed", "after", "teardown", "destroyed"]);
}

// Move-only state is fine: the case is moved, never copied.
struct MoveOnly
{
    int[] data;
    @disable this(this);
    int timed() => cast(int) data.length;
    void after(ref int n) { assert(n == 3); }
}

@("benchCase.moveOnlyState")
@system
unittest
{
    static void body_()
    {
        benchCase(MoveOnly([1, 2, 3]), name: "move-only");
    }

    foreach (error; measureAll(register(&body_)))
        assert(error.length == 0, error);
    benchCase(MoveOnly([1, 2, 3]), name: "move-only, inert");
}

@("benchCase.rejectsCasesThatReachTheFrame")
@safe
unittest
{
    // A case runs after the frame that registered it is gone, so a case type
    // that could reach that frame does not compile (TRB2).
    int local;
    struct Nested { int timed() => local; }
    static struct HoldsDelegate { int delegate() dg; int timed() => dg(); }
    static struct Inner { void delegate() dg; }
    static struct Deep { Inner[2] inner; void timed() {} }
    static struct NoTimed { void after() {} }
    static struct Fine { int[] state; Object o; int timed() => 1; }

    static assert(!__traits(compiles, benchCase(Nested(), name: "x")));
    static assert(!__traits(compiles, benchCase(HoldsDelegate(() => local), name: "x")));
    static assert(!__traits(compiles, benchCase(Deep(), name: "x")));
    static assert(!__traits(compiles, benchCase(NoTimed(), name: "x")));
    static assert(__traits(compiles, benchCase(Fine(), name: "x")));
}

// ─── the two roles: `@benchmark` measures the body, `@benchCases` registers ─

@("benchmark.benchCaseIsAnError")
@system
unittest
{
    import std.algorithm.searching : canFind;

    // A `@benchmark` body is the measured unit; registering cases from one
    // is a mistake reported at registration, naming the test.
    static void body_()
    {
        benchCase(Sentinel(1), name: "stray");
    }

    auto registered = registerBenchmark(benchmarkTest(&body_), BenchConfig());
    assert(!registered.result.succeeded);
    assert(registered.result.thrown[0].message.canFind("`b` is a `@benchmark`"),
        registered.result.thrown[0].message);
}

@("benchCases.zeroCasesIsAnError")
@system
unittest
{
    // An empty matrix (a filter, a loop bound) is an error, never a
    // measurement of the body.
    static void body_() {}

    auto registered = registerBenchmark(casesTest("empty", &body_), BenchConfig());
    assert(!registered.result.succeeded && !registered.result.skipped);
    assert(registered.cases.length == 0);
    assert(registered.result.thrown[0].message == "`empty` registered no cases",
        registered.result.thrown[0].message);
}

@("benchCases.zeroCasesAfterSkipSkips")
@system
unittest
{
    import sparkles.test_runner.skip : skipTest;

    // The way to say "nothing to measure here": skip.
    static void body_()
    {
        skipTest("TUI_BENCH_POCS removed every case");
    }

    auto registered = registerBenchmark(casesTest("filtered", &body_), BenchConfig());
    assert(registered.result.skipped);
    assert(registered.result.skipReason == "TUI_BENCH_POCS removed every case");
    assert(registered.cases.length == 0);
}

@("benchmark.wholeBody")
@system
unittest
{
    // A `@benchmark` body is one row, named after the test, measured whole.
    static void whole()
    {
        blackBox(3);
    }

    auto body_ = register(&whole, cases: false);
    assert(body_.length == 1 && body_[0].name == "b");
    assert(body_[0].runAfter is null, "a whole body is timed batched");
    foreach (error; measureAll(body_))
        assert(error.length == 0, error);
}

// ─── batched timing: back-to-back calls, for nanosecond-scale cases ─

// Counts its calls; `setup` and `teardown` bracket the measurement.
struct Batched
{
    enum timing = BenchTiming.batched;
    long[] cells; // reachable only through the case

    this(int k)
    {
        cells = new long[](8);
        cells[] = k;
    }

    void setup() { journal ~= "setup"; }
    long timed() => blackBox(++cells[0]);
    void teardown()
    {
        if (cells.length != 8)
            throw new Exception("the case's state is gone");
        journal ~= "teardown";
    }
}

@("benchCase.batchedRunsBackToBack")
@system
unittest
{
    import std.algorithm.searching : count;

    static void body_()
    {
        benchCase(Batched(0)); // named after the test
        benchCase(Batched(1), name: "named", labels: ["part": "b"]);
    }

    journal = null;
    auto cases = register(&body_);
    assert(cases.length == 2);
    assert(cases[0].name == "t" && cases[1].name == "named");
    assert(cases[0].runAfter is null, "a batched case runs nothing between calls");
    overwriteStackAndRecycleHeap();

    auto counters = CounterGroups.none;
    auto row = measureCase(cases[0], config, counters);
    assert(row.error.length == 0, row.error);
    // A pinned count is the iterations per sample, as for a whole body.
    assert(row.iterations == config.iterations && row.samples == config.sampleCount);
    assert(journal == ["setup", "teardown"]);
    disposeCases(cases);
}

@("benchCase.batchedInertOutsideBench")
@system
unittest
{
    journal = null;
    benchCase(Batched(0));
    assert(journal == ["setup", "teardown"]);
}

@("benchCase.batchedRejectsAfter")
@safe
unittest
{
    static struct WithAfter
    {
        enum timing = BenchTiming.batched;
        int timed() => 1;
        void after(ref int) {}
    }

    static struct BadTiming
    {
        enum timing = 1;
        void timed() {}
    }

    static assert(!__traits(compiles, benchCase(WithAfter(), name: "x")));
    static assert(!__traits(compiles, benchCase(BadTiming(), name: "x")));
}
