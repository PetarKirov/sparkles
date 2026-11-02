/**
 * The runner's options: one model and one parser for both clients of the
 * runner protocol, so an option means the same in each (process-model TRM4).
 */
module sparkles.test_runner.options;

struct RunnerOptions
{
    string include;
    string exclude;
    bool verbose;
    uint threads;
    bool noColors;
    bool list;
    bool skipSlow;
    bool onlySlow;
    bool bench;
    bool perf;
    bool perfScaled; /// keep the full group when it multiplexes; label estimates
    uint perfIters;  /// pin the counting-pass iteration count (0 = auto)
    uint perfBatch;  /// pin counting-pass iterations per bracket (0 = auto)
    string syscalls;
    string metrics;
    string sortBy;
    string[] groupBy;
    string benchJson;  /// --bench-json=FILE ("" = off)
    uint benchMinTime; /// --bench-min-time=MS (0 = BenchConfig's 5 ms default)
    bool listMetrics;
    string datasets;
    bool listDatasets;
    string ctfeTrace;
    bool betterC;
    bool wasm;
    bool wasmBare;
    string compiler;
    string[] importPaths;
    string[] includeImports;
    bool noAutoInclude;
    bool requireToolchain;
    bool keep;
    string[] stringImportPaths;
    string[] versions;
    string[] dflags;
    string probeDir;
    bool noDub;
}

/// The outcome of CLI parsing: either a populated `options`, a request for the
/// help text, or a one-line `error` — never a thrown exception, which would
/// escape the unittest hook as a raw stack trace.
struct ParsedArgs
{
    import std.getopt : Option;

    RunnerOptions options;
    string error; /// non-empty = fail the run with this message
    bool helpWanted;
    Option[] helpOptions; /// populated when `helpWanted`
}

/**
Parses the runner's CLI. A malformed value (`-t abc`), an unknown option,
and stray positional arguments (`--syscalls futex` — values attach with
`=`) all yield a readable `error` instead of an uncaught exception.

$(B `--DRT-*` options are dropped, not rejected.) They belong to druntime —
`--DRT-covopt=dstpath:…` redirects `-cov` listings, `--DRT-gcopt=…` configures
the collector — and the runtime acts on them before `main` runs, but leaves
them in the argv this hook is handed. Treating them as unknown made a
`-cov` build unusable: coverage listings were written correctly and the run
then failed on the very option that produced them.
*/
ParsedArgs parseRunnerOptions(string[] args)
{
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : startsWith;
    import std.array : array;
    import std.conv : ConvException, text;
    import std.getopt : arraySep, config, getopt, GetOptException;

    args = args.filter!(a => !a.startsWith("--DRT-")
        && !a.startsWith("dstpath:") && !a.startsWith("merge:") && !a.startsWith("srcpath:")).array;

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
        "no-colors",
            "Disable colored output",
            &options.noColors,
        "l|list",
            "List discovered tests without running them",
            &options.list,
        "skip-slow",
            "Leave out @slow tests (the summary counts them)",
            &options.skipSlow,
        "only-slow",
            "Run only @slow tests",
            &options.onlySlow,
        "bench",
            "Run @benchmark tests (ns/iter statistics) and @workload tests " ~
            "(single-pass window deltas + wall decomposition) instead of regular tests",
            &options.bench,
        "perf",
            "With --bench: collect hardware performance counters per benchmark " ~
            "(Linux perf_event; IPC, instructions, cache/branch miss rates)",
            &options.perf,
        "perf-scaled",
            "With --perf: keep the full counter group when the PMU would " ~
            "multiplex it; scaled values render as labeled estimates (≈). " ~
            "Default: the group shrinks until counts are exact",
            &options.perfScaled,
        "perf-iters",
            "With --bench: pin the counting-pass iteration count (default: " ~
            "the timing pass's count, capped) — makes per-pass counter totals " ~
            "and amortized one-time costs reproducible across runs",
            &options.perfIters,
        "perf-batch",
            "With --bench: pin how many iterations share one counting-pass " ~
            "bracket (default: auto-sized so a bracket spans ~1ms, so the " ~
            "bracket's own cost cannot dominate a fast body). 1 disables batching",
            &options.perfBatch,
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
            "(all rows in measurement order, incl. error rows, plus a meta block " ~
            "and, when @workload tests ran, a windows array)",
            &options.benchJson,
        "bench-min-time",
            "With --bench: per-case measurement budget in milliseconds — per-call " ~
            "cases: minimum total measured time; batched: target per sample. Default 5",
            &options.benchMinTime,
        "list-metrics",
            "With --bench: list the available metric columns (name, class, source) and exit",
            &options.listMetrics,
        "datasets",
            "With --bench: comma-separated dataset names to run (glob with '*'; " ~
            "'all' = every dataset; '?'/'help' = list them)",
            &options.datasets,
        "list-datasets",
            "With --bench: list available benchmark datasets and exit",
            &options.listDatasets,
        "ctfe-trace",
            "Evaluate @ctfe tests under LDC -ftime-trace (writing the trace " ~
            "to the given file) and report per-test CTFE cost",
            &options.ctfeTrace,
        "better-c",
            "Extract @betterC tests, compile them with -betterC, and run them",
            &options.betterC,
        "wasm",
            "Extract @wasm tests, compile them for wasm32-unknown-wasip1 with the full " ~
            "druntime and Phobos, and run them under wasmtime",
            &options.wasm,
        "wasm-bare",
            "Extract @wasm tests, compile them for bare wasm32 with -betterC, and run them " ~
            "under node, deno, bun or wasmtime",
            &options.wasmBare,
        "compiler",
            "D compiler for @ctfe/--better-c/--wasm/--wasm-bare (default: $DC, then ldc2, dmd; " ~
            "--wasm tries $SPARKLES_WASI_LDC first)",
            &options.compiler,
        "I|import-path",
            "Extra import path for @ctfe/--better-c/--wasm (repeatable)",
            &options.importPaths,
        "include-import",
            "Extra -i=<pattern> for --better-c/--wasm, e.g. std.ascii (repeatable)",
            &options.includeImports,
        "no-auto-include",
            "Don't compile the extracted tests' own modules into --better-c/--wasm",
            &options.noAutoInclude,
        "require-toolchain",
            "With --better-c/--wasm: fail instead of skipping when the toolchain is missing",
            &options.requireToolchain,
        "keep",
            "Keep the files generated by @ctfe/--better-c/--wasm",
            &options.keep,
        "string-import-path",
            "Extra string import path for @ctfe/--better-c/--wasm (repeatable)",
            &options.stringImportPaths,
        "version",
            "Version identifier for @ctfe/--better-c/--wasm (repeatable)",
            &options.versions,
        "dflag",
            "Compiler flag for @ctfe/--better-c/--wasm, e.g. -preview=dip1000 (repeatable)",
            &options.dflags,
        "probe-dir",
            "Where @ctfe/--better-c/--wasm write their generated sources and objects",
            &options.probeDir,
        "no-dub",
            "Never run dub describe for import paths or language flags",
            &options.noDub,
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

    auto ds = parseRunnerOptions(["prog", "--datasets=twitter,canada", "--list-datasets"]);
    assert(!ds.error.length);
    assert(ds.options.datasets == "twitter,canada");
    assert(ds.options.listDatasets);

    auto slow = parseRunnerOptions(["prog", "--skip-slow", "--only-slow"]);
    assert(!slow.error.length && slow.options.skipSlow && slow.options.onlySlow);

    auto help = parseRunnerOptions(["prog", "--help"]);
    assert(!help.error.length && help.helpWanted && help.helpOptions.length);
}

@("runner.parseRunnerOptions.ignoresDruntimeOptions")
@system
unittest
{
    // druntime's own options reach this argv but are not the application's to
    // reject: the runtime has already acted on them. Rejecting them made
    // `dub test -b unittest-cov -- --DRT-covopt=dstpath:DIR` fail *after*
    // writing the coverage listings it was asked for.
    auto cov = parseRunnerOptions(["prog", "--DRT-covopt=dstpath:/tmp/cov", "-t", "2"]);
    assert(!cov.error.length, cov.error);
    assert(cov.options.threads == 2);

    // They are dropped, not treated as positionals — the stray-argument check
    // must not fire on them either.
    assert(!parseRunnerOptions(["prog", "--DRT-gcopt=profile:1"]).error.length);

    // An option that merely looks similar is still unknown.
    assert(parseRunnerOptions(["prog", "--DRT"]).error.length);
}
