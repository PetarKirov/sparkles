/**
 * The fallback: how a test binary runs its own tests when no runner is
 * found (process-model §7). One test at a time, in discovery order, each on
 * the thread the protocol would place it on, with a plain one-line-per-test
 * report. Options that need the runner stop the run before any test.
 */
module sparkles.test_runner.fallback;

import sparkles.test_runner.model : Test, TestResult;

/// The options the fallback understands (TRF2): their own meanings, or, for
/// the compile context, accepted and unused.
private struct FallbackOptions
{
    string include;
    string exclude;
    bool verbose;
    uint threads;
    bool noColors;
    bool list;
    bool skipSlow;
    bool onlySlow;
}

/// The option names the fallback accepts, without dashes or a value.
private immutable string[] acceptedLong = [
    "include", "exclude", "verbose", "threads", "no-colors", "list",
    "skip-slow", "only-slow", "help",
    // The compile context: accepted so a command line written for the
    // runner still runs here; nothing in the fallback compiles.
    "compiler", "import-path", "include-import", "no-auto-include",
    "string-import-path", "version", "dflag", "probe-dir", "no-dub",
    "require-toolchain", "keep",
];

/// ditto, the single-letter forms.
private immutable string acceptedShort = "ievtlhI";

/// The first option in `args` the fallback does not accept, or `null`.
string firstRunnerOnlyOption(in string[] args) @safe pure nothrow
{
    import std.algorithm.searching : canFind, findSplitBefore;

    foreach (arg; args)
    {
        if (arg.length < 2 || arg[0] != '-')
            continue;
        if (arg == "--")
            break;
        if (arg[1] == '-')
        {
            const name = arg[2 .. $].findSplitBefore("=")[0];
            if (!acceptedLong.canFind(name))
                return arg.findSplitBefore("=")[0];
        }
        else if (!acceptedShortOption(arg[1]))
            return arg[0 .. 2];
    }
    return null;
}

@("fallback.firstRunnerOnlyOption")
@safe pure nothrow
unittest
{
    assert(firstRunnerOnlyOption(["-i", "Buffer", "-t", "4", "--skip-slow"]) is null);
    assert(firstRunnerOnlyOption(["--compiler=ldc2", "-I", "src", "-v"]) is null);
    assert(firstRunnerOnlyOption(["-v", "--bench"]) == "--bench");
    assert(firstRunnerOnlyOption(["--metrics=ipc"]) == "--metrics");
    assert(firstRunnerOnlyOption(["-x"]) == "-x");
    assert(firstRunnerOnlyOption(["-i", "--", "--bench"]) is null);
}

/// Whether `test` has a runtime body the fallback runs.
private bool isRuntimeTest(in Test test) @safe pure nothrow @nogc
    => !test.traits.isCtfe && !test.traits.isBenchmark && !test.traits.isWorkload;

/**
Runs `tests` in this process and returns the exit status: `0` if and only if
no selected test failed (TRF4). `args` are the binary's arguments without the
program name and without druntime's `--DRT-` options.
*/
int runFallback(Test[] tests, string[] args)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.getopt : config, getopt, GetOptException;
    import std.stdio : stderr, stdout;
    import sparkles.test_runner.filter : matchesFilter, matchesSlowSelection,
        SlowSelection;

    if (const option = firstRunnerOnlyOption(args))
    {
        stderr.writeln(option, ": needs the test runner, and this binary found none —",
            " set SPARKLES_TEST_RUNNER or pass --runner=PATH");
        return 2;
    }

    FallbackOptions options;
    string compiler, probeDir;
    string[] importPaths, includeImports, stringImportPaths, versions, dflags;
    bool noAutoInclude, noDub, requireToolchain, keep;
    auto argv = ["test"] ~ args;
    try
    {
        auto help = getopt(argv, config.caseSensitive,
            "i|include", "Run only tests whose name matches the regular expression",
                &options.include,
            "e|exclude", "Skip tests whose name matches the regular expression",
                &options.exclude,
            "v|verbose", "Show full stack traces", &options.verbose,
            "t|threads", "Accepted; the fallback runs one test at a time", &options.threads,
            "no-colors", "Accepted; the fallback prints no colors", &options.noColors,
            "l|list", "List discovered tests without running them", &options.list,
            "skip-slow", "Leave out @slow tests", &options.skipSlow,
            "only-slow", "Run only @slow tests", &options.onlySlow,
            "compiler", "Accepted and unused", &compiler,
            "I|import-path", "Accepted and unused", &importPaths,
            "include-import", "Accepted and unused", &includeImports,
            "no-auto-include", "Accepted and unused", &noAutoInclude,
            "string-import-path", "Accepted and unused", &stringImportPaths,
            "version", "Accepted and unused", &versions,
            "dflag", "Accepted and unused", &dflags,
            "probe-dir", "Accepted and unused", &probeDir,
            "no-dub", "Accepted and unused", &noDub,
            "require-toolchain", "Accepted and unused", &requireToolchain,
            "keep", "Accepted and unused", &keep);
        if (help.helpWanted)
        {
            import std.getopt : defaultGetoptPrinter;

            defaultGetoptPrinter("Running without the test runner (no "
                ~ "SPARKLES_TEST_RUNNER, no --runner=PATH): tests run one at a "
                ~ "time in this process.\n\nOptions:", help.options);
            return 0;
        }
    }
    catch (Exception e)
    {
        stderr.writeln("error: ", e.msg);
        return 2;
    }
    if (argv.length > 1)
    {
        stderr.writeln("error: unexpected argument '", argv[1], "'");
        return 2;
    }

    const slow = options.onlySlow ? SlowSelection.only
        : options.skipSlow ? SlowSelection.skip : SlowSelection.run;
    auto selected = tests
        .filter!(t => t.matchesFilter(options.include, options.exclude)
            && t.matchesSlowSelection(slow))
        .array;

    if (options.list)
    {
        foreach (ref test; selected)
            stdout.writeln(test.moduleName, " ", test.name);
        return 0;
    }

    size_t passed, failed, skipped, compileTime, measured;
    foreach (ref test; selected)
    {
        if (test.traits.isCtfe)
        {
            ++compileTime;
            continue;
        }
        if (!isRuntimeTest(test))
        {
            ++measured;
            continue;
        }
        const result = runPlaced(test);
        report(result, options.verbose);
        if (result.skipped)
            ++skipped;
        else if (result.succeeded)
            ++passed;
        else
            ++failed;
    }

    stdout.writeln();
    stdout.write("Summary: ", passed, " passed, ", failed, " failed, ", skipped, " skipped");
    if (compileTime)
        stdout.write(", ", compileTime, " compile-time not evaluated (needs the runner)");
    if (measured)
        stdout.write(", ", measured, " benchmarks and workloads not run");
    stdout.writeln();
    return failed ? 1 : 0;
}

/// Runs `test` on the thread TRP17 places it on: the main thread for a
/// `mainThread` test, otherwise a fresh worker-stack thread.
TestResult runPlaced(Test test, bool onMainThread = false)
{
    import sparkles.test_runner.attributes : ThreadAffinity;
    import sparkles.test_runner.execution : executeTest;
    import sparkles.test_runner.stack_budget : prepareCurrentThreadForStackBudget;
    import sparkles.test_runner.workers : joinTestWorkers, startTestWorkers;

    if (onMainThread || (test.traits.isSerial
            && test.traits.serialAffinity == ThreadAffinity.mainThread))
    {
        prepareCurrentThreadForStackBudget();
        return executeTest(test);
    }
    TestResult result;
    bool reported;
    try
        joinTestWorkers(startTestWorkers([test], 1, (TestResult r) { result = r; reported = true; },
            onCaller: false));
    catch (Throwable t)
    {
        import sparkles.test_runner.execution : toThrown;

        result = TestResult(test: test, thrown: toThrown(t));
        reported = true;
    }
    if (!reported)
    {
        import sparkles.test_runner.model : Thrown;

        // The test's thread ended without a result: report the test, not a
        // nameless failure.
        result = TestResult(test: test);
        result.thrown = [Thrown(type: "thread ended",
            message: "the test's thread ended without reporting a result")];
    }
    return result;
}

/// One result line, with a failure's messages beneath it (TRF3).
private void report(in TestResult result, bool verbose)
{
    import std.stdio : stdout;

    if (result.skipped)
    {
        stdout.writeln("⊘ ", result.test.name, " — ", result.skipReason);
        return;
    }
    stdout.writeln(result.succeeded ? "✓ " : "✗ ", result.test.name);
    foreach (ref thrown; result.thrown)
    {
        stdout.writeln("    ", thrown.type, "@", thrown.file, "(", thrown.line, "): ",
            thrown.message);
        if (verbose)
            foreach (line; thrown.info)
                stdout.writeln("        ", line);
    }
}

/// Whether `-c` is an option the fallback accepts.
private bool acceptedShortOption(char c) @safe pure nothrow @nogc
{
    foreach (accepted; acceptedShort)
        if (c == accepted)
            return true;
    return false;
}
