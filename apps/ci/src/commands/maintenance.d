/// `ci commits`, `ci cache`: building each commit of a branch, and seeding,
/// costing and collecting the caches.
module commands.maintenance;

import commands.files : detectRepoRoot;
import commands.output :
    RunMonitor, displayTestRunSummary, flushStdout, resultFooterRight, resultVerdict,
    streamResultBox, uiWidth;
import commands.toolchain : dubBuildCommand, findWasiCompiler, withLdcDflags;
import core.time : Duration, msecs;
import dub_deps : subPackageDirectories;
import sparkles.base.expected : Expected, ok;
import sparkles.base.logger : error, info, LogDelta, warning;
import sparkles.base.styled_template : styledText;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;
import sparkles.core_cli.process_utils : ChildStdin, executeMonitoredLines, ResourceUsage;
import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;
import std.algorithm : any, canFind, filter, map, startsWith;
import std.array : array, join;
import std.conv : text, to;
import std.file : exists, mkdirRecurse, remove, tempDir, write;
import std.path : baseName, buildPath;
import std.process : environment, execute;
import std.stdio : writeln;
import std.string : lineSplitter, strip;

/// Seed DUB's source cache from the Nix bundle, for the commands that run dub.
void seedDubHome()
{
    import dub_cache : seedBundledDubHome, userDubHome;

    seedBundledDubHome(userDubHome());
}

/// `ci cache seed-dub`.
RunExpected!void runSeedDubCache()
{
    import dub_cache : seedBundledDubHome, userDubHome;

    if (!environment.get("SPARKLES_DUB_SOURCES", "").length)
        return failRun("No source bundle configured; use nix run .#ci -- cache seed-dub");
    const imported = seedBundledDubHome(userDubHome());
    info(i"Imported $(imported) dependency version(s) into $(userDubHome())");
    return ranOk();
}

/++
`ci commits build-each`: `dub build` the chosen packages at every commit from
`base` (exclusive) to `HEAD`, in one detached scratch worktree walked oldest
first. See $(MREF each_commit) for why.
+/
RunExpected!void runBuildEachCommitMode(string base, string[] requested, bool failFast)
{
    import std.conv : to;
    import std.file : rmdirRecurse, tempDir;
    import std.process : thisProcessID;
    import sparkles.build_primitives.git_env : runGit;
    import each_commit : CommitFailure, defaultEachCommitPackages, failureReport,
        parseCommitRange, selectPackages, targetBuildArgs, wasiPackages;
    import std.process : thisProcessID;

    // The build graph's store, shared by every commit's builds.
    const graphCache = buildPath(environment.get("XDG_CACHE_HOME",
        buildPath(environment.get("HOME", "/"), ".cache")), "sparkles");

    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
    return failRun("Could not detect repository root");

    string[] unknown;
    const pkgs = selectPackages(requested.length ? requested
        : defaultEachCommitPackages.dup, subPackageDirectories(repoRoot), unknown);
    if (unknown.length)
    return failRun(text(i"--from: no sub-package named $(unknown.join(", "))"));
    string wasiCompiler;
    if (!findWasiCompiler(pkgs, wasiCompiler))
        return failRun("no WebAssembly-capable compiler for a package that needs one");

    if (base.length == 0)
    {
        const mb = runGit(["-C", repoRoot, "merge-base", "HEAD", "origin/main"]);
        if (mb.status != 0)
        return failRun(text(i"--base not given and HEAD has no merge-base with origin/main: $(mb.output.strip)"));
        base = mb.output.strip;
    }
    const log = runGit(["-C", repoRoot, "log", "--reverse", "--format=%h %s",
        base ~ "..HEAD"]);
    if (log.status != 0)
    return failRun(text(i"Could not list $(base)..HEAD: $(log.output.strip)"));
    const commits = parseCommitRange(log.output);
    if (commits.length == 0)
    {
        info(i"no commits in $(base)..HEAD: nothing to build");
        return ranOk();
    }

    // One worktree for the whole walk, so each build is incremental on the
    // last; detached, so no branch is created or moved.
    const wt = buildPath(tempDir, "ci-each-commit-" ~ thisProcessID.to!string);
    const add = runGit(["-C", repoRoot, "worktree", "add", "--detach", "--quiet",
        wt, commits[0].sha]);
    if (add.status != 0)
    return failRun(text(i"Could not create the scratch worktree: $(add.output.strip)"));
    scope (exit)
    {
        runGit(["-C", repoRoot, "worktree", "remove", "--force", wt]);
        if (wt.exists)
            rmdirRecurse(wt);
    }

    i"Building $(pkgs.length) package(s) at $(commits.length) commit(s) after $(base[0 .. base.length < 9 ? $ : 9])".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");
    flushStdout();

    auto monitor = RunMonitor.start();
    void onSample(in ResourceUsage) @safe
    {
        monitor.sample();
    }

    CommitFailure[] failures;
    string[] failedLabels;
    size_t processed;
    const total = commits.length * pkgs.length;
    walk: foreach (cIdx, commit; commits)
    {
        // What the last commit's builds left untracked goes first: a file dub
        // writes for a package (its `dub.selections.json`) that a later
        // commit tracks otherwise stops the checkout. Ignored build output
        // stays, so each build is still incremental.
        runGit(["-C", wt, "clean", "-fdq"]);
        const co = runGit(["-C", wt, "checkout", "--quiet", "--detach", commit.sha]);
        if (co.status != 0)
        return failRun(text(i"Could not check out $(commit.sha): $(co.output.strip)"));
        // The packages this commit has; a package a later commit adds is not
        // here yet, and has nothing to build.
        string[] present;
        foreach (pkg; pkgs)
            if (buildPath(wt, pkg, "dub.sdl").exists || buildPath(wt, pkg, "dub.json").exists)
                present ~= pkg;
            else
            {
                writeln(styledText(i"{dim $(commit.sha) $(pkg.baseName): not in this commit}"));
                ++processed;
            }
        // The build graph builds what it can model against the shared store
        // (build graph E3's follow-up): a commit compiles only the actions
        // whose keys it changes. The WebAssembly cross-builds, and a package
        // planning refuses, build with dub, and the report names them.
        string[] onGraph, withDub;
        foreach (pkg; present)
            (wasiPackages.canFind(pkg.baseName) ? withDub : onGraph) ~= pkg;
        while (onGraph.length)
        {
            import graph_driver : logicalProcessors, runGraph, RunOptions;

            const header = styledText(i"{dim $(commit.sha)} {cyan $(onGraph.map!(p => p.baseName).join(", "))} {dim › the build graph › $(commit.subject)}");
            writeln(header);
            auto g = runGraph(wt, null, RunOptions(into: buildPath(graphCache, "runs",
                text("build-each-", commit.sha, "-", thisProcessID)), cache: graphCache,
                applications: onGraph.map!(p => p.baseName).array, buildOnly: true, failFast: failFast,
                jobs: logicalProcessors));
            if (g.error.length)
            {
                // A package the graph cannot plan builds with dub instead.
                const refused = onGraph.filter!(p => g.error.startsWith(p.baseName ~ ":")).array;
                if (!refused.length)
                    return failRun(text(i"$(commit.sha): the build graph cannot plan: $(g.error)"));
                warning(i"$(commit.sha): the build graph cannot model $(refused[0].baseName) ($(g.error)); building it with dub");
                withDub ~= refused[0];
                onGraph = onGraph.filter!(p => p != refused[0]).array;
                continue;
            }
            processed += onGraph.length;
            if (g.exitCode != 0)
            {
                foreach (line; g.log.lineSplitter.filter!(l => l.canFind(": failed")))
                    writeln("  ", line);
                foreach (pkg; onGraph)
                    if (g.log.lineSplitter.any!(l => l.canFind(": failed") && l.canFind("sparkles." ~ pkg.baseName ~ ":")))
                    {
                        failures ~= CommitFailure(commit, pkg.baseName);
                        failedLabels ~= commit.sha ~ " :" ~ pkg.baseName;
                    }
                if (!failures.length || failures[$ - 1].commit.sha != commit.sha)
                {
                    failures ~= CommitFailure(commit, onGraph.map!(p => p.baseName).join(","));
                    failedLabels ~= commit.sha ~ " :" ~ onGraph.map!(p => p.baseName).join(",");
                }
                if (failFast)
                    break walk;
            }
            else
                info(i"✓ $(commit.sha): $(onGraph.length) package(s) built by the build graph: $(g.stats.summary)");
            break;
        }
        foreach (pi, pkg; withDub)
        {
            const pkgName = pkg.baseName;
            const progress = i"[$(processed + 1)/$(total)]".text;
            const header = styledText(i"{dim $(progress)} {yellow $(commit.sha)} {cyan $(pkgName)} {dim › dub (not on the build graph) › $(commit.subject)}");
            mkdirRecurse(buildPath(wt, pkg, "build"));
            auto lines = executeMonitoredLines(
                dubBuildCommand(wt, pkg, pkgName, targetBuildArgs(pkgName, wasiCompiler)),
                250.msecs, &onSample,
                ChildStdin.empty, Duration.zero, withLdcDflags(null));
            streamResultBox(header, lines,
                () => resultVerdict(lines.result.status == 0),
                (LogDelta d) => resultFooterRight(lines.result.usage, d));
            monitor.sample();
            ++processed;
            writeln();

            if (lines.result.status != 0)
            {
                failures ~= CommitFailure(commit, pkgName);
                failedLabels ~= commit.sha ~ " :" ~ pkgName;
                if (failFast)
                    break walk;
            }
        }
    }

    displayTestRunSummary(monitor.finish(processed, total, failedLabels));
    const report = failureReport(failures, commits.length, pkgs.length);
    if (failures.length)
    return failRun(report);
    info(i"✓ $(report)");
    return ranOk();
}

/// `ci cache gc-r2`: garbage-collect the R2 binary cache (see `r2_gc`).
RunExpected!void runGcR2Command(int keepCommits, int graceDays, bool dryRun)
{
    import core.time : days;
    import std.algorithm.iteration : filter, map, sum;
    import std.datetime.systime : Clock;
    import std.format : format;
    import std.datetime.timezone : UTC;
    import std.parallelism : TaskPool;
    import std.process : execute;
    import std.stdio : writefln;
    import std.string : lineSplitter, strip;

    import sparkles.base.expected : Expected, err, ok;
    import sparkles.base.logger : error, info, warning;

    import r2_gc : Bucket, deleteObject, getObject, keptRoots, listAll, markLive, plan,
        storeHash, youngNarinfos;

    static string gib(ulong bytes) => format("%.2f GiB", bytes / 1024.0 / 1024 / 1024);

    const bucket = Bucket.fromEnvironment();
    if (bucket.hasError)
    {
        string msg = bucket.error;
        return failRun(text(i"ci cache gc-r2: $(msg)"));
    }

    const log = execute(["git", "log", "--first-parent", "--format=%T",
        "-n", keepCommits.to!string, "HEAD"]);
    if (log.status != 0)
    {
        string out_ = log.output;
        return failRun(text(i"ci cache gc-r2: git log failed: $(out_)"));
    }
    const string[] keepTrees = log.output.lineSplitter.map!(l => l.strip.idup).filter!(l => l.length).array;

    auto pool = new TaskPool(16);
    scope (exit) pool.finish(blocking: true);

    // `parallel` foreach, not `amap`: a local lambda given to a TaskPool member
    // needs a dual context, which LDC does not support.
    Expected!(string, string)[] getAll(string[] keys)
    {
        // Plain arrays: an `Expected` cannot be default-constructed.
        auto bodies = new string[keys.length], failures = new string[keys.length];
        foreach (i, ref body_; pool.parallel(bodies, 1))
        {
            auto got = getObject(bucket.value, keys[i]);
            if (got.hasError)
                failures[i] = got.error;
            else
                body_ = got.value;
        }
        Expected!(string, string)[] results;
        foreach (i; 0 .. keys.length)
            results ~= failures[i].length ? err!string(failures[i]) : ok(bodies[i]);
        return results;
    }

    auto listed = listAll(bucket.value);
    if (listed.hasError)
    {
        string msg = listed.error;
        return failRun(text(i"ci cache gc-r2: $(msg)"));
    }
    auto objects = listed.value;
    const now = Clock.currTime(UTC());
    const grace = graceDays.days;
    const totalBytes = objects.map!(o => o.size).sum(0UL);
    writefln("R2: %d objects, %s, in %s.", objects.length, gib(totalBytes), bucket.value.name);

    auto roots = keptRoots(objects, keepTrees, now, grace);
    if (roots.length == 0)
    return failRun(text(i"ci cache gc-r2: no root survives (no gc-roots/ object for the last $(keepCommits) trees, none younger than $(graceDays) days); refusing to collect"));

    string[] seeds;
    auto rootTexts = getAll(roots.map!(o => o.key).array);
    foreach (i, got; rootTexts)
    {
        if (got.hasError)
        {
            string msg = got.error;
            return failRun(text(i"ci cache gc-r2: reading $(roots[i].key): $(msg)"));
        }
        foreach (line; got.value.lineSplitter)
        {
            const hash = storeHash(line.strip.idup);
            if (hash.hasError)
            {
                string msg = hash.error;
                warning(i"ci cache gc-r2: $(roots[i].key): $(msg)");
                continue;
            }
            seeds ~= hash.value;
        }
    }
    const young = youngNarinfos(objects, now, grace);
    writefln("R2: %d roots kept (%d trees of HEAD's last %d commits), %d store paths in them, %d narinfos younger than %d days.",
        roots.length, keepTrees.length, keepCommits, seeds.length, young.length, graceDays);
    seeds ~= young;

    auto live = markLive!(hashes => getAll(hashes.map!(h => h ~ ".narinfo").array))(seeds);
    if (live.hasError)
    {
        string msg = live.error;
        return failRun(text(i"ci cache gc-r2: $(msg); deleting nothing"));
    }
    if (live.value.missing.length)
        warning(i"ci cache gc-r2: $(live.value.missing.length) live store paths have no narinfo in the bucket (they are served elsewhere, or were never pushed)");

    const p = plan(objects, live.value, keepTrees, now, grace);
    writefln("R2: %d live store paths. Keeping %d objects (%s); %s %d narinfos, %d NARs and %d roots (%s).",
        live.value.paths.length, p.keptObjects, gib(p.keptBytes), dryRun ? "would delete" : "deleting",
        p.deleteNarinfos.length, p.deleteNars.length, p.deleteRoots.length, gib(p.freedBytes));
    if (dryRun)
        return ranOk();

    // Narinfos before the NARs they name: a client then sees a missing path,
    // never a narinfo whose NAR is gone. Roots last.
    size_t failures;
    foreach (batch; [p.deleteNarinfos, p.deleteNars, p.deleteRoots])
    {
        auto messages = new string[batch.length];
        foreach (i, ref message; pool.parallel(messages, 1))
        {
            auto res = deleteObject(bucket.value, batch[i]);
            if (res.hasError)
                message = res.error;
        }
        foreach (msg; messages)
            if (msg.length)
            {
                warning(i"ci cache gc-r2: $(msg)");
                failures++;
            }
    }
    if (failures)
    return failRun(text(i"ci cache gc-r2: $(failures) deletions failed; the next collection retries them"));
    info(i"R2: collected $(gib(p.freedBytes)).");
    return ranOk();
}

/// `ci cache pin-costs FILE`: the toolchain build plan's costs, from the history.
RunExpected!void runWritePinCosts(string path, string historyRemote)
{
    import std.file : write;
    import placements_run : pinCostsJson;

    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
    return failRun("Could not detect repository root");
    string[] degradations;
    const json = pinCostsJson(repoRoot, historyRemote, degradations);
    foreach (d; degradations)
        warning(i"$(d)");
    if (json.hasError)
    return failRun(json.error);
    write(path, json.value ~ "\n");
    info(i"wrote $(path)");
    return ranOk();
}
