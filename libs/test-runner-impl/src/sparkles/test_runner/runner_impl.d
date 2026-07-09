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

import sparkles.test_runner.bench : BenchConfig, BenchStats, CounterGroups, runBenchmark;
import sparkles.test_runner.driver : detectCompiler, DriverOptions, runCtfeTests;
import sparkles.test_runner.execution : executeTest;
import sparkles.test_runner.filter : matchesFilter;
import sparkles.test_runner.model : Test, TestResult;
import sparkles.test_runner.reporting : BenchProgress, detectTerminalWidth,
    formatBenchTable, formatCtfeFailedLine, formatCtfeLine, formatMetricCatalog,
    formatResultLine, formatSummary, formatThrown, RunTotals, stderrIsTty;

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
    bool perf;
    string syscalls;
    string metrics;
    string sortBy;
    string[] groupBy;
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

private UnitTestResult runnerMain(Test[] discovered, bool hostIsRunner)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.getopt : arraySep, config, getopt;
    import std.stdio : stdout;

    RunnerOptions options;
    auto args = Runtime.args;
    // Comma-separated array options (`--group-by=dataset,operation`, repeatable
    // `-I` paths) split on `,` in addition to accumulating across occurrences.
    arraySep = ",";
    // `--syscalls` takes an optional value (bare = total only), which std.getopt
    // can't express directly; rewrite a bare occurrence to the `*` sentinel.
    foreach (ref arg; args)
        if (arg == "--syscalls")
            arg = "--syscalls=*";
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

    bool ranLive = false;
    static if (hasCoreCliLive)
    {
        import sparkles.core_cli.term_caps : isTerminal;

        if (isTerminal())
        {
            runParallelLive(runnable, options, colored, width, threads, passed, failed);
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
/// With `--perf`, a hardware-counter counting pass runs per benchmark and the
/// table gains IPC / instruction / miss-rate columns.
private UnitTestResult runBenchMode(Test[] tests, in RunnerOptions options, bool colored)
{
    import std.algorithm.iteration : filter, splitter;
    import std.array : array;
    import std.stdio : stderr, stdout;
    import sparkles.test_runner.metrics : perfFamily, selectsSource, syscallFamily,
        tier0Family;
    import sparkles.test_runner.perf : PerfGroup;
    import sparkles.test_runner.syscalls : SyscallGroup;
    import sparkles.test_runner.tier0 : Tier0Group;

    // Which counting passes to open: --perf OR a --metrics perf metric (so
    // `--metrics=ipc`/`=all` populate the perf columns, mirroring tier0); a
    // --metrics tier0 metric (opt-in, no perms); and --syscalls (null = off,
    // "*" = total only, else a name list).
    const wantPerf = options.perf || selectsSource(options.metrics, "perf");
    const wantTier0 = selectsSource(options.metrics, "tier0");
    const wantSyscalls = options.syscalls.length > 0;
    const syscallNames = (options.syscalls == "*" || !wantSyscalls)
        ? null : options.syscalls.splitter(',').array;
    auto counters = CounterGroups.open(wantPerf, wantTier0, wantSyscalls, syscallNames);
    scope (exit)
        counters.close();
    if (wantPerf && !counters.perf.available)
        stderr.writeln("--perf: hardware counters ", counters.perf.status());
    if (wantSyscalls && !counters.syscalls.available)
        stderr.writeln("--syscalls: syscall counters ", counters.syscalls.status());

    // --list-metrics (also --metrics=? / --metrics=help): print the catalog and
    // exit. Dedicated probes report true availability regardless of the flags;
    // client metrics can't be listed without running, so they're just noted.
    if (options.listMetrics || options.metrics == "?" || options.metrics == "help")
    {
        auto perfProbe = PerfGroup.tryOpen(true);
        scope (exit)
            perfProbe.close();
        auto syscallProbe = SyscallGroup.tryOpen(true, null);
        scope (exit)
            syscallProbe.close();
        auto cat = perfFamily(perfProbe.available)
            ~ tier0Family(Tier0Group.tryOpen(true).available)
            ~ syscallFamily(syscallProbe.available);
        stdout.write(formatMetricCatalog(cat, colored));
        if (!perfProbe.available)
            stderr.writeln("--list-metrics: hardware counters ", perfProbe.status());
        stdout.writeln("client throughput/level metrics are defined per @benchmark and appear when present.");
        return UnitTestResult(0, 0, false, false);
    }

    import std.algorithm.mutation : SwapStrategy;
    import std.algorithm.sorting : sort;
    import std.range : iota;
    import sparkles.test_runner.bench : errorRow, measureCase, registerBenchmark,
        RegisteredCase;
    import sparkles.test_runner.execution : toThrown;
    import std.algorithm.searching : canFind;
    import sparkles.test_runner.metrics : catalog, groupKeyDisplay, groupKeyOf;

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
        const config = BenchConfig(iterations: test.traits.benchIterations);
        auto reg = registerBenchmark(test, config);
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

    // --group-by=list/help/? : print the available label keys and exit.
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
        return UnitTestResult(0, 0, false, false);
    }

    // Effective group keys: =all → every label key; else the given keys (empty =
    // no grouping), warning for any key no registered case carries.
    const(string)[] keys = options.groupBy;
    if (options.groupBy == ["all"])
        keys = allKeys;
    foreach (k; keys)
        if (!allKeys.canFind(k))
            stderr.writeln("--group-by: no @benchmark case has label '", k, "'");

    foreach (ref s; all)
        s.key = keys.length ? groupKeyOf(s.c.labels, keys) : s.test.name;

    // Warn on a --sort-by that names no orderable column (mirrors --group-by), so
    // a typo isn't silently ignored (it would fall back to discovery order). Valid:
    // "name"/"median/iter"/empty, a catalog metric (client/perf/tier0), or a
    // dynamic syscall column (sc:<name> / the "syscalls" total).
    if (options.sortBy.length && options.sortBy != "name" && options.sortBy != "median/iter")
    {
        import std.algorithm.iteration : map;
        import std.algorithm.searching : startsWith;

        auto synthetic = all.map!(s => BenchStats(name: s.c.name, metrics: s.c.metrics)).array;
        const known = catalog(synthetic).canFind!(d => d.name == options.sortBy)
            || options.sortBy == "syscalls" || options.sortBy.startsWith("sc:");
        if (!known)
            stderr.writeln("--sort-by: no metric column named '", options.sortBy,
                "' — rows keep their default order");
    }

    // Schedule: contiguous by key, keys in ascending order (stable within a key).
    auto order = iota(all.length).array;
    order.sort!((i, j) => all[i].key < all[j].key, SwapStrategy.stable);

    progress = BenchProgress(total: all.length,
        active: stderrIsTty(options.noColours) && all.length > 0,
        width: detectTerminalWidth());

    size_t totalRows, errorRows;
    bool firstFlush = true;
    BenchStats[] bucket;
    string curKey;

    void flush()
    {
        if (bucket.length == 0)
            return;
        progress.clear(); // erase the spinner before the table
        if (!firstFlush)
            stdout.write("\n"); // blank line between group tables
        stdout.write(formatBenchTable(bucket, colored, options.metrics,
            options.sortBy, keys));
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

        // Spinner label: the group + the case name when grouping (`name` alone is
        // just the varying dimension), else the case name.
        progress.tick(keys.length ? groupKeyDisplay(s.key) ~ "  " ~ s.c.name : s.c.name);
        try
        {
            auto row = measureCase(s.c, s.config, counters);
            if (row.error.length)
                errorRows++;
            bucket ~= row;
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
            bucket ~= errorRow(s.c.name, s.c.labels, thrown);
            errorRows++;
            totalRows++;
            progress.clear();
            foreach (th; thrown)
                stdout.write(formatThrown(th, colored, true));
        }
    }
    flush();
    progress.clear();

    if (totalRows == 0 && !failed)
        stdout.writeln("no @benchmark tests found");

    return UnitTestResult(totalRows + failed, totalRows - errorRows, false, false);
}

/// Whether `sparkles:core-cli` is in the tested package's dependency closure
/// (see `reporting.d` for the pattern) — its `detectTermCaps` is the shared
/// implementation of the console-preparation policy this runner used to inline.
private enum bool hasCoreCliTermCaps = __traits(compiles, {
    import sparkles.core_cli.term_caps : detectTermCaps;
});

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

static if (hasCoreCliLive)
/// The tty variant of the parallel run: a polled `N/M` progress line under the
/// streaming result lines. Workers never touch the terminal — they append their
/// finished output to a mutex-guarded queue and bump an atomic counter; the
/// main thread (no longer participating in the work) drains the queue through
/// `printAbove` and repaints one `ProgressLine`, which is erased on completion
/// so the permanent output matches the plain path.
private void runParallelLive(
    Test[] runnable, in RunnerOptions options, bool colored, uint width,
    size_t threads, ref shared size_t passed, ref shared size_t failed)
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
