/**
`ci pipeline` (ci task-DAG §1.3, M12): the work every CI job does, on the
build graph's shared store.

$(UL
    $(LI $(B The build graph's run:) every selected package's test legs (the
        placement's, with its coverage), the extracted modes of the packages
        that use them as legs of their own, the repository's checks, and
        `ci check commit-scope` over the branch's commits, as one graph.)
    $(LI $(B Stages after it:) the Markdown and standalone examples, the
        sanitized tests and the `@slow` tests, each a graph of its own (the
        sanitizer's flags change every compile), and the determinism check
        over the first run's actions (CIC13).)
    $(LI $(B The report:) each job `ci.yml` runs, and what the pipeline did
        for it: ran it, or skipped it, naming why (another host system, the
        Nix backend, a GPU).)
)

With `--placement NAME`, only that placement's mode runs (its tests, its
sanitized tests, or its extracted modes), and every other task is
`Skipped(placement)` in the report.
*/
module pipeline;

import core.time : Duration;

import std.algorithm : any, canFind, filter, map, sort, startsWith;
import std.array : array, join, split;
import std.conv : text;
import std.path : baseName, buildPath;
import std.stdio : writeln;
import std.sumtype : match;

import sparkles.base.logger : info, warning;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;

/// What `ci pipeline` was asked.
struct PipelineRequest
{
    string placement;   /// empty: everything this host runs
    string shard;       /// with `placement`: `K/N`
    string historyTip;  ///
    string historyRemote; ///
    string[] from;      /// package selectors
    bool failFast;      ///
    uint jobs;          /// 0: the host's
    bool interlaced;    ///
    uint determinismSample = 4; ///
}

/// One job of `ci.yml`, and what the pipeline did for it.
struct JobVerdict
{
    string job;
    string verdict; /// `passed`, `failed`, or `skipped (<why>)`
}

/// Runs the pipeline `r` asks for; fails when any job it ran failed.
RunExpected!void runPipeline(in PipelineRequest r)
{
    import cli : ExampleAction, FileSelection, Sanitizer, SpecialModes, TestCommand;
    import commands.check : runCheckAdHocSdl, runCheckCommitScope, runCheckCredits, runCheckDocsSidebar,
        runCheckGlossary, runCheckOpaqueRecipes, runCheckPinCache, runCheckSpecEvidence, runCheckVcsUrlsCommand,
        runReferenceLinksCommand;
    import commands.examples : runMarkdownExamplesCommand, runStandaloneExamplesCommand;
    import commands.files : detectRepoRoot;
    import commands.test_ : runTestCommand, specialModeArguments;
    import dub_deps : subPackageDirectories;
    import graph_driver : LastRun, logicalProcessors, Planned, recordLastRun, rerunCheck, runGraph, RunOptions;
    import placements_run : loadPlacements;
    import sparkles.build_graph.actions : Action, ActionKind, TestLeg;
    import sparkles.build_graph.execute : RunReporting;
    import sparkles.build_primitives.task.action : InProcessAction, ProcessAction, TaskAction;
    import sparkles.build_primitives.task.executor : TaskContext;
    import sparkles.build_primitives.task.model : EdgeCondition, EdgeReason, Failed, FailureReason, Skipped,
        SkipReason, Succeeded, TaskEdge, TaskOutcome, taskId;
    import sparkles.ci_provider : CiLog, systemEnvironment;
    import sparkles.event_horizon.sched : Sched;
    import std.datetime.systime : Clock;
    import std.process : environment, thisProcessID;

    const root = detectRepoRoot();
    if (root is null)
        return failRun("ci pipeline: not inside the repository");
    const xdg = environment.get("XDG_CACHE_HOME", buildPath(environment.get("HOME", "/"), ".cache"));
    const cache = buildPath(xdg, "sparkles");
    JobVerdict[] verdicts;
    bool anyFailed;
    void record(string job, RunExpected!void outcome)
    {
        const v = !outcome.hasError ? "passed" : outcome.error.skipped ? "skipped (" ~ outcome.error.message ~ ")"
            : "failed";
        anyFailed |= v == "failed";
        verdicts ~= JobVerdict(job, v);
    }
    void skip(string job, string why) { verdicts ~= JobVerdict(job, "skipped (" ~ why ~ ")"); }

    // The placement, if any, and the mode it runs.
    string mode = "all";
    bool serialLeg = true, parallelLeg = true, coverage = true;
    if (r.placement.length)
    {
        auto loaded = loadPlacements(root);
        const p = loaded.hasError ? null : loaded.value.find(r.placement);
        if (p is null)
            return failRun(loaded.hasError ? loaded.error : "ci/placements.json has no placement " ~ r.placement);
        mode = text(p.mode);
        serialLeg = p.serialLeg;
        parallelLeg = p.parallelLeg;
        coverage = p.coverage;
    }

    string[] subPackages = subPackageDirectories(root).dup;
    if (r.from.length)
        subPackages = subPackages.filter!(d => r.from.canFind(d.baseName)).array;
    const names = subPackages.map!(d => d.baseName).array;
    const capacity = r.jobs ? r.jobs : logicalProcessors;

    // The build graph's run: tests, extracted-mode legs, checks, commit scope.
    if (mode == "all" || mode == "test")
    {
        import commands.toolchain : parallelTestThreads;
        import sparkles.base.hw_caps : hwParallelism;

        const hostN = cast(uint) parallelTestThreads(hwParallelism());
        const parallelN = hostN < capacity ? hostN : capacity;
        TestLeg[] legs;
        if (serialLeg)
            legs ~= TestLeg(1, true, "serial");
        if (parallelLeg)
            legs ~= TestLeg(parallelN, true, "parallel");
        const special = mode == "all" ? specialModeArguments(root, subPackages) : null;

        // The checks a CI job runs, each a node of the graph.
        RunExpected!void delegate()[string] checks;
        if (mode == "all")
        {
            checks["check-sidebar"] = () => runCheckDocsSidebar();
            checks["check-glossary"] = () => runCheckGlossary();
            checks["check-credits"] = () => runCheckCredits();
            checks["check-spec-evidence"] = () => runCheckSpecEvidence(false);
            checks["check-adhoc-sdl"] = () => runCheckAdHocSdl();
            checks["check-opaque-recipes"] = () => runCheckOpaqueRecipes();
            checks["check-pin-cache"] = () => runCheckPinCache();
            checks["check-vcs-urls"] = () => runCheckVcsUrlsCommand(FileSelection.init);
            checks["check-reference-links"] = () => runReferenceLinksCommand(FileSelection.init, false);
            // `ci check commit-scope` over the branch's commits.
            foreach (sha, message; branchMessages(root))
            {
                const file = buildPath(cache, "runs", text("commit-", sha, ".msg"));
                checks["commit-scope-" ~ sha] = () {
                    import std.file : mkdirRecurse, write;

                    mkdirRecurse(buildPath(cache, "runs"));
                    write(file, message);
                    return runCheckCommitScope(file);
                };
            }
        }
        string[string] checkVerdicts;
        TaskOutcome checkNode(ref TaskContext!Sched ctx, const ref InProcessAction a)
        {
            // The body runs on the scheduler's thread, whose module state it
            // reads (`one_node`).
            const name = a.arguments[0];
            RunExpected!void outcome;
            try
                outcome = checks[name]();
            catch (Exception e)
                outcome = failRun(e.msg);
            checkVerdicts[name] = !outcome.hasError ? "passed" : outcome.error.skipped ? "skipped" : "failed";
            return !outcome.hasError ? TaskOutcome(Succeeded())
                : outcome.error.skipped ? TaskOutcome(Skipped(SkipReason.platform))
                : TaskOutcome(Failed(FailureReason.exitStatus, outcome.error.exitCode));
        }

        RunOptions o;
        o.into = buildPath(cache, "runs", text("ci-pipeline-", Clock.currTime.toUnixTime, "-", thisProcessID));
        o.cache = cache;
        o.runnerCore = true;
        o.packages = names.dup;
        o.legs = legs;
        o.coverage = coverage;
        o.failFast = r.failFast;
        o.echo = true;
        o.jobs = capacity;
        o.reporting = RunReporting(interlaced: r.interlaced, timings: true, ci: CiLog.detect(&systemEnvironment));
        o.handlers["pipeline:check"] = &checkNode;
        o.adjustPlan = (ref Planned p) {
            // Each extracted-mode package's leg: a clone of one of its test
            // actions, given the modes' flags (§5.3).
            Action[] added;
            TaskEdge[] edges;
            foreach (pkg, flags; special)
                foreach (ref a; p.graph.actions)
                    if (a.kind == ActionKind.test && a.id.text.startsWith("test:sparkles." ~ pkg ~ ":"))
                    {
                        auto parts = a.id.text.split(":");
                        const id = taskId(parts[0 .. 5] ~ "special").value;
                        auto clone = a;
                        clone.id = id;
                        clone.weight = 1;
                        clone.outputs = null;
                        clone.action = a.action.match!(
                            (ref const ProcessAction pa) {
                                string[] argv;
                                foreach (i, x; pa.argv)
                                    if (x != "--skip-slow" && x != "-t" && (i == 0 || pa.argv[i - 1] != "-t")
                                        && !x.startsWith("--DRT-covopt="))
                                        argv ~= x;
                                return TaskAction(ProcessAction(argv: argv ~ flags ~ ["-t", "1"],
                                    envDelta: pa.envDelta.dup, sandbox: pa.sandbox));
                            },
                            (ref const _) => clone.action);
                        added ~= clone;
                        foreach (ref e; p.graph.edges)
                            if (e.dependent == a.id)
                                edges ~= TaskEdge(e.prerequisite, id, e.condition, e.reason);
                        break;
                    }
            p.graph.actions ~= added;
            p.graph.edges ~= edges;
            foreach (name; checks.keys.sort)
                p.graph.actions ~= Action(ActionKind.test, taskId("check", name).value, size_t.max,
                    TaskAction(InProcessAction("pipeline:check", [name])), null, 1);
        };
        auto g = runGraph(root, null, o);
        if (g.error.length)
            return failRun("ci pipeline: " ~ g.error);
        const testsFailed = g.stats.succeeded.byKeyValue.any!(kv => kv.key.startsWith("test:") && !kv.value);
        anyFailed |= g.exitCode != 0;
        verdicts ~= JobVerdict("test", testsFailed ? "failed" : "passed");
        if (mode == "all")
        {
            const specialFailed = g.stats.succeeded.byKeyValue.any!(kv => kv.key.startsWith("test:")
                && kv.key.canFind(":special") && !kv.value);
            verdicts ~= JobVerdict("extracted-tests", special.length ? specialFailed ? "failed" : "passed"
                : "skipped (no package uses @betterC or @wasm)");
            foreach (name; checkVerdicts.keys.sort)
                verdicts ~= JobVerdict(name, checkVerdicts[name]);
        }
        recordLastRun(cache, LastRun(names.dup, legs, coverage, false, g.stats.resultKeys.dup));

        // CIC13: the determinism check over this run's actions.
        import std.stdio : stdout;

        auto writer = stdout.lockingTextWriter;
        const checked = rerunCheck(root, cache, r.determinismSample, null, writer);
        anyFailed |= checked != 0;
        verdicts ~= JobVerdict("determinism-check", checked == 0 ? "passed" : "failed");
    }
    else
        skip("test", "placement " ~ r.placement);

    if (mode == "all")
    {
        record("examples standalone", runStandaloneExamplesCommand(FileSelection.init, r.failFast));
        record("examples verify", runMarkdownExamplesCommand(ExampleAction.verify, FileSelection(["**.md"],
            ["libs/syntax/test/data/**", "libs/source-view/test/data/**"]), r.failFast));
    }
    // The sanitized tests: LDC on Linux, a graph of their own.
    if (mode == "all" || mode == "sanitize")
    {
        version (linux)
            record("sanitize", runTestCommand(TestCommand(sanitize: Sanitizer.address, failFast: r.failFast, from: r.from.dup,
                placement: r.placement, shard: r.shard, historyTip: r.historyTip, interlaced: r.interlaced)));
        else
            skip("sanitize", "AddressSanitizer runs on Linux");
    }
    if (mode == "extracted")
        record("extracted-tests", runTestCommand(TestCommand(specialModes: SpecialModes.all,
            failFast: r.failFast, placement: r.placement)));
    if (mode == "all")
        record("slow-tests", runTestCommand(TestCommand(slow: true, failFast: r.failFast, from: r.from.dup)));

    // What the pipeline does not run here, and why.
    foreach (job, why; [
        "platform": "other host systems: macOS, Windows and aarch64 run their placements there",
        "nix-build": "Nix builds of the packages: the Nix backend (build graph E4)",
        "nix-build-android": "Android's Nix builds: the Nix backend",
        "static-apps": "static application builds: the Nix backend",
        "shader-reproducibility": "shader builds on two systems: the Nix backend",
        "docs": "the documentation site's build: Node and VitePress",
        "cloud-env": "a cloud environment's preparation",
        "text-conformance": "the WebAssembly text conformance: the Nix backend",
        "nix-wasm": "the Nix evaluator's WebAssembly modules: the Nix backend",
        "freebsd": "FreeBSD: another host system",
        "sync": "base.sync's model checks: their own job",
        "pin-plan": "the binary cache's pin set: CI's planning job",
        "pin-build": "the binary cache's pin builds: the Nix backend",
        "pin-cache": "pushing the pin set: CI's credentials",
        "lint": "pre-commit hooks: `prek run --all-files`",
    ])
        skip(job, why);

    // Every job `ci.yml` runs is named (M12's gate): the checks under their
    // jobs' names, and what this run left out for its placement.
    foreach (ref v; verdicts)
        if (v.job == "check-spec-evidence")
            verdicts ~= JobVerdict("spec-evidence", v.verdict);
    static immutable ciJobs = ["placements", "test", "platform", "slow-tests-list", "slow-tests",
        "extracted-tests", "sanitize", "nix-build", "shader-reproducibility", "nix-build-android", "static-apps",
        "lint", "docs", "cloud-env", "text-conformance", "nix-wasm", "sync", "freebsd", "spec-evidence",
        "pin-plan", "pin-build", "pin-cache", "ci"];
    foreach (job; ciJobs)
        if (!verdicts.any!(v => v.job == job))
            skip(job, job == "placements" ? "CI's planning job: the pipeline reads ci/placements.json itself"
                : job == "ci" ? "the jobs' aggregate: this report"
                : job == "slow-tests-list" ? "the slow tests' matrix: slow-tests runs them"
                : "placement " ~ r.placement);

    writeln();
    verdicts.sort!((a, b) => a.job < b.job);
    foreach (v; verdicts)
        writeln(v.job, ": ", v.verdict);
    return anyFailed ? failRun("ci pipeline: a job failed") : ranOk();
}

/// Each commit of the branch since its merge-base with `origin/main`, by
/// short id: its message.
string[string] branchMessages(string root)
{
    import sparkles.build_primitives.git_env : runGitStdout;
    import std.string : strip;

    string[string] messages;
    const base = runGitStdout(["merge-base", "HEAD", "origin/main"], root);
    if (base.status != 0)
        return messages;
    const shas = runGitStdout(["rev-list", "--abbrev-commit", base.output.strip ~ "..HEAD"], root);
    if (shas.status != 0)
        return messages;
    foreach (sha; shas.output.split("\n"))
        if (sha.strip.length)
        {
            const message = runGitStdout(["log", "-1", "--format=%B", sha.strip], root);
            if (message.status == 0)
                messages[sha.strip.idup] = message.output.idup;
        }
    return messages;
}
