/// `ci commits`, `ci cache`: building each commit of a branch, and seeding,
/// costing and collecting the caches.
module commands.maintenance;

import cache_home : sparklesCache;
import commands.files : detectRepoRoot;
import commands.output : flushStdout, uiWidth;
import commands.toolchain : dubBuildCommand, withLdcDflags;
import dub_deps : subPackageDirectories;
import sparkles.base.expected : Expected, ok;
import sparkles.base.logger : error, info, warning;
import sparkles.base.styled_template : styledText;
import sparkles.build_graph.platforms : HostToolchain;
import sparkles.build_primitives.task.action : EnvEntry;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;
import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;
import std.algorithm : any, canFind, countUntil, filter, map, sort, startsWith;
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
`ci commits build-each`: build the chosen packages at every commit from
`base` (exclusive) to `HEAD`, as one run of the build graph (ci task-DAG
CIC21). Each commit is checked out in a scratch worktree of its own and
planned there, each package for every host the toolchain table lists it for
(the WebAssembly modules' previews; build-graph BGH2), the rest for the build
platform. The plans run together against the shared store, an action a
commit shares with the one before it waiting for that one's result. A
package planning refuses builds with dub in one more worktree, walked oldest
first so each build is incremental on the last, as tasks of the same run.
See $(MREF each_commit) for why.
+/
RunExpected!void runBuildEachCommitMode(string base, string[] requested, bool failFast)
{
    import std.file : rmdirRecurse, tempDir;
    import std.process : thisProcessID;
    import graph_driver : PreparedRun, RunOptions, prepareGraph, toolchainTable;
    import sparkles.build_graph.actions : ActionGraph, ActionKind;
    import sparkles.build_graph.execute : RunLayout, RunPart, RunReporting, RunStats, runActionsAcross,
        storeOperation;
    import sparkles.build_primitives.git_env : runGit;
    import sparkles.build_primitives.task.action : EnvEntry, InProcessAction, ProcessAction, TaskAction;
    import sparkles.build_primitives.task.executor : TaskContext;
    import sparkles.build_primitives.task.model : EdgeCondition, EdgeReason, FailureReason, Failed, OutcomeKind,
        OutputStream, PresentationKey, ResourceClaim, Succeeded, TaskEdge, TaskId, TaskKind, TaskNode, TaskOutcome,
        taskId;
    import sparkles.build_primitives.task.process : InProcessHandler;
    import sparkles.ci_provider : CiLog, systemEnvironment;
    import sparkles.event_horizon.sched : Sched;
    import each_commit : BuildUnit, CommitFailure, defaultEachCommitPackages, failureReport, parseCommitRange, unitBuilt,
        refusedUnit, reuseEdges, selectPackages, unitsOf;

    // The build graph's store, shared by every commit's builds.
    const graphCache = sparklesCache();

    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
        return failRun("Could not detect repository root");
    const table = toolchainTable();
    if (table.hasError)
        return failRun(table.error);

    string[] unknown;
    const pkgs = selectPackages(requested.length ? requested
        : defaultEachCommitPackages.dup, subPackageDirectories(repoRoot), unknown);
    if (unknown.length)
        return failRun(text(i"--packages: no sub-package named $(unknown.join(", "))"));
    const units = unitsOf(pkgs, table.value.packages);

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

    // The worktrees, one per commit and one for dub's walk, detached, so no
    // branch is created or moved; and the run's directories in the store.
    const pid = thisProcessID.to!string;
    const scratch = buildPath(tempDir, "ci-each-commit-" ~ pid);
    const runs = buildPath(graphCache, "runs", "build-each-" ~ pid);
    string[] worktrees;
    scope (exit)
    {
        foreach (wt; worktrees)
            runGit(["-C", repoRoot, "worktree", "remove", "--force", wt]);
        if (scratch.exists)
            rmdirRecurse(scratch);
    }
    string addWorktree(string name, string sha)
    {
        const wt = buildPath(scratch, name);
        const add = runGit(["-C", repoRoot, "worktree", "add", "--detach", "--quiet", wt, sha]);
        if (add.status != 0)
        {
            error(i"Could not create the scratch worktree $(wt): $(add.output.strip)");
            return null;
        }
        worktrees ~= wt;
        return wt;
    }
    // A package a later commit adds is not in an earlier one, and has
    // nothing to build there.
    bool hasPackage(string sha, string pkg)
        => [pkg ~ "/dub.sdl", pkg ~ "/dub.json"].any!(recipe =>
            runGit(["-C", repoRoot, "cat-file", "-e", sha ~ ":" ~ recipe]).status == 0);

    i"Building $(units.length) package build(s) at $(commits.length) commit(s) after $(base[0 .. base.length < 9 ? $ : 9])".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");
    flushStdout();

    auto reporting = RunReporting(timings: true, ci: CiLog.detect(&systemEnvironment));
    {
        import sparkles.base.term_caps : isTerminal;
        import sparkles.ci_provider : CiProvider;
        import task.reporter_live : LiveOptions, liveViewWanted, stdoutLiveView;

        if (liveViewWanted(false, false, isTerminal(), reporting.ci.provider != CiProvider.none))
            reporting.live = stdoutLiveView(LiveOptions());
    }

    // Each commit planned in its own worktree, each package for its hosts.
    // A unit planning refuses joins dub's walk.
    auto prepared = new PreparedRun[commits.length]; // the parts point into it
    auto onGraph = new BuildUnit[][commits.length];
    auto withDub = new BuildUnit[][commits.length];
    RunPart[] parts;
    size_t[] commitOf; // by part
    foreach (k, commit; commits)
    {
        foreach (unit; units)
            if (!hasPackage(commit.sha, unit.path))
                writeln(styledText(i"{dim $(commit.sha) $(unit.label): not in this commit}"));
            else
                onGraph[k] ~= unit;
        if (!onGraph[k].length)
            continue;
        const wt = addWorktree(commit.sha, commit.sha);
        if (wt is null)
            return failRun(text(i"$(commit.sha): no worktree to build it in"));
        // The commit's units planned as one graph.
        PreparedRun planUnits(const BuildUnit[] some)
        {
            string[] applications;
            string[][string] hostApplications;
            foreach (unit; some)
                if (unit.host.length)
                    hostApplications[unit.host] ~= unit.name;
                else
                    applications ~= unit.name;
            return prepareGraph(wt, null, RunOptions(into: buildPath(runs, commit.sha), cache: graphCache,
                applications: applications, hostApplications: hostApplications, buildOnly: true));
        }
        while (onGraph[k].length)
        {
            prepared[k] = planUnits(onGraph[k]);
            const why = prepared[k].run.error;
            if (!why.length)
                break;
            const refused = refusedUnit(onGraph[k], why);
            if (refused >= onGraph[k].length)
            {
                // A refusal that names no unit (a variant's, or a lint's): each unit
                // planned alone tells which refuse. One every unit meets alone is
                // the commit's, not a unit's, and fails the run.
                BuildUnit[] fine;
                foreach (unit; onGraph[k])
                {
                    const alone = planUnits([unit]).run.error;
                    if (!alone.length)
                        fine ~= unit;
                    else
                    {
                        warning(i"$(commit.sha): the build graph cannot model $(unit.label) ($(alone)); building it with dub");
                        withDub[k] ~= unit;
                    }
                }
                if (!fine.length && onGraph[k].length > 1 || fine.length == onGraph[k].length)
                    return failRun(text(i"$(commit.sha): the build graph cannot plan: $(why)"));
                onGraph[k] = fine;
                continue;
            }
            warning(i"$(commit.sha): the build graph cannot model $(onGraph[k][refused].label) ($(why)); building it with dub");
            withDub[k] ~= onGraph[k][refused];
            onGraph[k] = onGraph[k][0 .. refused] ~ onGraph[k][refused + 1 .. $];
        }
        if (!onGraph[k].length)
            continue;
        parts ~= RunPart(prepared[k].nodes, &prepared[k].run.plan.graph, prepared[k].layout, commit.sha);
        commitOf ~= k;
    }

    info(i"planned $(parts.length) commit(s) on the build graph");
    // An action a commit shares with the one before it waits for that one,
    // and reuses its result.
    TaskEdge[] across;
    foreach (i; 1 .. parts.length)
    {
        const diff = runGit(["-C", repoRoot, "diff", "--name-only", parts[i - 1].idSuffix, parts[i].idSuffix]);
        const changed = diff.status == 0 ? diff.output.lineSplitter.map!(l => l.idup).array : null;
        if (diff.status != 0)
            warning(i"$(parts[i].idSuffix): cannot list what changed since $(parts[i - 1].idSuffix), so nothing waits to be reused");
        across ~= reuseEdges(*parts[i - 1].graph, parts[i - 1].idSuffix, *parts[i].graph, parts[i].idSuffix,
            changed);
    }

    // dub's walk: per commit, a checkout of it, then each refused unit's
    // build, one at a time, as they share the worktree's build directories.
    // A unit for another host builds with its toolchain's compiler, as dub's
    // `--arch` takes it.
    enum dubSuffix = "dub";
    ActionGraph dubEdges; // edges only: the walk's tasks are keyless
    TaskNode[] dubNodes;
    BuildUnit[string] dubUnitOf; // by a dub build's id
    string[string] dubCommitOf;  // ditto
    InProcessHandler[string] handlers;
    if (withDub.any!(w => w.length > 0))
    {
        const dubWt = addWorktree(dubSuffix, commits[0].sha);
        if (dubWt is null)
            return failRun("no worktree for the packages dub builds");
        EnvEntry[] dubEnv;
        foreach (name, value; withLdcDflags(null))
            dubEnv ~= EnvEntry(name, value);
        TaskId last;
        foreach (k, commit; commits)
        {
            if (!withDub[k].length)
                continue;
            const checkout = taskId("checkout", commit.sha).value;
            string[] dirs;
            foreach (unit; withDub[k])
                dirs ~= unit.path;
            dubNodes ~= TaskNode(id: checkout, kind: TaskKind.build, label: "checkout " ~ commit.sha,
                order: PresentationKey(1, checkout.text, 0, 0), resources: ResourceClaim(jobsWeight: 1),
                action: TaskAction(InProcessAction("build-each:checkout", [dubWt, commit.sha] ~ dirs)));
            if (!last.empty)
                dubEdges.edges ~= TaskEdge(last, checkout, EdgeCondition.onCompletion, EdgeReason.planning);
            last = checkout;
            foreach (unit; withDub[k])
            {
                const id = taskId("dub", unit.name, unit.host.length ? unit.host : "build", commit.sha).value;
                string[] cross;
                EnvEntry[] env = dubEnv;
                if (unit.host.length)
                {
                    const entry = table.value.host(unit.host);
                    if (entry is null)
                        return failRun(text(i"$(unit.label): the toolchain table has no host $(unit.host)"));
                    cross = ["--arch=" ~ (entry.platform.triple.length ? entry.platform.triple : unit.host),
                        "--compiler=" ~ entry.ldc];
                    env = hostDubEnvironment(*entry);
                }
                dubNodes ~= TaskNode(id: id, kind: TaskKind.build, label: "dub " ~ unit.label ~ " " ~ commit.sha,
                    order: PresentationKey(1, id.text, 0, 0), resources: ResourceClaim(jobsWeight: 2),
                    action: TaskAction(ProcessAction(argv: dubBuildCommand(dubWt, unit.path, unit.name, cross),
                        envDelta: env, cwd: dubWt)));
                dubEdges.edges ~= TaskEdge(checkout, id, EdgeCondition.onSuccess, EdgeReason.planning);
                if (last != checkout)
                    dubEdges.edges ~= TaskEdge(last, id, EdgeCondition.onCompletion, EdgeReason.planning);
                dubUnitOf[id.text] = unit;
                dubCommitOf[id.text] = commit.sha;
                last = id;
            }
        }
        const into = buildPath(runs, dubSuffix);
        mkdirRecurse(into);
        parts ~= RunPart(dubNodes, &dubEdges, RunLayout(dubWt, into, graphCache), dubSuffix);
        handlers["build-each:checkout"] = (ref TaskContext!Sched ctx, const ref InProcessAction a) {
            // What the last commit's builds left untracked goes first: a file
            // dub writes for a package (its `dub.selections.json`) that a
            // later commit tracks otherwise stops the checkout. Ignored build
            // output stays, so each build is still incremental.
            const wt = a.arguments[0];
            runGit(["-C", wt, "clean", "-fdq"]);
            const co = runGit(["-C", wt, "checkout", "--quiet", "--detach", a.arguments[1]]);
            if (co.status != 0)
            {
                ctx.output(OutputStream.stderr, co.output.strip);
                return TaskOutcome(Failed(FailureReason.exitStatus, co.status));
            }
            foreach (pkg; a.arguments[2 .. $])
                mkdirRecurse(buildPath(wt, pkg, "build"));
            return TaskOutcome(Succeeded());
        };
    }
    if (!parts.length)
    {
        info(i"no commit of $(base)..HEAD has any of the packages: nothing to build");
        return ranOk();
    }

    static struct Echo
    {
        void put(T)(T s)
        {
            import std.stdio : stdout;

            stdout.write(s);
        }
    }
    Echo echo;
    auto stats = new RunStats[parts.length];
    // CIC23: predictions, the budget, the gate and limits, as `ci test` has.
    version (linux)
    {
        import run_resources : RunWatch, loadPeaks, predict, resourcesFor, savePeaks;
        import run_scope : actionsAccounted, limitingCgroup;

        const peaks = loadPeaks(graphCache);
        foreach (ref part; parts)
            predict(part.nodes, peaks);
        const bounding = limitingCgroup();
        auto watch = new RunWatch(graphCache, graphCache, runs, bounding);
        reporting.resources = resourcesFor(watch, bounding, actionsAccounted);
        info(i"disk at the start: $(watch.report())");
    }
    import sparkles.base.hw_caps : hwParallelism;

    // TDM10: the host's parallelism, its quotas and load folded in.
    const result = runActionsAcross(parts, across, echo, hwParallelism(), stats, failFast, handlers, reporting);
    version (linux)
    {
        import sparkles.build_primitives.task.model : CancelCause;

        watch.finish();
        savePeaks(graphCache, stats);
        if (result.cancelled && result.cancelCause == CancelCause.resources)
            error(i"the run stopped: $(result.cancelMessage)");
        info(i"disk at the end: $(watch.report())");
    }
    info(i"the run ended (exit $(result.exitCode)); evicting the store down to its bound");
    {
        import std.array : appender;

        auto discard = appender!string;
        cast(void) storeOperation(graphCache, "evict", discard); // BGS5, off the run's path
    }
    writeln();

    // A unit built at a commit when every link of its application for its
    // host succeeded, or its dub build did.
    CommitFailure[] failures;
    foreach (i, ref part; parts)
    {
        if (part.idSuffix == dubSuffix)
        {
            foreach (id, unit; dubUnitOf)
                if (stats[i].outcomes.get(id, OutcomeKind.skipped) != OutcomeKind.succeeded)
                    failures ~= CommitFailure(commits[commits.countUntil!(c => c.sha == dubCommitOf[id])], unit.label);
            continue;
        }
        const k = commitOf[i];
        const plan = &prepared[k].run.plan.plan;
        foreach (unit; onGraph[k])
        {
            string configOf(size_t variant) => variant < plan.variants.length ? plan.variants[variant].platform.config : null;
            if (!unitBuilt(*part.graph, &configOf, stats[i].outcomes, unit.name, unit.host.length ? unit.host : table.value.build))
                failures ~= CommitFailure(commits[k], unit.label);
        }
        info(i"$(commits[k].sha): $(stats[i].summary)");
    }
    failures.sort!((a, b) => commits.countUntil(a.commit) < commits.countUntil(b.commit));
    const report = failureReport(failures, commits.length, units.length);
    if (failures.length || result.exitCode != 0)
        return failRun(failures.length ? report : text("the build graph's run failed (exit ", result.exitCode, ")"));
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

    // Sixteen fetches at once, each blocking on its request, on threads of
    // their own (ci task-DAG M11: blocking HTTP, until a native client).
    Expected!(string, string)[] getAll(string[] keys)
    {
        // Plain arrays: an `Expected` cannot be default-constructed.
        auto bodies = new string[keys.length], failures = new string[keys.length];
        fanOut(keys.length, (size_t i) {
            auto got = getObject(bucket.value, keys[i]);
            if (got.hasError)
                failures[i] = got.error;
            else
                bodies[i] = got.value;
        });
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
        fanOut(batch.length, (size_t i) {
            auto res = deleteObject(bucket.value, batch[i]);
            if (res.hasError)
                messages[i] = res.error;
        });
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

/// Runs `work(0 .. n)` on up to sixteen threads, each request blocking on
/// its own (ci task-DAG M11: blocking HTTP, until a native client).
private void fanOut(size_t n, scope void delegate(size_t) work)
{
    import core.atomic : atomicOp;
    import core.thread : Thread;

    shared size_t next;
    void drain()
    {
        for (;;)
        {
            const i = atomicOp!"+="(next, 1) - 1;
            if (i >= n)
                return;
            work(i);
        }
    }
    Thread[] threads;
    foreach (_; 0 .. n < 16 ? n : 16)
        threads ~= new Thread(&drain).start();
    foreach (t; threads)
        t.join();
}

/++
The environment of a dub build for another host (`ci commits build-each`'s
fallback): the host's variables, its `pkg-config` directory alone, and LDC's
`-linkonce-templates` as its `DFLAGS`, never the build platform's. Nix's
`pkg-config` wrapper rebuilds `PKG_CONFIG_PATH` from its role variables, so
each of those this process has is set empty (build-graph BGH6).
+/
private EnvEntry[] hostDubEnvironment(const ref HostToolchain entry)
{
    import std.algorithm.searching : startsWith;
    import std.process : environment;

    EnvEntry[] env = [EnvEntry("DFLAGS", "-linkonce-templates")];
    foreach (name, value; entry.environment)
        env ~= EnvEntry(name, value);
    if (entry.pkgConfigLibdir.length)
    {
        env ~= [EnvEntry("PKG_CONFIG_LIBDIR", entry.pkgConfigLibdir), EnvEntry("PKG_CONFIG_PATH", "")];
        foreach (name, _; environment.toAA)
            if (name.startsWith("PKG_CONFIG_PATH_") || name.startsWith("NIX_PKG_CONFIG_WRAPPER_TARGET_"))
                env ~= EnvEntry(name, "");
    }
    return env;
}
