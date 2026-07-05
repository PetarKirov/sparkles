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

import sparkles.test_runner.bench : BenchConfig, BenchStats, runBenchmark;
import sparkles.test_runner.driver : detectCompiler, DriverOptions, runCtfeTests;
import sparkles.test_runner.execution : executeTest;
import sparkles.test_runner.filter : matchesFilter;
import sparkles.test_runner.model : Test, TestResult;
import sparkles.test_runner.reporting : detectTerminalWidth, formatBenchTable,
    formatCtfeFailedLine, formatCtfeLine, formatResultLine, formatSummary,
    formatThrown, RunTotals;

// ─────────────────────────────────────────────────────────────────────────────
// Entry point — called across the extern(C) seam by the registration shim,
// which has already discovered the tests and computed `hostIsRunner`.
// ─────────────────────────────────────────────────────────────────────────────

extern (C) void sparkles_test_runner_run(
    Test* testsPtr, size_t count, bool hostIsRunner, uint* executed, uint* passed)
{
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

private UnitTestResult runnerMain(Test[] discovered, bool hostIsRunner)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.getopt : config, getopt;
    import std.stdio : stdout;

    RunnerOptions options;
    auto args = Runtime.args;
    auto getoptResult = args.getopt(
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

    if (getoptResult.helpWanted)
    {
        stdout.writeln("Usage:\n\tdub test -- <options>\n\nOptions:");
        foreach (option; getoptResult.options)
        {
            import std.string : leftJustifier;

            stdout.writefln("  %s\t%s\t%s",
                option.optShort, option.optLong.leftJustifier(14), option.help);
        }
        return UnitTestResult(0, 0, false, false);
    }

    const colored = prepareConsole(options.noColours);
    // Cells available for the compact result lines; `0` (unknown / piped) skips
    // truncation so redirected output stays byte-identical.
    const width = detectTerminalWidth();

    // Hide the runner's own tests unless requested — or unless the tested
    // package is the runner itself, in which case they are the test suite.
    if (!options.selfTest && !testingRunnerItself(hostIsRunner))
        discovered = discovered.filter!(t => !t.isSelfTest).array;

    auto tests = discovered
        .filter!(t => t.matchesFilter(options.include, options.exclude))
        .array;

    if (options.list)
        return listTests(tests, colored);
    if (options.bench)
        return runBenchMode(tests, colored);
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
        stderr.writeln(render(colored,
            i"{red @ctfe evaluation failed} — fix the tests before tracing"));
        return UnitTestResult(ctfeTests.length, 0, false, false);
    }

    const costs = attributeCtfeCosts(
        ctfeTests, parseCtfeEvents(readText(options.ctfeTrace)));
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

    shared size_t passed, failed;
    const threads = options.threads ? options.threads : totalCPUs;

    with (new TaskPool(threads - 1))
    {
        foreach (test; parallel(runnable))
        {
            const result = executeTest(test);

            auto output = formatResultLine(result, colored, options.verbose, width) ~ "\n";
            foreach (thrown; result.thrown)
                output ~= formatThrown(thrown, colored, options.verbose);
            stdout.lockingTextWriter.put(output);

            atomicOp!"+="(result.succeeded ? passed : failed, size_t(1));
        }
        finish(true);
    }

    totals.passed = passed;
    totals.failed += failed; // ctfe failures are already counted

    stdout.writeln;
    stdout.writeln(formatSummary(totals, MonoTime.currTime - started, colored));

    const executed = totals.passed + totals.failed + totals.ctfePassed;
    return UnitTestResult(executed, totals.passed + totals.ctfePassed, false, false);
}

/// `--bench`: measure every `@benchmark` test serially and print the table.
private UnitTestResult runBenchMode(Test[] tests, bool colored)
{
    import std.algorithm.iteration : filter;
    import std.stdio : stdout;

    BenchStats[] rows;
    size_t failed;

    foreach (test; tests.filter!(t => t.traits.isBenchmark))
    {
        auto outcome = runBenchmark(test,
            BenchConfig(iterations: test.traits.benchIterations));
        if (outcome.result.succeeded)
        {
            rows ~= outcome.stats;
            continue;
        }

        failed++;
        stdout.write(formatResultLine(outcome.result, colored, true), "\n");
        foreach (thrown; outcome.result.thrown)
            stdout.write(formatThrown(thrown, colored, true));
    }

    if (rows.length)
        stdout.write(formatBenchTable(rows, colored));
    else if (!failed)
        stdout.writeln("no @benchmark tests found");

    return UnitTestResult(rows.length + failed, rows.length, false, false);
}

/// Prepares the console and reports whether colored output should be used.
/// Colors are off when `--no-colours`/`$NO_COLOR` is set or stdout is not a
/// terminal. On Windows this additionally sets the output code page to UTF-8
/// (so `✓ ✗ ⚙` render even without colours) and enables virtual-terminal
/// processing (so ANSI escapes are interpreted rather than printed literally);
/// colours stay off when stdout is redirected or VT can't be enabled.
private bool prepareConsole(bool noColours)
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
    else version (Windows)
    {
        import core.sys.windows.windows : DWORD,
            ENABLE_VIRTUAL_TERMINAL_PROCESSING, GetConsoleMode, GetStdHandle,
            INVALID_HANDLE_VALUE, SetConsoleMode, SetConsoleOutputCP,
            STD_OUTPUT_HANDLE;

        enum uint CP_UTF8 = 65_001;
        SetConsoleOutputCP(CP_UTF8);

        if (disabled)
            return false;

        auto handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if (handle is null || handle == INVALID_HANDLE_VALUE)
            return false;
        DWORD mode;
        // Fails when stdout is redirected (not a console) — the non-tty check.
        if (!GetConsoleMode(handle, &mode))
            return false;
        return SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0;
    }
    else
        return !disabled;
}
