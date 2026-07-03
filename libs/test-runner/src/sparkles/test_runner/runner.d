/**
 * The runner entry point, active only in `dub test` builds.
 *
 * Registers itself as druntime's extended module unit tester, discovers every
 * `unittest` in the tested package (via dub's generated `dub_test_root`), and
 * runs them in parallel. Tests annotated with the attributes from
 * $(MREF sparkles,test_runner,attributes) get special handling:
 *
 * $(LIST
 *     * `@ctfe` tests are forced through CTFE with `static assert` while this
 *       module compiles — a failure is a compile error — and are only
 *       reported at runtime;
 *     * `@benchmark` tests are skipped by default and measured by `--bench`;
 *     * `@betterC` / `@wasm` tests run normally here, and are additionally
 *       exercised in their special environments by `--better-c` / `--wasm`.
 * )
 */
module sparkles.test_runner.runner;

version (unittest):

static if (!__traits(compiles, () { static import dub_test_root; }))
{
    static assert(false,
        "Couldn't find 'dub_test_root'. Make sure you are running tests with `dub test`.");
}
else
{
    static import dub_test_root;
}

import core.attribute : standalone;
import core.runtime : Runtime, UnitTestResult;
import core.time : Duration, MonoTime;

import std.traits : fullyQualifiedName, hasUDA;

import sparkles.test_runner.attributes : ctfe;
import sparkles.test_runner.bench : BenchConfig, BenchStats, runBenchmark;
import sparkles.test_runner.discovery : discoverTests, moduleOf;
import sparkles.test_runner.execution : executeTest;
import sparkles.test_runner.model : matchesFilter, Test, TestResult;
import sparkles.test_runner.reporting : formatBenchTable, formatCtfeLine,
    formatResultLine, formatSummary, formatThrown, RunTotals;

// ─────────────────────────────────────────────────────────────────────────────
// Compile-time execution of @ctfe tests
// ─────────────────────────────────────────────────────────────────────────────

private enum bool ctfePasses(alias test) = () { test(); return true; }();

static foreach (m; dub_test_root.allModules)
    static foreach (test; __traits(getUnitTests, moduleOf!m))
        static if (hasUDA!(test, ctfe))
            static assert(ctfePasses!test,
                "@ctfe unittest failed during CTFE: " ~ fullyQualifiedName!test);

// ─────────────────────────────────────────────────────────────────────────────
// Runtime entry point
// ─────────────────────────────────────────────────────────────────────────────

// `@standalone` breaks the ctor-ordering cycle with the generated
// `dub_test_root` module (which imports this module back when the runner is
// compiled in via `sourcePaths`); this ctor only assigns a druntime global.
@standalone
shared static this() @system
{
    Runtime.extendedModuleUnitTester = &runnerMain;
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
    bool keep;
    bool selfTest;
}

/// Whether `test` belongs to the runner itself. In-monorepo hosts compile the
/// runner via `sourcePaths`, which puts its modules into `allModules`; hide
/// their tests unless `--self-test` is given or the tested package $(I is)
/// the runner (i.e. every discovered test is a runner test).
private bool isSelfTest(in Test test) @safe pure nothrow @nogc
{
    enum prefix = "sparkles.test_runner.";
    return test.fullName.length > prefix.length
        && test.fullName[0 .. prefix.length] == prefix;
}

private UnitTestResult runnerMain()
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
            "Report per-@ctfe-test CTFE cost from an LDC -ftime-trace JSON file",
            &options.ctfeTrace,
        "better-c",
            "Extract @betterC tests, compile them with -betterC, and run them",
            &options.betterC,
        "wasm",
            "Extract @wasm tests, cross-compile them to wasm32, and run them",
            &options.wasm,
        "compiler",
            "D compiler for --better-c/--wasm (default: $DC, then ldc2, dmd)",
            &options.compiler,
        "I|import-path",
            "Extra import path for --better-c/--wasm (repeatable)",
            &options.importPaths,
        "keep",
            "Keep the files generated by --better-c/--wasm",
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

    const colored = useColors(options.noColours);

    import std.algorithm.searching : all;

    auto discovered = discoverTests!(dub_test_root.allModules)();
    // Hide the runner's own tests unless requested — or unless the tested
    // package is the runner itself, in which case they are the test suite.
    if (!options.selfTest && !discovered.all!(t => t.isSelfTest))
        discovered = discovered.filter!(t => !t.isSelfTest).array;

    auto tests = discovered
        .filter!(t => t.matchesFilter(options.include, options.exclude))
        .array;

    if (options.list)
        return listTests(tests, colored);
    if (options.bench)
        return runBenchMode(tests, colored);
    if (options.ctfeTrace.length)
        return runCtfeTraceMode(tests, options.ctfeTrace, colored);
    if (options.betterC || options.wasm)
        return runDriverModes(tests, options);
    return runDefaultMode(tests, options, colored);
}

/// `--better-c` / `--wasm`: extract the annotated tests and exercise them in
/// their special environment via external compilation.
private UnitTestResult runDriverModes(Test[] tests, in RunnerOptions options)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import sparkles.test_runner.driver : DriverOptions, runBetterCTests, runWasmTests;

    const driverOptions = DriverOptions(
        compiler: options.compiler,
        importPaths: options.importPaths.dup,
        keep: options.keep,
        verbose: options.verbose,
    );

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

/// `--ctfe-trace <file>`: attribute the compile-time cost recorded by LDC's
/// `-ftime-trace` to the individual `@ctfe` tests.
private UnitTestResult runCtfeTraceMode(Test[] tests, string traceFile, bool colored)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.file : exists, readText;
    import std.stdio : stderr, stdout;
    import sparkles.test_runner.ctfe_trace : attributeCtfeCosts, parseCtfeEvents;
    import sparkles.test_runner.reporting : formatCtfeTraceTable, render;

    if (!traceFile.exists)
    {
        stderr.writeln(render(colored, i"{red no such trace file:} $(traceFile)"));
        stderr.writeln("produce one by adding to the package's unittest configuration:");
        stderr.writeln(`    dflags "-ftime-trace" "-ftime-trace-file=$PACKAGE_DIR/build/trace.json" ` ~
            `"--ftime-trace-granularity=0" platform="ldc"`);
        return UnitTestResult(1, 0, false, false);
    }

    auto ctfeTests = tests.filter!(t => t.traits.isCtfe).array;
    if (!ctfeTests.length)
    {
        stdout.writeln("no @ctfe tests found");
        return UnitTestResult(0, 0, false, false);
    }

    const costs = attributeCtfeCosts(ctfeTests, parseCtfeEvents(readText(traceFile)));
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

/// The default mode: run every regular test in parallel; report `@ctfe`
/// tests as compile-time-verified and count skipped benchmarks.
private UnitTestResult runDefaultMode(Test[] tests, in RunnerOptions options, bool colored)
{
    import core.atomic : atomicOp;
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.parallelism : TaskPool, totalCPUs;
    import std.stdio : stdout;

    RunTotals totals;
    const started = MonoTime.currTime;

    foreach (test; tests)
    {
        if (test.traits.isCtfe)
        {
            // Already executed during compilation — reaching this line proves
            // it passed; only report it.
            stdout.writeln(formatCtfeLine(test, colored));
            totals.ctfePassed++;
        }
        else if (test.traits.isBenchmark)
            totals.benchSkipped++;
    }

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

            auto output = formatResultLine(result, colored, options.verbose) ~ "\n";
            foreach (thrown; result.thrown)
                output ~= formatThrown(thrown, colored, options.verbose);
            stdout.lockingTextWriter.put(output);

            atomicOp!"+="(result.succeeded ? passed : failed, size_t(1));
        }
        finish(true);
    }

    totals.passed = passed;
    totals.failed = failed;

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

/// Colors are on for a tty unless `--no-colours` or `$NO_COLOR` is set.
private bool useColors(bool noColours)
{
    import std.process : environment;

    if (noColours || environment.get("NO_COLOR", "").length)
        return false;

    version (Posix)
    {
        import core.sys.posix.unistd : isatty, STDOUT_FILENO;

        return isatty(STDOUT_FILENO) != 0;
    }
    else
        return true;
}
