/**
 * The runner: the command line, scheduling, reports, and the compile-time and
 * extracted modes of `sparkles-test-runner` (process-model §2). It drives the
 * test binary through worker processes (see $(MREF sparkles,test_runner,pool))
 * and never runs a test body itself. Tests annotated with the attributes from
 * $(MREF sparkles,test_runner,attributes) get special handling:
 *
 * $(LIST
 *     * `@ctfe` tests are not executed: after CLI filtering, the selected ones
 *       are forced through CTFE by a driver-generated probe compiled with
 *       `-o- -unittest` (semantic analysis only), so `-i`/`-e` control which
 *       tests evaluate, and `--help`/`--list` never evaluate any;
 *     * `@benchmark` tests are skipped by default and measured by `--bench`;
 *     * `@betterC` / `@wasm` tests run normally, and are additionally
 *       exercised in their special environments by `--better-c` / `--wasm`.
 * )
 */
module sparkles.test_runner.runner_impl;

import core.runtime : UnitTestResult;
import core.time : Duration, MonoTime;

import sparkles.test_runner.bench : BenchConfig, BenchStats;
import sparkles.profiling.counters.capability : Capability, capabilityName, CapabilityReport;
import sparkles.test_runner.client : Hello, ProtocolError, Worker;
import sparkles.test_runner.driver : detectCompiler, DriverOptions, ModeReport, runCtfeTests;
import sparkles.test_runner.pool : joinTestWorkers, startTestWorkers;
import sparkles.test_runner.options : ParsedArgs, parseRunnerOptions, RunnerOptions;
import sparkles.test_runner.plan : selectTests, testPhases, verdict;
import sparkles.test_runner.model : Test, TestResult;
import sparkles.base.text.writers : formatted;
import sparkles.test_runner.reporting : BenchProgress, detectTerminalWidth,
    formatCapabilityBlock, formatCtfeFailedLine, formatCtfeLine,
    formatFailedRecap, formatResultLine, formatSummary,
    formatThrown, progressEnabled, RunTotals, TableGeometry, writeBenchTable,
    writeDatasetCatalog, DatasetInfo, writeMetricCatalog, writeWorkloadTable;

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

/// The binary under test, as the launcher named it.
private __gshared string testBinary;
/// What the first worker's `hello` said.
private __gshared Hello hello;
/// The first worker: it listed the tests, and the first worker thread or the
/// bench run takes it.
private __gshared Worker firstWorker;

/**
Runs the tests of `binary`, started as workers with `druntimeOptions`, under
the command line `args`, and returns the exit status: `0` if and only if
everything selected passed or was skipped.
*/
int runnerMain(string binary, string[] druntimeOptions, string[] args)
{
    import std.stdio : stderr;
    import sparkles.test_runner.pool : retireSpare, startFirstWorker, WorkerLaunch;

    testBinary = binary;
    try
        firstWorker = startFirstWorker(WorkerLaunch(binary, druntimeOptions,
            (string text) { stderr.write(text); stderr.flush(); }));
    catch (ProtocolError e)
    {
        stderr.writeln("error: ", e.msg);
        return 2;
    }
    catch (Exception e)
    {
        stderr.writeln("error: cannot start '", binary, "' as a worker: ", e.msg);
        return 2;
    }
    hello = firstWorker.hello;
    scope (exit)
        retireSpare();

    UnitTestResult result;
    try
        result = runSelected(firstWorker.listing, [binary] ~ args);
    catch (ProtocolError e)
    {
        stderr.writeln("error: ", e.msg);
        return 2;
    }
    return verdict(result.executed, result.passed);
}

/// Infers dub's `:subpackage` selector from its generated unittest executable
/// name (`sparkles-core-cli-test-unittest` → `:core-cli`). The repository root
/// package needs no selector; unknown/custom names remain useful best efforts.
private string rerunPackageSelector(string executable) @safe pure nothrow
{
    import std.path : baseName, stripExtension;
    import std.string : startsWith;

    auto name = executable.baseName.stripExtension;
    enum marker = "-test-";
    size_t markerPos;
    bool found;
    if (name.length >= marker.length)
        foreach_reverse (i; 0 .. name.length - marker.length + 1)
            if (name[i .. i + marker.length] == marker)
            {
                markerPos = i;
                found = true;
                break;
            }
    if (!found || markerPos == 0)
        return null;
    name = name[0 .. markerPos];
    if (name == "sparkles")
        return null;
    if (name.startsWith("sparkles-"))
        name = name["sparkles-".length .. $];
    return name.length ? ":" ~ name : null;
}

@("runner.rerunPackageSelector.generatedTargets")
@safe pure nothrow
unittest
{
    assert(rerunPackageSelector("libs/core-cli/build/sparkles-core-cli-test-unittest")
        == ":core-cli");
    assert(rerunPackageSelector("sparkles-test-runner-impl-test-unittest")
        == ":test-runner-impl");
    assert(rerunPackageSelector("apps/hue/build/hue-test-unittest") == ":hue");
    assert(rerunPackageSelector("sparkles-test-unittest") is null);
    assert(rerunPackageSelector("custom") is null);
}

private UnitTestResult runSelected(Test[] discovered, string[] args)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.stdio : stderr, stdout;

    auto parsed = parseRunnerOptions(args);
    if (parsed.error.length)
    {
        stderr.writeln("error: ", parsed.error, " (see --help)");
        return UnitTestResult(1, 0, false, false);
    }
    RunnerOptions options = parsed.options;
    {
        import sparkles.test_runner.driver : setProbeDir;

        setProbeDir(options.probeDir);
    }

    if (parsed.helpWanted)
    {
        stdout.writeln("Usage:\n\tdub test -- <options>\n\nOptions:");
        foreach (option; parsed.helpOptions)
        {
            import std.string : leftJustifier;

            stdout.writefln("  %s\t%s\t%s",
                option.optShort, option.optLong.leftJustifier(14), option.help);
        }
        return UnitTestResult(0, 0, false, false);
    }

    const colored = prepareConsole(options.noColors);
    // Cells available for the compact result lines; `0` (unknown / piped) skips
    // truncation so redirected output stays byte-identical.
    const width = detectTerminalWidth();

    auto selection = selectTests(discovered, options);
    if (selection.error.length)
    {
        stderr.writeln("error: ", selection.error);
        return UnitTestResult(1, 0, false, false);
    }
    auto tests = selection.tests;
    const slowSkipped = selection.slowSkipped;

    if (options.list)
        return listTests(tests, colored);
    // --list-metrics / --metrics=?/help print the catalog and exit; they are
    // handled inside runBenchMode, so route there even without --bench (otherwise
    // the flag is silently ignored and the whole suite runs).
    if (options.bench || options.listMetrics
        || options.metrics == "?" || options.metrics == "help")
        return runBenchMode(tests, options, colored);
    if (options.ctfeTrace.length)
        return runCtfeTraceMode(tests, options, colored);
    if (options.betterC || options.wasm || options.wasmBare)
        return runDriverModes(tests, options);
    return runDefaultMode(tests, options, colored, width, slowSkipped);
}

/// The driver options shared by the @ctfe, `--better-c`, and `--wasm` modes.
private DriverOptions toDriverOptions(const RunnerOptions options)
{
    return DriverOptions(
        compiler: options.compiler,
        importPaths: options.importPaths.dup,
        includeImports: options.includeImports.dup,
        noAutoInclude: options.noAutoInclude,
        keep: options.keep,
        verbose: options.verbose,
        stringImportPaths: options.stringImportPaths.dup,
        versions: options.versions.dup,
        dflags: options.dflags.dup,
        probeDir: options.probeDir,
        noDub: options.noDub,
        harnessRoots: hello.roots.dup,
        report: consoleReport,
    );
}

/// The modes' messages, on this process's console: their reports on stdout,
/// their diagnostics on stderr.
private ModeReport consoleReport()
{
    import std.stdio : stderr, stdout;

    static void output(string text) @trusted
    {
        stdout.write(text);
        stdout.flush();
    }

    static void diagnostics(string text) @trusted
    {
        stderr.write(text);
    }

    return ModeReport(output: toDelegate(&output), diagnostics: toDelegate(&diagnostics));
}

private auto toDelegate(F)(F fn) @trusted
{
    import std.functional : toDelegate;

    return fn.toDelegate;
}

/// Evaluates the (already filtered) `@ctfe` tests through the driver's probe
/// compile, prints per-test verdict lines plus any compiler output
/// (`__ctfeWrite` text, error trails), and updates `totals`.
private void runCtfeStage(
    in Test[] ctfeTests, in Test[] allTests, in RunnerOptions options,
    bool colored, uint width, ref RunTotals totals, ref TestResult[] failures)
{
    import std.algorithm.searching : canFind;
    import std.stdio : stderr, stdout;

    if (!ctfeTests.length)
        return;

    const outcome = runCtfeTests(ctfeTests, allTests, toDriverOptions(options));
    if (outcome.skipped)
    {
        stderr.writeln("skipping ", ctfeTests.length,
            " @ctfe tests: no D compiler found (set $DC or --compiler)");
        return;
    }

    if (outcome.output.length)
        stdout.write(outcome.output);
    foreach (ref test; ctfeTests)
    {
        // When the errors cannot be attributed to individual tests (e.g. a
        // module failed to compile), every selected test counts as failed.
        const failed = !outcome.succeeded
            && (!outcome.failedNames.length || outcome.failedNames.canFind(test.name));
        if (failed)
        {
            stdout.writeln(formatCtfeFailedLine(test, colored, width));
            totals.failed++;
            failures ~= TestResult(test: test, succeeded: false);
        }
        else
        {
            stdout.writeln(formatCtfeLine(test, colored, width));
            totals.ctfePassed++;
        }
    }
}

/// `--better-c` / `--wasm`: extract the annotated tests and exercise them in
/// their special environment via external compilation.
private UnitTestResult runDriverModes(Test[] tests, in RunnerOptions options)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import sparkles.test_runner.driver : runBetterCTests, runWasmBareTests, runWasmTests;

    const driverOptions = toDriverOptions(options);

    size_t executed, passed;
    bool failed;

    // A skip means the toolchain was missing, which is deliberately not a
    // failure — a contributor without wasm-ld should not see a red run.
    // In CI that is exactly backwards: a job whose whole purpose is to
    // exercise these modes would go green having run nothing, so
    // `--require-toolchain` turns the skip into a failure there.
    void account(in typeof(runBetterCTests(null, null, driverOptions)) outcome)
    {
        if (outcome.skipped)
        {
            failed |= options.requireToolchain;
            return;
        }
        executed += outcome.testCount;
        passed += outcome.succeeded ? outcome.testCount : 0;
        failed |= !outcome.succeeded;
    }

    if (options.betterC)
        account(runBetterCTests(
            tests.filter!(t => t.traits.isBetterC).array, tests, driverOptions));
    if (options.wasm)
        account(runWasmTests(
            tests.filter!(t => t.traits.isWasm).array, tests, driverOptions));
    if (options.wasmBare)
        account(runWasmBareTests(
            tests.filter!(t => t.traits.isWasm).array, tests, driverOptions));

    return UnitTestResult(failed ? (executed ? executed : 1) : executed, passed, false, false);
}

/// `--ctfe-trace <file>`: evaluate the `@ctfe` tests with LDC's
/// `-ftime-trace` enabled (writing the trace to `file`) and attribute the
/// recorded CTFE cost to the individual tests.
private UnitTestResult runCtfeTraceMode(Test[] tests, in RunnerOptions options, bool colored)
{
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import std.file : readText;
    import std.stdio : stderr, stdout;
    import sparkles.test_runner.ctfe_trace : attributeCtfeCosts, parseCtfeEvents;
    import sparkles.test_runner.reporting : render, writeCtfeTraceTable;

    auto ctfeTests = tests.filter!(t => t.traits.isCtfe).array;
    if (!ctfeTests.length)
    {
        stdout.writeln("no @ctfe tests found");
        return UnitTestResult(0, 0, false, false);
    }

    const compiler = detectCompiler(options.compiler, consoleReport);
    if (!compiler.canFind("ldc"))
    {
        stderr.writeln("--ctfe-trace requires an LDC compiler for -ftime-trace " ~
            "(set $DC or --compiler)");
        return UnitTestResult(1, 0, false, false);
    }

    const outcome = runCtfeTests(
        ctfeTests, tests, toDriverOptions(options), options.ctfeTrace);
    if (!outcome.succeeded)
    {
        stderr.write(outcome.output);
        // Distinguish "the tests failed" from "the trace file could not be
        // produced" (an uncreatable directory, or LDC's `Error: Error writing
        // -ftime-trace profile: could not open ...`) — blaming the tests for a
        // filesystem problem sends the user fixing the wrong thing.
        const envProblem = outcome.output.canFind("--ctfe-trace:")
            || (outcome.output.canFind("-ftime-trace") && outcome.output.canFind("rror"));
        if (envProblem)
            stderr.writeln(render(colored,
                i"{red --ctfe-trace}: could not produce $(options.ctfeTrace) (see above)"));
        else
            stderr.writeln(render(colored,
                i"{red @ctfe evaluation failed} — fix the tests before tracing"));
        return UnitTestResult(ctfeTests.length, 0, false, false);
    }

    string traceJson;
    try
        traceJson = readText(options.ctfeTrace);
    catch (Exception e)
    {
        stderr.writeln("--ctfe-trace: cannot read '", options.ctfeTrace, "': ", e.msg);
        return UnitTestResult(ctfeTests.length, 0, false, false);
    }
    const costs = attributeCtfeCosts(ctfeTests, parseCtfeEvents(traceJson));
    stdout.write(formatted!writeCtfeTraceTable(costs, colored));
    return UnitTestResult(ctfeTests.length, ctfeTests.length, false, false);
}

/// `--list`: one line per test with its special-handling markers.
private UnitTestResult listTests(Test[] tests, bool colored)
{
    import std.stdio : stdout;
    import sparkles.test_runner.attributes : ThreadAffinity;
    import sparkles.test_runner.reporting : render;

    auto writer = stdout.lockingTextWriter;
    foreach (test; tests)
    {
        const moduleName = test.moduleName;
        string markers;
        if (test.traits.isCtfe)
            markers ~= " @ctfe";
        if (test.traits.isBenchmark)
            markers ~= " @benchmark";
        if (test.traits.isWorkload)
            markers ~= " @workload";
        if (test.traits.isBetterC)
            markers ~= " @betterC";
        if (test.traits.isWasm)
            markers ~= " @wasm";
        if (test.traits.isSlow)
            markers ~= " @slow";
        if (test.traits.isSerial)
            markers ~= test.traits.serialAffinity == ThreadAffinity.mainThread
                ? " @serial(mainThread)" : " @serial";
        writer.put(render(colored,
            i" {dim $(moduleName)} $(test.name){cyan $(markers)}\n"));
    }
    return UnitTestResult(0, 0, false, false);
}

/// The default mode: evaluate the selected `@ctfe` tests through the probe
/// compile, run every regular test in parallel, and count skipped benchmarks
/// (and the `slowSkipped` tests `--skip-slow` left out before this point).
private UnitTestResult runDefaultMode(Test[] tests, in RunnerOptions options, bool colored, uint width,
    size_t slowSkipped)
{
    import core.atomic : atomicOp;
    import std.algorithm.iteration : filter;
    import std.array : array;
    import sparkles.base.hw_caps : hwParallelism;
    import std.stdio : stdout;

    RunTotals totals;
    totals.slowSkipped = slowSkipped;
    const started = MonoTime.currTime;
    TestResult[] failures;

    foreach (test; tests)
    {
        if (test.traits.isCtfe)
            continue;
        if (test.traits.isBenchmark)
            totals.benchSkipped++;
        else if (test.traits.isWorkload)
            totals.workloadSkipped++;
    }

    runCtfeStage(tests.filter!(t => t.traits.isCtfe).array, tests,
        options, colored, width, totals, failures);

    auto runnable = tests
        .filter!(t => !t.traits.isCtfe && !t.traits.isBenchmark && !t.traits.isWorkload)
        .array;

    shared size_t passed, failed, skipped;
    const threads = options.threads ? options.threads : hwParallelism();

    foreach (phase; testPhases(runnable, threads))
    {
        if (!phase.tests.length)
            continue;
        bool ranLive = false;
        static if (hasLiveRegion)
        {
            // The same animate-or-not policy as the bench spinner (tty and no
            // color opt-outs), asked about stdout — the line redraws beneath the
            // streamed result lines there.
            if (progressEnabled(options.noColors, stderrStream: false))
            {
                runParallelLive(phase.tests, options, colored, width, phase.threads,
                    passed, failed, skipped, failures, phase.onCaller);
                ranLive = true;
            }
        }
        if (!ranLive)
        {
            import sparkles.base.sync.mutex : Mutex;

            Mutex mutex;
            auto workers = startTestWorkers(phase.tests, phase.threads, (result) {
                auto output = capturedOutput(result) ~ formatResultLine(result, colored, options.verbose, width) ~ "\n";
                foreach (thrown; result.thrown)
                    output ~= formatThrown(thrown, colored, options.verbose);
                stdout.lockingTextWriter.put(output);
                stdout.flush();

                if (result.skipped)
                    atomicOp!"+="(skipped, size_t(1));
                else
                    atomicOp!"+="(result.succeeded ? passed : failed, size_t(1));
                if (!result.succeeded && !result.skipped)
                {
                    auto held = mutex.guard();
                    failures ~= result;
                }
            }, phase.onCaller);
            joinTestWorkers(workers);
        }
    }

    totals.passed = passed;
    totals.failed += failed; // ctfe failures are already counted
    // Skipped tests count in neither executed nor passed below (like
    // benchSkipped), so a skip never fails the run — the yellow summary
    // segment is the surfacing.
    totals.skipped = skipped;

    stdout.writeln;
    stdout.writeln(formatSummary(totals, MonoTime.currTime - started, colored));
    if (failures.length)
    {
        import std.algorithm.sorting : sort;

        failures.sort!((a, b) => a.test.fullName < b.test.fullName);
        const packageSelector = rerunPackageSelector(testBinary);
        stdout.write(formatFailedRecap(failures, colored,
            options.verbose, packageSelector));
    }

    const executed = totals.passed + totals.failed + totals.ctfePassed;
    return UnitTestResult(executed, totals.passed + totals.ctfePassed, false, false);
}

/// `--bench`: measure every `@benchmark` test serially and print the table.
/// With `--perf`, a hardware-counter counting pass runs per benchmark and the
/// table gains IPC / instruction / miss-rate columns.
private UnitTestResult runBenchMode(Test[] tests, in RunnerOptions options, bool colored)
{
    import std.algorithm.iteration : filter, splitter;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import std.stdio : stderr, stdout;
    import sparkles.test_runner.bench_client : BenchCase, measure, probe, register, workload;
    import sparkles.test_runner.workload : WorkloadOutcome;
    import sparkles.test_runner.bench_session : BenchOptions, MetricsListing;
    import sparkles.test_runner.metrics : pfmSelectorNames;
    import sparkles.test_runner.pool : retire, takeWorker;

    // One worker measures everything, with no other test running (TRS3).
    auto worker = takeWorker();
    scope (exit)
        retire(worker);

    // The worker opens the counting passes the options select and reports
    // what is absent or degraded; the header lines are its words (TRP21).
    const benchOptions = BenchOptions(perf: options.perf, perfScaled: options.perfScaled,
        perfIters: options.perfIters, syscalls: options.syscalls, metrics: options.metrics);
    const listing = options.listMetrics || options.metrics == "?" || options.metrics == "help";
    MetricsListing metricsListing;
    const probed = probe(worker, benchOptions, listing, metricsListing);
    foreach (note; probed.notes)
        stderr.writeln(note);
    const syscallNames = probed.syscallNames;
    const rawEvents = probed.rawEvents;

    // --list-metrics (also --metrics=? / --metrics=help): print the catalog,
    // the per-backend capability block, and exit. The worker probed every
    // source for its true availability regardless of the flags; client
    // metrics can't be listed without running, so they're just noted.
    if (listing)
    {
        stdout.write(formatted!writeMetricCatalog(metricsListing.catalog, colored));
        stdout.writeln;
        stdout.write(formatCapabilityBlock(metricsListing.blocks, colored));
        if (metricsListing.wallNote.length)
            stdout.writeln(metricsListing.wallNote);
        stdout.writeln("client throughput/level metrics are defined per @benchmark and appear when present.");
        return UnitTestResult(0, 0, false, false);
    }

    // Benchmark numbers from an assert-enabled (debug) build routinely read
    // several times off an optimized build's — say so up front, once per run,
    // instead of letting authoritative-looking tables mislead. (dub's stock
    // `unittest` build type is debug; a consumer wanting real numbers defines
    // a release buildType with the `unittests` option — see the docs.) The
    // binary's build decides, not the runner's.
    if (hello.asserts)
        stderr.writeln("warning: assert-enabled build — benchmark numbers may be ",
            "meaningless; use an optimized unittest buildType (e.g. dub test -b bench)");

    import std.algorithm.mutation : SwapStrategy;
    import std.algorithm.sorting : sort;
    import std.range : iota;
    import sparkles.test_runner.metrics : canonicalSortKey, catalog,
        groupKeyDisplay, groupKeyOf, matchesMetricGlob, unknownMetricSelectors;

    auto benchTests = tests.filter!(t => t.traits.isBenchmark).array;

    // A worker that a case crashed is replaced by one in the same state: the
    // sources open and every test registered again, in the same order, so a
    // case keeps its id (TRP26).
    Worker restartBenchWorker()
    {
        auto fresh = takeWorker();
        MetricsListing unused;
        cast(void) probe(fresh, benchOptions, false, unused);
        foreach (test; benchTests)
            cast(void) register(fresh, test, benchConfigFor(options.benchMinTime,
                test.traits.benchIterations, options.perfIters, options.perfBatch));
        return fresh;
    }

    // Register every @benchmark test's cases (running each body once, no
    // measurement). Cases sharing a streaming key are measured and printed
    // together — one table per group as it finishes.
    static struct Sched
    {
        BenchCase c;
        Test test;
        BenchConfig config;
        string key;
    }

    Sched[] all;
    string[] provenance;
    size_t failed;
    BenchProgress progress; // inert (active=false) until populated after registration
    void reportFailure(in TestResult result)
    {
        failed++;
        progress.clear(); // erase any spinner before the failure lines (no-op if inert)
        stdout.write(formatResultLine(result, colored, true), "\n");
        foreach (thrown; result.thrown)
            stdout.write(formatThrown(thrown, colored, true));
    }

    foreach (test; benchTests)
    {
        const config = benchConfigFor(options.benchMinTime, test.traits.benchIterations,
            options.perfIters, options.perfBatch);
        auto reg = register(worker, test, config);
        provenance ~= reg.provenance;
        if (reg.result.skipped)
        {
            // A registration-time skipTest: the ⊘ line with its reason; the
            // test contributes no rows and does not fail the run.
            progress.clear();
            stdout.write(formatResultLine(reg.result, colored, options.verbose), "\n");
            continue;
        }
        if (!reg.result.succeeded)
            reportFailure(reg.result); // still schedule the cases it did register
        foreach (c; reg.cases)
            all ~= Sched(c, test, config, null); // key resolved once label keys are known
    }

    // Suite provenance registered during the bodies above (or in module
    // constructors): one header line each, on stderr like every other note,
    // so piped stdout stays byte-stable.
    foreach (line; provenance)
        stderr.writeln("provenance: ", line);

    // Collect distinct dataset labels across registered cases
    bool[string] datasetSet;
    foreach (ref s; all)
        if (auto ds = "dataset" in s.c.labels)
            datasetSet[*ds] = true;
    auto allDatasets = datasetSet.keys.sort.release;

    // --list-datasets / --datasets=? / --datasets=help : list available datasets and exit
    if (options.listDatasets || options.datasets == "?" || options.datasets == "help")
    {
        if (allDatasets.length == 0)
            stdout.writeln("no @benchmark cases carry a dataset label");
        else
        {
            DatasetInfo[] infos;
            foreach (ds; allDatasets)
            {
                DatasetInfo info;
                info.name = ds;
                bool[string] ops;
                foreach (ref s; all)
                {
                    if (auto dsp = "dataset" in s.c.labels)
                    {
                        if (*dsp == ds)
                        {
                            info.caseCount++;
                            if (auto tp = "tier" in s.c.labels)
                                info.tier = *tp;
                            if (auto op = "operation" in s.c.labels)
                                ops[*op] = true;
                            foreach (m; s.c.metrics)
                            {
                                if (m.unit.symbol == "B" || m.unit.symbol == "byte" || m.unit.symbol == "bytes")
                                {
                                    if (m.amount > info.byteSize)
                                        info.byteSize = cast(ulong) m.amount;
                                }
                            }
                        }
                    }
                }
                info.operations = ops.keys.sort.release;
                infos ~= info;
            }
            stdout.write(formatted!writeDatasetCatalog(infos, colored));
            stdout.writeln;
        }
        return UnitTestResult(failed, 0, false, false);
    }

    // --datasets=... filter: keep only matching cases and warn on unmatched selectors
    if (options.datasets.length && options.datasets != "all")
    {
        import std.algorithm.iteration : splitter;
        import std.algorithm.searching : any;

        auto patterns = options.datasets.splitter(',').array;
        foreach (p; patterns)
            if (!allDatasets.any!(ds => matchesMetricGlob(ds, p)))
                stderr.writeln("--datasets: no @benchmark case has dataset '", p, "'");

        all = all.filter!((s) {
            if (auto ds = "dataset" in s.c.labels)
                return patterns.any!(p => matchesMetricGlob(*ds, p));
            return true;
        }).array;
    }

    // The label keys available to --group-by: the sorted union across all cases.
    bool[string] keySet;
    foreach (ref s; all)
        foreach (k; s.c.labels.byKey)
            keySet[k] = true;
    auto allKeys = keySet.keys.sort.release;

    // --group-by=list/help/? : print the available label keys and exit — still
    // reporting a registration failure (the printed keys may be incomplete when
    // a @benchmark body threw, and a query must not turn that into exit 0).
    if (options.groupBy == ["list"] || options.groupBy == ["help"] || options.groupBy == ["?"])
    {
        if (allKeys.length == 0)
            stdout.writeln("no @benchmark labels to group by");
        else
        {
            stdout.writeln("--group-by label keys (=all for every key, or a comma list):");
            foreach (k; allKeys)
                stdout.writeln("  ", k);
        }
        return UnitTestResult(failed, 0, false, false);
    }

    // Effective group keys: =all → every label key; else the given keys (empty =
    // no grouping), warning for any key no registered case carries.
    const(string)[] keys = options.groupBy;
    if (options.groupBy == ["all"])
        keys = allKeys;
    foreach (k; keys)
        if (!allKeys.canFind(k))
            stderr.writeln("--group-by: no @benchmark case has label '", k, "'");

    // Ungrouped runs stream one table per *test*; key by the module-qualified
    // fullName so two @benchmark tests sharing a display name in different
    // modules don't merge into one table.
    foreach (ref s; all)
        s.key = keys.length ? groupKeyOf(s.c.labels, keys) : s.test.fullName;

    // `sc:<name>` (the displayed header) and `syscalls:<name>` (the column id
    // `sortValue` matches on) are the same column; sort by the canonical id.
    const sortBy = canonicalSortKey(options.sortBy);

    // One validation universe for the --metrics/--sort-by typo warnings: the
    // client columns the registered cases mint, the static perf/tier0 families
    // (name validity is independent of availability), and the syscall columns
    // this run can carry — the total plus every requested tracepoint.
    string[] knownColumns;
    {
        import std.algorithm.iteration : map;

        auto synthetic = all.map!(s => BenchStats(name: s.c.name, metrics: s.c.metrics)).array;
        knownColumns = catalog(synthetic).map!(d => d.name).array ~ "syscalls";
        foreach (n; syscallNames)
            knownColumns ~= "syscalls:" ~ n;
        // Both the id and the displayed header sort/validate (r04c2 for
        // raw:r04c2), matching sortValue's header fallback.
        foreach (ref ev; rawEvents)
        {
            import sparkles.profiling.counters.raw : rawHeader;

            knownColumns ~= ev.id;
            knownColumns ~= rawHeader(ev.id);
        }
        // A pfm name that failed resolution already warned; keep it out of the
        // unknown-selector list so it is not flagged twice.
        foreach (n; pfmSelectorNames(options.metrics))
            knownColumns ~= "pfm:" ~ n;
    }

    // Warn on selectors that match nothing (mirrors --group-by/--sort-by), so a
    // typo isn't a silently missing column.
    foreach (p; unknownMetricSelectors(knownColumns, options.metrics))
        stderr.writeln("--metrics: no metric column matches '", p,
            "' — see --list-metrics");

    // Warn on a --sort-by that names no orderable column, so a typo isn't
    // silently ignored (it would fall back to discovery order).
    if (sortBy.length && sortBy != "name" && sortBy != "median/iter"
        && !knownColumns.canFind(sortBy))
        stderr.writeln("--sort-by: no metric column named '", options.sortBy,
            "' — rows keep their default order");

    // Schedule: contiguous by key, keys in ascending order (stable within a key).
    auto order = iota(all.length).array;
    order.sort!((i, j) => all[i].key < all[j].key, SwapStrategy.stable);

    // The live results table (the "bench ticker"): on an interactive stdout
    // the current group's table repaints in place, growing a row per measured
    // case, with a dim spinner row for the case in flight; it graduates into
    // scrollback when the group completes. Frames render only at case
    // boundaries — no painter thread, so no GC or terminal work runs
    // concurrently with a measurement. While the ticker is on, the stderr
    // spinner stays off (one animation); a run with stdout redirected but
    // stderr on the terminal keeps today's spinner instead.
    static if (hasBenchTicker)
        const bool ticker = all.length > 0
            && progressEnabled(options.noColors, stderrStream: false);
    else
        enum bool ticker = false;

    progress = BenchProgress(total: all.length,
        active: !ticker && progressEnabled(options.noColors) && all.length > 0,
        width: detectTerminalWidth(stderrStream: true));

    size_t totalRows, errorRows;
    bool firstFlush = true;
    BenchStats[] bucket;
    BenchStats[] measured; // run-long, for --bench-json (measurement order)
    TableGeometry geometry; // run-long column floors: streamed tables only widen
    string curKey;

    static if (hasBenchTicker)
    {
        import sparkles.ui.components.live : LiveRegion, stdoutLiveRegion;
        import sparkles.test_runner.reporting : benchFrameLines;

        LiveRegion region;   // one per streamed group while the ticker is on
        bool regionLive;
        size_t nameFloor;    // widest roster name of the group + spinner prefix
        size_t spin;

        // The group's stub-column floor: `⠹ name` must fit for every roster
        // case up front, so the in-flight row never resizes the table.
        size_t rosterNameFloor(string key)
        {
            import std.algorithm.comparison : max;
            import sparkles.base.text.grapheme : visibleWidth;

            size_t w;
            foreach (ref e; all)
                if (e.key == key)
                    w = max(w, visibleWidth(e.c.name));
            return w + 2;
        }

        void tickerFrame(BenchStats inflight)
        {
            if (!regionLive)
                return;
            region.update(benchFrameLines(bucket, inflight, spin++, colored,
                options.metrics, sortBy, keys, nameFloor, geometry));
        }
    }

    void flush()
    {
        if (bucket.length == 0)
            return;
        progress.clear(); // erase the spinner before the table
        static if (hasBenchTicker)
        {
            if (regionLive)
            {
                // The final frame (no in-flight row) graduates into scrollback;
                // it is line-identical to the flushed table (drawTableLines /
                // drawTable parity), so nothing is re-printed. The frames
                // already carried `geometry` forward.
                tickerFrame(BenchStats.init);
                region.finish(keepFrame: true);
                regionLive = false;
                firstFlush = false;
                bucket = null;
                return;
            }
        }
        if (!firstFlush)
            stdout.write("\n"); // blank line between group tables
        {
            // Directly, not through `formatted`: the geometry is updated.
            auto w = stdout.lockingTextWriter;
            writeBenchTable(w, bucket, colored, options.metrics, sortBy, keys, &geometry);
        }
        stdout.flush(); // on screen before the next tick redraws the spinner below
        firstFlush = false;
        bucket = null;
    }

    foreach (idx; order)
    {
        auto s = all[idx];
        if (bucket.length && s.key != curKey)
            flush();
        curKey = s.key;

        static if (hasBenchTicker)
            if (ticker && !regionLive)
            {
                if (!firstFlush)
                {
                    stdout.write("\n"); // blank line between graduated tables
                    stdout.flush();
                }
                region = stdoutLiveRegion();
                regionLive = true;
                nameFloor = rosterNameFloor(s.key);
            }

        // Spinner label: the group + the case name when grouping (`name` alone is
        // just the varying dimension), else the case name.
        progress.tick(keys.length ? groupKeyDisplay(s.key) ~ "  " ~ s.c.name : s.c.name);
        static if (hasBenchTicker)
            tickerFrame(BenchStats(name: s.c.name, labels: s.c.labels));
        {
            import sparkles.test_runner.bench : errorRow;
            import sparkles.test_runner.client : WorkerDied;
            import sparkles.test_runner.model : Thrown;

            // The worker isolates what the measurement threw: a skipTest is a
            // yellow skipped row, and a hard throw an error row in its group
            // table with its trace beside it, counted once via the error-row
            // path — not the separate `failed` tally.
            immutable(Thrown)[] thrown;
            BenchStats row;
            try
                row = measure(worker, s.c.id, s.config, thrown);
            catch (WorkerDied e)
            {
                // The case crashed its worker: an error row, and a new worker
                // with every case registered again, in the same order, so
                // the case ids still hold (TRP26).
                thrown = [Thrown(type: "worker crashed",
                    message: "the test binary " ~ e.ending ~ " while measuring this case")];
                row = errorRow(s.c.name, s.c.labels, thrown);
                if (e.output.length)
                    stdout.write(e.output);
                worker = restartBenchWorker();
            }
            if (row.error.length && !row.skipped)
                errorRows++;
            bucket ~= row;
            measured ~= row;
            totalRows++;
            if (thrown.length)
            {
                progress.clear();
                bool printedAbove = false;
                static if (hasBenchTicker)
                    if (regionLive)
                    {
                        // Permanent lines above the live frame — the frame repaints
                        // beneath them (`runParallelLive`'s pattern).
                        import std.string : lineSplitter;

                        foreach (th; thrown)
                            foreach (line; formatThrown(th, colored, true).lineSplitter)
                                region.printAbove(line);
                        printedAbove = true;
                    }
                if (!printedAbove)
                    foreach (th; thrown)
                        stdout.write(formatThrown(th, colored, true));
            }
        }
    }
    flush();
    progress.clear();

    // The @workload window phase (SPEC §4): measured after the bench groups,
    // rendered as one plain table at the end. No live repaint during any
    // window — for a handful of long single-pass windows the stderr spinner
    // is disclosure enough, and keeping display I/O out of measurement is
    // the model's point.
    import sparkles.test_runner.workload : WorkloadWindow;

    auto workloadTests = tests.filter!(t => t.traits.isWorkload).array;
    WorkloadWindow[] windows;
    if (workloadTests.length)
    {
        progress = BenchProgress(total: workloadTests.length,
            active: progressEnabled(options.noColors) && workloadTests.length > 0,
            width: detectTerminalWidth(stderrStream: true));
        foreach (test; workloadTests)
        {
            import sparkles.test_runner.client : WorkerDied;

            progress.tick(test.name);
            // The worker opens the wall and PSI sources on the first window,
            // and discloses a degraded decomposition once per run, like the
            // perf header notes.
            string[] notes;
            WorkloadOutcome outcome;
            try
                outcome = workload(worker, test, notes);
            catch (WorkerDied e)
            {
                outcome.result = Worker.crashed(test, e);
                worker = restartBenchWorker();
            }
            foreach (note; notes)
            {
                progress.clear();
                stderr.writeln(note);
            }
            if (outcome.result.skipped)
            {
                progress.clear();
                stdout.write(formatResultLine(outcome.result, colored,
                    options.verbose), "\n");
            }
            else if (!outcome.result.succeeded)
            {
                // A throw inside a window already produced an error row —
                // count it once via the error-row path (bench parity) and
                // print only the trace; a body failure outside any window
                // has no row and goes through the full failure tally.
                const hasErrorWindow = outcome.windows
                    .canFind!(w => w.error.length && !w.skipped);
                if (hasErrorWindow)
                {
                    progress.clear();
                    foreach (thrown; outcome.result.thrown)
                        stdout.write(formatThrown(thrown, colored, true));
                }
                else
                    reportFailure(outcome.result);
            }
            foreach (ref w; outcome.windows)
            {
                if (w.error.length && !w.skipped)
                    errorRows++;
                totalRows++;
            }
            windows ~= outcome.windows;
        }
        progress.clear();
        if (windows.length)
        {
            if (!firstFlush)
                stdout.write("\n"); // blank line between the bench tables and this one
            stdout.write(formatted!writeWorkloadTable(windows, colored));
            firstFlush = false;
        }
    }

    if (totalRows == 0 && !failed)
        stdout.writeln("no @benchmark or @workload tests found");

    if (options.benchJson.length)
    {
        import std.file : write;
        import sparkles.test_runner.bench_json : benchReportJson, collectBenchMeta;

        // The meta block records the effective knobs (an empty run still writes
        // a valid document, deterministic for tooling) plus any registered
        // suite-provenance lines, so the artifact is self-describing.
        auto meta = collectBenchMeta(benchConfigFor(options.benchMinTime, 0,
            options.perfIters, options.perfBatch));
        meta.provenance = provenance;
        // The binary was compiled by its own compiler, not the runner's.
        meta.compiler = compilerDescription(hello);
        try
            write(options.benchJson, benchReportJson(measured, meta, windows));
        catch (Exception e)
        {
            stderr.writeln("--bench-json: cannot write '", options.benchJson,
                "': ", e.msg);
            failed++; // → executed > passed in the returned result: non-zero exit
        }
    }

    return UnitTestResult(totalRows + failed, totalRows - errorRows, false, false);
}

/// Whether `sparkles:core-cli` is in the tested package's dependency closure
/// (see `reporting.d` for the pattern) — its `detectTermCaps` is the shared
/// implementation of the console-preparation policy this runner used to inline.
private enum bool hasTermCaps = __traits(compiles, {
    import sparkles.base.term_caps : detectTermCaps;
});

/// The per-test `BenchConfig` under the CLI knobs: `--bench-min-time` overrides
/// the sample-time budget (0 = keep the 5 ms default); a pinned
/// `@benchmark(iterations: N)` count threads through unchanged;
/// `--perf-iters` pins the counting-pass count (0 = follow the timing pass).
private BenchConfig benchConfigFor(uint benchMinTimeMs, uint iterations,
    uint perfItersPin = 0, uint perfBatchPin = 0) @safe pure nothrow @nogc
{
    import core.time : msecs;

    auto config = BenchConfig(iterations: iterations, perfIters: perfItersPin,
        perfBatch: perfBatchPin);
    if (benchMinTimeMs)
        config.minSampleTime = benchMinTimeMs.msecs;
    return config;
}

@("runner.benchConfigFor.minTimeOverride")
@safe pure nothrow @nogc
unittest
{
    import core.time : msecs;

    const pinned = benchConfigFor(0, 7);
    assert(pinned.iterations == 7 && pinned.minSampleTime == 5.msecs);
    const budgeted = benchConfigFor(2000, 0);
    assert(budgeted.minSampleTime == 2000.msecs);
    assert(budgeted.sampleCount == 32, "only the time budget is overridden");
}

/// Prepares the console and reports whether colored output should be used.
/// Delegates to `core-cli`'s `detectTermCaps` (colors off on `--no-colors` /
/// `$NO_COLOR` / `TERM=dumb` / non-tty; Windows UTF-8 code page + VT enable).
/// In `base`'s own test build (no `core-cli` there) a minimal inline fallback
/// keeps the same `--no-colors`/`$NO_COLOR`/tty behaviour.
private bool prepareConsole(bool noColors)
{
    static if (hasTermCaps)
    {
        import sparkles.base.term_caps : detectTermCaps;

        return detectTermCaps(noColors).colors;
    }
    else
    {
        import std.process : environment;

        const disabled = noColors || environment.get("NO_COLOR", "").length != 0;

        version (Posix)
        {
            import core.sys.posix.unistd : isatty, STDOUT_FILENO;

            if (disabled)
                return false;
            return isatty(STDOUT_FILENO) != 0;
        }
        else
            return !disabled;
    }
}

/// Whether the toolkit's live-region components are importable (same pattern as
/// `reporting.d`'s gate: absent when a package source-includes the runner).
private enum bool hasLiveRegion = __traits(compiles, {
    import sparkles.ui.components.live : stdoutLiveRegion;
    import sparkles.ui.components.progress : ProgressLine;
});

/// Likewise for the `--bench` live results table (the "ticker"): a `LiveRegion`
/// repainting `drawTableLines` frames.
private enum bool hasBenchTicker = __traits(compiles, {
    import sparkles.ui.components.live : stdoutLiveRegion;
    import sparkles.ui.components.table : drawTableLines;
});

static if (hasLiveRegion)
/// The tty variant of the parallel run: a polled `N/M` progress line under the
/// streaming result lines. Workers never touch the terminal — they append their
/// finished output to a mutex-guarded queue and bump an atomic counter; the
/// main thread (no longer participating in the work) drains the queue through
/// `printAbove` and repaints one `ProgressLine`, which is erased on completion
/// so the permanent output matches the plain path.
private void runParallelLive(
    Test[] runnable, in RunnerOptions options, bool colored, uint width,
    size_t threads, ref shared size_t passed, ref shared size_t failed,
    ref shared size_t skipped, ref TestResult[] failures, bool onCaller = true)
{
    import core.atomic : atomicLoad, atomicOp;
    import core.thread : Thread;
    import core.time : MonoTime, msecs;
    import std.array : appender;
    import std.string : lineSplitter;
    import sparkles.base.sync.mutex : Mutex;
    import sparkles.ui.components.live : stdoutLiveRegion;
    import sparkles.ui.components.progress : ProgressLine;

    Mutex mutex;
    string[] pendingOutput;
    shared size_t completed;

    auto workers = startTestWorkers(runnable, threads < 1 ? 1 : threads,
        (result) {
            auto output = capturedOutput(result) ~ formatResultLine(result, colored, options.verbose, width) ~ "\n";
            foreach (thrown; result.thrown)
                output ~= formatThrown(thrown, colored, options.verbose);
            {
                auto held = mutex.guard();
                pendingOutput ~= output;
                if (!result.succeeded && !result.skipped)
                    failures ~= result;
            }
            // Same three buckets as the plain path: a skip (yellow ⊘ line) counts
            // in neither passed nor failed, so it never fails the run.
            if (result.skipped)
                atomicOp!"+="(skipped, size_t(1));
            else
                atomicOp!"+="(result.succeeded ? passed : failed, size_t(1));
            atomicOp!"+="(completed, size_t(1)); // after the queue append (see drain)
        }, onCaller);
    scope (exit)
        joinTestWorkers(workers);

    auto region = stdoutLiveRegion();
    scope (exit)
        region.finish(keepFrame: false); // the summary follows; no lasting frame

    const started = MonoTime.currTime;
    size_t spin;
    void drain()
    {
        string[] drained;
        {
            auto held = mutex.guard();
            drained = pendingOutput;
            pendingOutput = null;
        }
        foreach (block; drained)
            foreach (line; block.lineSplitter)
                region.printAbove(line);
    }

    for (;;)
    {
        drain();
        const done = atomicLoad(completed);
        auto bar = appender!string;
        ProgressLine(frame: spin, done: done, total: runnable.length,
            colored: colored, elapsed: MonoTime.currTime - started).toString(bar);
        region.update([bar[]]);
        if (done == runnable.length)
            break;
        spin++;
        Thread.sleep(50.msecs);
    }
    // A worker may append between the final drain and the counter read; the
    // append happens-before its counter increment, so one more drain after
    // observing `completed == length` catches every straggler.
    drain();
}

/// The output a test wrote, ending in a line feed, or nothing: printed above
/// its result line, where it would have appeared had the test run in this
/// process.
private string capturedOutput(const TestResult result) @safe pure nothrow
{
    if (!result.output.length)
        return null;
    return result.output[$ - 1] == '\n' ? result.output : result.output ~ "\n";
}

/// The test binary's compiler, from its `hello`: the format `collectBenchMeta`
/// uses for the runner's own.
private string compilerDescription(const Hello hello)
{
    import std.conv : to;
    import std.format : format;

    long frontEnd;
    try
        frontEnd = hello.compilerVersion.to!long;
    catch (Exception)
        return hello.compilerVendor;
    return format!"%s (front-end %s.%03d)"(hello.compilerVendor, frontEnd / 1000, frontEnd % 1000);
}
