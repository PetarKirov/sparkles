/// `ci test`, `ci slow-tests list` and `ci placements list`: dub's builds and
/// tests of the sub-packages, their coverage, sanitizer, special-mode and slow
/// variants, and the placement of a run's shard.
module commands.test_;

import cli : Sanitizer, SpecialModes, TestCommand;
import commands.files : detectRepoRoot;
import commands.maintenance : seedDubHome;
import commands.output :
    RunMonitor, displayTestRunSummary, flushStdout, resultFooterRight, resultVerdict,
    streamResultBox, uiWidth;
import commands.toolchain :
    compilerIsLdc, dubTestCommand, findWasiCompiler, mergeEnv, parallelTestThreads,
    resolvedCompiler, sanitizeAsanOptions, sanitizeChildEnv, sanitizeCompilerFlags, sanitizePlatformSupported,
    testBinaryRan, testBuildType, withLdcDflags, withTestArgs;
import sparkles.build_primitives.task.action : EnvEntry;
import core.time : Duration, msecs;
import coverage : collectCoverage, PackageCoverage;
import dub_deps : subPackageDirectories;
import perf_record : testTaskId;
import perf_run : RunRecorder;
import placements : parseShard;
import placements_run : chooseShard, loadPlacements, PlacementArgs, placementMatrix;
import slow_tests :
    exactNamesPattern, matrixJson, SlowTestJob, slowTestsInListing, slowTestsInSource;
import sparkles.base.hw_caps : hwParallelism, describe;
import sparkles.base.logger : error, info, LogDelta, warning;
import sparkles.base.styled_template : styledText;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;
import sparkles.core_cli.process_utils :
    ChildStdin, executeMonitoredLines, MonitoredLineRange, MonitoredResult, ResourceUsage;
import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;
import std.algorithm : any, canFind, filter, map, sort;
import std.array : array, join;
import std.conv : text, to;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : baseName, buildPath;
import std.process : environment, execute;
import std.stdio : stderr, stdout, writeln;
import std.algorithm.searching : startsWith;
import std.array : split;
import std.string : endsWith, replace;
import graph_driver : GraphRun;
import watch_mode : runWatchMode, WatchAction;

/// `ci test`: the mode its options select.
RunExpected!void runTestCommand(in TestCommand cmd)
{
    seedDubHome();
    const where = PlacementArgs(cmd.placement, cmd.shard, cmd.historyTip, cmd.history.historyRemote);
    if (cmd.buildOnly)
        return cmd.watch ? runWatchMode(WatchAction.build, cmd.failFast)
            : runTestsOnGraph(cmd.failFast, false, cmd.from, where, buildOnly: true, cmd);
    if (cmd.slow)
        return runSlowTestsMode(cmd.from, cmd.tests, cmd.failFast);
    if (cmd.specialModes != SpecialModes.off)
        return runExtractedTestsMode(cmd.failFast, cmd.from, where,
            ExtractedModes(
                betterC: cmd.specialModes != SpecialModes.wasm,
                wasm: cmd.specialModes != SpecialModes.betterc));
    if (cmd.sanitize == Sanitizer.address)
    {
        // ASan and `-cov` both instrument every function, and the listings
        // would describe an ASan build nobody ships while overwriting the
        // plain run's `build/coverage`.
        if (cmd.coverage)
            info(i"coverage is off under --sanitize (ASan and -cov instrumentation do not mix)");
        if (!compilerIsLdc(environment.get("DC", "")))
            return failRun("ci test --sanitize address requires LDC (set DC=ldc2)");
        if (!sanitizePlatformSupported())
            return failRun("ci test --sanitize address is Linux-only: nixpkgs LDC has no ASan runtime on Darwin");
        return runTestsOnGraph(cmd.failFast, false, cmd.from, where, buildOnly: false, cmd, sanitize: true);
    }
    if (cmd.watch)
        return runWatchMode(WatchAction.test, cmd.failFast);
    return runTestsOnGraph(cmd.failFast, cmd.coverage, cmd.from, where, buildOnly: false, cmd);
}

/**
How a test run collects coverage, or that it does not.

`-cov` is not free — every counted line becomes an atomic increment — so this
is one value the test stream carries rather than a flag it re-interprets.

The listings all land in **one** directory and are merged (`merge:1`), which is
what makes them usable afterwards. A run scoped to a single package also emits
listings for every module it compiled, and those read `0% covered` because that
package's tests never exercised them; merging every package's run into one set
replaces those zeroes with the coverage some other package's tests did provide.
`hue --cov` then has a single directory holding one truthful answer per file.
*/
private struct CoverageRun
{
    bool enabled;
    string dir;       /// merged destination, `build/coverage`
    string dflags;    /// extra `$DFLAGS` for the child, empty when none apply

    /// The runtime arguments — the test binary's, so they belong after `--`.
    string[] runtimeArgs() const @safe pure nothrow
        => enabled ? ["--DRT-covopt=merge:1", "--DRT-covopt=dstpath:" ~ dir] : null;

    /// The environment additions for the child.
    const(string[string]) env() const @safe pure nothrow
        => enabled && dflags.length ? ["DFLAGS": dflags] : null;
}


/**
The sub-package paths a test run covers: those `--from` names, in request
order, or every one in `all` when it names none. Names no sub-package has are
returned in `unknown`.
*/
private string[] narrowSubPackages(in string[] all, in string[] requested, out string[] unknown) @safe pure
{
    import each_commit : selectPackages;

    if (requested.length)
        return selectPackages(requested, all, unknown);
    return all.dup;
}

@("ci.narrowSubPackages.requested")
@safe pure
unittest
{
    const all = ["libs/base", "libs/ui", "apps/hue"];
    string[] unknown;
    assert(narrowSubPackages(all, [], unknown) == all);
    assert(narrowSubPackages(all, ["hue", "base"], unknown) == ["apps/hue", "libs/base"],
        "in request order");
    assert(unknown.length == 0);
    narrowSubPackages(all, ["uii"], unknown);
    assert(unknown == ["uii"], "a typo is reported");
}

/// The options of a test run that change what it runs, as its run record's
/// `invocation.options` holds them (observability OBR7): not `--fail-fast`.
private string[] recordedOptions(in string[] requested, bool coverage) @safe pure
{
    string[] options;
    if (requested.length)
        options ~= ["--from"] ~ requested.dup;
    if (coverage)
        options ~= "--coverage";
    return options;
}

/**
The sub-packages a test run covers ($(LREF narrowSubPackages)). A name no
sub-package has is an error rather than a smaller run: a typo would otherwise
pass having tested nothing.
*/
private bool requestedSubPackages(string repoRoot, in string[] requested, out string[] chosen)
{
    const all = subPackageDirectories(repoRoot);
    if (all.length == 0)
    {
        error(i"No sub-packages found in dub.sdl");
        return false;
    }
    string[] unknown;
    chosen = narrowSubPackages(all, requested, unknown);
    if (unknown.length)
    {
        error(i"--from: no sub-package named $(unknown.join(", "))");
        return false;
    }
    return true;
}

/**
`ci test` and `ci test --build-only` on the build graph (ci task-DAG M7b): the
selected packages' test roots planned as actions, compiled and linked
against the shared store, and each test leg run through the runner core
(CIC11). A placement chooses the legs and whether coverage is collected
(OD22); each leg's wall time goes to the run record (OD21), and each
coverage test's listings are merged into `build/coverage`.
*/
private RunExpected!void runTestsOnGraph(bool failFast, bool coverage, in string[] requested,
    in PlacementArgs where, bool buildOnly, in TestCommand cmd = TestCommand.init, bool sanitize = false)
{
    import cli : parseCapacity;
    import sparkles.build_graph.execute : RunReporting;
    import sparkles.ci_provider : CiLog, systemEnvironment;
    import graph_driver : logicalProcessors;

    import core.time : MonoTime;
    import graph_driver : runGraph, RunOptions;
    import sparkles.build_graph.actions : TestLeg;
    import std.datetime.systime : Clock;
    import std.process : thisProcessID;

    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
        return failRun("Could not detect repository root");
    string[] subPackages;
    // §4: selectors, a change set and the closures through the selection
    // algebra (TDS4–TDS8); plain package names as before.
    if (cmd.since.length || cmd.dependencies || cmd.dependents
        || requested.any!(r => r.canFind('/') || r.canFind(':') || r.canFind('*') || r.canFind('?')))
    {
        const why = focusedPackages(repoRoot, cmd, subPackages);
        if (why.length)
            return failRun(why);
    }
    else if (!requestedSubPackages(repoRoot, requested, subPackages))
        return failRun("could not resolve the requested sub-packages");
    if (where.shard.length && !narrowToShard(repoRoot, requested, where, subPackages))
        return failRun("could not narrow the sub-packages to shard " ~ where.shard);
    // A placement chooses its legs and whether it collects coverage (OD22).
    bool serialLeg = true, parallelLeg = true;
    if (where.placement.length && !sanitize)
    {
        auto loaded = loadPlacements(repoRoot);
        const p = loaded.hasError ? null : loaded.value.find(where.placement);
        if (p is null)
            return failRun(text(i"$(loaded.hasError ? loaded.error : "ci/placements.json has no placement " ~ where.placement)"));
        serialLeg = p.serialLeg;
        parallelLeg = p.parallelLeg;
        if (coverage && !p.coverage)
            info(i"$(where.placement) collects no coverage; testing without -cov");
        coverage = coverage && p.coverage;
    }
    coverage = coverage && !buildOnly;
    // CIC1: the capacity in weighted units: `--jobs`, `$SPARKLES_CI_JOBS`,
    // the host's processors.
    const jobs = cmd.jobs.length ? parseCapacity(cmd.jobs)
        : parseCapacity(environment.get("SPARKLES_CI_JOBS", "")) ? parseCapacity(environment.get("SPARKLES_CI_JOBS", ""))
        : logicalProcessors;
    // A leg claims its `-t` (CIC11), so no wider than the capacity: on a
    // container whose processors are the host's, it would never be admitted.
    const hostN = cast(uint) parallelTestThreads(hwParallelism());
    const parallelN = hostN < jobs ? hostN : jobs;
    TestLeg[] legs;
    // Sanitize runs one leg, which keeps the `@slow` tests: the `-t 1` leg
    // contrasts with the stack watermark ASan turns off, and the runner sizes
    // ASan workers at 4 MiB (M8).
    if (sanitize)
        legs = [TestLeg(parallelN, false, "sanitize")];
    else
    {
        if (serialLeg)
            legs ~= TestLeg(1, true, "serial");
        if (parallelLeg)
            legs ~= TestLeg(parallelN, true, "parallel");
    }

    const names = subPackages.map!(p => p.baseName).array;
    const xdg = environment.get("XDG_CACHE_HOME", buildPath(environment.get("HOME", "/"), ".cache"));
    const cache = buildPath(xdg, "sparkles");
    const into = buildPath(cache, "runs", text("ci-test-", Clock.currTime.toUnixTime, "-", thisProcessID));
    info(i"$(names.length) package(s) to $(buildOnly ? "build" : "test") through the build graph; run directory $(into)");

    // A dry run records nothing either.
    auto recorder = RunRecorder.open(repoRoot, sanitize ? "test --sanitize address" : "test",
        recordedOptions(requested, coverage), where.placement, where.shard);
    scope (exit)
        if (!cmd.dryRun)
            if (const degradation = recorder.finish())
                warning(i"$(degradation)");

    const reporting = RunReporting(interlaced: cmd.interlaced, timings: true, dryRun: cmd.dryRun,
        ci: CiLog.detect(&systemEnvironment));
    // CIC12 under a dry run: the actions that would fail, from BGS8's
    // explain, which executes and writes nothing.
    if (cmd.dryRun && cmd.requireCached.length)
    {
        auto e = runGraph(repoRoot, null, RunOptions(into: into, cache: cache, packages: names.dup, legs: legs,
            coverage: coverage, buildOnly: buildOnly, explain: true));
        if (e.error.length)
            return failRun(e.error);
        size_t failing;
        foreach (line; e.stats.explained)
        {
            const kind = line.split(":")[0];
            if (cmd.requireCached.canFind(kind) && !line.canFind(": hit") && !line.canFind("digest record"))
            {
                writeln("would fail (--require-cached ", kind, "): ", line);
                ++failing;
            }
        }
        writeln(failing, " action(s) would fail under --require-cached ", cmd.requireCached.join(" "));
        return ranOk();
    }
    auto g = runGraph(repoRoot, null, RunOptions(into: into, cache: cache, runnerCore: true, packages: names.dup,
        legs: legs, coverage: coverage, buildOnly: buildOnly, failFast: failFast, echo: true, jobs: jobs,
        reporting: reporting, requireCached: cmd.requireCached.dup,
        extraFlags: sanitize ? [sanitizeCompilerFlags] : null,
        runtimeEnvironment: sanitize ? [EnvEntry("ASAN_OPTIONS", sanitizeAsanOptions)] : null));
    if (cmd.dryRun)
        return g.error.length ? failRun(g.error) : ranOk();
    if (g.error.length)
        return failRun(g.error);

    // OD21: each leg's wall time, under the record's task id.
    string[] failedPackages;
    foreach (task, wall; g.stats.wallTimes)
    {
        if (!task.startsWith("test:"))
            continue;
        const parts = task.split(":");
        const pkg = parts.length > 1 ? parts[1].replace("sparkles.", "") : task;
        const serial = task.endsWith(":serial");
        const ok = g.stats.succeeded.get(task, false);
        const began = g.stats.startedAt.get(task, MonoTime.init);
        recorder.add(testTaskId(pkg, sanitize ? "sanitize" : "unittest", serial), ok, began, began + wall);
        if (!ok && !failedPackages.canFind(pkg))
            failedPackages ~= pkg;
    }
    if (coverage)
        mergeCoverage(repoRoot, g, failedPackages, subPackages);
    // What `ci cache verify --rerun` checks (CIC13).
    {
        import graph_driver : LastRun, recordLastRun;

        recordLastRun(cache, LastRun(names.dup, legs, coverage, buildOnly, g.stats.resultKeys.dup));
    }
    if (g.exitCode != 0)
        return failRun(failedPackages.length ? text(failedPackages.length, " test package(s) failed: ",
            failedPackages.join(", ")) : text("the build graph's run failed (exit ", g.exitCode, ")"));
    return ranOk();
}

/**
The packages `cmd`'s selectors choose (ci task-DAG §4): `--from` selectors and
globs, `--since`'s change set judged by the packages' claims (CIC5), and the
dependency and dependent closures, as the directories the root recipe names.
A package outside this host's platforms is left out. The error, or null.
*/
private string focusedPackages(string repoRoot, in TestCommand cmd, out string[] directories)
{
    import repository_inputs : repositoryFocus;
    import sparkles.build_primitives.dub_manifest : hostPlatformTokens;
    import sparkles.build_primitives.resolve.configure : processEnvironment;
    import sparkles.build_primitives.workspace.package_graph : RecipeRole;
    import sparkles.build_primitives.workspace.select : planPackages;
    import watch_mode : hostBuildPlatform, registrySources;

    auto options = repositoryFocus(hostBuildPlatform(), registrySources(repoRoot), processEnvironment());
    options.from = cmd.from;
    options.since = cmd.since.length > 0;
    options.sinceRef = cmd.since;
    options.dependencies = cmd.dependencies;
    options.dependents = cmd.dependents;
    auto planned = planPackages(repoRoot, cmd.buildOnly ? RecipeRole.build : RecipeRole.test, options,
        hostPlatformTokens());
    if (planned.hasError)
        return text("selection: ", planned.error.detail);
    foreach (ref p; planned.value.selection.packages)
        if (!p.platformSkipped)
            directories ~= planned.value.graph.packages[p.graphIndex].path;
    if (!directories.length)
        return "the selection holds no package that runs on this host";
    info(i"selected $(directories.length) package(s): $(directories.map!(d => d.baseName).join(", "))");
    return null;
}

/**
Merges each coverage test's listings beneath the run's `out` into
`build/coverage`, published whole (CIC7): merged into a sibling directory,
which then replaces the old one by rename. Each test wrote its own
directory, so no two share a destination, and summing is commutative, so
the merge is deterministic. A package whose coverage build failed but
whose plain fallback passed is `Degraded(noCoverage)`: reported as
uncovered, not failed.
*/
private void mergeCoverage(string repoRoot, ref const GraphRun g, in string[] failedPackages,
    in string[] subPackages)
{
    import coverage : mergeListings;
    import std.file : dirEntries, rename, rmdirRecurse, SpanMode;
    import std.process : thisProcessID;
    import std.sumtype : match;
    import sparkles.build_graph.actions : ActionKind;
    import sparkles.build_primitives.task.action : ProcessAction;

    // CIC7's classification, from what each package's tests did.
    bool[string] covered, plainPassed;
    foreach (ref a; g.plan.graph.actions)
    {
        if (a.kind != ActionKind.test || !g.stats.succeeded.get(a.id.text, false))
            continue;
        const parts = a.id.text.split(":");
        const pkg = parts.length > 1 ? parts[1].replace("sparkles.", "") : a.id.text;
        const withCoverage = a.action.match!((ref const ProcessAction p) => p.argv.any!(x => x.startsWith("--DRT-covopt=")),
            (ref const _) => false);
        (withCoverage ? covered : plainPassed)[pkg] = true;
    }
    string[] uncovered;
    foreach (pkg, _; plainPassed)
        if (pkg !in covered)
            uncovered ~= pkg;
    uncovered.sort();

    CoverageRun cov = {enabled: true, dir: buildPath(repoRoot, "build", "coverage")};
    const staging = text(cov.dir, ".", thisProcessID);
    if (staging.exists)
        staging.rmdirRecurse;
    staging.mkdirRecurse;
    const outs = buildPath(g.into, "out");
    if (outs.exists)
        foreach (e; dirEntries(outs, "*.lst", SpanMode.depth))
        {
            // The generated test root is each package's own module.
            if (e.name.baseName.startsWith("generated-"))
                continue;
            const dest = buildPath(staging, e.name.baseName);
            const listing = readText(e.name);
            if (!dest.exists)
                write(dest, listing);
            else if (const merged = mergeListings(readText(dest), listing))
                write(dest, merged);
            else
                warning(i"$(e.name): its source differs from $(dest)'s, kept apart");
        }
    if (cov.dir.exists)
        cov.dir.rmdirRecurse;
    rename(staging, cov.dir);
    reportCoverage(subPackages, cov, failedPackages, uncovered);
}

/**
Reports line coverage from the listings a `ci test` run merged into `cov.dir`.

Reports only. There is no threshold and nothing fails on a low number: D's
`-cov` counts template instantiations per instantiation and emits listings for
imported modules too, so the figure is a trend indicator rather than a contract.
Gating on it would buy noise.

A package's row counts only the files it owns, beneath its own directory and no
nested package's
($(REF reportedUnder, coverage)), because the merged set describes the whole
repository — every module any package compiled. What merging changes is the
*number*: a file now carries the coverage every package's tests gave it, not
just its own package's, which is both the more useful figure and the one a
viewer shows.

Params:
    subPackages = repository-relative sub-package directories
    cov = the run that produced the listings
    failedPackages = packages whose tests did not pass, whose rows cannot be read
        as coverage
*/
private void reportCoverage(in string[] subPackages, in CoverageRun cov,
    in string[] failedPackages, in string[] uncovered)
{
    import std.algorithm : sort;
    import sparkles.base.text.writers : formatted;
    import sparkles.ui.components.table : drawTable, TableBuilder, TableProps;

    if (!cov.enabled || !cov.dir.exists)
        return;

    PackageCoverage[] results;
    foreach (pkg; subPackages)
        results ~= collectCoverage(cov.dir, pkg.baseName, pkg, subPackages);
    results.sort!((a, b) => a.percent < b.percent);

    static void writePercent(W)(ref W w, double p)
    {
        import std.format : formattedWrite;

        w.formattedWrite("%.1f", p);
    }

    TableBuilder rows;
    rows.row("package", "files", "covered", "coverable", "%");
    size_t totalCovered, totalCoverable;
    foreach (r; results)
    {
        totalCovered += r.covered;
        totalCoverable += r.coverable;
        rows.row(r.name, r.files.length, r.covered, r.coverable);
        if (r.coverable == 0)
            rows.cell("—");
        else
            rows.cell!writePercent(r.percent);
    }
    const total = totalCoverable == 0 ? 100.0 : (100.0 * totalCovered) / totalCoverable;
    rows.row("TOTAL", "", totalCovered, totalCoverable).cell!writePercent(total);

    writeln();
    writeln(drawTable(rows, TableProps(headerRows: 1)));
    styledText(i"{dim listings in} $(cov.dir) {dim — open one with} hue --cov").writeln;

    // The uncovered note goes to stderr; flush so it cannot land in the
    // middle of the table stdout has not finished writing.
    stdout.flush();

    // A package that only builds without `-cov` is tested but unmeasured, and
    // a row of zeroes would read as untested rather than as unmeasured.
    if (uncovered.length)
        warning(i"{yellow no coverage} for $(uncovered.length) package(s): $(uncovered.join(", ")) — they do not link under -cov, and were tested without it");
}

/**
The runner flags of the extracted modes each of `subPackages` (repository-
relative directories) uses, by package name, each with `--require-toolchain`:
`ci pipeline`'s special-mode legs.
*/
string[][string] specialModeArguments(string repoRoot, in string[] subPackages)
{
    string[][string] flags;
    foreach (pkg; subPackages)
    {
        const modes = extractedModesOf(repoRoot, pkg);
        string[] mine;
        if (modes.betterC)
            mine ~= "--better-c";
        if (modes.wasm)
            mine ~= "--wasm";
        if (mine.length)
            flags[pkg.baseName] = mine ~ "--require-toolchain";
    }
    return flags;
}

/// Which of the test runner's extracted-test modes a sub-package opts into.
struct ExtractedModes
{
    bool betterC; /// has at least one `@betterC` test
    bool wasm;    /// has at least one `@wasm` test

    bool any() const @safe pure nothrow @nogc => betterC || wasm;
}

/// The extracted-test modes a D source file opts into.
///
/// A deliberately shallow text scan, not a parse: the marker attributes are
/// written literally at their use sites, so this has no false negatives —
/// which is the direction that matters, since a missed module means a mode
/// silently goes unexercised. False positives (the attribute named in a doc
/// comment, as the runner's own modules do) merely run a mode that then
/// reports "no tests found" and exits 0, so they cost a little time and
/// nothing else.
ExtractedModes extractedModesInSource(scope const(char)[] source) @safe pure nothrow
{
    import std.algorithm.searching : canFind;

    return ExtractedModes(
        betterC: source.canFind("@betterC"),
        wasm: source.canFind("@wasm"),
    );
}

@("ci.extractedModesInSource")
@safe pure nothrow
unittest
{
    assert(extractedModesInSource("@betterC @safe unittest {}") == ExtractedModes(betterC: true));
    assert(extractedModesInSource("@wasm @safe unittest {}") == ExtractedModes(wasm: true));
    // The value form of the attribute is found the same way.
    assert(extractedModesInSource("@betterC(selfContained: true)")
        == ExtractedModes(betterC: true));
    assert(extractedModesInSource("@wasm(selfContained: true) @betterC")
        == ExtractedModes(betterC: true, wasm: true));

    auto none = extractedModesInSource("@safe @nogc unittest {}");
    assert(!none.any);
    assert(!extractedModesInSource("").any);
}

/// Whether a sub-package's `dub.sdl` wires in `sparkles:test-runner`, by
/// either recipe: a `dependency "sparkles:test-runner"` (the common path) or
/// the cycle-safe `sourcePaths "../test-runner/src" …` source-include used by
/// `base`, `core-cli`, and `test-utils`.
///
/// This gate is what keeps `ci test --special-modes all` honest. Without the runner,
/// `dub test :pkg -- --better-c` reaches druntime's default tester, which
/// ignores the flag, runs the ordinary unittests and exits 0 — a green that
/// means nothing. Better to leave such a package out than to report success
/// for a mode that never ran.
///
/// The recipe is read through the `dub.sdl` schema, in every scope that can
/// declare either: the top level, each configuration and each build type. A
/// comment that mentions the runner does not count.
bool integratesTestRunner(scope const(char)[] dubConfig) @safe pure
{
    import std.algorithm.searching : any, canFind, endsWith;
    import sparkles.build_primitives.dub_manifest : DubBuildSettings, parseDubManifest,
        valuesOf;

    static bool wires(scope const DubBuildSettings settings)
        => settings.dependencies.any!(d => d.name == "sparkles:test-runner")
            || settings.sourcePaths.valuesOf.any!(p => p.endsWith("test-runner/src"));

    const parsed = parseDubManifest(dubConfig);
    if (parsed.hasError)
        return false;
    const manifest = parsed.value;
    return wires(manifest.buildSettings)
        || manifest.configurations.any!(c => wires(c.buildSettings))
        || manifest.buildTypes.any!(b => wires(b.buildSettings));
}

@("ci.integratesTestRunner")
@safe pure
unittest
{
    assert(integratesTestRunner(`    dependency "sparkles:test-runner" path="../.."`));
    assert(integratesTestRunner(`configuration "unittest" {
    sourcePaths "../test-runner/src" "../test-runner-impl/src"
}`));
    assert(!integratesTestRunner(`dependency "sparkles:base" path="../.."`));
    assert(!integratesTestRunner(""));
    // A comment, or a package merely named like it, is not the runner.
    assert(!integratesTestRunner("// test-runner comes later\nname \"x\"\n"));
    assert(!integratesTestRunner(`dependency "test-runner-extras" version="*"`));
}

/// The modes any `.d` file under `packagePath` opts into — empty for a
/// package that does not integrate the runner (see $(LREF integratesTestRunner)).
private ExtractedModes extractedModesOf(string repoRoot, string packagePath)
{
    import std.file : dirEntries, readText, SpanMode;
    import std.path : buildPath, extension;

    const root = buildPath(repoRoot, packagePath);
    ExtractedModes modes;
    if (!root.exists)
        return modes;

    const dubConfig = buildPath(root, "dub.sdl");
    if (!dubConfig.exists || !integratesTestRunner(dubConfig.readText))
        return modes;
    foreach (entry; dirEntries(root, SpanMode.depth))
    {
        if (!entry.isFile || entry.name.extension != ".d")
            continue;
        const found = extractedModesInSource(entry.name.readText);
        modes.betterC |= found.betterC;
        modes.wasm |= found.wasm;
        if (modes.betterC && modes.wasm)
            break; // nothing left to learn
    }
    return modes;
}

/// `ci test --special-modes all`: run the test runner's `--better-c` and `--wasm` modes
/// for every sub-package whose sources use the matching marker attribute.
///
/// These modes are not covered by `ci test`: a `@betterC` test runs as an
/// ordinary unittest there, and only `--better-c` additionally extracts it,
/// compiles it without druntime, and runs the result — so a break in the
/// extraction, the `-betterC` codegen, or the wasm cross-compile is invisible
/// to `dub test`.
///
/// `--require-toolchain` is what makes this job meaningful: both modes
/// normally $(I skip) when their toolchain is missing (no D compiler, no
/// wasm-ld, no wasm runtime), which is right for a contributor's machine and
/// exactly wrong here — without it a missing linker would leave this reporting
/// success having run nothing.
private RunExpected!void runExtractedTestsMode(bool failFast, in string[] requested,
    in PlacementArgs where, ExtractedModes wanted)
{
    info(i"resolving repository root");
    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
    return failRun("Could not detect repository root");
    info(i"repository root: $(repoRoot)");

    info(i"scanning sub-packages for @betterC / @wasm");
    string[] subPackages;
    if (!requestedSubPackages(repoRoot, requested, subPackages))
        return failRun("could not resolve the requested sub-packages");
    if (where.shard.length && !narrowToShard(repoRoot, requested, where, subPackages))
        return failRun("could not narrow the sub-packages to shard " ~ where.shard);

    struct Job
    {
        string packagePath; /// repo-relative, e.g. `libs/base`
        string packageName;
        string flag; /// `--better-c` or `--wasm`
    }

    Job[] jobs;
    foreach (pkg; subPackages)
    {
        const modes = extractedModesOf(repoRoot, pkg);
        if (modes.betterC && wanted.betterC)
            jobs ~= Job(pkg, pkg.baseName, "--better-c");
        if (modes.wasm && wanted.wasm)
            jobs ~= Job(pkg, pkg.baseName, "--wasm");
    }

    if (jobs.length == 0)
    {
        // Not a pass: the repo is supposed to have such tests, so an empty
        // sweep means the scan (or the attributes) regressed.
        return failRun("No sub-package uses @betterC or @wasm — nothing to run");
    }

    // M8: each package's modes are one leg of its test binary on the build
    // graph, run by the runner core's driver.
    import core.time : MonoTime;
    import graph_driver : runGraph, RunOptions;
    import sparkles.build_graph.actions : TestLeg;
    import std.datetime.systime : Clock;
    import std.process : thisProcessID;

    string[] packages;
    string[][string] arguments;
    foreach (job; jobs)
    {
        if (!packages.canFind(job.packageName))
            packages ~= job.packageName;
        arguments["sparkles:" ~ job.packageName] ~= job.flag;
    }
    foreach (pkg, ref args; arguments)
        args ~= "--require-toolchain";
    info(i"$(jobs.length) extracted-test mode(s) in $(packages.length) package(s)");
    auto recorder = RunRecorder.open(repoRoot, "test --special-modes",
        recordedOptions(requested, false), where.placement, where.shard);
    scope (exit)
        if (const degradation = recorder.finish())
            warning(i"$(degradation)");
    const xdg = environment.get("XDG_CACHE_HOME", buildPath(environment.get("HOME", "/"), ".cache"));
    const cache = buildPath(xdg, "sparkles");
    auto g = runGraph(repoRoot, null, RunOptions(into: buildPath(cache, "runs",
        text("ci-test-special-", Clock.currTime.toUnixTime, "-", thisProcessID)), cache: cache, runnerCore: true,
        packages: packages, legs: [TestLeg(1, false, "special")], testArguments: arguments,
        failFast: failFast, echo: true));
    if (g.error.length)
        return failRun(g.error);
    foreach (task, wall; g.stats.wallTimes)
        if (task.startsWith("test:"))
        {
            const parts = task.split(":");
            const pkg = parts.length > 1 ? parts[1].replace("sparkles.", "") : task;
            const began = g.stats.startedAt.get(task, MonoTime.init);
            recorder.add(testTaskId(pkg, "special", true), g.stats.succeeded.get(task, false), began, began + wall);
        }
    return g.exitCode != 0 ? failRun("the extracted-test modes failed") : ranOk();
}

/// The `@slow` tests that the sources of each sub-package integrating the
/// runner mark (all of them, or those of `packageNames`), in package and then
/// file order. A slow test without a name, or two with one name in a package,
/// is a `problem`: its CI job could not select it.
private SlowTestJob[] collectSlowTests(string repoRoot, in string[] packageNames,
    ref string[] problems)
{
    import std.file : dirEntries, SpanMode;
    import std.path : extension, relativePath;

    SlowTestJob[] jobs;
    foreach (pkg; subPackageDirectories(repoRoot))
    {
        const name = pkg.baseName;
        if (packageNames.length && !packageNames.canFind(name))
            continue;
        const root = buildPath(repoRoot, pkg);
        const dubConfig = buildPath(root, "dub.sdl");
        if (!dubConfig.exists || !integratesTestRunner(dubConfig.readText))
            continue;

        string[] files;
        foreach (entry; dirEntries(root, SpanMode.depth))
            if (entry.isFile && entry.name.extension == ".d")
                files ~= entry.name;
        files.sort();
        foreach (file; files)
            foreach (test; slowTestsInSource(file.readText))
            {
                const where = i"$(file.relativePath(repoRoot)):$(test.line)".text;
                if (!test.name.length)
                    problems ~= where ~ ": a @slow test needs a @(\"name\") for its CI job to select it";
                else if (jobs.canFind(SlowTestJob(name, test.name)))
                    problems ~= where ~ ": a second @slow test named " ~ test.name ~ " in :" ~ name;
                else
                    jobs ~= SlowTestJob(name, test.name);
            }
    }
    return jobs;
}

/// `ci slow-tests list`: the `slow-tests` CI job's matrix, on stdout and in
/// `$GITHUB_OUTPUT`.
RunExpected!void runListSlowTestsMode()
{
    import std.stdio : File;

    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
    return failRun("Could not detect repository root");

    string[] problems;
    const jobs = collectSlowTests(repoRoot, null, problems);
    foreach (problem; problems)
        error(i"$(problem)");
    if (problems.length)
        return failRun(text(problems.length, " problem(s) collecting the slow tests"));
    if (jobs.length == 0)
    {
        // As for `ci test --special-modes all`: the job exists for these tests, so an
        // empty list means the scan (or the attribute) regressed.
        return failRun("No @slow test found — the slow-tests matrix would be empty");
    }

    const json = matrixJson(jobs);
    info(i"$(jobs.length) slow test(s)");
    stdout.writeln(json);
    const output = environment.get("GITHUB_OUTPUT", "");
    if (output.length)
        File(output, "a").write("matrix=" ~ json ~ "\n");
    return ranOk();
}

/// `ci test --slow`: run the `@slow` tests of each selected package, after
/// checking that its test binary agrees with the source scan about which
/// tests those are.
private RunExpected!void runSlowTestsMode(in string[] packageNames, in string[] testNames, bool failFast)
{
    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
    return failRun("Could not detect repository root");

    string[] problems;
    auto all = collectSlowTests(repoRoot, packageNames, problems);
    foreach (problem; problems)
        error(i"$(problem)");
    if (problems.length)
        return failRun(text(problems.length, " problem(s) collecting the slow tests"));
    foreach (name; testNames)
        if (!all.canFind!(job => job.test == name))
        return failRun(text(i"--tests: no @slow test is named $(name)"));
    if (all.length == 0)
    return failRun("No @slow test found in the selected packages");

    // M8: each package's slow tests are one leg of its test binary on the
    // build graph, selecting exactly the chosen names.
    import graph_driver : runGraph, RunOptions;
    import sparkles.build_graph.actions : TestLeg;
    import std.datetime.systime : Clock;
    import std.process : thisProcessID;

    string[] packages;
    string[][string] arguments;
    foreach (job; all)
    {
        if (packages.canFind(job.packageName))
            continue;
        auto marked = all.filter!(j => j.packageName == job.packageName).map!(j => j.test).array;
        const selected = testNames.length ? marked.filter!(name => testNames.canFind(name)).array : marked;
        if (!selected.length)
            continue;
        packages ~= job.packageName;
        arguments["sparkles:" ~ job.packageName] = ["--only-slow", "-i", exactNamesPattern(selected)];
    }
    info(i"the slow tests of $(packages.length) package(s): $(packages.join(", "))");
    const xdg = environment.get("XDG_CACHE_HOME", buildPath(environment.get("HOME", "/"), ".cache"));
    const cache = buildPath(xdg, "sparkles");
    const threads = cast(uint) parallelTestThreads(hwParallelism());
    auto g = runGraph(repoRoot, null, RunOptions(into: buildPath(cache, "runs",
        text("ci-test-slow-", Clock.currTime.toUnixTime, "-", thisProcessID)), cache: cache, runnerCore: true,
        packages: packages, legs: [TestLeg(threads, false, "slow")], testArguments: arguments,
        failFast: failFast, echo: true));
    if (g.error.length)
        return failRun(g.error);
    return g.exitCode != 0 ? failRun("the slow tests failed") : ranOk();
}

/**
`--shard K/N`: replace `subPackages` by the packages shard `K` of
`where.placement` runs, packed from the history (CIC14). The shard owns its
selection, so `--from` is refused beside it.
*/
private bool narrowToShard(string repoRoot, in string[] requested,
    in PlacementArgs where, ref string[] subPackages)
{
    if (where.placement.length == 0)
    {
        error(i"--shard needs --placement");
        return false;
    }
    if (requested.length)
    {
        error(i"--shard chooses the packages itself; drop --from");
        return false;
    }
    const kn = parseShard(where.shard);
    if (kn.hasError)
    {
        error(i"$(kn.error)");
        return false;
    }
    const chosen = chooseShard(repoRoot, subPackages, where.placement, kn.value[0], kn.value[1],
        where.historyTip, where.historyRemote);
    if (chosen.hasError)
    {
        error(i"$(chosen.error)");
        return false;
    }
    foreach (d; chosen.value.degradations)
        warning(i"$(d)");
    const tip = chosen.value.historyTip;
    const at = tip.length ? "refs/perf/data " ~ tip[0 .. 12] : "no history";
    info(i"shard $(where.shard) of $(where.placement): $(chosen.value.packages.length) of $(subPackages.length) package(s), packed from $(chosen.value.records) record(s) at $(at)");
    subPackages = chosen.value.packages.dup;
    return true;
}

/// `ci placements list`: the placements' shards as a CI matrix, with the tip
/// of `refs/perf/data` every shard reads.
RunExpected!void runListPlacements(string provider, string githubOutput, string historyRemote)
{
    import std.file : append;
    import std.path : buildPath;
    import std.stdio : stdout;
    import perf_history : canonicalRemote, historyCacheDir, historyTip, openHistory;

    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
    return failRun("Could not detect repository root");
    auto loaded = loadPlacements(repoRoot);
    if (loaded.hasError)
    return failRun(loaded.error);
    string tip;
    auto history = openHistory(historyCacheDir(historyRemote.length ? historyRemote : canonicalRemote),
        historyRemote.length ? historyRemote : canonicalRemote,
        buildPath(repoRoot, "nix", "perf-data-signers"));
    if (history.hasError)
        warning(i"$(history.error)");
    else
    {
        foreach (d; history.value.degradations)
            warning(i"$(d)");
        tip = historyTip(history.value, null, long.max);
    }
    const matrix = placementMatrix(loaded.value, provider, tip);
    stdout.writeln(matrix);
    if (githubOutput.length)
    {
        // One matrix per mode as well: a job cannot filter a matrix it is given.
        string lines = "matrix=" ~ matrix ~ "\ntip=" ~ tip ~ "\n";
        foreach (m; ["test", "sanitize", "extracted"])
            lines ~= "matrix-" ~ m ~ "=" ~ placementMatrix(loaded.value, provider, null, m) ~ "\n";
        append(githubOutput, lines);
    }
    return ranOk();
}
