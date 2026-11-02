/**
 * The run plan both clients follow (process-model TRM3): which tests a run
 * selects, the phases they run in, and the verdict on the outcome. The core
 * plans; its clients place the tests on workers.
 */
module sparkles.test_runner.plan;

import sparkles.test_runner.model : Test;
import sparkles.test_runner.options : RunnerOptions;

/// One run phase of the default mode: tests and the workers that run them.
struct TestPhase
{
    Test[] tests;
    size_t threads;
    /// A single worker runs on the calling thread (see `startTestWorkers`).
    bool onCaller = true;
}

/// The default mode's phases: every test but the `@serial` ones on `threads`
/// workers; then the `@serial` ones of any thread, one at a time on one
/// worker; then the `mainThread` ones, one at a time on the calling thread.
TestPhase[3] testPhases(Test[] runnable, size_t threads) @safe pure
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import sparkles.test_runner.attributes : ThreadAffinity;

    return [
        TestPhase(runnable.filter!(t => !t.traits.isSerial).array, threads),
        TestPhase(runnable.filter!(t => t.traits.isSerial
            && t.traits.serialAffinity == ThreadAffinity.none).array, 1, onCaller: false),
        TestPhase(runnable.filter!(t => t.traits.isSerial
            && t.traits.serialAffinity == ThreadAffinity.mainThread).array, 1),
    ];
}

@("runner.testPhases.serialRunLast")
@safe pure
unittest
{
    import sparkles.test_runner.attributes : ThreadAffinity;

    Test parallel, anyThread, mainThread;
    parallel.name = "parallel";
    anyThread.name = "anyThread";
    anyThread.traits.isSerial = true;
    mainThread.name = "mainThread";
    mainThread.traits.isSerial = true;
    mainThread.traits.serialAffinity = ThreadAffinity.mainThread;

    const phases = testPhases([mainThread, parallel, anyThread], 4);
    assert(phases[0].threads == 4 && phases[0].tests.length == 1);
    assert(phases[0].tests[0].name == "parallel");
    assert(phases[1].threads == 1 && !phases[1].onCaller);
    assert(phases[1].tests.length == 1 && phases[1].tests[0].name == "anyThread");
    assert(phases[2].threads == 1 && phases[2].onCaller);
    assert(phases[2].tests.length == 1 && phases[2].tests[0].name == "mainThread");
}

/// The tests a run selects, or why its options select none.
struct Selection
{
    /// The selected tests, in discovery order.
    Test[] tests;
    /// How many `--skip-slow` left out, for the summary: a filter that drops
    /// tests without a word would let a run that skipped everything read as
    /// a pass.
    size_t slowSkipped;
    /// Non-empty when the options are inconsistent; nothing runs.
    string error;
}

/// Checks the options' combinations and applies `-i`, `-e`, `--skip-slow`
/// and `--only-slow` to `discovered`.
Selection selectTests(Test[] discovered, in RunnerOptions options)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.regex : regex, RegexException;
    import sparkles.test_runner.filter : matchesFilter, matchesSlowSelection, SlowSelection;

    // The run modes are mutually exclusive; silently preferring one turned
    // `--ctfe-trace f --bench` into a false green — the requested trace was
    // never written, yet the run exited 0. `--list` / `--list-metrics` remain
    // winning queries on top of any mode.
    const requestedModes = (options.bench ? 1 : 0)
        + (options.ctfeTrace.length ? 1 : 0)
        + (options.betterC || options.wasm || options.wasmBare ? 1 : 0);
    if (requestedModes > 1)
        return Selection(error: "pick one mode — --bench, --ctfe-trace, or --better-c/--wasm");
    if (options.wasm && options.wasmBare)
        return Selection(error: "--wasm and --wasm-bare are mutually exclusive");
    if (options.skipSlow && options.onlySlow)
        return Selection(error: "--skip-slow and --only-slow exclude each other");

    // Validate the patterns once up front: a malformed regex would otherwise
    // throw out of the filter with a raw stack trace.
    try
    {
        if (options.include.length)
            cast(void) regex(options.include);
        if (options.exclude.length)
            cast(void) regex(options.exclude);
    }
    catch (RegexException e)
        return Selection(error: "invalid --include/--exclude regular expression: " ~ e.msg);

    const slow = options.skipSlow ? SlowSelection.skip
        : options.onlySlow ? SlowSelection.only : SlowSelection.run;
    auto matching = discovered
        .filter!(t => t.matchesFilter(options.include, options.exclude))
        .array;
    auto tests = matching.filter!(t => t.matchesSlowSelection(slow)).array;
    return Selection(tests: tests, slowSkipped: matching.length - tests.length);
}

@("plan.selectTests.filtersAndRejects")
@system
unittest
{
    import sparkles.test_runner.model : TestTraits;

    Test[] tests = [
        Test(fullName: "m.a", name: "Buffer.append"),
        Test(fullName: "m.b", name: "Buffer.remove", traits: TestTraits(isSlow: true)),
        Test(fullName: "m.c", name: "Pool.take"),
    ];
    auto s = selectTests(tests, RunnerOptions(include: "Buffer", skipSlow: true));
    assert(!s.error.length && s.tests.length == 1 && s.tests[0].name == "Buffer.append");
    assert(s.slowSkipped == 1);

    assert(selectTests(tests, RunnerOptions(include: "(")).error.length);
    assert(selectTests(tests, RunnerOptions(bench: true, betterC: true)).error.length);
    assert(selectTests(tests, RunnerOptions(skipSlow: true, onlySlow: true)).error.length);
}

/// The verdict on a run (process-model TRM4): `0` if and only if everything
/// selected passed or was skipped, from the count of tests that ran and the
/// count of those that passed.
int verdict(size_t executed, size_t passed) @safe pure nothrow @nogc
    => executed == passed ? 0 : 1;

@("plan.verdict")
@safe pure nothrow @nogc
unittest
{
    assert(verdict(0, 0) == 0);
    assert(verdict(3, 3) == 0);
    assert(verdict(3, 2) == 1);
}
