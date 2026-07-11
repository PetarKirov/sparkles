/**
 * The runner entry point, active only in `dub test` builds.
 *
 * Registers itself as druntime's extended module unit tester, discovers every
 * `unittest` in the tested package (via dub's generated `dub_test_root`), and
 * runs them in parallel. Tests annotated with the attributes from
 * $(MREF sparkles,test_runner,attributes) get special handling:
 *
 * $(LIST
 *     * `@ctfe` tests are not executed in-process: after CLI filtering, the
 *       selected ones are forced through CTFE by a driver-generated probe
 *       compiled with `-o- -unittest` (semantic analysis only), so `-i`/`-e`
 *       control which tests evaluate, and `--help`/`--list` never evaluate
 *       any;
 *     * `@benchmark` tests are skipped by default and measured by `--bench`;
 *     * `@betterC` / `@wasm` tests run normally here, and are additionally
 *       exercised in their special environments by `--better-c` / `--wasm`.
 * )
 */
module sparkles.test_runner.runner_impl;

import core.runtime : Runtime, UnitTestResult;
import core.time : Duration, MonoTime;

import sparkles.test_runner.bench : BenchConfig, BenchStats, CounterGroups;
import sparkles.test_runner.capability : Capability, capabilityName, CapabilityReport;
import sparkles.test_runner.driver : detectCompiler, DriverOptions, runCtfeTests;
import sparkles.test_runner.execution : executeTest;
import sparkles.test_runner.filter : matchesFilter;
import sparkles.test_runner.model : Test, TestResult;
import sparkles.test_runner.reporting : BenchProgress, detectTerminalWidth,
    formatBenchTable, formatCapabilityBlock, formatCtfeFailedLine, formatCtfeLine,
    formatMetricCatalog, formatResultLine, formatSummary, formatThrown,
    progressEnabled, RunTotals, TableGeometry;

// ─────────────────────────────────────────────────────────────────────────────
// Entry point — called across the extern(C) seam by the registration shim,
// which has already discovered the tests and computed `hostIsRunner`.
// ─────────────────────────────────────────────────────────────────────────────

extern (C) void sparkles_test_runner_run(
    Test* testsPtr, size_t count, bool hostIsRunner, uint* executed, uint* passed)
{
    version (OSX)
    {
        // druntime resolves macOS stack traces by forking `atos -p <pid>`, which
        // intermittently stalls on sandboxed CI runners and hangs the whole
        // binary the moment a test throws (the runner reads `thrown.info` in
        // `toThrown`). Swap in an in-process handler that keeps the full
        // backtrace but never spawns atos. See `sparkles.test_runner.macos_trace`.
        import sparkles.test_runner.macos_trace : installInProcessTraceHandler;

        installInProcessTraceHandler();
    }

    const result = runnerMain(testsPtr[0 .. count], hostIsRunner);
    *executed = cast(uint) result.executed;
    *passed = cast(uint) result.passed;
}

private struct RunnerOptions
{
    string include;
    string exclude;
    bool verbose;
    uint threads;
    bool noColours;
    bool list;
    bool bench;
    bool perf;
    string syscalls;
    string metrics;
    string sortBy;
    string[] groupBy;
    string benchJson;  /// --bench-json=FILE ("" = off)
    uint benchMinTime; /// --bench-min-time=MS (0 = BenchConfig's 5 ms default)
    bool listMetrics;
    string ctfeTrace;
    bool betterC;
    bool wasm;
    string compiler;
    string[] importPaths;
    string[] includeImports;
    bool keep;
    bool selfTest;
}

/// Whether `test` belongs to the runner itself. In-monorepo hosts compile the
/// runner via `sourcePaths`, which puts its modules into `allModules`; hide
/// their tests unless `--self-test` is given or the tested package $(I is)
/// the runner.
private bool isSelfTest(in Test test) @safe pure nothrow @nogc
{
    enum prefix = "sparkles.test_runner.";
    return test.fullName.length > prefix.length
        && test.fullName[0 .. prefix.length] == prefix;
}

/// Whether this test build is `dub test :test-runner` (whose suite $(I is) the
/// runner's own tests). `hostIsRunner` (every module belongs to the runner) is
/// the compile-time half, computed by the registration shim and passed in; the
/// test-binary-name check is the runtime half.
private bool testingRunnerItself(bool hostIsRunner)
{
    import std.algorithm.searching : canFind;
    import std.path : baseName;

    if (!hostIsRunner)
        return false;
    auto args = Runtime.args;
    return args.length && args[0].baseName.canFind("test-runner");
}

/// The outcome of CLI parsing: either a populated `options`, a request for the
/// help text, or a one-line `error` — never a thrown exception, which would
/// escape the unittest hook as a raw stack trace.
private struct ParsedArgs
{
    import std.getopt : Option;

    RunnerOptions options;
    string error; /// non-empty = fail the run with this message
    bool helpWanted;
    Option[] helpOptions; /// populated when `helpWanted`
}

/// Parses the runner's CLI. A malformed value (`-t abc`), an unknown option,
/// and stray positional arguments (`--syscalls futex` — values attach with
/// `=`) all yield a readable `error` instead of an uncaught exception.
package ParsedArgs parseRunnerOptions(string[] args)
{
    import std.conv : ConvException, text;
    import std.getopt : arraySep, config, getopt, GetOptException;

    ParsedArgs r;
    // Comma-separated array options (`--group-by=dataset,operation`, repeatable
    // `-I` paths) split on `,` in addition to accumulating across occurrences.
    arraySep = ",";
    // `--syscalls` takes an optional value (bare = total only), which std.getopt
    // can't express directly; rewrite a bare occurrence to the `*` sentinel.
    foreach (ref arg; args)
        if (arg == "--syscalls")
            arg = "--syscalls=*";
    try
    {
        auto res = parseInto(args, r.options);
        r.helpWanted = res.helpWanted;
        r.helpOptions = res.options;
    }
    catch (GetOptException e)
        r.error = e.msg;
    catch (ConvException e)
        r.error = e.msg;
    if (!r.error.length && args.length > 1)
        r.error = text("unexpected positional argument", args.length > 2 ? "s " : " ",
            args[1 .. $], " — attach option values with '=' (e.g. --syscalls=futex)");
    return r;
}

/// The getopt call proper (separated so `parseRunnerOptions` can guard it).
private auto parseInto(ref string[] args, ref RunnerOptions options)
{
    import std.getopt : config, getopt;

    return args.getopt(
        config.caseSensitive,
        "i|include",
            "Run only tests whose name matches the regular expression",
            &options.include,
        "e|exclude",
            "Skip tests whose name matches the regular expression",
            &options.exclude,
        "v|verbose",
            "Show durations, locations, and full stack traces",
            &options.verbose,
        "t|threads",
            "Number of worker threads (0 = auto-detect)",
            &options.threads,
        "no-colours",
            "Disable colored output",
            &options.noColours,
        "l|list",
            "List discovered tests without running them",
            &options.list,
        "bench",
            "Run @benchmark tests instead of regular tests",
            &options.bench,
        "perf",
            "With --bench: collect hardware performance counters per benchmark " ~
            "(Linux perf_event; IPC, instructions, cache/branch miss rates)",
            &options.perf,
        "syscalls",
            "With --bench: count syscalls per iteration (Linux perf tracepoints). " ~
            "Bare adds a total column; =futex,sched_yield adds one column each",
            &options.syscalls,
        "metrics",
            "With --bench: comma-separated metric columns to show (glob with '*'; " ~
            "'all' = every available; '?'/'help' = list them). Default: standard columns",
            &options.metrics,
        "sort-by",
            "With --bench: sort rows by 'name' or a metric column name " ~
            "(default: median/iter, ascending). Applied within --group-by groups",
            &options.sortBy,
        "group-by",
            "With --bench: split into one table per group of the given case label " ~
            "keys (comma-separated or repeated), e.g. =dataset,operation. " ~
            "=all groups by every label; =list lists the available keys",
            &options.groupBy,
        "bench-json",
            "With --bench: also write the results as JSON to the given file " ~
            "(all rows in measurement order, incl. error rows, plus a meta block)",
            &options.benchJson,
        "bench-min-time",
            "With --bench: per-case measurement budget in milliseconds — per-call " ~
            "cases: minimum total measured time; batched: target per sample. Default 5",
            &options.benchMinTime,
        "list-metrics",
            "With --bench: list the available metric columns (name, class, source) and exit",
            &options.listMetrics,
        "ctfe-trace",
            "Evaluate @ctfe tests under LDC -ftime-trace (writing the trace " ~
            "to the given file) and report per-test CTFE cost",
            &options.ctfeTrace,
        "better-c",
            "Extract @betterC tests, compile them with -betterC, and run them",
            &options.betterC,
        "wasm",
            "Extract @wasm tests, cross-compile them to wasm32, and run them",
            &options.wasm,
        "compiler",
            "D compiler for @ctfe/--better-c/--wasm (default: $DC, then ldc2, dmd)",
            &options.compiler,
        "I|import-path",
            "Extra import path for @ctfe/--better-c/--wasm (repeatable)",
            &options.importPaths,
        "include-import",
            "Extra -i=<pattern> for --better-c/--wasm, e.g. std.ascii (repeatable)",
            &options.includeImports,
        "keep",
            "Keep the files generated by @ctfe/--better-c/--wasm",
            &options.keep,
        "self-test",
            "Also run the test runner's own unittests",
            &options.selfTest,
    );
}

@("runner.parseRunnerOptions.readableErrors")
@system
unittest
{
    // Parse failures become messages, never uncaught exceptions out of the
    // unittest hook; stray positionals (the `--syscalls futex` trap) error too.
    assert(parseRunnerOptions(["prog", "-t", "abc"]).error.length);
    assert(parseRunnerOptions(["prog", "--bogus"]).error.length);
    assert(parseRunnerOptions(["prog", "--syscalls", "futex"]).error.length);

    auto ok = parseRunnerOptions(["prog", "--syscalls", "-t", "4"]);
    assert(!ok.error.length);
    assert(ok.options.syscalls == "*" && ok.options.threads == 4);

    auto help = parseRunnerOptions(["prog", "--help"]);
    assert(!help.error.length && help.helpWanted && help.helpOptions.length);
}

private UnitTestResult runnerMain(Test[] discovered, bool hostIsRunner)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.stdio : stderr, stdout;

    auto parsed = parseRunnerOptions(Runtime.args);
    if (parsed.error.length)
    {
        stderr.writeln("error: ", parsed.error, " (see --help)");
        return UnitTestResult(1, 0, false, false);
    }
    RunnerOptions options = parsed.options;

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

    // The run modes are mutually exclusive; silently preferring one (the old
    // behavior) turned e.g. `--ctfe-trace f --bench` into a false green — the
    // requested trace was never written, yet the run exited 0. `--list` /
    // `--list-metrics` remain winning queries on top of any mode.
    const requestedModes = (options.bench ? 1 : 0)
        + (options.ctfeTrace.length ? 1 : 0)
        + (options.betterC || options.wasm ? 1 : 0);
    if (requestedModes > 1)
    {
        stderr.writeln("error: pick one mode — --bench, --ctfe-trace, or --better-c/--wasm");
        return UnitTestResult(1, 0, false, false);
    }

    const colored = prepareConsole(options.noColours);
    // Cells available for the compact result lines; `0` (unknown / piped) skips
    // truncation so redirected output stays byte-identical.
    const width = detectTerminalWidth();

    // Hide the runner's own tests unless requested — or unless the tested
    // package is the runner itself, in which case they are the test suite.
    if (!options.selfTest && !testingRunnerItself(hostIsRunner))
        discovered = discovered.filter!(t => !t.isSelfTest).array;

    // Validate the user-supplied patterns once up front: a malformed regex
    // would otherwise throw `RegexException` out of this unittest hook and crash
    // the run with a raw stack trace instead of a readable message.
    {
        import std.regex : regex, RegexException;
        import std.stdio : stderr;

        try
        {
            if (options.include.length)
                cast(void) regex(options.include);
            if (options.exclude.length)
                cast(void) regex(options.exclude);
        }
        catch (RegexException e)
        {
            stderr.writeln("invalid --include/--exclude regular expression: ", e.msg);
            return UnitTestResult(1, 0, false, false);
        }
    }

    auto tests = discovered
        .filter!(t => t.matchesFilter(options.include, options.exclude))
        .array;

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
    if (options.betterC || options.wasm)
        return runDriverModes(tests, options);
    return runDefaultMode(tests, options, colored, width);
}

/// The driver options shared by the @ctfe, `--better-c`, and `--wasm` modes.
private DriverOptions toDriverOptions(const RunnerOptions options)
{
    return DriverOptions(
        compiler: options.compiler,
        importPaths: options.importPaths.dup,
        includeImports: options.includeImports.dup,
        keep: options.keep,
        verbose: options.verbose,
    );
}

/// Evaluates the (already filtered) `@ctfe` tests through the driver's probe
/// compile, prints per-test verdict lines plus any compiler output
/// (`__ctfeWrite` text, error trails), and updates `totals`.
private void runCtfeStage(
    in Test[] ctfeTests, in Test[] allTests, in RunnerOptions options,
    bool colored, uint width, ref RunTotals totals)
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
    import sparkles.test_runner.driver : runBetterCTests, runWasmTests;

    const driverOptions = toDriverOptions(options);

    size_t executed, passed;
    bool failed;

    if (options.betterC)
    {
        const outcome = runBetterCTests(
            tests.filter!(t => t.traits.isBetterC).array, tests, driverOptions);
        if (!outcome.skipped)
        {
            executed += outcome.testCount;
            passed += outcome.succeeded ? outcome.testCount : 0;
            failed |= !outcome.succeeded;
        }
    }
    if (options.wasm)
    {
        const outcome = runWasmTests(
            tests.filter!(t => t.traits.isWasm).array, tests, driverOptions);
        if (!outcome.skipped)
        {
            executed += outcome.testCount;
            passed += outcome.succeeded ? outcome.testCount : 0;
            failed |= !outcome.succeeded;
        }
    }

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
    import sparkles.test_runner.reporting : formatCtfeTraceTable, render;

    auto ctfeTests = tests.filter!(t => t.traits.isCtfe).array;
    if (!ctfeTests.length)
    {
        stdout.writeln("no @ctfe tests found");
        return UnitTestResult(0, 0, false, false);
    }

    const compiler = detectCompiler(options.compiler);
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
    stdout.write(formatCtfeTraceTable(costs, colored));
    return UnitTestResult(ctfeTests.length, ctfeTests.length, false, false);
}

/// `--list`: one line per test with its special-handling markers.
private UnitTestResult listTests(Test[] tests, bool colored)
{
    import std.stdio : stdout;
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
        if (test.traits.isBetterC)
            markers ~= " @betterC";
        if (test.traits.isWasm)
            markers ~= " @wasm";
        writer.put(render(colored,
            i" {dim $(moduleName)} $(test.name){cyan $(markers)}\n"));
    }
    return UnitTestResult(0, 0, false, false);
}

/// The default mode: evaluate the selected `@ctfe` tests through the probe
/// compile, run every regular test in parallel, and count skipped benchmarks.
private UnitTestResult runDefaultMode(Test[] tests, in RunnerOptions options, bool colored, uint width)
{
    import core.atomic : atomicOp;
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.parallelism : TaskPool, totalCPUs;
    import std.stdio : stdout;

    RunTotals totals;
    const started = MonoTime.currTime;

    foreach (test; tests)
        if (!test.traits.isCtfe && test.traits.isBenchmark)
            totals.benchSkipped++;

    runCtfeStage(tests.filter!(t => t.traits.isCtfe).array, tests,
        options, colored, width, totals);

    auto runnable = tests
        .filter!(t => !t.traits.isCtfe && !t.traits.isBenchmark)
        .array;

    shared size_t passed, failed, skipped;
    const threads = options.threads ? options.threads : totalCPUs;

    bool ranLive = false;
    static if (hasCoreCliLive)
    {
        // The same animate-or-not policy as the bench spinner (tty and no
        // colour opt-outs), asked about stdout — the line redraws beneath the
        // streamed result lines there.
        if (progressEnabled(options.noColours, stderrStream: false))
        {
            runParallelLive(runnable, options, colored, width, threads,
                passed, failed, skipped);
            ranLive = true;
        }
    }
    if (!ranLive) with (new TaskPool(threads - 1))
    {
        foreach (test; parallel(runnable))
        {
            const result = executeTest(test);

            auto output = formatResultLine(result, colored, options.verbose, width) ~ "\n";
            foreach (thrown; result.thrown)
                output ~= formatThrown(thrown, colored, options.verbose);
            stdout.lockingTextWriter.put(output);

            if (result.skipped)
                atomicOp!"+="(skipped, size_t(1));
            else
                atomicOp!"+="(result.succeeded ? passed : failed, size_t(1));
        }
        finish(true);
    }

    totals.passed = passed;
    totals.failed += failed; // ctfe failures are already counted
    // Skipped tests count in neither executed nor passed below (like
    // benchSkipped), so a skip never fails the run — the yellow summary
    // segment is the surfacing.
    totals.skipped = skipped;

    stdout.writeln;
    stdout.writeln(formatSummary(totals, MonoTime.currTime - started, colored));

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
    import sparkles.test_runner.metrics : perfFamily, rawSelectorEvents,
        selectsSource, syscallFamily, syscallSelectorNames, tier0Family;

    // Which counting passes to open: --perf OR a --metrics perf metric (so
    // `--metrics=ipc`/`=all` populate the perf columns, mirroring tier0); a
    // --metrics tier0 metric (opt-in, no perms); and the syscall pass for
    // --syscalls (null = off, "*" = total only, else a name list) OR a
    // --metrics syscall column (`syscalls`, `syscalls:<name>`, `all`).
    const metricSyscalls = syscallSelectorNames(options.metrics);
    const wantPerf = options.perf || selectsSource(options.metrics, "perf");
    const wantTier0 = selectsSource(options.metrics, "tier0");
    const wantSyscalls = options.syscalls.length > 0 || metricSyscalls.length > 0
        || selectsSource(options.metrics, "syscall");
    auto syscallNames = (options.syscalls == "*" || !options.syscalls.length)
        ? null : options.syscalls.splitter(',').array;
    foreach (n; metricSyscalls)
        if (!syscallNames.canFind(n))
            syscallNames ~= n;
    const rawEvents = rawSelectorEvents(options.metrics);
    const wantRaw = rawEvents.length > 0;
    auto counters = CounterGroups.open(wantPerf, wantTier0, wantSyscalls, syscallNames,
        wantRaw, rawEvents);
    scope (exit)
        counters.close();
    // Absent-but-requested capabilities, one line each, re-derived from the
    // capability reports so the header and --list-metrics share one vocabulary.
    static void noteAbsent(string flag, in CapabilityReport report, Capability wanted)
    {
        foreach (ref a; report.absences)
            if (a.capability & wanted)
                stderr.writeln(flag, ": ", capabilityName(a.capability),
                    " unavailable (", a.reason, ")");
    }

    if (wantPerf && !counters.perf.available)
        noteAbsent("--perf", counters.perf.capabilities, Capability.counting);
    if (wantTier0 && !counters.tier0.available)
        noteAbsent("--metrics", counters.tier0.capabilities, Capability.counting);
    if (wantSyscalls && !counters.syscalls.available)
        noteAbsent("--syscalls", counters.syscalls.capabilities, Capability.eventTracing);
    if (wantRaw && !counters.raw.available)
        noteAbsent("--metrics", counters.raw.capabilities, Capability.countingRaw);
    // The group read caps the named tracepoints (SyscallGroup truncates its
    // list); a silently dropped column reads as "never fires" — say so.
    if (counters.syscalls.available && syscallNames.length > counters.syscalls.names.length)
        stderr.writeln("--syscalls: only the first ", counters.syscalls.names.length,
            " named tracepoints are counted (", syscallNames.length, " requested)");

    // --list-metrics (also --metrics=? / --metrics=help): print the catalog,
    // the per-backend capability block, and exit. One full-probe bundle
    // reports true availability regardless of the flags; client metrics can't
    // be listed without running, so they're just noted.
    if (options.listMetrics || options.metrics == "?" || options.metrics == "help")
    {
        auto probe = CounterGroups.open(true, true, true, null, rawWanted: true);
        scope (exit)
            probe.close();
        auto cat = perfFamily(probe.perf.available)
            ~ tier0Family(probe.tier0.available)
            ~ syscallFamily(probe.syscalls.available);
        stdout.write(formatMetricCatalog(cat, colored));
        stdout.writeln;
        stdout.write(formatCapabilityBlock(probe.capabilities, colored));
        stdout.writeln("client throughput/level metrics are defined per @benchmark and appear when present.");
        return UnitTestResult(0, 0, false, false);
    }

    // Benchmark numbers from an assert-enabled (debug) build routinely read
    // several times off an optimized build's — say so up front, once per run,
    // instead of letting authoritative-looking tables mislead. (dub's stock
    // `unittest` build type is debug; a consumer wanting real numbers defines
    // a release buildType with the `unittests` option — see the docs.)
    version (assert)
        stderr.writeln("warning: assert-enabled build — benchmark numbers may be ",
            "meaningless; use an optimized unittest buildType (e.g. dub test -b bench)");

    import std.algorithm.mutation : SwapStrategy;
    import std.algorithm.sorting : sort;
    import std.range : iota;
    import sparkles.test_runner.bench : errorRow, measureCase, registerBenchmark,
        RegisteredCase;
    import sparkles.test_runner.execution : toThrown;
    import sparkles.test_runner.skip : TestSkipped;
    import std.algorithm.searching : canFind;
    import sparkles.test_runner.metrics : canonicalSortKey, catalog,
        groupKeyDisplay, groupKeyOf, unknownMetricSelectors;

    auto benchTests = tests.filter!(t => t.traits.isBenchmark).array;

    // Register every @benchmark test's cases (running each body once, no
    // measurement). Cases sharing a streaming key are measured and printed
    // together — one table per group as it finishes.
    static struct Sched
    {
        RegisteredCase c;
        Test test;
        BenchConfig config;
        string key;
    }

    Sched[] all;
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
        const config = benchConfigFor(options.benchMinTime, test.traits.benchIterations);
        auto reg = registerBenchmark(test, config);
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
        foreach (ref ev; rawEvents)
            knownColumns ~= "raw:" ~ ev.selector;
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
    static if (hasCoreCliBenchTicker)
        const bool ticker = all.length > 0
            && progressEnabled(options.noColours, stderrStream: false);
    else
        enum bool ticker = false;

    progress = BenchProgress(total: all.length,
        active: !ticker && progressEnabled(options.noColours) && all.length > 0,
        width: detectTerminalWidth(stderrStream: true));

    size_t totalRows, errorRows;
    bool firstFlush = true;
    BenchStats[] bucket;
    BenchStats[] measured; // run-long, for --bench-json (measurement order)
    TableGeometry geometry; // run-long column floors: streamed tables only widen
    string curKey;

    static if (hasCoreCliBenchTicker)
    {
        import sparkles.core_cli.ui.live : LiveRegion, stdoutLiveRegion;
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
        static if (hasCoreCliBenchTicker)
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
        stdout.write(formatBenchTable(bucket, colored, options.metrics,
            sortBy, keys, &geometry));
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

        static if (hasCoreCliBenchTicker)
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
        static if (hasCoreCliBenchTicker)
            tickerFrame(BenchStats(name: s.c.name, labels: s.c.labels));
        try
        {
            auto row = measureCase(s.c, s.config, counters);
            if (row.error.length)
                errorRows++;
            bucket ~= row;
            measured ~= row;
            totalRows++;
        }
        catch (TestSkipped sk)
        {
            // A measurement-time skipTest (an environment probe inside a
            // deferred closure): a yellow skipped row, counted as neither
            // passed-with-numbers nor failed — the run stays green.
            import sparkles.test_runner.bench : errorCell;

            auto row = BenchStats(name: s.c.name, labels: s.c.labels,
                error: errorCell(sk.message.idup), skipped: true);
            bucket ~= row;
            measured ~= row;
            totalRows++;
        }
        catch (Throwable t)
        {
            // A hard throw during measurement: surface it as an error row in its
            // group table (like a soft Expected error) so the matrix shows exactly
            // which case crashed, and still print the trace. Counted once via the
            // error-row path — not the separate `failed` tally. `toThrown`
            // re-throws OutOfMemoryError, which must abort the run.
            auto thrown = toThrown(t);
            auto row = errorRow(s.c.name, s.c.labels, thrown);
            bucket ~= row;
            measured ~= row;
            errorRows++;
            totalRows++;
            progress.clear();
            bool printedAbove = false;
            static if (hasCoreCliBenchTicker)
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
    flush();
    progress.clear();

    if (totalRows == 0 && !failed)
        stdout.writeln("no @benchmark tests found");

    if (options.benchJson.length)
    {
        import std.file : write;
        import sparkles.test_runner.bench_json : benchReportJson, collectBenchMeta;

        // The meta block records the effective knobs (an empty run still writes
        // a valid document, deterministic for tooling).
        const meta = collectBenchMeta(benchConfigFor(options.benchMinTime, 0));
        try
            write(options.benchJson, benchReportJson(measured, meta));
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
private enum bool hasCoreCliTermCaps = __traits(compiles, {
    import sparkles.core_cli.term_caps : detectTermCaps;
});

/// The per-test `BenchConfig` under the CLI knobs: `--bench-min-time` overrides
/// the sample-time budget (0 = keep the 5 ms default); a pinned
/// `@benchmark(iterations: N)` count threads through unchanged.
private BenchConfig benchConfigFor(uint benchMinTimeMs, uint iterations)
    @safe pure nothrow @nogc
{
    import core.time : msecs;

    auto config = BenchConfig(iterations: iterations);
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
/// Delegates to `core-cli`'s `detectTermCaps` (colors off on `--no-colours` /
/// `$NO_COLOR` / `TERM=dumb` / non-tty; Windows UTF-8 code page + VT enable).
/// In `base`'s own test build (no `core-cli` there) a minimal inline fallback
/// keeps the same `--no-colours`/`$NO_COLOR`/tty behaviour.
private bool prepareConsole(bool noColours)
{
    static if (hasCoreCliTermCaps)
    {
        import sparkles.core_cli.term_caps : detectTermCaps;

        return detectTermCaps(noColours).colors;
    }
    else
    {
        import std.process : environment;

        const disabled = noColours || environment.get("NO_COLOR", "").length != 0;

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

/// Whether `core-cli`'s live-region components are importable (same pattern as
/// `reporting.d`'s gates: `core-cli` cannot be a dub dependency of this package).
private enum bool hasCoreCliLive = __traits(compiles, {
    import sparkles.core_cli.ui.live : stdoutLiveRegion;
    import sparkles.core_cli.ui.progress : ProgressLine;
});

/// Likewise for the `--bench` live results table (the "ticker"): a `LiveRegion`
/// repainting `drawTableLines` frames.
private enum bool hasCoreCliBenchTicker = __traits(compiles, {
    import sparkles.core_cli.ui.live : stdoutLiveRegion;
    import sparkles.core_cli.ui.table : drawTableLines;
});

static if (hasCoreCliLive)
/// The tty variant of the parallel run: a polled `N/M` progress line under the
/// streaming result lines. Workers never touch the terminal — they append their
/// finished output to a mutex-guarded queue and bump an atomic counter; the
/// main thread (no longer participating in the work) drains the queue through
/// `printAbove` and repaints one `ProgressLine`, which is erased on completion
/// so the permanent output matches the plain path.
private void runParallelLive(
    Test[] runnable, in RunnerOptions options, bool colored, uint width,
    size_t threads, ref shared size_t passed, ref shared size_t failed,
    ref shared size_t skipped)
{
    import core.atomic : atomicLoad, atomicOp;
    import core.sync.mutex : Mutex;
    import core.thread : Thread;
    import core.time : MonoTime, msecs;
    import std.array : appender;
    import std.parallelism : task, TaskPool;
    import std.string : lineSplitter;
    import sparkles.core_cli.ui.live : stdoutLiveRegion;
    import sparkles.core_cli.ui.progress : ProgressLine;

    auto pool = new TaskPool(threads < 1 ? 1 : threads);
    scope (exit)
        pool.finish(true);

    auto mutex = new Mutex;
    string[] pendingOutput;
    shared size_t completed;

    void runOne(size_t idx)
    {
        const result = executeTest(runnable[idx]);
        auto output = formatResultLine(result, colored, options.verbose, width) ~ "\n";
        foreach (thrown; result.thrown)
            output ~= formatThrown(thrown, colored, options.verbose);
        synchronized (mutex)
            pendingOutput ~= output;
        // Same three buckets as the plain path: a skip (yellow ⊘ line) counts
        // in neither passed nor failed, so it never fails the run.
        if (result.skipped)
            atomicOp!"+="(skipped, size_t(1));
        else
            atomicOp!"+="(result.succeeded ? passed : failed, size_t(1));
        atomicOp!"+="(completed, size_t(1)); // after the queue append (see drain)
    }

    foreach (i; 0 .. runnable.length)
        pool.put(task(&runOne, i));

    auto region = stdoutLiveRegion();
    scope (exit)
        region.finish(keepFrame: false); // the summary follows; no lasting frame

    const started = MonoTime.currTime;
    size_t spin;
    void drain()
    {
        string[] drained;
        synchronized (mutex)
        {
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
